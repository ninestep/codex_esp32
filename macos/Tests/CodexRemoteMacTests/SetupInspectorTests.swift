import Darwin
import Foundation
import XCTest
@testable import CodexRemoteMac

final class SetupInspectorTests: XCTestCase {
    func testTemporaryAppWaitsForManualRelaunchWhenStableBundleIsInstalled() async {
        let environment = FakeSetupEnvironment(
            applicationURL: URL(fileURLWithPath: "/tmp/Codex Remote.app"),
            stableApplicationInstalled: true
        )
        let inspector = SetupInspector(environment: environment, context: .testReady)

        let snapshot = SetupSnapshot(results: await inspector.inspect())
        let result = snapshot.result(for: .applicationLocation)

        XCTAssertEqual(result?.state, .waitingForUser)
        XCTAssertTrue(result?.summary.contains("/Applications/Codex Remote.app") == true)
        XCTAssertEqual(result?.availableActions, [.recheck])
    }

    func testMacSetupEnvironmentValidatesInstalledApplicationBundleResources() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = root.appendingPathComponent("Codex Remote.app", isDirectory: true)
        for relativePath in [
            "Contents/MacOS/codex-remote-app",
            "Contents/MacOS/codex-remote-helper",
            "Contents/Resources/codex",
            "Contents/Resources/codex-remote-hook",
        ] {
            let url = appURL.appendingPathComponent(relativePath)
            try write("#!/bin/sh\n", to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let hooksURL = appURL.appendingPathComponent("Contents/Resources/codex-remote-hooks.json")
        try write("{}", to: hooksURL)

        let environment = MacSetupEnvironment()
        let valid = await environment.isApplicationBundleInstalled(at: appURL)
        XCTAssertTrue(valid)

        try FileManager.default.removeItem(at: hooksURL)
        let missingResource = await environment.isApplicationBundleInstalled(at: appURL)
        XCTAssertFalse(missingResource)
    }

    func testMacSetupEnvironmentUsesInjectedHotkeyTestEvidence() async {
        let environment = MacSetupEnvironment(hotkeyTestReader: { hotkey in
            hotkey == "⌥Space"
        })

        let matching = await environment.wasHotkeyTested("⌥Space")
        let different = await environment.wasHotkeyTested("⌘⇧V")
        XCTAssertTrue(matching)
        XCTAssertFalse(different)
    }

    func testInspectReturnsAllItemsInStableUniqueOrderWhenReady() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let hooksURL = root.appendingPathComponent("hooks.json")
        try write(#"{"hooks":{}}"#, to: hooksURL)
        let hooksWrittenAt = Date(timeIntervalSince1970: 200)
        try FileManager.default.setAttributes([.modificationDate: hooksWrittenAt], ofItemAtPath: hooksURL.path)
        let inspector = SetupInspector(
            environment: FakeSetupEnvironment(
                applicationURL: URL(fileURLWithPath: "/Applications/Codex Remote.app"),
                ghosttyExecutableURL: URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/MacOS/ghostty"),
                ghosttyVersion: .installed("1.2.3"),
                codexExecutableURL: URL(fileURLWithPath: "/usr/local/bin/codex"),
                codexVersion: .installed("codex 9.8.7"),
                shimInstalled: true,
                shellPathConfigured: true,
                hooksConfiguration: .valid,
                hooksTrusted: true,
                blackHoleInstalled: true,
                bluetoothPermission: .granted,
                microphonePermission: .granted,
                accessibilityPermission: .granted,
                hotkeyTested: true,
                localIPCReachable: true,
                esp32Connected: true
            ),
            context: .testReady.withHooksConfigurationURL(hooksURL),
            hookTrustEvidenceStore: StaticHookTrustEvidenceStore(
                evidence: HookTrustEvidence(acceptedAt: hooksWrittenAt, eventName: "SessionStart")
            )
        )

        let results = await inspector.inspect()

        XCTAssertEqual(results.map(\.item), SetupItem.allCases)
        XCTAssertEqual(Set(results.map(\.item)).count, SetupItem.allCases.count)
        XCTAssertTrue(results.allSatisfy { $0.state == .ready })
        XCTAssertTrue(SetupSnapshot(results: results).isMacReady)
    }

    func testInspectMapsMissingConfigurationToPreciseActions() async throws {
        let inspector = SetupInspector(
            environment: FakeSetupEnvironment(
                applicationURL: URL(fileURLWithPath: "/tmp/Codex Remote.app"),
                ghosttyExecutableURL: nil,
                ghosttyVersion: .notInstalled,
                codexExecutableURL: URL(fileURLWithPath: "/usr/local/bin/codex"),
                codexVersion: .unrecognized(""),
                shimInstalled: false,
                shellPathConfigured: false,
                hooksConfiguration: .missing,
                hooksTrusted: nil,
                blackHoleInstalled: false,
                bluetoothPermission: .denied,
                microphonePermission: .notDetermined,
                accessibilityPermission: .restricted,
                hotkeyTested: false,
                localIPCReachable: false,
                esp32Connected: false
            ),
            context: .testReady
        )

        let snapshot = SetupSnapshot(results: await inspector.inspect())

        assertResult(snapshot, .applicationLocation, .needsConfiguration, [.installApplication], summaryContains: "不在稳定位置")
        assertResult(snapshot, .ghostty, .needsConfiguration, [], summaryContains: "未安装")
        assertResult(snapshot, .codexCLI, .needsConfiguration, [], summaryContains: "版本不可识别")
        assertResult(snapshot, .shim, .needsConfiguration, [.installShimAndPath])
        assertResult(snapshot, .shellPath, .needsConfiguration, [.installShimAndPath])
        assertResult(snapshot, .hooksConfiguration, .needsConfiguration, [.installHooks])
        assertResult(snapshot, .hooksTrust, .waitingForUser, [.confirmHooksTrust])
        assertResult(snapshot, .blackHole, .needsConfiguration, [.installBlackHole])
        assertResult(snapshot, .bluetoothPermission, .waitingForUser, [.requestBluetooth])
        assertResult(snapshot, .microphonePermission, .waitingForUser, [.requestMicrophone])
        assertResult(snapshot, .accessibilityPermission, .waitingForUser, [.requestAccessibility])
        assertResult(snapshot, .doubaoHotkey, .waitingForUser, [.testHotkey])
        assertResult(snapshot, .localIPC, .failed, [.restoreManagedConfiguration])
        assertResult(snapshot, .esp32Device, .waitingForUser, [])
        XCTAssertFalse(snapshot.isMacReady)
    }

    func testVersionCommandFailureIsDifferentFromMissingExecutable() async throws {
        let inspector = SetupInspector(
            environment: FakeSetupEnvironment(
                ghosttyExecutableURL: URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/MacOS/ghostty"),
                ghosttyVersion: .unrecognized("unexpected"),
                codexExecutableURL: nil,
                codexVersion: .notInstalled
            ),
            context: .testReady
        )

        let snapshot = SetupSnapshot(results: await inspector.inspect())

        assertResult(snapshot, .ghostty, .needsConfiguration, [], summaryContains: "版本不可识别")
        assertResult(snapshot, .codexCLI, .needsConfiguration, [], summaryContains: "未安装")
    }

    func testPermissionChecksDoNotRequestPrompts() async throws {
        let environment = FakeSetupEnvironment(
            bluetoothPermission: .notDetermined,
            microphonePermission: .notDetermined,
            accessibilityPermission: .notDetermined
        )
        let inspector = SetupInspector(environment: environment, context: .testReady)

        _ = await inspector.inspect()

        let permissionQueryCount = await environment.permissionQueryCount()
        let permissionRequestCount = await environment.permissionRequestCount()
        XCTAssertEqual(permissionQueryCount, 3)
        XCTAssertEqual(permissionRequestCount, 0)
    }

    func testESP32WaitingDoesNotBlockMacReadiness() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let hooksURL = root.appendingPathComponent("hooks.json")
        try write(#"{"hooks":{}}"#, to: hooksURL)
        let hooksWrittenAt = Date(timeIntervalSince1970: 200)
        try FileManager.default.setAttributes([.modificationDate: hooksWrittenAt], ofItemAtPath: hooksURL.path)
        let inspector = SetupInspector(
            environment: FakeSetupEnvironment(esp32Connected: false),
            context: .testReady.withHooksConfigurationURL(hooksURL),
            hookTrustEvidenceStore: StaticHookTrustEvidenceStore(
                evidence: HookTrustEvidence(acceptedAt: hooksWrittenAt, eventName: "SessionStart")
            )
        )

        let snapshot = SetupSnapshot(results: await inspector.inspect())

        XCTAssertEqual(snapshot.result(for: .esp32Device)?.state, .waitingForUser)
        XCTAssertTrue(snapshot.isMacReady)
    }

    func testInvalidHotkeyWaitsForUserWithoutAutomaticInstallAction() async throws {
        let inspector = SetupInspector(
            environment: FakeSetupEnvironment(hotkeyTested: false),
            context: SetupInspectionContext.testReady.withHotkey("Space")
        )

        let snapshot = SetupSnapshot(results: await inspector.inspect())

        assertResult(snapshot, .doubaoHotkey, .waitingForUser, [], summaryContains: "快捷键无效")
    }

    func testHooksTrustRequiresAcceptedEvidenceAtOrAfterHooksConfigurationWriteTime() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let hooksURL = root.appendingPathComponent("hooks.json")
        try write(#"{"hooks":{}}"#, to: hooksURL)
        let hooksWrittenAt = Date(timeIntervalSince1970: 200)
        try FileManager.default.setAttributes([.modificationDate: hooksWrittenAt], ofItemAtPath: hooksURL.path)

        let staleInspector = SetupInspector(
            environment: FakeSetupEnvironment(hooksConfiguration: .valid, hooksTrusted: true),
            context: .testReady.withHooksConfigurationURL(hooksURL),
            hookTrustEvidenceStore: StaticHookTrustEvidenceStore(
                evidence: HookTrustEvidence(acceptedAt: Date(timeIntervalSince1970: 199), eventName: "Stop")
            )
        )
        let currentInspector = SetupInspector(
            environment: FakeSetupEnvironment(hooksConfiguration: .valid, hooksTrusted: false),
            context: .testReady.withHooksConfigurationURL(hooksURL),
            hookTrustEvidenceStore: StaticHookTrustEvidenceStore(
                evidence: HookTrustEvidence(acceptedAt: Date(timeIntervalSince1970: 200), eventName: "Stop")
            )
        )
        let unknownInspector = SetupInspector(
            environment: FakeSetupEnvironment(hooksConfiguration: .valid, hooksTrusted: true),
            context: .testReady.withHooksConfigurationURL(hooksURL),
            hookTrustEvidenceStore: StaticHookTrustEvidenceStore(
                evidence: HookTrustEvidence(acceptedAt: Date(timeIntervalSince1970: 201), eventName: "UnknownEvent")
            )
        )

        let stale = SetupSnapshot(results: await staleInspector.inspect())
        let current = SetupSnapshot(results: await currentInspector.inspect())
        let unknown = SetupSnapshot(results: await unknownInspector.inspect())

        assertResult(stale, .hooksTrust, .waitingForUser, [.confirmHooksTrust], summaryContains: "/hooks")
        assertResult(current, .hooksTrust, .ready, [], summaryContains: "Hooks 信任已确认")
        assertResult(unknown, .hooksTrust, .waitingForUser, [.confirmHooksTrust], summaryContains: "/hooks")
    }

    func testCommandRequestRejectsRelativeExecutablePath() {
        XCTAssertThrowsError(try CommandRequest(executablePath: "bin/echo", arguments: []))
    }

    func testCommandRunPreservesNonZeroExitCodeAndRedactsOutput() async throws {
        let runner = ProcessCommandRunner(maxOutputBytes: 256)
        let request = try CommandRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'token=abc123\\npassword: super-secret\\nHOME=/Users/alice\\n'; exit 7"]
        )

        let result = try await runner.run(request)

        XCTAssertEqual(result.exitCode, 7)
        XCTAssertTrue(result.stdout.contains("token=[REDACTED]"))
        XCTAssertTrue(result.stdout.contains("password: [REDACTED]"))
        XCTAssertTrue(result.stdout.contains("HOME=~"))
        XCTAssertFalse(result.stdout.contains("abc123"))
        XCTAssertFalse(result.stdout.contains("super-secret"))
        XCTAssertFalse(result.stdout.contains("/Users/alice"))
    }

