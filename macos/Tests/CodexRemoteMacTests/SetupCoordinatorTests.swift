import Foundation
import XCTest
@testable import CodexRemoteMac

final class SetupCoordinatorTests: XCTestCase {
    func testRunAllStopsBeforeBlackHoleAndNeverExecutesItAutomatically() async {
        let snapshot = makeSnapshot(overrides: [.blackHole: .needsConfiguration])
        let inspector = SetupInspectorSpy(snapshots: [snapshot])
        let executor = SetupExecutorSpy()
        let coordinator = SetupCoordinator(inspector: inspector, executor: executor)

        _ = await coordinator.runAll()

        let actions = await executor.actions()
        XCTAssertEqual(actions, [])
        let result = await coordinator.snapshot.result(for: .blackHole)
        XCTAssertEqual(result?.state, .needsConfiguration)
    }

    func testRunAllExecutesDependenciesInOrderAndStopsAtHooksTrustWaitingForUser() async {
        let inspector = SetupInspectorSpy(snapshots: [
            makeSnapshot(overrides: [.applicationLocation: .needsConfiguration]),
            makeSnapshot(
                overrides: [.ghostty: .needsConfiguration],
                actions: [.ghostty: [.installApplication]]
            ),
            makeSnapshot(
                overrides: [.codexCLI: .needsConfiguration],
                actions: [.codexCLI: [.installApplication]]
            ),
            makeSnapshot(overrides: [.shim: .needsConfiguration]),
            makeSnapshot(overrides: [.shellPath: .needsConfiguration]),
            makeSnapshot(overrides: [.hooksConfiguration: .needsConfiguration]),
            makeSnapshot(overrides: [.hooksTrust: .waitingForUser]),
        ])
        let executor = SetupExecutorSpy()
        let coordinator = SetupCoordinator(inspector: inspector, executor: executor)

        let outcome = await coordinator.runAll()

        let actions = await executor.actions()
        let snapshot = await coordinator.snapshot
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(actions, [
            RecordedSetupAction(item: .applicationLocation, action: .installApplication),
            RecordedSetupAction(item: .ghostty, action: .installApplication),
            RecordedSetupAction(item: .codexCLI, action: .installApplication),
            RecordedSetupAction(item: .shim, action: .installShimAndPath),
            RecordedSetupAction(item: .shellPath, action: .installShimAndPath),
            RecordedSetupAction(item: .hooksConfiguration, action: .installHooks),
        ])
        XCTAssertEqual(snapshot.result(for: .hooksTrust)?.state, .waitingForUser)
    }

    func testResumeAfterUserActionRechecksAndContinuesAutomation() async {
        let inspector = SetupInspectorSpy(snapshots: [
            makeSnapshot(
                overrides: [.hooksTrust: .waitingForUser],
                actions: [.hooksTrust: [.confirmHooksTrust]]
            ),
            makeSnapshot(overrides: [.blackHole: .needsConfiguration]),
            makeSnapshot(),
        ])
        let executor = SetupExecutorSpy()
        let coordinator = SetupCoordinator(inspector: inspector, executor: executor)

        let runOutcome = await coordinator.runAll()
        let resumeOutcome = await coordinator.resumeAfterUserAction(.confirmHooksTrust, for: .hooksTrust)

        let actions = await executor.actions()
        let snapshot = await coordinator.snapshot
        XCTAssertEqual(runOutcome, .completed)
        XCTAssertEqual(resumeOutcome, .completed)
        XCTAssertEqual(actions, [
            RecordedSetupAction(item: .hooksTrust, action: .confirmHooksTrust),
        ])
        XCTAssertEqual(snapshot.result(for: .blackHole)?.state, .needsConfiguration)
    }

    func testActionFailureMarksFailedResultAndDoesNotContinue() async {
        let inspector = SetupInspectorSpy(snapshots: [
            makeSnapshot(overrides: [.shim: .needsConfiguration]),
        ])
        let executor = SetupExecutorSpy(failingActions: [.installShimAndPath])
        let coordinator = SetupCoordinator(inspector: inspector, executor: executor)

        let outcome = await coordinator.runAll()

        let snapshot = await coordinator.snapshot
        let actions = await executor.actions()
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(actions, [
            RecordedSetupAction(item: .shim, action: .installShimAndPath),
        ])
        XCTAssertEqual(snapshot.result(for: .shim)?.state, .failed)
        XCTAssertEqual(snapshot.result(for: .shellPath)?.state, .ready)
    }

