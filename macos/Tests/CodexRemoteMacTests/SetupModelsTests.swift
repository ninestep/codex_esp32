import Foundation
import XCTest
@testable import CodexRemoteMac

final class SetupModelsTests: XCTestCase {
    func testAllRequiredItemsReadyMakesSnapshotReady() {
        let snapshot = SetupSnapshot(results: SetupItem.allCases.map { item in
            SetupCheckResult(item: item, state: .ready, summary: "\(item) ready")
        })

        XCTAssertTrue(snapshot.isMacReady)
    }

    func testWaitingRequiredItemKeepsSnapshotNotReady() {
        let snapshot = SetupSnapshot(results: SetupItem.allCases.map { item in
            SetupCheckResult(
                item: item,
                state: item == .hooksTrust ? .waitingForUser : .ready,
                summary: "\(item)"
            )
        })

        XCTAssertFalse(snapshot.isMacReady)
    }

    func testOnlyESP32WaitingDoesNotBlockSnapshotReadiness() {
        let snapshot = SetupSnapshot(results: SetupItem.allCases.map { item in
            SetupCheckResult(
                item: item,
                state: item == .esp32Device ? .waitingForUser : .ready,
                summary: "\(item)"
            )
        })

        XCTAssertTrue(snapshot.isMacReady)
    }

    func testEmptySnapshotIsNotReady() {
        XCTAssertFalse(SetupSnapshot(results: []).isMacReady)
    }

    func testResultLookupUsesSetupItemIdentity() {
        let codex = SetupCheckResult(item: .codexCLI, state: .ready, summary: "Codex ready")
        let snapshot = SetupSnapshot(results: [
            SetupCheckResult(item: .ghostty, state: .ready, summary: "Ghostty ready"),
            codex,
        ])

        XCTAssertEqual(snapshot.result(for: .codexCLI), codex)
        XCTAssertNil(snapshot.result(for: .blackHole))
    }

    func testCheckResultDefaultsDetailAndActions() {
        let result = SetupCheckResult(item: .shellPath, state: .checking, summary: "Checking")

        XCTAssertNil(result.detail)
        XCTAssertEqual(result.availableActions, [])
        XCTAssertEqual(result.id, .shellPath)
    }
}
