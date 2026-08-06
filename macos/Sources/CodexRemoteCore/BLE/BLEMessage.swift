import Foundation

public enum RemoteTerminalKey: UInt8, Equatable, Sendable {
    case enter = 1
    case escape = 2
    case up = 3
    case down = 4
    case left = 5
    case right = 6
    case backspace = 7
    case clearLine = 8
}

public enum RemoteTerminalShortcut: UInt8, Equatable, Sendable {
    case newSession = 1
    case quit = 2
    case write = 3
    case plan = 4
    case compact = 5
}

public enum RemoteActionResult: UInt8, Equatable, Sendable {
    case success = 0
    case unavailable = 1
    case invalidState = 2
    case rejected = 3
    case protocolError = 4
}

public enum DeviceSessionState: UInt8, Equatable, Sendable {
    case idle = 0
    case working = 1
    case completeUnread = 2
    case requiresInput = 3
    case error = 4
    case offline = 5
}

public struct DeviceSessionCapabilities: OptionSet, Equatable, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let scroll = Self(rawValue: 1 << 0)
    public static let terminalKeys = Self(rawValue: 1 << 1)
    public static let ptt = Self(rawValue: 1 << 2)
    public static let navigationKeys = Self(rawValue: 1 << 3)
    public static let terminalShortcuts = Self(rawValue: 1 << 4)
}

public struct DeviceSession: Equatable, Sendable {
    public let sessionKey: UInt16
    public let displayTitle: String
    public let workingDirectoryLabel: String
    public let state: DeviceSessionState
    public let statusDetail: String
    public let unread: Bool
    public let capabilities: DeviceSessionCapabilities
    public let updatedAtMilliseconds: UInt64

    public init(
        sessionKey: UInt16,
        displayTitle: String,
        workingDirectoryLabel: String,
        state: DeviceSessionState,
        statusDetail: String,
        unread: Bool,
        capabilities: DeviceSessionCapabilities,
        updatedAtMilliseconds: UInt64
    ) {
        self.sessionKey = sessionKey
        self.displayTitle = displayTitle
        self.workingDirectoryLabel = workingDirectoryLabel
        self.state = state
        self.statusDetail = statusDetail
        self.unread = unread
        self.capabilities = capabilities
        self.updatedAtMilliseconds = updatedAtMilliseconds
    }

    public init(
        remoteSession: RemoteSession,
        sessionKey: UInt16,
        capabilities: DeviceSessionCapabilities
    ) {
        self.init(
            sessionKey: sessionKey,
            displayTitle: remoteSession.displayTitle,
            workingDirectoryLabel: remoteSession.workingDirectoryLabel,
            state: DeviceSessionState(remoteState: remoteSession.state),
            statusDetail: remoteSession.statusDetail,
            unread: remoteSession.unread,
            capabilities: capabilities,
            updatedAtMilliseconds: UInt64(max(0, remoteSession.updatedAt.timeIntervalSince1970 * 1_000))
        )
    }
}

private extension DeviceSessionState {
    init(remoteState: RemoteSessionState) {
        switch remoteState {
        case .idle: self = .idle
        case .working: self = .working
        case .completeUnread: self = .completeUnread
        case .requiresInput: self = .requiresInput
        case .error: self = .error
        case .offline: self = .offline
        }
    }
}

public struct ADPCMFrame: Equatable, Sendable {
    public let sequence: UInt32
    public let sampleTimestamp: UInt64
    public let predictor: Int16
    public let stepIndex: UInt8
    public let sampleCount: UInt16
    public let encodedSamples: Data

    public init(
        sequence: UInt32,
        sampleTimestamp: UInt64,
        predictor: Int16,
        stepIndex: UInt8,
        sampleCount: UInt16,
        encodedSamples: Data
    ) {
        self.sequence = sequence
        self.sampleTimestamp = sampleTimestamp
        self.predictor = predictor
        self.stepIndex = stepIndex
        self.sampleCount = sampleCount
        self.encodedSamples = encodedSamples
    }
}

public struct AssetItemDescriptor: Equatable, Sendable {
    public let assetID: UInt16
    public let width: UInt16
    public let height: UInt16
    public let byteCount: UInt32
    public let crc32: UInt32

