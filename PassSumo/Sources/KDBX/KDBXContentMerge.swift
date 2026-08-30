import Foundation
import KDBXKit

/// Applies a `Vault`'s edits onto the ORIGINAL `KDBXContent` the file was decoded from.
///
/// This is the half of the codec that makes pass-sumo a password manager rather than a data-loss
/// incident. It never constructs a database from `Vault`: for every group and entry it starts from
/// the object KDBXKit parsed out of the user's file and overwrites only the handful of fields
/// `Vault` actually models. Everything else on that object comes along untouched — entry history,
/// custom icons, tags, AutoType, colours, expiry, usage counts, and any `CustomData` a different
/// KDBX client wrote and we have never heard of.
///
/// Attachments are modelled now (see `KDBXAttachments`), so they are no longer on that
/// carried-along list — but the same principle applies one level down: an entry whose attachment
/// list did not change keeps its `<Binary>` elements byte-identical, and the binary pool is only
/// ever appended to, never compacted. `KDBXBinaryPool`'s doc comment has the full reasoning.
///
/// Two things the underlying library cannot preserve, so this type cannot either — do not read the
/// round-trip as byte-perfect:
///
/// - **Sub-second timestamps.** KDBXKit parses and writes KDBX times at one-second resolution.
/// - **Unknown XML elements outside `CustomData`.** `CustomData` is the format's sanctioned
///   extension point and KDBXKit round-trips it, including keys it does not understand. An element
///   another client invented *elsewhere* in the schema is dropped by the parser before this type
///   ever sees it.
enum KDBXContentMerge {
    static func apply(_ vault: Vault, to original: KDBXContent) -> KDBXContent {
        var content = original
        let now = Date()

        // Only assign when it actually differs: `Meta.databaseName`'s `didSet` bumps
        // `DatabaseNameChanged` and `SettingsChanged`, so an unconditional write would mark every
        // save as a rename and confuse merge tooling in other clients.
        if content.database.meta.databaseName != vault.name {
            content.database.meta.databaseName = vault.name
        }

        let index = OriginalIndex(root: original.database.root.group)
        let memoryProtection = original.database.meta.memoryProtection
        // The KDBX root group has a real UUID of its own; our model collapses it to a `nil` parent.
        // `PreviousParentGroup` is a plain UUID in the format with no "was at the root" spelling,
        // so a move out of the root has to name this id explicitly.
        let rootGroupUUID = original.database.root.group.uuid

        // Seeded from the file's own pool, appended to as new attachments arrive, written back
        // once at the end. Never compacted — see `KDBXBinaryPool`.
        var pool = KDBXBinaryPool(original.innerHeader.binaryContent)

        // Group ids the vault still knows about; anything the tree walk cannot reach is rescued
        // onto the root below rather than silently dropped.
        let knownGroupIDs = Set(vault.groups.map(\.id))
        let childGroups = Dictionary(grouping: vault.groups, by: \.parentID)
        let entriesByGroup = Dictionary(grouping: vault.entries, by: \.groupID)
        var emittedGroupIDs: Set<UUID> = []
        var emittedEntryIDs: Set<UUID> = []

        /// `parentID` is the group this entry is being emitted INTO, which is not always
        /// `entry.groupID` — an entry naming a group that no longer exists is rescued onto the root
        /// below. The move bookkeeping has to reflect where the entry actually lands, or a rescued
        /// entry would claim it never moved.
        func buildEntry(_ entry: VaultEntry, in parentID: UUID?) -> KDBX.Entry {
            emittedEntryIDs.insert(entry.id)
            var base = index.entries[entry.id] ?? KDBX.Entry(
                uuid: entry.id,
                times: KDBX.Times(creationTime: entry.created, lastModificationTime: entry.modified)
            )
            let baseTitle = base.strings
                .first { $0.key == KDBXStandardField.title.rawValue }?
                .value.withRevealedString { $0 } ?? ""

            base.strings = KDBXEntryStrings.apply(
                entry,
                to: base.strings,
                baseTitle: baseTitle,
                memoryProtection: memoryProtection
            )

            base.binaries = KDBXAttachments.merge(
                entry.attachments,
                into: base.binaries,
                blobs: vault.blobs,
                pool: &pool
            )

            var times = base.times ?? KDBX.Times()
            times.creationTime = restore(entry.created, into: times.creationTime)
            times.lastModificationTime = restore(entry.modified, into: times.lastModificationTime)

            // A move — including the move into the recycle bin, which is all "delete" is here —
            // updates `LocationChanged` and leaves a `PreviousParentGroup` breadcrumb. Both are
            // what KDBX merge tooling reads to decide which replica's placement of an item is the
            // more recent one, and what other clients' "restore from bin" acts on. Written ONLY on
            // an actual move, so a save that changed nothing still emits the same bytes.
            if let originalParent = index.entryParents[entry.id], originalParent != parentID {
                times.locationChanged = now
                base.previousParentGroup = originalParent ?? rootGroupUUID
            }
            base.times = times
            return base
        }

        func buildGroup(_ group: VaultGroup, in parentID: UUID?) -> KDBX.Group? {
            // A parent cycle in `vault.groups` (A→B→A) would recurse until the stack blew up, and
            // the crash would look like a codec bug rather than bad input. The vault is built by our
            // own UI so this should be unreachable — which is exactly why it is worth a guard
            // instead of a comment: an unreachable crash is still a crash.
            guard emittedGroupIDs.insert(group.id).inserted else { return nil }

            var base = index.groups[group.id] ?? makeGroup(
                group,
                isRecycleBin: group.id == vault.recycleBin.groupID,
                at: now
            )
            base.name = group.name
            base.entries = (entriesByGroup[group.id] ?? []).map { buildEntry($0, in: group.id) }
            base.groups = (childGroups[group.id] ?? []).compactMap { buildGroup($0, in: group.id) }

            if let originalParent = index.groupParents[group.id], originalParent != parentID {
                var times = base.times ?? KDBX.Times()
                times.locationChanged = now
                base.times = times
                base.previousParentGroup = originalParent ?? rootGroupUUID
            }
            return base
        }

        var root = original.database.root.group
        root.groups = (childGroups[nil] ?? []).compactMap { buildGroup($0, in: nil) }

        // Groups whose `parentID` points at a group that is not in the vault (or that a cycle kept
        // the walk from reaching) would otherwise vanish along with every entry inside them.
        // Re-home them at the top level: a folder in the wrong place is recoverable, a deleted one
        // is not.
        let orphanGroups = vault.groups.filter { !emittedGroupIDs.contains($0.id) }
        root.groups.append(contentsOf: orphanGroups.compactMap { buildGroup($0, in: nil) })

        // Same reasoning for entries: `groupID == nil` is the documented "root" case, and a
        // `groupID` naming a group that no longer exists is rescued to root rather than dropped.
        root.entries = vault.entries
            .filter { $0.groupID == nil || !knownGroupIDs.contains($0.groupID!) }
            .map { buildEntry($0, in: nil) }

        content.database.root.group = root
        content.database.root.deletedObjects = tombstones(
            existing: original.database.root.deletedObjects,
            removedGroups: Set(index.groups.keys).subtracting(emittedGroupIDs),
            removedEntries: Set(index.entries.keys).subtracting(emittedEntryIDs),
            at: now
        )
        content.innerHeader.binaryContent = pool.contents
        applyRecycleBinPointer(vault.recycleBin, to: &content.database.meta)

        return content
    }

