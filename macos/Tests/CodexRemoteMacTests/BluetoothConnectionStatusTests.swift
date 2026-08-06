import XCTest
@testable import CodexRemoteMac

@MainActor
final class BluetoothConnectionStatusTests: XCTestCase {
    func testUpdateTracksReadyAndReturnsOnlyRealTransitions() {
        let status = BluetoothConnectionStatus()

        XCTAssertFalse(status.isConnected)
        XCTAssertTrue(status.update(.ready(id: "device-1")))
        XCTAssertTrue(status.isConnected)
        XCTAssertFalse(status.update(.ready(id: "device-1")))
        XCTAssertTrue(status.update(.scanning))
        XCTAssertFalse(status.isConnected)
    }
}
