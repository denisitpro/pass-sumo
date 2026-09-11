import CryptoKit
import Foundation

// MARK: - Outcome

/// What the pre-save backup did. Deliberately a returned value, never a thrown error.
///
/// The policy this type exists to encode (issue #26): **a backup that cannot be made must not
/// block the save, and must not be swallowed either.** Those are two separate requirements and
/// both have a failure mode of their own.
///
/// - Throwing would block the save. The backup runs *before* the write it protects, so a thrown
///   error propagates out of `VaultFileAccess.write` and the user's edits never reach disk. That is
///   how the sibling-file backup turned "this directory is not writable" into "this password
///   manager cannot save at all" — the defect issue #26 is about.
/// - Ignoring it would swallow the failure. Saving without a backup is a real reduction in safety
///   (the pre-save copy is the only protection against our own codec writing a semantically wrong
///   file), and the remaining causes now that backups live in the app's own container — no disk
///   space, a damaged container — are problems the user needs to hear about, not conditions to
///   paper over.
///
/// So the save proceeds and the failure is reported: `VaultStore` keeps it in `lastBackupError`,
/// and the UI shows it (`StatusBar`'s backup warning). The user is told that their data is on disk
/// AND that it went there without a safety net, and can decide what to do about it.
enum VaultBackupOutcome: Equatable, Sendable {
    /// A complete backup exists at this URL.
    case made(URL)
    /// There was nothing to back up: a brand-new database whose first save is what creates the
    /// file. Not a failure — there is no previous version to protect.
    case notNeeded
    /// The backup could not be made. The save went ahead regardless; this must be surfaced.
    case failed(VaultError)

    var url: URL? {
        if case .made(let url) = self { return url }
        return nil
    }

    var error: VaultError? {
        if case .failed(let error) = self { return error }
        return nil
    }
}

// MARK: - Policy

/// Where backups live and how much of them survives.
///
/// Injectable in full so tests (and the durability helper, which runs unsandboxed and must not
/// scatter files through the developer's real Application Support) can point `root` at a throwaway
/// directory and drive `now` without sleeping a real second between saves.
struct VaultBackupPolicy: Sendable {
    /// The directory every database's own backup subdirectory is created under.
    var root: @Sendable () throws -> URL
    /// Most backups kept for one database.
    var maxCount: Int
    /// Age past which a backup is pruned.
    var maxAge: TimeInterval
    /// Ceiling on the total logical size of one database's backups.
    var maxTotalBytes: Int
    /// Clock that stamps backup filenames and decides what counts as old.
    var now: @Sendable () -> Date

    /// The production defaults.
    ///
    /// Every number here is chosen against the fact that a real vault is multi-megabyte: the
    /// owner's own test database is 5.7 MB, and a single attachment may be up to 25 MB, so an
    /// unbounded backup directory would quietly grow into gigabytes inside the app's container
    /// where the user would never think to look.
    ///
    /// - `maxCount: 10` — ten pre-save snapshots is the same depth the previous sibling-file
    ///   rotation kept, and it covers the case the backup exists for: "a save a few edits ago
    ///   wrote something wrong, give me the version before it". At 5.7 MB that is ~57 MB.
    /// - `maxTotalBytes: 200 MB` — a ceiling that binds regardless of count, for the vault that is
    ///   much larger than the typical one. 10 × 5.7 MB = 57 MB, so at the expected size the count
    ///   cap is what bites and this is only headroom; a vault around 20 MB is where bytes start
    ///   winning and the depth silently drops to nine, eight, … Two hundred megabytes is also small
    ///   enough to be unremarkable in `Library/Application Support` on any Mac that can run this
    ///   app.
    /// - `maxAge: 90 days` — a pre-save backup from last quarter is not what anyone reaches for,
    ///   and without an age cap a vault saved twice a year would keep its ten backups forever.
    ///   Generous on purpose, and safe to be: pruning never removes the newest backup (see
    ///   `VaultBackupStore.prune`), so a database untouched for a year still has the last copy of
    ///   itself.
    ///
    /// One caveat on the byte cap, recorded so nobody mistakes it for a disk-usage measurement:
    /// `FileManager.copyItem` on APFS issues `clonefile(2)`, so a fresh backup initially costs
    /// almost no *physical* space and diverges only as the original is rewritten. The cap counts
    /// logical sizes, which is the conservative direction (it prunes sooner than physically
    /// necessary) and the only one that stays correct on a volume where the copy is a real copy.
    static let `default` = VaultBackupPolicy(
        root: { try VaultBackupStore.defaultRoot(fileManager: .default) },
        maxCount: 10,
        maxAge: 90 * 24 * 60 * 60,
        maxTotalBytes: 200 * 1024 * 1024,
        now: Date.init
    )
}

