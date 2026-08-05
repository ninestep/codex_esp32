import CodexRemoteMac
import SwiftUI

struct InstallationDiagnosticsView: View {
    @ObservedObject var model: AppModel
    @State private var pendingRequest: SetupConfirmationRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.setupSnapshot.isMacReady ? "Mac 已准备就绪" : "安装配置尚未完成")
                        .font(.title2.bold())
                    Text("状态来自当前环境检查；重新打开时不会沿用伪状态。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("重新检查") {
                    Task { await model.refreshSetup() }
                }
                .disabled(model.isSetupBusy)
                Button(model.hasStartedAutomaticSetup ? "继续配置" : "开始自动配置") {
                    pendingRequest = .automatic
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isSetupBusy)
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(model.setupSnapshot.results) { result in
                        SetupCheckRow(result: result, isBusy: model.isSetupBusy) { action in
                            if action.requiresExplicitConfirmation {
                                pendingRequest = .single(action, result.item)
                            } else {
                                Task { await model.performSetupAction(action, for: result.item) }
                            }
                        }
                    }
                }
            }

            GroupBox("诊断日志") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if model.setupLog.isEmpty {
                            Text("暂无日志")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(model.setupLog.suffix(120)) { line in
                                Text("[\(line.level.displayName)] \(line.message)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(line.level.color)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 90, maxHeight: 150)
            }
        }
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
    }
}

struct SetupCheckRow: View {
    let result: SetupCheckResult
    let isBusy: Bool
    let onAction: (SetupAction) -> Void

    var body: some View {
        let presentation = result.state.presentation
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: presentation.symbol)
                .foregroundStyle(presentation.color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(result.item.displayName).fontWeight(.semibold)
                    Text(presentation.label)
                        .font(.caption)
                        .foregroundStyle(presentation.color)
                }
                Text(result.summary)
                    .foregroundStyle(.secondary)
                if let detail = result.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            if let action = result.availableActions.first {
                Button(action.displayName) { onAction(action) }
                    .disabled(isBusy || result.state == .checking || result.state == .configuring)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
    }
}

enum SetupConfirmationRequest: Identifiable {
    case automatic
    case single(SetupAction, SetupItem)

    var id: String {
        switch self {
        case .automatic: "automatic"
        case .single(let action, let item): "\(action)-\(item.rawValue)"
        }
    }

    var title: String {
        switch self {
        case .automatic: "确认运行自动配置"
        case .single(let action, _): "确认\(action.displayName)"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            "将按检查结果修改以下目标：\n• /Applications/Codex Remote.app\n• ~/.zshrc\n• ~/.codex-remote/bin/codex\n• ~/.codex/hooks.json\n\n流程会在需要系统授权或 /hooks 人工确认时暂停。BlackHole 缺失时，后续会单独提示并需另行确认 brew install --cask blackhole-2ch；本次自动配置不会安装。"
        case .single(let action, _):
            action.confirmationDetail
        }
    }

    var confirmButtonTitle: String {
        switch self {
        case .automatic: "开始自动配置"
        case .single(let action, _): action.displayName
        }
    }

    var isDestructive: Bool {
        if case .single(.restoreManagedConfiguration, _) = self { return true }
        return false
    }
}

extension SetupAction {
    var displayName: String {
        switch self {
        case .installApplication: "安装应用"
        case .installShimAndPath: "配置 PATH"
        case .installHooks: "配置 Hooks"
        case .confirmHooksTrust: "复查信任"
        case .installBlackHole: "安装 BlackHole"
        case .requestBluetooth: "检查蓝牙权限"
        case .requestMicrophone: "授权麦克风"
        case .requestAccessibility: "授权辅助功能"
        case .testHotkey: "测试快捷键"
        case .recheck: "重新检查"
        case .restoreManagedConfiguration: "恢复托管配置"
        }
    }

    var requiresExplicitConfirmation: Bool {
        switch self {
        case .installApplication, .installShimAndPath, .installHooks, .installBlackHole,
             .requestBluetooth, .requestMicrophone, .requestAccessibility,
             .testHotkey, .restoreManagedConfiguration:
            true
        case .confirmHooksTrust, .recheck:
            false
        }
    }

    var confirmationDetail: String {
        switch self {
        case .installApplication: "将安装或更新：/Applications/Codex Remote.app"
        case .installShimAndPath: "将修改：~/.zshrc\n将创建：~/.codex-remote/bin/codex"
        case .installHooks: "将合并 Codex Remote hooks：~/.codex/hooks.json"
        case .installBlackHole: "将执行：brew install --cask blackhole-2ch"
        case .requestBluetooth: "将检查并由 macOS 请求 Codex Remote 的蓝牙权限。"
        case .requestMicrophone: "将由 macOS 请求 Codex Remote 的麦克风权限。"
        case .requestAccessibility: "将由 macOS 请求 Codex Remote 的辅助功能权限。"
        case .testHotkey: "三秒倒计时后将发送一次当前豆包快捷键的 key-down/key-up 事件。"
        case .restoreManagedConfiguration: "将从 ~/.zshrc、~/.codex/hooks.json 和 ~/.codex-remote/bin/codex 中移除仅由 Codex Remote 管理的内容。"
        case .confirmHooksTrust, .recheck: "只读取并复查当前状态。"
        }
    }
}

extension SetupItem {
    var displayName: String {
        switch self {
        case .applicationLocation: "应用安装位置"
        case .ghostty: "Ghostty"
        case .codexCLI: "Codex CLI"
        case .shim: "Codex 命令桥接"
        case .shellPath: "Shell PATH"
        case .hooksConfiguration: "Codex Hooks"
        case .hooksTrust: "Hooks 信任"
        case .blackHole: "BlackHole 2ch"
        case .bluetoothPermission: "蓝牙权限"
        case .microphonePermission: "麦克风权限"
        case .accessibilityPermission: "辅助功能权限"
        case .doubaoHotkey: "豆包语音快捷键"
        case .localIPC: "本地 IPC"
        case .esp32Device: "ESP32 设备"
        }
    }
}

private struct SetupStatePresentation {
    let symbol: String
    let label: String
    let color: Color
}

private extension SetupState {
    var presentation: SetupStatePresentation {
        switch self {
        case .ready: .init(symbol: "checkmark.circle.fill", label: "已就绪", color: .green)
        case .needsConfiguration: .init(symbol: "wrench.and.screwdriver.fill", label: "需要配置", color: .orange)
        case .waitingForUser: .init(symbol: "person.crop.circle.badge.clock", label: "等待用户", color: .orange)
        case .failed: .init(symbol: "xmark.octagon.fill", label: "配置失败", color: .red)
        case .checking: .init(symbol: "clock.arrow.circlepath", label: "正在检查", color: .gray)
        case .configuring: .init(symbol: "gearshape.2.fill", label: "正在配置", color: .blue)
        case .notApplicable: .init(symbol: "minus.circle", label: "不适用", color: .gray)
        }
    }
}

private extension SetupLogLevel {
    var displayName: String {
        switch self {
        case .info: "信息"
        case .warning: "警告"
        case .error: "错误"
        }
    }

    var color: Color {
        switch self {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}
