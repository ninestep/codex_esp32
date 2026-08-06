import Foundation

@MainActor
public final class BluetoothConnectionStatus {
    public private(set) var isConnected = false

    public init() {}

    @discardableResult
    public func update(_ state: BluetoothTransportState) -> Bool {
        let nextValue: Bool
        if case .ready = state {
            nextValue = true
        } else {
            nextValue = false
        }
        guard nextValue != isConnected else { return false }
        isConnected = nextValue
        return true
    }
}
