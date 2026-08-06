import CodexRemoteMac
import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var isShowingCleanupConfirmation = false

    var body: some View {
        TabView {
            generalSettings
                .tabItem { Label("常规", systemImage: "gearshape") }
            InstallationDiagnosticsView(model: model)
                .padding(20)
                .tabItem { Label("安装与诊断", systemImage: "stethoscope") }
        }
        .frame(width: 720, height: 620)
    }

    private var generalSettings: some View {
        Form {
            Section("连接") {
                TextField("本地 Socket", text: $model.settings.socketPath)
                    .textFieldStyle(.roundedBorder)
                Toggle("自动重新连接 BLE 设备", isOn: $model.settings.automaticBLEReconnect)
            }

            Section("Codex CLI") {
                LabeledContent("可执行文件") {
                    HStack(spacing: 8) {
                        TextField("/path/to/codex", text: $model.settings.codexCLIPath)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            chooseCodexCLI()
                        } label: {
                            Image(systemName: "folder")
                        }
                        .help("选择 Codex CLI 可执行文件")
                    }
                }
                Text("留空时自动探测 Codex CLI；填写后只使用指定路径。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !model.isCodexCLIPathInputValid {
                    Label("请输入绝对路径，或清空后使用自动探测。", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("豆包语音输入") {
                LabeledContent("快捷键") {
                    HotkeyRecorderField(value: $model.settings.doubaoHotkey)
                }
                Text("点击录制框后，直接按住豆包中配置的组合键（建议 ⌘⌥）；全部松开后自动记录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !model.settings.doubaoHotkey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   HotkeyParser().parse(model.settings.doubaoHotkey) == nil {
                    Label("快捷键格式无效；请重新录制至少两个 Command、Option、Control 修饰键。", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Picker("触发模式", selection: $model.settings.hotkeyMode) {
                    Text("按住型").tag(HotkeyTriggerMode.hold)
                    Text("切换型").tag(HotkeyTriggerMode.toggle)
                }
                .disabled(holdModeRequired)
                if holdModeRequired {
                    Text("纯修饰键组合使用按住型：设备按下时按顺序发送，松开时反向释放。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(model.audioReadinessText)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("测试豆包快捷键") {
                        Task { await model.testDoubaoHotkey() }
                    }
                    .disabled(
                        model.isSetupBusy
                            || HotkeyParser().parse(model.settings.doubaoHotkey) == nil
                    )
                    Text(model.hotkeyTestState.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("授权辅助功能…") { model.requestAccessibilityPermission() }
                    .disabled(model.isSetupBusy)
                Text("Codex CLI 路径和快捷键保存后立即生效；Socket 设置将在下次启动时生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let message = model.settingsSaveMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(message.contains("无效") ? .red : .secondary)
                }
            }

            Section("维护") {
                Text("移除 Codex Remote 写入的 Shell PATH、命令桥接和 Codex Hooks。不会删除 App、Codex CLI、BlackHole 或 macOS 权限。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("清理 Codex Remote 配置…", role: .destructive) {
                    isShowingCleanupConfirmation = true
                }
                .disabled(model.isSetupBusy)
                if let message = model.managedConfigurationCleanupMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(message.contains("失败") ? .red : .secondary)
                }
            }

            HStack {
                Spacer()
                Button("保存") { model.saveSettings() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isDoubaoHotkeyInputValid || !model.isCodexCLIPathInputValid)
            }
        }
        .padding(20)
        .alert("清理 Codex Remote 配置？", isPresented: $isShowingCleanupConfirmation) {
            Button("清理配置", role: .destructive) {
                Task {
                    await model.performSetupAction(.restoreManagedConfiguration, for: .localIPC)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将从 ~/.zshrc、~/.codex/hooks.json 和 ~/.codex-remote/bin/codex 中移除仅由 Codex Remote 管理的内容。此操作不会自动重新配置。")
        }
    }

    private var holdModeRequired: Bool {
        HotkeyParser().parse(model.settings.doubaoHotkey)?.requiresHoldMode == true
    }

    private func chooseCodexCLI() {
        let panel = NSOpenPanel()
        panel.title = "选择 Codex CLI"
        panel.prompt = "选择"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.settings.codexCLIPath = url.path
    }
}
