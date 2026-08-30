import CryptoKit
import Foundation

// MARK: - Domain model
//
// Plain value types describing a fully-decrypted KDBX database. These are the ONLY shapes the
// rest of the app (UI, Store) ever touches — codec-specific concepts (XML nodes, header params,
// KDF salts, …) never leak past `Sources/KDBX`'s `VaultCodec` conformance. See `VaultCodec.swift`
// for how anything a codec reads but `Vault` has no field for still survives a save.

/// One password entry. `password` is plaintext here by design — `Vault` only exists in memory
/// while the database is unlocked; nothing in this file ever writes it to disk or a log.
struct VaultEntry: Identifiable, Sendable, Equatable {
    var id: UUID                       // KDBX entry UUID
    var groupID: UUID?                 // parent group; nil == root
    var title: String
    var username: String
    var password: String               // plaintext while unlocked
    var url: String
    var notes: String
    var otpAuthURL: String?            // raw `otpauth://...` taken from the "otp" string field
    var customFields: [String: String] // all other string fields, minus the 5 standard ones + otp
    /// File attachments on this entry, as METADATA ONLY — the bytes live once in `Vault.blobs`
    /// and are reached through `Vault.bytes(for:)`. See `VaultAttachment` for why.
    var attachments: [VaultAttachment] = []
    var created: Date
    var modified: Date
}

// MARK: - Attachments

/// Content address of one attachment payload: the SHA-256 of its bytes.
///
/// A content hash rather than a synthetic id because it makes two things fall out for free that
/// would otherwise need bookkeeping: de-duplication (attaching the same screenshot to two entries
/// resolves to one blob, which is exactly how KDBX's own binary pool behaves), and a cheap,
/// honest `VaultBlob.==` — see that type.
struct VaultBlobID: Hashable, Sendable {
    /// The raw 32-byte digest. Not a hex string: this is compared and hashed far more often than
    /// it is printed, and a `Data` keeps both operations allocation-free.
    let digest: Data

    init(hashing bytes: Data) {
        digest = Data(SHA256.hash(data: bytes))
    }
}

/// The bytes of one attachment, pooled vault-wide and keyed by their own content hash.
///
/// **`==` compares only `id`, and that is not a shortcut — it is the definition.** `id` is the
/// SHA-256 of `bytes`, so equal ids mean equal bytes (finding a counterexample is finding a
/// SHA-256 collision). The reason it matters: `Vault` is `Equatable`, `VaultStore.State` wraps it,
/// and SwiftUI compares that state on every change — a byte-wise `Data` comparison would run
/// `memcmp` over every screenshot in the vault on each of those, for a value that cannot differ
/// without its id differing first.
struct VaultBlob: Sendable, Equatable, Identifiable {
    let id: VaultBlobID
    let bytes: Data

    init(bytes: Data) {
        self.bytes = bytes
        self.id = VaultBlobID(hashing: bytes)
    }

    static func == (lhs: VaultBlob, rhs: VaultBlob) -> Bool { lhs.id == rhs.id }
}

/// One attachment as an entry sees it: a filename plus a REFERENCE to pooled bytes.
///
/// **Why a reference and not the bytes inline.** KDBX stores attachment payloads once in a
/// database-wide binary pool and gives each entry a `<Binary>` element naming a pool index, so
/// several entries can share one blob. Modelling that as "every entry owns its bytes" would be a
/// lie in two directions at once: it would duplicate a shared blob per referencing entry in
/// memory, and — because `VaultEntry` is `Equatable` and lives inside an `Equatable` `Vault` that
/// SwiftUI diffs on every state change — it would drag multi-megabyte payloads through every one
/// of those comparisons and through every copy of the (value-typed) entry the UI makes. Keeping
/// `VaultEntry` at name + hash + size + flag leaves it the cheap little struct the list, the
/// detail view and the search index all assume it is, and leaves exactly one copy of the bytes,
/// in `Vault.blobs`, mirroring the format's own pool. The cost is one indirection —
/// `Vault.bytes(for:)` — paid only by the two places that genuinely need payload bytes: the
/// preview and "Save As…".
struct VaultAttachment: Sendable, Equatable, Identifiable {
    /// The filename the user sees. KDBX requires these to be unique WITHIN one entry (a duplicate
    /// key is a validation warning in the format), which is what makes it usable as `id` here.
    var name: String
    /// Where the bytes are — resolve with `Vault.bytes(for:)`.
    var blobID: VaultBlobID
    /// Payload size, carried alongside so a list can show "1.2 MB" without touching the payload.
    var byteCount: Int
    /// Whether the payload is inner-stream encrypted on disk (KDBX's per-binary `protected` flag).
    /// Preserved so a round-trip does not silently downgrade another client's protected binary.
    var isProtected: Bool

