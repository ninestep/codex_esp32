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

    private enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case sessionID = "session_id"
        case launcherInstanceID = "launcher_instance_id"
        case message
        case lastAssistantMessage = "last_assistant_message"
        case env
    }

    private enum EnvironmentKeys: String, CodingKey {
        case launcherInstanceID = "CODEX_REMOTE_INSTANCE_ID"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.hookEventName = try container.decode(String.self, forKey: .hookEventName)
        self.sessionID = try container.decode(String.self, forKey: .sessionID)
        self.message = try container.decodeIfPresent(String.self, forKey: .message)
        self.lastAssistantMessage = try container.decodeIfPresent(String.self, forKey: .lastAssistantMessage)

        if let launcherInstanceID = try container.decodeIfPresent(String.self, forKey: .launcherInstanceID) {
            self.launcherInstanceID = launcherInstanceID
        } else if container.contains(.env) {
            let env = try container.nestedContainer(keyedBy: EnvironmentKeys.self, forKey: .env)
            self.launcherInstanceID = try env.decodeIfPresent(String.self, forKey: .launcherInstanceID)
        } else {
            self.launcherInstanceID = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hookEventName, forKey: .hookEventName)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encodeIfPresent(launcherInstanceID, forKey: .launcherInstanceID)
        try container.encodeIfPresent(message, forKey: .message)
        try container.encodeIfPresent(lastAssistantMessage, forKey: .lastAssistantMessage)
    }
}

public enum LocalEvent: Codable, Equatable, Sendable {
    case launchRegistered(LaunchRegistration)
    case hookReceived(HookPayload)
}
