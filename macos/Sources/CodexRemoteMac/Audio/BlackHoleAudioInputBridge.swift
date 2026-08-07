import AudioToolbox
import AVFoundation
import CodexRemoteCore
import Foundation
import OSLog

struct AudioSignalDiagnostics: Equatable, Sendable {
    var frameCount = 0
    var sampleCount = 0
    var peakMagnitude: Int32 = 0
    var squareSum = 0.0

    var rmsMagnitude: Int32 {
        guard sampleCount > 0 else { return 0 }
        return Int32((squareSum / Double(sampleCount)).squareRoot().rounded())
    }

    mutating func record(_ samples: [Int16]) {
        frameCount += 1
        sampleCount += samples.count
        for sample in samples {
            let value = Int32(sample)
            peakMagnitude = max(peakMagnitude, abs(value))
            squareSum += Double(value) * Double(value)
        }
    }
}

struct BlackHoleOutputGain: Sendable {
    static let multiplier: Int32 = 24

    func apply(to sample: Int16) -> Int16 {
        let amplified = Int32(sample) * Self.multiplier
        if amplified > Int32(Int16.max) { return Int16.max }
        if amplified < Int32(Int16.min) { return Int16.min }
        return Int16(amplified)
    }
}

@MainActor
public final class BlackHoleAudioInputBridge: AudioInputHandling {
    private static let logger = Logger(subsystem: "CodexRemote", category: "BlackHoleAudio")
    public var dependencyStatus: AudioDependencyStatus {
        blackHoleDeviceIDProvider() == nil ? .blackHoleMissing : .ready
    }

    private let catalog: CoreAudioDeviceCatalog
    private let emitter: any HotkeyEmitting
    private let hotkey: ParsedHotkey?
    private let hotkeyMode: HotkeyTriggerMode
    private let blackHoleDeviceIDProvider: () -> AudioDeviceID?
    private let originalInputDeviceIDProvider: () -> AudioDeviceID?
    private let setDefaultInputDeviceIDOperation: ((AudioDeviceID) throws -> Void)?
    private let configureEngineOperation: ((AudioDeviceID) throws -> Void)?
    private let playbackCompletionOperation: (() async -> Void)?
    private let codec = IMAADPCMCodec()
    private let outputGain = BlackHoleOutputGain()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var originalInputDeviceID: AudioDeviceID?
    private var expectedSequence: UInt32?
    private var activeHotkey: ParsedHotkey?
    private var signalDiagnostics = AudioSignalDiagnostics()

    public init(
        hotkeyText: String,
        hotkeyMode: HotkeyTriggerMode,
        catalog: CoreAudioDeviceCatalog = CoreAudioDeviceCatalog(),
        emitter: any HotkeyEmitting = CGEventHotkeyEmitter()
    ) {
        self.catalog = catalog
        self.emitter = emitter
        self.hotkey = HotkeyParser().parse(hotkeyText)
        self.hotkeyMode = hotkeyMode
        self.blackHoleDeviceIDProvider = { catalog.blackHole2ch()?.id }
        self.originalInputDeviceIDProvider = { catalog.defaultInputDeviceID() }
        self.setDefaultInputDeviceIDOperation = nil
        self.configureEngineOperation = nil
        self.playbackCompletionOperation = nil
    }

    init(
        hotkeyText: String,
        hotkeyMode: HotkeyTriggerMode,
        blackHoleDeviceID: AudioDeviceID?,
        originalInputDeviceID: AudioDeviceID?,
        emitter: any HotkeyEmitting,
        setDefaultInputDeviceIDOperation: @escaping (AudioDeviceID) throws -> Void = { _ in },
        configureEngineOperation: @escaping (AudioDeviceID) throws -> Void = { _ in },
        playbackCompletionOperation: @escaping () async -> Void = {}
    ) {
        self.catalog = CoreAudioDeviceCatalog()
        self.emitter = emitter
        self.hotkey = HotkeyParser().parse(hotkeyText)
        self.hotkeyMode = hotkeyMode
        self.blackHoleDeviceIDProvider = { blackHoleDeviceID }
        self.originalInputDeviceIDProvider = { originalInputDeviceID }
        self.setDefaultInputDeviceIDOperation = setDefaultInputDeviceIDOperation
        self.configureEngineOperation = configureEngineOperation
        self.playbackCompletionOperation = playbackCompletionOperation
    }

    public func begin(firstAudioSequence: UInt32) throws {
        guard expectedSequence == nil else { throw AudioInputBridgeError.alreadyActive }
        guard let blackHoleDeviceID = blackHoleDeviceIDProvider() else { throw AudioInputBridgeError.dependencyMissing }
        guard let hotkey else { throw AudioInputBridgeError.hotkeyNotConfigured }
        guard emitter.isAuthorized else { throw AudioInputBridgeError.accessibilityNotGranted }
        guard let originalInput = originalInputDeviceIDProvider() else {
            throw AudioInputBridgeError.audioSystemFailure
        }

        originalInputDeviceID = originalInput
        do {
            if let setDefaultInputDeviceIDOperation {
                try setDefaultInputDeviceIDOperation(blackHoleDeviceID)
            } else {
                try catalog.setDefaultInputDeviceID(blackHoleDeviceID)
            }
            if let configureEngineOperation {
                try configureEngineOperation(blackHoleDeviceID)
            } else {
                try configureEngine(outputDeviceID: blackHoleDeviceID)
            }
            try triggerBegin(hotkey)
            activeHotkey = hotkey
            expectedSequence = firstAudioSequence
            signalDiagnostics = AudioSignalDiagnostics()
        } catch {
            restoreSystemState()
            throw error
        }
    }

