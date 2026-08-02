import Foundation

public struct SessionStateReducer: Sendable {
    public init() {}

    public func reduce(
        _ event: SessionEvent,
        from current: RemoteSessionState,
        at date: Date = .now
    ) -> SessionStateResult {
        switch event {
        case .sessionStarted:
            return result(.idle, "会话已连接", false, date)
        case .userPromptSubmitted:
            return result(.working, "Codex 正在处理", false, date)
        case let .permissionRequested(detail), let .structuredWaiting(detail):
            return result(.requiresInput, detail, false, date)
        case let .stopped(.blockingInput(detail)):
            return result(.requiresInput, detail, false, date)
        case let .stopped(.normal(detail)):
            return result(.completeUnread, detail, true, date)
        case .detailViewed:
            return result(current == .completeUnread ? .idle : current, "", false, date)
        case let .failed(detail):
            return result(.error, detail, false, date)
        case let .disconnected(detail):
            return result(.offline, detail, false, date)
        }
    }

    private func result(
        _ state: RemoteSessionState,
        _ detail: String,
        _ unread: Bool,
        _ date: Date
    ) -> SessionStateResult {
        SessionStateResult(
            state: state,
            statusDetail: String(detail.prefix(120)),
            unread: unread,
            updatedAt: date
        )
    }
}
