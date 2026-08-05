import Darwin
import Foundation
import XCTest
@testable import CodexRemoteMac

final class ManagedShellConfigurationTests: XCTestCase {
    func testFirstInstallAppendsSingleBlockCreatesBackupAndCorrectShim() throws {
        let fixture = try ShellFixture(existingProfile: "alias ll='ls -la'\n", mode: 0o640)
        defer { fixture.cleanup() }

        let result = try fixture.configuration.install(appURL: fixture.appURL)

        XCTAssertEqual(result, .installed)
        XCTAssertTrue(try profileText(fixture.profileURL).hasSuffix("\n\(ManagedShellConfiguration.managedBlock)\n"))
        XCTAssertEqual(try symlinkDestination(fixture.shimURL), fixture.codexResourceURL.path)
        XCTAssertEqual(try posixMode(fixture.profileURL), 0o640)
        XCTAssertEqual(try posixMode(fixture.managedBinDirectoryURL), 0o700)
        XCTAssertEqual(try backupFiles(in: fixture.root).count, 1)
        XCTAssertTrue(ManagedShellConfiguration.isShellPathConfigured(try profileText(fixture.profileURL)))
    }

    func testRepeatedInstallDoesNotDuplicateBlockOrBackup() throws {
        let fixture = try ShellFixture(existingProfile: "before\n")
        defer { fixture.cleanup() }

        try fixture.configuration.install(appURL: fixture.appURL)
        let first = try profileText(fixture.profileURL)
        try fixture.configuration.install(appURL: fixture.appURL)

        XCTAssertEqual(try profileText(fixture.profileURL), first)
        XCTAssertEqual(try backupFiles(in: fixture.root).count, 1)
    }

    func testNewProfileIsCreatedWith0600Mode() throws {
        let fixture = try ShellFixture(existingProfile: nil)
        defer { fixture.cleanup() }

        try fixture.configuration.install(appURL: fixture.appURL)

        XCTAssertEqual(try posixMode(fixture.profileURL), 0o600)
    }

    func testDuplicateOrUnclosedMarkersAreRejectedWithoutChangingBytes() throws {
        for content in [
            "\(ManagedShellConfiguration.managedBlock)\n\(ManagedShellConfiguration.managedBlock)\n",
            "\(ManagedShellConfiguration.startMarker)\n",
        ] {
            let fixture = try ShellFixture(existingProfile: content)
            defer { fixture.cleanup() }
            let before = try Data(contentsOf: fixture.profileURL)

            XCTAssertThrowsError(try fixture.configuration.install(appURL: fixture.appURL)) { error in
                XCTAssertEqual(error as? ManagedShellConfigurationError, .invalidManagedBlock)
            }
            XCTAssertEqual(try Data(contentsOf: fixture.profileURL), before)
        }
    }

    func testProfileSymlinkIsRejected() throws {
        let fixture = try ShellFixture(existingProfile: nil)
        defer { fixture.cleanup() }
        let realProfile = fixture.root.appendingPathComponent("real-zshrc")
        try Data("real\n".utf8).write(to: realProfile)
        try FileManager.default.createSymbolicLink(at: fixture.profileURL, withDestinationURL: realProfile)

        XCTAssertThrowsError(try fixture.configuration.install(appURL: fixture.appURL)) { error in
            XCTAssertEqual(error as? ManagedShellConfigurationError, .invalidProfile)
        }
    }

    func testManagedDirectoryWithWidePermissionsIsRejectedWithoutChmod() throws {
        let fixture = try ShellFixture(existingProfile: "")
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.managedBinDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.managedBinDirectoryURL.path)