    var id: String { name }
}

/// Why an attachment could not be taken in. Flat and `Equatable` for the same reason `VaultError`
/// is — it is displayed directly, never unwrapped through a chain of causes.
enum VaultAttachmentError: Error, Equatable {
    case tooLarge(name: String, byteCount: Int, limit: Int)
    case unreadable(name: String)
}

extension VaultAttachment {
    /// Hard per-attachment ceiling: 25 MB.
    ///
    /// KDBX itself imposes no limit, which is precisely the problem — the whole database is
    /// decrypted into memory on unlock and re-encrypted in full on every save, so an attachment's
    /// size is paid again on each of those, not once at import. A 500 MB video attached "because
    /// it fit" turns every subsequent save into a multi-second stall and every unlock into a
    /// half-gigabyte resident footprint, i.e. a denial of service the user commits against
    /// themselves and cannot easily undo from inside a now-unusable app.
    ///
    /// 25 MB is chosen against the actual use case the owner described — screenshots, scans of
    /// documents, recovery-code images — where a generous 4032×3024 photo lands around 5 MB and a
    /// multi-page PDF scan around 10 MB. It leaves several times the headroom those need while
    /// keeping the worst case a user can build one attachment at a time bounded at something a Mac
    /// absorbs without a visible hang. It is deliberately a REFUSAL, not a warning: the failure it
    /// prevents shows up later, in a different screen, where it can no longer be connected to the
    /// file that caused it.
    static let maximumByteCount = 25 * 1024 * 1024

    /// Builds an attachment plus its pooled blob, or throws if the payload is over the limit.
    ///
    /// New attachments default to `isProtected: true` for the same reason new custom fields do
    /// (see `KDBXEntryStrings.apply`): what people put in a password manager's attachments is
    /// recovery-code screenshots and identity documents far more often than it is trivia, every
    /// KDBX client reads a protected binary transparently, so there is no interop cost to erring
    /// this way.
    static func make(
        name: String,
        bytes: Data,
        isProtected: Bool = true
    ) throws -> (attachment: VaultAttachment, blob: VaultBlob) {
        guard bytes.count <= maximumByteCount else {
            throw VaultAttachmentError.tooLarge(
                name: name,
                byteCount: bytes.count,
                limit: maximumByteCount
            )
        }
        let blob = VaultBlob(bytes: bytes)
        let attachment = VaultAttachment(
            name: name,
            blobID: blob.id,
            byteCount: bytes.count,
            isProtected: isProtected
        )
        return (attachment, blob)
    }
}

// MARK: - Recycle bin

/// The database's recycle-bin configuration, mirroring KDBX's own `Meta` fields.
///
/// `isEnabled` folds the format's tri-state (`RecycleBinEnabled` present-true / present-false /
/// absent) into a bool by treating ABSENT as enabled — that is KeePass's own default, and the
/// alternative (absent means off) would silently deny the feature to every database whose writer
/// simply never emitted the element. Present-and-false is honoured exactly: the codec never turns
/// the bin on in a database whose owner turned it off.
struct RecycleBinConfiguration: Sendable, Equatable {
    var isEnabled: Bool = true
    /// The bin group, or `nil` when the database has no bin group yet. `nil` covers both "the
    /// field is absent" and KDBX's all-zeroes `RecycleBinUUID`, which the format defines as
    /// exactly that same "not created yet" sentinel.
    var groupID: UUID?
}

