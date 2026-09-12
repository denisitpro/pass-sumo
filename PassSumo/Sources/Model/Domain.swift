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
    /// All other string fields, minus the 5 standard ones + otp. Keyed by field name; see
    /// `VaultFieldValue` for why the value is not a bare `String`.
    var customFields: [String: VaultFieldValue]
    /// Index into KeePass's built-in icon set (0…68), stored verbatim as the file's `IconID`.
    ///
    /// Modelled as the raw integer rather than as an app-side enum because the integer is the
    /// interop contract: every other client reads this number and draws its own artwork for it.
    /// What pass-sumo draws for a given number is `StandardIconCatalog`'s business, not this
    /// type's — and a value outside 0…68 (another client's, or a future KeePass release's) must
    /// still round-trip untouched rather than be normalised away by an enum that cannot represent
    /// it.
    ///
    /// `customIconUUID`, KDBX's other icon channel, is deliberately still unmodelled and survives
    /// only through `KDBXContentMerge`'s preserved original — see `Vault`'s doc comment.
    var iconID: UInt32 = VaultEntry.defaultIconID
    /// File attachments on this entry, as METADATA ONLY — the bytes live once in `Vault.blobs`
    /// and are reached through `Vault.bytes(for:)`. See `VaultAttachment` for why.
    var attachments: [VaultAttachment] = []
    var created: Date
    var modified: Date
    /// When the PASSWORD itself last changed, derived from the entry's KDBX `<History>` — never
    /// from `modified`, which bumps on any field edit at all (issue #33). `nil` means "no
    /// derivable date": either the entry has no history to walk (never resaved by a second
    /// client, or another client's `HistoryMaxItems` trimmed it away entirely) or history exists
    /// but every recorded value is unavailable. This is deliberately NOT a substitute for
    /// `created` when history is empty — an entry manufactured with no evidence at all sorts into
    /// an explicit "unknown" bucket rather than silently pretending to be exactly as old as the
    /// entry itself.
    ///
    /// Computed ONCE, by `KDBXVaultProjection` at decode time (see `KDBXPasswordHistory`), not
    /// recomputed per render — deriving it means revealing the `Password` field of every history
    /// snapshot, which is exactly the protected-field decryption the entry list must not repeat
    /// on every row draw. Consequently this field is only as fresh as the last decode: an in-app
    /// password edit does not update it until the vault is saved and reopened, the same way the
    /// rest of `entry.history` only reaches the file through `KDBXContentMerge`'s preserved
    /// original rather than through anything `Vault` models live.
    var passwordLastChanged: Date? = nil

    /// Previous states of this entry that pass-sumo recorded and that the file's own `<History>`
    /// does not hold yet, oldest first — issue #75.
    ///
    /// **This is not "the entry's history".** The `<History>` a KeePass client wrote is NOT
    /// projected in here and never will be: a snapshot is a full KDBX entry carrying tags,
    /// AutoType, colours, expiry, custom data and its own positional binary-pool references, none
    /// of which `VaultEntrySnapshot` models, so round-tripping the file's snapshots through this
    /// array would quietly strip all of it. The file's own snapshots ride along untouched inside
    /// the preserved original, exactly as before (see `Vault`'s doc comment); this array carries
    /// only what pass-sumo itself has to ADD to them, and `KDBXContentMerge` appends it.
    ///
    /// It therefore accumulates for as long as the vault stays unlocked, not just until the next
    /// save: `VaultStore` keeps the same `DecodedVault` for the whole session, so every save
    /// re-derives the file from that one decode plus this array. Dropping an entry from it after a
    /// save would delete the snapshot from the file on the save after that.
    ///
    /// `VaultStore.upsert` is the only thing that appends here, and it OWNS this property the same
    /// way it owns `modified` — a caller's value is ignored, because the edit form builds a whole
    /// new `VaultEntry` and cannot know what the entry it is replacing had accumulated.
    var historyAdditions: [VaultEntrySnapshot] = []
}

