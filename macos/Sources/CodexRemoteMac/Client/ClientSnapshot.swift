import CodexRemoteCore

public struct ClientSnapshot: Equatable, Sendable {
    public let transportState: BluetoothTransportState
    public let sessions: [RemoteSession]
    public let deviceInformation: DeviceInformation?
    public let selectedSessionKey: UInt16?

    public init(
        transportState: BluetoothTransportState,
        sessions: [RemoteSession],
        deviceInformation: DeviceInformation?,
        selectedSessionKey: UInt16?
    ) {
        self.transportState = transportState
        self.sessions = sessions
        self.deviceInformation = deviceInformation
        self.selectedSessionKey = selectedSessionKey
    }
}