/// A folder in the vault's group tree. Flat storage (`parentID`, not nested arrays) so `Vault`
/// stays a plain `Equatable` value type and the UI can rebuild whatever tree shape it needs
/// (sidebar outline, breadcrumb, …) from `Vault.group(_:)` / `rootGroups` without this type
/// having to anticipate the presentation.
struct VaultGroup: Identifiable, Sendable, Equatable {
    var id: UUID
    var parentID: UUID?
    var name: String
}

/// Fully decrypted database content — everything the app can show or edit. Deliberately does NOT
/// model anything a KDBX file can carry that pass-sumo has no UI for yet (entry history, custom
/// icons, unknown header/XML data); that unmodeled remainder is the codec's job to round-trip via
/// `DecodedVault.opaque`, not this type's job to represent.
struct Vault: Sendable, Equatable {
    var name: String                          // Meta/DatabaseName
    var groups: [VaultGroup]
    var entries: [VaultEntry]

    /// Every attachment payload in the database, once each, keyed by its content hash — the
    /// domain-level mirror of KDBX's database-wide binary pool. Entries point in here via
    /// `VaultAttachment.blobID`; see that type for why the bytes live here and not on the entry.
    ///
    /// Defaulted so the memberwise initializer stays source-compatible with every `Vault(...)`
    /// call site that predates attachments (previews, fakes, tests).
    var blobs: [VaultBlobID: VaultBlob] = [:]

    /// Recycle-bin configuration read from (and written back to) `Meta`. Defaulted for the same
    /// source-compatibility reason as `blobs`; the default is "enabled, no bin group yet", which
    /// is what a database that has never had anything deleted looks like.
    var recycleBin = RecycleBinConfiguration()
}

/// What's needed to decrypt or create a database. `keyFile` is carried end-to-end even though v1
/// alpha never sets it (see repo CLAUDE.md) — adding it later must not change this type's shape or
/// every codec/store call site again.
struct VaultCredentials: Sendable {
    var password: String
    var keyFile: Data?                        // nil for v1 alpha; keep the parameter
}

/// Every way opening, decoding, or saving a database can fail. Deliberately flat (no nested
/// `Error` wrapping) so `VaultStore.lastError` is directly `Equatable`-comparable in tests and
/// directly displayable by the UI without unwrapping a chain of causes.
enum VaultError: Error, Equatable {
    case wrongCredentials
    case notAKDBXFile
    case unsupportedVersion(String)
    case corrupted(String)
    case unsupportedFeature(String)
    case io(String)
}

// MARK: - Vault convenience lookups

extension Vault {
    /// Entries filed directly under `groupID`. `nil` means the entries pass-sumo shows at the
    /// vault's top level, outside any group — mirrors `VaultEntry.groupID`'s own "nil == root"
    /// convention, not a special case bolted on here.
    func entries(inGroup groupID: UUID?) -> [VaultEntry] {
        entries.filter { $0.groupID == groupID }
    }

    /// The group with `id`, or `nil` if it isn't (or is no longer) part of this vault.
    func group(_ id: UUID) -> VaultGroup? {
        groups.first { $0.id == id }
    }

    /// Groups with no parent — what a sidebar's outline starts drawing from.
    var rootGroups: [VaultGroup] {
        groups.filter { $0.parentID == nil }
    }

    /// The payload behind `attachment`, or `nil` if the blob is missing from the pool.
    ///
    /// `nil` is not an expected outcome — every projected attachment's blob is pooled by the same
    /// pass that projected it — but it is returned rather than force-unwrapped because the one way
    /// to reach it is a `Vault` assembled by hand (a test, a future importer) with a dangling
    /// reference, and that deserves an empty row, not a crash in the middle of the detail view.
    func bytes(for attachment: VaultAttachment) -> Data? {
        blobs[attachment.blobID]?.bytes
    }
}