    public init(assetID: UInt16, width: UInt16, height: UInt16, byteCount: UInt32, crc32: UInt32) {
        self.assetID = assetID
        self.width = width
        self.height = height
        self.byteCount = byteCount
        self.crc32 = crc32
    }
}

public struct AssetManifest: Equatable, Sendable {
    public let setID: UInt32
    public let totalBytes: UInt32
    public let items: [AssetItemDescriptor]

    public init(setID: UInt32, totalBytes: UInt32, items: [AssetItemDescriptor]) {
        self.setID = setID
        self.totalBytes = totalBytes
        self.items = items
    }
}

public struct AssetChunk: Equatable, Sendable {
    public let setID: UInt32
    public let assetID: UInt16
    public let offset: UInt32
    public let bytes: Data

    public init(setID: UInt32, assetID: UInt16, offset: UInt32, bytes: Data) {
        self.setID = setID
        self.assetID = assetID
        self.offset = offset
        self.bytes = bytes
    }
}

public enum AssetAckResult: UInt8, Equatable, Sendable {
    case accepted = 0
    case retryFromOffset = 1
    case rejected = 2
    case complete = 3
}

public struct DeviceFeatureCapabilities: OptionSet, Equatable, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let display = Self(rawValue: 1 << 0)
    public static let microphone = Self(rawValue: 1 << 1)
    public static let touch = Self(rawValue: 1 << 2)
    public static let userButton = Self(rawValue: 1 << 3)
    public static let assetStorage = Self(rawValue: 1 << 4)
}

public struct DeviceInformation: Equatable, Sendable {
    public let firmwareVersion: String
    public let capabilities: DeviceFeatureCapabilities
    public let batteryPercent: UInt8

    public init(firmwareVersion: String, capabilities: DeviceFeatureCapabilities, batteryPercent: UInt8) {
        self.firmwareVersion = firmwareVersion
        self.capabilities = capabilities
        self.batteryPercent = batteryPercent
    }
}

public enum ResyncReason: UInt8, Equatable, Sendable {
    case connectionReset = 1
    case sequenceGap = 2
    case malformedFragment = 3
    case staleGeneration = 4
}

public enum BLEMessage: Equatable, Sendable {
    case selectSession(requestID: UInt32, sessionKey: UInt16)
    case scroll(sessionKey: UInt16, delta: Int16, sequence: UInt32)
    case terminalKey(requestID: UInt32, sessionKey: UInt16, key: RemoteTerminalKey)
    case pttBegin(requestID: UInt32, sessionKey: UInt16, firstAudioSequence: UInt32)
    case pttEnd(requestID: UInt32, sessionKey: UInt16, lastAudioSequence: UInt32)
    case actionResult(requestID: UInt32, result: RemoteActionResult, detail: String)
    case stateSnapshot(generation: UInt32, sessions: [DeviceSession])
    case stateDelta(generation: UInt32, sequence: UInt32, session: DeviceSession)
    case audioFrame(ADPCMFrame)
    case assetManifest(AssetManifest)
    case assetChunk(AssetChunk)
    case assetAcknowledgement(setID: UInt32, assetID: UInt16, nextOffset: UInt32, result: AssetAckResult)
    case deviceInfo(DeviceInformation)
    case resyncRequired(reason: ResyncReason)
    case terminalShortcut(requestID: UInt32, sessionKey: UInt16, shortcut: RemoteTerminalShortcut)
}

public struct BLEDecodedMessage: Equatable, Sendable {
    public let sequence: UInt32
    public let message: BLEMessage

    public init(sequence: UInt32, message: BLEMessage) {
        self.sequence = sequence
        self.message = message
    }
}

public enum BLEMessageCodecError: Error, Equatable, Sendable {
    case tooManySessions(Int)
    case tooManyAssets(Int)
    case unknownEnum(field: String, rawValue: UInt8)
    case invalidBoolean(UInt8)
    case invalidAudioSampleCount(UInt16)
    case invalidAudioByteCount(Int)
    case invalidStepIndex(UInt8)
    case invalidBatteryPercent(UInt8)
    case invalidAssetManifest
    case chunkTooLarge(Int)
}
