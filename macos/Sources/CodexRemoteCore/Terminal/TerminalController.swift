public enum TerminalKey: String, Codable, Sendable {
    case enter, escape, up, down, left, right, backspace, clearLine
}

public enum TerminalShortcut: String, Codable, Sendable {
    case newSession = "/new"
    case quit = "/q"
    case write = "/w"
    case plan = "/plan"
    case compact = "/compact"
}

public struct TerminalContext: Equatable, Sendable {
    public let terminalTargetID: String
    public let workingDirectory: String
    public let displayTitle: String

    public init(terminalTargetID: String, workingDirectory: String, displayTitle: String) {
        self.terminalTargetID = terminalTargetID
        self.workingDirectory = workingDirectory
        self.displayTitle = displayTitle
    }
}

public protocol TerminalController: Sendable {
    func captureFocusedTerminal() async throws -> TerminalContext
    func focus(terminalTargetID: String) async throws
    func scroll(deltaY: Int, terminalTargetID: String) async throws
    func sendKey(_ key: TerminalKey, to terminalTargetID: String) async throws
    func sendShortcut(_ shortcut: TerminalShortcut, to terminalTargetID: String) async throws
}