// MARK: - Recycle bin

extension Vault {
    /// Every group id inside the recycle bin, the bin group itself included. Empty when the
    /// database has no bin group. Used to keep deleted entries out of search and to decide whether
    /// a second delete means "permanently".
    var recycleBinGroupIDs: Set<UUID> {
        guard let binID = recycleBin.groupID, groups.contains(where: { $0.id == binID }) else {
            return []
        }
        var result: Set<UUID> = [binID]
        // Fixed-point expansion rather than recursion: `groups` is a flat parent-linked list that
        // another client can leave a cycle in (see `GroupTreeBuilder`'s own handling), and a walk
        // that follows parents naively would not terminate on one. Each pass can only add ids, and
        // there are finitely many, so this always halts.
        var didGrow = true
        while didGrow {
            didGrow = false
            for group in groups
                where !result.contains(group.id)
                && group.parentID.map(result.contains) == true
            {
                result.insert(group.id)
                didGrow = true
            }
        }
        return result
    }

    /// Whether the entry currently sits inside the recycle bin.
    func isInRecycleBin(_ entry: VaultEntry) -> Bool {
        guard let groupID = entry.groupID else { return false }
        return recycleBinGroupIDs.contains(groupID)
    }

    /// Moves `entryID` into the recycle bin, creating the bin group on first use, and returns
    /// `true` when it did.
    ///
    /// Returns `false` — meaning "the caller must delete permanently instead" — when the database
    /// has the bin switched off, or when the entry is already in the bin (KDBX has no second bin
    /// to move it to, and every other client treats that case as a permanent delete).
    mutating func moveToRecycleBin(entryID: UUID) -> Bool {
        guard recycleBin.isEnabled,
              let index = entries.firstIndex(where: { $0.id == entryID }),
              !isInRecycleBin(entries[index])
        else { return false }

        let binID = ensureRecycleBinGroup()
        entries[index].groupID = binID
        return true
    }

    /// The bin group's id, creating the group if the database does not have one yet.
    ///
    /// Lazy creation is the cross-client convention, not an optimisation: a database that has
    /// never had anything deleted carries an all-zeroes `RecycleBinUUID` and no bin folder, and
    /// materialising one on open would add a visible folder to someone else's vault for nothing.
    private mutating func ensureRecycleBinGroup() -> UUID {
        if let existing = recycleBin.groupID, groups.contains(where: { $0.id == existing }) {
            return existing
        }
        let bin = VaultGroup(id: UUID(), parentID: nil, name: Self.recycleBinGroupName)
        groups.append(bin)
        recycleBin.groupID = bin.id
        recycleBin.isEnabled = true
        return bin.id
    }

    /// The name every KeePass-family client gives the bin folder. Matching it exactly is what
    /// makes a bin we create show up as THE recycle bin in KeePassXC/Strongbox rather than as an
    /// ordinary folder that happens to be pointed at by `Meta`.
    static let recycleBinGroupName = "Recycle Bin"

    /// Removes the entry outright, with no bin involved. The caller is responsible for having
    /// confirmed with the user first — nothing below this line asks.
    mutating func removePermanently(entryID: UUID) {
        entries.removeAll { $0.id == entryID }
    }

    /// Empties the bin: every entry inside it and every folder nested under it are removed. The
    /// bin group itself stays, because `Meta/RecycleBinUUID` still points at it and other clients
    /// expect that pointer to resolve.
    ///
    /// Orphaned attachment blobs are deliberately NOT collected here — see
    /// `KDBXBinaryPool`'s doc comment for why pruning the pool is unsafe.
    mutating func emptyRecycleBin() {
        let binIDs = recycleBinGroupIDs
        guard let binID = recycleBin.groupID, !binIDs.isEmpty else { return }
        entries.removeAll { $0.groupID.map(binIDs.contains) == true }
        groups.removeAll { binIDs.contains($0.id) && $0.id != binID }
    }
}

