import Foundation

/// File I/O behind a protocol so `VaultStore` never touches security-scoped bookmarks or the
/// filesystem directly (Dependency Inversion — `VaultStore`'s tests and SwiftUI previews get
/// `InMemoryVaultFileAccess` below instead: no sandbox, no temp directories, no real timing).
protocol VaultFileAccess: Sendable {
    func read(from url: URL) throws -> Data

    /// Atomic write. Implementations MUST create a rotated backup of the existing file first —
    /// see `SandboxedVaultFileAccess`'s doc comment for why that ordering matters. Returns the
    /// backup's URL, or `nil` when there was nothing to back up (a brand-new file).
    func write(_ data: Data, to url: URL) throws -> URL?

    /// Mint a security-scoped bookmark for `url`, so a later launch can regain sandboxed access to
    /// a user-picked file without re-prompting via `NSOpenPanel`.
    func bookmark(for url: URL) throws -> Data

    /// Resolve a bookmark minted by `bookmark(for:)`. `isStale` mirrors
    /// `URL(resolvingBookmarkData:bookmarkDataIsStale:)`'s out-parameter: `true` means the URL
    /// still resolved but should be re-bookmarked (the file moved/was renamed but is still
    /// reachable at the resolved location).
    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool)
}

/// Real, sandboxed implementation: security-scoped bookmarks plus atomic, backed-up writes.
final class SandboxedVaultFileAccess: VaultFileAccess {
    /// Where rotated backups are written, how many are kept, and what clock stamps their
    /// filenames. Injectable so tests can point `directory` at a throwaway temp folder and drive
    /// `now` without a real wall-clock sleep between saves (see `VaultStoreTests`).
    struct BackupPolicy: Sendable {
        var directory: @Sendable (URL) -> URL   // given the vault's URL, the directory backups live in
        var maxKept: Int
        var now: @Sendable () -> Date

        /// Backups live alongside the vault file itself, keep the newest 10, stamped with the
        /// real wall clock — the production default per the architecture contract ("default N").
        static let `default` = BackupPolicy(
            directory: { $0.deletingLastPathComponent() },
            maxKept: 10,
            now: Date.init
        )
    }

    private let backupPolicy: BackupPolicy
    // `FileManager` is documented by Apple as safe to share across threads (each call is
    // independently thread-safe), but the SDK's `NSFileManager` header predates `Sendable` and
    // carries no conformance — `nonisolated(unsafe)` records that this is a deliberate, verified
    // exception, not an oversight, rather than wrapping a thread-safe type in a lock it doesn't need.
    nonisolated(unsafe) private let fileManager: FileManager

    init(backupPolicy: BackupPolicy = .default, fileManager: FileManager = .default) {
        self.backupPolicy = backupPolicy
        self.fileManager = fileManager
    }

    func read(from url: URL) throws -> Data {
        // Security-scoped access is a FINITE resource the sandbox hands out per process; a start
        // without a matching stop leaks it until the process exits. `defer` guarantees the release
        // runs even if `Data(contentsOf:)` throws below.
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw VaultError.io("failed to read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    func write(_ data: Data, to url: URL) throws -> URL? {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }

        // Back up BEFORE the write it guards: if this save turns out to write garbage (a bug, a
        // truncated encode), the pre-save backup is still the last known-good copy of the vault.
        let backupURL = try makeBackupIfNeeded(for: url)
        do {
            // `.atomic` writes to a temp file in the same directory and renames it over the
            // destination, so a crash or power loss mid-write leaves either the old file or the
            // fully-written new one — never a half-written vault. This does NOT replace the backup
            // above: `.atomic` only protects against a torn write, not against overwriting a good
            // file with bytes that are wrong for some other reason (e.g. a codec bug that
            // serializes an empty vault) — that's what the backup is for.
            try data.write(to: url, options: [.atomic])
        } catch {
            throw VaultError.io("failed to write \(url.lastPathComponent): \(error.localizedDescription)")
        }
        return backupURL
    }

    func bookmark(for url: URL) throws -> Data {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            return try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw VaultError.io("failed to bookmark \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return (url, isStale)
        } catch {
            throw VaultError.io("failed to resolve bookmark: \(error.localizedDescription)")
        }
    }

    /// Copies the existing file (if any) to `<original filename>.bak-<yyyyMMdd-HHmmss>` next to
    /// it, then deletes all but the newest `maxKept` backups. Returns the new backup's URL, or
    /// `nil` when there was nothing to back up — a brand-new vault whose first save hasn't
    /// happened yet has no prior file to protect.
    ///
    /// This is an explicit v1 requirement (repo CLAUDE.md): a backup MUST always exist before the
    /// FIRST save to a database that already existed on disk, even one this `VaultStore` never
    /// wrote itself (e.g. opened from a file KeePassXC created).
    private func makeBackupIfNeeded(for url: URL) throws -> URL? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        let directory = backupPolicy.directory(url)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: backupPolicy.now())

