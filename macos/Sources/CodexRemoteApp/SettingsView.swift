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
                TextField("快捷键（例如 ⌥Space）", text: $model.settings.doubaoHotkey)
                    .textFieldStyle(.roundedBorder)
                if !model.settings.doubaoHotkey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   HotkeyParser().parse(model.settings.doubaoHotkey) == nil {
                    Label("快捷键格式无效，需要至少一个修饰键和一个受支持按键。", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Picker("触发模式", selection: $model.settings.hotkeyMode) {
                    Text("按住型").tag(HotkeyTriggerMode.hold)
                    Text("切换型").tag(HotkeyTriggerMode.toggle)
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
}