        XCTAssertThrowsError(try fixture.configuration.install(appURL: fixture.appURL)) { error in
            XCTAssertEqual(error as? ManagedShellConfigurationError, .invalidManagedBinDirectory)
        }
        XCTAssertEqual(try posixMode(fixture.managedBinDirectoryURL), 0o755)
    }

    func testManagedDirectoryAncestorSymlinkIsRejectedWithoutWritingThroughIt() throws {
        let fixture = try ShellFixture(existingProfile: "before\n")
        defer { fixture.cleanup() }
        let external = fixture.root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent(".codex-remote"),
            withDestinationURL: external
        )
        let before = try Data(contentsOf: fixture.profileURL)

        XCTAssertThrowsError(try fixture.configuration.install(appURL: fixture.appURL)) { error in
            XCTAssertEqual(error as? ManagedShellConfigurationError, .invalidManagedBinDirectory)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.profileURL), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: external.appendingPathComponent("bin/codex").path))
    }

    func testManagedDirectoryAncestorSymlinkIsRejectedWhenExternalBinAlreadyExists() throws {
        let fixture = try ShellFixture(existingProfile: "before\n")
        defer { fixture.cleanup() }
        let externalBin = fixture.root.appendingPathComponent("external/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: externalBin, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: externalBin.path)
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent(".codex-remote"),
            withDestinationURL: externalBin.deletingLastPathComponent()
        )
        let before = try Data(contentsOf: fixture.profileURL)

        XCTAssertThrowsError(try fixture.configuration.install(appURL: fixture.appURL)) { error in
            XCTAssertEqual(error as? ManagedShellConfigurationError, .invalidManagedBinDirectory)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.profileURL), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: externalBin.appendingPathComponent("codex").path))
    }

    func testManagedDirectoryRootWithWidePermissionsIsRejectedWithoutWriting() throws {
        let fixture = try ShellFixture(existingProfile: "before\n")
        defer { fixture.cleanup() }
        let managedRoot = fixture.root.appendingPathComponent(".codex-remote", isDirectory: true)
        try FileManager.default.createDirectory(at: managedRoot, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: managedRoot.path)
        let before = try Data(contentsOf: fixture.profileURL)

        XCTAssertThrowsError(try fixture.configuration.install(appURL: fixture.appURL)) { error in
            XCTAssertEqual(error as? ManagedShellConfigurationError, .invalidManagedBinDirectory)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.profileURL), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.shimURL.path))
        XCTAssertEqual(try posixMode(managedRoot), 0o777)
    }

    func testManagedDirectoryRootWithMissingOwnerExecuteIsRejectedWithoutWriting() throws {
        let fixture = try ShellFixture(existingProfile: "before\n")
        defer { fixture.cleanup() }
        let managedRoot = fixture.root.appendingPathComponent(".codex-remote", isDirectory: true)
        try FileManager.default.createDirectory(at: managedRoot, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: managedRoot.path)
        let before = try Data(contentsOf: fixture.profileURL)

        XCTAssertThrowsError(try fixture.configuration.install(appURL: fixture.appURL)) { error in
            XCTAssertEqual(error as? ManagedShellConfigurationError, .invalidManagedBinDirectory)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.profileURL), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.shimURL.path))
        XCTAssertEqual(try posixMode(managedRoot), 0o600)
    }

    func testManagedBinDirectoryWithMissingOwnerWriteIsRejectedWithoutWriting() throws {
        let fixture = try ShellFixture(existingProfile: "before\n")
        defer { fixture.cleanup() }
        let managedRoot = fixture.managedBinDirectoryURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: fixture.managedBinDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: managedRoot.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.managedBinDirectoryURL.path)
        let before = try Data(contentsOf: fixture.profileURL)

        XCTAssertThrowsError(try fixture.configuration.install(appURL: fixture.appURL)) { error in
            XCTAssertEqual(error as? ManagedShellConfigurationError, .invalidManagedBinDirectory)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.profileURL), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.shimURL.path))
        XCTAssertEqual(try posixMode(fixture.managedBinDirectoryURL), 0o500)
    }

    func testManagedDirectoryRootWithDifferentOwnerIsRejectedWithoutWriting() throws {
        let fixture = try ShellFixture(existingProfile: "before\n")
        defer { fixture.cleanup() }
        let managedRoot = fixture.root.appendingPathComponent(".codex-remote", isDirectory: true)
        try FileManager.default.createDirectory(at: managedRoot, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: managedRoot.path)
        let before = try Data(contentsOf: fixture.profileURL)
        let configuration = ManagedShellConfiguration(
            profileURL: fixture.profileURL,
            managedBinDirectoryURL: fixture.managedBinDirectoryURL,
            shimURL: fixture.shimURL,
            fileOperations: NonOwnerManagedShellFileOperations(nonOwnerURL: managedRoot)
        )

        XCTAssertThrowsError(try configuration.install(appURL: fixture.appURL)) { error in
            XCTAssertEqual(error as? ManagedShellConfigurationError, .invalidManagedBinDirectory)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.profileURL), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.shimURL.path))
    }

    func testForeignShimIsRejectedAndNotOverwritten() throws {
        let fixture = try ShellFixture(existingProfile: "")
        defer { fixture.cleanup() }
        let managedRoot = fixture.managedBinDirectoryURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: fixture.managedBinDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: managedRoot.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.managedBinDirectoryURL.path)
        let foreign = fixture.root.appendingPathComponent("foreign-codex")
        try Data("foreign".utf8).write(to: foreign)
        try FileManager.default.createSymbolicLink(at: fixture.shimURL, withDestinationURL: foreign)

        XCTAssertThrowsError(try fixture.configuration.install(appURL: fixture.appURL)) { error in
            XCTAssertEqual(error as? ManagedShellConfigurationError, .conflict)
        }
        XCTAssertEqual(try symlinkDestination(fixture.shimURL), foreign.path)
    }

    func testInstallRollsBackProfileWhenShimCreationFails() throws {
        let fixture = try ShellFixture(existingProfile: "before\n")
        defer { fixture.cleanup() }
        let before = try Data(contentsOf: fixture.profileURL)
        let configuration = ManagedShellConfiguration(
            profileURL: fixture.profileURL,
            managedBinDirectoryURL: fixture.managedBinDirectoryURL,
            shimURL: fixture.shimURL,
            fileOperations: FailingShimManagedShellFileOperations()
        )

        XCTAssertThrowsError(try configuration.install(appURL: fixture.appURL)) { error in
            XCTAssertEqual(error as? ManagedShellConfigurationError, .writeFailed)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.profileURL), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.shimURL.path))
    }

    func testInstallDoesNotCreateShimWhenProfileWriteFails() throws {
        let fixture = try ShellFixture(existingProfile: "before\n")
        defer { fixture.cleanup() }
        let configuration = ManagedShellConfiguration(
            profileURL: fixture.profileURL,
            managedBinDirectoryURL: fixture.managedBinDirectoryURL,
            shimURL: fixture.shimURL,
            fileOperations: FailingProfileWriteManagedShellFileOperations()
        )

        XCTAssertThrowsError(try configuration.install(appURL: fixture.appURL)) { error in
            XCTAssertEqual(error as? ManagedShellConfigurationError, .writeFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.shimURL.path))
        XCTAssertEqual(try profileText(fixture.profileURL), "before\n")
    }

    func testRestoreOnlyDeletesManagedBlockAndOwnedShim() throws {
        let fixture = try ShellFixture(existingProfile: "before\n")
        defer { fixture.cleanup() }
        try fixture.configuration.install(appURL: fixture.appURL)
        try Data("after\n".utf8).write(to: fixture.profileURL, options: .atomic)
        try Data("before\n\(ManagedShellConfiguration.managedBlock)\nafter\n".utf8).write(to: fixture.profileURL, options: .atomic)

        let result = try fixture.configuration.restore(appURL: fixture.appURL)

        XCTAssertEqual(result, .restored)
        XCTAssertEqual(try profileText(fixture.profileURL), "before\nafter\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.shimURL.path))
    }

    func testRestoreRollsBackProfileWhenShimRemovalFails() throws {
        let fixture = try ShellFixture(existingProfile: "before\n")
        defer { fixture.cleanup() }
        try fixture.configuration.install(appURL: fixture.appURL)
        let before = try Data(contentsOf: fixture.profileURL)
        let beforeMode = try posixMode(fixture.profileURL)
        let configuration = ManagedShellConfiguration(
            profileURL: fixture.profileURL,
            managedBinDirectoryURL: fixture.managedBinDirectoryURL,
            shimURL: fixture.shimURL,
            fileOperations: FailingShimRemovalManagedShellFileOperations()
        )

        XCTAssertThrowsError(try configuration.restore(appURL: fixture.appURL)) { error in
            XCTAssertEqual(error as? ManagedShellConfigurationError, .writeFailed)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.profileURL), before)
        XCTAssertEqual(try posixMode(fixture.profileURL), beforeMode)
        XCTAssertEqual(try symlinkDestination(fixture.shimURL), fixture.codexResourceURL.path)
    }

    func testRestoreReportsRollbackFailedWhenProfileRollbackFails() throws {
        let fixture = try ShellFixture(existingProfile: "before\n")
        defer { fixture.cleanup() }
        try fixture.configuration.install(appURL: fixture.appURL)
        let configuration = ManagedShellConfiguration(
            profileURL: fixture.profileURL,
            managedBinDirectoryURL: fixture.managedBinDirectoryURL,
            shimURL: fixture.shimURL,
            fileOperations: FailingShimRemovalAndRollbackManagedShellFileOperations()
        )

        XCTAssertThrowsError(try configuration.restore(appURL: fixture.appURL)) { error in
            XCTAssertEqual(error as? ManagedShellConfigurationError, .rollbackFailed)
        }
    }

    func testRestoreRollsBackProfileWhenOwnedShimBecomesForeignAfterProfileWrite() throws {
        let fixture = try ShellFixture(existingProfile: "before\n", mode: 0o640)
        defer { fixture.cleanup() }
        try fixture.configuration.install(appURL: fixture.appURL)
        let before = try Data(contentsOf: fixture.profileURL)
        let beforeMode = try posixMode(fixture.profileURL)
        let foreign = fixture.root.appendingPathComponent("foreign-codex")
        try Data("foreign".utf8).write(to: foreign)
        let configuration = ManagedShellConfiguration(
            profileURL: fixture.profileURL,
            managedBinDirectoryURL: fixture.managedBinDirectoryURL,
            shimURL: fixture.shimURL,
            fileOperations: ShimRaceManagedShellFileOperations(foreignTargetURL: foreign)
        )

        XCTAssertThrowsError(try configuration.restore(appURL: fixture.appURL)) { error in
            XCTAssertEqual(error as? ManagedShellConfigurationError, .conflict)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.profileURL), before)
        XCTAssertEqual(try posixMode(fixture.profileURL), beforeMode)
        XCTAssertEqual(try symlinkDestination(fixture.shimURL), foreign.path)
    }

    func testRestoreTreatsOwnedShimMissingAfterProfileWriteAsAlreadyCleaned() throws {
        let fixture = try ShellFixture(existingProfile: "before\n", mode: 0o640)
        defer { fixture.cleanup() }
        try fixture.configuration.install(appURL: fixture.appURL)
        let configuration = ManagedShellConfiguration(
            profileURL: fixture.profileURL,
            managedBinDirectoryURL: fixture.managedBinDirectoryURL,
            shimURL: fixture.shimURL,
            fileOperations: ShimMissingAfterProfileWriteManagedShellFileOperations()
        )

        let result = try configuration.restore(appURL: fixture.appURL)

        XCTAssertEqual(result, .restored)
        XCTAssertEqual(try profileText(fixture.profileURL), "before\n")
        XCTAssertEqual(try posixMode(fixture.profileURL), 0o640)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.shimURL.path))
    }

    func testRestoreDoesNotDeleteForeignReplacedShim() throws {
        let fixture = try ShellFixture(existingProfile: "before\n")
        defer { fixture.cleanup() }
        try fixture.configuration.install(appURL: fixture.appURL)
        try FileManager.default.removeItem(at: fixture.shimURL)
        let foreign = fixture.root.appendingPathComponent("foreign-codex")
        try Data("foreign".utf8).write(to: foreign)
        try FileManager.default.createSymbolicLink(at: fixture.shimURL, withDestinationURL: foreign)

        XCTAssertThrowsError(try fixture.configuration.restore(appURL: fixture.appURL)) { error in
            XCTAssertEqual(error as? ManagedShellConfigurationError, .conflict)
        }
        XCTAssertEqual(try symlinkDestination(fixture.shimURL), foreign.path)
        XCTAssertTrue(try profileText(fixture.profileURL).contains(ManagedShellConfiguration.managedBlock))
    }
}

