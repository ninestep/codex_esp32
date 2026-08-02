import CodexRemoteCore
import Darwin
import Foundation
@preconcurrency import Network

public enum UnixSocketEventServerError: Error, Equatable, Sendable {
    case alreadyStarted
    case parentDirectoryMissing(String)
    case socketPathTooLong(String)
    case socketPathAlreadyExists(String)
    case listenerFailed(String)
    case socketPermissionFailed(Int32)
    case socketIdentityUnavailable(Int32)
    case socketPathNotSocket(String)
}

public actor UnixSocketEventServer {
    public typealias Handler = @Sendable (LocalEvent) async throws -> Void

    private let socketURL: URL
    private let maximumActiveConnections: Int
    private let frameReadTimeout: Duration
    private let handler: Handler
    private let queue = DispatchQueue(label: "codex-remote.unix-socket-event-server")
    private let codec = LocalEventCodec()

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: ConnectionState] = [:]
    private var socketIdentity: SocketIdentity?
    private var startContinuation: CheckedContinuation<Void, Error>?

    public init(socketURL: URL, handler: @escaping Handler) {
        self.init(
            socketURL: socketURL,
            maximumActiveConnections: 16,
            frameReadTimeout: .seconds(5),
            handler: handler
        )
    }

    init(
        socketURL: URL,
        maximumActiveConnections: Int = 16,
        frameReadTimeout: Duration = .seconds(5),
        handler: @escaping Handler
    ) {
        self.socketURL = socketURL
        self.maximumActiveConnections = maximumActiveConnections
        self.frameReadTimeout = frameReadTimeout
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

        for state in connections.values {
            state.timeoutTask?.cancel()
            state.connection.cancel()
        }
        connections.removeAll()

        unlinkSocketIfOwned()
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

        var status = stat()
        let result = socketURL.path.withCString { lstat($0, &status) }
        if result == 0 {
            throw UnixSocketEventServerError.socketPathAlreadyExists(socketURL.path)
        }
        guard errno == ENOENT else {
            throw UnixSocketEventServerError.socketIdentityUnavailable(errno)
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            do {
                try chmodSocket()
                socketIdentity = try currentSocketIdentity()
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

    private func currentSocketIdentity() throws -> SocketIdentity {
        var status = stat()
        guard socketURL.path.withCString({ lstat($0, &status) }) == 0 else {
            throw UnixSocketEventServerError.socketIdentityUnavailable(errno)
        }
        guard status.st_mode & S_IFMT == S_IFSOCK else {
            throw UnixSocketEventServerError.socketPathNotSocket(socketURL.path)
        }
        return SocketIdentity(device: status.st_dev, inode: status.st_ino)
    }

    private func unlinkSocketIfOwned() {
        defer {
            socketIdentity = nil
        }
        guard let socketIdentity else {
            return
        }
        guard let currentIdentity = try? currentSocketIdentity(), currentIdentity == socketIdentity else {
            return
        }
        unlink(socketURL.path)
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
        guard connections.count < maximumActiveConnections else {
            connection.start(queue: queue)
            sendResponse(.serverBusy, on: connection, claim: .none)
            return
        }

        let identifier = ObjectIdentifier(connection)
        connections[identifier] = ConnectionState(connection: connection, lifecycle: ConnectionLifecycle(), timeoutTask: nil)
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: frameReadTimeout)
            } catch {
                return
            }
            self.handleReadTimeout(for: connection)
        }
        connections[identifier]?.timeoutTask = timeoutTask
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
        guard canReceiveFrame(from: connection) else {
            return
        }

        let remainingBytes = LocalEventCodec.maximumFrameBytes + 1 - accumulated.count
        guard remainingBytes > 0 else {
            sendResponse(.frameTooLarge, on: connection, claim: .active)
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
            connection.cancel()
            removeConnection(connection)
            return
        }

        guard canReceiveFrame(from: connection) else {
            return
        }

        var frame = accumulated
        if let data {
            frame.append(data)
        }

        if frame.count > LocalEventCodec.maximumFrameBytes {
            sendResponse(.frameTooLarge, on: connection, claim: .active)
            return
        }

        if isComplete {
            guard claimFrameProcessing(for: connection) else {
                return
            }
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
                sendResponse(.frameTooLarge, on: connection, claim: .processing)
            }
            return
        } catch {
            sendResponse(.invalidEvent, on: connection, claim: .processing)
            return
        }

        do {
            try await handler(event)
            sendResponse(.ok, on: connection, claim: .processing)
        } catch {
            sendResponse(.handlerFailed, on: connection, claim: .processing)
        }
    }

    private func sendResponse(
        _ response: SocketResponse,
        on connection: NWConnection,
        claim: ResponseClaim
    ) {
        guard claim == .none || claimResponse(for: connection, claim: claim) else {
            return
        }
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

    private func handleReadTimeout(for connection: NWConnection) {
        guard connections[ObjectIdentifier(connection)] != nil else {
            return
        }
        sendResponse(.readTimeout, on: connection, claim: .timeout)
    }

    private func canReceiveFrame(from connection: NWConnection) -> Bool {
        connections[ObjectIdentifier(connection)]?.lifecycle.canReceiveFrame ?? false
    }

    private func claimFrameProcessing(for connection: NWConnection) -> Bool {
        let identifier = ObjectIdentifier(connection)
        guard var state = connections[identifier] else {
            return false
        }
        guard state.lifecycle.claimFrameProcessing() else {
            return false
        }
        state.timeoutTask?.cancel()
        state.timeoutTask = nil
        connections[identifier] = state
        return true
    }

    private func claimResponse(for connection: NWConnection, claim: ResponseClaim) -> Bool {
        let identifier = ObjectIdentifier(connection)
        guard var state = connections[identifier] else {
            return false
        }

        let claimed = switch claim {
        case .none:
            true
        case .active:
            state.lifecycle.claimActiveResponse()
        case .timeout:
            state.lifecycle.claimTimeoutResponse()
        case .processing:
            state.lifecycle.claimProcessingResponse()
        }
        guard claimed else {
            return false
        }
        state.timeoutTask?.cancel()
        state.timeoutTask = nil
        connections[identifier] = state
        return true
    }

    private func removeConnection(_ connection: NWConnection) {
        let state = connections.removeValue(forKey: ObjectIdentifier(connection))
        state?.timeoutTask?.cancel()
    }

    private static var maximumUnixSocketPathBytes: Int {
        MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    }
}

