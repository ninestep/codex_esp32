import Foundation
import XCTest
@testable import CodexRemoteMac

final class ApplicationInstallerTests: XCTestCase {
    func testValidInstallCopiesBundleToDestinationAndRequiresRelaunch() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Build/Codex Remote.app", isDirectory: true)
        let destination = root.appendingPathComponent("Applications/Codex Remote.app", isDirectory: true)
        try makeValidApplicationBundle(at: source, payload: "v1")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let result = try ApplicationInstaller().install(sourceApplicationURL: source, destinationApplicationURL: destination)

        XCTAssertEqual(result, .installedAndRequiresRelaunch(destination.standardizedFileURL))
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("Contents/Resources/codex"), encoding: .utf8),
            "v1"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testInvalidSourceDoesNotReplaceExistingApplication() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Invalid.app", isDirectory: true)
        let destination = root.appendingPathComponent("Applications/Codex Remote.app", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try makeValidApplicationBundle(at: destination, payload: "old")

        XCTAssertThrowsError(try ApplicationInstaller().install(
            sourceApplicationURL: source,
            destinationApplicationURL: destination
        )) { error in
            XCTAssertEqual(error as? ApplicationInstallError, .invalidSource)
        }
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("Contents/Resources/codex"), encoding: .utf8),
            "old"
        )
    }

    func testExistingDestinationIsReplacedWithoutDeletingFirst() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Build/Codex Remote.app", isDirectory: true)
        let destination = root.appendingPathComponent("Applications/Codex Remote.app", isDirectory: true)
        try makeValidApplicationBundle(at: source, payload: "new")
        try makeValidApplicationBundle(at: destination, payload: "old")

        _ = try ApplicationInstaller().install(sourceApplicationURL: source, destinationApplicationURL: destination)

        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("Contents/Resources/codex"), encoding: .utf8),
            "new"
        )
        let backups = try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
            .filter { $0.contains("Codex Remote.app.backup-") }
        XCTAssertEqual(backups.count, 1)
    }

    func testRejectsNonStandardDestinationBeforeWriting() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Build/Codex Remote.app", isDirectory: true)
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let destination = applications
            .appendingPathComponent("Nested/..", isDirectory: true)
            .appendingPathComponent("Codex Remote.app", isDirectory: true)
        try makeValidApplicationBundle(at: source, payload: "v1")
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)

        XCTAssertThrowsError(try ApplicationInstaller().install(
            sourceApplicationURL: source,
            destinationApplicationURL: destination
        )) { error in
            XCTAssertEqual(error as? ApplicationInstallError, .unsafePath)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: applications.path), [])
    }

    func testStagingVerificationFailureKeepsExistingDestination() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Build/Codex Remote.app", isDirectory: true)
        let destination = root.appendingPathComponent("Applications/Codex Remote.app", isDirectory: true)
        try makeValidApplicationBundle(at: source, payload: "new")
        try makeValidApplicationBundle(at: destination, payload: "old")
        let operations = CorruptingApplicationInstallerFileOperations()

        XCTAssertThrowsError(try ApplicationInstaller(fileOperations: operations).install(
            sourceApplicationURL: source,
            destinationApplicationURL: destination
        )) { error in
            XCTAssertEqual(error as? ApplicationInstallError, .verificationFailed)
        }
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("Contents/Resources/codex"), encoding: .utf8),
            "old"
        )
    }

    func testReplacementFailureRestoresExistingDestination() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Build/Codex Remote.app", isDirectory: true)
        let destination = root.appendingPathComponent("Applications/Codex Remote.app", isDirectory: true)
        try makeValidApplicationBundle(at: source, payload: "new")
        try makeValidApplicationBundle(at: destination, payload: "old")
        let operations = FailingReplacementApplicationInstallerFileOperations()

        XCTAssertThrowsError(try ApplicationInstaller(fileOperations: operations).install(
            sourceApplicationURL: source,
            destinationApplicationURL: destination
        )) { error in
            XCTAssertEqual(error as? ApplicationInstallError, .replacementFailed)
        }
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("Contents/Resources/codex"), encoding: .utf8),
            "old"
        )
    }

    func testReplacementAndRollbackFailurePreservesBackupAndReturnsRollbackFailed() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Build/Codex Remote.app", isDirectory: true)
        let destination = root.appendingPathComponent("Applications/Codex Remote.app", isDirectory: true)
        try makeValidApplicationBundle(at: source, payload: "new")
        try makeValidApplicationBundle(at: destination, payload: "old")
        let operations = FailingReplacementAndRollbackApplicationInstallerFileOperations()

        XCTAssertThrowsError(try ApplicationInstaller(fileOperations: operations).install(
            sourceApplicationURL: source,
            destinationApplicationURL: destination
        )) { error in
            XCTAssertEqual(error as? ApplicationInstallError, .rollbackFailed)
        }
        let backupPayloads = try operations.backupURLs.map {
            try String(contentsOf: $0.appendingPathComponent("Contents/Resources/codex"), encoding: .utf8)
        }
        XCTAssertTrue(backupPayloads.contains("old"))
    }

    func testPartialBackupCopyFailureKeepsDestinationAndDoesNotRestore() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Build/Codex Remote.app", isDirectory: true)
        let destination = root.appendingPathComponent("Applications/Codex Remote.app", isDirectory: true)
        try makeValidApplicationBundle(at: source, payload: "new")
        try makeValidApplicationBundle(at: destination, payload: "old")
        let operations = PartialBackupCopyFailureApplicationInstallerFileOperations()

        XCTAssertThrowsError(try ApplicationInstaller(fileOperations: operations).install(
            sourceApplicationURL: source,
            destinationApplicationURL: destination
        )) { error in
            XCTAssertEqual(error as? ApplicationInstallError, .replacementFailed)
        }
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("Contents/Resources/codex"), encoding: .utf8),
            "old"
        )
        XCTAssertFalse(operations.replaceAttempted)
        XCTAssertFalse(operations.restoreAttempted)
    }

    func testBackupValidationFailureKeepsDestinationAndDoesNotReplaceOrRestore() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Build/Codex Remote.app", isDirectory: true)
        let destination = root.appendingPathComponent("Applications/Codex Remote.app", isDirectory: true)
        try makeValidApplicationBundle(at: source, payload: "new")
        try makeValidApplicationBundle(at: destination, payload: "old")
        let operations = BackupValidationMismatchApplicationInstallerFileOperations(source: source, destination: destination)

        XCTAssertThrowsError(try ApplicationInstaller(fileOperations: operations).install(
            sourceApplicationURL: source,
            destinationApplicationURL: destination
        )) { error in
            XCTAssertEqual(error as? ApplicationInstallError, .verificationFailed)
        }
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("Contents/Resources/codex"), encoding: .utf8),
            "old"
        )
        XCTAssertFalse(operations.replaceAttempted)
        XCTAssertFalse(operations.restoreAttempted)
        XCTAssertEqual(operations.remainingBackupStagingURLs(), [])
    }

    func testReplaceSuccessThenDestinationValidationFailureRestoresOldDestination() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Build/Codex Remote.app", isDirectory: true)
        let destination = root.appendingPathComponent("Applications/Codex Remote.app", isDirectory: true)
        try makeValidApplicationBundle(at: source, payload: "new")
        try makeValidApplicationBundle(at: destination, payload: "old")
        let operations = ReplacingWithInvalidApplicationInstallerFileOperations()

        XCTAssertThrowsError(try ApplicationInstaller(fileOperations: operations).install(
            sourceApplicationURL: source,
            destinationApplicationURL: destination
        )) { error in
            XCTAssertEqual(error as? ApplicationInstallError, .replacementFailed)
        }
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("Contents/Resources/codex"), encoding: .utf8),
            "old"
        )
    }

    func testReplaceSuccessThenValidationFailureAndRestoreFailureKeepsBackup() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Build/Codex Remote.app", isDirectory: true)
        let destination = root.appendingPathComponent("Applications/Codex Remote.app", isDirectory: true)
        try makeValidApplicationBundle(at: source, payload: "new")
        try makeValidApplicationBundle(at: destination, payload: "old")
        let operations = InvalidReplacementAndRestoreFailureApplicationInstallerFileOperations()

        XCTAssertThrowsError(try ApplicationInstaller(fileOperations: operations).install(
            sourceApplicationURL: source,
            destinationApplicationURL: destination
        )) { error in
            XCTAssertEqual(error as? ApplicationInstallError, .rollbackFailed)
        }
        let backupPayloads = try operations.backupURLs.map {
            try String(contentsOf: $0.appendingPathComponent("Contents/Resources/codex"), encoding: .utf8)
        }
        XCTAssertTrue(backupPayloads.contains("old"))
    }

    func testIdempotentComparisonDetectsSymlinkEntryDifferences() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Build/Codex Remote.app", isDirectory: true)
        let destination = root.appendingPathComponent("Applications/Codex Remote.app", isDirectory: true)
        try makeValidApplicationBundle(at: source, payload: "new")
        try makeValidApplicationBundle(at: destination, payload: "new")
        let sourceLink = source.appendingPathComponent("Contents/Resources/current")
        let destinationLink = destination.appendingPathComponent("Contents/Resources/current")
        try FileManager.default.createSymbolicLink(atPath: sourceLink.path, withDestinationPath: "codex")
        try FileManager.default.createSymbolicLink(atPath: destinationLink.path, withDestinationPath: "codex-old")

        _ = try ApplicationInstaller().install(sourceApplicationURL: source, destinationApplicationURL: destination)

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destinationLink.path), "codex")
    }

    func testRejectsSourceEqualToDestination() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Codex Remote.app", isDirectory: true)
        try makeValidApplicationBundle(at: app, payload: "v1")

        XCTAssertThrowsError(try ApplicationInstaller().install(
            sourceApplicationURL: app,
            destinationApplicationURL: app
        )) { error in
            XCTAssertEqual(error as? ApplicationInstallError, .invalidDestination)
        }
    }

    func testPermissionErrorsAreMappedWithoutLeakingInternalError() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Build/Codex Remote.app", isDirectory: true)
        let destination = root.appendingPathComponent("Applications/Codex Remote.app", isDirectory: true)
        try makeValidApplicationBundle(at: source, payload: "v1")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        XCTAssertThrowsError(try ApplicationInstaller(
            fileOperations: PermissionDeniedApplicationInstallerFileOperations()
        ).install(sourceApplicationURL: source, destinationApplicationURL: destination)) { error in
            XCTAssertEqual(error as? ApplicationInstallError, .permissionDenied)
        }
    }
}

