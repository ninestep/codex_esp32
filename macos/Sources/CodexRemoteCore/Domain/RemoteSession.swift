import Foundation

public enum RemoteSessionState: String, Codable, Sendable {
    case idle, working, completeUnread, requiresInput, error, offline
}

public struct RemoteSession: Codable, Equatable, Sendable {
    public let remoteSessionID: String
    public let launcherInstanceID: String
    public var providerSessionID: String?
    public let terminalTargetID: String
    public var displayTitle: String
    public var workingDirectoryLabel: String
    public var state: RemoteSessionState
    public var statusDetail: String
    public var unread: Bool
    public var updatedAt: Date

    public init(
        remoteSessionID: String,
        launcherInstanceID: String,
        providerSessionID: String?,
        terminalTargetID: String,
        displayTitle: String,
        workingDirectoryLabel: String,
        state: RemoteSessionState = .idle,
        statusDetail: String = "",
        unread: Bool = false,
        updatedAt: Date = .now
    ) {
        self.remoteSessionID = remoteSessionID
        self.launcherInstanceID = launcherInstanceID
        self.providerSessionID = providerSessionID
        self.terminalTargetID = terminalTargetID
        self.displayTitle = displayTitle
        self.workingDirectoryLabel = workingDirectoryLabel
        self.state = state
        self.statusDetail = statusDetail
        self.unread = unread
        self.updatedAt = updatedAt
    }
}