    func testCommandRunRedactsAuthorizationBearerValuesCaseInsensitively() async throws {
        let runner = ProcessCommandRunner(maxOutputBytes: 256)
        let request = try CommandRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["Authorization: Bearer abc123\nauthorization=Bearer DEF456\n"]
        )

        let result = try await runner.run(request)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Authorization: Bearer [REDACTED]"))
        XCTAssertTrue(result.stdout.contains("authorization=Bearer [REDACTED]"))
        XCTAssertFalse(result.stdout.contains("abc123"))
        XCTAssertFalse(result.stdout.contains("DEF456"))
    }

    func testCommandRunRedactsQuotedJSONSecretsAndEnvironmentSecretSuffixes() async throws {
        let runner = ProcessCommandRunner(maxOutputBytes: 512)
        let request = try CommandRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: [
                #""token":"json-token"\n"password": "json-password"\nOPENAI_API_KEY=openai-key\nAWS_SECRET_ACCESS_KEY=aws-secret\nSERVICE_TOKEN=service-token\nDB_PASSWORD=db-password\nAPP_SECRET=app-secret\n"#,
            ]
        )

        let result = try await runner.run(request)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains(#""token":"[REDACTED]""#))
        XCTAssertTrue(result.stdout.contains(#""password": "[REDACTED]""#))
        XCTAssertTrue(result.stdout.contains("OPENAI_API_KEY=[REDACTED]"))
        XCTAssertTrue(result.stdout.contains("AWS_SECRET_ACCESS_KEY=[REDACTED]"))
        XCTAssertTrue(result.stdout.contains("SERVICE_TOKEN=[REDACTED]"))
        XCTAssertTrue(result.stdout.contains("DB_PASSWORD=[REDACTED]"))
        XCTAssertTrue(result.stdout.contains("APP_SECRET=[REDACTED]"))
        for secret in ["json-token", "json-password", "openai-key", "aws-secret", "service-token", "db-password", "app-secret"] {
            XCTAssertFalse(result.stdout.contains(secret))
        }
    }

    func testCommandRunTruncatesLargeOutput() async throws {
        let runner = ProcessCommandRunner(maxOutputBytes: 12)
        let request = try CommandRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["12345678901234567890"]
        )

        let result = try await runner.run(request)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.hasPrefix("123456789012"))
        XCTAssertTrue(result.stdout.contains("[truncated]"))
    }

    func testCommandRunTruncatesUTF8WithoutReplacementCharacter() async throws {
        let runner = ProcessCommandRunner(maxOutputBytes: 5)
        let request = try CommandRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["你好世界"]
        )

        let result = try await runner.run(request)

        XCTAssertTrue(result.stdout.hasPrefix("你"))
        XCTAssertTrue(result.stdout.contains("[truncated]"))
        XCTAssertFalse(result.stdout.contains("\u{FFFD}"))
    }

    func testCommandRunCancellationTerminatesStartedProcess() async throws {
        let started = ProcessStartProbe()
        let runner = ProcessCommandRunner(onProcessStarted: { pid in
            Task {
                await started.record(pid)
            }
        })
        let request = try CommandRequest(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"]
        )

        let task = Task {
            try await runner.run(request)
        }
        let pid = try await started.waitForPID(timeout: .seconds(2))
        XCTAssertTrue(processExists(pid))

        task.cancel()

        do {
            _ = try await withTimeout(.seconds(2)) {
                try await task.value
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }

        try await waitUntilProcessExits(pid, timeout: .seconds(2))
    }

    func testCommandStreamBoundsTotalOutputAcrossStdoutAndStderr() async throws {
        let runner = ProcessCommandRunner(maxOutputBytes: 12, maxStreamLineBytes: 64)
        let request = try CommandRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '1234567890'; sleep 0.1; printf 'ABCDEFGHIJ' >&2"]
        )

        var events: [CommandEvent] = []
        for try await event in runner.stream(request) {
            events.append(event)
        }

        let emittedBytes = events.reduce(0) { count, event in
            switch event {
            case .standardOutput(let value):
                return count + Data(value.utf8).count
            case .standardError(let value):
                return value == "[truncated]" ? count : count + Data(value.utf8).count
            case .completed:
                return count
            }
        }
        XCTAssertLessThanOrEqual(emittedBytes, 12)
        XCTAssertEqual(events.filter { $0 == .standardError("[truncated]") }.count, 1)
        XCTAssertEqual(events.last, .completed(0))
    }

    func testCommandStreamBoundsSingleLineWithoutNewline() async throws {
        let runner = ProcessCommandRunner(maxOutputBytes: 64, maxStreamLineBytes: 8)
        let request = try CommandRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["abcdefghijklmnop"]
        )

        var events: [CommandEvent] = []
        for try await event in runner.stream(request) {
            events.append(event)
        }

        XCTAssertEqual(events.filter { $0 == .standardOutput("abcdefgh") }.count, 1)
        XCTAssertEqual(events.filter { $0 == .standardError("[truncated]") }.count, 1)
        XCTAssertEqual(events.last, .completed(0))
    }

    func testCommandStreamCancellationTerminatesProcessAndFinishesConsumer() async throws {
        let started = ProcessStartProbe()
        let runner = ProcessCommandRunner(onProcessStarted: { pid in
            Task {
                await started.record(pid)
            }
        })
        let request = try CommandRequest(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"]
        )

        let stream = runner.stream(request)
        let task = Task {
            for try await _ in stream {}
        }
        let pid = try await started.waitForPID(timeout: .seconds(2))
        XCTAssertTrue(processExists(pid))

        task.cancel()
        _ = try await withTimeout(.seconds(2)) {
            try await task.value
        }
        try await waitUntilProcessExits(pid, timeout: .seconds(2))
    }

    func testCommandStreamYieldsLinesThenCompletion() async throws {
        let runner = ProcessCommandRunner()
        let request = try CommandRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["one\\ntwo\\n"]
        )

        var events: [CommandEvent] = []
        for try await event in runner.stream(request) {
            events.append(event)
        }

        XCTAssertEqual(events, [
            .standardOutput("one"),
            .standardOutput("two"),
            .completed(0),
        ])
    }

    func testMacSetupEnvironmentRequiresShimSymlinkToManagedTarget() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let appResources = root.appendingPathComponent("Codex Remote.app/Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: appResources, withIntermediateDirectories: true)
        let target = appResources.appendingPathComponent("codex")
        FileManager.default.createFile(atPath: target.path, contents: Data("#!/bin/sh\n".utf8))
        let shim = root.appendingPathComponent("bin/codex")
        try FileManager.default.createDirectory(at: shim.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: shim, withDestinationURL: target)

        let environment = MacSetupEnvironment()
        let symlinkReady = await environment.isShimInstalled(at: shim, targetURL: target)
        XCTAssertTrue(symlinkReady)

        try FileManager.default.removeItem(at: shim)
        FileManager.default.createFile(atPath: shim.path, contents: Data("#!/bin/sh\n".utf8))
        let regularFileReady = await environment.isShimInstalled(at: shim, targetURL: target)
        XCTAssertFalse(regularFileReady)
    }

    func testMacSetupEnvironmentRequiresUniqueManagedPathBlock() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let zshrc = root.appendingPathComponent(".zshrc")
        let environment = MacSetupEnvironment()

        try write(
            """
            # >>> Codex Remote >>>
            export PATH="$HOME/.codex-remote/bin:$PATH"
            # <<< Codex Remote <<<
            """,
            to: zshrc
        )
        let validPathBlock = await environment.isShellPathConfigured(profileURL: zshrc)
        XCTAssertTrue(validPathBlock)

        try write(
            """
            # >>> Codex Remote >>>
            export PATH="$HOME/.codex-remote/bin:$PATH"
            # <<< Codex Remote <<<
            # >>> Codex Remote >>>
            export PATH="$HOME/.codex-remote/bin:$PATH"
            # <<< Codex Remote <<<
            """,
            to: zshrc
        )
        let duplicatePathBlock = await environment.isShellPathConfigured(profileURL: zshrc)
        XCTAssertFalse(duplicatePathBlock)

        try write(
            """
            # >>> Codex Remote >>>
            export PATH="$HOME/bin:$PATH"
            # <<< Codex Remote <<<
            """,
            to: zshrc
        )
        let wrongPathBlock = await environment.isShellPathConfigured(profileURL: zshrc)
        XCTAssertFalse(wrongPathBlock)
    }

    func testMacSetupEnvironmentValidatesManagedHooksConfigurationShapeAndCommand() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let hooksURL = root.appendingPathComponent("hooks.json")
        let hookExecutableURL = root.appendingPathComponent("Codex Remote.app/Contents/Resources/codex-remote-hook")
        try FileManager.default.createDirectory(at: hookExecutableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: hookExecutableURL.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookExecutableURL.path)
        let environment = MacSetupEnvironment()

        try write(validHooksJSON(command: "'\(hookExecutableURL.path)'", includeStop: true), to: hooksURL)
        let validHooks = await environment.hooksConfigurationState(at: hooksURL, hookExecutableURL: hookExecutableURL)
        XCTAssertEqual(validHooks, .valid)

        try write(validHooksJSON(command: "'\(hookExecutableURL.path)'", includeStop: true, sessionMatcher: "resume"), to: hooksURL)
        XCTAssertInvalid(await environment.hooksConfigurationState(at: hooksURL, hookExecutableURL: hookExecutableURL))

        try write(validHooksJSON(command: "'\(hookExecutableURL.path)'", includeStop: true, sessionTimeout: 6), to: hooksURL)
        XCTAssertInvalid(await environment.hooksConfigurationState(at: hooksURL, hookExecutableURL: hookExecutableURL))

        try write(validHooksJSON(command: "'\(hookExecutableURL.path)'", includeStop: true, sessionStatusMessage: "wrong"), to: hooksURL)
        XCTAssertInvalid(await environment.hooksConfigurationState(at: hooksURL, hookExecutableURL: hookExecutableURL))

        try write(validHooksJSON(command: "'\(hookExecutableURL.path)'", includeStop: true, userPromptMatcher: "startup"), to: hooksURL)
        XCTAssertInvalid(await environment.hooksConfigurationState(at: hooksURL, hookExecutableURL: hookExecutableURL))

        try write(validHooksJSON(command: "'\(hookExecutableURL.path)'", includeStop: true, userPromptTimeout: 6), to: hooksURL)
        XCTAssertInvalid(await environment.hooksConfigurationState(at: hooksURL, hookExecutableURL: hookExecutableURL))

        try FileManager.default.removeItem(at: hooksURL)
        let symlinkHooks = root.appendingPathComponent("symlink-hooks.json")
        try write(validHooksJSON(command: "'\(hookExecutableURL.path)'", includeStop: true), to: symlinkHooks)
        try FileManager.default.createSymbolicLink(at: hooksURL, withDestinationURL: symlinkHooks)
        XCTAssertInvalid(await environment.hooksConfigurationState(at: hooksURL, hookExecutableURL: hookExecutableURL))
        try FileManager.default.removeItem(at: hooksURL)

        let symlinkHookExecutable = root.appendingPathComponent("symlink-hook")
        try FileManager.default.createSymbolicLink(at: symlinkHookExecutable, withDestinationURL: hookExecutableURL)
        try write(validHooksJSON(command: "'\(symlinkHookExecutable.path)'", includeStop: true), to: hooksURL)
        XCTAssertInvalid(await environment.hooksConfigurationState(at: hooksURL, hookExecutableURL: symlinkHookExecutable))

        try FileManager.default.removeItem(at: symlinkHookExecutable)
        try write("not-executable", to: symlinkHookExecutable)
        try write(validHooksJSON(command: "'\(symlinkHookExecutable.path)'", includeStop: true), to: hooksURL)
        XCTAssertInvalid(await environment.hooksConfigurationState(at: hooksURL, hookExecutableURL: symlinkHookExecutable))

        try write(#"{"hooks":{}}"#, to: hooksURL)
        XCTAssertInvalid(await environment.hooksConfigurationState(at: hooksURL, hookExecutableURL: hookExecutableURL))

        try write(validHooksJSON(command: "'\(hookExecutableURL.path)'", includeStop: false), to: hooksURL)
        XCTAssertInvalid(await environment.hooksConfigurationState(at: hooksURL, hookExecutableURL: hookExecutableURL))

        try write(validHooksJSON(command: "'/tmp/wrong-hook'", includeStop: true), to: hooksURL)
        XCTAssertInvalid(await environment.hooksConfigurationState(at: hooksURL, hookExecutableURL: hookExecutableURL))

        try write("{", to: hooksURL)
        XCTAssertInvalid(await environment.hooksConfigurationState(at: hooksURL, hookExecutableURL: hookExecutableURL))
    }

    func testMacSetupEnvironmentRejectsHooksConfigurationInWritableParentDirectory() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let publicDirectory = root.appendingPathComponent("public", isDirectory: true)
        try FileManager.default.createDirectory(at: publicDirectory, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: publicDirectory.path)
        let hooksURL = publicDirectory.appendingPathComponent("hooks.json")
        let hookExecutableURL = root.appendingPathComponent("Codex Remote.app/Contents/Resources/codex-remote-hook")
        try FileManager.default.createDirectory(at: hookExecutableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: hookExecutableURL.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookExecutableURL.path)
        try write(validHooksJSON(command: "'\(hookExecutableURL.path)'", includeStop: true), to: hooksURL)

        XCTAssertInvalid(await MacSetupEnvironment().hooksConfigurationState(at: hooksURL, hookExecutableURL: hookExecutableURL))
    }

    private func assertResult(
        _ snapshot: SetupSnapshot,
        _ item: SetupItem,
        _ state: SetupState,
        _ actions: [SetupAction],
        summaryContains expectedSummary: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let result = snapshot.result(for: item) else {
            XCTFail("Missing \(item)", file: file, line: line)
            return
        }
        XCTAssertEqual(result.state, state, file: file, line: line)
        XCTAssertEqual(result.availableActions, actions, file: file, line: line)
        if let expectedSummary {
            XCTAssertTrue(result.summary.contains(expectedSummary), "summary: \(result.summary)", file: file, line: line)
        }
    }
}

