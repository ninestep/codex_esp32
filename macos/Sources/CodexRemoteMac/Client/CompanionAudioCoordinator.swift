import CodexRemoteCore
import Foundation
import OSLog

public enum CompanionSpeechState: Equatable, Sendable {
    case idle
    case recording
    case processing
    case failed(String)
}

public struct CompanionAudioSnapshot: Equatable, Sendable {
    public let transportState: BluetoothTransportState
    public let deviceInformation: DeviceInformation?
    public let speechState: CompanionSpeechState

    public init(
        transportState: BluetoothTransportState,
        deviceInformation: DeviceInformation?,
        speechState: CompanionSpeechState
    ) {
        self.transportState = transportState
        self.deviceInformation = deviceInformation
        self.speechState = speechState
    }
}

struct CompanionAudioDiagnostics: Equatable, Sendable {
    var fragmentCount = 0
    var byteCount = 0
    var decodedFrameCount = 0
    var firstFrameSequence: UInt32?
    var lastFrameSequence: UInt32?
    var packetErrorCount = 0

    mutating func recordFragment(byteCount: Int) {
        fragmentCount += 1
        self.byteCount += byteCount
    }

    mutating func recordFrame(sequence: UInt32) {
        decodedFrameCount += 1
        if firstFrameSequence == nil { firstFrameSequence = sequence }
        lastFrameSequence = sequence
    }
}

@MainActor
public final class CompanionAudioCoordinator {
    private static let logger = Logger(subsystem: "CodexRemote", category: "CompanionAudioCoordinator")

    public var onSnapshotChange: ((CompanionAudioSnapshot) -> Void)?
    public private(set) var deviceInformation: DeviceInformation?
    public private(set) var speechState: CompanionSpeechState = .idle
    private(set) var diagnostics = CompanionAudioDiagnostics()

    private let transport: any BluetoothTransport
    private let audioInput: any AudioInputHandling
    private let layoutReader: any CodexMicroLayoutReading
    private let messageCodec = BLEMessageCodec()
    private let fragmentCodec = BLEFragmentCodec()
    private var reassemblers: [BLELogicalChannel: BLEFragmentReassembler] = [:]
    private var cachedResults: [UInt32: BLEMessage] = [:]
    private var cachedRequestOrder: [UInt32] = []
    private var activePTTSessionKey: UInt16?
    private var nextEnvelopeSequence: UInt32 = 1
    private var nextMessageID: UInt32 = 1