// MARK: - Store

/// Makes and prunes the pre-save backups of a `.kdbx` file, inside the app's own container.
///
/// ## Why the container, and why no entitlement
///
/// A database the user picked through `NSOpenPanel` is granted to the app as a **single file**, not
/// as its directory. Writing `<name>.kdbx.bak-<stamp>` next to it — what this code used to do — is
/// creating a new file in a directory nobody granted, so it fails, and because the backup runs
/// before the write it protects, the save failed with it (issue #26).
///
/// The destination is therefore the app's own Application Support directory, obtained from
/// `FileManager` rather than by expanding `~` or hardcoding a container path. Inside the App
/// Sandbox that resolves to the app's container, which the app owns outright: no entitlement is
/// needed, and none is to be added. That last part is not a preference. A sibling app by the same
/// developer was rejected under App Review Guideline 2.4.5(i) for shipping
/// `com.apple.security.files.downloads.read-write` purely to back a write the user had never
/// chosen; "just add a file-access entitlement so the backup works" is precisely that mistake
/// again. A user-choosable backup folder, with its own `NSOpenPanel` grant and persisted
/// security-scoped bookmark, is the sanctioned way to write anywhere else — and is deliberately a
/// follow-up, not part of this change.
///
/// The cost of the container, stated plainly: the user cannot see or sync these backups unless they
/// go looking, which is why the app has a "Show Backups in Finder" menu item, and `make remove`
/// wipes them along with the rest of the container.
///
/// `final class` + `Sendable` mirrors `SandboxedVaultFileAccess`, for the same reason: the one
/// stored dependency is a `FileManager`, which Apple documents as thread-safe per call but whose
/// header carries no `Sendable` conformance.
final class VaultBackupStore: Sendable {
    private let policy: VaultBackupPolicy
    // Same deliberate exception as `SandboxedVaultFileAccess.fileManager` — see its comment.
    nonisolated(unsafe) private let fileManager: FileManager

    init(policy: VaultBackupPolicy = .default, fileManager: FileManager = .default) {
        self.policy = policy
        self.fileManager = fileManager
    }

    // MARK: Locations

    /// `<Application Support>/PassSumo/Backups`.
    ///
    /// `FileManager` is asked for the directory (`create: false` — the backup path is created on
    /// demand by `backUp`, with intermediate directories), never `~`-expansion and never a literal
    /// `~/Library/Containers/...`: inside the App Sandbox this call already answers with the app's
    /// own container, and a hardcoded path would be both wrong outside it and a hostage to Apple
    /// changing the container layout.
    ///
    /// The `PassSumo/` component is redundant inside the container, which is app-private already.
    /// It is kept because this same code runs unsandboxed in the durability helper, where the
    /// answer is the *shared* `~/Library/Application Support` and a bare `Backups/` at the top of
    /// it would be litter in someone else's namespace.
    static func defaultRoot(fileManager: FileManager) throws -> URL {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return support
            .appendingPathComponent("PassSumo", isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)
    }

    /// The root all per-database subdirectories sit under, or `nil` if `FileManager` cannot name it.
    ///
    /// Non-throwing because its callers are a menu item's enablement and a menu item's action, and
    /// neither has anywhere useful to put an error.
    func rootDirectory() -> URL? {
        try? policy.root()
    }

    /// The subdirectory `url`'s backups live in. Does not create it.
    func directory(for url: URL) throws -> URL {
        try policy.root().appendingPathComponent(Self.directoryName(for: url), isDirectory: true)
    }

