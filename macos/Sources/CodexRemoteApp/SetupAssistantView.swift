import CodexRemoteMac
import SwiftUI

struct SetupAssistantView: View {
    @ObservedObject var model: AppModel
    let onSetUpLater: () -> Void

    @State private var stage: SetupAssistantStage = .foundation
    @State private var pendingRequest: SetupConfirmationRequest?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Codex Remote")
                    .font(.title2.bold())
                    .padding(.bottom, 12)
                ForEach(SetupAssistantStage.allCases) { candidate in
                    Button {
                        stage = candidate
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: candidate.symbol)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.title).fontWeight(.semibold)
                                Text(candidate.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(9)
                        .background(
                            stage == candidate ? Color.accentColor.opacity(0.13) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button("稍后设置") { onSetUpLater() }
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(width: 220)
            .background(.thinMaterial)

            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(stage.title).font(.largeTitle.bold())
                        Text(stage.description).foregroundStyle(.secondary)
                    }
                    Spacer()
                    readinessBadge
                }

                ProgressView(value: readinessProgress)
                    .accessibilityLabel("Mac 配置就绪进度")
                    .accessibilityValue("\(Int(readinessProgress * 100))%")

                ScrollView {
                    LazyVStack(spacing: 8) {
                        let results = visibleResults
                        if results.isEmpty {
                            ContentUnavailableView("正在检查", systemImage: "clock.arrow.circlepath")
                        } else {
                            ForEach(results) { result in
                                SetupCheckRow(result: result, isBusy: model.isSetupBusy) { action in
                                    if action.requiresExplicitConfirmation {
                                        pendingRequest = .single(action, result.item)
                                    } else {
                                        Task { await model.performSetupAction(action, for: result.item) }
                                    }
                                }
                            }
                            if stage == .testing {
                                Divider().padding(.vertical, 6)
                                Text("综合测试清单")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                ForEach(functionalTestResults) { result in
                                    FunctionalTestRow(result: result)
                                }
                            }
                        }
                    }
                }

