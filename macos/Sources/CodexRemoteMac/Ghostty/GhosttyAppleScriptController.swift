import CodexRemoteCore

public enum GhosttyControllerError: Error, Equatable, Sendable {
    case noFocusedTerminal
    case invalidTerminalID
    case appleScriptFailed(String)
}

public struct GhosttyAppleScriptController: TerminalController, Sendable {
    private let runner: any AppleScriptRunning

    public init(runner: any AppleScriptRunning = ProcessAppleScriptRunner()) {
        self.runner = runner
    }

    public func captureFocusedTerminal() async throws -> TerminalContext {
        let output = try await runner.run(source: """
        tell application "Ghostty"
            if frontmost is false then error "Ghostty is not frontmost"
            tell front window
                tell selected tab
                    set focusedTerminal to focused terminal
                    set terminalID to id of focusedTerminal
                    set terminalCWD to working directory of focusedTerminal
                    set terminalName to name
                end tell
            end tell
            return terminalID & tab & terminalCWD & tab & terminalName
        end tell
        """)
        let fields = output.components(separatedBy: "\t")
        guard fields.count >= 3 else {
            throw GhosttyControllerError.noFocusedTerminal
        }

        return TerminalContext(
            terminalTargetID: fields[0],
            workingDirectory: fields[1],
            displayTitle: fields[2]
        )
    }

    public func focus(terminalTargetID: String) async throws {
        let terminalID = try validatedTerminalID(terminalTargetID)
        _ = try await runner.run(source: """
        tell application "Ghostty"
            activate
            tell terminal id "\(terminalID)"
                focus
            end tell
        end tell
        """)
    }

    public func scroll(deltaY: Int, terminalTargetID: String) async throws {
        let terminalID = try validatedTerminalID(terminalTargetID)
        _ = try await runner.run(source: """
        tell application "Ghostty"
            tell terminal id "\(terminalID)"
                send mouse scroll x 0 y \(deltaY) precision true
            end tell
        end tell
        """)
    }

    public func sendKey(_ key: TerminalKey, to terminalTargetID: String) async throws {
        let terminalID = try validatedTerminalID(terminalTargetID)
        _ = try await runner.run(source: """
        tell application "Ghostty"
            tell terminal id "\(terminalID)"
                send key "\(key.rawValue)"
            end tell
        end tell
        """)
    }

    private func validatedTerminalID(_ terminalTargetID: String) throws -> String {
        guard !terminalTargetID.contains("\""), !terminalTargetID.contains("\\") else {
            throw GhosttyControllerError.invalidTerminalID
        }

        return terminalTargetID
    }
}
