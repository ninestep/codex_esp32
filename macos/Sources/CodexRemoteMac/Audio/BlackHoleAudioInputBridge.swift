import AudioToolbox
import AVFoundation
import CodexRemoteCore
import Foundation

@MainActor
public final class BlackHoleAudioInputBridge: AudioInputHandling {
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
    private lazy var engine = AVAudioEngine()
    private lazy var player = AVAudioPlayerNode()
    private var originalInputDeviceID: AudioDeviceID?
    private var expectedSequence: UInt32?
    private var activeHotkey: ParsedHotkey?

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
        emitter: any HotkeyEmitting
    ) {
        self.catalog = CoreAudioDeviceCatalog()
        self.emitter = emitter
        self.hotkey = HotkeyParser().parse(hotkeyText)
        self.hotkeyMode = hotkeyMode
        self.blackHoleDeviceIDProvider = { blackHoleDeviceID }
        self.originalInputDeviceIDProvider = { originalInputDeviceID }
        self.setDefaultInputDeviceIDOperation = { _ in }
        self.configureEngineOperation = { _ in }
        self.playbackCompletionOperation = {}
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
            if let configureEngineOperation {
                try configureEngineOperation(blackHoleDeviceID)
            } else {
                try configureEngine(outputDeviceID: blackHoleDeviceID)
            }
            if let setDefaultInputDeviceIDOperation {
                try setDefaultInputDeviceIDOperation(blackHoleDeviceID)
            } else {
                try catalog.setDefaultInputDeviceID(blackHoleDeviceID)
            }
            try triggerBegin(hotkey)
            activeHotkey = hotkey
            expectedSequence = firstAudioSequence
        } catch {
            restoreSystemState()
            throw error
        }
    }

    public func receive(_ frame: ADPCMFrame) throws {
        guard let expectedSequence else { throw AudioInputBridgeError.notActive }
        guard frame.sequence >= expectedSequence else { return }
        if frame.sequence > expectedSequence {
            for _ in expectedSequence..<frame.sequence {
                try schedule(samples: Array(repeating: 0, count: IMAADPCMCodec.samplesPerFrame))
            }
        }
        try schedule(samples: codec.decode(frame))
        self.expectedSequence = frame.sequence &+ 1
    }

    public func end(lastAudioSequence: UInt32) async throws {
        guard expectedSequence != nil else { throw AudioInputBridgeError.notActive }
        if let playbackCompletionOperation {
            await playbackCompletionOperation()
        } else {
            await playbackCompletion()
        }
        if let hotkey = activeHotkey { try triggerEnd(hotkey) }
        restoreSystemState()
        _ = lastAudioSequence
    }

    public func abort() {
        if let hotkey = activeHotkey, hotkeyMode == .hold {
            _ = try? keyUpAfterSuccessfulKeyDown(hotkey)
        }
        restoreSystemState()
    }

    private func configureEngine(outputDeviceID: AudioDeviceID) throws {
        engine.attach(player)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else { throw AudioInputBridgeError.audioSystemFailure }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        var deviceID = outputDeviceID
        let status = AudioUnitSetProperty(
            engine.outputNode.audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw AudioInputBridgeError.audioSystemFailure }
        do {
            try engine.start()
        } catch {
            throw AudioInputBridgeError.audioSystemFailure
        }
        player.play()
    }

    private func schedule(samples: [Int16]) throws {
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
            target[index] = Float(sample) / Float(Int16.max)
        }
        player.scheduleBuffer(buffer)
    }

    private func playbackCompletion() async {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) else {
            return
        }
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
            player.stop()
            engine.stop()
            engine.detach(player)
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