    /// Builds the KDBX object for a group the file did not have yet.
    ///
    /// The recycle bin is the one group whose creation is more than "a folder with a name". Other
    /// clients *identify* it by `Meta/RecycleBinUUID`, but they *present* it by its icon, and they
    /// expect its contents to stay out of search and auto-type the way their own bin does — so a
    /// bin we create sets all three, rather than leaving a folder that is only nominally the bin.
    /// `enableSearching: .value(false)` is the format's own mechanism for "hide this subtree from
    /// search results", which is the same rule `Vault.search` enforces on our side.
    private static func makeGroup(_ group: VaultGroup, isRecycleBin: Bool, at now: Date) -> KDBX.Group {
        let times = KDBX.Times(
            creationTime: now,
            lastModificationTime: now,
            locationChanged: isRecycleBin ? now : nil
        )
        guard isRecycleBin else {
            return KDBX.Group(uuid: group.id, times: times)
        }
        return KDBX.Group(
            uuid: group.id,
            iconID: KDBXRecycleBin.iconID,
            times: times,
            enableAutoType: .value(false),
            enableSearching: .value(false)
        )
    }

    /// Points `Meta` at the vault's recycle-bin group.
    ///
    /// **Writes nothing when the database has the bin switched off.** `RecycleBinEnabled = false`
    /// is a decision its owner made in another client, and a password manager that quietly
    /// re-enabled it on the next save would be overriding that decision in a file it was only
    /// asked to edit. The domain layer already refuses to create a bin group in that case
    /// (`Vault.moveToRecycleBin`), so `groupID` is `nil` here and there is nothing to write.
    ///
    /// Both assignments are conditional because `Meta`'s own `didSet` observers bump
    /// `RecycleBinChanged` and `SettingsChanged` — an unconditional write would stamp a settings
    /// change into every save of an untouched database.
    private static func applyRecycleBinPointer(
        _ configuration: RecycleBinConfiguration,
        to meta: inout KDBX.Meta
    ) {
        guard configuration.isEnabled, let binID = configuration.groupID else { return }
        if meta.recycleBinUUID != binID {
            meta.recycleBinUUID = binID
        }
        if meta.recycleBinEnabled != true {
            meta.recycleBinEnabled = true
        }
    }

