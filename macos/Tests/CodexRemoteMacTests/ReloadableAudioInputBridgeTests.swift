import CodexRemoteCore
import Foundation
import XCTest
@testable import CodexRemoteMac

@MainActor
final class ReloadableAudioInputBridgeTests: XCTestCase {
    func testRoutesCallsToCurrentBridgeAndReplacementBridge() async throws {
        let old = RecordingAudioInputBridge(status: .blackHoleMissing)
        let replacement = RecordingAudioInputBridge(status: .ready)
        let bridge = ReloadableAudioInputBridge(current: old)

        XCTAssertEqual(bridge.dependencyStatus, .blackHoleMissing)
        try bridge.begin(firstAudioSequence: 10)
        try bridge.receive(frame(sequence: 10))
        try await bridge.end(lastAudioSequence: 10)

        bridge.replace(with: replacement)
        XCTAssertEqual(bridge.dependencyStatus, .ready)
        try bridge.begin(firstAudioSequence: 20)
        try bridge.receive(frame(sequence: 20))
        try await bridge.end(lastAudioSequence: 20)

        XCTAssertEqual(old.events, [
            .begin(10),
            .receive(10),
            .end(10),
            .abort,
        ])
        XCTAssertEqual(replacement.events, [
            .begin(20),
            .receive(20),
            .end(20),
        ])
    }

    func testReplaceAbortsOldActiveTransactionBeforeRoutingToReplacement() throws {
        let old = RecordingAudioInputBridge(status: .ready)
        let replacement = RecordingAudioInputBridge(status: .ready)
        let bridge = ReloadableAudioInputBridge(current: old)

        try bridge.begin(firstAudioSequence: 1)
        bridge.replace(with: replacement)
        try bridge.begin(firstAudioSequence: 2)

        XCTAssertEqual(old.events, [.begin(1), .abort])
        XCTAssertEqual(replacement.events, [.begin(2)])
    }

    func testReplaceWhileOldEndIsSuspendedImmediatelyRoutesNewCallsToReplacement() async throws {
        let old = SuspendedEndingAudioInputBridge(status: .ready)
        let replacement = RecordingAudioInputBridge(status: .ready)
        let bridge = ReloadableAudioInputBridge(current: old)

        let endTask = Task { @MainActor in
            try await bridge.end(lastAudioSequence: 1)
        }
        await old.waitUntilEndStarted()

        bridge.replace(with: replacement)
        try bridge.begin(firstAudioSequence: 2)
        old.resumeEnd()
        try await endTask.value

        XCTAssertEqual(old.events, [.end(1), .abort])
        XCTAssertEqual(replacement.events, [.begin(2)])
        XCTAssertEqual(bridge.dependencyStatus, .ready)
    }

    private func frame(sequence: UInt32) -> ADPCMFrame {
        ADPCMFrame(
            sequence: sequence,
            sampleTimestamp: 1,
            predictor: 0,
            stepIndex: 0,
            sampleCount: 1,
            encodedSamples: Data()
        )
    }
}

@MainActor
private final class RecordingAudioInputBridge: AudioInputHandling {
    enum Event: Equatable {
        case begin(UInt32)
        case receive(UInt32)
        case end(UInt32)
        case abort
    }

    let dependencyStatus: AudioDependencyStatus
    private(set) var events: [Event] = []

    init(status: AudioDependencyStatus) {
        self.dependencyStatus = status
    }

    func begin(firstAudioSequence: UInt32) {
        events.append(.begin(firstAudioSequence))
    }

    func receive(_ frame: ADPCMFrame) {
        events.append(.receive(frame.sequence))
    }

    func end(lastAudioSequence: UInt32) async {
        events.append(.end(lastAudioSequence))
    }

    func abort() {
        events.append(.abort)
    }
}

@MainActor
private final class SuspendedEndingAudioInputBridge: AudioInputHandling {
    let dependencyStatus: AudioDependencyStatus
    private(set) var events: [RecordingAudioInputBridge.Event] = []
    private var endContinuation: CheckedContinuation<Void, Never>?
    private var endStartedContinuation: CheckedContinuation<Void, Never>?

    init(status: AudioDependencyStatus) {
        self.dependencyStatus = status
    }

    func begin(firstAudioSequence: UInt32) {
        events.append(.begin(firstAudioSequence))
    }

    func receive(_ frame: ADPCMFrame) {
        events.append(.receive(frame.sequence))
    }

    func end(lastAudioSequence: UInt32) async {
        events.append(.end(lastAudioSequence))
        endStartedContinuation?.resume()
        endStartedContinuation = nil
        await withCheckedContinuation { continuation in
            endContinuation = continuation
        }
    }

    func abort() {
        events.append(.abort)
    }

    func waitUntilEndStarted() async {
        if events.contains(.end(1)) { return }
        await withCheckedContinuation { continuation in
            endStartedContinuation = continuation
        }
    }

    func resumeEnd() {
        endContinuation?.resume()
        endContinuation = nil
    }
}