    /// `<database name>-<12 hex>` — the per-database subdirectory name.
    ///
    /// ## Why this identity
    ///
    /// The requirement is that a user with several vaults can tell which backups are which, and
    /// that two databases with the same filename in different folders never share a directory.
    /// The only identity available where this code runs is the file's own path: `VaultFileAccess`
    /// is handed bytes and a URL, never a decoded vault. The two tempting alternatives are both
    /// unusable —
    ///
    /// - the KDBX `Meta/CustomData` database UUID (`PassSumo/DatabaseID`) exists only after the
    ///   user enrols Touch ID, because assigning it means writing to their file; it is absent for
    ///   every other database, which is most of them, and
    /// - the KDBX master seed is regenerated on every save by design, so it is not an identity at
    ///   all.
    ///
    /// So: the standardized absolute path, hashed. The hash is what makes it unique; the plain
    /// filename in front of it is what makes it recognisable, so the user opening the backups
    /// folder reads `Personal-3f2a9c1d84b0` and not a bare digest. The path itself is deliberately
    /// **not** in the name — a filesystem path routinely carries the account name, an employer, a
    /// client or a project, none of which belongs in a directory listing that a screenshot or a
    /// support log might carry.
    ///
    /// Twelve hex characters is 48 bits of the SHA-256. For the handful of databases one person
    /// keeps, a collision is not a realistic event, and its consequence would be two backup sets
    /// sharing one directory — untidy, not destructive, because pruning only ever matches names
    /// built from that set's own filename stem.
    ///
    /// **Consequence, by design:** moving or renaming the database changes the path and therefore
    /// starts a fresh backup set; the previous one is left in place rather than adopted or deleted.
    /// That is the deliberate choice. "This path no longer resolves" is indistinguishable from
    /// "that external disk is not plugged in right now", and deleting somebody's backups on that
    /// guess is the one mistake a backup system may never make. The previous directory is not
    /// abandoned outright, though: `pruneAllBackupDirectories` keeps revisiting it under the same
    /// age/count/byte caps as any other, so it converges to its own single newest backup instead of
    /// staying frozen at however many it held at the moment of the move (issue #42) — while still
    /// never losing that last copy.
    static func directoryName(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
        let fingerprint = digest.compactMap { String(format: "%02x", $0) }.joined().prefix(12)
        return "\(sanitized(url.deletingPathExtension().lastPathComponent))-\(fingerprint)"
    }

    /// A filename component reduced to something safe to put in a path.
    ///
    /// Vault filenames come from the user, so they can contain `/` and `:` (which macOS shows as
    /// the other one), leading dots, and — via a pathological name — hundreds of characters. Each
    /// one is a way to make this code create a directory somewhere it did not intend.
    private static func sanitized(_ component: String) -> String {
        let cleaned = String(
            component.map { character -> Character in
                switch character {
                case "/", ":", "\\": return "-"
                default: return character
                }
            }
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .prefix(60)
        // A leading dot would hide the directory in Finder — the opposite of the point of the
        // "Show Backups in Finder" command. "." and ".." would be catastrophic rather than merely
        // hidden, and the trim can also leave nothing at all.
        let trimmed = cleaned.drop { $0 == "." }
        return trimmed.isEmpty ? "database" : String(trimmed)
    }

    /// The inverse of `directoryName(for:)`: recovers the `stem` a directory's backups are named
    /// with, from the directory name alone — no `URL` required.
    ///
    /// Exists for `pruneAllBackupDirectories`, which walks the backup root and finds directories it
    /// did not just create for a live save, so it has no path to hash and compare. `directoryName`
    /// always appends exactly `-<12 lowercase hex>`, so stripping that fixed-width, fixed-alphabet
    /// suffix recovers the same `stem` `listing(in:stem:)` needs — including one that itself
    /// contains hyphens, since only the final 13 characters are inspected. `nil` for anything that
    /// does not have that shape, so a directory this store did not create (or a user's own folder
    /// dropped next to ours under the root) is left alone rather than swept as if it were one of
    /// ours — the same "recognise our own files exactly, touch nothing else" rule `listing(in:stem:)`
    /// already applies within a directory, extended to which directories get walked at all.
    static func stem(fromDirectoryName name: String) -> String? {
        let hexLength = 12
        guard name.count > hexLength + 1 else { return nil }
        let fingerprint = name.suffix(hexLength)
        // `isHexDigit` alone also accepts uppercase A–F; `directoryName` only ever emits lowercase
        // (`String(format: "%02x", ...)`), so a character must additionally be a digit or lowercase
        // to count — digits have no case of their own, hence the `isNumber` half of this check.
        guard fingerprint.allSatisfy({ $0.isHexDigit && ($0.isNumber || $0.isLowercase) }) else {
            return nil
        }
        let withoutFingerprint = name.dropLast(hexLength)
        guard withoutFingerprint.hasSuffix("-") else { return nil }
        let stem = withoutFingerprint.dropLast()
        return stem.isEmpty ? nil : String(stem)
    }

    // MARK: Making a backup

    /// Copies `url`'s current contents into its backup directory, then prunes. **Never throws** —
    /// see `VaultBackupOutcome`'s doc comment for why that is the whole point of this type.
    ///
    /// The caller must already hold security-scoped access to `url`: this reads the user's file.
    /// `SandboxedVaultFileAccess.write` is the only caller and brackets it — see
    /// `withSecurityScope` there.
    func backUp(_ url: URL) -> VaultBackupOutcome {
        guard fileManager.fileExists(atPath: url.path) else { return .notNeeded }

        let directory: URL
        let destination: URL
        do {
            directory = try self.directory(for: url)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            destination = directory.appendingPathComponent(fileName(for: url, at: policy.now()))
            // Same-second collision (two saves inside one clock second): overwrite that slot rather
            // than fail. Losing a second of backup granularity is not worth a warning in the UI.
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: url, to: destination)
        } catch {
            return .failed(.io(
                "couldn't back up \(url.lastPathComponent) before saving: "
                    + error.localizedDescription
            ))
        }

        // Deliberately after the copy and deliberately best-effort: a backup that exists is worth
        // more than a tidy directory, so a prune that cannot delete something must not turn a
        // successful backup into a reported failure.
        //
        // Sweeps every per-database directory under the root, not only this one (issue #42): see
        // `pruneAllBackupDirectories` for why an orphaned directory must be revisited by the same
        // caps, not left frozen at whatever it held when its database was last saved here.
        pruneAllBackupDirectories()
        return .made(destination)
    }