private final class FailingShimManagedShellFileOperations: LocalManagedShellFileOperations, @unchecked Sendable {
    override func createSymbolicLink(at url: URL, withDestinationURL destination: URL) throws {
        throw CocoaError(.fileWriteUnknown)
    }
}

private final class FailingProfileWriteManagedShellFileOperations: LocalManagedShellFileOperations, @unchecked Sendable {
    override func createTemporaryFile(in parentURL: URL, prefix: String, data: Data, mode: mode_t) throws -> URL {
        throw CocoaError(.fileWriteUnknown)
    }
}

private final class FailingShimRemovalManagedShellFileOperations: LocalManagedShellFileOperations, @unchecked Sendable {
    override func removeItem(at url: URL) throws {
        if url.lastPathComponent == "codex" {
            throw CocoaError(.fileWriteUnknown)
        }
        try super.removeItem(at: url)
    }
}

private final class FailingShimRemovalAndRollbackManagedShellFileOperations: LocalManagedShellFileOperations, @unchecked Sendable {
    private var profileWriteCount = 0

    override func replaceFile(at url: URL, withPreparedTemporaryFile temporaryURL: URL) throws {
        if url.lastPathComponent == ".zshrc" {
            profileWriteCount += 1
            if profileWriteCount >= 2 {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try super.replaceFile(at: url, withPreparedTemporaryFile: temporaryURL)
    }

    override func removeItem(at url: URL) throws {
        if url.lastPathComponent == "codex" {
            throw CocoaError(.fileWriteUnknown)
        }
        try super.removeItem(at: url)
    }
}

private final class ShimRaceManagedShellFileOperations: LocalManagedShellFileOperations, @unchecked Sendable {
    private let foreignTargetURL: URL
    private var profileWriteCount = 0

    init(foreignTargetURL: URL) {
        self.foreignTargetURL = foreignTargetURL
        super.init()
    }

    override func replaceFile(at url: URL, withPreparedTemporaryFile temporaryURL: URL) throws {
        try super.replaceFile(at: url, withPreparedTemporaryFile: temporaryURL)
        if url.lastPathComponent == ".zshrc" {
            profileWriteCount += 1
            if profileWriteCount == 1 {
                let shim = url.deletingLastPathComponent().appendingPathComponent(".codex-remote/bin/codex")
                try FileManager.default.removeItem(at: shim)
                try FileManager.default.createSymbolicLink(at: shim, withDestinationURL: foreignTargetURL)
            }
        }
    }
}

private final class ShimMissingAfterProfileWriteManagedShellFileOperations: LocalManagedShellFileOperations, @unchecked Sendable {
    private var profileWriteCount = 0

    override func replaceFile(at url: URL, withPreparedTemporaryFile temporaryURL: URL) throws {
        try super.replaceFile(at: url, withPreparedTemporaryFile: temporaryURL)
        if url.lastPathComponent == ".zshrc" {
            profileWriteCount += 1
            if profileWriteCount == 1 {
                let shim = url.deletingLastPathComponent().appendingPathComponent(".codex-remote/bin/codex")
                try FileManager.default.removeItem(at: shim)
            }
        }
    }
}

private final class NonOwnerManagedShellFileOperations: LocalManagedShellFileOperations, @unchecked Sendable {
    private let nonOwnerURL: URL

    init(nonOwnerURL: URL) {
        self.nonOwnerURL = nonOwnerURL.standardizedFileURL
        super.init()
    }

    override func ownerUserID(at url: URL) throws -> uid_t {
        if url.standardizedFileURL.path == nonOwnerURL.path {
            return Darwin.geteuid() + 1
        }
        return try super.ownerUserID(at: url)
    }
}

private struct ShellFixture {
    let root: URL
    let profileURL: URL
    let managedBinDirectoryURL: URL
    let shimURL: URL
    let appURL: URL
    let codexResourceURL: URL
    let configuration: ManagedShellConfiguration

    init(existingProfile: String?, mode: mode_t = 0o600) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManagedShellConfigurationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        profileURL = root.appendingPathComponent(".zshrc")
        managedBinDirectoryURL = root.appendingPathComponent(".codex-remote/bin", isDirectory: true)
        shimURL = managedBinDirectoryURL.appendingPathComponent("codex")
        appURL = root.appendingPathComponent("Codex Remote.app", isDirectory: true)
        codexResourceURL = appURL.appendingPathComponent("Contents/Resources/codex")
        try FileManager.default.createDirectory(at: codexResourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("codex".utf8).write(to: codexResourceURL)
        if let existingProfile {
            try Data(existingProfile.utf8).write(to: profileURL)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: profileURL.path)
        }
        configuration = ManagedShellConfiguration(
            profileURL: profileURL,
            managedBinDirectoryURL: managedBinDirectoryURL,
            shimURL: shimURL
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func profileText(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
}

private func symlinkDestination(_ url: URL) throws -> String {
    try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
}

private func backupFiles(in root: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.contains(".zshrc.codex-remote-backup-") }
}

private func posixMode(_ url: URL) throws -> mode_t {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return mode_t((attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0) & 0o777
}
