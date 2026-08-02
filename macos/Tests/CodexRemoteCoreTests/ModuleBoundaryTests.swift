import XCTest
@testable import CodexRemoteCore

final class ModuleBoundaryTests: XCTestCase {
    func testCoreCanConstructRemoteSessionWithoutPlatformTypes() {
        let session = RemoteSession(
            remoteSessionID: "remote-1",
            launcherInstanceID: "launch-1",
            providerSessionID: nil,
            terminalTargetID: "terminal-1",
            displayTitle: "esp32",
            workingDirectoryLabel: "esp32"
        )

        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(session.terminalTargetID, "terminal-1")
    }
}