    func testRefreshOnlyInspectsWithoutExecutingActions() async {
        let inspector = SetupInspectorSpy(snapshots: [
            makeSnapshot(overrides: [.blackHole: .needsConfiguration]),
        ])
        let executor = SetupExecutorSpy()
        let coordinator = SetupCoordinator(inspector: inspector, executor: executor)

        let outcome = await coordinator.refresh()

        let actions = await executor.actions()
        let snapshot = await coordinator.snapshot
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(actions, [])
        XCTAssertEqual(snapshot.result(for: .blackHole)?.state, .needsConfiguration)
    }

    func testRestoreManagedConfigurationCanRunFromReadySnapshotAndOnlyRefreshes() async {
        let refreshedSnapshot = makeSnapshot(overrides: [
            .shim: .needsConfiguration,
            .shellPath: .needsConfiguration,
            .hooksConfiguration: .needsConfiguration,
        ])
        let inspector = SetupInspectorSpy(snapshots: [refreshedSnapshot])
        let executor = SetupExecutorSpy()
        let coordinator = SetupCoordinator(
            inspector: inspector,
            executor: executor,
            initialSnapshot: SetupSnapshot(results: makeSnapshot())
        )

        let outcome = await coordinator.perform(.restoreManagedConfiguration, for: .localIPC)

        let actions = await executor.actions()
        let snapshot = await coordinator.snapshot
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(actions, [
            RecordedSetupAction(item: .localIPC, action: .restoreManagedConfiguration),
        ])
        XCTAssertEqual(snapshot.result(for: .shim)?.state, .needsConfiguration)
        XCTAssertEqual(snapshot.result(for: .shellPath)?.state, .needsConfiguration)
        XCTAssertEqual(snapshot.result(for: .hooksConfiguration)?.state, .needsConfiguration)
    }

    func testCheckingAndConfiguringStatesDoNotExecuteAutomatically() async {
        for state in [SetupState.checking, .configuring] {
            let inspector = SetupInspectorSpy(snapshots: [
                makeSnapshot(
                    overrides: [.shim: state],
                    actions: [.shim: [.installShimAndPath]]
                ),
            ])
            let executor = SetupExecutorSpy()
            let coordinator = SetupCoordinator(inspector: inspector, executor: executor)

            let outcome = await coordinator.runAll()

            let actions = await executor.actions()
            let snapshot = await coordinator.snapshot
            XCTAssertEqual(outcome, .completed)
            XCTAssertEqual(actions, [])
            XCTAssertEqual(snapshot.result(for: .shim)?.state, state)
        }
    }

    func testRepeatedIdenticalAutomaticResultFailsAfterOneAttempt() async {
        let repeatedSnapshot = makeSnapshot(overrides: [.shim: .needsConfiguration])
        let inspector = SetupInspectorSpy(snapshots: [repeatedSnapshot, repeatedSnapshot])
        let executor = SetupExecutorSpy()
        let coordinator = SetupCoordinator(inspector: inspector, executor: executor)

        let outcome = await coordinator.runAll()

        let actions = await executor.actions()
        let snapshot = await coordinator.snapshot
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(actions, [
            RecordedSetupAction(item: .shim, action: .installShimAndPath),
        ])
        XCTAssertEqual(snapshot.result(for: .shim)?.state, .failed)
        XCTAssertEqual(snapshot.result(for: .shim)?.detail, SetupExecutionError.verificationFailed.userMessage)
    }

    func testConcurrentRunAllDoesNotReenterAndDuplicateSideEffects() async {
        let executor = ReentrantSetupExecutor()
        let inspector = CompletionAwareInspector(executor: executor)
        let coordinator = SetupCoordinator(inspector: inspector, executor: executor)
        await executor.setOnFirstPerform {
            await coordinator.runAll()
        }

        let outcome = await coordinator.runAll()

        let actions = await executor.actions()
        let nestedOutcomes = await executor.nestedOutcomes()
        let snapshot = await coordinator.snapshot
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(nestedOutcomes, [.rejected(.busy)])
        XCTAssertEqual(actions, [
            RecordedSetupAction(item: .shim, action: .installShimAndPath),
        ])
        XCTAssertTrue(snapshot.isMacReady)
    }