private actor FakeSetupEnvironment: SetupEnvironmentReading {
    let applicationURL: URL
    let stableApplicationInstalled: Bool
    let ghosttyExecutableURL: URL?
    let ghosttyVersion: SetupExecutableVersion
    let codexExecutableURL: URL?
    let codexVersion: SetupExecutableVersion
    let shimInstalled: Bool
    let shellPathConfigured: Bool
    let hooksConfiguration: SetupConfigurationState
    let hooksTrusted: Bool?
    let blackHoleInstalled: Bool
    let bluetoothPermission: PermissionCheck
    let microphonePermission: PermissionCheck
    let accessibilityPermission: PermissionCheck
    let hotkeyTested: Bool
    let localIPCReachable: Bool
    let esp32Connected: Bool
    private var queriedPermissions = 0
    private var requestedPermissions = 0

    init(
        applicationURL: URL = URL(fileURLWithPath: "/Applications/Codex Remote.app"),
        stableApplicationInstalled: Bool = false,
        ghosttyExecutableURL: URL? = URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/MacOS/ghostty"),
        ghosttyVersion: SetupExecutableVersion = .installed("1.0.0"),
        codexExecutableURL: URL? = URL(fileURLWithPath: "/usr/local/bin/codex"),
        codexVersion: SetupExecutableVersion = .installed("codex 1.0.0"),
        shimInstalled: Bool = true,
        shellPathConfigured: Bool = true,
        hooksConfiguration: SetupConfigurationState = .valid,
        hooksTrusted: Bool? = true,
        blackHoleInstalled: Bool = true,
        bluetoothPermission: PermissionCheck = .granted,
        microphonePermission: PermissionCheck = .granted,
        accessibilityPermission: PermissionCheck = .granted,
        hotkeyTested: Bool = true,
        localIPCReachable: Bool = true,
        esp32Connected: Bool = true
    ) {
        self.applicationURL = applicationURL
        self.stableApplicationInstalled = stableApplicationInstalled
        self.ghosttyExecutableURL = ghosttyExecutableURL
        self.ghosttyVersion = ghosttyVersion
        self.codexExecutableURL = codexExecutableURL
        self.codexVersion = codexVersion
        self.shimInstalled = shimInstalled
        self.shellPathConfigured = shellPathConfigured
        self.hooksConfiguration = hooksConfiguration
        self.hooksTrusted = hooksTrusted
        self.blackHoleInstalled = blackHoleInstalled
        self.bluetoothPermission = bluetoothPermission
        self.microphonePermission = microphonePermission
        self.accessibilityPermission = accessibilityPermission
        self.hotkeyTested = hotkeyTested
        self.localIPCReachable = localIPCReachable
        self.esp32Connected = esp32Connected
    }

    func currentApplicationURL() -> URL { applicationURL }
    func isApplicationBundleInstalled(at url: URL) async -> Bool { stableApplicationInstalled }
    func ghosttyExecutable() async -> URL? { ghosttyExecutableURL }
    func ghosttyVersion(executableURL: URL) async -> SetupExecutableVersion { ghosttyVersion }
    func codexExecutable() async -> URL? { codexExecutableURL }
    func codexVersion(executableURL: URL) async -> SetupExecutableVersion { codexVersion }
    func isShimInstalled(at url: URL, targetURL: URL) async -> Bool { shimInstalled }
    func isShellPathConfigured(profileURL: URL) async -> Bool { shellPathConfigured }
    func hooksConfigurationState(at url: URL, hookExecutableURL: URL) async -> SetupConfigurationState { hooksConfiguration }
    func hooksTrustState(targetURL: URL) async -> Bool? { hooksTrusted }
    func isBlackHoleInstalled() async -> Bool { blackHoleInstalled }
    func wasHotkeyTested(_ hotkey: String) async -> Bool { hotkeyTested }
    func isLocalIPCReachable(socketPath: String) async -> Bool { localIPCReachable }
    func isESP32Connected() async -> Bool { esp32Connected }

    func permissionStatus(_ permission: SetupPermissionKind) async -> PermissionCheck {
        queriedPermissions += 1
        switch permission {
        case .bluetooth: return bluetoothPermission
        case .microphone: return microphonePermission
        case .accessibility: return accessibilityPermission
        }
    }

    func requestPermission(_ permission: SetupPermissionKind) async {
        requestedPermissions += 1
    }

    func permissionQueryCount() -> Int { queriedPermissions }
    func permissionRequestCount() -> Int { requestedPermissions }
}