// MARK: - Entry history

/// One past state of an entry: what a KDBX `<History>` snapshot records, limited to the fields
/// `VaultEntry` models.
///
/// A separate type rather than a `[VaultEntry]`, for two reasons that both bite. A struct cannot
/// contain an array of itself, so `VaultEntry.historyAdditions: [VaultEntry]` does not even
/// compile; and the three properties left out here are exactly the three that would be wrong to
/// keep — `id` (a snapshot shares its live entry's UUID, so a second copy of it is a chance to
/// disagree), `groupID` (a snapshot records field values, not where the entry sat: moving an entry
/// between folders is not an edit any KeePass client snapshots), and `historyAdditions` itself
/// (the format is explicit that a historical entry carries no history of its own, which is what
/// keeps growth linear rather than quadratic).
///
/// `password` is plaintext here for the same reason `VaultEntry.password` is, and with the same
/// consequence made explicit: a snapshot IS another copy of a secret, so changing a password does
/// not remove the old one from the database. It is encrypted exactly like the live value — never
/// less — but it is still there, which is the entire point of the feature and worth stating
/// rather than discovering.
struct VaultEntrySnapshot: Sendable, Equatable {
    var title: String
    var username: String
    var password: String
    var url: String
    var notes: String
    var otpAuthURL: String?
    var customFields: [String: VaultFieldValue]
    var iconID: UInt32
    /// The attachments the entry had at the time, as references into `Vault.blobs` — the same
    /// metadata-only shape `VaultEntry.attachments` uses, and it resolves through the same pool.
    /// A payload only a snapshot still references stays in the vault (and in the file's binary
    /// pool, which is append-only), so an old version's attachment is still openable.
    var attachments: [VaultAttachment]
    var created: Date
    /// The entry's `LastModificationTime` AS IT WAS, deliberately not "when this version was
    /// retired". `KDBXPasswordHistory` reads a snapshot's own modification time as the moment that
    /// version *became* current, which is the convention every KeePass-family client writes and
    /// issue #33's derivation already depends on.
    var modified: Date
}

extension VaultEntrySnapshot {
    /// The state `entry` is in right now, ready to be pushed onto its own history.
    init(of entry: VaultEntry) {
        self.init(
            title: entry.title,
            username: entry.username,
            password: entry.password,
            url: entry.url,
            notes: entry.notes,
            otpAuthURL: entry.otpAuthURL,
            customFields: entry.customFields,
            iconID: entry.iconID,
            attachments: entry.attachments,
            created: entry.created,
            modified: entry.modified
        )
    }

    /// This snapshot back in `VaultEntry` shape, so the codec can run its ONE field-mapping
    /// implementation over a snapshot as well as over a live entry.
    ///
    /// The alternative — a second mapping path for snapshots — would have to re-derive the TOTP
    /// convention, the reserved-key exclusions and the per-field protection classes, and the day
    /// those two copies disagree is the day a history snapshot is written with a password in the
    /// clear. `groupID` is `nil` because nothing downstream of the field mapping reads it: a
    /// snapshot is emitted inside its live entry, never placed in a group of its own.
    func entry(id: UUID) -> VaultEntry {
        VaultEntry(
            id: id,
            groupID: nil,
            title: title,
            username: username,
            password: password,
            url: url,
            notes: notes,
            otpAuthURL: otpAuthURL,
            customFields: customFields,
            iconID: iconID,
            attachments: attachments,
            created: created,
            modified: modified
        )
    }
}

