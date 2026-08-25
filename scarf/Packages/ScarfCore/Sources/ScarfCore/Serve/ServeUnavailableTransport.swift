import Foundation

/// `ServerTransport` for `.serve` contexts. Every primitive fails with
/// a clear error so accidental SSH-path calls cannot silently hang or
/// pretend to talk to a filesystem.
public struct ServeUnavailableTransport: ServerTransport {
    public let contextID: ServerID
    public let isRemote: Bool = true

    public init(contextID: ServerID) {
        self.contextID = contextID
    }

    private func fail() -> TransportError {
        .other(message: HermesServeError.transportUnavailable.errorDescription
            ?? "Hermes URL connections do not support SSH I/O")
    }

    public nonisolated func readFile(_ path: String) throws -> Data { throw fail() }
    public nonisolated func writeFile(_ path: String, data: Data) throws { throw fail() }
    public nonisolated func fileExists(_ path: String) -> Bool { false }
    public nonisolated func stat(_ path: String) -> FileStat? { nil }
    public nonisolated func listDirectory(_ path: String) throws -> [String] { throw fail() }
    public nonisolated func createDirectory(_ path: String) throws { throw fail() }
    public nonisolated func removeFile(_ path: String) throws { throw fail() }

    public nonisolated func runProcess(
        executable: String,
        args: [String],
        stdin: Data?,
        timeout: TimeInterval?
    ) throws -> ProcessResult {
        throw fail()
    }

    #if !os(iOS)
    public nonisolated func makeProcess(executable: String, args: [String]) -> Process {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/false")
        proc.arguments = []
        return proc
    }
    #endif

    public nonisolated func streamLines(
        executable: String,
        args: [String]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: fail()) }
    }

    public nonisolated func streamScript(
        _ script: String,
        timeout: TimeInterval
    ) async throws -> ProcessResult {
        throw fail()
    }

    public nonisolated func watchPaths(_ paths: [String]) -> AsyncStream<WatchEvent> {
        AsyncStream { $0.finish() }
    }
}
