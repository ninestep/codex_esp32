import CodexRemoteCore
import Foundation

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
        tell application id "com.mitchellh.ghostty"
            if frontmost is false then error "Ghostty is not frontmost"
            set targetTab to selected tab of front window
            set targetTerm to focused terminal of targetTab
            return (id of targetTerm) & tab & (working directory of targetTerm) & tab & (name of targetTerm)
        end tell
        """)
        let fields = output.components(separatedBy: "\t")
        guard fields.count == 3, !fields[0].isEmpty else {
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
        tell application id "com.mitchellh.ghostty"
            activate
            set targetTerm to terminal id "\(terminalID)"
            focus targetTerm
        end tell
        """)
    }

    public func scroll(deltaY: Int, terminalTargetID: String) async throws {
        let terminalID = try validatedTerminalID(terminalTargetID)
        _ = try await runner.run(source: """
        tell application id "com.mitchellh.ghostty"
            set targetTerm to terminal id "\(terminalID)"
            send mouse scroll x 0 y \(deltaY) precision true to targetTerm
        end tell
        """)
    }

    public func sendKey(_ key: TerminalKey, to terminalTargetID: String) async throws {
        let terminalID = try validatedTerminalID(terminalTargetID)
        _ = try await runner.run(source: """
        tell application id "com.mitchellh.ghostty"
            set targetTerm to terminal id "\(terminalID)"
            send key "\(key.rawValue)" to targetTerm
        end tell
        """)
    }

    private func validatedTerminalID(_ terminalTargetID: String) throws -> String {
        let invalidCharacters = CharacterSet(charactersIn: "\"\\\n\r\t")
        guard !terminalTargetID.isEmpty, terminalTargetID.rangeOfCharacter(from: invalidCharacters) == nil else {
            throw GhosttyControllerError.invalidTerminalID
        }

        return terminalTargetID
    }
}
