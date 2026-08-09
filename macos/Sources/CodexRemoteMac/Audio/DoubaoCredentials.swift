import Foundation
import Security

public struct DoubaoASRCredentials: Codable, Equatable, Sendable {
    public let cookies: [String: String]
    public let deviceID: String
    public let webID: String

    public init(cookies: [String: String], deviceID: String, webID: String) {
        self.cookies = cookies
        self.deviceID = deviceID
        self.webID = webID
    }

    var cookieHeader: String {
        cookies.keys.sorted().compactMap { key in
            cookies[key].map { "\(key)=\($0)" }
        }.joined(separator: "; ")
    }

    var isValid: Bool {
        !cookies.isEmpty && !deviceID.isEmpty && !webID.isEmpty
    }
}

public enum DoubaoCredentialsStoreError: Error, Equatable, Sendable {
    case encodingFailed
    case keychain(OSStatus)
}

public final class DoubaoCredentialsStore: @unchecked Sendable {
    private let service: String
    private let account: String

    public init(
        service: String = "net.codexremote.mac.doubao-asr",
        account: String = "web-session"
    ) {
        self.service = service
        self.account = account
    }

    public func load() -> DoubaoASRCredentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let credentials = try? JSONDecoder().decode(DoubaoASRCredentials.self, from: data),
              credentials.isValid
        else { return nil }
        return credentials
    }

    public func save(_ credentials: DoubaoASRCredentials) throws {
        guard credentials.isValid,
              let data = try? JSONEncoder().encode(credentials)
        else { throw DoubaoCredentialsStoreError.encodingFailed }

        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                baseQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw DoubaoCredentialsStoreError.keychain(updateStatus)
            }
        } else if status != errSecSuccess {
            throw DoubaoCredentialsStoreError.keychain(status)
        }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DoubaoCredentialsStoreError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
