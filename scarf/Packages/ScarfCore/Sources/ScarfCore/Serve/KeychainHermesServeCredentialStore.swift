#if canImport(Security)
import Foundation
import Security

/// Keychain-backed password / session-token store for Hermes URL connections.
/// Never stores the secret in UserDefaults or the server config JSON.
public struct KeychainHermesServeCredentialStore: HermesServeCredentialStore {
    public static let defaultService = "com.scarf.serve-auth"
    private let service: String

    public init(service: String = defaultService) {
        self.service = service
    }

    public func load(for serverID: ServerID) async throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: serverID),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else {
            throw HermesServeError.decoding("Keychain read failed (\(status))")
        }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ secret: String, for serverID: ServerID) async throws {
        let account = account(for: serverID)
        let data = Data(secret.utf8)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw HermesServeError.decoding("Keychain write failed (\(status))")
        }
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

    private func account(for serverID: ServerID) -> String {
        "serve-auth:\(serverID.uuidString)"
    }

    private func fingerprintAccount(_ fingerprint: String) -> String {
        "serve-auth-fp:\(fingerprint)"
    }

    private func readAccount(_ account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
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
        let data = Data(secret.utf8)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
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
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw HermesServeError.decoding("Keychain delete failed (\(status))")
        }
    }
}
#endif
