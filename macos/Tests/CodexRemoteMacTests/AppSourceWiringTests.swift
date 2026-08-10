import Foundation
import XCTest

final class AppSourceWiringTests: XCTestCase {
    func testAppDeclaresGhosttyAutomationUsage() throws {
        let macosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoURL = macosRoot.appendingPathComponent("App/Info.plist")
        let data = try Data(contentsOf: infoURL)
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        XCTAssertEqual(
            info["NSAppleEventsUsageDescription"] as? String,
            "允许 Codex Remote 控制 Ghostty，以聚焦用户选择的 Codex 会话并发送终端操作。"
        )
    }

    func testAppDeclaresAndPackagesCodexRemoteIcon() throws {
        let macosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoURL = macosRoot.appendingPathComponent("App/Info.plist")
        let data = try Data(contentsOf: infoURL)
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let packageScript = try String(
            contentsOf: macosRoot.appendingPathComponent("Scripts/package-app.zsh"),
            encoding: .utf8
        )

        XCTAssertEqual(info["CFBundleIconFile"] as? String, "CodexRemote.icns")
        XCTAssertEqual(info["LSUIElement"] as? Bool, true)
        XCTAssertTrue(packageScript.contains("App/CodexRemote.icns"))
        XCTAssertTrue(packageScript.contains("Contents/Resources/CodexRemote.icns"))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: macosRoot.appendingPathComponent("App/CodexRemote.icns").path
            )
        )
    }

    func testPackageUsesStableLocalSigningIdentityByDefault() throws {
        let macosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let packageScript = try String(
            contentsOf: macosRoot.appendingPathComponent("Scripts/package-app.zsh"),
            encoding: .utf8
        )

        XCTAssertTrue(
            packageScript.contains(
                "local_signing_identity=\"Codex Remote Local Code Signing\""
            )
        )
        XCTAssertTrue(
            packageScript.contains(
                "signing_identity=${CODE_SIGN_IDENTITY:-$local_signing_identity}"
            )
        )
        XCTAssertTrue(packageScript.contains("security find-identity -v -p codesigning"))
        XCTAssertTrue(
            packageScript.contains(
                "codesign --force --deep --sign \"$signing_identity\" \"$app_dir\""
            )
        )
        XCTAssertTrue(
            packageScript.contains(
                "set CODE_SIGN_IDENTITY=- only for disposable ad-hoc builds"
            )
        )
        XCTAssertFalse(packageScript.contains("codesign --force --deep --sign - \"$app_dir\""))
    }

    func testMenuBarLabelObservesAppModel() throws {
        let macosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = macosRoot.appendingPathComponent("Sources/CodexRemoteApp/CodexRemoteApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("MenuBarStatusLabel(model: appDelegate.model)"))
        XCTAssertTrue(source.contains("@ObservedObject var model: AppModel"))
        XCTAssertTrue(source.contains("Text(model.menuBarStatusToken)"))
        XCTAssertTrue(source.contains("accessibilityLabel"))
    }

    func testMenuBarSymbolUsesThreeCodexRemoteConnectionStates() throws {
        let macosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = macosRoot.appendingPathComponent("Sources/CodexRemoteApp/AppModel.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("case .ready: \">_\""))
        XCTAssertTrue(source.contains("case .disconnected, .unavailable: \"x_\""))
        XCTAssertTrue(source.contains(".subscribingNotifications:"))
        XCTAssertTrue(source.contains("\"o_\""))
    }

    func testCoreBluetoothResetsPersistedDeviceInfoSubscription() throws {
        let macosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = macosRoot.appendingPathComponent(
            "Sources/CodexRemoteMac/Bluetooth/CoreBluetoothTransport.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("if characteristic.isNotifying"))
        XCTAssertTrue(source.contains("pendingSubscriptionResets.insert(role)"))
        XCTAssertTrue(source.contains("setNotifyValue(false, for: characteristic)"))
        XCTAssertTrue(source.contains("pendingSubscriptionResets.remove(role)"))
        XCTAssertTrue(source.contains("setNotifyValue(true, for: characteristic)"))
        XCTAssertTrue(source.contains("succeeded: error == nil && characteristic.isNotifying"))
        XCTAssertTrue(source.contains("isNotifying: characteristic.isNotifying"))
        XCTAssertTrue(source.contains("case let .read(role)"))
        XCTAssertTrue(source.contains("peripheral?.readValue(for: characteristic)"))
        XCTAssertTrue(source.contains("retrieveConnectedPeripherals("))
        XCTAssertTrue(source.contains("scanRetryTask"))
        XCTAssertTrue(source.contains("Task.sleep(for: .seconds(1))"))
        XCTAssertTrue(source.contains("self.state == .scanning"))
        XCTAssertTrue(source.contains("CBUUID(string: \"1812\")"))
        XCTAssertTrue(source.contains("hidDeviceName = \"Codex Micro\""))
        XCTAssertTrue(source.contains("withServices: [BluetoothUUIDs.service]"))
    }

    func testSettingsDescribeDirectDoubaoRecognitionWithoutShortcutSetup() throws {
        let macosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for relativePath in [
            "Sources/CodexRemoteApp/SettingsView.swift",
            "Sources/CodexRemoteApp/SetupAssistantView.swift",
        ] {
            let source = try String(
                contentsOf: macosRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            XCTAssertTrue(source.contains("豆包") || source.contains("设备的语音键"), relativePath)
            XCTAssertFalse(source.contains("豆包快捷键"), relativePath)
            XCTAssertFalse(source.contains("HotkeyRecorderField"), relativePath)
        }
    }

    func testEnhancedModeUIOnlyExposesCurrentDeviceAndSpeechControls() throws {
        let macosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let menuSource = try String(
            contentsOf: macosRoot.appendingPathComponent(
                "Sources/CodexRemoteApp/MenuBarContentView.swift"
            ),
            encoding: .utf8
        )
        let settingsSource = try String(
            contentsOf: macosRoot.appendingPathComponent(
                "Sources/CodexRemoteApp/SettingsView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(menuSource.contains("长按说话 · 单击确认 · 双击取消"))
        XCTAssertTrue(menuSource.contains("Text(\"电量\")"))
        XCTAssertTrue(menuSource.contains("model.batterySummaryText"))
        XCTAssertTrue(settingsSource.contains("LabeledContent(\"充电状态\""))
        XCTAssertTrue(settingsSource.contains("model.chargingStatusText"))
        XCTAssertFalse(menuSource.contains("本地服务"))
        XCTAssertFalse(menuSource.contains("snapshot.sessions"))

        for expectedText in ["设备连接", "语音识别", "实体按键", "登录豆包", "辅助功能权限"] {
            XCTAssertTrue(settingsSource.contains(expectedText), expectedText)
        }
        for removedText in ["本地 Socket", "Codex CLI", "安装与诊断", "清理 Codex Remote 配置", "BlackHole"] {
            XCTAssertFalse(settingsSource.contains(removedText), removedText)
        }
        XCTAssertFalse(settingsSource.contains("model.saveSettings()"))
    }

    func testEnhancedRuntimeUsesDoubaoSpeechSessionAndFocusedKeyboardEmitter() throws {
        let macosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appModelSource = try String(
            contentsOf: macosRoot.appendingPathComponent(
                "Sources/CodexRemoteApp/AppModel.swift"
            ),
            encoding: .utf8
        )
        let settingsSource = try String(
            contentsOf: macosRoot.appendingPathComponent("Sources/CodexRemoteApp/SettingsView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            appModelSource.contains("credentials: doubaoLoginController.credentials")
        )
        XCTAssertTrue(appModelSource.contains("await doubaoLoginController.restoreCredentials()"))
        XCTAssertTrue(appModelSource.contains("CGEventRecognizedTextEmitter()"))
        XCTAssertTrue(settingsSource.contains("登录豆包"))
        XCTAssertFalse(settingsSource.contains("微信输入法"))
    }

    func testEnhancedRuntimeDoesNotStartLegacySessionOrIPCServices() throws {
        let macosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: macosRoot.appendingPathComponent("Sources/CodexRemoteApp/AppModel.swift"),
            encoding: .utf8
        )
        let startBody = try XCTUnwrap(
            source.split(separator: "func start() async {", maxSplits: 1).last?
                .split(separator: "func saveSettings()", maxSplits: 1).first
        )

        XCTAssertTrue(startBody.contains("CompanionAudioCoordinator(audioInput: audioInput)"))
        XCTAssertFalse(startBody.contains("SessionService()"))
        XCTAssertFalse(startBody.contains("UnixSocketIPCServer"))
        XCTAssertFalse(startBody.contains("HookEventQueue"))
    }
}