// MARK: - Search

private extension String {
    /// Case- and diacritic-insensitive comparison key ("Café" and "cafe" fold to the same string).
    /// `.folding` is Foundation's Unicode-aware normalization — cheaper and more correct than a
    /// hand-rolled `lowercased()` + character-by-character strip, and it's what `NSString`'s own
    /// diacritic-insensitive search uses under the hood.
    var searchNormalized: String {
        folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }
}

extension Vault {
    /// Full-text search across every entry, matching `query` case- and diacritic-insensitively
    /// against title, username, URL, notes, every custom field's name AND value, **and the
    /// password itself**.
    ///
    /// Searching the password is a DELIBERATE product differentiator, not an oversight: KeePassium
    /// (a direct competitor for this exact user — see repo CLAUDE.md's positioning notes)
    /// explicitly does not search the password field. A user who half-remembers a password (or is
    /// hunting down every entry that reuses one they now know is compromised) can find it here;
    /// that use case is worth more than the theoretical risk of a password briefly existing as a
    /// search-index comparison string in memory it already lived in anyway.
    ///
    /// An empty query returns every entry — the natural "no filter applied" behavior a search
    /// field should have when the user hasn't typed anything.
    ///
    /// **Entries in the recycle bin are excluded unless `includingRecycleBin` is set.** Finding a
    /// password the user deliberately threw away, mixed in among the live ones and visually
    /// identical to them, is the exact confusion a recycle bin exists to prevent — the user would
    /// copy it, paste it, and discover it is stale somewhere else entirely. The opt-in exists for
    /// the one context where showing them is right: the user has explicitly selected the bin in
    /// the sidebar and is searching *within* it (see `EntryListFilter`).
    func search(_ query: String, includingRecycleBin: Bool = false) -> [VaultEntry] {
        let excluded = includingRecycleBin ? [] : recycleBinGroupIDs
        let candidates = excluded.isEmpty
            ? entries
            : entries.filter { $0.groupID.map(excluded.contains) != true }

        let needle = query.searchNormalized
        guard !needle.isEmpty else { return candidates }

        return candidates.filter { entry in
            if entry.title.searchNormalized.contains(needle) { return true }
            if entry.username.searchNormalized.contains(needle) { return true }
            if entry.url.searchNormalized.contains(needle) { return true }
            if entry.notes.searchNormalized.contains(needle) { return true }
            // See the doc comment above: this line is the differentiator, keep it.
            if entry.password.searchNormalized.contains(needle) { return true }
            for (name, value) in entry.customFields {
                if name.searchNormalized.contains(needle) { return true }
                if value.searchNormalized.contains(needle) { return true }
            }
            return false
        }
    }
}

// MARK: - Sample data

/// Force-unwraps a UUID string literal. Safe ONLY here: every call site below is a hardcoded,
/// visually-inspected-valid literal used for fixture data — never a value that came from a data
/// path (file, network, user input), which is where a force-unwrap would be a real crash risk.
private func fixedUUID(_ string: String) -> UUID {
    UUID(uuidString: string)!
}

/// Parses a fixed ISO-8601 instant for fixture data. Never `Date()`: `Vault.sample` backs both
/// SwiftUI previews and the `-ui-testing` XCUITest fixture (see architecture contract), and both
/// need byte-identical data across runs — a wall-clock timestamp would make any date-based
/// snapshot or accessibility assertion flaky by construction.
private func fixedDate(_ isoString: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    // Every literal below is a valid, inspected ISO-8601 string; `?? .distantPast` only exists to
    // give the function a total (non-optional, non-crashing) signature.
    return formatter.date(from: isoString) ?? .distantPast
}

