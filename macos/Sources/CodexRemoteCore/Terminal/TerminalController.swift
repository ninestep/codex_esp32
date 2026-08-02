public enum TerminalKey: String, Codable, Sendable {
    case enter, escape
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
}
