import CodexRemoteCore
import Foundation

public protocol SessionClient: Sendable {
    func activeSessions(limit: Int) async -> [RemoteSession]
    func selectSession(remoteSessionID: String) async throws -> RemoteSession
    func sendKey(_ key: TerminalKey, remoteSessionID: String) async throws
    func sendShortcut(_ shortcut: TerminalShortcut, remoteSessionID: String) async throws
    func scroll(deltaY: Int, remoteSessionID: String) async throws
}

extension SessionService: SessionClient {}

@MainActor
public final class MacClientCoordinator {
    public private(set) var deviceInformation: DeviceInformation?
    public private(set) var selectedSessionKey: UInt16?
    public var onSnapshotChange: ((ClientSnapshot) -> Void)?

    private let sessionClient: any SessionClient
    private let transport: any BluetoothTransport
    private let audioInput: (any AudioInputHandling)?
    private let messageCodec = BLEMessageCodec()
    private let fragmentCodec = BLEFragmentCodec()
    private var syncReducer = DeviceSyncReducer()
    private var reassemblers: [BLELogicalChannel: BLEFragmentReassembler] = [:]
    private var cachedResults: [UInt32: BLEMessage] = [:]
    private var cachedRequestOrder: [UInt32] = []
    private var lastScrollSequenceBySession: [UInt16: UInt32] = [:]
    private var nextEnvelopeSequence: UInt32 = 1
    private var nextMessageID: UInt32 = 1
    private var currentSessions: [RemoteSession] = []
    private var activePTTSessionKey: UInt16?

    public init(
        sessionClient: any SessionClient,
        transport: any BluetoothTransport,
        audioInput: (any AudioInputHandling)? = nil
    ) {
        self.sessionClient = sessionClient
        self.transport = transport
        self.audioInput = audioInput

        transport.onStateChange = { [weak self] state in
            self?.handleTransportState(state)
        }
        transport.onPacket = { [weak self] packet in
            guard let self else { return }
            Task { @MainActor in
                try? await self.receive(packet: packet)
            }
        }
    }

    public convenience init(
        sessionService: SessionService = SessionService(),
        transport: any BluetoothTransport = CoreBluetoothTransport(),
        audioInput: (any AudioInputHandling)? = nil
    ) {
        self.init(sessionClient: sessionService, transport: transport, audioInput: audioInput)
    }

    public func start() {
        transport.start()
    }

    public func stop() {
        transport.stop()
        resetConnection()
    }

    public func refreshSessions() async throws {
        let sessions = await sessionClient.activeSessions(limit: 8)
        currentSessions = sessions
        try send(syncReducer.updateSessions(sessions))
        publishSnapshot()
    }

    public func receive(packet: BLETransportPacket) async throws {
        guard [.controlToHost, .deviceInfo, .audioToHost].contains(packet.channel) else {
            return
        }

        var reassembler = reassemblers[packet.channel, default: BLEFragmentReassembler()]
        do {
            let result = try reassembler.accept(packet.bytes)
            reassemblers[packet.channel] = reassembler
            guard case let .complete(data) = result else { return }
            try await receive(message: messageCodec.decode(data).message)
        } catch {
            reassemblers[packet.channel] = BLEFragmentReassembler()
            try send(.resyncRequired(reason: .malformedFragment))
            throw error
        }
    }

