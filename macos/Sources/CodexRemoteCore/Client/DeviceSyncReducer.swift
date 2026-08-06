public struct DeviceSyncReducer: Sendable {
    public private(set) var connectionState: DeviceConnectionState = .disconnected

    private var latestSessions: [RemoteSession] = []
    private var projectedByRemoteID: [String: DeviceSession] = [:]
    private var sessionKeyByRemoteID: [String: UInt16] = [:]
    private var nextSessionKey: UInt16 = 1

    public init() {}

    @discardableResult
    public mutating func connect(remoteVersion: BLEProtocolVersion) -> [BLEMessage] {
        guard remoteVersion.major == BLEProtocolVersion.current.major else {
            connectionState = .incompatible(remoteMajor: remoteVersion.major)
            return []
        }

        let projected = project(latestSessions)
        projectedByRemoteID = Dictionary(uniqueKeysWithValues: zip(latestSessions.map(\.remoteSessionID), projected))
        connectionState = .ready(generation: 1, lastDeltaSequence: 0)
        return [.stateSnapshot(generation: 1, sessions: projected)]
    }

    @discardableResult
    public mutating func updateSessions(_ sessions: [RemoteSession]) -> [BLEMessage] {
        latestSessions = Array(sessions.prefix(8))
        guard case let .ready(generation, lastDeltaSequence) = connectionState else {
            return []
        }

        let projected = project(latestSessions)
        let remoteIDs = latestSessions.map(\.remoteSessionID)
        let previousIDs = Set(projectedByRemoteID.keys)
        let currentIDs = Set(remoteIDs)

        if previousIDs != currentIDs {
            let nextGeneration = generation + 1
            projectedByRemoteID = Dictionary(uniqueKeysWithValues: zip(remoteIDs, projected))
            connectionState = .ready(generation: nextGeneration, lastDeltaSequence: 0)
            return [.stateSnapshot(generation: nextGeneration, sessions: projected)]
        }

        var sequence = lastDeltaSequence
        var messages: [BLEMessage] = []
        for (remoteID, session) in zip(remoteIDs, projected) where projectedByRemoteID[remoteID] != session {
            sequence += 1
            projectedByRemoteID[remoteID] = session
            messages.append(.stateDelta(generation: generation, sequence: sequence, session: session))
        }
        connectionState = .ready(generation: generation, lastDeltaSequence: sequence)
        return messages
    }

    public mutating func resync() -> [BLEMessage] {
        guard case let .ready(generation, _) = connectionState else {
            return []
        }
        let nextGeneration = generation + 1
        let projected = project(latestSessions)
        projectedByRemoteID = Dictionary(uniqueKeysWithValues: zip(latestSessions.map(\.remoteSessionID), projected))
        connectionState = .ready(generation: nextGeneration, lastDeltaSequence: 0)
        return [.stateSnapshot(generation: nextGeneration, sessions: projected)]
    }

    public mutating func disconnect() {
        connectionState = .disconnected
        projectedByRemoteID.removeAll(keepingCapacity: true)
    }

    public func remoteSessionID(for sessionKey: UInt16) -> String? {
        sessionKeyByRemoteID.first(where: { $0.value == sessionKey })?.key
    }

    public func sessionKey(for remoteSessionID: String) -> UInt16? {
        sessionKeyByRemoteID[remoteSessionID]
    }

    private mutating func project(_ sessions: [RemoteSession]) -> [DeviceSession] {
        let currentIDs = Set(sessions.map(\.remoteSessionID))
        sessionKeyByRemoteID = sessionKeyByRemoteID.filter { currentIDs.contains($0.key) }

        return sessions.map { session in
            let key: UInt16
            if let existing = sessionKeyByRemoteID[session.remoteSessionID] {
                key = existing
            } else {
                key = nextSessionKey
                nextSessionKey += 1
                sessionKeyByRemoteID[session.remoteSessionID] = key
            }
            return DeviceSession(
                remoteSession: session,
                sessionKey: key,
                capabilities: [.scroll, .terminalKeys, .ptt, .navigationKeys, .terminalShortcuts]
            )
        }
    }
}
