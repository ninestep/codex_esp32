import Foundation

public enum BLELogicalChannel: UInt8, Hashable, Sendable {
    case controlToHost
    case controlToDevice
    case stateToDevice
    case audioToHost
    case assetToDevice
    case deviceInfo
}

public struct BLETransportPacket: Equatable, Sendable {
    public let channel: BLELogicalChannel
    public let bytes: Data

    public init(channel: BLELogicalChannel, bytes: Data) {
        self.channel = channel
        self.bytes = bytes
    }
}

public struct SimulatedKeyExecution: Equatable, Sendable {
    public let requestID: UInt32
    public let sessionKey: UInt16
    public let key: RemoteTerminalKey

    public init(requestID: UInt32, sessionKey: UInt16, key: RemoteTerminalKey) {
        self.requestID = requestID
        self.sessionKey = sessionKey
        self.key = key
    }
}

public struct SimulatedScrollExecution: Equatable, Sendable {
    public let sessionKey: UInt16
    public let delta: Int16
    public let sequence: UInt32

    public init(sessionKey: UInt16, delta: Int16, sequence: UInt32) {
        self.sessionKey = sessionKey
        self.delta = delta
        self.sequence = sequence
    }
}

public struct SimulatedRemoteDevice: Sendable {
    public private(set) var sessions: [UInt16: DeviceSession] = [:]
    public private(set) var selectedSessionKey: UInt16?
    public private(set) var keyExecutions: [SimulatedKeyExecution] = []
    public private(set) var scrollExecutions: [SimulatedScrollExecution] = []
    public private(set) var audioReceivedSequences: [UInt32] = []
    public private(set) var audioDroppedFrameCount = 0
    public private(set) var isRecording = false

    public var activeAssetSet: ActiveAssetSet? {
        assetTransfer.activeSet
    }

    private let maximumPacketBytes: Int
    private let deviceInformation: DeviceInformation
    private let messageCodec = BLEMessageCodec()
    private let fragmentCodec = BLEFragmentCodec()
    private var reassemblers: [BLELogicalChannel: BLEFragmentReassembler] = [:]
    private var generation: UInt32?
    private var lastDeltaSequence: UInt32 = 0
    private var lastScrollSequence: [UInt16: UInt32] = [:]
    private var cachedResults: [UInt32: BLEMessage] = [:]
    private var expectedAudioSequence: UInt32?
    private var assetTransfer = AssetTransferState()
    private var nextOutboundSequence: UInt32 = 1
    private var nextOutboundMessageID: UInt32 = 1

    public init(maximumPacketBytes: Int, deviceInformation: DeviceInformation) {
        self.maximumPacketBytes = maximumPacketBytes
        self.deviceInformation = deviceInformation
    }

    public mutating func connect() throws -> [BLETransportPacket] {
        try makePackets(.deviceInfo(deviceInformation), channel: .deviceInfo)
    }

    public mutating func disconnect() {
        reassemblers.removeAll()
        sessions.removeAll()
        selectedSessionKey = nil
        generation = nil
        lastDeltaSequence = 0
        lastScrollSequence.removeAll()
        cachedResults.removeAll()
        expectedAudioSequence = nil
        isRecording = false
        audioReceivedSequences.removeAll()
        audioDroppedFrameCount = 0
        assetTransfer.cancelPending()
    }

    public mutating func receive(_ packet: BLETransportPacket) throws -> [BLETransportPacket] {
        var reassembler = reassemblers[packet.channel] ?? BLEFragmentReassembler()
        let result: BLEReassemblyResult
        do {
            result = try reassembler.accept(packet.bytes)
        } catch {
            reassemblers[packet.channel] = reassembler
            return try makePackets(.resyncRequired(reason: .malformedFragment), channel: .controlToDevice)
        }
        reassemblers[packet.channel] = reassembler

        guard case let .complete(data) = result else {
            return []
        }
        let decoded = try messageCodec.decode(data)
        return try apply(decoded.message)
    }

