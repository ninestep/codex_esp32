import ApplicationServices

public enum HotkeyRecordingUpdate: Equatable, Sendable {
    case recording(String)
    case completed(String)
    case invalid
}

public struct HotkeyRecordingSession: Sendable {
    private var candidate: String?
    private var isInvalid = false

    public init() {}

    public mutating func update(flags: CGEventFlags) -> HotkeyRecordingUpdate {
        if flags.contains(.maskShift) || flags.contains(.maskSecondaryFn) {
            candidate = nil
            isInvalid = true
            return .invalid
        }

        let display = [
            (CGEventFlags.maskCommand, "⌘"),
            (.maskAlternate, "⌥"),
            (.maskControl, "⌃"),
        ]
        .filter { flags.contains($0.0) }
        .map(\.1)
        .joined()

        guard !display.isEmpty else {
            let result: HotkeyRecordingUpdate
            if !isInvalid, let candidate {
                result = .completed(candidate)
            } else {
                result = .invalid
            }
            reset()
            return result
        }

        guard !isInvalid else { return .invalid }
        if display.count >= 2 {
            candidate = display
        }
        return .recording(candidate ?? display)
    }

    public mutating func reset() {
        candidate = nil
        isInvalid = false
    }
}