    func testUnknownExecutionErrorDoesNotLeakSecretDetail() async {
        let inspector = SetupInspectorSpy(snapshots: [
            makeSnapshot(overrides: [.shim: .needsConfiguration]),
        ])
        let executor = SetupExecutorSpy(failingActions: [.installShimAndPath: SecretExecutorError()])
        let coordinator = SetupCoordinator(inspector: inspector, executor: executor)

        let outcome = await coordinator.runAll()

        let detail = await coordinator.snapshot.result(for: .shim)?.detail
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(detail, "未能完成配置，请重试")
        XCTAssertFalse(detail?.contains("secret-token") ?? true)
        XCTAssertFalse(detail?.contains("token") ?? true)
    }

    func testBlackHoleCommandFailureShowsRedactedReasonAndRecoveryGuidance() async {
        let inspector = SetupInspectorSpy(snapshots: [
            makeSnapshot(overrides: [.blackHole: .needsConfiguration]),
        ])
        let executor = SetupExecutorSpy(failingActions: [
            .installBlackHole: BlackHoleInstallerError.commandFailed(
                exitCode: 1,
                stderrSummary: "sudo: a terminal is required"
            ),
        ])
        let coordinator = SetupCoordinator(
            inspector: inspector,
            executor: executor,
            initialSnapshot: SetupSnapshot(results: makeSnapshot(overrides: [.blackHole: .needsConfiguration]))
        )

        _ = await coordinator.perform(.installBlackHole, for: .blackHole)

        let detail = await coordinator.snapshot.result(for: .blackHole)?.detail
        XCTAssertTrue(detail?.contains("退出码 1") == true)
        XCTAssertTrue(detail?.contains("sudo: a terminal is required") == true)
        XCTAssertTrue(detail?.contains("brew install --cask blackhole-2ch") == true)
        XCTAssertTrue(detail?.contains("重启 Mac") == true)
    }

    func testGhosttyAndCodexCLINeedsConfigurationWithoutAvailableActionsDoNotUseDefaultInstallAction() async {
        for item in [SetupItem.ghostty, .codexCLI] {
            let inspector = SetupInspectorSpy(snapshots: [
                makeSnapshot(overrides: [item: .needsConfiguration]),
            ])
            let executor = SetupExecutorSpy()
            let coordinator = SetupCoordinator(inspector: inspector, executor: executor)

            let outcome = await coordinator.runAll()

            let actions = await executor.actions()
            let snapshot = await coordinator.snapshot
            XCTAssertEqual(outcome, .completed)
            XCTAssertEqual(actions, [])
            XCTAssertEqual(snapshot.result(for: item)?.state, .needsConfiguration)
        }
    }

    func testActionOnlyPerformRejectsMissingTargetWithoutExecuting() async {
        let executor = SetupExecutorSpy()
        let coordinator = SetupCoordinator(
            inspector: SetupInspectorSpy(snapshots: []),
            executor: executor,
            initialSnapshot: SetupSnapshot(results: makeSnapshot())
        )

        let outcome = await coordinator.perform(.confirmHooksTrust)

        let actions = await executor.actions()
        XCTAssertEqual(outcome, .rejected(.missingTarget))
        XCTAssertEqual(actions, [])
    }

    func testActionOnlyPerformRejectsAmbiguousTargetWithoutExecuting() async {
        let executor = SetupExecutorSpy()
        let coordinator = SetupCoordinator(
            inspector: SetupInspectorSpy(snapshots: []),
            executor: executor,
            initialSnapshot: SetupSnapshot(results: makeSnapshot(
                overrides: [.shim: .needsConfiguration, .shellPath: .needsConfiguration]
            ))
        )

        let outcome = await coordinator.perform(.installShimAndPath)

        let actions = await executor.actions()
        XCTAssertEqual(outcome, .rejected(.ambiguousAction))
        XCTAssertEqual(actions, [])
    }

    func testExplicitPerformRejectsInvalidItemActionWithoutExecutingOrChangingSnapshot() async {
        let initial = SetupSnapshot(results: makeSnapshot(overrides: [.shim: .needsConfiguration]))
        let executor = SetupExecutorSpy()
        let coordinator = SetupCoordinator(
            inspector: SetupInspectorSpy(snapshots: []),
            executor: executor,
            initialSnapshot: initial
        )

        let outcome = await coordinator.perform(.installHooks, for: .shim)

        let actions = await executor.actions()
        let snapshot = await coordinator.snapshot
        XCTAssertEqual(outcome, .rejected(.invalidTargetAction))
        XCTAssertEqual(actions, [])
        XCTAssertEqual(snapshot, initial)
    }