    public init(
        transport: any BluetoothTransport = CoreBluetoothTransport(),
        audioInput: any AudioInputHandling,
        layoutReader: any CodexMicroLayoutReading = CodexMicroLayoutReader()
    ) {
        self.transport = transport
        self.audioInput = audioInput
        self.layoutReader = layoutReader
        transport.onStateChange = { [weak self] state in
            self?.handleTransportState(state)
        }
        transport.onPacket = { [weak self] packet in
            guard let self else { return }
            Task { @MainActor in
                do {
                    try await self.receive(packet: packet)
                } catch {
                    Self.logger.error("Companion BLE packet failed channel=\(String(describing: packet.channel), privacy: .public) error=\(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    public func start() {
        transport.start()
        publishSnapshot()
    }

    public func stop() {
        transport.stop()
        resetConnection()
    }

    public func receive(packet: BLETransportPacket) async throws {
        guard [.controlToHost, .deviceInfo, .audioToHost].contains(packet.channel) else { return }
        if packet.channel == .audioToHost {
            diagnostics.recordFragment(byteCount: packet.bytes.count)
        }
        var reassembler = reassemblers[packet.channel, default: BLEFragmentReassembler()]
        do {
            let result = try reassembler.accept(packet.bytes)
            reassemblers[packet.channel] = reassembler
            guard case .complete(let data) = result else { return }
            try await receive(message: messageCodec.decode(data).message)
        } catch {
            reassemblers[packet.channel] = BLEFragmentReassembler()
            if packet.channel == .audioToHost { diagnostics.packetErrorCount += 1 }
            try send(.resyncRequired(reason: .malformedFragment))
            throw error
        }
    }

    public func receive(message: BLEMessage) async throws {
        switch message {
        case .deviceInfo(let information):
            deviceInformation = information
            publishSnapshot()
            do {
                let layout = try layoutReader.read()
                try send(.microControlLayout(layout.companionLayout))
                Self.logger.info("Codex Micro control layout sent to device")
            } catch {
                Self.logger.error("Codex Micro control layout unavailable error=\(String(describing: error), privacy: .public)")
            }

        case let .pttBegin(requestID, sessionKey, firstAudioSequence):
            try await handleRequest(requestID: requestID) {
                guard self.activePTTSessionKey == nil else {
                    return .actionResult(requestID: requestID, result: .invalidState, detail: "PTT 已在录音")
                }
                do {
                    self.diagnostics = CompanionAudioDiagnostics()
                    try self.audioInput.begin(firstAudioSequence: firstAudioSequence)
                    self.activePTTSessionKey = sessionKey
                    self.speechState = .recording
                    self.publishSnapshot()
                    return .actionResult(requestID: requestID, result: .success, detail: "PTT 已就绪")
                } catch {
                    let detail = self.audioErrorDetail(error)
                    self.speechState = .failed(detail)
                    self.publishSnapshot()
                    return .actionResult(requestID: requestID, result: .unavailable, detail: detail)
                }
            }

        case .audioFrame(let frame):
            diagnostics.recordFrame(sequence: frame.sequence)
            guard activePTTSessionKey != nil else {
                Self.logger.warning("Ignoring audio frame without active PTT sequence=\(frame.sequence)")
                return
            }
            do {
                try audioInput.receive(frame)
            } catch {
                audioInput.abort()
                activePTTSessionKey = nil
                let detail = audioErrorDetail(error)
                speechState = .failed(detail)
                publishSnapshot()
            }

        case let .pttEnd(requestID, sessionKey, lastAudioSequence):
            try await handleRequest(requestID: requestID) {
                guard self.activePTTSessionKey == sessionKey else {
                    return .actionResult(requestID: requestID, result: .invalidState, detail: "PTT 未开始")
                }
                self.speechState = .processing
                self.publishSnapshot()
                do {
                    try await self.audioInput.end(lastAudioSequence: lastAudioSequence)
                    self.activePTTSessionKey = nil
                    self.speechState = .idle
                    self.publishSnapshot()
                    self.logDiagnostics(deviceLastSequence: lastAudioSequence)
                    return .actionResult(requestID: requestID, result: .success, detail: "PTT 已结束")
                } catch {
                    self.audioInput.abort()
                    self.activePTTSessionKey = nil
                    let detail = self.audioErrorDetail(error)
                    self.speechState = .failed(detail)
                    self.publishSnapshot()
                    return .actionResult(requestID: requestID, result: .unavailable, detail: detail)
                }
            }

        case .resyncRequired:
            reassemblers.removeAll()

        case .selectSession, .scroll, .terminalKey, .terminalShortcut,
             .actionResult, .stateSnapshot, .stateDelta,
             .assetManifest, .assetChunk, .assetAcknowledgement,
             .microControlLayout:
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
        if activePTTSessionKey != nil { audioInput.abort() }
        activePTTSessionKey = nil
        deviceInformation = nil
        speechState = .idle
        diagnostics = CompanionAudioDiagnostics()
        reassemblers.removeAll()
        cachedResults.removeAll()
        cachedRequestOrder.removeAll()
        publishSnapshot()
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

    private func send(_ message: BLEMessage) throws {
        let encoded = try messageCodec.encode(message, sequence: nextEnvelopeSequence)
        nextEnvelopeSequence &+= 1
        let packets = try fragmentCodec.fragment(
            encoded,
            messageID: nextMessageID,
            maximumPacketBytes: transport.maximumWriteValueLength
        )
        nextMessageID &+= 1
        for bytes in packets {
            try transport.send(
                BLETransportPacket(channel: .controlToDevice, bytes: bytes),
                mode: .withResponse
            )
        }
    }

    private func publishSnapshot() {
        onSnapshotChange?(CompanionAudioSnapshot(
            transportState: transport.state,
            deviceInformation: deviceInformation,
            speechState: speechState
        ))
    }

    private func audioErrorDetail(_ error: Error) -> String {
        switch error as? AudioInputBridgeError {
        case .accessibilityNotGranted: "请授予辅助功能权限"
        case .alreadyActive: "PTT 已在录音"
        case .dependencyMissing, .hotkeyNotConfigured: "语音识别服务不可用"
        case .notActive, .invalidSequence, .audioSystemFailure, .none: "语音识别失败"
        }
    }

    private func logDiagnostics(deviceLastSequence: UInt32) {
        let detail = "fragments=\(diagnostics.fragmentCount) bytes=\(diagnostics.byteCount) "
            + "frames=\(diagnostics.decodedFrameCount) firstSequence=\(diagnostics.firstFrameSequence ?? 0) "
            + "lastSequence=\(diagnostics.lastFrameSequence ?? 0) "
            + "deviceLastSequence=\(deviceLastSequence) errors=\(diagnostics.packetErrorCount)"
        Self.logger.info("Companion PTT summary \(detail, privacy: .public)")
    }
}
