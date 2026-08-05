import CodexRemoteCore

@MainActor
public protocol AudioInputHandling: AnyObject {
    var dependencyStatus: AudioDependencyStatus { get }
    func begin(firstAudioSequence: UInt32) throws
    func receive(_ frame: ADPCMFrame) throws
    func end(lastAudioSequence: UInt32) async throws
    func abort()
}

public enum AudioInputBridgeError: Error, Equatable, Sendable {
    case dependencyMissing
    case hotkeyNotConfigured
    case accessibilityNotGranted
    case alreadyActive
    case notActive
    case invalidSequence(expected: UInt32, actual: UInt32)
    case audioSystemFailure
}
