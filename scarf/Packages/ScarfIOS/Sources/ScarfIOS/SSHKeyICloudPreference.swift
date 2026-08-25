// Apple-only: Security.framework + UserDefaults are iOS/Mac only.
// On Linux this file is skipped; tests don't exercise it.
#if canImport(Security)

import Foundation
import ScarfCore

/// Device-local preference for iCloud Keychain sync of SSH keys, Hermes
/// URL passwords, and the server list. Backed by
/// `ScarfGoICloudSyncPreference` (default on when unset).
public enum SSHKeyICloudPreference {

    public static let key = ScarfGoICloudSyncPreference.key

    public static var isEnabled: Bool {
        get { ScarfGoICloudSyncPreference.isEnabled }
        set { ScarfGoICloudSyncPreference.isEnabled = newValue }
    }
}

#endif // canImport(Security)
