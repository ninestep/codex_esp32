import Foundation

public struct AutomaticSetupProgressState: Equatable, Sendable {
    public private(set) var hasStarted = false

    public init() {}

    public mutating func begin() {
        hasStarted = true
    }
}

public struct SetupOperationLogClassification: Equatable, Sendable {
    public let level: SetupLogLevel
    public let message: String

    public init(level: SetupLogLevel, message: String) {
        self.level = level
        self.message = message
    }
}

public enum SetupOperationLogClassifier {
    public static func classify(
        operation: String,
        outcome: SetupOperationOutcome,
        snapshot: SetupSnapshot,
        targetItem: SetupItem?
    ) -> SetupOperationLogClassification {
        if case .rejected(let error) = outcome {
            return SetupOperationLogClassification(
                level: .error,
                message: "\(operation)未执行：\(error.userMessage)"
            )
        }

        let failed: SetupCheckResult?
        if let targetItem {
            let target = snapshot.result(for: targetItem)
            failed = target?.state == .failed ? target : nil
        } else {
            failed = snapshot.results.first { $0.state == .failed }
        }

        if let failed {
            let reason = failed.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
            return SetupOperationLogClassification(
                level: .error,
                message: "\(operation) 失败：\((reason?.isEmpty == false ? reason : nil) ?? failed.summary)"
            )
        }

        return SetupOperationLogClassification(
            level: .info,
            message: "\(operation)流程已结束，已按当前环境复查状态"
        )
    }
}

public struct SetupActivityState: Equatable, Sendable {
    public private(set) var isBusy = false
    private var hasPendingServiceRebuild = false

    public init() {}

    public mutating func begin() -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        return true
    }

    public mutating func requestServiceRebuild() -> Bool {
        guard isBusy else { return true }
        hasPendingServiceRebuild = true
        return false
    }

    public mutating func finish() -> Bool {
        guard isBusy else { return false }
        isBusy = false
        let shouldRebuild = hasPendingServiceRebuild
        hasPendingServiceRebuild = false
        return shouldRebuild
    }
}
