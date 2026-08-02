import Foundation

public enum WaitingInputClassification: Equatable, Sendable {
    case blocking(String)
    case normal(String)
}

public struct WaitingInputClassifier: Sendable {
    private let replySignals = ["请回复", "请确认", "需要你选择", "请选择", "请提供", "请授权"]
    private let pauseSignals = ["我会继续", "才能继续", "后继续", "再继续", "之后继续"]
    private let optionalSignals = ["如果你愿意", "如有需要", "也可以继续优化"]

    public init() {}

    public func classify(_ text: String) -> WaitingInputClassification {
        let summary = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        let optional = optionalSignals.contains { text.contains($0) }
        let asksForReply = replySignals.contains { text.contains($0) }
        let pausesWork = pauseSignals.contains { text.contains($0) }

        return asksForReply && pausesWork && !optional ? .blocking(summary) : .normal(summary)
    }
}