    /// KDBX times are optional in the schema, and the projection turns a missing one into
    /// `.distantPast`. Writing that sentinel back would ADD a year-0001 `<CreationTime>` to a file
    /// that deliberately had none — a diff against another client's copy for no reason. So: a
    /// sentinel over an absent original stays absent; anything else is written.
    private static func restore(_ modelDate: Date, into existing: Date?) -> Date? {
        if modelDate == .distantPast, existing == nil { return nil }
        return modelDate
    }

    /// Records a `DeletedObjects` tombstone for everything that was in the original file but is not
    /// in the vault any more.
    ///
    /// Without this, KDBX merge (KeePassXC's "Merge database", any two-way sync) treats a deleted
    /// entry as one the *other* replica has and this one lacks, and resurrects it. Existing
    /// tombstones are carried through untouched — they are another client's record of ITS
    /// deletions, and dropping them resurrects those instead.
    ///
    /// A recycle-bin delete produces NO tombstone, and must not: the entry still exists, it moved.
    /// Only emptying the bin — or a permanent delete — reaches this.
    private static func tombstones(
        existing: [KDBX.DeletedObject],
        removedGroups: Set<UUID>,
        removedEntries: Set<UUID>,
        at date: Date
    ) -> [KDBX.DeletedObject] {
        guard !removedGroups.isEmpty || !removedEntries.isEmpty else { return existing }
        var result = existing
        let alreadyRecorded = Set(existing.map(\.uuid))
        // Sorted so a save is deterministic given the same input — an unordered Set would shuffle
        // the tail of the file between otherwise identical saves and make diffs noisy.
        for uuid in removedGroups.union(removedEntries).sorted(by: { $0.uuidString < $1.uuidString })
            where !alreadyRecorded.contains(uuid)
        {
            result.append(KDBX.DeletedObject(uuid: uuid, deletionTime: date))
        }
        return result
    }
}

// MARK: - Index over the original tree

/// Flat lookup of every group and entry in the file we decoded, keyed by UUID, so the merge can
/// find an object's original even after the user moved it to a different folder.
private struct OriginalIndex {
    var groups: [UUID: KDBX.Group] = [:]
    var entries: [UUID: KDBX.Entry] = [:]