private enum ResponseClaim: Equatable {
    case none
    case active
    case timeout
    case processing
}

private struct ConnectionState {
    let connection: NWConnection
    var lifecycle: ConnectionLifecycle
    var timeoutTask: Task<Void, Never>?
}

struct ConnectionLifecycle: Sendable {
    private enum Phase: Sendable {
        case active
        case processing
        case responding
    }

    private var phase: Phase = .active

    var canReceiveFrame: Bool {
        phase == .active
    }

    mutating func claimFrameProcessing() -> Bool {
        guard phase == .active else {
            return false
        }
        phase = .processing
        return true
    }

    mutating func claimActiveResponse() -> Bool {
        guard phase == .active else {
            return false
        }
        phase = .responding
        return true
    }

    mutating func claimTimeoutResponse() -> Bool {
        claimActiveResponse()
    }

    mutating func claimProcessingResponse() -> Bool {
        guard phase == .processing else {
            return false
        }
        phase = .responding
        return true
    }
}

private struct SocketIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
}

private enum SocketResponse {
    case ok
    case invalidEvent
    case frameTooLarge
    case handlerFailed
    case serverBusy
    case readTimeout

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
        case .serverBusy:
            failureData(code: "server_busy")
        case .readTimeout:
            failureData(code: "read_timeout")
        }
    }

    private func failureData(code: String) -> Data {
        Data(#"{"ok":false,"error":"\#(code)"}"#.utf8)
    }
}
