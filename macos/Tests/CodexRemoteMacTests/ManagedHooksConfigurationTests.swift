import Darwin
import Foundation
import XCTest
@testable import CodexRemoteMac

final class ManagedHooksConfigurationTests: XCTestCase {
    func testInstallShellQuotesRawAbsoluteCommandContainingSpaces() throws {
        let fixture = try HooksFixture(existingJSON: #"{"hooks":{}}"#)
        defer { fixture.cleanup() }

        try ManagedHooksConfiguration(paths: fixture.paths).install(command: fixture.commandURL.path)

        let object = try fixture.readJSONObject()
        XCTAssertEqual(
            fixture.codexRemoteCommands(in: object),
            Array(repeating: "'\(fixture.commandURL.path)'", count: 4)
        )
    }

    func testInstallPreservesUnrelatedHooksUnknownFieldsAndIsIdempotent() throws {
        let fixture = try HooksFixture(
            existingJSON: """
            {"description":"third party","unknownRoot":true,"hooks":{"Stop":[{"hooks":[{"type":"command","command":"third-party"}]}],"CustomEvent":[{"extra":1,"hooks":[{"type":"command","command":"custom"}]}]}}
            """
        )
        defer { fixture.cleanup() }
        let manager = ManagedHooksConfiguration(paths: fixture.paths)

        try manager.install(command: "'\(fixture.commandURL.path)'")
        let first = try Data(contentsOf: fixture.paths.hooksURL)
        try manager.install(command: "'\(fixture.commandURL.path)'")

        let object = try fixture.readJSONObject()
        XCTAssertEqual(try Data(contentsOf: fixture.paths.hooksURL), first)
        XCTAssertEqual(object["description"] as? String, "third party")
        XCTAssertEqual(object["unknownRoot"] as? Bool, true)
        XCTAssertEqual(fixture.commands(in: object, event: "Stop").filter { $0 == "third-party" }.count, 1)
        XCTAssertEqual(fixture.commands(in: object, event: "CustomEvent"), ["custom"])
        XCTAssertEqual(fixture.codexRemoteCommands(in: object), Array(repeating: "'\(fixture.commandURL.path)'", count: 4))
        XCTAssertEqual(fixture.sessionStartMatcher(in: object), "startup|resume")
        XCTAssertEqual(fixture.sessionStartStatusMessage(in: object), "同步 Codex Remote 会话")
        XCTAssertEqual(try fixture.mode(), 0o600)
        XCTAssertEqual(try fixture.backupFiles().count, 1)
    }

    func testInvalidJSONLeavesOriginalBytesUnchanged() throws {
        let fixture = try HooksFixture(existingJSON: "{invalid")
        defer { fixture.cleanup() }

        XCTAssertThrowsError(try ManagedHooksConfiguration(paths: fixture.paths).install(command: "hook"))
        XCTAssertEqual(try Data(contentsOf: fixture.paths.hooksURL), Data("{invalid".utf8))
    }

    func testRelativeCommandIsRejectedWithoutChangingBytes() throws {
        let fixture = try HooksFixture(existingJSON: #"{"hooks":{}}"#)
        defer { fixture.cleanup() }
        let before = try Data(contentsOf: fixture.paths.hooksURL)

        XCTAssertThrowsError(try ManagedHooksConfiguration(paths: fixture.paths).install(command: "codex-remote-hook"))

        XCTAssertEqual(try Data(contentsOf: fixture.paths.hooksURL), before)
        XCTAssertEqual(try fixture.temporaryFiles(), [])
    }

    func testInstallRejectsMissingAbsoluteCommandBeforeBackupOrWrite() throws {
        let fixture = try HooksFixture(existingJSON: #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"third-party"}]}]}}"#)
        defer { fixture.cleanup() }
        let missingCommand = fixture.root.appendingPathComponent("missing-hook")
        let before = try Data(contentsOf: fixture.paths.hooksURL)

        XCTAssertThrowsError(try ManagedHooksConfiguration(paths: fixture.paths).install(command: "'\(missingCommand.path)'"))

        XCTAssertEqual(try Data(contentsOf: fixture.paths.hooksURL), before)
        XCTAssertEqual(try fixture.backupFiles(), [])
        XCTAssertEqual(try fixture.temporaryFiles(), [])
    }

    func testInstallRejectsNonExecutableCommandBeforeBackupOrWrite() throws {
        let fixture = try HooksFixture(existingJSON: #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"third-party"}]}]}}"#)
        defer { fixture.cleanup() }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.commandURL.path)
        let before = try Data(contentsOf: fixture.paths.hooksURL)

        XCTAssertThrowsError(try ManagedHooksConfiguration(paths: fixture.paths).install(command: "'\(fixture.commandURL.path)'"))

        XCTAssertEqual(try Data(contentsOf: fixture.paths.hooksURL), before)
        XCTAssertEqual(try fixture.backupFiles(), [])
        XCTAssertEqual(try fixture.temporaryFiles(), [])
    }

    func testInstallRejectsSymlinkCommandBeforeBackupOrWrite() throws {
        let fixture = try HooksFixture(existingJSON: #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"third-party"}]}]}}"#)
        defer { fixture.cleanup() }
        let symlinkCommand = fixture.root.appendingPathComponent("symlink-hook")
        try FileManager.default.createSymbolicLink(at: symlinkCommand, withDestinationURL: fixture.commandURL)
        let before = try Data(contentsOf: fixture.paths.hooksURL)

        XCTAssertThrowsError(try ManagedHooksConfiguration(paths: fixture.paths).install(command: "'\(symlinkCommand.path)'"))

        XCTAssertEqual(try Data(contentsOf: fixture.paths.hooksURL), before)
        XCTAssertEqual(try fixture.backupFiles(), [])
        XCTAssertEqual(try fixture.temporaryFiles(), [])
    }

    func testInstallRejectsManagedEventNonArrayWithoutChangingBytes() throws {
        let fixture = try HooksFixture(existingJSON: #"{"hooks":{"Stop":{"hooks":[{"type":"command","command":"third-party"}]}}}"#)
        defer { fixture.cleanup() }
        let before = try Data(contentsOf: fixture.paths.hooksURL)

        XCTAssertThrowsError(try ManagedHooksConfiguration(paths: fixture.paths).install(command: "'\(fixture.commandURL.path)'"))

        XCTAssertEqual(try Data(contentsOf: fixture.paths.hooksURL), before)
        XCTAssertEqual(try fixture.backupFiles(), [])
        XCTAssertEqual(try fixture.temporaryFiles(), [])
    }

    func testRestoreRejectsManagedEventMixedArrayWithoutChangingBytes() throws {
        let fixture = try HooksFixture(existingJSON: #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"third-party"}]},"bad"]}}"#)
        defer { fixture.cleanup() }
        let before = try Data(contentsOf: fixture.paths.hooksURL)

        XCTAssertThrowsError(try ManagedHooksConfiguration(paths: fixture.paths).restore(command: "'\(fixture.commandURL.path)'"))

        XCTAssertEqual(try Data(contentsOf: fixture.paths.hooksURL), before)
        XCTAssertEqual(try fixture.backupFiles(), [])
        XCTAssertEqual(try fixture.temporaryFiles(), [])
    }

    func testInstallRejectsGroupWithMalformedHooksArrayWithoutChangingBytes() throws {
        let fixture = try HooksFixture(existingJSON: #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"third-party"},"bad"]}]}}"#)
        defer { fixture.cleanup() }
        let before = try Data(contentsOf: fixture.paths.hooksURL)

        XCTAssertThrowsError(try ManagedHooksConfiguration(paths: fixture.paths).install(command: "'\(fixture.commandURL.path)'"))

        XCTAssertEqual(try Data(contentsOf: fixture.paths.hooksURL), before)
        XCTAssertEqual(try fixture.backupFiles(), [])
        XCTAssertEqual(try fixture.temporaryFiles(), [])
    }

    func testInstallRejectsWritableParentDirectoryWithoutWriting() throws {
        let fixture = try HooksFixture(existingJSON: #"{"hooks":{}}"#)
        defer { fixture.cleanup() }
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: fixture.root.path)
        let before = try Data(contentsOf: fixture.paths.hooksURL)

        XCTAssertThrowsError(try ManagedHooksConfiguration(paths: fixture.paths).install(command: "'\(fixture.commandURL.path)'"))

        XCTAssertEqual(try Data(contentsOf: fixture.paths.hooksURL), before)
        XCTAssertEqual(try fixture.backupFiles(), [])
        XCTAssertEqual(try fixture.temporaryFiles(), [])
    }

    func testMissingConfigurationCreatesPrivateHooksFile() throws {
        let fixture = try HooksFixture(existingJSON: nil)
        defer { fixture.cleanup() }

        try ManagedHooksConfiguration(paths: fixture.paths).install(command: "'\(fixture.commandURL.path)'")

        let object = try fixture.readJSONObject()
        XCTAssertEqual(fixture.codexRemoteCommands(in: object), Array(repeating: "'\(fixture.commandURL.path)'", count: 4))
        XCTAssertEqual(try fixture.mode(), 0o600)
        XCTAssertEqual(try fixture.backupFiles(), [])
    }

    func testRestoreOnlyDeletesOwnedCommandHooksAndPreservesOtherContent() throws {
        let fixture = try HooksFixture(
            existingJSON: """
            {"metadata":{"owner":"user"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"third-party"}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"before"}]}]}}
            """
        )
        defer { fixture.cleanup() }
        let manager = ManagedHooksConfiguration(paths: fixture.paths)
        try manager.install(command: "'\(fixture.commandURL.path)'")

        try manager.restore(command: "'\(fixture.commandURL.path)'")

        let object = try fixture.readJSONObject()
        XCTAssertEqual((object["metadata"] as? [String: Any])?["owner"] as? String, "user")
        XCTAssertEqual(fixture.codexRemoteCommands(in: object), [])
        XCTAssertEqual(fixture.commands(in: object, event: "Stop"), ["third-party"])
        XCTAssertEqual(fixture.commands(in: object, event: "UserPromptSubmit"), ["before"])
        XCTAssertNil((object["hooks"] as? [String: Any])?["SessionStart"])
        XCTAssertNil((object["hooks"] as? [String: Any])?["PermissionRequest"])
    }

    func testRestoreDeletesOwnedHooksWhenCommandExecutableIsMissing() throws {
        let fixture = try HooksFixture(
            existingJSON: """
            {"metadata":{"owner":"user"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"third-party"}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"before"}]}],"CustomEvent":[{"hooks":[{"type":"command","command":"custom"}]}]}}
            """
        )
        defer { fixture.cleanup() }
        let manager = ManagedHooksConfiguration(paths: fixture.paths)
        try manager.install(command: "'\(fixture.commandURL.path)'")
        try FileManager.default.removeItem(at: fixture.commandURL)

        try manager.restore(command: "'\(fixture.commandURL.path)'")

        let object = try fixture.readJSONObject()
        XCTAssertEqual((object["metadata"] as? [String: Any])?["owner"] as? String, "user")
        XCTAssertEqual(fixture.codexRemoteCommands(in: object), [])
        XCTAssertEqual(fixture.commands(in: object, event: "Stop"), ["third-party"])
        XCTAssertEqual(fixture.commands(in: object, event: "UserPromptSubmit"), ["before"])
        XCTAssertEqual(fixture.commands(in: object, event: "CustomEvent"), ["custom"])
        XCTAssertEqual(try fixture.backupFiles().count, 2)
    }

    func testRestoreDeletesOwnedHooksWhenCommandExecutableIsNotExecutable() throws {
        let fixture = try HooksFixture(
            existingJSON: """
            {"metadata":{"owner":"user"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"third-party"}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"before"}]}]}}
            """
        )
        defer { fixture.cleanup() }
        let manager = ManagedHooksConfiguration(paths: fixture.paths)
        try manager.install(command: "'\(fixture.commandURL.path)'")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.commandURL.path)

        try manager.restore(command: "'\(fixture.commandURL.path)'")

        let object = try fixture.readJSONObject()
        XCTAssertEqual((object["metadata"] as? [String: Any])?["owner"] as? String, "user")
        XCTAssertEqual(fixture.codexRemoteCommands(in: object), [])
        XCTAssertEqual(fixture.commands(in: object, event: "Stop"), ["third-party"])
        XCTAssertEqual(fixture.commands(in: object, event: "UserPromptSubmit"), ["before"])
        XCTAssertEqual(try fixture.backupFiles().count, 2)
    }

    func testRestoreRejectsRelativeCommandWithoutChangingBytes() throws {
        let fixture = try HooksFixture(existingJSON: #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"third-party"}]}]}}"#)
        defer { fixture.cleanup() }
        let before = try Data(contentsOf: fixture.paths.hooksURL)

        XCTAssertThrowsError(try ManagedHooksConfiguration(paths: fixture.paths).restore(command: "codex-remote-hook"))

        XCTAssertEqual(try Data(contentsOf: fixture.paths.hooksURL), before)
        XCTAssertEqual(try fixture.backupFiles(), [])
        XCTAssertEqual(try fixture.temporaryFiles(), [])
    }

    func testSymlinkConfigurationIsRejectedWithoutWritingThroughIt() throws {
        let fixture = try HooksFixture(existingJSON: nil)
        defer { fixture.cleanup() }
        let target = fixture.root.appendingPathComponent("target-hooks.json")
        try Data(#"{"hooks":{}}"#.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: fixture.paths.hooksURL, withDestinationURL: target)
        let before = try Data(contentsOf: target)

        XCTAssertThrowsError(try ManagedHooksConfiguration(paths: fixture.paths).install(command: "'\(fixture.commandURL.path)'"))

        XCTAssertEqual(try Data(contentsOf: target), before)
        XCTAssertEqual(try fixture.temporaryFiles(), [])
    }

    func testReplaceFailureLeavesOriginalBytesUnchangedAndRemovesTemporaryFile() throws {
        let fixture = try HooksFixture(existingJSON: #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"third-party"}]}]}}"#)
        defer { fixture.cleanup() }
        let before = try Data(contentsOf: fixture.paths.hooksURL)
        let manager = ManagedHooksConfiguration(
            paths: fixture.paths,
            beforeReplace: { _, _ in throw POSIXError(.EIO) }
        )

        XCTAssertThrowsError(try manager.install(command: "'\(fixture.commandURL.path)'"))

        XCTAssertEqual(try Data(contentsOf: fixture.paths.hooksURL), before)
        XCTAssertEqual(try fixture.temporaryFiles(), [])
    }
}

final class HookTrustEvidenceStoreTests: XCTestCase {
    func testEvidenceURLUsesSocketParentDirectory() {
        let socketURL = URL(fileURLWithPath: "/private/tmp/codex-remote-501/events.sock")

        XCTAssertEqual(
            HookTrustEvidenceStore.evidenceURL(forSocketAt: socketURL).path,
            "/private/tmp/codex-remote-501/codex-remote-hook-trust.json"
        )
    }

    func testDefaultEvidenceURLUsesCodexDirectoryUnderInjectedHome() throws {
        let home = URL(fileURLWithPath: "/tmp/test-home", isDirectory: true)

        XCTAssertEqual(
            HookTrustEvidenceStore.defaultEvidenceURL(homeDirectory: home).path,
            "/tmp/test-home/.codex/codex-remote-hook-trust.json"
        )
    }

    func testEvidenceURLResolvesDirectoryAndExplicitJSONTargets() throws {
        let directory = URL(fileURLWithPath: "/tmp/test-home/.codex", isDirectory: true)
        let explicit = URL(fileURLWithPath: "/tmp/test-home/custom-trust.json")

        XCTAssertEqual(
            HookTrustEvidenceStore.evidenceURL(fromTrustTarget: directory).path,
            "/tmp/test-home/.codex/codex-remote-hook-trust.json"
        )
        XCTAssertEqual(
            HookTrustEvidenceStore.evidenceURL(fromTrustTarget: explicit).path,
            "/tmp/test-home/custom-trust.json"
        )
    }

    func testRecordAcceptedHookPersistsLatestEventWithPrivateMode() throws {
        let fixture = try HooksFixture(existingJSON: nil)
        defer { fixture.cleanup() }
        let store = HookTrustEvidenceStore(
            evidenceURL: fixture.root.appendingPathComponent("trust.json"),
            clock: { Date(timeIntervalSince1970: 100) }
        )

        try store.recordAcceptedHook(eventName: "SessionStart")

        let evidence = try XCTUnwrap(store.latestEvidence())
        XCTAssertEqual(evidence.eventName, "SessionStart")
        XCTAssertEqual(evidence.acceptedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(try fileMode(at: fixture.root.appendingPathComponent("trust.json")), 0o600)
    }

    func testCorruptEvidenceIsTreatedAsMissing() throws {
        let fixture = try HooksFixture(existingJSON: nil)
        defer { fixture.cleanup() }
        let evidenceURL = fixture.root.appendingPathComponent("trust.json")
        try Data("{".utf8).write(to: evidenceURL)

        XCTAssertNil(HookTrustEvidenceStore(evidenceURL: evidenceURL).latestEvidence())
    }

    func testEvidenceSymlinkIsRejectedWithoutWritingTarget() throws {
        let fixture = try HooksFixture(existingJSON: nil)
        defer { fixture.cleanup() }
        let evidenceURL = fixture.root.appendingPathComponent("trust.json")
        let targetURL = fixture.root.appendingPathComponent("target.json")
        try Data("target".utf8).write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: evidenceURL, withDestinationURL: targetURL)

        XCTAssertThrowsError(try HookTrustEvidenceStore(evidenceURL: evidenceURL).recordAcceptedHook(eventName: "Stop"))

        XCTAssertEqual(try Data(contentsOf: targetURL), Data("target".utf8))
    }

    func testRecordAcceptedHookRejectsWritableParentWithoutWriting() throws {
        let fixture = try HooksFixture(existingJSON: nil)
        defer { fixture.cleanup() }
        let trustDirectory = fixture.root.appendingPathComponent("trust", isDirectory: true)
        try FileManager.default.createDirectory(at: trustDirectory, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: trustDirectory.path)
        let evidenceURL = trustDirectory.appendingPathComponent("trust.json")

        XCTAssertThrowsError(try HookTrustEvidenceStore(evidenceURL: evidenceURL).recordAcceptedHook(eventName: "Stop"))

        XCTAssertFalse(FileManager.default.fileExists(atPath: evidenceURL.path))
    }

    func testLatestEvidenceIgnoresNonPrivateEvidenceFile() throws {
        let fixture = try HooksFixture(existingJSON: nil)
        defer { fixture.cleanup() }
        let evidenceURL = fixture.root.appendingPathComponent("trust.json")
        let store = HookTrustEvidenceStore(
            evidenceURL: evidenceURL,
            clock: { Date(timeIntervalSince1970: 100) }
        )
        try store.recordAcceptedHook(eventName: "Stop")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: evidenceURL.path)

        XCTAssertNil(store.latestEvidence())
    }

    func testLatestEvidenceIgnoresEvidenceInWritableParentDirectory() throws {
        let fixture = try HooksFixture(existingJSON: nil)
        defer { fixture.cleanup() }
        let trustDirectory = fixture.root.appendingPathComponent("trust", isDirectory: true)
        try FileManager.default.createDirectory(at: trustDirectory, withIntermediateDirectories: false)
        let evidenceURL = trustDirectory.appendingPathComponent("trust.json")
        let store = HookTrustEvidenceStore(
            evidenceURL: evidenceURL,
            clock: { Date(timeIntervalSince1970: 100) }
        )
        try store.recordAcceptedHook(eventName: "Stop")
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: trustDirectory.path)

        XCTAssertNil(store.latestEvidence())
    }

    func testRecordAcceptedHookRejectsNonPrivateExistingEvidenceWithoutOverwriting() throws {
        let fixture = try HooksFixture(existingJSON: nil)
        defer { fixture.cleanup() }
        let evidenceURL = fixture.root.appendingPathComponent("trust.json")
        let original = Data(#"{"acceptedAt":"1970-01-01T00:00:00Z","eventName":"Stop"}"#.utf8)
        try original.write(to: evidenceURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: evidenceURL.path)

        XCTAssertThrowsError(try HookTrustEvidenceStore(evidenceURL: evidenceURL).recordAcceptedHook(eventName: "SessionStart"))

        XCTAssertEqual(try Data(contentsOf: evidenceURL), original)
        XCTAssertEqual(try fileMode(at: evidenceURL), 0o666)
    }
}

private struct HooksFixture {
    let root: URL
    let paths: ManagedHooksConfiguration.Paths
    let commandURL: URL

    init(existingJSON: String?) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManagedHooksConfigurationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let hooksURL = root.appendingPathComponent("hooks.json")
        commandURL = root.appendingPathComponent("Codex Remote.app/Contents/Resources/codex-remote-hook")
        try FileManager.default.createDirectory(at: commandURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: commandURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: commandURL.path)
        if let existingJSON {
            try Data(existingJSON.utf8).write(to: hooksURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: hooksURL.path)
        }
        paths = ManagedHooksConfiguration.Paths(hooksURL: hooksURL)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func readJSONObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: paths.hooksURL)) as? [String: Any])
    }

    func commands(in object: [String: Any], event: String) -> [String] {
        groups(in: object, event: event).flatMap { group in
            (group["hooks"] as? [[String: Any]])?.compactMap { $0["command"] as? String } ?? []
        }
    }

    func codexRemoteCommands(in object: [String: Any]) -> [String] {
        ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Stop"].flatMap { event in
            commands(in: object, event: event).filter { $0.contains("codex-remote-hook") }
        }
    }

    func sessionStartMatcher(in object: [String: Any]) -> String? {
        groups(in: object, event: "SessionStart").first?["matcher"] as? String
    }

    func sessionStartStatusMessage(in object: [String: Any]) -> String? {
        let hook = (groups(in: object, event: "SessionStart").first?["hooks"] as? [[String: Any]])?.first
        return hook?["statusMessage"] as? String
    }

    func mode() throws -> mode_t {
        try fileMode(at: paths.hooksURL)
    }

    func backupFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.contains("hooks.json.codex-remote-backup-") }
            .sorted()
    }

    func temporaryFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".codex-remote-hooks-") && $0.hasSuffix(".tmp") }
            .sorted()
    }

    private func groups(in object: [String: Any], event: String) -> [[String: Any]] {
        guard let hooks = object["hooks"] as? [String: Any] else {
            return []
        }
        return hooks[event] as? [[String: Any]] ?? []
    }
}

private func fileMode(at url: URL) throws -> mode_t {
    var status = stat()
    guard url.path.withCString({ lstat($0, &status) }) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    return status.st_mode & 0o777
}