    /// `<name>-<yyyyMMdd-HHmmss>.kdbx`.
    ///
    /// The original extension is kept (rather than the old `.bak-<stamp>` suffix) so a backup is
    /// still a double-clickable `.kdbx` that KeePassXC, Strongbox or this app will open. The stamp
    /// is fixed-width and big-endian, so a lexicographic sort of these names is a chronological
    /// one; `en_US_POSIX` because a `DateFormatter` on the user's locale can produce non-ASCII
    /// digits, which would make the sort meaningless.
    private func fileName(for url: URL, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = Self.stampFormat
        let stem = Self.sanitized(url.deletingPathExtension().lastPathComponent)
        let stamp = formatter.string(from: date)
        let extensionPart = url.pathExtension
        return extensionPart.isEmpty ? "\(stem)-\(stamp)" : "\(stem)-\(stamp).\(extensionPart)"
    }

    private static let stampFormat = "yyyyMMdd-HHmmss"
    /// Length of a `stampFormat` string. Used to reject a file whose name merely starts like ours.
    private static let stampLength = 15

    // MARK: Reading the directory

    /// One backup this store wrote, as identified by its filename.
    struct Backup: Equatable, Sendable {
        let url: URL
        /// Taken from the filename's stamp, not from the filesystem, so the ordering survives
        /// anything that touches modification dates (a restore from Time Machine, an rsync, a
        /// clone) — the same reasoning the previous filename-sorted rotation used.
        let date: Date
        /// Logical size in bytes; `0` when it cannot be read.
        let byteCount: Int
    }

    /// The backups of `url` this store recognises as its own, oldest first.
    func backups(of url: URL) -> [Backup] {
        guard let directory = try? directory(for: url) else { return [] }
        return listing(
            in: directory,
            stem: Self.sanitized(url.deletingPathExtension().lastPathComponent)
        )
    }