        let backupURL = directory.appendingPathComponent("\(url.lastPathComponent).bak-\(stamp)")
        do {
            // Same-second collision (two saves within one clock second): overwrite that rotation
            // slot rather than fail the save outright — losing a few seconds of backup
            // granularity is far better than blocking the user's save entirely.
            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.removeItem(at: backupURL)
            }
            try fileManager.copyItem(at: url, to: backupURL)
        } catch {
            throw VaultError.io("failed to back up \(url.lastPathComponent): \(error.localizedDescription)")
        }

        try rotateBackups(in: directory, matching: url.lastPathComponent)
        return backupURL
    }

    /// Deletes all but the newest `maxKept` backups for `originalFilename` in `directory`.
    /// "Newest" is decided by filename sort — the `yyyyMMdd-HHmmss` stamp sorts lexicographically
    /// exactly as it sorts chronologically — rather than filesystem mtime, so rotation stays
    /// correct even if something else touches a backup file's modification date.
    private func rotateBackups(in directory: URL, matching originalFilename: String) throws {
        let prefix = "\(originalFilename).bak-"
        let contents = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let backups = contents
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard backups.count > backupPolicy.maxKept else { return }
        for stale in backups.dropLast(backupPolicy.maxKept) {
            // Best-effort: a leftover stale backup file is a nuisance, not a reason to fail a save
            // that has already succeeded by this point.
            try? fileManager.removeItem(at: stale)
        }
    }
}

/// No-filesystem fake for previews and tests that don't need to exercise sandboxing or backups —
/// see `VaultStoreTests`, which uses a real `SandboxedVaultFileAccess` against a temp directory
/// specifically for the tests that DO need that behavior (backup rotation, wrong-password
/// round-trip through actual bytes on disk).
final class InMemoryVaultFileAccess: VaultFileAccess, @unchecked Sendable {
    // `@unchecked`: every stored property below is only ever touched while holding `lock`, so
    // access is serialized regardless of which thread/actor calls in — the compiler can't see
    // that invariant through a plain `NSLock`, hence the manual opt-out.
    private let lock = NSLock()
    private var files: [URL: Data] = [:]
    private var bookmarks: [Data: URL] = [:]

    init() {}

    func read(from url: URL) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let data = files[url] else {
            throw VaultError.io("no in-memory file at \(url.path)")
        }
        return data
    }

    func write(_ data: Data, to url: URL) throws -> URL? {
        lock.lock(); defer { lock.unlock() }
        files[url] = data
        // The fake never rotates backups — nothing in `Sources/UI`/previews depends on that, and
        // the real rotation behavior is tested against `SandboxedVaultFileAccess` instead.
        return nil
    }

    func bookmark(for url: URL) throws -> Data {
        // There's no real filesystem to ask macOS to bookmark; a bookmark here is just an opaque
        // token round-tripped through a dictionary keyed by that token's own bytes.
        guard let token = url.absoluteString.data(using: .utf8) else {
            throw VaultError.io("URL is not representable as UTF-8: \(url)")
        }
        lock.lock(); defer { lock.unlock() }
        bookmarks[token] = url
        return token
    }

    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard let url = bookmarks[data] else {
            throw VaultError.io("unknown in-memory bookmark")
        }
        return (url, false)
    }
}
