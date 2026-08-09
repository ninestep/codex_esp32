import AppKit
import CodexRemoteMac
import Combine
import SwiftUI

@MainActor
final class SpeechVisualizationWindowController: NSWindowController {
    private let model: AppModel
    private var activityObservation: AnyCancellable?

    init(model: AppModel) {
        self.model = model
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func start() {
        prepareWindowIfNeeded()
        activityObservation = model.$speechAudioActivity
            .removeDuplicates()
            .sink { [weak self] activity in
                self?.updateVisibility(for: activity)
            }
    }

    func stop() {
        activityObservation?.cancel()
        activityObservation = nil
        window?.orderOut(nil)
    }

    private func prepareWindowIfNeeded() {
        guard window == nil else { return }
        let contentView = SpeechVisualizationView(model: model)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 132),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = NSHostingController(rootView: contentView)
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        window = panel
    }

    private func updateVisibility(for activity: SpeechAudioActivity) {
        guard let panel = window else { return }
        guard activity.phase != .idle else {
            panel.orderOut(nil)
            return
        }
        position(panel)
        panel.orderFrontRegardless()
    }

    private func position(_ panel: NSWindow) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else { return }
        let origin = NSPoint(
            x: visibleFrame.midX - panel.frame.width / 2,
            y: visibleFrame.minY + 18
        )
        panel.setFrameOrigin(origin)
    }
}

private struct SpeechVisualizationView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let activity = model.speechAudioActivity
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.22), lineWidth: 0.8)
                }

            VoiceWaveEffect(activity: activity)
        }
        .padding(8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(activity.phase == .processing ? "正在识别语音" : "正在接收语音")
    }
}

private struct VoiceWaveEffect: View {
    let activity: SpeechAudioActivity

    private var visualLevel: CGFloat {
        activity.phase == .processing ? 0.08 : CGFloat(activity.level)
    }

    private var waveform: [Double] {
        activity.waveform.count == 21 ? activity.waveform : Array(repeating: 0, count: 21)
    }

    var body: some View {
        ZStack {
            ambientWave(width: 430, height: 112, opacity: 0.12, y: 66)
            ambientWave(width: 370, height: 92, opacity: 0.18, y: 72)

            HStack(spacing: 3) {
                ForEach(Array(waveform.enumerated()), id: \.offset) { index, value in
                    let centerWeight = 0.58 + 0.42 * (1 - abs(Double(index - 10)) / 10)
                    let height = 5 + CGFloat(value * centerWeight) * 37
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.12, green: 0.70, blue: 1), .blue],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 3.5, height: height)
                }
            }
            .frame(height: 46)
            .offset(y: -24)
            .shadow(color: Color.cyan.opacity(0.62), radius: 5)
        }
        .frame(width: 348, height: 108)
        .clipped()
        .animation(.interactiveSpring(response: 0.11, dampingFraction: 0.68), value: waveform)
        .animation(.easeOut(duration: 0.16), value: visualLevel)
    }

    private func ambientWave(width: CGFloat, height: CGFloat, opacity: Double, y: CGFloat) -> some View {
        Ellipse()
            .fill(
                RadialGradient(
                    colors: [
                        Color.cyan.opacity(opacity + Double(visualLevel) * 0.18),
                        Color.blue.opacity(opacity + Double(visualLevel) * 0.12),
                        Color.blue.opacity(0),
                    ],
                    center: .top,
                    startRadius: 2,
                    endRadius: width * 0.48
                )
            )
            .frame(
                width: width + visualLevel * 34,
                height: height + visualLevel * 42
            )
            .offset(y: y - visualLevel * 16)
    }
}
