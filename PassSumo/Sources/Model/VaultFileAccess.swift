import Foundation

/// What a vault file looked like at one moment, cheaply enough to re-take on every save (issue
/// #173). Modification date AND size, because either alone is too easy to fool: a sync that
/// rewrites a database of the same length leaves the size identical, and a filesystem or a
/// restore-from-backup can hand back the timestamp it was given.
///
/// Deliberately NOT a content hash. Hashing the file means reading all of it — on the save path,
/// under a security scope, for a file that lives on a network volume or in iCloud — every time,
/// and the question being asked ("is this still the byte-for-byte file I decoded?") does not need
/// certainty in the safe direction. A missed change is the same clobber we had before; a false
/// alarm costs the user one dialog.
struct FileFingerprint: Equatable, Sendable {
    var modificationDate: Date
    var size: Int
}

/// The one rule deciding whether a save is about to overwrite somebody else's work (issue #173).
///
/// A free function rather than an `if` inside `VaultStore.performSave`, because both of its
/// "don't block the save" branches are judgement calls that deserve to be asserted directly
/// rather than inferred from a store's end state:
///
/// - **`expected == nil` — we never knew.** The first save of a database created in this session
///   (nothing was on disk to fingerprint), or a store whose fingerprint could not be taken. There
///   is no baseline to compare against, so there is nothing to claim.
/// - **`current == nil` — the file is gone.** Deleted or moved out from under us. Writing it back
///   destroys nothing: there is no other copy at this path to lose. Refusing here would strand a
///   user whose database was moved to the Trash with the app open, and the write itself is what
///   reports a volume that genuinely went away.
enum ExternalChangeCheck {
    static func isConflict(expected: FileFingerprint?, current: FileFingerprint?) -> Bool {
        guard let expected, let current else { return false }
        return current != expected
    }
}

/// File I/O behind a protocol so `VaultStore` never touches security-scoped bookmarks or the
/// filesystem directly (Dependency Inversion — `VaultStore`'s tests and SwiftUI previews get
/// `InMemoryVaultFileAccess` below instead: no sandbox, no temp directories, no real timing).
protocol VaultFileAccess: Sendable {
    func read(from url: URL) throws -> Data

    /// What the file at `url` looks like right now, or `nil` when there is nothing to describe —
    /// the file does not exist yet, or its metadata could not be read.
    ///
    /// **Non-throwing on purpose.** Both callers (`VaultStore`'s pre-write check and its
    /// post-write refresh) want the same thing from a failure: carry on. A thrown error on the
    /// check would turn "we could not stat the file" into a save that cannot happen, and on the
    /// refresh it would turn a write that DID land into a reported failure. `nil` says "unknown",
    /// and `ExternalChangeCheck` treats unknown as "do not block".
    func fingerprint(of url: URL) -> FileFingerprint?

    /// Atomic write, preceded by an attempt to back the existing file up.
    ///
    /// Two hard requirements, and the second one is the fix for issue #26:
    ///
    /// 1. Implementations MUST attempt a backup of the existing file BEFORE the write — that
    ///    ordering is what makes the backup a copy of the last known-good version rather than of
    ///    the bytes this save is about to produce.
    /// 2. A failed backup MUST NOT abort the write, and MUST NOT be discarded. It is reported in
    ///    the returned `VaultBackupOutcome` so the caller can tell the user their data is saved but
    ///    unprotected. Throwing here would mean a save that cannot happen at all; returning
    ///    `.notNeeded` for a failure would mean the user is never told.
    ///
    /// Throws only when the write itself failed, in which case nothing was written.
    @discardableResult
    func write(_ data: Data, to url: URL) throws -> VaultBackupOutcome

    /// Mint a security-scoped bookmark for `url`, so a later launch can regain sandboxed access to
    /// a user-picked file without re-prompting via `NSOpenPanel`.
    func bookmark(for url: URL) throws -> Data

