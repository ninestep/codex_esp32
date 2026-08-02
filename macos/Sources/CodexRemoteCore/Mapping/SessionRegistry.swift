import Foundation

public enum SessionRegistryError: Error, Equatable {
    case duplicateLauncher(String)
    case terminalAlreadyBound(String)
    case unknownLauncher(String)
    case providerAlreadyBound(String)
    case unknownRemoteSession(String)
}

public actor SessionRegistry {
    private var sessionsByRemoteID: [String: RemoteSession] = [:]
    private var remoteIDByLauncher: [String: String] = [:]
    private var remoteIDByTerminal: [String: String] = [:]
    private var remoteIDByProvider: [String: String] = [:]
    private let idGenerator: @Sendable () -> String

    public init(idGenerator: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.idGenerator = idGenerator
    }

    public func registerLaunch(
        launcherInstanceID: String,
        terminalTargetID: String,
        displayTitle: String,
        workingDirectoryLabel: String
    ) throws {
        if remoteIDByLauncher[launcherInstanceID] != nil {
            throw SessionRegistryError.duplicateLauncher(launcherInstanceID)
        }
        if remoteIDByTerminal[terminalTargetID] != nil {
            throw SessionRegistryError.terminalAlreadyBound(terminalTargetID)
        }

        let remoteSessionID = idGenerator()
        let session = RemoteSession(
            remoteSessionID: remoteSessionID,
            launcherInstanceID: launcherInstanceID,
            providerSessionID: nil,
            terminalTargetID: terminalTargetID,
            displayTitle: displayTitle,
            workingDirectoryLabel: workingDirectoryLabel
        )
        sessionsByRemoteID[remoteSessionID] = session
        remoteIDByLauncher[launcherInstanceID] = remoteSessionID
        remoteIDByTerminal[terminalTargetID] = remoteSessionID
    }

    public func bindProviderSession(
        launcherInstanceID: String,
        providerSessionID: String
    ) throws -> RemoteSession {
        guard let remoteSessionID = remoteIDByLauncher[launcherInstanceID],
              var session = sessionsByRemoteID[remoteSessionID] else {
            throw SessionRegistryError.unknownLauncher(launcherInstanceID)
        }
        if remoteIDByProvider[providerSessionID] != nil {
            throw SessionRegistryError.providerAlreadyBound(providerSessionID)
        }
        if let existingProviderSessionID = session.providerSessionID {
            throw SessionRegistryError.providerAlreadyBound(existingProviderSessionID)
        }

        session.providerSessionID = providerSessionID
        sessionsByRemoteID[remoteSessionID] = session
        remoteIDByProvider[providerSessionID] = remoteSessionID
        return session
    }

    public func session(remoteSessionID: String) throws -> RemoteSession {
        guard let session = sessionsByRemoteID[remoteSessionID] else {
            throw SessionRegistryError.unknownRemoteSession(remoteSessionID)
        }
        return session
    }

    public func session(providerSessionID: String) throws -> RemoteSession {
        guard let remoteSessionID = remoteIDByProvider[providerSessionID],
              let session = sessionsByRemoteID[remoteSessionID] else {
            throw SessionRegistryError.unknownRemoteSession(providerSessionID)
        }
        return session
    }

    public func apply(
        _ result: SessionStateResult,
        providerSessionID: String
    ) throws -> RemoteSession {
        guard let remoteSessionID = remoteIDByProvider[providerSessionID],
              var session = sessionsByRemoteID[remoteSessionID] else {
            throw SessionRegistryError.unknownRemoteSession(providerSessionID)
        }

        session.state = result.state
        session.statusDetail = result.statusDetail
        session.unread = result.unread
        session.updatedAt = result.updatedAt
        sessionsByRemoteID[remoteSessionID] = session
        return session
    }

    public func activeSessions(limit: Int = 8) -> [RemoteSession] {
        Array(
            sessionsByRemoteID.values
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(limit)
        )
    }
}
