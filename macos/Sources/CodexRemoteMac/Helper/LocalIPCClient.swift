import CodexRemoteCore
import Darwin
import Foundation

public protocol LocalIPCClienting: Sendable {
    func send(_ request: LocalIPCRequest, to socketURL: URL) async throws -> LocalIPCResponse
}

public enum LocalIPCClientError: Error, Equatable, Sendable {
    case connectFailed(Int32)
    case connectTimedOut
    case sendFailed(Int32)
    case receiveFailed(Int32)
    case emptyResponse
    case readTimedOut
}

public struct LocalIPCClient: LocalIPCClienting {
    private let codec: LocalIPCCodec
    private let responseTimeout: Duration

    public init(codec: LocalIPCCodec = LocalIPCCodec(), responseTimeout: Duration = .seconds(5)) {
        self.codec = codec
        self.responseTimeout = responseTimeout
    }

    public func send(_ request: LocalIPCRequest, to socketURL: URL) async throws -> LocalIPCResponse {
        let frame = try codec.encodeRequest(request)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw LocalIPCClientError.connectFailed(errno)
        }
        defer {
            close(descriptor)
        }
        try configure(descriptor)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketURL.path.utf8CString)
        let sunPathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= sunPathCapacity else {
            throw LocalIPCClientError.connectFailed(ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: sunPathCapacity) { buffer in
                for index in pathBytes.indices {
                    buffer[index] = pathBytes[index]
                }
            }
        }

        let deadline = IPCDeadline(timeout: responseTimeout)
        try connect(descriptor, to: &address, deadline: deadline)

        try writeAll(frame, to: descriptor, deadline: deadline)
        shutdown(descriptor, SHUT_WR)
        let response = try readLine(from: descriptor, deadline: deadline)
        guard !response.isEmpty else {
            throw LocalIPCClientError.emptyResponse
        }
        return try codec.decodeResponse(response)
    }

    private func configure(_ descriptor: Int32) throws {
        var noSigpipe: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigpipe,
            socklen_t(MemoryLayout.size(ofValue: noSigpipe))
        ) == 0 else {
            throw LocalIPCClientError.sendFailed(errno)
        }

        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw LocalIPCClientError.connectFailed(errno)
        }
    }

    private func connect(_ descriptor: Int32, to address: inout sockaddr_un, deadline: IPCDeadline) throws {
        while true {
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result == 0 {
                return
            }

            switch errno {
            case EINTR:
                continue
            case EINPROGRESS, EALREADY:
                do {
                    try waitFor(descriptor, events: Int16(POLLOUT), deadline: deadline)
                } catch IPCPollError.timedOut {
                    throw LocalIPCClientError.connectTimedOut
                } catch IPCPollError.failed(let code) {
                    throw LocalIPCClientError.connectFailed(code)
                }
                var socketError: Int32 = 0
                var socketErrorLength = socklen_t(MemoryLayout.size(ofValue: socketError))
                guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &socketErrorLength) == 0 else {
                    throw LocalIPCClientError.connectFailed(errno)
                }
                guard socketError == 0 else {
                    throw LocalIPCClientError.connectFailed(socketError)
                }
                return
            case EAGAIN:
                throw LocalIPCClientError.connectTimedOut
            default:
                throw LocalIPCClientError.connectFailed(errno)
            }
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32, deadline: IPCDeadline) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }

            var written = 0
            while written < data.count {
                do {
                    try waitFor(descriptor, events: Int16(POLLOUT), deadline: deadline)
                } catch IPCPollError.timedOut {
                    throw LocalIPCClientError.sendFailed(ETIMEDOUT)
                } catch IPCPollError.failed(let code) {
                    throw LocalIPCClientError.sendFailed(code)
                }
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    data.count - written
                )
                if result > 0 {
                    written += result
                    continue
                }
                switch errno {
                case EINTR:
                    continue
                case EAGAIN, EWOULDBLOCK:
                    continue
                default:
                    throw LocalIPCClientError.sendFailed(errno)
                }
            }
        }
    }

    private func readLine(from descriptor: Int32, deadline: IPCDeadline) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= LocalIPCCodec.maximumFrameBytes {
            do {
                try waitFor(descriptor, events: Int16(POLLIN), deadline: deadline)
            } catch IPCPollError.timedOut {
                throw LocalIPCClientError.readTimedOut
            } catch IPCPollError.failed(let code) {
                throw LocalIPCClientError.receiveFailed(code)
            }
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
                if data.last == UInt8(ascii: "\n") {
                    return data
                }
                continue
            }
            if count == 0 {
                return data
            }
            switch errno {
            case EINTR:
                continue
            case EAGAIN, EWOULDBLOCK:
                continue
            default:
                throw LocalIPCClientError.receiveFailed(errno)
            }
        }
        throw LocalIPCCodecError.frameTooLarge(data.count)
    }

    private func waitFor(_ descriptor: Int32, events: Int16, deadline: IPCDeadline) throws {
        var pollDescriptor = pollfd(fd: descriptor, events: events, revents: 0)
        while true {
            let result = poll(&pollDescriptor, 1, try deadline.remainingMilliseconds())
            if result > 0 {
                if pollDescriptor.revents & Int16(POLLERR | POLLNVAL) != 0 {
                    throw IPCPollError.failed(EIO)
                }
                return
            }
            if result == 0 {
                throw IPCPollError.timedOut
            }
            if errno == EINTR {
                continue
            }
            throw IPCPollError.failed(errno)
        }
    }
}

private enum IPCPollError: Error {
    case timedOut
    case failed(Int32)
}

private struct IPCDeadline: Sendable {
    private let endUptimeNanoseconds: UInt64

    init(timeout: Duration) {
        let now = DispatchTime.now().uptimeNanoseconds
        self.endUptimeNanoseconds = now.saturatingAdding(timeout.nanoseconds)
    }

    func remainingMilliseconds() throws -> Int32 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < endUptimeNanoseconds else {
            throw IPCPollError.timedOut
        }
        let remainingNanoseconds = endUptimeNanoseconds - now
        let milliseconds = max(1, (remainingNanoseconds + 999_999) / 1_000_000)
        return Int32(min(UInt64(Int32.max), milliseconds))
    }
}

private extension Duration {
    var nanoseconds: UInt64 {
        let components = self.components
        guard components.seconds > 0 || components.attoseconds > 0 else {
            return 0
        }
        let secondPart = UInt64(max(0, components.seconds)).saturatingMultiplying(1_000_000_000)
        let nanoPart = UInt64(max(0, components.attoseconds / 1_000_000_000))
        return secondPart.saturatingAdding(nanoPart)
    }
}

private extension UInt64 {
    func saturatingAdding(_ value: UInt64) -> UInt64 {
        let (result, overflow) = addingReportingOverflow(value)
        return overflow ? UInt64.max : result
    }

    func saturatingMultiplying(_ value: UInt64) -> UInt64 {
        let (result, overflow) = multipliedReportingOverflow(by: value)
        return overflow ? UInt64.max : result
    }
}
