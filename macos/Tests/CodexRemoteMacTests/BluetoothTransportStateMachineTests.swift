import XCTest
@testable import CodexRemoteMac

final class BluetoothTransportStateMachineTests: XCTestCase {
    func testUUIDContractIsStable() {
        XCTAssertEqual(BluetoothUUIDs.service.uuidString, "7D2E0000-7C6A-4E6D-A3E1-9F6B4C520001")
        XCTAssertEqual(BluetoothUUIDs.controlToHost.uuidString, "7D2E0001-7C6A-4E6D-A3E1-9F6B4C520001")
        XCTAssertEqual(BluetoothUUIDs.controlToDevice.uuidString, "7D2E0002-7C6A-4E6D-A3E1-9F6B4C520001")
        XCTAssertEqual(BluetoothUUIDs.stateToDevice.uuidString, "7D2E0003-7C6A-4E6D-A3E1-9F6B4C520001")
        XCTAssertEqual(BluetoothUUIDs.audioToHost.uuidString, "7D2E0004-7C6A-4E6D-A3E1-9F6B4C520001")
        XCTAssertEqual(BluetoothUUIDs.assetToDevice.uuidString, "7D2E0005-7C6A-4E6D-A3E1-9F6B4C520001")
        XCTAssertEqual(BluetoothUUIDs.deviceInfo.uuidString, "7D2E0006-7C6A-4E6D-A3E1-9F6B4C520001")
    }

    func testPoweredOnScansAndFirstDiscoveryStopsScanBeforeConnecting() {
        var machine = BluetoothTransportStateMachine()

        XCTAssertEqual(machine.handle(.centralChanged(.poweredOn)), [.startScan])
        XCTAssertEqual(machine.state, .scanning)
        XCTAssertEqual(machine.handle(.discoveredDevice(id: "device-1")), [.stopScan, .connect(id: "device-1")])
        XCTAssertEqual(machine.state, .connecting(id: "device-1"))
        XCTAssertTrue(machine.handle(.discoveredDevice(id: "device-2")).isEmpty)
    }

    func testUnavailableCentralDoesNotScanAndClearsConnection() {
        var machine = BluetoothTransportStateMachine()
        _ = machine.handle(.centralChanged(.poweredOn))
        _ = machine.handle(.discoveredDevice(id: "device-1"))

        XCTAssertEqual(machine.handle(.centralChanged(.unauthorized)), [.cancelConnection(id: "device-1")])
        XCTAssertEqual(machine.state, .unavailable(.unauthorized))
    }

    func testReadyRequiresAllSixCharacteristics() {
        var machine = connectedMachine()
        let incomplete = Set(BluetoothCharacteristic.allCases.dropLast())

        XCTAssertTrue(machine.handle(.characteristicsDiscovered(incomplete)).isEmpty)
        XCTAssertEqual(machine.state, .discoveringCharacteristics(id: "device-1"))
        XCTAssertEqual(machine.handle(.characteristicsDiscovered(Set(BluetoothCharacteristic.allCases))), [
            .subscribe(.controlToHost),
            .subscribe(.audioToHost),
            .resetSubscription(.deviceInfo),
            .connectionReady,
        ])
        XCTAssertEqual(machine.state, .ready(id: "device-1"))
    }

    func testDisconnectResetsAndRestartsScanWhenPoweredOn() {
        var machine = connectedMachine()
        _ = machine.handle(.characteristicsDiscovered(Set(BluetoothCharacteristic.allCases)))

        XCTAssertEqual(machine.handle(.disconnected(id: "device-1")), [.startScan])
        XCTAssertEqual(machine.state, .scanning)
    }

    private func connectedMachine() -> BluetoothTransportStateMachine {
        var machine = BluetoothTransportStateMachine()
        _ = machine.handle(.centralChanged(.poweredOn))
        _ = machine.handle(.discoveredDevice(id: "device-1"))
        XCTAssertEqual(machine.handle(.connected(id: "device-1")), [.discoverService])
        XCTAssertEqual(machine.handle(.serviceDiscovered), [.discoverCharacteristics])
        return machine
    }
}
