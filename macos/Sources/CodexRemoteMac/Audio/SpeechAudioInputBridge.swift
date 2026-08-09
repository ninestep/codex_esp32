import AVFoundation
import ApplicationServices
import CodexRemoteCore
import Foundation
import OSLog
import Speech

public enum SpeechRecognitionAuthorization {
    public static func request() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            true
        case .notDetermined:
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        case .denied, .restricted:
            false
        @unknown default:
            false
        }
    }
}

@MainActor
public protocol SpeechRecognitionSession: AnyObject {
    func append(samples: [Int16]) throws
    func finish() async throws -> String
    func cancel()
}

@MainActor
public protocol SpeechRecognitionSessionFactory: AnyObject {
    var dependencyStatus: AudioDependencyStatus { get }
    func makeSession() throws -> any SpeechRecognitionSession
}

public extension SpeechRecognitionSessionFactory {
    var dependencyStatus: AudioDependencyStatus { .ready }
}

@MainActor
public protocol RecognizedTextEmitting: AnyObject {
    func emit(text: String) throws
}

public enum SpeechAudioActivityPhase: Equatable, Sendable {
    case idle
    case recording
    case processing
}

public struct SpeechAudioActivity: Equatable, Sendable {
    public let phase: SpeechAudioActivityPhase
    public let level: Double
    public let waveform: [Double]

    public init(phase: SpeechAudioActivityPhase, level: Double, waveform: [Double] = []) {
        self.phase = phase
        self.level = min(max(level, 0), 1)
        self.waveform = waveform.map { min(max($0, 0), 1) }
    }

    public static let idle = SpeechAudioActivity(phase: .idle, level: 0)
}

@MainActor
public final class SpeechAudioInputBridge: AudioInputHandling {
    private static let logger = Logger(subsystem: "CodexRemote", category: "SpeechAudioInput")
    public var dependencyStatus: AudioDependencyStatus { sessionFactory.dependencyStatus }

    private let sessionFactory: any SpeechRecognitionSessionFactory
    private let textEmitter: any RecognizedTextEmitting
    private let activityHandler: (SpeechAudioActivity) -> Void
    private let codec = IMAADPCMCodec()
    private var session: (any SpeechRecognitionSession)?
    private var expectedSequence: UInt32?
    private var smoothedAudioLevel = 0.0
    private var smoothedWaveform = Array(repeating: 0.0, count: 21)

    public init(
        sessionFactory: any SpeechRecognitionSessionFactory = NativeSpeechRecognitionSessionFactory(),
        textEmitter: any RecognizedTextEmitting = ChatGPTComposerTextEmitter(),
        activityHandler: @escaping (SpeechAudioActivity) -> Void = { _ in }
    ) {
        self.sessionFactory = sessionFactory
        self.textEmitter = textEmitter
        self.activityHandler = activityHandler
    }

    public func begin(firstAudioSequence: UInt32) throws {
        guard expectedSequence == nil else { throw AudioInputBridgeError.alreadyActive }
        session = try sessionFactory.makeSession()
        expectedSequence = firstAudioSequence
        smoothedAudioLevel = 0
        smoothedWaveform = Array(repeating: 0, count: 21)
        activityHandler(SpeechAudioActivity(phase: .recording, level: 0, waveform: smoothedWaveform))
    }

    public func receive(_ frame: ADPCMFrame) throws {
        guard let expectedSequence, let session else {
            throw AudioInputBridgeError.notActive
        }
        guard frame.sequence >= expectedSequence else { return }
        if frame.sequence > expectedSequence {
            for _ in expectedSequence..<frame.sequence {
                try session.append(samples: Array(repeating: 0, count: IMAADPCMCodec.samplesPerFrame))
            }
        }
        let samples = try codec.decode(frame)
        try session.append(samples: samples)
        smoothedAudioLevel = Self.smoothedLevel(samples: samples, previous: smoothedAudioLevel)
        smoothedWaveform = Self.smoothedWaveform(samples: samples, previous: smoothedWaveform)
        activityHandler(SpeechAudioActivity(
            phase: .recording,
            level: smoothedAudioLevel,
            waveform: smoothedWaveform
        ))
        self.expectedSequence = frame.sequence &+ 1
    }

    public func end(lastAudioSequence: UInt32) async throws {
        guard let session else { throw AudioInputBridgeError.notActive }
        activityHandler(SpeechAudioActivity(phase: .processing, level: 0))
        do {
            let text = try await session.finish().trimmingCharacters(in: .whitespacesAndNewlines)
            Self.logger.info("Recognition completed characters=\(text.count)")
            if !text.isEmpty {
                try textEmitter.emit(text: text)
                Self.logger.info("Recognized text keyboard emission completed characters=\(text.count)")
            }
            self.session = nil
            expectedSequence = nil
            smoothedAudioLevel = 0
            smoothedWaveform = Array(repeating: 0, count: 21)
            activityHandler(.idle)
            _ = lastAudioSequence
        } catch {
            abort()
            throw error
        }
    }

