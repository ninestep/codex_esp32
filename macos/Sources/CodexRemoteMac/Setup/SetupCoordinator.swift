import Foundation

public protocol SetupInspecting: Sendable {
    func inspect() async -> [SetupCheckResult]
}

public protocol SetupExecuting: Sendable {
    func perform(_ action: SetupAction, for item: SetupItem) async throws
}

public actor SetupCoordinator {
    public private(set) var snapshot: SetupSnapshot

    private let inspector: any SetupInspecting
    private let executor: any SetupExecuting
    private var isBusy = false

    public init(
        inspector: any SetupInspecting,
        executor: any SetupExecuting,
        initialSnapshot: SetupSnapshot = SetupSnapshot()
    ) {
        self.inspector = inspector
        self.executor = executor
        self.snapshot = initialSnapshot
    }

    @discardableResult
    public func runAll() async -> SetupOperationOutcome {
        guard beginOperation() else {
            return .rejected(.busy)
        }
        defer { finishOperation() }

        await runAutomationUnlocked(inspectFirst: true)
        return .completed
    }

    @discardableResult
    public func resumeAfterUserAction(_ action: SetupAction) async -> SetupOperationOutcome {
        guard beginOperation() else {
            return .rejected(.busy)
        }
        defer { finishOperation() }

        switch resolveItem(for: action) {
        case .success(let item):
            return await resumeAfterUserActionUnlocked(action, for: item)
        case .failure(let error):
            return .rejected(error)
        }
    }

    @discardableResult
    public func resumeAfterUserAction(_ action: SetupAction, for item: SetupItem) async -> SetupOperationOutcome {
        guard beginOperation() else {
            return .rejected(.busy)
        }
        defer { finishOperation() }

        return await resumeAfterUserActionUnlocked(action, for: item)
    }

    @discardableResult
    public func perform(_ action: SetupAction) async -> SetupOperationOutcome {
        guard beginOperation() else {
            return .rejected(.busy)
        }
        defer { finishOperation() }

        switch resolveItem(for: action) {
        case .success(let item):
            return await performUnlocked(action, for: item)
        case .failure(let error):
            return .rejected(error)
        }
    }

    @discardableResult
    public func perform(_ action: SetupAction, for item: SetupItem) async -> SetupOperationOutcome {
        guard beginOperation() else {
            return .rejected(.busy)
        }
        defer { finishOperation() }

        return await performUnlocked(action, for: item)
    }

    @discardableResult
    public func refresh() async -> SetupOperationOutcome {
        guard beginOperation() else {
            return .rejected(.busy)
        }
        defer { finishOperation() }

        await refreshUnlocked()
        return .completed
    }

    private func performUnlocked(_ action: SetupAction, for item: SetupItem) async -> SetupOperationOutcome {
        guard canPerform(action, for: item) else {
            return .rejected(.invalidTargetAction)
        }

        guard await executeUnlocked(action, for: item) else {
            return .completed
        }

        await refreshUnlocked()
        return .completed
    }

    private func resumeAfterUserActionUnlocked(
        _ action: SetupAction,
        for item: SetupItem
    ) async -> SetupOperationOutcome {
        guard canResumeAfterUserAction(action, for: item) else {
            return .rejected(.invalidTargetAction)
        }

        guard await executeUnlocked(action, for: item) else {
            return .completed
        }

        await refreshUnlocked()
        await runAutomationUnlocked(inspectFirst: false)
        return .completed
    }

    private func refreshUnlocked() async {
        snapshot = SetupSnapshot(results: await inspector.inspect())
    }

    private func runAutomationUnlocked(inspectFirst: Bool) async {
        if inspectFirst {
            await refreshUnlocked()
        }

        while let result = nextBlockingResult() {
            guard result.state == .needsConfiguration else {
                return
            }

            let action = result.availableActions.first ?? SetupAction.defaultAction(for: result.item)
            guard let action else {
                return
            }

            // BlackHole is an external package install and always requires its own
            // explicit confirmation after the general automatic-setup confirmation.
            guard action != .installBlackHole else {
                return
            }

            guard await executeUnlocked(action, for: result.item) else {
                return
            }

            await refreshUnlocked()
            if let refreshed = snapshot.result(for: result.item),
               refreshed.state == .needsConfiguration,
               (refreshed.availableActions.first ?? SetupAction.defaultAction(for: refreshed.item)) == action {
                markFailed(item: result.item, error: SetupExecutionError.verificationFailed)
                return
            }
        }
    }

    private func nextBlockingResult() -> SetupCheckResult? {
        for item in Self.dependencyOrder {
            guard let result = snapshot.result(for: item), !result.state.isReadyState else {
                continue
            }
            return result
        }
        return nil
    }

    @discardableResult
    private func executeUnlocked(_ action: SetupAction, for item: SetupItem) async -> Bool {
        do {
            try await executor.perform(action, for: item)
            return true
        } catch {
            markFailed(item: item, error: error)
            return false
        }
    }

    private func markFailed(item: SetupItem, error: any Error) {
        let message: String
        if let setupError = error as? SetupExecutionError {
            message = setupError.userMessage
        } else {
            message = "未能完成配置，请重试"
        }

        let failedResult = SetupCheckResult(
            item: item,
            state: .failed,
            summary: "配置失败",
            detail: message
        )
        var replaced = false
        let results = snapshot.results.map { result in
            if result.item == item {
                replaced = true
                return failedResult
            }
            return result
        }
        snapshot = SetupSnapshot(results: replaced ? results : snapshot.results + [failedResult])
    }

    private func resolveItem(for action: SetupAction) -> Result<SetupItem, SetupExecutionError> {
        let matches = snapshot.results.filter { result in
            result.availableActions.contains(action)
        }
        if matches.isEmpty {
            return .failure(.missingTarget)
        }
        if matches.count > 1 {
            return .failure(.ambiguousAction)
        }
        return .success(matches[0].item)
    }

    private func canPerform(_ action: SetupAction, for item: SetupItem) -> Bool {
        guard let result = snapshot.result(for: item) else {
            return false
        }

        if result.availableActions.contains(action) {
            return true
        }

        return result.state == .needsConfiguration && SetupAction.defaultAction(for: item) == action
    }

    private func canResumeAfterUserAction(_ action: SetupAction, for item: SetupItem) -> Bool {
        guard let result = snapshot.result(for: item) else {
            return false
        }

        return result.state == .waitingForUser && result.availableActions.contains(action)
    }

    private func beginOperation() -> Bool {
        guard !isBusy else {
            return false
        }
        isBusy = true
        return true
    }

    private func finishOperation() {
        isBusy = false
    }

    private static let dependencyOrder: [SetupItem] = [
        .applicationLocation,
        .ghostty,
        .codexCLI,
        .shim,
        .shellPath,
        .hooksConfiguration,
        .hooksTrust,
        .blackHole,
        .bluetoothPermission,
        .microphonePermission,
        .accessibilityPermission,
        .doubaoHotkey,
        .localIPC,
    ]
}
