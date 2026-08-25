import Foundation

/// Whether ScarfGo should write connection secrets (server list, Hermes
/// URL passwords, SSH keys) to iCloud Keychain.
///
/// Reuses the issue-#52 UserDefaults key so an explicit opt-in or
/// opt-out survives. When the key has never been set, the default is
/// **on** so a reinstall on the same Apple ID can restore hosts and
/// login without finding a hidden toggle first.
public enum ScarfGoICloudSyncPreference: Sendable {
    public static let key = "scarf.icloud.syncSSHKey"

    public static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: key) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: key)
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