    public func abort() {
        session?.cancel()
        session = nil
        expectedSequence = nil
        smoothedAudioLevel = 0
        smoothedWaveform = Array(repeating: 0, count: 21)
        activityHandler(.idle)
    }

    private static func smoothedLevel(samples: [Int16], previous: Double) -> Double {
        guard !samples.isEmpty else { return previous * 0.75 }
        let meanSquare = samples.reduce(0.0) { partial, sample in
            let normalized = Double(sample) / Double(Int16.max)
            return partial + normalized * normalized
        } / Double(samples.count)
        let rootMeanSquare = sqrt(meanSquare)
        let normalized = min(max((rootMeanSquare - 0.006) / 0.09, 0), 1)
        let emphasizedLevel = pow(normalized, 0.58)
        let smoothing = emphasizedLevel > previous ? 0.76 : 0.28
        return previous + (emphasizedLevel - previous) * smoothing
    }

    private static func smoothedWaveform(samples: [Int16], previous: [Double]) -> [Double] {
        let bandCount = 21
        guard !samples.isEmpty else { return Array(repeating: 0, count: bandCount) }
        return (0..<bandCount).map { index in
            let start = index * samples.count / bandCount
            let end = max(start + 1, (index + 1) * samples.count / bandCount)
            let slice = samples[start..<min(end, samples.count)]
            let meanSquare = slice.reduce(0.0) { partial, sample in
                let normalized = Double(sample) / Double(Int16.max)
                return partial + normalized * normalized
            } / Double(slice.count)
            let rootMeanSquare = sqrt(meanSquare)
            let normalized = min(max((rootMeanSquare - 0.004) / 0.075, 0), 1)
            let emphasized = pow(normalized, 0.52)
            let oldValue = previous.indices.contains(index) ? previous[index] : 0
            let smoothing = emphasized > oldValue ? 0.82 : 0.34
            return oldValue + (emphasized - oldValue) * smoothing
        }
    }
}

@MainActor
public final class NativeSpeechRecognitionSessionFactory: SpeechRecognitionSessionFactory {
    public init() {}

    public func makeSession() throws -> any SpeechRecognitionSession {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw AudioInputBridgeError.audioSystemFailure
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
              recognizer.isAvailable else {
            throw AudioInputBridgeError.audioSystemFailure
        }
        return try NativeSpeechRecognitionSession(recognizer: recognizer)
    }
}

@MainActor
private final class NativeSpeechRecognitionSession: SpeechRecognitionSession {
    private static let finishTimeout: Duration = .seconds(12)

    private let request: SFSpeechAudioBufferRecognitionRequest
    private var task: SFSpeechRecognitionTask?
    private var latestText = ""
    private var finishContinuation: CheckedContinuation<String, Error>?
    private var finishTimeoutTask: Task<Void, Never>?
    private var terminalError: Error?
    private var didReceiveFinalResult = false

    init(recognizer: SFSpeechRecognizer) throws {
        request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result { latestText = result.bestTranscription.formattedString }
            if let error {
                terminalError = error
                complete(with: .failure(error))
            } else if result?.isFinal == true {
                didReceiveFinalResult = true
                complete(with: .success(latestText))
            }
        }
    }

    func append(samples: [Int16]) throws {
        guard !samples.isEmpty,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: 16_000,
                  channels: 1,
                  interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let target = buffer.floatChannelData?[0]
        else { throw AudioInputBridgeError.audioSystemFailure }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() {
            target[index] = Float(sample) / Float(Int16.max)
        }
        request.append(buffer)
    }

    func finish() async throws -> String {
        request.endAudio()
        if let terminalError { throw terminalError }
        if didReceiveFinalResult { return latestText }
        return try await withCheckedThrowingContinuation { continuation in
            finishContinuation = continuation
            finishTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: Self.finishTimeout)
                guard !Task.isCancelled else { return }
                self?.failTimedOutFinish()
            }
        }
    }

    func cancel() {
        task?.cancel()
        finishTimeoutTask?.cancel()
        finishTimeoutTask = nil
        finishContinuation = nil
    }

    private func complete(with result: Result<String, Error>) {
        finishTimeoutTask?.cancel()
        finishTimeoutTask = nil
        guard let continuation = finishContinuation else { return }
        finishContinuation = nil
        continuation.resume(with: result)
    }

    private func failTimedOutFinish() {
        guard finishContinuation != nil else { return }
        task?.cancel()
        complete(with: .failure(AudioInputBridgeError.audioSystemFailure))
    }
}

@MainActor
public final class CGEventRecognizedTextEmitter: RecognizedTextEmitting {
    public init() {}

    public func emit(text: String) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw AudioInputBridgeError.audioSystemFailure
        }
        let units = Array(text.utf16)
        for chunkStart in stride(from: 0, to: units.count, by: 200) {
            let chunk = Array(units[chunkStart..<min(chunkStart + 200, units.count)])
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { throw AudioInputBridgeError.audioSystemFailure }
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }
}
