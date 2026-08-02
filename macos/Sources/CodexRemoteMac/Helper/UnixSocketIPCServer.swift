import CodexRemoteCore
import Darwin
import Foundation
@preconcurrency import Network

public enum UnixSocketIPCServerError: Error, Equatable, Sendable {
    case alreadyStarted
    case parentDirectoryMissing(String)
    case socketPathTooLong(String)
    case socketPathAlreadyExists(String)
    case listenerFailed(String)
    case socketPermissionFailed(Int32)
    case socketIdentityUnavailable(Int32)
    case socketPathNotSocket(String)
}

public actor UnixSocketIPCServer {
    public typealias Handler = @Sendable (LocalIPCRequest) async throws -> LocalIPCResponse

    private let socketURL: URL
    private let maximumActiveConnections: Int
    private let frameReadTimeout: Duration
    private let handler: Handler
    private let queue = DispatchQueue(label: "codex-remote.unix-socket-ipc-server")
    private let codec = LocalIPCCodec()

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: IPCConnectionState] = [:]
    private var socketIdentity: IPCSocketIdentity?
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
            throw UnixSocketIPCServerError.alreadyStarted
        }
        try validateSocketPath()

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: socketURL.path)
        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters)
        } catch {
            throw UnixSocketIPCServerError.listenerFailed(String(describing: error))
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
            continuation.resume(throwing: UnixSocketIPCServerError.listenerFailed("stopped"))
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
            throw UnixSocketIPCServerError.parentDirectoryMissing(parentPath)
        }

        guard socketURL.path.utf8.count < Self.maximumUnixSocketPathBytes else {
            throw UnixSocketIPCServerError.socketPathTooLong(socketURL.path)
        }

        var status = stat()
        let result = socketURL.path.withCString { lstat($0, &status) }
        if result == 0 {
            throw UnixSocketIPCServerError.socketPathAlreadyExists(socketURL.path)
        }
        guard errno == ENOENT else {
            throw UnixSocketIPCServerError.socketIdentityUnavailable(errno)
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
            resumeStart(throwing: UnixSocketIPCServerError.listenerFailed(String(describing: error)))
        case .cancelled:
            listener = nil
            resumeStart(throwing: UnixSocketIPCServerError.listenerFailed("cancelled"))
        default:
            break
        }
    }

    private func chmodSocket() throws {
        guard chmod(socketURL.path, S_IRUSR | S_IWUSR) == 0 else {
            throw UnixSocketIPCServerError.socketPermissionFailed(errno)
        }
    }

    private func currentSocketIdentity() throws -> IPCSocketIdentity {
        var status = stat()
        guard socketURL.path.withCString({ lstat($0, &status) }) == 0 else {
            throw UnixSocketIPCServerError.socketIdentityUnavailable(errno)
        }
        guard status.st_mode & S_IFMT == S_IFSOCK else {
            throw UnixSocketIPCServerError.socketPathNotSocket(socketURL.path)
        }
        return IPCSocketIdentity(device: status.st_dev, inode: status.st_ino)
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
            sendResponse(.error(code: .serverBusy), on: connection, claim: .none)
            return
        }

        let identifier = ObjectIdentifier(connection)
        connections[identifier] = IPCConnectionState(connection: connection, lifecycle: IPCConnectionLifecycle(), timeoutTask: nil)
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

        let remainingBytes = LocalIPCCodec.maximumFrameBytes + 1 - accumulated.count
        guard remainingBytes > 0 else {
            sendResponse(.error(code: .frameTooLarge), on: connection, claim: .active)
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

        if frame.count > LocalIPCCodec.maximumFrameBytes {
            sendResponse(.error(code: .frameTooLarge), on: connection, claim: .active)
            return
        }

        if let newlineIndex = frame.firstIndex(of: UInt8(ascii: "\n")) {
            guard claimFrameProcessing(for: connection) else {
                return
            }
            await process(Data(frame[...newlineIndex]), on: connection)
            return
        }

        if isComplete {
            guard claimFrameProcessing(for: connection) else {
                return
            }
            sendResponse(.error(code: .invalidRequest), on: connection, claim: .processing)
            return
        }

        receiveFrame(from: connection, accumulated: frame)
    }

    private func process(_ frame: Data, on connection: NWConnection) async {
        let request: LocalIPCRequest
        do {
            request = try codec.decodeRequest(frame)
        } catch let error as LocalIPCCodecError {
            switch error {
            case .frameTooLarge:
                sendResponse(.error(code: .frameTooLarge), on: connection, claim: .processing)
            case .missingNewline:
                sendResponse(.error(code: .invalidRequest), on: connection, claim: .processing)
            }
            return
        } catch {
            sendResponse(.error(code: .invalidRequest), on: connection, claim: .processing)
            return
        }

        do {
            let response = try await handler(request)
            sendResponse(response, on: connection, claim: .processing)
        } catch {
            sendResponse(.error(code: .handlerFailed), on: connection, claim: .processing)
        }
    }

    private func sendResponse(
        _ response: LocalIPCResponse,
        on connection: NWConnection,
        claim: IPCResponseClaim
    ) {
        guard claim == .none || claimResponse(for: connection, claim: claim) else {
            return
        }

        let data: Data
        do {
            data = try codec.encodeResponse(response)
        } catch {
            data = Data(#"{"version":1,"type":"error","code":"handler_failed"}"#.utf8 + [UInt8(ascii: "\n")])
        }
        connection.send(
            content: data,
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
        sendResponse(.error(code: .readTimeout), on: connection, claim: .timeout)
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

    private func claimResponse(for connection: NWConnection, claim: IPCResponseClaim) -> Bool {
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

private enum IPCResponseClaim: Equatable {
    case none
    case active
    case timeout
    case processing
}

private struct IPCConnectionState {
    let connection: NWConnection
    var lifecycle: IPCConnectionLifecycle
    var timeoutTask: Task<Void, Never>?
}

private struct IPCConnectionLifecycle: Sendable {
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

private struct IPCSocketIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
}
