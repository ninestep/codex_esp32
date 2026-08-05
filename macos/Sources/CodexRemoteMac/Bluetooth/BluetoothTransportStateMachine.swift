public enum BluetoothCentralAvailability: Equatable, Sendable {
    case poweredOn
    case poweredOff
    case unauthorized
    case unsupported
}

public enum BluetoothCharacteristic: CaseIterable, Equatable, Hashable, Sendable {
    case controlToHost
    case controlToDevice
    case stateToDevice
    case audioToHost
    case assetToDevice
    case deviceInfo
}

public enum BluetoothTransportState: Equatable, Sendable {
    case disconnected
    case unavailable(BluetoothCentralAvailability)
    case scanning
    case connecting(id: String)
    case discoveringService(id: String)
    case discoveringCharacteristics(id: String)
    case ready(id: String)
}

public enum BluetoothTransportEvent: Equatable, Sendable {
    case centralChanged(BluetoothCentralAvailability)
    case discoveredDevice(id: String)
    case connected(id: String)
    case serviceDiscovered
    case characteristicsDiscovered(Set<BluetoothCharacteristic>)
    case disconnected(id: String)
}

public enum BluetoothTransportAction: Equatable, Sendable {
    case startScan
    case stopScan
    case connect(id: String)
    case cancelConnection(id: String)
    case discoverService
    case discoverCharacteristics
    case subscribe(BluetoothCharacteristic)
    case connectionReady
}

public struct BluetoothTransportStateMachine: Sendable {
    public private(set) var state: BluetoothTransportState = .disconnected
    private var centralAvailability: BluetoothCentralAvailability = .poweredOff

    public init() {}

    public mutating func handle(_ event: BluetoothTransportEvent) -> [BluetoothTransportAction] {
        switch event {
        case let .centralChanged(availability):
            centralAvailability = availability
            guard availability == .poweredOn else {
                let actions = cancellationActions()
                state = .unavailable(availability)
                return actions
            }
            guard state != .scanning else { return [] }
            state = .scanning
            return [.startScan]

        case let .discoveredDevice(id):
            guard state == .scanning else { return [] }
            state = .connecting(id: id)
            return [.stopScan, .connect(id: id)]

        case let .connected(id):
            guard state == .connecting(id: id) else { return [] }
            state = .discoveringService(id: id)
            return [.discoverService]

        case .serviceDiscovered:
            guard case let .discoveringService(id) = state else { return [] }
            state = .discoveringCharacteristics(id: id)
            return [.discoverCharacteristics]

        case let .characteristicsDiscovered(characteristics):
            guard case let .discoveringCharacteristics(id) = state,
                  characteristics == Set(BluetoothCharacteristic.allCases)
            else { return [] }
            state = .ready(id: id)
            return [
                .subscribe(.controlToHost),
                .subscribe(.audioToHost),
                .subscribe(.deviceInfo),
                .connectionReady,
            ]

        case let .disconnected(id):
            guard activeDeviceID == id else { return [] }
            if centralAvailability == .poweredOn {
                state = .scanning
                return [.startScan]
            }
            state = .disconnected
            return []
        }
    }

    private var activeDeviceID: String? {
        switch state {
        case let .connecting(id), let .discoveringService(id), let .discoveringCharacteristics(id), let .ready(id):
            id
        case .disconnected, .unavailable, .scanning:
            nil
        }
    }

    private func cancellationActions() -> [BluetoothTransportAction] {
        if let activeDeviceID {
            return [.cancelConnection(id: activeDeviceID)]
        }
        if state == .scanning {
            return [.stopScan]
        }
        return []
    }
}