extension Vault {
    /// Deterministic demo database: 3 groups, 20 entries, fixed UUIDs and dates throughout.
    /// Backs SwiftUI previews (`#Preview`) and the `-ui-testing` launch fixture used by
    /// `PassSumoUITests` — see the architecture contract's Testing section. A couple of entries
    /// carry `otpAuthURL` (valid-looking base32 TOTP secrets) and a couple carry `customFields`,
    /// so previews/UI tests exercise those code paths without needing a real KDBX file.
    static let sample: Vault = {
        let groupEmail = VaultGroup(
            id: fixedUUID("10000000-0000-0000-0000-000000000001"),
            parentID: nil,
            name: "Email"
        )
        let groupWork = VaultGroup(
            id: fixedUUID("10000000-0000-0000-0000-000000000002"),
            parentID: nil,
            name: "Work"
        )
        let groupFinance = VaultGroup(
            id: fixedUUID("10000000-0000-0000-0000-000000000003"),
            parentID: nil,
            name: "Finance"
        )

        // `created`/`modified` are close together for almost every entry (a database that was
        // populated once and rarely edited, which is the common case) — realistic without needing
        // per-entry hand-tuned history.
        func stamped(_ isoString: String) -> (created: Date, modified: Date) {
            let date = fixedDate(isoString)
            return (date, date)
        }

        var entries: [VaultEntry] = []

        // MARK: Email (7)

        let emailDates1 = stamped("2025-11-02T09:14:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("20000000-0000-0000-0000-000000000001"),
            groupID: groupEmail.id,
            title: "Gmail Personal",
            username: "den.larkin@gmail.com",
            password: "Tr0ub4dor&3-gmail",
            url: "https://accounts.google.com",
            notes: "Recovery phone on file. 2FA via authenticator app.",
            // Classic RFC-style demo secret (base32(\"Hello!\\xDE\\xAD\\xBE\\xEF\")), reused across
            // OTP libraries' own docs — deliberately recognizable as a placeholder, not a real seed.
            otpAuthURL: "otpauth://totp/Google:den.larkin@gmail.com?secret=JBSWY3DPEHPK3PXP&issuer=Google&algorithm=SHA1&digits=6&period=30",
            customFields: [:],
            created: emailDates1.created,
            modified: emailDates1.modified
        ))

