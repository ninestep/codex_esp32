import Foundation

public enum StopReason: Equatable, Sendable {
    case normal(String)
    case blockingInput(String)
}

public enum SessionEvent: Equatable, Sendable {
    case sessionStarted
    case userPromptSubmitted
    case permissionRequested(String)
    case structuredWaiting(String)
    case stopped(StopReason)
    case detailViewed
    case failed(String)
    case disconnected(String)
}

public struct SessionStateResult: Equatable, Sendable {
    public let state: RemoteSessionState
    public let statusDetail: String
    public let unread: Bool
    public let updatedAt: Date
}