private struct StaticHookTrustEvidenceStore: HookTrustEvidenceReading {
    let evidence: HookTrustEvidence?

    func latestEvidence() -> HookTrustEvidence? {
        evidence
    }
}

private actor ProcessStartProbe {
    private var pid: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    func record(_ pid: Int32) {
        guard self.pid == nil else { return }
        self.pid = pid
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume(returning: pid)
        }
    }

    func waitForPID(timeout: Duration) async throws -> Int32 {
        try await withTimeout(timeout) {
            await self.currentOrWait()
        }
    }

    private func currentOrWait() async -> Int32 {
        if let pid {
            return pid
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private func withTimeout<T: Sendable>(
    _ timeout: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TestTimeoutError()
        }
        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}

private func waitUntilProcessExits(_ pid: Int32, timeout: Duration) async throws {
    try await withTimeout(timeout) {
        while processExists(pid) {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private func processExists(_ pid: Int32) -> Bool {
    Darwin.kill(pid, 0) == 0 || errno == EPERM
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SetupInspectorTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ value: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(value.utf8).write(to: url)
}

private func validHooksJSON(
    command: String,
    includeStop: Bool,
    sessionMatcher: String = "startup|resume",
    sessionTimeout: Int = 5,
    sessionStatusMessage: String = "同步 Codex Remote 会话",
    userPromptMatcher: String? = nil,
    userPromptTimeout: Int = 5
) -> String {
    let userPromptMatcherField = userPromptMatcher.map { "\"matcher\":\"\(jsonEscaped($0))\"," } ?? ""
    var events = """
    "SessionStart":[{"matcher":"\(jsonEscaped(sessionMatcher))","hooks":[{"type":"command","command":"\(jsonEscaped(command))","timeout":\(sessionTimeout),"statusMessage":"\(jsonEscaped(sessionStatusMessage))"}]}],
    "UserPromptSubmit":[{\(userPromptMatcherField)"hooks":[{"type":"command","command":"\(jsonEscaped(command))","timeout":\(userPromptTimeout)}]}],
    "PermissionRequest":[{"hooks":[{"type":"command","command":"\(jsonEscaped(command))","timeout":5}]}]
    """
    if includeStop {
        events += #","Stop":[{"hooks":[{"type":"command","command":""# + jsonEscaped(command) + #"","timeout":5}]}]"#
    }
    return #"{"description":"test","hooks":{"# + events + #","ThirdParty":[{"hooks":[{"type":"command","command":"third-party"}]}]}}"#
}

private func jsonEscaped(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

private func XCTAssertInvalid(
    _ state: SetupConfigurationState,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    if case .invalid = state {
        return
    }
    XCTFail("Expected invalid, got \(state)", file: file, line: line)
}

private struct TestTimeoutError: Error {}

private extension SetupInspectionContext {
    static let testReady = SetupInspectionContext(
        socketPath: "/tmp/codex-remote.sock",
        doubaoHotkey: "⌘ Space",
        applicationURL: URL(fileURLWithPath: "/Applications/Codex Remote.app"),
        stableApplicationURL: URL(fileURLWithPath: "/Applications/Codex Remote.app"),
        managedShimURL: URL(fileURLWithPath: "/usr/local/bin/codex-remote"),
        shellProfileURL: URL(fileURLWithPath: "/Users/test/.zshrc"),
        managedHooksConfigurationURL: URL(fileURLWithPath: "/Users/test/.codex/hooks.json"),
        managedHooksTrustTargetURL: URL(fileURLWithPath: "/Users/test/.codex")
    )

    func withHotkey(_ hotkey: String) -> SetupInspectionContext {
        SetupInspectionContext(
            socketPath: socketPath,
            doubaoHotkey: hotkey,
            applicationURL: applicationURL,
            stableApplicationURL: stableApplicationURL,
            managedShimURL: managedShimURL,
            managedShimTargetURL: managedShimTargetURL,
            shellProfileURL: shellProfileURL,
            managedHooksConfigurationURL: managedHooksConfigurationURL,
            managedHookExecutableURL: managedHookExecutableURL,
            managedHooksTrustTargetURL: managedHooksTrustTargetURL
        )
    }

    func withHooksConfigurationURL(_ url: URL) -> SetupInspectionContext {
        SetupInspectionContext(
            socketPath: socketPath,
            doubaoHotkey: doubaoHotkey,
            applicationURL: applicationURL,
            stableApplicationURL: stableApplicationURL,
            managedShimURL: managedShimURL,
            managedShimTargetURL: managedShimTargetURL,
            shellProfileURL: shellProfileURL,
            managedHooksConfigurationURL: url,
            managedHookExecutableURL: managedHookExecutableURL,
            managedHooksTrustTargetURL: managedHooksTrustTargetURL
        )
    }
}