    public func receive(message: BLEMessage) async throws {
        switch message {
        case let .deviceInfo(info):
            deviceInformation = info
            let sessions = await sessionClient.activeSessions(limit: 8)
            currentSessions = sessions
            _ = syncReducer.updateSessions(sessions)
            try send(syncReducer.connect(remoteVersion: .current))
            publishSnapshot()

        case let .selectSession(requestID, sessionKey):
            try await handleRequest(requestID: requestID) {
                guard let remoteSessionID = self.syncReducer.remoteSessionID(for: sessionKey) else {
                    return .actionResult(requestID: requestID, result: .unavailable, detail: "会话不存在")
                }
                do {
                    _ = try await self.sessionClient.selectSession(remoteSessionID: remoteSessionID)
                    self.selectedSessionKey = sessionKey
                    try await self.refreshSessions()
                    self.publishSnapshot()
                    return .actionResult(requestID: requestID, result: .success, detail: "")
                } catch {
                    return .actionResult(requestID: requestID, result: .unavailable, detail: "无法切换会话")
                }
            }

        case let .terminalKey(requestID, sessionKey, remoteKey):
            try await handleRequest(requestID: requestID) {
                guard self.selectedSessionKey == sessionKey,
                      let remoteSessionID = self.syncReducer.remoteSessionID(for: sessionKey) else {
                    return .actionResult(requestID: requestID, result: .invalidState, detail: "请先进入会话")
                }
                let key: TerminalKey = switch remoteKey {
                case .enter: .enter
                case .escape: .escape
                case .up: .up
                case .down: .down
                case .left: .left
                case .right: .right
                case .backspace: .backspace
                case .clearLine: .clearLine
                }
                do {
                    try await self.sessionClient.sendKey(key, remoteSessionID: remoteSessionID)
                    return .actionResult(requestID: requestID, result: .success, detail: "")
                } catch {
                    return .actionResult(requestID: requestID, result: .unavailable, detail: "按键发送失败")
                }
            }

        case let .terminalShortcut(requestID, sessionKey, remoteShortcut):
            try await handleRequest(requestID: requestID) {
                guard self.selectedSessionKey == sessionKey,
                      let remoteSessionID = self.syncReducer.remoteSessionID(for: sessionKey) else {
                    return .actionResult(requestID: requestID, result: .invalidState, detail: "请先进入会话")
                }
                let shortcut: TerminalShortcut = switch remoteShortcut {
                case .newSession: .newSession
                case .quit: .quit
                case .write: .write
                case .plan: .plan
                case .compact: .compact
                }
                do {
                    try await self.sessionClient.sendShortcut(shortcut, remoteSessionID: remoteSessionID)
                    return .actionResult(requestID: requestID, result: .success, detail: "")
                } catch {
                    return .actionResult(requestID: requestID, result: .unavailable, detail: "快捷键发送失败")
                }
            }

        case let .scroll(sessionKey, delta, sequence):
            guard selectedSessionKey == sessionKey,
                  let remoteSessionID = syncReducer.remoteSessionID(for: sessionKey),
                  sequence > lastScrollSequenceBySession[sessionKey, default: 0] else {
                return
            }
            lastScrollSequenceBySession[sessionKey] = sequence
            try await sessionClient.scroll(deltaY: Int(delta), remoteSessionID: remoteSessionID)

        case let .pttBegin(requestID, sessionKey, firstAudioSequence):
            try await handleRequest(requestID: requestID) {
                guard self.selectedSessionKey == sessionKey else {
                    return .actionResult(requestID: requestID, result: .invalidState, detail: "请先进入会话")
                }
                guard let audioInput = self.audioInput else {
                    return .actionResult(requestID: requestID, result: .unavailable, detail: "语音链路不可用")
                }
                do {
                    try audioInput.begin(firstAudioSequence: firstAudioSequence)
                    self.activePTTSessionKey = sessionKey
                    return .actionResult(requestID: requestID, result: .success, detail: "PTT 已就绪")
                } catch {
                    return .actionResult(
                        requestID: requestID,
                        result: .unavailable,
                        detail: self.audioErrorDetail(error)
                    )
                }
            }

        case let .audioFrame(frame):
            guard activePTTSessionKey != nil, let audioInput else { return }
            do {
                try audioInput.receive(frame)
            } catch {
                audioInput.abort()
                activePTTSessionKey = nil
            }

        case let .pttEnd(requestID, sessionKey, lastAudioSequence):
            try await handleRequest(requestID: requestID) {
                guard self.activePTTSessionKey == sessionKey, let audioInput = self.audioInput else {
                    return .actionResult(requestID: requestID, result: .invalidState, detail: "PTT 未开始")
                }
                do {
                    try await audioInput.end(lastAudioSequence: lastAudioSequence)
                    self.activePTTSessionKey = nil
                    return .actionResult(requestID: requestID, result: .success, detail: "PTT 已结束")
                } catch {
                    audioInput.abort()
                    self.activePTTSessionKey = nil
                    return .actionResult(requestID: requestID, result: .unavailable, detail: "语音结束失败")
                }
            }

        case .resyncRequired:
            try send(syncReducer.resync())

        case .actionResult, .stateSnapshot, .stateDelta,
             .assetManifest, .assetChunk, .assetAcknowledgement:
            break
        }
    }

