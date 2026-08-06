import Foundation

public enum LocalIPCCodecError: Error, Equatable, Sendable {
    case frameTooLarge(Int)
    case missingNewline
}

public enum LocalIPCErrorCode: String, Codable, Equatable, Sendable {
    case invalidRequest = "invalid_request"
    case frameTooLarge = "frame_too_large"
    case handlerFailed = "handler_failed"
    case serverBusy = "server_busy"
    case readTimeout = "read_timeout"
}

public enum LocalIPCRequest: Equatable, Sendable {
    case registerLaunch(launcherID: String)
    case unregisterLaunch(launcherID: String)
    case hook(HookPayload)
    case list
    case focus(remoteSessionID: String)
    case scroll(remoteSessionID: String, deltaY: Int)
    case key(remoteSessionID: String, key: TerminalKey)
}

extension LocalIPCRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case version
        case type
        case launcherID
        case payload
        case sessionID
        case deltaY
        case key
    }

    private enum RequestType: String, Codable {
        case registerLaunch
        case unregisterLaunch
        case hook
        case list
        case focus
        case scroll
        case key
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .version) == 1 else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "unsupported version")
        }

        switch try container.decode(RequestType.self, forKey: .type) {
        case .registerLaunch:
            self = .registerLaunch(launcherID: try container.decode(String.self, forKey: .launcherID))
        case .unregisterLaunch:
            self = .unregisterLaunch(launcherID: try container.decode(String.self, forKey: .launcherID))
        case .hook:
            self = .hook(try container.decode(HookPayload.self, forKey: .payload))
        case .list:
            self = .list
        case .focus:
            self = .focus(remoteSessionID: try container.decode(String.self, forKey: .sessionID))
        case .scroll:
            self = .scroll(
                remoteSessionID: try container.decode(String.self, forKey: .sessionID),
                deltaY: try container.decode(Int.self, forKey: .deltaY)
            )
        case .key:
            self = .key(
                remoteSessionID: try container.decode(String.self, forKey: .sessionID),
                key: try container.decode(TerminalKey.self, forKey: .key)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .version)

        switch self {
        case .registerLaunch(let launcherID):
            try container.encode(RequestType.registerLaunch, forKey: .type)
            try container.encode(launcherID, forKey: .launcherID)
        case .unregisterLaunch(let launcherID):
            try container.encode(RequestType.unregisterLaunch, forKey: .type)
            try container.encode(launcherID, forKey: .launcherID)
        case .hook(let payload):
            try container.encode(RequestType.hook, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .list:
            try container.encode(RequestType.list, forKey: .type)
        case .focus(let remoteSessionID):
            try container.encode(RequestType.focus, forKey: .type)
            try container.encode(remoteSessionID, forKey: .sessionID)
        case .scroll(let remoteSessionID, let deltaY):
            try container.encode(RequestType.scroll, forKey: .type)
            try container.encode(remoteSessionID, forKey: .sessionID)
            try container.encode(deltaY, forKey: .deltaY)
        case .key(let remoteSessionID, let key):
            try container.encode(RequestType.key, forKey: .type)
            try container.encode(remoteSessionID, forKey: .sessionID)
            try container.encode(key, forKey: .key)
        }
    }
}

public enum LocalIPCResponse: Equatable, Sendable {
    case ok
    case sessions([RemoteSession])
    case error(code: LocalIPCErrorCode)
}

extension LocalIPCResponse: Codable {
    private enum CodingKeys: String, CodingKey {
        case version
        case type
        case sessions
        case code
    }

    private enum ResponseType: String, Codable {
        case ok
        case sessions
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .version) == 1 else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "unsupported version")
        }

        switch try container.decode(ResponseType.self, forKey: .type) {
        case .ok:
            self = .ok
        case .sessions:
            self = .sessions(try container.decode([RemoteSession].self, forKey: .sessions))
        case .error:
            self = .error(code: try container.decode(LocalIPCErrorCode.self, forKey: .code))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .version)

        switch self {
        case .ok:
            try container.encode(ResponseType.ok, forKey: .type)
        case .sessions(let sessions):
            try container.encode(ResponseType.sessions, forKey: .type)
            try container.encode(sessions, forKey: .sessions)
        case .error(let code):
            try container.encode(ResponseType.error, forKey: .type)
            try container.encode(code, forKey: .code)
        }
    }
}

public struct LocalIPCCodec: Sendable {
    public static let maximumFrameBytes = 64 * 1024

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func encodeRequest(_ request: LocalIPCRequest) throws -> Data {
        try encodeLine(request)
    }

    public func decodeRequest(_ data: Data) throws -> LocalIPCRequest {
        try decodeLine(LocalIPCRequest.self, from: data)
    }

    public func encodeResponse(_ response: LocalIPCResponse) throws -> Data {
        try encodeLine(response)
    }

    public func decodeResponse(_ data: Data) throws -> LocalIPCResponse {
        try decodeLine(LocalIPCResponse.self, from: data)
    }

    private func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try encoder.encode(value)
        data.append(UInt8(ascii: "\n"))
        try validateFrameSize(data.count)
        return data
    }

    private func decodeLine<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try validateFrameSize(data.count)
        guard data.last == UInt8(ascii: "\n") else {
            throw LocalIPCCodecError.missingNewline
        }
        return try decoder.decode(type, from: data.dropLast())
    }

    private func validateFrameSize(_ size: Int) throws {
        guard size <= Self.maximumFrameBytes else {
            throw LocalIPCCodecError.frameTooLarge(size)
        }
    }
}