    public func receive(_ frame: ADPCMFrame) throws {
        guard let expectedSequence else { throw AudioInputBridgeError.notActive }
        guard frame.sequence >= expectedSequence else { return }
        try restartEngineIfNeeded()
        if frame.sequence > expectedSequence {
            for _ in expectedSequence..<frame.sequence {
                try schedule(samples: Array(repeating: 0, count: IMAADPCMCodec.samplesPerFrame))
            }
        }
        let samples = try codec.decode(frame)
        signalDiagnostics.record(samples)
        try schedule(samples: samples)
        self.expectedSequence = frame.sequence &+ 1
    }

    private func restartEngineIfNeeded() throws {
        guard let engine, let player else { throw AudioInputBridgeError.audioSystemFailure }
        guard !engine.isRunning else { return }
        do {
            try engine.start()
            player.play()
            Self.logger.info("BlackHole audio engine restarted after a configuration change")
        } catch {
            Self.logger.error(
                "Restarting BlackHole audio engine failed: \(error.localizedDescription, privacy: .public)"
            )
            throw AudioInputBridgeError.audioSystemFailure
        }
    }

    public func end(lastAudioSequence: UInt32) async throws {
        guard expectedSequence != nil else { throw AudioInputBridgeError.notActive }
        do {
            if let playbackCompletionOperation {
                await playbackCompletionOperation()
            } else {
                try await playbackCompletion()
            }
            let detail = "frames=\(signalDiagnostics.frameCount) samples=\(signalDiagnostics.sampleCount) "
                + "peak=\(signalDiagnostics.peakMagnitude) rms=\(signalDiagnostics.rmsMagnitude)"
            Self.logger.info("PTT PCM summary \(detail, privacy: .public)")
            if let hotkey = activeHotkey { try triggerEnd(hotkey) }
            restoreSystemState()
            _ = lastAudioSequence
        } catch {
            restoreSystemState()
            throw error
        }
    }

    public func abort() {
        if let hotkey = activeHotkey, hotkeyMode == .hold {
            _ = try? keyUpAfterSuccessfulKeyDown(hotkey)
        }
        restoreSystemState()
    }

    private func configureEngine(outputDeviceID: AudioDeviceID) throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let outputNode = engine.outputNode
        guard let audioUnit = outputNode.audioUnit else {
            Self.logger.error("BlackHole output AudioUnit is unavailable")
            throw AudioInputBridgeError.audioSystemFailure
        }
        var deviceID = outputDeviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            Self.logger.error("Binding AVAudioEngine to BlackHole failed with OSStatus \(status)")
            throw AudioInputBridgeError.audioSystemFailure
        }
        let outputFormat = outputNode.inputFormat(forBus: 0)
        guard outputFormat.sampleRate > 0, outputFormat.channelCount > 0 else {
            Self.logger.error("BlackHole reported an invalid output format")
            throw AudioInputBridgeError.audioSystemFailure
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else { throw AudioInputBridgeError.audioSystemFailure }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.connect(engine.mainMixerNode, to: outputNode, format: outputFormat)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            Self.logger.error("Starting BlackHole audio engine failed: \(error.localizedDescription, privacy: .public)")
            throw AudioInputBridgeError.audioSystemFailure
        }
        player.play()
        self.engine = engine
        self.player = player
    }

    private func schedule(samples: [Int16]) throws {
        guard let player else { throw AudioInputBridgeError.audioSystemFailure }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let target = buffer.floatChannelData?[0] else {
            throw AudioInputBridgeError.audioSystemFailure
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() {
            let amplified = outputGain.apply(to: sample)
            target[index] = Float(amplified) / Float(Int16.max)
        }
        player.scheduleBuffer(buffer)
    }

    private func playbackCompletion() async throws {
        try restartEngineIfNeeded()
        guard let player,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: 16_000,
                  channels: 1,
                  interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)
        else { throw AudioInputBridgeError.audioSystemFailure }
        buffer.frameLength = 1
        await withCheckedContinuation { continuation in
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                continuation.resume()
            }
        }
    }

    private func triggerBegin(_ hotkey: ParsedHotkey) throws {
        switch hotkeyMode {
        case .hold:
            try emitter.keyDown(hotkey)
        case .toggle:
            try emitter.keyDown(hotkey)
            try keyUpAfterSuccessfulKeyDown(hotkey)
        }
    }

    private func triggerEnd(_ hotkey: ParsedHotkey) throws {
        switch hotkeyMode {
        case .hold:
            try keyUpAfterSuccessfulKeyDown(hotkey)
        case .toggle:
            try emitter.keyDown(hotkey)
            try keyUpAfterSuccessfulKeyDown(hotkey)
        }
    }

    private func keyUpAfterSuccessfulKeyDown(_ hotkey: ParsedHotkey) throws {
        do {
            try emitter.keyUp(hotkey)
        } catch {
            emitter.recoverAfterKeyUpFailure(hotkey)
            throw error
        }
    }

    private func restoreSystemState() {
        if configureEngineOperation == nil {
            player?.stop()
            engine?.stop()
            if let player { engine?.detach(player) }
            player = nil
            engine = nil
        }
        if let originalInputDeviceID {
            if let setDefaultInputDeviceIDOperation {
                try? setDefaultInputDeviceIDOperation(originalInputDeviceID)
            } else {
                try? catalog.setDefaultInputDeviceID(originalInputDeviceID)
            }
        }
        originalInputDeviceID = nil
        expectedSequence = nil
        activeHotkey = nil
    }
}
