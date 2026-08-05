@preconcurrency import CoreBluetooth
import CodexRemoteCore
import Foundation

@MainActor
public final class CoreBluetoothTransport: NSObject, BluetoothTransport {
    public var onStateChange: ((BluetoothTransportState) -> Void)?
    public var onPacket: ((BLETransportPacket) -> Void)?

    public var state: BluetoothTransportState { stateMachine.state }
    public var maximumWriteValueLength: Int {
        peripheral?.maximumWriteValueLength(for: .withoutResponse) ?? 20
    }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var discoveredPeripherals: [String: CBPeripheral] = [:]
    private var characteristics: [BluetoothCharacteristic: CBCharacteristic] = [:]
    private var stateMachine = BluetoothTransportStateMachine()

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    public func start() {
        execute(stateMachine.handle(.centralChanged(map(central.state))))
    }

    public func stop() {
        central.stopScan()
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        self.peripheral = nil
        characteristics.removeAll()
    }

    public func send(_ packet: BLETransportPacket, mode: BluetoothWriteMode) throws {
        guard case .ready = state, let peripheral else {
            throw BluetoothTransportError.notReady
        }
        guard let role = outboundRole(for: packet.channel), let characteristic = characteristics[role] else {
            throw BluetoothTransportError.unsupportedChannel(packet.channel)
        }
        let writeType: CBCharacteristicWriteType = mode == .withResponse ? .withResponse : .withoutResponse
        let maximum = peripheral.maximumWriteValueLength(for: writeType)
        guard packet.bytes.count <= maximum else {
            throw BluetoothTransportError.payloadTooLarge(maximum: maximum, actual: packet.bytes.count)
        }
        peripheral.writeValue(packet.bytes, for: characteristic, type: writeType)
    }

    private func execute(_ actions: [BluetoothTransportAction]) {
        for action in actions {
            switch action {
            case .startScan:
                central.scanForPeripherals(withServices: [BluetoothUUIDs.service])
            case .stopScan:
                central.stopScan()
            case let .connect(id):
                if let target = discoveredPeripherals[id] {
                    peripheral = target
                    central.connect(target)
                }
            case let .cancelConnection(id):
                if let target = discoveredPeripherals[id] ?? peripheral {
                    central.cancelPeripheralConnection(target)
                }
            case .discoverService:
                peripheral?.discoverServices([BluetoothUUIDs.service])
            case .discoverCharacteristics:
                if let service = peripheral?.services?.first(where: { $0.uuid == BluetoothUUIDs.service }) {
                    peripheral?.discoverCharacteristics(BluetoothUUIDs.characteristics, for: service)
                }
            case let .subscribe(role):
                if let characteristic = characteristics[role] {
                    peripheral?.setNotifyValue(true, for: characteristic)
                }
            case .connectionReady:
                break
            }
        }
        onStateChange?(stateMachine.state)
    }

    private func map(_ state: CBManagerState) -> BluetoothCentralAvailability {
        switch state {
        case .poweredOn: .poweredOn
        case .unauthorized: .unauthorized
        case .unsupported: .unsupported
        case .unknown, .resetting, .poweredOff: .poweredOff
        @unknown default: .unsupported
        }
    }

    private func role(for uuid: CBUUID) -> BluetoothCharacteristic? {
        BluetoothUUIDs.roleByUUID[uuid]
    }

    private func outboundRole(for channel: BLELogicalChannel) -> BluetoothCharacteristic? {
        switch channel {
        case .controlToDevice: .controlToDevice
        case .stateToDevice: .stateToDevice
        case .assetToDevice: .assetToDevice
        case .controlToHost, .audioToHost, .deviceInfo: nil
        }
    }

    private func inboundChannel(for role: BluetoothCharacteristic) -> BLELogicalChannel? {
        switch role {
        case .controlToHost: .controlToHost
        case .audioToHost: .audioToHost
        case .deviceInfo: .deviceInfo
        case .controlToDevice, .stateToDevice, .assetToDevice: nil
        }
    }
}

extension CoreBluetoothTransport: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        execute(stateMachine.handle(.centralChanged(map(central.state))))
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier.uuidString
        discoveredPeripherals[id] = peripheral
        execute(stateMachine.handle(.discoveredDevice(id: id)))
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        execute(stateMachine.handle(.connected(id: peripheral.identifier.uuidString)))
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        execute(stateMachine.handle(.disconnected(id: peripheral.identifier.uuidString)))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        characteristics.removeAll()
        self.peripheral = nil
        execute(stateMachine.handle(.disconnected(id: peripheral.identifier.uuidString)))
    }
}

extension CoreBluetoothTransport: @preconcurrency CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, peripheral.services?.contains(where: { $0.uuid == BluetoothUUIDs.service }) == true else { return }
        execute(stateMachine.handle(.serviceDiscovered))
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { return }
        for characteristic in service.characteristics ?? [] {
            if let role = role(for: characteristic.uuid) {
                characteristics[role] = characteristic
            }
        }
        execute(stateMachine.handle(.characteristicsDiscovered(Set(characteristics.keys))))
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil,
              let value = characteristic.value,
              let role = role(for: characteristic.uuid),
              let channel = inboundChannel(for: role)
        else { return }
        onPacket?(BLETransportPacket(channel: channel, bytes: value))
    }
}

private extension BluetoothUUIDs {
    static var characteristics: [CBUUID] {
        [controlToHost, controlToDevice, stateToDevice, audioToHost, assetToDevice, deviceInfo]
    }

    static var roleByUUID: [CBUUID: BluetoothCharacteristic] {
        [
            controlToHost: .controlToHost,
            controlToDevice: .controlToDevice,
            stateToDevice: .stateToDevice,
            audioToHost: .audioToHost,
            assetToDevice: .assetToDevice,
            deviceInfo: .deviceInfo,
        ]
    }
}
