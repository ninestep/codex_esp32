import CodexRemoteCore
import Darwin
import Foundation

public protocol LocalIPCClienting: Sendable {
    func send(_ request: LocalIPCRequest, to socketURL: URL) async throws -> LocalIPCResponse
}

public enum LocalIPCClientError: Error, Equatable, Sendable {
    case connectFailed(Int32)
    case sendFailed(Int32)
    case receiveFailed(Int32)
    case emptyResponse
}

public struct LocalIPCClient: LocalIPCClienting {
    private let codec: LocalIPCCodec

    public init(codec: LocalIPCCodec = LocalIPCCodec()) {
        self.codec = codec
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

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw LocalIPCClientError.connectFailed(errno)
        }

        try writeAll(frame, to: descriptor)
        shutdown(descriptor, SHUT_WR)
        let response = try readLine(from: descriptor)
        guard !response.isEmpty else {
            throw LocalIPCClientError.emptyResponse
        }
        return try codec.decodeResponse(response)
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }

            var written = 0
            while written < data.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    data.count - written
                )
                guard result > 0 else {
                    throw LocalIPCClientError.sendFailed(errno)
                }
                written += result
            }
        }
    }

    private func readLine(from descriptor: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= LocalIPCCodec.maximumFrameBytes {
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
            throw LocalIPCClientError.receiveFailed(errno)
        }
        throw LocalIPCCodecError.frameTooLarge(data.count)
    }
}