private final class CorruptingApplicationInstallerFileOperations: LocalApplicationInstallerFileOperations, @unchecked Sendable {
    override func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try super.copyItem(at: sourceURL, to: destinationURL)
        try FileManager.default.removeItem(at: destinationURL.appendingPathComponent("Contents/Resources/codex"))
    }
}

private final class FailingReplacementApplicationInstallerFileOperations: LocalApplicationInstallerFileOperations, @unchecked Sendable {
    override func replaceItem(at destinationURL: URL, with sourceURL: URL) throws {
        throw CocoaError(.fileWriteUnknown)
    }
}

private final class FailingReplacementAndRollbackApplicationInstallerFileOperations: LocalApplicationInstallerFileOperations, @unchecked Sendable {
    private(set) var backupURLs: [URL] = []

    override func replaceItem(at destinationURL: URL, with sourceURL: URL) throws {
        throw CocoaError(.fileWriteUnknown)
    }

    override func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        if backupURLs.contains(sourceURL), destinationURL.lastPathComponent == "Codex Remote.app" {
            throw CocoaError(.fileWriteUnknown)
        }
        try super.moveItem(at: sourceURL, to: destinationURL)
        if destinationURL.lastPathComponent.contains(".backup-"),
           !destinationURL.lastPathComponent.contains(".backup-staging-") {
            backupURLs.append(destinationURL)
        }
    }
}