extension VaultEntry {
    /// Whether replacing `other` with `self` is an EDIT — a change a KDBX client would push onto
    /// the entry's history — rather than a move or a re-stamp.
    ///
    /// Written as "normalise the exclusions away, then `==`", not as a field-by-field comparison,
    /// and that shape is the point: a property added to `VaultEntry` later is INCLUDED by default.
    /// The field-by-field form fails silently in the worse direction — a new field nobody thought
    /// to list here would simply stop being snapshotted, and the loss shows up as a missing old
    /// password months later. `EntryEditView.save()` used to have the same class of bug (rebuilding
    /// via `VaultEntry(...)` dropped `iconID`); it now copies-then-assigns (issue #95).
    ///
    /// Three things are deliberately not edits:
    ///
    /// - `groupID` — a move, including the move into the recycle bin that is all "delete" is here.
    ///   No KeePass client snapshots one; the format records it as `LocationChanged` plus a
    ///   `PreviousParentGroup` breadcrumb, which `KDBXContentMerge` already writes. Snapshotting
    ///   deletes would also mean every emptied bin had been silently duplicating entries first.
    /// - `modified` — `upsert` stamps it to now on every call, so comparing it would make every
    ///   save of an unchanged entry an edit.
    /// - `passwordLastChanged` and `historyAdditions` — derived and bookkeeping respectively, both
    ///   owned by `upsert` rather than by whoever built the entry.
    func differsInSnapshottedFields(from other: VaultEntry) -> Bool {
        func normalized(_ entry: VaultEntry) -> VaultEntry {
            var copy = entry
            copy.groupID = nil
            copy.modified = .distantPast
            copy.passwordLastChanged = nil
            copy.historyAdditions = []
            return copy
        }
        return normalized(self) != normalized(other)
    }
}

// MARK: - Custom fields

/// One custom string field's value, plus whether the file stores that field as a secret.
///
/// This used to be a bare `String`, and dropping the protection flag on decode cost two things: a
/// field another client had marked secret came back rendered in the clear, and the user had no way
/// to mark one of their own. The flag is deliberately ONE `Bool` rather than KDBXKit's four-case
/// `ProtectedString.Value`: the domain model must not learn the codec's storage classes (the
/// architecture contract's dependency-inversion rule — it is what lets the whole UI run against
/// in-memory fakes), and "is this a secret" is the only distinction the entry view and the writer
/// actually need. The collapse in both directions lives at the codec boundary, in
/// `Sources/KDBX/KDBXFieldKeys.swift`.
struct VaultFieldValue: Sendable, Equatable {
    /// Plaintext while unlocked, exactly like `VaultEntry.password` and for the same reason.
    var value: String
    /// `true` when the field is a secret: concealed in `EntryDetailView` until revealed, and
    /// written back into a protected on-disk class. Not derived from the value — it is the file's
    /// own marking, or the user's choice in the edit sheet.
    var isProtected: Bool
}

extension VaultFieldValue {
    /// A field that is not a secret. Spelled out at call sites so "shown in the clear" reads as a
    /// decision somebody made rather than a default that got inherited.
    static func plain(_ value: String) -> Self { .init(value: value, isProtected: false) }

    /// A field that is a secret.
    static func protected(_ value: String) -> Self { .init(value: value, isProtected: true) }
}

extension VaultEntry {
    /// What an entry whose icon was never chosen carries: KeePass's icon 0, the key.
    ///
    /// Not an assumption — every `.kdbx` under `Sources/UnitTests/Fixtures` was exported to XML
    /// and checked: every entry KeePassXC wrote without an explicit icon has `<IconID>0`. There is
    /// no "absent" spelling to distinguish from it, so 0 is both "default" and "the key icon", and
    /// nothing downstream may treat it as "unset".
    static let defaultIconID: UInt32 = 0
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
    /// The filename the user sees, and this type's `id`.
    ///
    /// The FORMAT does not guarantee this is unique within one entry: a repeated `<Binary Key>` is
    /// a validation warning, not a rejection, and KDBXKit's own `ProtectedBinary.key` is documented
    /// as nothing more than the filename. Duplicate `Identifiable` ids make `ForEach` render wrong
    /// and warn at runtime, so the invariant is ENFORCED ON THE WAY IN rather than assumed to hold:
    /// `KDBXAttachments.project` suffixes a repeated name as it reads the file, and `EntryEditView`
    /// does the same when the user picks a second file with a name already taken.
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
    /// The whole selection was refused, not one file in it — see
    /// `VaultAttachment.maximumBatchByteCount`.
    case batchTooLarge(totalByteCount: Int, limit: Int)
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

