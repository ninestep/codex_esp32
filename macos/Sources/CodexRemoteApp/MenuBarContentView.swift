import AppKit
import CodexRemoteCore
import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Codex Remote")
                    .font(.headline)
                Text("Codex Micro 控制器")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                statusRow(
                    title: "设备",
                    value: model.bluetoothStatusText,
                    color: deviceStatusColor
                )
                statusRow(
                    title: "语音",
                    value: model.audioReadinessText,
                    color: model.isSpeechInputReady ? .green : .orange
                )
                HStack(spacing: 6) {
                    Image(systemName: "battery.100percent")
                        .foregroundStyle(.secondary)
                        .frame(width: 8)
                    Text("电量")
                    Text(model.batteryText)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))

            Label("长按说话 · 单击确认 · 双击取消", systemImage: "hand.tap")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            HStack(spacing: 16) {
                SettingsLink {
                    Label("设置…", systemImage: "gearshape")
                }
                Button("退出") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(12)
        .frame(width: 290)
    }

    private var deviceStatusColor: Color {
        switch model.snapshot.transportState {
        case .ready:
            .green
        case .scanning, .connecting, .discoveringService, .discoveringCharacteristics,
             .subscribingNotifications:
            .orange
        case .disconnected, .unavailable:
            .secondary
        }
    }

    private func statusRow(title: String, value: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