    private func handleTransportState(_ state: BluetoothTransportState) {
        switch state {
        case .ready:
            publishSnapshot()
        case .disconnected, .unavailable, .scanning, .connecting, .discoveringService,
             .discoveringCharacteristics, .subscribingNotifications:
            resetConnection()
        }
    }

    private func resetConnection() {
        if activePTTSessionKey != nil {
            audioInput?.abort()
        }
        activePTTSessionKey = nil
        syncReducer.disconnect()
        deviceInformation = nil
        selectedSessionKey = nil
        reassemblers.removeAll()
        cachedResults.removeAll()
        cachedRequestOrder.removeAll()
        lastScrollSequenceBySession.removeAll()
        publishSnapshot()
    }

    private func audioErrorDetail(_ error: Error) -> String {
        switch error as? AudioInputBridgeError {
        case .dependencyMissing: "未检测到 BlackHole 2ch"
        case .hotkeyNotConfigured: "请先设置豆包语音快捷键"
        case .accessibilityNotGranted: "请授予辅助功能权限"
        case .alreadyActive: "PTT 已在录音"
        case .notActive, .invalidSequence, .audioSystemFailure, .none: "语音链路启动失败"
        }
    }

    private func publishSnapshot() {
        onSnapshotChange?(ClientSnapshot(
            transportState: transport.state,
            sessions: currentSessions,
            deviceInformation: deviceInformation,
            selectedSessionKey: selectedSessionKey
        ))
    }

    private func handleRequest(
        requestID: UInt32,
        operation: () async -> BLEMessage
    ) async throws {
        if let cached = cachedResults[requestID] {
            try send(cached)
            return
        }

        let result = await operation()
        cachedResults[requestID] = result
        cachedRequestOrder.append(requestID)
        if cachedRequestOrder.count > 128 {
            cachedResults.removeValue(forKey: cachedRequestOrder.removeFirst())
        }
        try send(result)
    }

    private func send(_ messages: [BLEMessage]) throws {
        for message in messages {
            try send(message)
        }
    }

    private func send(_ message: BLEMessage) throws {
        let channel = try outboundChannel(for: message)
        let encoded = try messageCodec.encode(message, sequence: nextEnvelopeSequence)
        nextEnvelopeSequence &+= 1
        let packets = try fragmentCodec.fragment(
            encoded,
            messageID: nextMessageID,
            maximumPacketBytes: transport.maximumWriteValueLength
        )
        nextMessageID &+= 1
        for bytes in packets {
            try transport.send(BLETransportPacket(channel: channel, bytes: bytes), mode: .withResponse)
        }
    }

    private func outboundChannel(for message: BLEMessage) throws -> BLELogicalChannel {
        switch message {
        case .stateSnapshot, .stateDelta:
            return .stateToDevice
        case .actionResult, .resyncRequired:
            return .controlToDevice
        case .assetManifest, .assetChunk:
            return .assetToDevice
        default:
            throw BluetoothTransportError.unsupportedChannel(.controlToDevice)
        }
    }
}