    /// Everything in `directory` whose name this store could have produced for `stem`, oldest
    /// first.
    ///
    /// The name has to match exactly — `<stem>-<15-character stamp>` optionally followed by an
    /// extension, with the stamp actually parsing as a date. That strictness is the requirement
    /// that pruning be safe in a directory containing files it did not write: a prefix check alone
    /// would happily delete a `Personal-notes.txt` the user dropped in there, and a directory the
    /// app opens in Finder is a directory people put things in.
    private func listing(in directory: URL, stem: String) -> [Backup] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = Self.stampFormat

        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents.compactMap { candidate -> Backup? in
            let values = try? candidate.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { return nil }

            let name = candidate.deletingPathExtension().lastPathComponent
            let prefix = stem + "-"
            guard name.hasPrefix(prefix) else { return nil }
            let stamp = String(name.dropFirst(prefix.count))
            guard stamp.count == Self.stampLength, let date = formatter.date(from: stamp) else {
                return nil
            }
            return Backup(url: candidate, date: date, byteCount: values?.fileSize ?? 0)
        }
        .sorted { $0.date < $1.date }
    }

    // MARK: Pruning

    /// Deletes oldest-first until all three caps are satisfied, and **never deletes the newest
    /// backup**, whatever the caps say.
    ///
    /// The three caps answer different failure modes and none of them subsumes the others: `count`
    /// bounds the depth for a database saved constantly, `maxTotalBytes` bounds the disk for a
    /// database that is unusually large, and `maxAge` bounds the calendar for one saved so rarely
    /// that neither of the other two would ever bind. See `VaultBackupPolicy.default` for how the
    /// numbers were chosen.
    ///
    /// Keeping the newest unconditionally is the floor: a vault whose last save was two years ago
    /// still has exactly one copy of itself, and a single backup can never be pruned down to none.
    private func prune(in directory: URL, stem: String) {
        var remaining = listing(in: directory, stem: stem)
        var totalBytes = remaining.reduce(0) { $0 + $1.byteCount }
        let now = policy.now()

        while remaining.count > 1 {
            let oldest = remaining[0]
            let tooMany = remaining.count > policy.maxCount
            let tooOld = now.timeIntervalSince(oldest.date) > policy.maxAge
            let tooBig = totalBytes > policy.maxTotalBytes
            guard tooMany || tooOld || tooBig else { break }

            // Best-effort: a backup that refuses to be deleted is a nuisance, not a reason to
            // report the backup that was just taken as a failure.
            try? fileManager.removeItem(at: oldest.url)
            totalBytes -= oldest.byteCount
            remaining.removeFirst()
        }
    }

    // MARK: Orphaned directories (issue #42)

    /// Applies `prune(in:stem:)` to every per-database subdirectory under the backup root, not only
    /// the one the current `backUp` call just wrote to.
    ///
    /// ## The bug this closes
    ///
    /// Before this method existed, `prune` only ever ran for the directory of the database
    /// currently being saved. Renaming or moving a database (`directoryName(for:)` hashes the
    /// standardized path, deliberately) starts a fresh directory, and the old one is never the
    /// target of a `backUp` call again — so it was never pruned again either. It kept whatever it
    /// held at the moment it was abandoned: bounded per directory by the usual caps, but unbounded
    /// in the number of such directories, since nothing ever revisited them. Ten relocations of one
    /// vault could leave up to ten directories each still near its own count/byte ceiling.
    ///
    /// ## Why this is not "delete directories whose database no longer exists at that path"
    ///
    /// That check is exactly the one this deliberately does NOT make. A path that fails to resolve
    /// is indistinguishable from a database on a volume that is simply not mounted right now — an
    /// external drive, a network share, removable media. Treating "the file isn't there" as "the
    /// database is gone" would let a plugged-out drive silently cost someone their only backups of
    /// a database they still have, which is a worse failure than the space leak this method fixes.
    /// So every directory under the root is swept by the SAME caps every directory has always been
    /// subject to, whether or not this call's `url` is the one that put it there, and whether or not
    /// anything currently exists at the path that directory's name was derived from.
    ///
    /// ## Why this still bounds the leak, even without deleting anything based on existence
    ///
    /// `prune` already never deletes a directory's newest backup, and that floor is unconditional
    /// here too — sweeping does not add a way around it, it just makes the AGE cap actually apply to
    /// directories that used to be exempt from ever running it again. A directory that stops being
    /// written to converges, within `maxAge`, to holding exactly its one newest backup — not the up
    /// to `maxCount` / `maxTotalBytes` it could have been frozen at before. That does not bound the
    /// total size of `Backups/` as the number of relocations grows without limit (each surviving
    /// directory still costs at least one backup's worth of bytes forever), but it converts an
    /// unbounded-per-directory leak into a bounded-per-directory one, which is the trade this issue's
    /// "never delete the last copy" requirement forces: a policy that reclaims that last file too
    /// would have to guess "orphaned" from "unmounted", and guessing wrong destroys data a
    /// space leak never does.
    ///
    /// ## Recognising a directory as ours
    ///
    /// A directory only counts if `stem(fromDirectoryName:)` can recover a stem from its name — the
    /// same "match our own naming exactly, touch nothing else" rule `listing(in:stem:)` already
    /// applies to individual files, extended to deciding which directories get walked at all. A
    /// folder a user dropped directly under the (Finder-visible) backup root is left alone.
    ///
    /// Best-effort throughout, like `prune` itself: nothing here can turn the backup that was just
    /// made into a reported failure.
    private func pruneAllBackupDirectories() {
        guard let root = try? policy.root() else { return }
        let entries = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
            guard isDirectory == true else { continue }
            guard let stem = Self.stem(fromDirectoryName: entry.lastPathComponent) else { continue }
            prune(in: entry, stem: stem)
        }
    }
}
