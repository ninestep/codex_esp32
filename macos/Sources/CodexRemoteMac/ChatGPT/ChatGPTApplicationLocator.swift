import AppKit
import Foundation

public struct ChatGPTApplication: Equatable, Sendable {
    public let processIdentifier: pid_t
    public let bundleIdentifier: String

    public init(processIdentifier: pid_t, bundleIdentifier: String) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
    }
}

public enum ChatGPTApplicationLocatorError: Error, Equatable, Sendable {
    case notRunning
    case multipleInstances
    case unsupportedIdentity(String)
}

@MainActor
public protocol RunningApplicationProviding: AnyObject {
    func runningApplications() -> [ChatGPTApplication]
}

@MainActor
public final class WorkspaceRunningApplicationProvider: RunningApplicationProviding {
    public init() {}

    public func runningApplications() -> [ChatGPTApplication] {
        NSWorkspace.shared.runningApplications.compactMap { application in
            guard let bundleIdentifier = application.bundleIdentifier else { return nil }
            return ChatGPTApplication(
                processIdentifier: application.processIdentifier,
                bundleIdentifier: bundleIdentifier
            )
        }
    }
}

@MainActor
public final class ChatGPTApplicationLocator {
    public static let supportedBundleIdentifier = "com.openai.codex"

    private let applicationProvider: any RunningApplicationProviding

    public init(
        applicationProvider: any RunningApplicationProviding = WorkspaceRunningApplicationProvider()
    ) {
        self.applicationProvider = applicationProvider
    }

    public func locate() throws -> ChatGPTApplication {
        let candidates = applicationProvider.runningApplications().filter {
            $0.bundleIdentifier.caseInsensitiveCompare(Self.supportedBundleIdentifier) == .orderedSame
        }
        guard !candidates.isEmpty else { throw ChatGPTApplicationLocatorError.notRunning }
        guard candidates.count == 1 else { throw ChatGPTApplicationLocatorError.multipleInstances }
        guard candidates[0].bundleIdentifier == Self.supportedBundleIdentifier else {
            throw ChatGPTApplicationLocatorError.unsupportedIdentity(candidates[0].bundleIdentifier)
        }
        return candidates[0]
    }
}
