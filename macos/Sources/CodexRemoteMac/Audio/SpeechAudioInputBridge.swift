import AVFoundation
import ApplicationServices
import CodexRemoteCore
import Foundation
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
    func makeSession() throws -> any SpeechRecognitionSession
}

@MainActor
public protocol RecognizedTextEmitting: AnyObject {
    func emit(text: String) throws
}

@MainActor
public final class SpeechAudioInputBridge: AudioInputHandling {
    public let dependencyStatus: AudioDependencyStatus = .ready

    private let sessionFactory: any SpeechRecognitionSessionFactory
    private let textEmitter: any RecognizedTextEmitting
    private let codec = IMAADPCMCodec()
    private var session: (any SpeechRecognitionSession)?
    private var expectedSequence: UInt32?

    public init(
        sessionFactory: any SpeechRecognitionSessionFactory = NativeSpeechRecognitionSessionFactory(),
        textEmitter: any RecognizedTextEmitting = CGEventRecognizedTextEmitter()
    ) {
        self.sessionFactory = sessionFactory
        self.textEmitter = textEmitter
    }

    public func begin(firstAudioSequence: UInt32) throws {
        guard expectedSequence == nil else { throw AudioInputBridgeError.alreadyActive }
        session = try sessionFactory.makeSession()
        expectedSequence = firstAudioSequence
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
        try session.append(samples: codec.decode(frame))
        self.expectedSequence = frame.sequence &+ 1
    }

    public func end(lastAudioSequence: UInt32) async throws {
        guard let session else { throw AudioInputBridgeError.notActive }
        do {
            let text = try await session.finish().trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { try textEmitter.emit(text: text) }
            self.session = nil
            expectedSequence = nil
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
