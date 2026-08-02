import CodexRemoteCore
import Foundation

public enum RawHookPayloadMappingError: Error, Equatable, Sendable {
    case malformedJSON
    case missingField(String)
}

public struct RawHookPayloadMapper: Sendable {
    private let processEnvironment: [String: String]

    public init(processEnvironment: [String: String]) {
        self.processEnvironment = processEnvironment
    }

    public func map(_ rawData: Data) throws -> HookPayload {
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: rawData) as? [String: Any] else {
                throw RawHookPayloadMappingError.malformedJSON
            }
            object = decoded
        } catch let error as RawHookPayloadMappingError {
            throw error
        } catch {
            throw RawHookPayloadMappingError.malformedJSON
        }

        let hookEventName = try requiredString("hook_event_name", in: object)
        let sessionID = try requiredString("session_id", in: object)
        let env = object["env"] as? [String: Any]
        let jsonLauncherID = env?["CODEX_REMOTE_INSTANCE_ID"] as? String

        return HookPayload(
            hookEventName: hookEventName,
            sessionID: sessionID,
            launcherInstanceID: nonEmpty(jsonLauncherID) ?? nonEmpty(processEnvironment["CODEX_REMOTE_INSTANCE_ID"]),
            message: object["message"] as? String,
            lastAssistantMessage: object["last_assistant_message"] as? String
        )
    }

    private func requiredString(_ key: String, in object: [String: Any]) throws -> String {
        guard let value = object[key] as? String, let nonEmptyValue = nonEmpty(value) else {
            throw RawHookPayloadMappingError.missingField(key)
        }
        return nonEmptyValue
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else {
            return nil
        }
        return value
    }
}