        let emailDates2 = stamped("2025-11-02T09:20:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("20000000-0000-0000-0000-000000000002"),
            groupID: groupEmail.id,
            title: "iCloud",
            username: "den.larkin@icloud.com",
            password: "Purple-Kayak-77-Bridge",
            url: "https://appleid.apple.com",
            notes: "",
            otpAuthURL: nil,
            customFields: [:],
            created: emailDates2.created,
            modified: emailDates2.modified
        ))

        let emailDates3 = stamped("2025-11-03T18:02:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("20000000-0000-0000-0000-000000000003"),
            groupID: groupEmail.id,
            title: "ProtonMail",
            username: "den.larkin@proton.me",
            password: "Fj29!qzWmL-proton",
            url: "https://mail.proton.me",
            notes: "Privacy-focused backup mailbox.",
            otpAuthURL: nil,
            customFields: [:],
            created: emailDates3.created,
            modified: emailDates3.modified
        ))

        let emailDates4 = stamped("2025-11-04T08:45:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("20000000-0000-0000-0000-000000000004"),
            groupID: groupEmail.id,
            title: "Outlook",
            username: "d.larkin@outlook.com",
            password: "Q7#mVxRt-outlook22",
            url: "https://outlook.live.com",
            notes: "",
            otpAuthURL: nil,
            customFields: [:],
            created: emailDates4.created,
            modified: emailDates4.modified
        ))

        let emailDates5 = stamped("2025-11-04T08:50:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("20000000-0000-0000-0000-000000000005"),
            groupID: groupEmail.id,
            title: "Fastmail",
            username: "den@fastmail.com",
            password: "N4vy-Cobalt-Otter",
            url: "https://www.fastmail.com",
            notes: "",
            otpAuthURL: nil,
            customFields: [:],
            created: emailDates5.created,
            modified: emailDates5.modified
        ))

        let emailDates6 = stamped("2025-11-05T21:11:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("20000000-0000-0000-0000-000000000006"),
            groupID: groupEmail.id,
            title: "Yahoo Mail",
            username: "denlarkin@yahoo.com",
            password: "Sunset-88-Harbor!",
            url: "https://login.yahoo.com",
            notes: "Old inbox, kept for a couple of newsletter subscriptions.",
            otpAuthURL: nil,
            customFields: [:],
            created: emailDates6.created,
            modified: emailDates6.modified
        ))

        let emailDates7 = stamped("2025-11-06T10:30:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("20000000-0000-0000-0000-000000000007"),
            groupID: groupEmail.id,
            title: "Zoho Mail",
            username: "den.larkin@zohomail.com",
            password: "Gr4nite-Falcon-09",
            url: "https://mail.zoho.com",
            notes: "",
            otpAuthURL: nil,
            customFields: ["Recovery Email": "den.recovery@zohomail.com"],
            created: emailDates7.created,
            modified: emailDates7.modified
        ))

        // MARK: Work (7)

        let workDates1 = stamped("2025-10-14T13:05:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("20000000-0000-0000-0000-000000000008"),
            groupID: groupWork.id,
            title: "GitHub",
            username: "denisitpro",
            password: "8vC!zQ2mLp-github",
            url: "https://github.com/login",
            notes: "",
            otpAuthURL: "otpauth://totp/GitHub:denisitpro?secret=KRSXG5CTMVRXEZLU&issuer=GitHub&algorithm=SHA1&digits=6&period=30",
            customFields: ["SSH Key Fingerprint": "SHA256:tZ4kR3F1n9pLwQxM7vC2sB8hY5aU0eD6jK1oI3rT9nQ"],
            created: workDates1.created,
            modified: workDates1.modified
        ))

        let workDates2 = stamped("2025-10-14T13:20:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("20000000-0000-0000-0000-000000000009"),
            groupID: groupWork.id,
            title: "Atlassian (Jira)",
            username: "den.larkin@cointelegraph.com",
            password: "R3d-Kestrel-Path41",
            url: "https://id.atlassian.com",
            notes: "",
            otpAuthURL: nil,
            customFields: [:],
            created: workDates2.created,
            modified: workDates2.modified
        ))

        let workDates3 = stamped("2025-10-15T09:00:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("2000000a-0000-0000-0000-00000000000a"),
            groupID: groupWork.id,
            title: "Slack",
            username: "den.larkin@cointelegraph.com",
            password: "Bl4ck-Anchor-Dune7",
            url: "https://cointelegraph.slack.com",
            notes: "",
            otpAuthURL: nil,
            customFields: [:],
            created: workDates3.created,
            modified: workDates3.modified
        ))

        let workDates4 = stamped("2025-10-16T16:40:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("2000000b-0000-0000-0000-00000000000b"),
            groupID: groupWork.id,
            title: "AWS Console",
            username: "den.larkin",
            password: "Xk9#mQ2vTz-aws!",
            url: "https://console.aws.amazon.com",
            notes: "IAM user, not root — root creds are not in this vault.",
            otpAuthURL: nil,
            customFields: ["Account ID": "482910337201", "Role": "Admin"],
            created: workDates4.created,
            modified: workDates4.modified
        ))

        let workDates5 = stamped("2025-10-17T11:25:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("2000000c-0000-0000-0000-00000000000c"),
            groupID: groupWork.id,
            title: "Google Workspace Admin",
            username: "admin@cointelegraph.com",
            password: "Vw8!zRp4-workspace",
            url: "https://admin.google.com",
            notes: "",
            otpAuthURL: nil,
            customFields: [:],
            created: workDates5.created,
            modified: workDates5.modified
        ))

        let workDates6 = stamped("2025-10-18T15:00:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("2000000d-0000-0000-0000-00000000000d"),
            groupID: groupWork.id,
            title: "Figma",
            username: "den.larkin@cointelegraph.com",
            password: "Teal-Osprey-63!",
            url: "https://www.figma.com/login",
            notes: "",
            otpAuthURL: nil,
            customFields: [:],
            created: workDates6.created,
            modified: workDates6.modified
        ))

        let workDates7 = stamped("2025-10-19T08:10:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("2000000e-0000-0000-0000-00000000000e"),
            groupID: groupWork.id,
            title: "Notion",
            username: "den.larkin@cointelegraph.com",
            password: "Amber-Trellis-902",
            url: "https://www.notion.so/login",
            notes: "",
            otpAuthURL: nil,
            customFields: [:],
            created: workDates7.created,
            modified: workDates7.modified
        ))

        // MARK: Finance (6)

        let financeDates1 = stamped("2025-09-01T07:30:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("2000000f-0000-0000-0000-00000000000f"),
            groupID: groupFinance.id,
            title: "Chase Bank",
            username: "denlarkin",
            password: "Chase!Willow-2025",
            url: "https://secure.chase.com",
            notes: "Primary checking + savings.",
            otpAuthURL: nil,
            customFields: [:],
            created: financeDates1.created,
            modified: financeDates1.modified
        ))

        let financeDates2 = stamped("2025-09-02T12:00:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("20000010-0000-0000-0000-000000000010"),
            groupID: groupFinance.id,
            title: "Fidelity Investments",
            username: "den.larkin",
            password: "Fj3#Marlin-Fidelity",
            url: "https://login.fidelity.com",
            notes: "401k rollover + brokerage.",
            otpAuthURL: nil,
            customFields: [:],
            created: financeDates2.created,
            modified: financeDates2.modified
        ))

        let financeDates3 = stamped("2025-09-03T19:45:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("20000011-0000-0000-0000-000000000011"),
            groupID: groupFinance.id,
            title: "Coinbase",
            username: "den.larkin@cointelegraph.com",
            password: "Zx7!Quartz-Coinbase",
            url: "https://www.coinbase.com/signin",
            notes: "",
            otpAuthURL: "otpauth://totp/Coinbase:den.larkin%40cointelegraph.com?secret=MFRGGZDFMZTWQ2LK&issuer=Coinbase&algorithm=SHA1&digits=6&period=30",
            customFields: [:],
            created: financeDates3.created,
            modified: financeDates3.modified
        ))

        let financeDates4 = stamped("2025-09-04T14:15:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("20000012-0000-0000-0000-000000000012"),
            groupID: groupFinance.id,
            title: "PayPal",
            username: "den.larkin@gmail.com",
            password: "P4yPal-Cinder-19",
            url: "https://www.paypal.com/signin",
            notes: "",
            otpAuthURL: nil,
            customFields: [:],
            created: financeDates4.created,
            modified: financeDates4.modified
        ))

        let financeDates5 = stamped("2025-09-05T10:05:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("20000013-0000-0000-0000-000000000013"),
            groupID: groupFinance.id,
            title: "Wise",
            username: "den.larkin@gmail.com",
            password: "Wise-Petrel-4471",
            url: "https://wise.com/login",
            notes: "USD/EUR transfers for contractor payments.",
            otpAuthURL: nil,
            customFields: [:],
            created: financeDates5.created,
            modified: financeDates5.modified
        ))

        let financeDates6 = stamped("2025-09-06T17:50:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("20000014-0000-0000-0000-000000000014"),
            groupID: groupFinance.id,
            title: "Vanguard",
            username: "denlarkin",
            password: "V4ngu4rd-Meridian",
            url: "https://investor.vanguard.com",
            notes: "IRA.",
            otpAuthURL: nil,
            customFields: [:],
            created: financeDates6.created,
            modified: financeDates6.modified
        ))

        return Vault(
            name: "Demo Vault",
            groups: [groupEmail, groupWork, groupFinance],
            entries: entries
        )
    }()
}
