#if canImport(Security)

import Foundation
import Security
import ScarfCore

/// iCloud Keychain mirror of the iOS server list (no passwords).
/// UserDefaults remains the fast local cache; this blob survives uninstall
/// when iCloud Keychain sync is on.
public struct KeychainIOSServerConfigMirror: Sendable {
    public static let defaultService = "com.scarf.server-config"
    public static let account = "servers-v2"

    private let service: String

    public init(service: String = defaultService) {
        self.service = service
    }

    public func loadAll() throws -> [ServerID: IOSServerConfig] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return [:] }
        guard status == errSecSuccess, let data = out as? Data else {
            return [:]
        }
        let raw = (try? JSONDecoder().decode([String: IOSServerConfig].self, from: data)) ?? [:]
        var result: [ServerID: IOSServerConfig] = [:]
        for (idString, config) in raw {
            guard let uuid = UUID(uuidString: idString) else { continue }
            result[uuid] = config
        }
        return result
    }

    public func saveAll(_ all: [ServerID: IOSServerConfig]) throws {
        var raw: [String: IOSServerConfig] = [:]
        for (id, config) in all {
            raw[id.uuidString] = config
        }
        let data = try JSONEncoder().encode(raw)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        var add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecValueData as String: data,
        ]
        if ScarfGoICloudSyncPreference.isEnabled {
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            add[kSecAttrSynchronizable as String] = kCFBooleanTrue as Any
        } else {
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrSynchronizable as String] = kCFBooleanFalse as Any
        }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SSHKeyStoreError.backendFailure(
                message: "Server-list Keychain write failed",
                osStatus: status
            )
        }
    }

    public func deleteAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

#endif
