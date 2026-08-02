import Foundation

public enum LocalEventCodecError: Error, Equatable {
    case frameTooLarge(Int)
}

public struct LocalEventCodec: Sendable {
    public static let maximumFrameBytes = 64 * 1024

    public init() {}

    public func encode(_ event: LocalEvent) throws -> Data {
        let data = try JSONEncoder().encode(event)
        try validateFrameSize(data.count)
        return data
    }

    public func decode(_ data: Data) throws -> LocalEvent {
        try validateFrameSize(data.count)
        return try JSONDecoder().decode(LocalEvent.self, from: data)
    }

    private func validateFrameSize(_ size: Int) throws {
        guard size <= Self.maximumFrameBytes else {
            throw LocalEventCodecError.frameTooLarge(size)
        }
    }
}
