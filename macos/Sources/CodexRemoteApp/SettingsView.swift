import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Codex Remote 设置")
                        .font(.title2.weight(.semibold))
                    Text("管理 Codex Micro 的连接和语音输入。")
                        .foregroundStyle(.secondary)
                }

                settingsSection("设备连接", systemImage: "dot.radiowaves.left.and.right") {
                    statusRow(
                        title: "Codex Micro",
                        value: model.bluetoothStatusText,
                        isReady: model.isDeviceConnected
                    )
                    LabeledContent("电量", value: model.batteryText)
                    Text("App 会自动查找并重新连接附近的设备。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                settingsSection("语音识别", systemImage: "waveform") {
                    statusRow(
                        title: "当前状态",
                        value: model.audioReadinessText,
                        isReady: model.isSpeechInputReady
                    )

                    HStack(spacing: 10) {
                        Button(model.doubaoLoginState == .ready ? "重新登录豆包…" : "登录豆包…") {
                            model.showDoubaoLogin()
                        }
                        if model.doubaoLoginState == .ready {
                            Button("退出登录", role: .destructive) {
                                model.logoutDoubao()
                            }
                        }
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("辅助功能权限")
                            Text("用于把识别结果写入当前输入框。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.isAccessibilityTrusted {
                            Label("已授权", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Button("授权…") {
                                model.requestAccessibilityPermission()
                            }
                        }
                    }
                }

                settingsSection("实体按键", systemImage: "button.programmable") {
                    shortcutRow(action: "长按", result: "语音输入")
                    shortcutRow(action: "单击", result: "确认（Return）")
                    shortcutRow(action: "双击", result: "取消（Escape）")
                }
            }
            .padding(24)
        }
        .frame(width: 540, height: 520)
    }

    private func settingsSection<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.headline)
        }
    }

    private func statusRow(title: String, value: String, isReady: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer()
            Circle()
                .fill(isReady ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private func shortcutRow(action: String, result: String) -> some View {
        LabeledContent(action, value: result)
    }
}