    /// Resolve a bookmark minted by `bookmark(for:)`. `isStale` mirrors
    /// `URL(resolvingBookmarkData:bookmarkDataIsStale:)`'s out-parameter: `true` means the URL
    /// still resolved but should be re-bookmarked (the file moved/was renamed but is still
    /// reachable at the resolved location).
    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool)

    /// Where this implementation keeps backups of `url` — or of every database, when `url` is
    /// `nil` and nothing is open. `nil` means this implementation keeps no on-disk backups.
    ///
    /// Exists so the app can offer "Show Backups in Finder": the backups now live inside the app's
    /// container, which is somewhere the user would never find on their own, and a backup nobody
    /// can reach is only half a backup. Pure path derivation — it creates nothing, so it is safe to
    /// call from a menu item's enablement on every redraw.
    func backupDirectory(for url: URL?) -> URL?
}

/// Real, sandboxed implementation: security-scoped bookmarks plus atomic writes, with the pre-save
/// backup delegated to `VaultBackupStore`.
///
/// The backup is a separate type on purpose (Single Responsibility): where backups go, how they are
/// named per database, and how many survive is a policy with its own reasoning and its own tests —
/// see `VaultBackupStore` — while this type's job is the sandbox bracket and the atomic write.
final class SandboxedVaultFileAccess: VaultFileAccess {
    private let backups: VaultBackupStore
    // `FileManager` is documented by Apple as safe to share across threads (each call is
    // independently thread-safe), but the SDK's `NSFileManager` header predates `Sendable` and
    // carries no conformance — `nonisolated(unsafe)` records that this is a deliberate, verified
    // exception, not an oversight, rather than wrapping a thread-safe type in a lock it doesn't need.
    nonisolated(unsafe) private let fileManager: FileManager

    init(backupPolicy: VaultBackupPolicy = .default, fileManager: FileManager = .default) {
        self.backups = VaultBackupStore(policy: backupPolicy, fileManager: fileManager)
        self.fileManager = fileManager
    }

