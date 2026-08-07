import CodexRemoteCore
import XCTest
@testable import CodexRemoteMac

@MainActor
final class SpeechAudioInputBridgeTests: XCTestCase {
    func testReceivesDecodedPCMAndEmitsFinalRecognitionTextOnEnd() async throws {
        let session = RecordingSpeechSession(finalText: "你好世界")
        let emitter = RecordingRecognizedTextEmitter()
        let bridge = SpeechAudioInputBridge(
            sessionFactory: RecordingSpeechSessionFactory(session: session),
            textEmitter: emitter
        )
        let frame = try IMAADPCMCodec().encode(
            samples: Array(repeating: Int16(1200), count: IMAADPCMCodec.samplesPerFrame),
            sequence: 7,
            sampleTimestamp: 0
        )

        try bridge.begin(firstAudioSequence: 7)
        try bridge.receive(frame)
        try await bridge.end(lastAudioSequence: 7)

        XCTAssertEqual(session.receivedSamples.count, IMAADPCMCodec.samplesPerFrame)
        XCTAssertEqual(emitter.values, ["你好世界"])
    }

    func testEndWithEmptyRecognitionDoesNotEmitText() async throws {
        let session = RecordingSpeechSession(finalText: "   ")
        let emitter = RecordingRecognizedTextEmitter()
        let bridge = SpeechAudioInputBridge(
            sessionFactory: RecordingSpeechSessionFactory(session: session),
            textEmitter: emitter
        )

        try bridge.begin(firstAudioSequence: 1)
        try await bridge.end(lastAudioSequence: 0)

        XCTAssertTrue(emitter.values.isEmpty)
    }

    func testSequenceGapAppendsSilentFrameBeforeDecodedPCM() throws {
        let session = RecordingSpeechSession(finalText: "")
        let bridge = SpeechAudioInputBridge(
            sessionFactory: RecordingSpeechSessionFactory(session: session),
            textEmitter: RecordingRecognizedTextEmitter()
        )
        let frame = try IMAADPCMCodec().encode(
            samples: Array(repeating: Int16(1200), count: IMAADPCMCodec.samplesPerFrame),
            sequence: 2,
            sampleTimestamp: 0
        )

        try bridge.begin(firstAudioSequence: 1)
        try bridge.receive(frame)

        XCTAssertEqual(session.appendedFrames.count, 2)
        XCTAssertTrue(session.appendedFrames[0].allSatisfy { $0 == 0 })
        XCTAssertFalse(session.appendedFrames[1].allSatisfy { $0 == 0 })
    }

    func testEndFailureCancelsSessionAndDoesNotEmitText() async {
        let session = RecordingSpeechSession(finalText: "", finishError: AudioInputBridgeError.audioSystemFailure)
        let emitter = RecordingRecognizedTextEmitter()
        let bridge = SpeechAudioInputBridge(
            sessionFactory: RecordingSpeechSessionFactory(session: session),
            textEmitter: emitter
        )

        XCTAssertNoThrow(try bridge.begin(firstAudioSequence: 1))
        do {
            try await bridge.end(lastAudioSequence: 0)
            XCTFail("Expected recognition failure")
        } catch {
            XCTAssertEqual(error as? AudioInputBridgeError, .audioSystemFailure)
        }
        XCTAssertTrue(session.wasCancelled)
        XCTAssertTrue(emitter.values.isEmpty)
    }

    func testAbortCancelsActiveSession() throws {
        let session = RecordingSpeechSession(finalText: "")
        let bridge = SpeechAudioInputBridge(
            sessionFactory: RecordingSpeechSessionFactory(session: session),
            textEmitter: RecordingRecognizedTextEmitter()
        )

        try bridge.begin(firstAudioSequence: 1)
        bridge.abort()

        XCTAssertTrue(session.wasCancelled)
        XCTAssertThrowsError(try bridge.receive(makeFrame(sequence: 1)))
    }

    private func makeFrame(sequence: UInt32) throws -> ADPCMFrame {
        try IMAADPCMCodec().encode(
            samples: Array(repeating: Int16(1200), count: IMAADPCMCodec.samplesPerFrame),
            sequence: sequence,
            sampleTimestamp: 0
        )
    }
}

@MainActor
private final class RecordingSpeechSessionFactory: SpeechRecognitionSessionFactory {
    let session: RecordingSpeechSession

    init(session: RecordingSpeechSession) { self.session = session }

    func makeSession() throws -> any SpeechRecognitionSession { session }
}

@MainActor
private final class RecordingSpeechSession: SpeechRecognitionSession {
    let finalText: String
    let finishError: Error?
    var appendedFrames: [[Int16]] = []
    var wasCancelled = false

    var receivedSamples: [Int16] { appendedFrames.flatMap { $0 } }

    init(finalText: String, finishError: Error? = nil) {
        self.finalText = finalText
        self.finishError = finishError
    }

    func append(samples: [Int16]) throws { appendedFrames.append(samples) }
    func finish() async throws -> String {
        if let finishError { throw finishError }
        return finalText
    }
    func cancel() { wasCancelled = true }
}

@MainActor
private final class RecordingRecognizedTextEmitter: RecognizedTextEmitting {
    var values: [String] = []
    func emit(text: String) throws { values.append(text) }
}