    private mutating func apply(_ message: BLEMessage) throws -> [BLETransportPacket] {
        switch message {
        case let .stateSnapshot(newGeneration, newSessions):
            generation = newGeneration
            lastDeltaSequence = 0
            sessions = Dictionary(uniqueKeysWithValues: newSessions.map { ($0.sessionKey, $0) })
            if let selectedSessionKey, sessions[selectedSessionKey] == nil {
                self.selectedSessionKey = nil
                stopRecording()
            }
            return []

        case let .stateDelta(incomingGeneration, sequence, session):
            guard let generation else {
                return try makePackets(.resyncRequired(reason: .connectionReset), channel: .controlToDevice)
            }
            guard incomingGeneration == generation else {
                return try makePackets(.resyncRequired(reason: .staleGeneration), channel: .controlToDevice)
            }
            guard sequence == lastDeltaSequence + 1 else {
                return try makePackets(.resyncRequired(reason: .sequenceGap), channel: .controlToDevice)
            }
            sessions[session.sessionKey] = session
            lastDeltaSequence = sequence
            return []

        case let .selectSession(requestID, sessionKey):
            if let cached = cachedResults[requestID] {
                return try makePackets(cached, channel: .controlToDevice)
            }
            let response: BLEMessage
            if sessions[sessionKey] != nil {
                selectedSessionKey = sessionKey
                response = .actionResult(requestID: requestID, result: .success, detail: "会话已选择")
            } else {
                response = .actionResult(requestID: requestID, result: .unavailable, detail: "会话不可用")
            }
            cachedResults[requestID] = response
            return try makePackets(response, channel: .controlToDevice)

        case let .scroll(sessionKey, delta, sequence):
            guard sessions[sessionKey] != nil, selectedSessionKey == sessionKey else { return [] }
            let previous = lastScrollSequence[sessionKey] ?? 0
            guard sequence > previous else { return [] }
            lastScrollSequence[sessionKey] = sequence
            scrollExecutions.append(SimulatedScrollExecution(sessionKey: sessionKey, delta: delta, sequence: sequence))
            return []

        case let .terminalKey(requestID, sessionKey, key):
            if let cached = cachedResults[requestID] {
                return try makePackets(cached, channel: .controlToDevice)
            }
            let response: BLEMessage
            if sessions[sessionKey] != nil, selectedSessionKey == sessionKey, !isRecording {
                keyExecutions.append(SimulatedKeyExecution(requestID: requestID, sessionKey: sessionKey, key: key))
                response = .actionResult(requestID: requestID, result: .success, detail: "按键已发送")
            } else {
                response = .actionResult(requestID: requestID, result: .invalidState, detail: "会话未激活")
            }
            cachedResults[requestID] = response
            return try makePackets(response, channel: .controlToDevice)

        case let .pttBegin(requestID, sessionKey, firstAudioSequence):
            if let cached = cachedResults[requestID] {
                return try makePackets(cached, channel: .controlToDevice)
            }
            let response: BLEMessage
            if sessions[sessionKey] != nil, selectedSessionKey == sessionKey, !isRecording {
                isRecording = true
                expectedAudioSequence = firstAudioSequence
                audioReceivedSequences.removeAll()
                audioDroppedFrameCount = 0
                response = .actionResult(requestID: requestID, result: .success, detail: "PTT 已就绪")
            } else {
                response = .actionResult(requestID: requestID, result: .invalidState, detail: "请先进入会话")
            }
            cachedResults[requestID] = response
            return try makePackets(response, channel: .controlToDevice)

        case let .audioFrame(frame):
            guard isRecording, let expectedAudioSequence else { return [] }
            guard frame.sequence >= expectedAudioSequence else { return [] }
            audioDroppedFrameCount += Int(frame.sequence - expectedAudioSequence)
            audioReceivedSequences.append(frame.sequence)
            self.expectedAudioSequence = frame.sequence + 1
            return []

        case let .pttEnd(requestID, sessionKey, _):
            if let cached = cachedResults[requestID] {
                return try makePackets(cached, channel: .controlToDevice)
            }
            let response: BLEMessage
            if isRecording, selectedSessionKey == sessionKey {
                stopRecording()
                response = .actionResult(requestID: requestID, result: .success, detail: "PTT 已结束")
            } else {
                response = .actionResult(requestID: requestID, result: .invalidState, detail: "PTT 未开始")
            }
            cachedResults[requestID] = response
            return try makePackets(response, channel: .controlToDevice)

        case let .assetManifest(manifest):
            try assetTransfer.begin(manifest)
            return try makePackets(
                .assetAcknowledgement(setID: manifest.setID, assetID: 0, nextOffset: 0, result: .accepted),
                channel: .controlToHost
            )

        case let .assetChunk(chunk):
            let nextOffset = try assetTransfer.receive(chunk)
            let result: AssetAckResult
            do {
                _ = try assetTransfer.finalize()
                result = .complete
            } catch AssetTransferError.incompleteAsset {
                result = .accepted
            }
            return try makePackets(
                .assetAcknowledgement(setID: chunk.setID, assetID: chunk.assetID, nextOffset: nextOffset, result: result),
                channel: .controlToHost
            )

        case .actionResult, .assetAcknowledgement, .deviceInfo, .resyncRequired:
            return []
        }
    }

    private mutating func stopRecording() {
        isRecording = false
        expectedAudioSequence = nil
    }

    private mutating func makePackets(
        _ message: BLEMessage,
        channel: BLELogicalChannel
    ) throws -> [BLETransportPacket] {
        let encoded = try messageCodec.encode(message, sequence: nextOutboundSequence)
        let fragments = try fragmentCodec.fragment(
            encoded,
            messageID: nextOutboundMessageID,
            maximumPacketBytes: maximumPacketBytes
        )
        nextOutboundSequence &+= 1
        nextOutboundMessageID &+= 1
        return fragments.map { BLETransportPacket(channel: channel, bytes: $0) }
    }
}
