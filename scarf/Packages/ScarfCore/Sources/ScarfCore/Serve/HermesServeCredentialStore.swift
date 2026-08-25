import Foundation

/// Password / session-token storage for a Hermes URL connection.
/// iOS wires Keychain; tests use the in-memory store.
public protocol HermesServeCredentialStore: Sendable {
    func load(for serverID: ServerID) async throws -> String?
    func save(_ secret: String, for serverID: ServerID) async throws
    func delete(for serverID: ServerID) async throws
    /// Fallback key so feature VMs that share a synthetic context id
    /// (the iOS A1 pool id) still find the password.
    func load(fingerprint: String) async throws -> String?
    func save(_ secret: String, fingerprint: String) async throws
    func delete(fingerprint: String) async throws
}

/// Process-wide credential store. iOS/Mac set this to a Keychain
/// implementation at launch; tests replace it with the in-memory store.
public enum HermesServeRuntime {
    nonisolated(unsafe) public static var credentials: any HermesServeCredentialStore =
        InMemoryHermesServeCredentialStore()
}

public actor InMemoryHermesServeCredentialStore: HermesServeCredentialStore {
    private var storage: [ServerID: String] = [:]
    private var fingerprints: [String: String] = [:]

    public init() {}

    public func load(for serverID: ServerID) async throws -> String? {
        storage[serverID]
    }

    public func save(_ secret: String, for serverID: ServerID) async throws {
        storage[serverID] = secret
    }

    public func delete(for serverID: ServerID) async throws {
        storage.removeValue(forKey: serverID)
    }

    public func load(fingerprint: String) async throws -> String? {
        fingerprints[fingerprint]
    }

    public func save(_ secret: String, fingerprint: String) async throws {
        fingerprints[fingerprint] = secret
    }

    public func delete(fingerprint: String) async throws {
        fingerprints.removeValue(forKey: fingerprint)
    }
}
