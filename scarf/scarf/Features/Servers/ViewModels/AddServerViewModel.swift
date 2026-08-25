import Foundation
import ScarfCore
import AppKit

/// Drives the Add Server sheet. Exposed state maps 1:1 to form fields, plus
/// a reachability test that runs `ssh host 'command -v hermes && ls .hermes/state.db'`
/// and surfaces stderr inline on failure.
@Observable
@MainActor
final class AddServerViewModel {
    /// Name shown in the server picker (defaults to host if the user leaves
    /// it blank).
    enum ConnectionMode: String, CaseIterable, Identifiable {
        case ssh = "SSH"
        case serve = "Hermes URL"
        var id: String { rawValue }
    }

    var mode: ConnectionMode = .ssh
    var serveURL: String = ""
    var serveUsername: String = ""
    var servePassword: String = ""
    private var lastServeAuthMode: HermesServeAuthMode = .basic

    var displayName: String = ""
    var host: String = ""
    var user: String = ""
    var port: String = ""
    var identityFile: String = ""
    /// Override for `~/.hermes` on the remote. Empty = default.
    var remoteHome: String = ""
    /// Override for the parent dir under which template installs land on
    /// this host. Empty = default (`~/projects`). Created on first install
    /// if missing.
    var projectsRoot: String = ""

    /// Manual override for the remote command/path used to invoke
    /// Hermes. Filled in when the auto-probe can't find `hermes` on
    /// the remote `$PATH` — e.g., it's exposed as a zsh shell function
    /// wrapping `docker compose exec`, an alias, or lives in an
    /// unusual location. Empty = let the probe decide (the previous
    /// behavior, still the default). When set, persisted to
    /// `SSHConfig.hermesBinaryHint`; downstream ACP/CLI calls invoke
    /// this verbatim via `/bin/sh -c "<hint> …"`, so any string a
    /// non-interactive shell can resolve works (absolute path, bare
    /// command name, function loaded via a sourced rc, etc.).
    /// gh#105.
    var hermesBinary: String = ""

    var isTesting: Bool = false
    /// Outcome of the most recent Test Connection run. `nil` = not yet run.
    var testResult: TestResult?

    enum TestResult: Equatable {
        /// `suggestedRemoteHome` is non-nil when the probe didn't find
        /// state.db at the configured (or default) path but did find a
        /// `state.db` at one of the well-known alternates (e.g. a systemd
        /// install in `/var/lib/hermes/.hermes`). UI offers a one-click
        /// fill so the user doesn't have to know the convention.
        case success(hermesPath: String, dbFound: Bool, suggestedRemoteHome: String?)
        /// `command` is the full ssh invocation we attempted (so the user can
        /// paste it into Terminal to see what their shell does with it).
        /// `stderr` is whatever ssh / the remote shell wrote to stderr.
        case failure(message: String, stderr: String, command: String)
    }

    /// The config the form currently represents — built on demand, not
    /// persisted until the user clicks Save.
    var draftConfig: SSHConfig {
        SSHConfig(
            host: host.trimmingCharacters(in: .whitespaces),
            user: nonEmpty(user),
            port: Int(port),
            identityFile: nonEmpty(identityFile),
            remoteHome: nonEmpty(remoteHome),
            projectsRoot: nonEmpty(projectsRoot),
            hermesBinaryHint: nonEmpty(hermesBinary)
        )
    }

    /// Hostname or alias is the only required field; everything else
    /// defaults to `~/.ssh/config` / ssh-agent.
    var canSave: Bool {
        switch mode {
        case .ssh:
            return !host.trimmingCharacters(in: .whitespaces).isEmpty
        case .serve:
            return OnboardingLogic.validateServeURL(serveURL).canAdvance
        }
    }

    var resolvedDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        if mode == .serve {
            return URL(string: serveURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host
                ?? serveURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return host.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Identity file picker

    func pickIdentityFile() {
        let panel = NSOpenPanel()
        panel.message = "Choose an SSH private key"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // Default to ~/.ssh so users land in the right place.
        if let sshDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .deletingLastPathComponent().appendingPathComponent(".ssh", isDirectory: true) {
            panel.directoryURL = sshDir
        }
        if panel.runModal() == .OK, let url = panel.url {
            identityFile = url.path
        }
    }

    // MARK: - Test Connection

    /// Run a single ssh round-trip to verify auth + discover the remote
    /// hermes binary. Populates `testResult` with either a success (so the
    /// user knows the binary was found and the DB is readable) or a
    /// failure with stderr for debugging.
    ///
    /// Uses `ssh -v` for the test probe so we capture the full handshake
    /// trace — even if auth fails before the remote shell starts, ssh's
    /// own diagnostic output gives the user (and us) something to act on.
    func testConnection() async {
        isTesting = true
        defer { isTesting = false }

        if mode == .serve {
            await testServe()
            return
        }
        let config = draftConfig
        let probe = TestConnectionProbe(config: config)
        testResult = await probe.run()
    }

    private func testServe() async {
        let trimmed = serveURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var config = HermesServeConfig(
            baseURL: trimmed,
            authMode: .basic,
            username: nonEmpty(serveUsername)
        )
        let client = HermesServeClient(config: config)
        do {
            let status = try await client.probe()
            lastServeAuthMode = status.advertisedAuthMode
            config.authMode = status.advertisedAuthMode
            if status.advertisedAuthMode == .basic {
                try await client.loginBasic(
                    username: serveUsername.trimmingCharacters(in: .whitespaces),
                    password: servePassword,
                    provider: status.passwordLoginProvider
                )
            }
            testResult = .success(
                hermesPath: status.versionLineForCapabilities.isEmpty
                    ? "hermes serve"
                    : status.versionLineForCapabilities,
                dbFound: true,
                suggestedRemoteHome: nil
            )
        } catch {
            testResult = .failure(
                message: error.localizedDescription,
                stderr: "",
                command: "GET \(trimmed)/api/status"
            )
        }
    }

    func kindForSave() -> ServerKind {
        switch mode {
        case .ssh:
            return .ssh(configForSave())
        case .serve:
            return .serve(HermesServeConfig(
                baseURL: serveURL.trimmingCharacters(in: .whitespacesAndNewlines),
                authMode: lastServeAuthMode,
                username: nonEmpty(serveUsername)
            ))
        }
    }

    var serveSecretForSave: String? {
        guard mode == .serve else { return nil }
        let trimmed = servePassword.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// If the test succeeded, we prefer to save the probed binary path into
    /// `hermesBinaryHint` so subsequent calls don't need to re-resolve it.
    /// A user-supplied `hermesBinary` override (gh#105) always wins — that's
    /// the point of the field — so we only fall back to the probe value when
    /// the user left it blank.
    func configForSave() -> SSHConfig {
        var cfg = draftConfig
        if cfg.hermesBinaryHint == nil, case .success(let path, _, _) = testResult {
            cfg.hermesBinaryHint = path
        }
        return cfg
    }

    // MARK: - Helpers

    private func nonEmpty(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
