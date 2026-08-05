import CodexRemoteCore
import Foundation

public enum BluetoothWriteMode: Equatable, Sendable {
    case withResponse
    case withoutResponse
}

public enum BluetoothTransportError: Error, Equatable, Sendable {
    case notReady
    case unsupportedChannel(BLELogicalChannel)
    case payloadTooLarge(maximum: Int, actual: Int)
}

@MainActor
public protocol BluetoothTransport: AnyObject {
    var state: BluetoothTransportState { get }
    var maximumWriteValueLength: Int { get }
    var onStateChange: ((BluetoothTransportState) -> Void)? { get set }
    var onPacket: ((BLETransportPacket) -> Void)? { get set }

    func start()
    func stop()
    func send(_ packet: BLETransportPacket, mode: BluetoothWriteMode) throws
}