    /// Ceiling on ONE add operation: 100 MB, i.e. four attachments at the per-file cap.
    ///
    /// The per-file cap cannot bound a multi-file pick, and the file picker allows one. ⌘A over a
    /// folder of four hundred twenty-megabyte photos is a single gesture in which every individual
    /// file is legal and the vault grows by roughly 8 GB — the whole-database memory and save-time
    /// failure `maximumByteCount` exists to prevent, reached around the side.
    ///
    /// Four times the per-file cap, because the realistic batch is "the pages of one scanned
    /// document" or "the screenshots of one recovery flow" — a handful of files, not hundreds.
    /// Someone with genuinely more to attach can add them in several passes, making a deliberate
    /// choice each time rather than discovering the cost at the next save. Like the per-file cap it
    /// is a REFUSAL, and it refuses the whole selection rather than truncating it: attaching the
    /// first four of a hundred files and saying nothing is how a user ends up believing a document
    /// is in the vault when it is not.
    static let maximumBatchByteCount = 4 * maximumByteCount

    /// Screens one add operation's selection before a single byte of it is read.
    ///
    /// `byteCount` is what the filesystem declared for that file, or `nil` when it could not say.
    /// **`nil` fails CLOSED.** A volume that cannot report a size — a network or FUSE mount, a
    /// cloud placeholder that has not been materialised — is exactly where reading first and asking
    /// afterwards hurts most, so an unknown size is a refusal rather than a zero that waves the
    /// file straight past the check that exists for it.
    ///
    /// A selection over `maximumBatchByteCount` refuses EVERYTHING and accepts nothing; see that
    /// property for why a truncation would be worse than a refusal. Every problem in the selection
    /// is reported, not only the last one: picking three oversized files is one mistake made three
    /// times, and naming one of them sends the user back to rediscover the other two by hand.
    ///
    /// Pure, and separate from the file picker that calls it, so both rules have unit tests instead
    /// of only being reachable by driving an `NSOpenPanel`. It returns INDICES into `declaredSizes`
    /// rather than anything file-shaped — the caller keeps its URLs; this type has no business
    /// knowing they exist.
    static func screenBatch(
        declaredSizes: [(name: String, byteCount: Int?)]
    ) -> (accepted: [Int], problems: [VaultAttachmentError]) {
        var accepted: [Int] = []
        var problems: [VaultAttachmentError] = []
        var totalByteCount = 0

        for (index, file) in declaredSizes.enumerated() {
            guard let byteCount = file.byteCount else {
                problems.append(.unreadable(name: file.name))
                continue
            }
            guard byteCount <= maximumByteCount else {
                problems.append(.tooLarge(
                    name: file.name, byteCount: byteCount, limit: maximumByteCount
                ))
                continue
            }
            totalByteCount += byteCount
            accepted.append(index)
        }

        guard totalByteCount <= maximumBatchByteCount else {
            problems.append(.batchTooLarge(
                totalByteCount: totalByteCount, limit: maximumBatchByteCount
            ))
            return ([], problems)
        }
        return (accepted, problems)
    }

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
    /// Index into KeePass's built-in icon set, stored verbatim as the file's `IconID`. Same
    /// contract and the same reasoning as `VaultEntry.iconID`; only the default differs.
    var iconID: UInt32 = VaultGroup.defaultIconID
}

extension VaultGroup {
    /// What a folder whose icon was never chosen carries: KeePass's icon 48, the folder.
    ///
    /// Verified the same way as `VaultEntry.defaultIconID` — every group in every fixture that has
    /// no icon of its own, the KDBX root group included, has `<IconID>48`.
    static let defaultIconID: UInt32 = 48
}

