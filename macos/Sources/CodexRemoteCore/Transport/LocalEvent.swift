import Foundation

public struct LaunchRegistration: Codable, Equatable, Sendable {
    public let launcherInstanceID: String
    public let terminalTargetID: String
    public let displayTitle: String
    public let workingDirectoryLabel: String

    public init(
        launcherInstanceID: String,
        terminalTargetID: String,
        displayTitle: String,
        workingDirectoryLabel: String
    ) {
        self.launcherInstanceID = launcherInstanceID
        self.terminalTargetID = terminalTargetID
        self.displayTitle = displayTitle
        self.workingDirectoryLabel = workingDirectoryLabel
    }
}

public struct HookPayload: Codable, Equatable, Sendable {
    public let hookEventName: String
    public let sessionID: String
    public let launcherInstanceID: String?
    public let message: String?
    public let lastAssistantMessage: String?

    public init(
        hookEventName: String,
        sessionID: String,
        launcherInstanceID: String?,
        message: String?,
        lastAssistantMessage: String?
    ) {
        self.hookEventName = hookEventName
        self.sessionID = sessionID
        self.launcherInstanceID = launcherInstanceID
        self.message = message
        self.lastAssistantMessage = lastAssistantMessage
    }
}

public enum LocalEvent: Codable, Equatable, Sendable {
    case launchRegistered(LaunchRegistration)
    case hookReceived(HookPayload)
}
