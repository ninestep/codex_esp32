import CodexRemoteCore
import Foundation

public struct SessionIPCDispatcher: Sendable {
    private let service: SessionService

    public init(service: SessionService) {
        self.service = service
    }

    public func handle(_ request: LocalIPCRequest) async -> LocalIPCResponse {
        do {
            switch request {
            case .registerLaunch(let launcherID):
                _ = try await service.registerFocusedLaunch(launcherInstanceID: launcherID)
                return .ok
            case .hook(let payload):
                _ = try await service.receiveHook(payload)
                return .ok
            case .list:
                return .sessions(await service.activeSessions(limit: 8))
            case .focus(let remoteSessionID):
                _ = try await service.selectSession(remoteSessionID: remoteSessionID)
                return .ok
            case .scroll(let remoteSessionID, let deltaY):
                try await service.scroll(deltaY: deltaY, remoteSessionID: remoteSessionID)
                return .ok
            case .key(let remoteSessionID, let key):
                try await service.sendKey(key, remoteSessionID: remoteSessionID)
                return .ok
            }
        } catch {
            return .error(code: .handlerFailed)
        }
    }

    public func handlePending(_ event: PendingLocalEvent) async -> LocalIPCResponse {
        do {
            switch event {
            case .launchSnapshot(let snapshot):
                _ = try await service.registerLaunchSnapshot(snapshot)
                return .ok
            case .hook(let payload):
                _ = try await service.receiveHook(payload)
                return .ok
            }
        } catch {
            return .error(code: .handlerFailed)
        }
    }
}
