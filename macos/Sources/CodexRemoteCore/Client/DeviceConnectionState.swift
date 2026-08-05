public enum DeviceConnectionState: Equatable, Sendable {
    case disconnected
    case ready(generation: UInt32, lastDeltaSequence: UInt32)
    case incompatible(remoteMajor: UInt8)
}
