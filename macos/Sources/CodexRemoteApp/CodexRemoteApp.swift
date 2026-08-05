import AppKit
import SwiftUI

@main
struct CodexRemoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Codex Remote", systemImage: appDelegate.model.menuBarSymbol) {
            MenuBarContentView(model: appDelegate.model)
        }

        Settings {
            SettingsView(model: appDelegate.model)
        }
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
}
