import Foundation

public struct BLEEnvelopeCodec: Sendable {
    public static let maximumFrameBytes = 256 * 1024
    public static let fixedOverheadBytes = 18

    private static let magic = Data([0x43, 0x52])
    private static let headerBytes = 14
    private static let checksumBytes = 4

    public init() {}

    public func encode(_ envelope: BLEEnvelope) throws -> Data {
        guard envelope.flags == 0 else {
            throw BLECodecError.unsupportedFlags(envelope.flags)
        }
        guard let payloadLength = UInt32(exactly: envelope.payload.count) else {
            throw BLECodecError.numericOverflow
        }

        let encodedSize = Self.fixedOverheadBytes + envelope.payload.count
        guard encodedSize <= Self.maximumFrameBytes else {
            throw BLECodecError.frameTooLarge(encodedSize)
        }

        var encoder = BLEBinaryEncoder()
        encoder.append(Self.magic)
        encoder.append(envelope.version.major)
        encoder.append(envelope.version.minor)
        encoder.append(envelope.type.rawValue)
        encoder.append(envelope.flags)
        encoder.append(envelope.sequence)
        encoder.append(payloadLength)
        encoder.append(envelope.payload)

        var data = encoder.data
        data.append(contentsOf: BLECRC32.checksum(data).littleEndianBytes)
        return data
    }

    public func decode(_ data: Data) throws -> BLEEnvelope {
        guard data.count >= Self.fixedOverheadBytes else {
            throw BLECodecError.truncated
        }
        guard data.count <= Self.maximumFrameBytes else {
            throw BLECodecError.frameTooLarge(data.count)
        }

        var decoder = BLEBinaryDecoder(data: Data(data.prefix(Self.headerBytes)))
        guard try decoder.readData(count: 2) == Self.magic else {
            throw BLECodecError.invalidMagic
        }
        let major = try decoder.readUInt8()
        let minor = try decoder.readUInt8()
        guard major == BLEProtocolVersion.current.major else {
            throw BLECodecError.incompatibleMajorVersion(major)
        }

        let rawType = try decoder.readUInt8()
        guard let type = BLEMessageType(rawValue: rawType) else {
            throw BLECodecError.unknownMessageType(rawType)
        }
        let flags = try decoder.readUInt8()
        guard flags == 0 else {
            throw BLECodecError.unsupportedFlags(flags)
        }
        let sequence = try decoder.readUInt32()
        let expectedPayloadLength = Int(try decoder.readUInt32())
        let actualPayloadLength = data.count - Self.fixedOverheadBytes
        guard expectedPayloadLength == actualPayloadLength else {
            throw BLECodecError.payloadLengthMismatch(expected: expectedPayloadLength, actual: actualPayloadLength)
        }

        let bodyEnd = data.index(data.endIndex, offsetBy: -Self.checksumBytes)
        let body = data[..<bodyEnd]
        var checksumDecoder = BLEBinaryDecoder(data: Data(data[bodyEnd...]))
        let expectedChecksum = try checksumDecoder.readUInt32()
        guard BLECRC32.checksum(body) == expectedChecksum else {
            throw BLECodecError.crcMismatch
        }

        let payloadStart = data.index(data.startIndex, offsetBy: Self.headerBytes)
        let payload = Data(data[payloadStart..<bodyEnd])
        return BLEEnvelope(
            version: BLEProtocolVersion(major: major, minor: minor),
            type: type,
            flags: flags,
            sequence: sequence,
            payload: payload
        )
    }
}
