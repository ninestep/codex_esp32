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
        if let previousRemoteID = remoteIDByTerminal[terminalTargetID],
           let previousSession = sessionsByRemoteID.removeValue(forKey: previousRemoteID) {
            remoteIDByLauncher.removeValue(forKey: previousSession.launcherInstanceID)
            remoteIDByTerminal.removeValue(forKey: previousSession.terminalTargetID)
            if let providerSessionID = previousSession.providerSessionID {
                remoteIDByProvider.removeValue(forKey: providerSessionID)
            }
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

    @discardableResult
    public func unregisterLaunch(launcherInstanceID: String) -> Bool {
        guard let remoteSessionID = remoteIDByLauncher.removeValue(forKey: launcherInstanceID),
              let session = sessionsByRemoteID.removeValue(forKey: remoteSessionID) else {
            return false
        }

        remoteIDByTerminal.removeValue(forKey: session.terminalTargetID)
        if let providerSessionID = session.providerSessionID {
            remoteIDByProvider.removeValue(forKey: providerSessionID)
        }
        return true
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

    public func apply(
        _ result: SessionStateResult,
        providerSessionID: String,
        ifCurrentState expected: RemoteSessionState
    ) throws -> RemoteSession {
        guard let remoteSessionID = remoteIDByProvider[providerSessionID],
              var session = sessionsByRemoteID[remoteSessionID] else {
            throw SessionRegistryError.unknownRemoteSession(providerSessionID)
        }

        guard session.state == expected else {
            return session
        }

        session.state = result.state
        session.statusDetail = result.statusDetail
        session.unread = result.unread
        session.updatedAt = result.updatedAt
        sessionsByRemoteID[remoteSessionID] = session
        return session
    }

    public func activeSessions(limit: Int = 8) -> [RemoteSession] {
        guard limit > 0 else {
            return []
        }

        return Array(
            sessionsByRemoteID.values
                .sorted(by: Self.compareActiveSessions)
                .prefix(limit)
        )
    }

    private static func compareActiveSessions(_ lhs: RemoteSession, _ rhs: RemoteSession) -> Bool {
        let lhsPriority = priority(for: lhs.state)
        let rhsPriority = priority(for: rhs.state)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.remoteSessionID < rhs.remoteSessionID
    }

    private static func priority(for state: RemoteSessionState) -> Int {
        switch state {
        case .requiresInput, .error:
            0
        case .working:
            1
        case .completeUnread:
            2
        case .idle:
            3
        case .offline:
            4
        }
    }
}