private final class PartialBackupCopyFailureApplicationInstallerFileOperations: LocalApplicationInstallerFileOperations, @unchecked Sendable {
    private(set) var replaceAttempted = false
    private(set) var restoreAttempted = false

    override func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        guard destinationURL.lastPathComponent.contains(".backup-staging-") else {
            try super.copyItem(at: sourceURL, to: destinationURL)
            return
        }
        let partialResource = destinationURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: partialResource, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: partialResource.appendingPathComponent("codex"))
        throw CocoaError(.fileWriteUnknown)
    }

    override func replaceItem(at destinationURL: URL, with sourceURL: URL) throws {
        replaceAttempted = true
        try super.replaceItem(at: destinationURL, with: sourceURL)
    }

    override func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        if sourceURL.lastPathComponent.contains(".backup-"),
           !sourceURL.lastPathComponent.contains(".backup-staging-"),
           destinationURL.lastPathComponent == "Codex Remote.app" {
            restoreAttempted = true
        }
        try super.moveItem(at: sourceURL, to: destinationURL)
    }
}

private final class BackupValidationMismatchApplicationInstallerFileOperations: LocalApplicationInstallerFileOperations, @unchecked Sendable {
    private let source: URL
    private let destination: URL
    private(set) var replaceAttempted = false
    private(set) var restoreAttempted = false
    private(set) var backupStagingURLs: [URL] = []

