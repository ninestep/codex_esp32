import XCTest
@testable import CodexRemoteMac

final class SetupAppSupportTests: XCTestCase {
    func testAutomaticSetupProgressStartsOnlyWhenBeginIsCalled() {
        var progress = AutomaticSetupProgressState()

        XCTAssertFalse(progress.hasStarted)

        progress.begin()

        XCTAssertTrue(progress.hasStarted)
    }

    func testOperationLogClassifiesFailedSnapshotAsErrorWithDetail() {
        let snapshot = SetupSnapshot(results: [
            SetupCheckResult(
                item: .hooksConfiguration,
                state: .failed,
                summary: "配置失败",
                detail: "hooks JSON 无效"
            ),
        ])

        let result = SetupOperationLogClassifier.classify(
            operation: "配置 Hooks",
            outcome: .completed,
            snapshot: snapshot,
            targetItem: .hooksConfiguration
        )

        XCTAssertEqual(result.level, .error)
        XCTAssertEqual(result.message, "配置 Hooks 失败：hooks JSON 无效")
    }

    func testCompletedOutcomeOnlySaysFlowEndedAfterReinspection() {
        let result = SetupOperationLogClassifier.classify(
            operation: "继续配置",
            outcome: .completed,
            snapshot: SetupSnapshot(results: [
                SetupCheckResult(item: .hooksTrust, state: .waitingForUser, summary: "等待信任"),
            ]),
            targetItem: nil
        )

        XCTAssertEqual(result.level, .info)
        XCTAssertEqual(result.message, "继续配置流程已结束，已按当前环境复查状态")
        XCTAssertFalse(result.message.contains("成功"))
    }

    func testTargetReadyIgnoresUnrelatedFailedItemWhenClassifyingSingleAction() {
        let snapshot = SetupSnapshot(results: [
            SetupCheckResult(item: .shim, state: .ready, summary: "Shim 已安装"),
            SetupCheckResult(
                item: .blackHole,
                state: .failed,
                summary: "BlackHole 安装失败",
                detail: "旧失败"
            ),
        ])

        let result = SetupOperationLogClassifier.classify(
            operation: "配置命令桥接与 PATH",
            outcome: .completed,
            snapshot: snapshot,
            targetItem: .shim
        )

        XCTAssertEqual(result.level, .info)
        XCTAssertFalse(result.message.contains("失败"))
    }

    func testRejectedOutcomeUsesErrorMessage() {
        let result = SetupOperationLogClassifier.classify(
            operation: "自动配置",
            outcome: .rejected(.busy),
            snapshot: SetupSnapshot(),
            targetItem: nil
        )

        XCTAssertEqual(result.level, .error)
        XCTAssertTrue(result.message.contains(SetupExecutionError.busy.userMessage))
    }

    func testActivityStateRejectsReentryAndDefersServiceRebuild() {
        var state = SetupActivityState()

        XCTAssertTrue(state.begin())
        XCTAssertFalse(state.begin())
        XCTAssertFalse(state.requestServiceRebuild())
        XCTAssertTrue(state.finish())
        XCTAssertFalse(state.isBusy)
        XCTAssertTrue(state.requestServiceRebuild())
    }
}
