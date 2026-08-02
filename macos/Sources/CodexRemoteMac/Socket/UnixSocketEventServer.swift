import CodexRemoteCore
import Darwin
import Foundation
@preconcurrency import Network

public enum UnixSocketEventServerError: Error, Equatable, Sendable {
    case alreadyStarted
    case parentDirectoryMissing(String)
    case socketPathTooLong(String)
    case listenerFailed(String)
    case socketPermissionFailed(Int32)
}

public actor UnixSocketEventServer {
    public typealias Handler = @Sendable (LocalEvent) async throws -> Void

    private let socketURL: URL
    private let handler: Handler
    private let queue = DispatchQueue(label: "codex-remote.unix-socket-event-server")
    private let codec = LocalEventCodec()

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var startContinuation: CheckedContinuation<Void, Error>?

    public init(socketURL: URL, handler: @escaping Handler) {
        self.socketURL = socketURL
        self.handler = handler
    }

    public func start() async throws {
        guard listener == nil, startContinuation == nil else {
            throw UnixSocketEventServerError.alreadyStarted
        }
        try validateSocketPath()

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: socketURL.path)
        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters)
        } catch {
            throw UnixSocketEventServerError.listenerFailed(String(describing: error))
        }

        listener = newListener
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startContinuation = continuation
                newListener.stateUpdateHandler = { [weak newListener] state in
                    guard newListener != nil else {
                        return
                    }
                    Task {
                        await self.handleListenerState(state)
                    }
                }
                newListener.newConnectionHandler = { connection in
                    Task {
                        await self.accept(connection)
                    }
                }
                newListener.start(queue: queue)
            }
        } onCancel: {
            newListener.cancel()
        }
    }

    public func stop() async {
        if let continuation = startContinuation {
            startContinuation = nil
            continuation.resume(throwing: UnixSocketEventServerError.listenerFailed("stopped"))
        }

        listener?.cancel()
        listener = nil

        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()

        unlink(socketURL.path)
    }

    private func validateSocketPath() throws {
        let parentPath = socketURL.deletingLastPathComponent().path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parentPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw UnixSocketEventServerError.parentDirectoryMissing(parentPath)
        }

        guard socketURL.path.utf8.count < Self.maximumUnixSocketPathBytes else {
            throw UnixSocketEventServerError.socketPathTooLong(socketURL.path)
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            do {
                try chmodSocket()
                resumeStart()
            } catch {
                listener?.cancel()
                listener = nil
                resumeStart(throwing: error)
            }
        case .failed(let error):
            listener?.cancel()
            listener = nil
            resumeStart(throwing: UnixSocketEventServerError.listenerFailed(String(describing: error)))
        case .cancelled:
            listener = nil
            resumeStart(throwing: UnixSocketEventServerError.listenerFailed("cancelled"))
        default:
            break
        }
    }

    private func chmodSocket() throws {
        guard chmod(socketURL.path, S_IRUSR | S_IWUSR) == 0 else {
            throw UnixSocketEventServerError.socketPermissionFailed(errno)
        }
    }

    private func resumeStart(throwing error: Error? = nil) {
        guard let continuation = startContinuation else {
            return
        }
        startContinuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    private func accept(_ connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        connections[identifier] = connection
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled:
                Task {
                    await self.removeConnection(connection)
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveFrame(from: connection, accumulated: Data())
    }

    private func receiveFrame(from connection: NWConnection, accumulated: Data) {
        let remainingBytes = LocalEventCodec.maximumFrameBytes + 1 - accumulated.count
        guard remainingBytes > 0 else {
            sendResponse(.frameTooLarge, on: connection)
            return
        }

        connection.receive(minimumIncompleteLength: 1, maximumLength: remainingBytes) { data, _, isComplete, error in
            Task {
                await self.handleReceive(
                    data: data,
                    isComplete: isComplete,
                    error: error,
                    accumulated: accumulated,
                    connection: connection
                )
            }
        }
    }

    private func handleReceive(
        data: Data?,
        isComplete: Bool,
        error: NWError?,
        accumulated: Data,
        connection: NWConnection
    ) async {
        if error != nil {
            removeConnection(connection)
            return
        }

        var frame = accumulated
        if let data {
            frame.append(data)
        }

        if frame.count > LocalEventCodec.maximumFrameBytes {
            sendResponse(.frameTooLarge, on: connection)
            return
        }

        if isComplete {
            await process(frame, on: connection)
            return
        }

        receiveFrame(from: connection, accumulated: frame)
    }

    private func process(_ frame: Data, on connection: NWConnection) async {
        let event: LocalEvent
        do {
            event = try codec.decode(frame)
        } catch let error as LocalEventCodecError {
            switch error {
            case .frameTooLarge:
                sendResponse(.frameTooLarge, on: connection)
            }
            return
        } catch {
            sendResponse(.invalidEvent, on: connection)
            return
        }

        do {
            try await handler(event)
            sendResponse(.ok, on: connection)
        } catch {
            sendResponse(.handlerFailed, on: connection)
        }
    }

    private func sendResponse(_ response: SocketResponse, on connection: NWConnection) {
        connection.send(
            content: response.data,
            contentContext: .defaultMessage,
            isComplete: true,
            completion: .contentProcessed { _ in
                Task {
                    await self.removeConnection(connection)
                }
                connection.cancel()
            }
        )
    }

    private func removeConnection(_ connection: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
    }

    private static var maximumUnixSocketPathBytes: Int {
        MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    }
}

private enum SocketResponse {
    case ok
    case invalidEvent
    case frameTooLarge
    case handlerFailed

    var data: Data {
        switch self {
        case .ok:
            Data(#"{"ok":true}"#.utf8)
        case .invalidEvent:
            failureData(code: "invalid_event")
        case .frameTooLarge:
            failureData(code: "frame_too_large")
        case .handlerFailed:
            failureData(code: "handler_failed")
        }
    }

    private func failureData(code: String) -> Data {
        Data(#"{"ok":false,"error":"\#(code)"}"#.utf8)
    }
}
