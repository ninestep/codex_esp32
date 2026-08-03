import Foundation

public enum BLEFragmentError: Error, Equatable, Sendable {
    case packetTooSmall(Int)
    case malformedFragment
    case invalidFragmentCount(UInt16)
    case tooManyFragments(UInt16)
    case messageTooLarge(Int)
    case unexpectedFragmentIndex(expected: UInt16, actual: UInt16)
    case unexpectedMessageID(expected: UInt32, actual: UInt32)
    case fragmentCountMismatch(expected: UInt16, actual: UInt16)
}

public enum BLEReassemblyResult: Equatable, Sendable {
    case waiting
    case complete(Data)
}

public struct BLEFragmentCodec: Sendable {
    public static let headerBytes = 8
    public static let maximumMessageBytes = 256 * 1024
    public static let maximumFragments = 1_024

    public init() {}

    public func fragment(
        _ message: Data,
        messageID: UInt32,
        maximumPacketBytes: Int
    ) throws -> [Data] {
        guard maximumPacketBytes > Self.headerBytes else {
            throw BLEFragmentError.packetTooSmall(maximumPacketBytes)
        }
        guard message.count <= Self.maximumMessageBytes else {
            throw BLEFragmentError.messageTooLarge(message.count)
        }

        let payloadCapacity = maximumPacketBytes - Self.headerBytes
        let requiredCount = max(1, (message.count + payloadCapacity - 1) / payloadCapacity)
        guard requiredCount <= Self.maximumFragments, let fragmentCount = UInt16(exactly: requiredCount) else {
            throw BLEFragmentError.tooManyFragments(UInt16(clamping: requiredCount))
        }

        return (0..<requiredCount).map { index in
            let startOffset = index * payloadCapacity
            let endOffset = min(startOffset + payloadCapacity, message.count)
            var encoder = BLEBinaryEncoder()
            encoder.append(messageID)
            encoder.append(UInt16(index))
            encoder.append(fragmentCount)
            if startOffset < endOffset {
                let start = message.index(message.startIndex, offsetBy: startOffset)
                let end = message.index(message.startIndex, offsetBy: endOffset)
                encoder.append(message[start..<end])
            }
            return encoder.data
        }
    }
}

public struct BLEFragmentReassembler: Sendable {
    private var messageID: UInt32?
    private var fragmentCount: UInt16?
    private var nextIndex: UInt16 = 0
    private var accumulated = Data()

    public init() {}

    public mutating func accept(_ packet: Data) throws -> BLEReassemblyResult {
        do {
            return try acceptValidated(packet)
        } catch {
            reset()
            throw error
        }
    }

    public mutating func reset() {
        messageID = nil
        fragmentCount = nil
        nextIndex = 0
        accumulated.removeAll(keepingCapacity: false)
    }

    private mutating func acceptValidated(_ packet: Data) throws -> BLEReassemblyResult {
        guard packet.count >= BLEFragmentCodec.headerBytes else {
            throw BLEFragmentError.malformedFragment
        }
        var decoder = BLEBinaryDecoder(data: packet)
        let incomingMessageID = try decoder.readUInt32()
        let incomingIndex = try decoder.readUInt16()
        let incomingCount = try decoder.readUInt16()

        guard incomingCount > 0 else {
            throw BLEFragmentError.invalidFragmentCount(incomingCount)
        }
        guard incomingCount <= BLEFragmentCodec.maximumFragments else {
            throw BLEFragmentError.tooManyFragments(incomingCount)
        }
        guard incomingIndex < incomingCount else {
            throw BLEFragmentError.unexpectedFragmentIndex(expected: nextIndex, actual: incomingIndex)
        }

        if let messageID, messageID != incomingMessageID {
            throw BLEFragmentError.unexpectedMessageID(expected: messageID, actual: incomingMessageID)
        }
        if let fragmentCount, fragmentCount != incomingCount {
            throw BLEFragmentError.fragmentCountMismatch(expected: fragmentCount, actual: incomingCount)
        }
        guard incomingIndex == nextIndex else {
            throw BLEFragmentError.unexpectedFragmentIndex(expected: nextIndex, actual: incomingIndex)
        }

        if messageID == nil {
            messageID = incomingMessageID
            fragmentCount = incomingCount
        }

        let payload = try decoder.readData(count: decoder.remainingCount)
        guard accumulated.count + payload.count <= BLEFragmentCodec.maximumMessageBytes else {
            throw BLEFragmentError.messageTooLarge(accumulated.count + payload.count)
        }
        accumulated.append(payload)
        nextIndex += 1

        if nextIndex == incomingCount {
            let complete = accumulated
            reset()
            return .complete(complete)
        }
        return .waiting
    }
}