    func testResumeRejectsNonWaitingTargetWithoutExecutingOrChangingSnapshot() async {
        let initial = SetupSnapshot(results: makeSnapshot(
            overrides: [.hooksTrust: .needsConfiguration],
            actions: [.hooksTrust: [.confirmHooksTrust]]
        ))
        let executor = SetupExecutorSpy()
        let coordinator = SetupCoordinator(
            inspector: SetupInspectorSpy(snapshots: []),
            executor: executor,
            initialSnapshot: initial
        )

        let outcome = await coordinator.resumeAfterUserAction(.confirmHooksTrust, for: .hooksTrust)

        let actions = await executor.actions()
        let snapshot = await coordinator.snapshot
        XCTAssertEqual(outcome, .rejected(.invalidTargetAction))
        XCTAssertEqual(actions, [])
        XCTAssertEqual(snapshot, initial)
    }

    private func makeSnapshot(
        overrides: [SetupItem: SetupState] = [:],
        actions: [SetupItem: [SetupAction]] = [:]
    ) -> [SetupCheckResult] {
        SetupItem.allCases.map { item in
            SetupCheckResult(
                item: item,
                state: overrides[item] ?? .ready,
                summary: "\(item) \(overrides[item] ?? .ready)",
                availableActions: actions[item] ?? SetupAction.defaultAction(for: item).map { [$0] } ?? []
            )
        }
    }
}

private actor SetupInspectorSpy: SetupInspecting {
    private var snapshots: [[SetupCheckResult]]
    private var inspectionCount = 0

    init(snapshots: [[SetupCheckResult]]) {
        self.snapshots = snapshots
    }

    func inspect() -> [SetupCheckResult] {
        defer { inspectionCount += 1 }
        if inspectionCount < snapshots.count {
            return snapshots[inspectionCount]
        }
        return snapshots.last ?? []
    }
}

private actor SetupExecutorSpy: SetupExecuting {
    private var recordedActions: [RecordedSetupAction] = []
    private let failingActions: [SetupAction: any Error]

    init(failingActions: [SetupAction: any Error] = [:]) {
        self.failingActions = failingActions
    }

    init(failingActions: Set<SetupAction>) {
        self.failingActions = Dictionary(uniqueKeysWithValues: failingActions.map {
            ($0, SetupExecutionError.commandFailed)
        })
    }

    func perform(_ action: SetupAction, for item: SetupItem) throws {
        recordedActions.append(RecordedSetupAction(item: item, action: action))
        if let error = failingActions[action] {
            throw error
        }
    }

    func actions() -> [RecordedSetupAction] {
        recordedActions
    }
}

private actor ReentrantSetupExecutor: SetupExecuting {
    private var recordedActions: [RecordedSetupAction] = []
    private var completedCount = 0
    private var recordedNestedOutcomes: [SetupOperationOutcome] = []
    private var onFirstPerform: (@Sendable () async -> SetupOperationOutcome)?

    func setOnFirstPerform(_ callback: @escaping @Sendable () async -> SetupOperationOutcome) {
        onFirstPerform = callback
    }

    func perform(_ action: SetupAction, for item: SetupItem) async throws {
        recordedActions.append(RecordedSetupAction(item: item, action: action))
        if recordedActions.count == 1 {
            if let outcome = await onFirstPerform?() {
                recordedNestedOutcomes.append(outcome)
            }
        }
        completedCount += 1
    }

    func completions() -> Int {
        completedCount
    }

    func actions() -> [RecordedSetupAction] {
        recordedActions
    }

    func nestedOutcomes() -> [SetupOperationOutcome] {
        recordedNestedOutcomes
    }
}

private actor CompletionAwareInspector: SetupInspecting {
    private let executor: ReentrantSetupExecutor

    init(executor: ReentrantSetupExecutor) {
        self.executor = executor
    }

    func inspect() async -> [SetupCheckResult] {
        if await executor.completions() > 0 {
            return SetupItem.allCases.map { item in
                SetupCheckResult(item: item, state: .ready, summary: "\(item) ready")
            }
        }
        return SetupItem.allCases.map { item in
            SetupCheckResult(
                item: item,
                state: item == .shim ? .needsConfiguration : .ready,
                summary: "\(item)",
                availableActions: SetupAction.defaultAction(for: item).map { [$0] } ?? []
            )
        }
    }
}

private struct RecordedSetupAction: Equatable, Sendable {
    let item: SetupItem
    let action: SetupAction
}

private struct SecretExecutorError: Error, CustomStringConvertible {
    let description = "failed with token=secret-token"
}
