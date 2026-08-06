import Foundation

public struct BLEProtocolVersion: Equatable, Sendable {
    public static let current = BLEProtocolVersion(major: 1, minor: 2)

    public let major: UInt8
    public let minor: UInt8

    public init(major: UInt8, minor: UInt8) {
        self.major = major
        self.minor = minor
    }
}

public enum BLEMessageType: UInt8, CaseIterable, Sendable {
    case selectSession = 0x01
    case scroll = 0x02
    case terminalKey = 0x03
    case pttBegin = 0x04
    case pttEnd = 0x05
    case actionResult = 0x06
    case stateSnapshot = 0x07
    case stateDelta = 0x08
    case audioFrame = 0x09
    case assetManifest = 0x0a
    case assetChunk = 0x0b
    case assetAcknowledgement = 0x0c
    case deviceInfo = 0x0d
    case resyncRequired = 0x0e
    case terminalShortcut = 0x0f
}

public struct BLEEnvelope: Equatable, Sendable {
    public let version: BLEProtocolVersion
    public let type: BLEMessageType
    public let flags: UInt8
    public let sequence: UInt32
    public let payload: Data

    public init(
        version: BLEProtocolVersion = .current,
        type: BLEMessageType,
        flags: UInt8 = 0,
        sequence: UInt32,
        payload: Data
    ) {
        self.version = version
        self.type = type
        self.flags = flags
        self.sequence = sequence
        self.payload = payload
    }
}

public enum BLECodecError: Error, Equatable, Sendable {
    case frameTooLarge(Int)
    case truncated
    case invalidMagic
    case incompatibleMajorVersion(UInt8)
    case unknownMessageType(UInt8)
    case unsupportedFlags(UInt8)
    case payloadLengthMismatch(expected: Int, actual: Int)
    case crcMismatch
    case invalidUTF8
    case stringTooLong(maximum: Int, actual: Int)
    case numericOverflow
    case trailingBytes(Int)
}