    /// The ONE place in this type that opens and closes security-scoped access.
    ///
    /// Scoped access is a finite resource the sandbox hands out per process; a `start` without a
    /// matching `stop` leaks it until the process exits. Every method that touches the user's file
    /// goes through here rather than repeating the pair, so there is exactly one `defer` to get
    /// right instead of one per method. (ShotSumo makes this structural — its scoped-access flag is
    /// `fileprivate`, so no caller outside that file can build a value that skips the bracket. That
    /// shape does not transfer here, because there is no wrapper value type to hide a flag in: the
    /// URLs come straight from `VaultStore`. So this remains a convention, enforced by there being
    /// one obvious helper to call, not by the type system.)
    private func withSecurityScope<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    func read(from url: URL) throws -> Data {
        try withSecurityScope(url) {
            do {
                return try Data(contentsOf: url)
            } catch {
                throw VaultError.io("failed to read \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    /// **`FileManager.attributesOfItem(atPath:)`, deliberately, and NOT `url.resourceValues(…)`**
    /// — which is the idiom the rest of this module uses (`VaultBackupStore`), and which is wrong
    /// here. `NSURL` caches resource values, the Swift `URL` overlay forwards to it, and
    /// `VaultStore` asks the same `URL` value twice per save: once before the write, once after it.
    /// Probed on this machine (Darwin 25.6, APFS): write 100 bytes, read, rewrite 250 bytes, read
    /// again — `resourceValues` reported size 100 BOTH times, `attributesOfItem` reported 100 then
    /// 250. With the cached reading, this whole feature would be inert after the first save, since
    /// every later fingerprint would be the first one and could never differ.
    ///
    /// The second probe answers the other half: three back-to-back atomic writes produced three
    /// distinct modification dates (sub-microsecond apart), so a same-size rewrite by another
    /// client is still caught by the date.
    func fingerprint(of url: URL) -> FileFingerprint? {
        withSecurityScope(url) {
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let date = attributes[.modificationDate] as? Date,
                  let size = (attributes[.size] as? NSNumber)?.intValue
            else { return nil }
            return FileFingerprint(modificationDate: date, size: size)
        }
    }

    @discardableResult
    func write(_ data: Data, to url: URL) throws -> VaultBackupOutcome {
        // The whole call is inside the bracket because BOTH halves touch the user's file: the
        // backup reads it, the atomic write replaces it.
        try withSecurityScope(url) {
            // Back up BEFORE the write it guards: if this save turns out to write garbage (a bug, a
            // truncated encode), the pre-save backup is still the last known-good copy of the vault.
            //
            // `backUp` cannot throw, by design. A backup that fails must leave the user able to
            // save — see `VaultBackupOutcome` — so its failure travels back as a value and is
            // surfaced by `VaultStore.lastBackupError`, not by aborting this method.
            let outcome = backups.backUp(url)
            do {
                // `.atomic` writes to a temp file and renames it over the destination, so a crash
                // or power loss mid-write leaves either the old file or the fully-written new one —
                // never a half-written vault. This does NOT replace the backup above: `.atomic`
                // only protects against a torn write, not against overwriting a good file with
                // bytes that are wrong for some other reason (e.g. a codec bug that serializes an
                // empty vault) — that's what the backup is for.
                //
                // Measured under a Seatbelt profile modelling a file-scoped grant (see
                // `AtomicWriteTests`): Foundation does not blindly create a sibling here. It falls
                // back to a temporary file the sandbox permits and still replaces by rename.
                try data.write(to: url, options: [.atomic])
            } catch {
                throw VaultError.io("failed to write \(url.lastPathComponent): \(error.localizedDescription)")
            }
            return outcome
        }
    }

    func bookmark(for url: URL) throws -> Data {
        try withSecurityScope(url) {
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
    }

    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        // No security-scope bracket: resolving a bookmark does not access the file, it only
        // produces the URL that a later `read`/`write` will bracket.
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

    func backupDirectory(for url: URL?) -> URL? {
        guard let url else { return backups.rootDirectory() }
        return try? backups.directory(for: url)
    }
}

/// No-filesystem fake for previews and tests that don't need to exercise sandboxing or backups —
/// see `VaultStoreTests`, which uses a real `SandboxedVaultFileAccess` against a temp directory
/// specifically for the tests that DO need that behavior (backup retention, wrong-password
/// round-trip through actual bytes on disk).
final class InMemoryVaultFileAccess: VaultFileAccess, @unchecked Sendable {
    // `@unchecked`: every stored property below is only ever touched while holding `lock`, so
    // access is serialized regardless of which thread/actor calls in — the compiler can't see
    // that invariant through a plain `NSLock`, hence the manual opt-out.
    private let lock = NSLock()
    private var files: [URL: Data] = [:]
    private var bookmarks: [Data: URL] = [:]
    private var fingerprints: [URL: FileFingerprint] = [:]

    /// Stands in for the filesystem's clock. A counter and not `Date()`, for the same reason
    /// `VaultStoreTests.TestClock` is one: two writes in a test land microseconds apart, and a
    /// fake that handed out equal timestamps would make `ExternalChangeCheck` lean entirely on
    /// size — so a test rewriting a same-length vault would pass while the real thing regressed.
    private var writeCount: TimeInterval = 0

    init() {}

    func read(from url: URL) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let data = files[url] else {
            throw VaultError.io("no in-memory file at \(url.path)")
        }
        return data
    }

    /// `nil` for a URL never written here, mirroring the real one's "there is no such file".
    func fingerprint(of url: URL) -> FileFingerprint? {
        lock.lock(); defer { lock.unlock() }
        return fingerprints[url]
    }

    @discardableResult
    func write(_ data: Data, to url: URL) throws -> VaultBackupOutcome {
        lock.lock(); defer { lock.unlock() }
        files[url] = data
        writeCount += 1
        fingerprints[url] = FileFingerprint(
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000 + writeCount),
            size: data.count
        )
        // The fake keeps no backups — nothing in `Sources/UI`/previews depends on that, and the
        // real retention behavior is tested against `SandboxedVaultFileAccess` instead.
        // `.notNeeded` rather than `.failed`: this is not a backup that went wrong, it is a
        // filesystem that does not exist, and reporting a failure here would put a warning in the
        // UI of every preview and every `-ui-testing 1` run.
        return .notNeeded
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

    /// `nil`: there is no directory to reveal, which is what disables "Show Backups in Finder"
    /// under `-ui-testing 1` instead of opening Finder on a real path during an e2e run.
    func backupDirectory(for url: URL?) -> URL? { nil }
}
