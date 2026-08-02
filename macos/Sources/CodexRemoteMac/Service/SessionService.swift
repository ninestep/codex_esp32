import CodexRemoteCore
import Foundation

public enum SessionServiceError: Error, Equatable, Sendable {
    case providerSessionMissing(String)
    case launcherInstanceMissing(String)
}

public actor SessionService {
    private let registry: SessionRegistry
    private let controller: any TerminalController
    private let reducer: SessionStateReducer
    private let classifier: WaitingInputClassifier

    public init(
        controller: any TerminalController = GhosttyAppleScriptController(),
        idGenerator: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.registry = SessionRegistry(idGenerator: idGenerator)
        self.controller = controller
        self.reducer = SessionStateReducer()
        self.classifier = WaitingInputClassifier()
    }

    @discardableResult
    public func registerFocusedLaunch(launcherInstanceID: String) async throws -> RemoteSession {
        let context = try await controller.captureFocusedTerminal()
        try await registry.registerLaunch(
            launcherInstanceID: launcherInstanceID,
            terminalTargetID: context.terminalTargetID,
            displayTitle: context.displayTitle,
            workingDirectoryLabel: URL(fileURLWithPath: context.workingDirectory).lastPathComponent
        )
        return try await session(launcherInstanceID: launcherInstanceID)
    }

    @discardableResult
    public func receiveHook(_ payload: HookPayload) async throws -> RemoteSession? {
        switch payload.hookEventName {
        case "SessionStart":
            guard let launcherInstanceID = payload.launcherInstanceID else {
                throw SessionServiceError.launcherInstanceMissing(payload.sessionID)
            }
            let session = try await registry.bindProviderSession(
                launcherInstanceID: launcherInstanceID,
                providerSessionID: payload.sessionID
            )
            return try await apply(.sessionStarted, to: session)

        case "UserPromptSubmit":
            let session = try await registry.session(providerSessionID: payload.sessionID)
            return try await apply(.userPromptSubmitted, to: session)

        case "PermissionRequest":
            let session = try await registry.session(providerSessionID: payload.sessionID)
            return try await apply(
                .permissionRequested(detail(from: payload)),
                to: session
            )

        case "Stop":
            let session = try await registry.session(providerSessionID: payload.sessionID)
            return try await apply(stopEvent(from: payload), to: session)

        default:
            return nil
        }
    }

    public func session(providerSessionID: String) async throws -> RemoteSession {
        try await registry.session(providerSessionID: providerSessionID)
    }

    public func session(remoteSessionID: String) async throws -> RemoteSession {
        try await registry.session(remoteSessionID: remoteSessionID)
    }

    public func activeSessions(limit: Int = 8) async -> [RemoteSession] {
        await registry.activeSessions(limit: limit)
    }

    @discardableResult
    public func selectSession(remoteSessionID: String) async throws -> RemoteSession {
        let session = try await registry.session(remoteSessionID: remoteSessionID)
        let providerSessionID = try requireProviderSession(session)

        try await controller.focus(terminalTargetID: session.terminalTargetID)
        guard session.state == .completeUnread else {
            return session
        }

        let result = reducer.reduce(.detailViewed, from: session.state)
        return try await registry.apply(result, providerSessionID: providerSessionID)
    }

    public func sendKey(_ key: TerminalKey, remoteSessionID: String) async throws {
        let session = try await registry.session(remoteSessionID: remoteSessionID)
        _ = try requireProviderSession(session)

        try await controller.focus(terminalTargetID: session.terminalTargetID)
        try await controller.sendKey(key, to: session.terminalTargetID)
    }

    public func scroll(deltaY: Int, remoteSessionID: String) async throws {
        let session = try await registry.session(remoteSessionID: remoteSessionID)
        _ = try requireProviderSession(session)

        try await controller.scroll(deltaY: deltaY, terminalTargetID: session.terminalTargetID)
    }

    private func apply(_ event: SessionEvent, to session: RemoteSession) async throws -> RemoteSession {
        guard let providerSessionID = session.providerSessionID else {
            throw SessionServiceError.providerSessionMissing(session.remoteSessionID)
        }

        let result = reducer.reduce(event, from: session.state)
        return try await registry.apply(result, providerSessionID: providerSessionID)
    }

    private func stopEvent(from payload: HookPayload) -> SessionEvent {
        switch classifier.classify(detail(from: payload)) {
        case .blocking(let detail):
            return .stopped(.blockingInput(detail))
        case .normal(let detail):
            return .stopped(.normal(detail))
        }
    }

    private func detail(from payload: HookPayload) -> String {
        payload.lastAssistantMessage ?? payload.message ?? ""
    }

    private func requireProviderSession(_ session: RemoteSession) throws -> String {
        guard let providerSessionID = session.providerSessionID else {
            throw SessionServiceError.providerSessionMissing(session.remoteSessionID)
        }
        return providerSessionID
    }

    private func session(launcherInstanceID: String) async throws -> RemoteSession {
        if let session = await registry.activeSessions(limit: Int.max)
            .first(where: { $0.launcherInstanceID == launcherInstanceID }) {
            return session
        }
        throw SessionRegistryError.unknownLauncher(launcherInstanceID)
    }
}
