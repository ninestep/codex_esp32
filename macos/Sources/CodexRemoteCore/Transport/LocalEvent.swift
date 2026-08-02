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

    private enum CodingKeys: String, CodingKey {
        case type
        case payload
    }

    private enum EventType: String, Codable {
        case launchRegistered
        case hookReceived
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        switch try container.decode(EventType.self, forKey: .type) {
        case .launchRegistered:
            self = .launchRegistered(try container.decode(LaunchRegistration.self, forKey: .payload))
        case .hookReceived:
            self = .hookReceived(try container.decode(HookPayload.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .launchRegistered(let registration):
            try container.encode(EventType.launchRegistered, forKey: .type)
            try container.encode(registration, forKey: .payload)
        case .hookReceived(let payload):
            try container.encode(EventType.hookReceived, forKey: .type)
            try container.encode(payload, forKey: .payload)
        }
    }
}
