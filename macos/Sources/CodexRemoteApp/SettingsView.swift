import CodexRemoteMac
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

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
                Text("快捷键保存后立即生效；Socket 设置将在下次启动时生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let message = model.settingsSaveMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(message.contains("无效") ? .red : .secondary)
                }
            }

            HStack {
                Spacer()
                Button("保存") { model.saveSettings() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isDoubaoHotkeyInputValid)
            }
        }
        .padding(20)
    }

    private var holdModeRequired: Bool {
        HotkeyParser().parse(model.settings.doubaoHotkey)?.requiresHoldMode == true
    }
}