                if stage == .automatic || stage == .foundation {
                    HStack {
                        Spacer()
                        Button(primaryConfigurationButtonTitle) {
                            if model.setupSnapshot.results.isEmpty {
                                Task { await model.refreshSetup() }
                            } else {
                                pendingRequest = .automatic
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isSetupBusy)
                    }
                } else if stage == .testing {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(model.audioReadinessText, systemImage: "waveform")
                        Text("语音由 ESP32 PTT 直接发送到豆包识别；松开设备按键后，将结果写入 ChatGPT 输入框。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        Text(model.setupSnapshot.isMacReady ? "Mac 侧配置已完成；ESP32 状态单独展示。" : "仍有必需项未就绪，请返回对应阶段继续。")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("完成") { onSetUpLater() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.setupSnapshot.isMacReady)
                    }
                }
            }
            .padding(24)
        }
        .frame(minWidth: 860, minHeight: 580)
        .confirmationDialog(
            pendingRequest?.title ?? "确认配置",
            isPresented: Binding(
                get: { pendingRequest != nil },
                set: { if !$0 { pendingRequest = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingRequest
        ) { request in
            Button(request.confirmButtonTitle, role: request.isDestructive ? .destructive : nil) {
                pendingRequest = nil
                Task {
                    switch request {
                    case .automatic:
                        stage = .automatic
                        await model.runAutomaticSetup()
                    case .single(let action, let item):
                        await model.performSetupAction(action, for: item)
                    }
                }
            }
            Button("取消", role: .cancel) { pendingRequest = nil }
        } message: { request in
            Text(request.detail)
        }
        .task {
            await model.refreshSetup()
        }
    }

    private var readinessBadge: some View {
        Label(
            model.setupSnapshot.isMacReady ? "Mac 已准备就绪" : "需要继续配置",
            systemImage: model.setupSnapshot.isMacReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
        )
        .foregroundStyle(model.setupSnapshot.isMacReady ? .green : .orange)
    }

    private var primaryConfigurationButtonTitle: String {
        if model.setupSnapshot.results.isEmpty { return "开始检查" }
        return model.hasStartedAutomaticSetup ? "继续配置" : "开始自动配置"
    }

    private var readinessProgress: Double {
        let required = model.setupSnapshot.results.filter(\.item.blocksMacReadiness)
        guard !required.isEmpty else { return 0 }
        let ready = required.filter { $0.state == .ready || $0.state == .notApplicable }
        return Double(ready.count) / Double(required.count)
    }

    private var visibleResults: [SetupCheckResult] {
        let allowed = Set(stage.items)
        return model.setupSnapshot.results.filter { allowed.contains($0.item) }
    }

    private var functionalTestResults: [FunctionalTestResult] {
        let hasSession = !model.snapshot.sessions.isEmpty
        let deviceConnected: Bool
        if case .ready = model.snapshot.transportState {
            deviceConnected = true
        } else {
            deviceConnected = false
        }
        return [
            FunctionalTestResult(
                id: "session-discovery",
                title: "会话发现",
                state: hasSession ? .verified : .waiting,
                detail: hasSession ? "已发现当前 Codex 会话" : "等待 Codex 会话"
            ),
            .manual("ghostty-focus", "Ghostty 聚焦", prerequisiteReady: hasSession),
            .manual("scroll", "页面滚动", prerequisiteReady: hasSession),
            .manual("enter", "Enter 操作", prerequisiteReady: hasSession),
            .manual("escape", "Esc 操作", prerequisiteReady: hasSession),
            FunctionalTestResult(
                id: "audio",
                title: "设备音频到豆包语音识别",
                state: model.audioStatus == .ready ? .manual : .waiting,
                detail: model.audioStatus == .ready ? "需使用真实设备说话并检查 ChatGPT 输入框" : "等待豆包登录"
            ),
            FunctionalTestResult(
                id: "ble",
                title: "BLE 控制链路",
                state: deviceConnected ? .manual : .waiting,
                detail: deviceConnected ? "设备已连接，仍需人工验证控制闭环" : "等待设备"
            ),
        ]
    }
}

private enum FunctionalTestState {
    case verified, waiting, manual

    var symbol: String {
        switch self {
        case .verified: "checkmark.circle.fill"
        case .waiting: "clock.fill"
        case .manual: "person.crop.circle.badge.questionmark"
        }
    }

    var label: String {
        switch self {
        case .verified: "已有证据"
        case .waiting: "等待条件"
        case .manual: "需人工验证"
        }
    }

    var color: Color {
        switch self {
        case .verified: .green
        case .waiting: .gray
        case .manual: .orange
        }
    }
}

private struct FunctionalTestResult: Identifiable {
    let id: String
    let title: String
    let state: FunctionalTestState
    let detail: String

    static func manual(_ id: String, _ title: String, prerequisiteReady: Bool) -> FunctionalTestResult {
        FunctionalTestResult(
            id: id,
            title: title,
            state: prerequisiteReady ? .manual : .waiting,
            detail: prerequisiteReady ? "需在真实 Ghostty 会话中人工验证" : "等待 Codex 会话"
        )
    }
}

private struct FunctionalTestRow: View {
    let result: FunctionalTestResult

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: result.state.symbol)
                .foregroundStyle(result.state.color)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(result.title).fontWeight(.semibold)
                    Text(result.state.label)
                        .font(.caption)
                        .foregroundStyle(result.state.color)
                }
                Text(result.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(9)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}

private enum SetupAssistantStage: String, CaseIterable, Identifiable {
    case foundation
    case automatic
    case testing
    case complete

    var id: String { rawValue }

    var title: String {
        switch self {
        case .foundation: "基础环境"
        case .automatic: "自动配置"
        case .testing: "功能测试"
        case .complete: "完成"
        }
    }

    var subtitle: String {
        switch self {
        case .foundation: "应用、Ghostty、Codex"
        case .automatic: "PATH、Hooks、权限"
        case .testing: "IPC、语音、设备"
        case .complete: "就绪状态与剩余验收"
        }
    }

    var description: String {
        switch self {
        case .foundation: "确认运行 Codex Remote 所需的基础软件与稳定安装位置。"
        case .automatic: "逐项配置命令桥接、Codex hooks 和 macOS 权限。"
        case .testing: "检查本地 IPC、豆包语音识别状态，并等待 ESP32 设备。"
        case .complete: "Mac 就绪状态与 ESP32 真机验收分开计算，不会把等待设备误报为失败。"
        }
    }

    var symbol: String {
        switch self {
        case .foundation: "shippingbox.fill"
        case .automatic: "wand.and.stars"
        case .testing: "checklist"
        case .complete: "checkmark.seal.fill"
        }
    }

    var items: [SetupItem] {
        switch self {
        case .foundation:
            [.applicationLocation, .ghostty, .codexCLI]
        case .automatic:
            [.shim, .shellPath, .hooksConfiguration, .hooksTrust,
             .bluetoothPermission, .microphonePermission, .accessibilityPermission]
        case .testing:
            [.localIPC, .esp32Device]
        case .complete:
            SetupItem.allCases
        }
    }
}
