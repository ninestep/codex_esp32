import AppKit
import SwiftUI

@main
struct CodexRemoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(model: appDelegate.model)
        } label: {
            MenuBarStatusLabel(model: appDelegate.model)
        }

        Settings {
            SettingsView(model: appDelegate.model)
        }
    }
}

private struct MenuBarStatusLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 2) {
            Text(model.menuBarStatusToken)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Codex Remote，\(model.bluetoothStatusText)")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private lazy var setupWindowController = SetupWindowController(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.onOpenSetupAssistant = { [weak self] in
            self?.setupWindowController.show()
        }
        Task {
            await model.start()
            await model.refreshSetup()
            if !model.setupSnapshot.isMacReady {
                setupWindowController.show()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task {
            await model.refreshSetup()
        }
    }
}