    init(source: URL, destination: URL) {
        self.source = source.standardizedFileURL
        self.destination = destination.standardizedFileURL
        super.init()
    }

    override func directoryContentsEqual(_ lhs: URL, _ rhs: URL) throws -> Bool {
        if lhs.standardizedFileURL.path == source.path,
           rhs.standardizedFileURL.path == destination.path {
            return false
        }
        if rhs.lastPathComponent.contains(".backup-staging-") {
            return false
        }
        return try super.directoryContentsEqual(lhs, rhs)
    }

    override func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        if destinationURL.lastPathComponent.contains(".backup-staging-") {
            backupStagingURLs.append(destinationURL)
        }
        try super.copyItem(at: sourceURL, to: destinationURL)
    }

    override func replaceItem(at destinationURL: URL, with sourceURL: URL) throws {
        replaceAttempted = true
        try super.replaceItem(at: destinationURL, with: sourceURL)
    }

    override func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        if sourceURL.lastPathComponent.contains(".backup-"),
           !sourceURL.lastPathComponent.contains(".backup-staging-"),
           destinationURL.lastPathComponent == "Codex Remote.app" {
            restoreAttempted = true
        }
        try super.moveItem(at: sourceURL, to: destinationURL)
    }

    func remainingBackupStagingURLs() -> [URL] {
        backupStagingURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

private final class ReplacingWithInvalidApplicationInstallerFileOperations: LocalApplicationInstallerFileOperations, @unchecked Sendable {
    private(set) var backupURLs: [URL] = []

    override func replaceItem(at destinationURL: URL, with sourceURL: URL) throws {
        try super.replaceItem(at: destinationURL, with: sourceURL)
        try FileManager.default.removeItem(at: destinationURL.appendingPathComponent("Contents/Resources/codex"))
    }

    override func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try super.moveItem(at: sourceURL, to: destinationURL)
        if destinationURL.lastPathComponent.contains(".backup-"),
           !destinationURL.lastPathComponent.contains(".backup-staging-") {
            backupURLs.append(destinationURL)
        }
    }
}

private final class InvalidReplacementAndRestoreFailureApplicationInstallerFileOperations: LocalApplicationInstallerFileOperations, @unchecked Sendable {
    private(set) var backupURLs: [URL] = []

    override func replaceItem(at destinationURL: URL, with sourceURL: URL) throws {
        try super.replaceItem(at: destinationURL, with: sourceURL)
        try FileManager.default.removeItem(at: destinationURL.appendingPathComponent("Contents/Resources/codex"))
    }

    override func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        if backupURLs.contains(sourceURL), destinationURL.lastPathComponent == "Codex Remote.app" {
            throw CocoaError(.fileWriteUnknown)
        }
        try super.moveItem(at: sourceURL, to: destinationURL)
        if destinationURL.lastPathComponent.contains(".backup-"),
           !destinationURL.lastPathComponent.contains(".backup-staging-") {
            backupURLs.append(destinationURL)
        }
    }
}

private final class PermissionDeniedApplicationInstallerFileOperations: LocalApplicationInstallerFileOperations, @unchecked Sendable {
    override func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

private func makeValidApplicationBundle(at url: URL, payload: String) throws {
    let macOS = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
    let resources = url.appendingPathComponent("Contents/Resources", isDirectory: true)
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    try writeExecutable("app", to: macOS.appendingPathComponent("codex-remote-app"))
    try writeExecutable("helper", to: macOS.appendingPathComponent("codex-remote-helper"))
    try writeExecutable(payload, to: resources.appendingPathComponent("codex"))
    try writeExecutable("hook", to: resources.appendingPathComponent("codex-remote-hook"))
    try Data("{}".utf8).write(to: resources.appendingPathComponent("codex-remote-hooks.json"))
}

private func writeExecutable(_ value: String, to url: URL) throws {
    try Data(value.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ApplicationInstallerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
