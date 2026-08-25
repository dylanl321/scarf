#if canImport(Security)
import Foundation
import Security

/// Keychain-backed password / session-token store for Hermes URL connections.
/// Never stores the secret in UserDefaults or the server config JSON.
///
/// New writes follow `ScarfGoICloudSyncPreference` (default on) so a
/// reinstall on the same Apple ID can restore login. Reads use
/// `kSecAttrSynchronizableAny` so device-only and synced copies both match.
public struct KeychainHermesServeCredentialStore: HermesServeCredentialStore {
    public static let defaultService = "com.scarf.serve-auth"
    private let service: String

    public init(service: String = defaultService) {
        self.service = service
    }

    public func load(for serverID: ServerID) async throws -> String? {
        try readAccount(account(for: serverID))
    }

    public func save(_ secret: String, for serverID: ServerID) async throws {
        try writeAccount(account(for: serverID), secret: secret)
    }

    public func delete(for serverID: ServerID) async throws {
        try deleteAccount(account(for: serverID))
    }

    public func load(fingerprint: String) async throws -> String? {
        try readAccount(fingerprintAccount(fingerprint))
    }

    public func save(_ secret: String, fingerprint: String) async throws {
        try writeAccount(fingerprintAccount(fingerprint), secret: secret)
    }

    public func delete(fingerprint: String) async throws {
        try deleteAccount(fingerprintAccount(fingerprint))
    }

    /// Rewrite every item under this service to the requested sync state.
    public func migrateAllItems(toICloudSync enabled: Bool) async throws {
        ScarfGoICloudSyncPreference.isEnabled = enabled
        let accounts = try listAccounts()
        var pairs: [(String, String)] = []
        for account in accounts {
            if let secret = try readAccount(account) {
                pairs.append((account, secret))
            }
        }
        for (account, secret) in pairs {
            try writeAccount(account, secret: secret, syncToICloud: enabled)
        }
    }

    private func account(for serverID: ServerID) -> String {
        "serve-auth:\(serverID.uuidString)"
    }

    private func fingerprintAccount(_ fingerprint: String) -> String {
        "serve-auth-fp:\(fingerprint)"
    }

    private func listAccounts() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        switch status {
        case errSecSuccess:
            guard let array = items as? [[String: Any]] else { return [] }
            return array.compactMap { $0[kSecAttrAccount as String] as? String }
        case errSecItemNotFound:
            return []
        default:
            throw HermesServeError.decoding("Keychain list failed (\(status))")
        }
    }

    private func readAccount(_ account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else {
            throw HermesServeError.decoding("Keychain read failed (\(status))")
        }
        return String(data: data, encoding: .utf8)
    }

    private func writeAccount(_ account: String, secret: String) throws {
        try writeAccount(account, secret: secret, syncToICloud: ScarfGoICloudSyncPreference.isEnabled)
    }

    private func writeAccount(_ account: String, secret: String, syncToICloud: Bool) throws {
        let data = Data(secret.utf8)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        var add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        if syncToICloud {
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            add[kSecAttrSynchronizable as String] = kCFBooleanTrue as Any
        } else {
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrSynchronizable as String] = kCFBooleanFalse as Any
        }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw HermesServeError.decoding("Keychain write failed (\(status))")
        }
    }

    private func deleteAccount(_ account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw HermesServeError.decoding("Keychain delete failed (\(status))")
        }
    }
}
#endif
