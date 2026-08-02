import Foundation

public enum LocalEventCodecError: Error, Equatable {
    case frameTooLarge(Int)
}

public struct LocalEventCodec: Sendable {
    public static let maximumFrameBytes = 64 * 1024

    public init() {}

    public func encode<T: Encodable>(_ value: T) throws -> Data {
        let data = try JSONEncoder().encode(value)
        try validateFrameSize(data.count)
        return data
    }

    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try validateFrameSize(data.count)
        return try JSONDecoder().decode(type, from: data)
    }

    private func validateFrameSize(_ size: Int) throws {
        guard size <= Self.maximumFrameBytes else {
            throw LocalEventCodecError.frameTooLarge(size)
        }
    }
}
