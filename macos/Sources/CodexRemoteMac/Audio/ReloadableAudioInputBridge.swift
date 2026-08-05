import CodexRemoteCore

@MainActor
public final class ReloadableAudioInputBridge: AudioInputHandling {
    private var current: any AudioInputHandling

    public init(current: any AudioInputHandling) {
        self.current = current
    }

    public func replace(with replacement: any AudioInputHandling) {
        current.abort()
        current = replacement
    }

    public var dependencyStatus: AudioDependencyStatus {
        current.dependencyStatus
    }

    public func begin(firstAudioSequence: UInt32) throws {
        try current.begin(firstAudioSequence: firstAudioSequence)
    }

    public func receive(_ frame: ADPCMFrame) throws {
        try current.receive(frame)
    }

    public func end(lastAudioSequence: UInt32) async throws {
        try await current.end(lastAudioSequence: lastAudioSequence)
    }

    public func abort() {
        current.abort()
    }
}