    /// Where each entry sat in the ORIGINAL tree, using the same "nil == root" convention as
    /// `VaultEntry.groupID`. `[UUID: UUID?]` rather than `[UUID: UUID]` so that "was at the root"
    /// (present, `nil`) stays distinguishable from "was not in the file at all" (absent) —
    /// collapsing the two would make every newly created entry look like a move.
    var entryParents: [UUID: UUID?] = [:]
    var groupParents: [UUID: UUID?] = [:]

    init(root: KDBX.Group) {
        // The root group itself is deliberately absent: it maps onto our `nil` parent sentinel and
        // is carried forward whole by the caller, never rebuilt from a `VaultGroup`.
        for child in root.groups { walk(child, parentID: nil) }
        for entry in root.entries {
            entries[entry.uuid] = entry
            entryParents[entry.uuid] = UUID?.none
        }
    }

    private mutating func walk(_ group: KDBX.Group, parentID: UUID?) {
        groups[group.uuid] = group
        groupParents[group.uuid] = parentID
        // History snapshots share their live entry's UUID, so indexing them would overwrite the
        // live entry with a stale revision — the exact shape of a silent data-loss bug. Only the
        // live entries are indexed; `history` rides along inside whichever entry object wins.
        for entry in group.entries {
            entries[entry.uuid] = entry
            entryParents[entry.uuid] = group.uuid
        }
        for child in group.groups { walk(child, parentID: group.uuid) }
    }
}

// MARK: - String fields

enum KDBXEntryStrings {
    /// Rewrites one entry's `String` fields from `VaultEntry`, leaving every field the model does
    /// not own exactly as it was.
    static func apply(
        _ entry: VaultEntry,
        to base: [KDBX.ProtectedString],
        baseTitle: String,
        memoryProtection: KDBX.MemoryProtectionConfig?
    ) -> [KDBX.ProtectedString] {
        var result = base

        let standard: [(KDBXStandardField, String)] = [
            (.title, entry.title),
            (.userName, entry.username),
            (.password, entry.password),
            (.url, entry.url),
            (.notes, entry.notes),
        ]
        for (field, value) in standard {
            // An absent standard field stays absent when the new value is empty. KDBX clients cope
            // with either, but adding five empty elements to an entry that had two is gratuitous
            // churn in someone else's file.
            if result.contains(where: { $0.key == field.rawValue }) || !value.isEmpty {
                result.setValue(
                    value,
                    forKey: field.rawValue,
                    defaultProtected: memoryProtection.protects(field)
                )
            }
        }

        // TOTP: only touched when the URL genuinely changed. Comparing against what the projection
        // would have produced from THIS base (same title it used, hence `baseTitle`) means an
        // untouched entry keeps its fields byte-identical — including a `TOTP Seed`/`TOTP Settings`
        // pair we cannot express as a URI at all.
        let baseURL = KDBXTOTPConvention.readOTPAuthURL(from: base, label: baseTitle)
        if entry.otpAuthURL != baseURL {
            result = KDBXTOTPConvention.write(entry.otpAuthURL, into: result)
        }

        // Custom fields. New ones default to protected-on-disk: a password manager's custom
        // attributes hold recovery codes and security answers far more often than they hold trivia,
        // and both KeePass and KeePassXC read a protected attribute transparently, so there is no
        // interop cost to erring this way. Existing fields keep whatever class the file gave them.
        let reserved = KDBXStandardField.allKeys.union(KDBXTOTPConvention.reservedKeys)
        for (key, value) in entry.customFields where !reserved.contains(key) {
            result.setValue(value, forKey: key, defaultProtected: true)
        }
        // A custom field the user removed has to actually go. Scoped to non-reserved keys so this
        // can never delete a standard field or a TOTP field the model does not carry.
        result.removeAll { !reserved.contains($0.key) && entry.customFields[$0.key] == nil }

        return result
    }
}
