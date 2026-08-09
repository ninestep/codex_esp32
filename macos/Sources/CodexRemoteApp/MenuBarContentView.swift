import CodexRemoteCore
import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusRow("本地服务", model.helperStatus)
            statusRow("设备", model.bluetoothStatusText)
            statusRow("电量", model.batteryText)
            statusRow("语音", model.audioReadinessText)

            Divider()

            if model.snapshot.sessions.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Codex Micro 增强模式")
                    Text("实体长按使用设备麦克风和豆包语音识别")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(model.snapshot.sessions, id: \.remoteSessionID) { session in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(color(for: session.state))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(session.displayTitle)
                            Text(session.workingDirectoryLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Divider()
            if !model.isEnhancedMode && !model.setupSnapshot.isMacReady {
                Button {
                    model.openSetupAssistant()
                } label: {
                    Label("完成安装配置…", systemImage: "exclamationmark.triangle.fill")
                }
            }
            SettingsLink { Text("设置…") }
            Button("退出") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 330)
    }

    private func statusRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    private func color(for state: RemoteSessionState) -> Color {
        switch state {
        case .idle: .white
        case .working: .blue
        case .completeUnread: .green
        case .requiresInput: .orange
        case .error: .red
        case .offline: .gray
        }
    }
}
