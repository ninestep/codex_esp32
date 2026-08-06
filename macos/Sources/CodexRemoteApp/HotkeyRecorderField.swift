import AppKit
import CodexRemoteMac
import SwiftUI

struct HotkeyRecorderField: NSViewRepresentable {
    @Binding var value: String

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let view = HotkeyRecorderNSView()
        view.configuredValue = value
        view.onCompletion = { value = $0 }
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
        nsView.onCompletion = { value = $0 }
        if !nsView.isRecording {
            nsView.configuredValue = value
        }
    }
}

@MainActor
final class HotkeyRecorderNSView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var recordingSession = HotkeyRecordingSession()

    var onCompletion: ((String) -> Void)?
    var configuredValue = "" {
        didSet {
            if !isRecording {
                showConfiguredValue()
            }
        }
    }
    private(set) var isRecording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1

        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        showConfiguredValue()
        updateAppearance()
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("录制豆包快捷键")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func accessibilityPerformPress() -> Bool {
        window?.makeFirstResponder(self)
        return true
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        recordingSession.reset()
        isRecording = true
        label.stringValue = "请按下快捷键…"
        updateAppearance()
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        recordingSession.reset()
        isRecording = false
        showConfiguredValue()
        updateAppearance()
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else {
            super.flagsChanged(with: event)
            return
        }

        switch recordingSession.update(flags: Self.cgEventFlags(from: event.modifierFlags)) {
        case .recording(let displayValue):
            label.stringValue = "\(displayValue)（松开以保存）"
        case .completed(let displayValue):
            configuredValue = displayValue
            onCompletion?(displayValue)
            window?.makeFirstResponder(nil)
        case .invalid:
            label.stringValue = "请同时按下至少两个 ⌘ ⌥ ⌃"
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            window?.makeFirstResponder(nil)
        } else {
            recordingSession.reset()
            label.stringValue = "仅支持 ⌘、⌥、⌃ 的组合"
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func showConfiguredValue() {
        label.stringValue = configuredValue.isEmpty ? "点击后按下快捷键" : configuredValue
        setAccessibilityValue(configuredValue)
    }

    private func updateAppearance() {
        layer?.borderColor = isRecording
            ? NSColor.controlAccentColor.cgColor
            : NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    private static func cgEventFlags(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var result: CGEventFlags = []
        if flags.contains(.command) { result.insert(.maskCommand) }
        if flags.contains(.option) { result.insert(.maskAlternate) }
        if flags.contains(.control) { result.insert(.maskControl) }
        if flags.contains(.shift) { result.insert(.maskShift) }
        if flags.contains(.function) { result.insert(.maskSecondaryFn) }
        return result
    }
}