/// Fully decrypted database content — everything the app can show or edit. Deliberately does NOT
/// model anything a KDBX file can carry that pass-sumo has no UI for yet (the file's own entry
/// history, user-supplied custom icons, unknown header/XML data); that unmodeled remainder is the
/// codec's job to round-trip via `DecodedVault.opaque`, not this type's job to represent. Three
/// deliberate exceptions:
///
/// - `VaultEntry.passwordLastChanged`: the file's history still isn't modeled (no list of past
///   snapshots read out of it exists here), but the single date derived from walking it is,
///   because issue #33 needs a sort key and computing that key once at decode time is what keeps
///   the entry list from re-decrypting history on every render.
/// - `VaultEntry.historyAdditions` (issue #75): the snapshots pass-sumo itself takes, which have
///   to be modeled because the model is what decides an edit happened. Write-only in the same
///   sense as above — nothing is ever read into it from the file.
/// - `iconID` on entries and groups (issue #89): KDBX's *built-in* icon index is modeled and
///   written back, because the app has to be able to change it. KDBX's *other* icon channel,
///   `CustomIconUUID` plus the `Meta/CustomIcons` image pool, is still unmodeled and still
///   round-trips opaquely — writing `iconID` must never disturb it, which is what
///   `KDBXCodecTests.testRoundTripPreservesCustomIconWhenIconIDIsChanged` exists to prove.
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
    /// A sentence for the person looking at the screen, plus — when there is one — the raw
    /// technical text from the layer that actually failed.
    ///
    /// The two are separate payloads because they have different audiences and the split kept
    /// being lost when they were one string. A KDBXKit error interpolated into the sentence put
    /// `invalidKeyLength(algorithm: KDBXKit.InnerHeader.EncryptionAlgorithm.ChaCha20, …)` in front
    /// of a user who cannot act on it, and it pushed the part they *can* act on out of view. The
    /// diagnostic is still shown — smaller, selectable, so it can be pasted into a bug report —
    /// but it is never what the first line says.
    case corrupted(String, diagnostic: String?)
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

    /// `groupID` and every nested folder under it. Used by the sidebar count and the list
    /// filter (issue #143) so selecting a parent is not an empty column.
    func subtreeGroupIDs(of groupID: UUID) -> Set<UUID> {
        var result: Set<UUID> = [groupID]
        var queue = [groupID]
        while let current = queue.popLast() {
            for child in groups where child.parentID == current {
                if result.insert(child.id).inserted {
                    queue.append(child.id)
                }
            }
        }
        return result
    }

    func entries(inSubtreeOf groupID: UUID) -> [VaultEntry] {
        let ids = subtreeGroupIDs(of: groupID)
        return entries.filter { entry in
            guard let gid = entry.groupID else { return false }
            return ids.contains(gid)
        }
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

// MARK: - Group tree

extension Vault {
    /// `groupID` together with every group nested beneath it, however deep.
    ///
    /// Fixed-point expansion rather than recursion — `recycleBinGroupIDs` is this function applied
    /// to the bin, and the reason is the same for both: `groups` is a flat parent-linked list that
    /// another KDBX client can leave a cycle in, and a walk that follows parents naively would not
    /// terminate on one. Each pass can only add ids, and there are finitely many, so this halts.
    ///
    /// The id itself is always in the result, even when no such group exists — a subtree is at
    /// minimum its own root. Callers that care whether the group is real check that separately
    /// rather than reading an empty set as "not found".
    func groupSubtreeIDs(of groupID: UUID) -> Set<UUID> {
        var result: Set<UUID> = [groupID]
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

    /// Whether `groupID` may be re-parented under `newParentID` (`nil` = the vault's top level).
    ///
    /// **The rule that matters is the cycle: a group may not be moved into its own descendant, nor
    /// into itself.** `KDBXContentMerge.buildGroup` does have a guard that survives such a vault,
    /// but that is an encoder backstop for input another client corrupted, and the price it pays is
    /// silently dropping a branch of the tree — data loss dressed up as robustness. A legal UI
    /// action must never be what reaches it, so the refusal lives here, where the caller can be
    /// told no and show the user nothing happened.
    ///
    /// A move to where the group already is passes this check: it is legal, merely pointless, and
    /// `moveGroup` is what reports that nothing changed.
    func canMoveGroup(_ groupID: UUID, under newParentID: UUID?) -> Bool {
        guard groups.contains(where: { $0.id == groupID }) else { return false }
        guard let newParentID else { return true }
        guard groups.contains(where: { $0.id == newParentID }) else { return false }
        // The subtree contains `groupID` itself, so "into itself" is refused by the same test.
        return !groupSubtreeIDs(of: groupID).contains(newParentID)
    }

    /// Re-parents `groupID` and reports whether the vault actually changed. Everything nested
    /// inside comes along untouched: children name their parent, so moving the root of a subtree
    /// moves the subtree.
    ///
    /// `false` means either the move was refused (see `canMoveGroup`) or it would have changed
    /// nothing — the caller must not mark the vault dirty on either.
    @discardableResult
    mutating func moveGroup(_ groupID: UUID, under newParentID: UUID?) -> Bool {
        guard canMoveGroup(groupID, under: newParentID),
              let index = groups.firstIndex(where: { $0.id == groupID }),
              groups[index].parentID != newParentID
        else { return false }
        groups[index].parentID = newParentID
        return true
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
        // The bin's own subtree, through the one cycle-safe walk both this and the group
        // operations share — see `groupSubtreeIDs(of:)` for why it is written the way it is.
        return groupSubtreeIDs(of: binID)
    }

    /// Whether the entry currently sits inside the recycle bin.
    func isInRecycleBin(_ entry: VaultEntry) -> Bool {
        guard let groupID = entry.groupID else { return false }
        return recycleBinGroupIDs.contains(groupID)
    }

    /// Every entry that is NOT in the recycle bin — what "all entries" means to the user.
    ///
    /// The same exclusion `search(_:includingRecycleBin:)` applies, hoisted so the list column
    /// (`EntryListFilter`) and the sidebar's "All Entries" count can share ONE definition instead
    /// of each re-deriving it. Sharing it is the point: while the exclusion lived only inside
    /// `search`, an empty query still listed the bin's contents, so recycling an entry left the
    /// row in place, still selected, with the detail pane unchanged — no visible effect at all.
    /// That reads as "the keystroke did not register" and invites a second ⌫, and the second one
    /// is the permanent delete.
    ///
    /// A database with no bin group — including one whose owner switched the bin off, where
    /// nothing was ever moved into one — yields `entries` unchanged.
    var liveEntries: [VaultEntry] {
        let excluded = recycleBinGroupIDs
        guard !excluded.isEmpty else { return entries }
        return entries.filter { $0.groupID.map(excluded.contains) != true }
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

    /// Moves a whole folder — its entries, and every folder nested inside it — into the recycle
    /// bin, and returns `true` when it did.
    ///
    /// The move is one assignment: children name their parent, so re-parenting the folder onto the
    /// bin takes the entire subtree with it, exactly the way `moveToRecycleBin(entryID:)` moves one
    /// entry. Nothing is copied and nothing is renumbered, so a restore is the reverse assignment.
    ///
    /// Returns `false` in three cases, and they are NOT interchangeable — which is why
    /// `VaultStore.plannedDeletion(forGroup:)`, and not this method's return value, is what decides
    /// what a delete means:
    ///
    /// - the database has the bin switched off, or the folder is already inside the bin — a
    ///   permanent delete, the same as for an entry;
    /// - the folder IS the bin, or the bin is nested somewhere inside it — neither a recycle nor a
    ///   permanent delete is right. Re-parenting would make the bin its own ancestor (a cycle), and
    ///   deleting outright would destroy the bin and everything anyone ever put in it.
    mutating func moveToRecycleBin(groupID: UUID) -> Bool {
        guard recycleBin.isEnabled,
              groups.contains(where: { $0.id == groupID }),
              // Covers "the folder IS the bin" too: the bin is the first member of its own subtree.
              !recycleBinGroupIDs.contains(groupID)
        else { return false }
        // The bin nested somewhere inside the folder being deleted. Refused rather than resolved:
        // every resolution moves someone else's bin to a place they did not put it.
        if let binID = recycleBin.groupID, groupSubtreeIDs(of: groupID).contains(binID) {
            return false
        }

        let binID = ensureRecycleBinGroup()
        // Found AFTER `ensureRecycleBinGroup`, which appends to `groups`. An index taken before a
        // mutation of the same array happens to survive an append, and would stop surviving the
        // day bin creation is written differently.
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return false }
        groups[index].parentID = binID
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
        // The icon is part of what makes this folder read as THE bin in other clients, exactly
        // like the name below — and now that `iconID` is modeled, it has to be set HERE. The codec
        // also stamps it when it mints the group (`KDBXContentMerge.makeGroup`), but the merge
        // then writes the model's `iconID` over whatever it stamped; a bin created with the
        // default folder icon would arrive in KeePassXC as an ordinary folder.
        let bin = VaultGroup(
            id: UUID(),
            parentID: nil,
            name: Self.recycleBinGroupName,
            iconID: KDBXRecycleBin.iconID
        )
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

    /// Removes a folder, every folder nested inside it, and every entry in any of them — no bin
    /// involved. Same obligation as the entry overload: the caller has already confirmed with the
    /// user, because nothing below this line asks.
    ///
    /// **Refuses to take the recycle bin with it.** Removing the bin would leave
    /// `Meta/RecycleBinUUID` pointing at a group that no longer exists, which other clients read as
    /// a damaged database rather than as "no bin". Emptying the bin is the operation that exists for
    /// that, and it deliberately keeps the group.
    mutating func removePermanently(groupID: UUID) {
        let doomed = groupSubtreeIDs(of: groupID)
        if let binID = recycleBin.groupID, doomed.contains(binID) { return }
        entries.removeAll { $0.groupID.map(doomed.contains) == true }
        groups.removeAll { doomed.contains($0.id) }
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
        let candidates = includingRecycleBin ? entries : liveEntries

        let needle = query.searchNormalized
        guard !needle.isEmpty else { return candidates }

        return candidates.filter { entry in
            if entry.title.searchNormalized.contains(needle) { return true }
            if entry.username.searchNormalized.contains(needle) { return true }
            if entry.url.searchNormalized.contains(needle) { return true }
            if entry.notes.searchNormalized.contains(needle) { return true }
            // See the doc comment above: this line is the differentiator, keep it.
            if entry.password.searchNormalized.contains(needle) { return true }
            for (name, field) in entry.customFields {
                if name.searchNormalized.contains(needle) { return true }
                // A protected field's value is searched like the password above: concealment is a
                // display rule, and a vault you cannot search by recovery code is worse at its job.
                if field.value.searchNormalized.contains(needle) { return true }
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
    /// so previews/UI tests exercise those code paths without needing a real KDBX file. Those
    /// custom fields deliberately cover BOTH protection states — a concealed one (`Recovery
    /// Email`) and plain ones (`SSH Key Fingerprint`, `Account ID`, `Role`) — so a preview or a
    /// screenshot shows what a real vault looks like rather than one uniform rendering. An SSH
    /// *public*-key fingerprint and an AWS account id are published identifiers, not secrets.
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
            username: "sample.user@example.com",
            password: "Tr0ub4dor&3-gmail",
            url: "https://accounts.google.com",
            notes: "Recovery phone on file. 2FA via authenticator app.",
            // Classic RFC-style demo secret (base32(\"Hello!\\xDE\\xAD\\xBE\\xEF\")), reused across
            // OTP libraries' own docs — deliberately recognizable as a placeholder, not a real seed.
            otpAuthURL: "otpauth://totp/Google:sample.user@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Google&algorithm=SHA1&digits=6&period=30",
            customFields: [:],
            created: emailDates1.created,
            modified: emailDates1.modified
        ))

        let emailDates2 = stamped("2025-11-02T09:20:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("20000000-0000-0000-0000-000000000002"),
            groupID: groupEmail.id,
            title: "iCloud",
            username: "sampleuser@example.com",
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
            username: "s.user.private@example.com",
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
            username: "s.user@example.com",
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
            username: "sample@example.com",
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
            username: "sampleuser82@example.com",
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
            username: "sample.user.alt@example.com",
            password: "Gr4nite-Falcon-09",
            url: "https://mail.zoho.com",
            notes: "",
            otpAuthURL: nil,
            customFields: ["Recovery Email": .protected("sample.recovery@example.com")],
            created: emailDates7.created,
            modified: emailDates7.modified
        ))

        // MARK: Work (7)

        let workDates1 = stamped("2025-10-14T13:05:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("20000000-0000-0000-0000-000000000008"),
            groupID: groupWork.id,
            title: "GitHub",
            username: "samplecoder",
            password: "8vC!zQ2mLp-github",
            url: "https://github.com/login",
            notes: "",
            otpAuthURL: "otpauth://totp/GitHub:samplecoder?secret=KRSXG5CTMVRXEZLU&issuer=GitHub&algorithm=SHA1&digits=6&period=30",
            customFields: ["SSH Key Fingerprint": .plain("SHA256:tZ4kR3F1n9pLwQxM7vC2sB8hY5aU0eD6jK1oI3rT9nQ")],
            created: workDates1.created,
            modified: workDates1.modified
        ))

        let workDates2 = stamped("2025-10-14T13:20:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("20000000-0000-0000-0000-000000000009"),
            groupID: groupWork.id,
            title: "Atlassian (Jira)",
            username: "sample.user@example.org",
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
            username: "sample.user@example.org",
            password: "Bl4ck-Anchor-Dune7",
            url: "https://slack.com/signin",
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
            username: "sample.user",
            password: "Xk9#mQ2vTz-aws!",
            url: "https://console.aws.amazon.com",
            notes: "IAM user, not root — root creds are not in this vault.",
            otpAuthURL: nil,
            customFields: ["Account ID": .plain("482910337201"), "Role": .plain("Admin")],
            created: workDates4.created,
            modified: workDates4.modified
        ))

        let workDates5 = stamped("2025-10-17T11:25:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("2000000c-0000-0000-0000-00000000000c"),
            groupID: groupWork.id,
            title: "Google Workspace Admin",
            username: "admin@example.org",
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
            username: "sample.user@example.org",
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
            username: "sample.user@example.org",
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
            username: "sampleuser",
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
            username: "sample.user",
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
            username: "sample.user@example.org",
            password: "Zx7!Quartz-Coinbase",
            url: "https://www.coinbase.com/signin",
            notes: "",
            otpAuthURL: "otpauth://totp/Coinbase:sample.user%40example.org?secret=MFRGGZDFMZTWQ2LK&issuer=Coinbase&algorithm=SHA1&digits=6&period=30",
            customFields: [:],
            created: financeDates3.created,
            modified: financeDates3.modified
        ))

        let financeDates4 = stamped("2025-09-04T14:15:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("20000012-0000-0000-0000-000000000012"),
            groupID: groupFinance.id,
            title: "PayPal",
            username: "sample.user@example.com",
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
            username: "sample.user@example.com",
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
            username: "sampleuser",
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
