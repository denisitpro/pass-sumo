import KDBXKit
import XCTest
@testable import PassSumo

/// Issue #75: an in-app edit has to leave a `<History>` snapshot of what the entry used to be.
///
/// Before this, `<History>` was round-tripped and never written — a password overwritten with a
/// typo was gone as far as the app was concerned, recoverable only by restoring the whole database
/// from a pre-save backup. The three layers are tested separately because they answer three
/// different questions:
///
/// - **Model** (`VaultStore.upsert`) — *when* is a snapshot taken, and of what. This is where the
///   decision lives, deliberately, so that every path that replaces an entry gets it rather than
///   only the one screen that happens to call it today.
/// - **Codec** (`KDBXContentMerge` + `KDBXEntryHistory`) — where the snapshot lands in the file,
///   that it is APPENDED to whatever another client already wrote, that its attachment references
///   still resolve, and that `Meta`'s two retention caps are honoured. Driven through
///   `KDBXContentMerge.apply` directly: that is the production merge, and skipping the KDF keeps
///   these microseconds rather than ~2s each.
/// - **End to end** — one real `VaultStore` + `KDBXKitCodec` save and reopen, and one
///   `keepassxc-cli` reading of the result, because "the bytes are where we think" is not the same
///   claim as "another client finds them there".
@MainActor
final class EntryHistorySnapshotTests: XCTestCase {
    private let password = "history-suite-master-password"

    // MARK: - Fixtures

    private func makeEntry(
        id: UUID = UUID(),
        groupID: UUID? = nil,
        title: String = "Sample",
        username: String = "sampleuser",
        password: String = "first-password",
        url: String = "https://example.com/login",
        notes: String = "",
        otpAuthURL: String? = nil,
        customFields: [String: VaultFieldValue] = [:],
        iconID: UInt32 = VaultEntry.defaultIconID,
        attachments: [VaultAttachment] = []
    ) -> VaultEntry {
        VaultEntry(
            id: id,
            groupID: groupID,
            title: title,
            username: username,
            password: password,
            url: url,
            notes: notes,
            otpAuthURL: otpAuthURL,
            customFields: customFields,
            iconID: iconID,
            attachments: attachments,
            created: Date(timeIntervalSince1970: 1_000),
            modified: Date(timeIntervalSince1970: 1_000)
        )
    }

    /// A freshly created, unlocked vault plus the fake disk under it — `InMemoryVaultFileAccess`,
    /// so nothing here touches a real file or the user's Application Support.
    private func makeStore(
        codec: any VaultCodec = InMemoryVaultCodec()
    ) async -> (store: VaultStore, fileAccess: InMemoryVaultFileAccess, url: URL) {
        let fileAccess = InMemoryVaultFileAccess()
        let store = VaultStore(codec: codec, fileAccess: fileAccess)
        let url = URL(fileURLWithPath: "/history-suite/\(UUID().uuidString).kdbx")
        await store.createNew(at: url, credentials: VaultCredentials(password: password, keyFile: nil))
        return (store, fileAccess, url)
    }

    private struct VaultIsLocked: Error {}

    private func unlockedVault(_ store: VaultStore) throws -> Vault {
        guard case .unlocked(let vault) = store.state else { throw VaultIsLocked() }
        return vault
    }

    private func onlyEntry(_ store: VaultStore) throws -> VaultEntry {
        let entries = try unlockedVault(store).entries
        XCTAssertEqual(entries.count, 1, "these tests keep exactly one entry in the vault")
        return try XCTUnwrap(entries.first)
    }

    // MARK: - Model: when a snapshot is taken

    /// The defect itself, at the layer that fixes it: one edit, one snapshot, and the snapshot
    /// holds the values the entry HAD while the live entry holds the new ones.
    func testEditingAnEntryRecordsOneSnapshotOfTheOldValues() async throws {
        let store = await makeStore().store
        store.upsert(makeEntry(title: "Bank", password: "old-password"))

        let before = try onlyEntry(store)
        XCTAssertTrue(before.historyAdditions.isEmpty, "a freshly created entry has nothing to snapshot")

        var edited = before
        edited.password = "new-password"
        store.upsert(edited)

        let after = try onlyEntry(store)
        XCTAssertEqual(after.password, "new-password", "the live entry must carry the new value")
        XCTAssertEqual(after.historyAdditions.count, 1)
        let snapshot = try XCTUnwrap(after.historyAdditions.first)
        XCTAssertEqual(snapshot.password, "old-password", "the whole point: the OLD password is recoverable")
        XCTAssertEqual(snapshot.title, "Bank")
        // The snapshot carries the entry's own old timestamps, not the moment it was retired —
        // `KDBXPasswordHistory` reads a snapshot's `modified` as when that version became current.
        XCTAssertEqual(snapshot.modified, before.modified)
        XCTAssertEqual(snapshot.created, before.created)
        XCTAssertGreaterThan(after.modified, snapshot.modified, "the live entry's stamp must move on")
    }

    /// Snapshots accumulate, oldest first, so an intermediate value is not lost by the edit after
    /// it. This is why the snapshot is taken in the model and not derived at save time from what
    /// is on disk: a save-time diff can only ever see the state the file was decoded in, so the
    /// middle value of two edits between saves would be unrecoverable.
    func testEverySubsequentEditAppendsAnotherSnapshotOldestFirst() async throws {
        let store = await makeStore().store
        store.upsert(makeEntry(password: "one"))

        for value in ["two", "three", "four"] {
            var edited = try onlyEntry(store)
            edited.password = value
            store.upsert(edited)
        }

        let final = try onlyEntry(store)
        XCTAssertEqual(final.password, "four")
        XCTAssertEqual(final.historyAdditions.map(\.password), ["one", "two", "three"])
    }

    /// Re-saving an entry nobody changed must not grow its history. `upsert` bumps `modified`
    /// unconditionally, so a comparison that included that stamp would call every save an edit and
    /// fill the file with identical snapshots.
    func testAnUnchangedUpsertRecordsNoSnapshot() async throws {
        let store = await makeStore().store
        store.upsert(makeEntry())

        let untouched = try onlyEntry(store)
        store.upsert(untouched)
        store.upsert(try onlyEntry(store))

        XCTAssertTrue(try onlyEntry(store).historyAdditions.isEmpty)
    }

    /// Moving an entry between folders is not an edit, and neither is deleting it — "delete" here
    /// IS a move, into the recycle bin. No KeePass client snapshots either; the format records a
    /// move as `LocationChanged` plus a `PreviousParentGroup` breadcrumb, which the merge already
    /// writes. Snapshotting them would mean every emptied bin had been silently duplicating the
    /// entries in it first.
    func testMovingOrDeletingAnEntryIsNotAnEdit() async throws {
        let store = await makeStore().store
        let folder = try XCTUnwrap(store.addGroup(named: "Work", parentID: nil))
        store.upsert(makeEntry())

        var moved = try onlyEntry(store)
        moved.groupID = folder.id
        store.upsert(moved)
        XCTAssertTrue(try onlyEntry(store).historyAdditions.isEmpty, "a move is not an edit")

        store.delete(entryID: moved.id)
        let binned = try XCTUnwrap(try unlockedVault(store).entries.first { $0.id == moved.id })
        XCTAssertNotEqual(binned.groupID, folder.id, "precondition: the delete moved it to the bin")
        XCTAssertTrue(binned.historyAdditions.isEmpty, "a delete is a move, not an edit")
    }

    /// A brand-new entry has no previous state to snapshot — and must not inherit a list the
    /// caller happened to be carrying. `upsert` owns this property outright.
    func testANewEntryHasNoHistoryEvenIfTheCallerSuppliesOne() async throws {
        let store = await makeStore().store
        var arriving = makeEntry()
        arriving.historyAdditions = [VaultEntrySnapshot(of: makeEntry(password: "not-this-entrys"))]

        store.upsert(arriving)

        XCTAssertTrue(try onlyEntry(store).historyAdditions.isEmpty)
    }

    /// `upsert` also owns `passwordLastChanged`, and has to: `EntryEditView.save()` builds a whole
    /// new `VaultEntry` out of the fields the form shows, so the value decoded from the file's
    /// `<History>` (issue #33) arrives here as the property's `nil` default. Passing that through
    /// erased the sort key on every edit; ignoring the caller both fixes that and makes the date
    /// derivable for an entry pass-sumo alone has ever edited, which is what #75 asks for.
    func testPasswordLastChangedIsStampedOnAPasswordEditAndCarriedThroughAnUnrelatedOne() async throws {
        let store = await makeStore().store
        store.upsert(makeEntry(password: "old"))
        XCTAssertNil(try onlyEntry(store).passwordLastChanged, "no evidence yet — must not be invented")

        var rotated = try onlyEntry(store)
        rotated.password = "rotated"
        store.upsert(rotated)
        let rotatedEntry = try onlyEntry(store)
        let stamped = try XCTUnwrap(rotatedEntry.passwordLastChanged)
        XCTAssertEqual(stamped, rotatedEntry.modified)

        // A later edit that leaves the password alone must not move the date — that is the exact
        // confusion between "modified" and "password changed" issue #33 exists to remove.
        var renamed = rotatedEntry
        renamed.title = "Renamed"
        store.upsert(renamed)
        let afterRename = try onlyEntry(store)
        XCTAssertEqual(afterRename.passwordLastChanged, stamped)
        XCTAssertEqual(afterRename.historyAdditions.count, 2, "the rename is still an edit")
    }

    /// Removing an attachment must not orphan the snapshot that still references it. `upsert`
    /// never removes anything from `vault.blobs`, which is the domain-level half of the same
    /// append-only rule the KDBX binary pool follows.
    func testAnAttachmentRemovedByAnEditStaysReachableThroughTheSnapshot() async throws {
        let store = await makeStore().store
        let bytes = Data("recovery-codes".utf8)
        let (attachment, blob) = try VaultAttachment.make(name: "codes.txt", bytes: bytes)
        store.upsert(makeEntry(attachments: [attachment]), addingBlobs: [blob])

        var stripped = try onlyEntry(store)
        stripped.attachments = []
        store.upsert(stripped)

        let entry = try onlyEntry(store)
        XCTAssertTrue(entry.attachments.isEmpty, "precondition: the live entry dropped it")
        XCTAssertEqual(entry.historyAdditions.first?.attachments, [attachment])
        let stillPooled = try unlockedVault(store).bytes(for: attachment)
        XCTAssertEqual(stillPooled, bytes)
    }

    // MARK: - Model: what counts as an edit

    /// The comparison is written as "normalise the exclusions away, then `==`" precisely so a
    /// field added to `VaultEntry` later is snapshotted by default. This pins both halves: every
    /// modelled field is an edit, and the four exclusions are not.
    func testDiffersInSnapshottedFieldsCoversEveryModelledFieldAndOnlyExcludesFour() throws {
        let base = makeEntry()
        let (attachment, _) = try VaultAttachment.make(name: "a.txt", bytes: Data("a".utf8))

        var mutations: [(String, VaultEntry)] = []
        func variant(_ label: String, _ change: (inout VaultEntry) -> Void) {
            var copy = base
            change(&copy)
            mutations.append((label, copy))
        }
        variant("title") { $0.title = "Other" }
        variant("username") { $0.username = "other" }
        variant("password") { $0.password = "other" }
        variant("url") { $0.url = "https://example.org" }
        variant("notes") { $0.notes = "note" }
        variant("otpAuthURL") { $0.otpAuthURL = "otpauth://totp/X?secret=JBSWY3DPEHPK3PXP" }
        variant("customFields") { $0.customFields = ["PIN": .protected("1234")] }
        variant("iconID") { $0.iconID = 12 }
        variant("attachments") { $0.attachments = [attachment] }
        variant("created") { $0.created = Date(timeIntervalSince1970: 5) }

        for (label, mutated) in mutations {
            XCTAssertTrue(
                mutated.differsInSnapshottedFields(from: base),
                "a change to \(label) must be snapshotted"
            )
        }

        var excluded = base
        excluded.groupID = UUID()
        excluded.modified = Date()
        excluded.passwordLastChanged = Date()
        excluded.historyAdditions = [VaultEntrySnapshot(of: base)]
        XCTAssertFalse(
            excluded.differsInSnapshottedFields(from: base),
            "placement, the modification stamp and the two properties upsert owns are not edits"
        )
    }

    // MARK: - Codec: where the snapshot lands

    /// The production merge, without the KDF — this is exactly what `KDBXKitCodec.encode` runs
    /// once it has unwrapped the origin.
    private func merged(_ vault: Vault, onto content: KDBXContent) -> KDBXContent {
        KDBXContentMerge.apply(vault, to: content)
    }

    private func emptyContent() -> KDBXContent {
        KDBXContent.makeEmpty(databaseName: "History Vault", generator: "PassSumoTests")
    }

    private func kdbxEntry(titled title: String, in content: KDBXContent) throws -> KDBX.Entry {
        var found: KDBX.Entry?
        content.database.visitEntries(in: content.database.root.group) { entry in
            if found == nil, Self.string("Title", in: entry) == title { found = entry }
        }
        return try XCTUnwrap(found, "no entry titled \(title)")
    }

    private static func string(_ key: String, in entry: KDBX.Entry) -> String? {
        entry.strings.first { $0.key == key }?.value.withRevealedString { $0 }
    }

    /// A vault with one entry that has been edited `count` times in the app, plus the content it
    /// was decoded from — the shape every trimming test below starts from.
    private func vaultWithEditedEntry(
        passwords: [String],
        content: KDBXContent
    ) throws -> Vault {
        var vault = KDBXVaultProjection.vault(from: content)
        var entry = makeEntry(password: try XCTUnwrap(passwords.first))
        vault.entries = [entry]
        // Applied once so the entry exists in the file, and the snapshots below are then built on
        // the object the file holds — the same sequence a real session goes through.
        let seeded = merged(vault, onto: content)
        vault = KDBXVaultProjection.vault(from: seeded)
        entry = try XCTUnwrap(vault.entries.first)
        for value in passwords.dropFirst() {
            entry.historyAdditions.append(VaultEntrySnapshot(of: entry))
            entry.password = value
        }
        vault.entries = [entry]
        return vault
    }

    /// The snapshot reaches the file where every other KDBX client looks for it: inside the live
    /// entry's `<History>`, sharing its UUID, carrying its own old values and its own old times.
    func testSnapshotIsWrittenIntoTheEntrysKDBXHistory() throws {
        let content = emptyContent()
        var vault = KDBXVaultProjection.vault(from: content)
        var entry = makeEntry(title: "Bank", password: "old-password")
        entry.historyAdditions = [VaultEntrySnapshot(of: entry)]
        entry.password = "new-password"
        entry.modified = Date(timeIntervalSince1970: 9_000)
        vault.entries = [entry]

        let saved = merged(vault, onto: content)
        let written = try kdbxEntry(titled: "Bank", in: saved)

        XCTAssertEqual(Self.string("Password", in: written), "new-password")
        XCTAssertEqual(written.history.count, 1)
        let snapshot = try XCTUnwrap(written.history.first)
        XCTAssertEqual(Self.string("Password", in: snapshot), "old-password")
        XCTAssertEqual(snapshot.uuid, entry.id, "a snapshot shares its live entry's UUID")
        XCTAssertEqual(snapshot.times?.lastModificationTime, Date(timeIntervalSince1970: 1_000))
        XCTAssertTrue(snapshot.history.isEmpty, "a historical entry carries no history of its own")
    }

    /// The password inside a snapshot is written protected, like the live one. A snapshot IS
    /// another copy of a secret; the copy must not be the one that is cheaper to read.
    func testASnapshottedPasswordIsWrittenProtected() throws {
        let content = emptyContent()
        var vault = KDBXVaultProjection.vault(from: content)
        var entry = makeEntry(password: "old-password")
        entry.historyAdditions = [VaultEntrySnapshot(of: entry)]
        entry.password = "new-password"
        vault.entries = [entry]

        let snapshot = try XCTUnwrap(
            try kdbxEntry(titled: "Sample", in: merged(vault, onto: content)).history.first
        )
        let value = try XCTUnwrap(snapshot.strings.first { $0.key == "Password" }?.value)
        XCTAssertTrue(value.isProtected, "a historical password must not be written in the clear")
    }

    /// Snapshots another client wrote are APPENDED to, never rebuilt: their exact objects survive,
    /// ours go after them. Rebuilding them from `VaultEntrySnapshot` would strip the tags,
    /// AutoType, expiry and custom data a snapshot also carries.
    func testOurSnapshotsAreAppendedToTheHistoryTheFileAlreadyHad() throws {
        var content = emptyContent()
        var vault = KDBXVaultProjection.vault(from: content)
        let entry = makeEntry(password: "live")
        vault.entries = [entry]
        content = merged(vault, onto: content)

        // A snapshot that came from somewhere else, complete with metadata we do not model.
        var inherited = try kdbxEntry(titled: "Sample", in: content)
        inherited.history = []
        inherited.tags = ["written-elsewhere"]
        inherited.strings = [KDBX.ProtectedString(key: "Password", value: .regular("ancient"))]
        try mutate(entryID: entry.id, in: &content) { $0.history = [inherited] }

        vault = KDBXVaultProjection.vault(from: content)
        var edited = try XCTUnwrap(vault.entries.first)
        edited.historyAdditions = [VaultEntrySnapshot(of: edited)]
        edited.password = "rotated"
        vault.entries = [edited]

        let written = try kdbxEntry(titled: "Sample", in: merged(vault, onto: content))
        XCTAssertEqual(written.history.map { Self.string("Password", in: $0) }, ["ancient", "live"])
        XCTAssertEqual(written.history.first?.tags, ["written-elsewhere"], "the foreign snapshot was rebuilt")
    }

    /// A snapshot inherits everything the domain does not model from the entry the FILE holds —
    /// which is not an approximation: pass-sumo cannot edit any of it, so the live entry's values
    /// are the values every past version had.
    func testASnapshotCarriesTheUnmodelledFieldsOfTheEntryItWasTakenFrom() throws {
        var content = emptyContent()
        var vault = KDBXVaultProjection.vault(from: content)
        let entry = makeEntry(password: "old")
        vault.entries = [entry]
        content = merged(vault, onto: content)
        try mutate(entryID: entry.id, in: &content) {
            $0.tags = ["work", "rotated-quarterly"]
            $0.overrideURL = "cmd://open-the-sample"
        }

        vault = KDBXVaultProjection.vault(from: content)
        var edited = try XCTUnwrap(vault.entries.first)
        edited.historyAdditions = [VaultEntrySnapshot(of: edited)]
        edited.password = "new"
        vault.entries = [edited]

        let snapshot = try XCTUnwrap(
            try kdbxEntry(titled: "Sample", in: merged(vault, onto: content)).history.first
        )
        XCTAssertEqual(snapshot.tags, ["work", "rotated-quarterly"])
        XCTAssertEqual(snapshot.overrideURL, "cmd://open-the-sample")
    }

    /// The pool invariant, from the direction that would break it: the live entry drops an
    /// attachment, the snapshot keeps it, and the payload must still be resolvable. Nothing may be
    /// removed from or renumbered in the pool, because every snapshot's `<Binary Ref>` is
    /// positional.
    func testASnapshotsAttachmentStillResolvesAfterTheLiveEntryDropsIt() throws {
        var content = emptyContent()
        var vault = KDBXVaultProjection.vault(from: content)
        let bytes = Data("recovery-codes-for-the-sample-account".utf8)
        let (attachment, blob) = try VaultAttachment.make(name: "codes.txt", bytes: bytes)
        vault.blobs[blob.id] = blob
        vault.entries = [makeEntry(attachments: [attachment])]
        content = merged(vault, onto: content)
        XCTAssertEqual(content.innerHeader.binaryContent.count, 1, "precondition: one pooled payload")

        vault = KDBXVaultProjection.vault(from: content)
        var stripped = try XCTUnwrap(vault.entries.first)
        stripped.historyAdditions = [VaultEntrySnapshot(of: stripped)]
        stripped.attachments = []
        vault.entries = [stripped]

        let saved = merged(vault, onto: content)
        let written = try kdbxEntry(titled: "Sample", in: saved)
        XCTAssertTrue(written.binaries.isEmpty, "the live entry dropped it")

        let pool = KDBXBinaryPool(saved.innerHeader.binaryContent)
        let snapshot = try XCTUnwrap(written.history.first)
        let reference = try XCTUnwrap(snapshot.binaries.first)
        XCTAssertEqual(reference.key, "codes.txt")
        guard case let .ref(index) = reference.value else {
            return XCTFail("the snapshot's attachment must be a pool reference, got \(reference.value)")
        }
        let slot = try XCTUnwrap(pool.slot(at: index), "the snapshot's ref points past the pool")
        XCTAssertEqual(slot.byteCount, bytes.count)
        XCTAssertEqual(
            saved.innerHeader.binaryContent.count,
            1,
            "the orphaned payload stays in the pool — slots are append-only, never reclaimed"
        )
    }

    /// Applies `change` to the one live entry with `entryID` inside `content`, so a test can put
    /// state on the file's own object that our projection has no field for.
    private func mutate(
        entryID: UUID,
        in content: inout KDBXContent,
        _ change: (inout KDBX.Entry) -> Void
    ) throws {
        var root = content.database.root.group
        let index = try XCTUnwrap(root.entries.firstIndex { $0.uuid == entryID })
        change(&root.entries[index])
        content.database.root.group = root
    }

    // MARK: - Codec: retention limits

    private func withLimits(
        _ content: KDBXContent,
        maxItems: KDBX.ValueOrUnlimited<UInt32>?,
        maxSize: KDBX.ValueOrUnlimited<UInt64>? = .unlimited
    ) -> KDBXContent {
        var result = content
        result.database.meta.historyMaxItems = maxItems
        result.database.meta.historyMaxSize = maxSize
        return result
    }

    func testHistoryIsTrimmedToHistoryMaxItemsOldestFirst() throws {
        let content = withLimits(emptyContent(), maxItems: .value(2))
        let seeded = try vaultWithEditedEntry(passwords: ["one", "two", "three", "four"], content: content)

        let written = try kdbxEntry(titled: "Sample", in: merged(seeded, onto: content))
        XCTAssertEqual(written.history.map { Self.string("Password", in: $0) }, ["two", "three"])
    }

    /// `HistoryMaxItems = 0` is a real instruction, not a missing value: KeePass writes it to mean
    /// "keep no history", and a database whose owner asked for that must not get history from us.
    func testHistoryMaxItemsOfZeroKeepsNoSnapshots() throws {
        let content = withLimits(emptyContent(), maxItems: .value(0))
        let seeded = try vaultWithEditedEntry(passwords: ["one", "two"], content: content)

        XCTAssertTrue(try kdbxEntry(titled: "Sample", in: merged(seeded, onto: content)).history.isEmpty)
    }

    func testUnlimitedHistoryMaxItemsKeepsEverySnapshot() throws {
        let content = withLimits(emptyContent(), maxItems: .unlimited)
        let passwords = (0 ... 14).map { "password-\($0)" }
        let seeded = try vaultWithEditedEntry(passwords: passwords, content: content)

        let written = try kdbxEntry(titled: "Sample", in: merged(seeded, onto: content))
        XCTAssertEqual(written.history.count, passwords.count - 1)
    }

    /// An absent `HistoryMaxItems` — which is what `makeEmpty` produces, and what plenty of real
    /// files have — falls back to KeePass's own default of ten rather than to no limit at all.
    func testAbsentHistoryMaxItemsFallsBackToTenSnapshots() throws {
        let content = withLimits(emptyContent(), maxItems: nil)
        XCTAssertNil(content.database.meta.historyMaxItems, "precondition: the element is absent")
        let passwords = (0 ... 14).map { "password-\($0)" }
        let seeded = try vaultWithEditedEntry(passwords: passwords, content: content)

        let written = try kdbxEntry(titled: "Sample", in: merged(seeded, onto: content))
        XCTAssertEqual(written.history.count, KDBXEntryHistory.defaultMaxItems)
        XCTAssertEqual(Self.string("Password", in: try XCTUnwrap(written.history.last)), "password-13")
    }

    /// The byte budget, honoured by dropping the oldest snapshots. The cap here is deliberately
    /// tight enough that only the newest few notes fit.
    func testHistoryMaxSizeDropsTheOldestSnapshots() throws {
        let filler = String(repeating: "x", count: 400)
        let content = withLimits(emptyContent(), maxItems: .unlimited, maxSize: .value(1_000))
        var vault = KDBXVaultProjection.vault(from: content)
        var entry = makeEntry(notes: filler)
        vault.entries = [entry]
        let seeded = merged(vault, onto: content)
        vault = KDBXVaultProjection.vault(from: seeded)
        entry = try XCTUnwrap(vault.entries.first)
        for index in 0 ..< 6 {
            entry.historyAdditions.append(VaultEntrySnapshot(of: entry))
            entry.password = "password-\(index)"
        }
        vault.entries = [entry]

        let written = try kdbxEntry(titled: "Sample", in: merged(vault, onto: content))
        XCTAssertGreaterThan(written.history.count, 0, "the newest snapshots must survive")
        XCTAssertLessThan(written.history.count, 6, "the byte budget must actually bite")
    }

    /// An attachment the live entry still has costs a snapshot nothing, because the pool stores
    /// the payload once. Charging every snapshot for a shared payload would let one screenshot
    /// evict every password beside it.
    func testASharedAttachmentIsNotChargedAgainstTheHistoryBudget() throws {
        let payload = Data(repeating: 0x5A, count: 4_000)
        let (attachment, blob) = try VaultAttachment.make(name: "scan.png", bytes: payload)
        let content = withLimits(emptyContent(), maxItems: .unlimited, maxSize: .value(5_000))
        var vault = KDBXVaultProjection.vault(from: content)
        vault.blobs[blob.id] = blob
        vault.entries = [makeEntry(attachments: [attachment])]
        let seeded = merged(vault, onto: content)
        vault = KDBXVaultProjection.vault(from: seeded)
        var entry = try XCTUnwrap(vault.entries.first)
        for index in 0 ..< 3 {
            entry.historyAdditions.append(VaultEntrySnapshot(of: entry))
            entry.password = "password-\(index)"
        }
        vault.entries = [entry]

        let written = try kdbxEntry(titled: "Sample", in: merged(vault, onto: seeded))
        XCTAssertEqual(written.history.count, 3, "three snapshots of 4 KB shared once must all fit in 5 KB")
    }

    /// An entry pass-sumo did NOT edit keeps its inherited history untrimmed, even past the
    /// default cap. The caps for an absent element are a convention we adopt, not something the
    /// file declared — applying them to an untouched entry would let a save that changed one
    /// password delete another client's history from an unrelated one.
    func testAnUneditedEntrysInheritedHistoryIsNeverTrimmed() throws {
        var content = withLimits(emptyContent(), maxItems: nil, maxSize: nil)
        var vault = KDBXVaultProjection.vault(from: content)
        let entry = makeEntry()
        vault.entries = [entry]
        content = merged(vault, onto: content)

        var template = try kdbxEntry(titled: "Sample", in: content)
        template.history = []
        let inherited = (0 ..< 25).map { index -> KDBX.Entry in
            var snapshot = template
            snapshot.strings = [KDBX.ProtectedString(key: "Password", value: .regular("old-\(index)"))]
            return snapshot
        }
        try mutate(entryID: entry.id, in: &content) { $0.history = inherited }

        vault = KDBXVaultProjection.vault(from: content)
        let written = try kdbxEntry(titled: "Sample", in: merged(vault, onto: content))
        XCTAssertEqual(written.history.count, 25, "an untouched entry's history must not be trimmed")
    }

    // MARK: - End to end

    /// The whole path, once, with real crypto: the app edits a password twice, saves, locks and
    /// reopens — and the file that comes back holds both previous values as `<History>`, with
    /// issue #33's password-change date now derivable from them.
    func testEditingSavingAndReopeningLeavesTheOldPasswordsInTheFile() async throws {
        let codec = KDBXKitCodec()
        let (store, fileAccess, url) = await makeStore(codec: codec)
        store.upsert(makeEntry(title: "Bank", password: "first"))
        for value in ["second", "third"] {
            var edited = try onlyEntry(store)
            edited.password = value
            store.upsert(edited)
        }
        await store.save()
        XCTAssertNil(store.lastError)
        store.lock()

        await store.open(url: url, credentials: VaultCredentials(password: password, keyFile: nil))
        XCTAssertNil(store.lastError)
        let reopened = try onlyEntry(store)
        XCTAssertEqual(reopened.password, "third")
        XCTAssertTrue(reopened.historyAdditions.isEmpty, "the file's own history is not projected back in")
        XCTAssertNotNil(reopened.passwordLastChanged, "issue #33's date is derivable now that history exists")

        // Straight off the (fake) disk and through the codec again, because what has to be true
        // is a fact about the FILE, not about anything the store still holds in memory.
        let onDisk = try codec.decode(
            fileData: try fileAccess.read(from: url),
            credentials: VaultCredentials(password: password, keyFile: nil)
        )
        let content = try XCTUnwrap((onDisk.opaque as? KDBXOrigin)?.content)
        let written = try kdbxEntry(titled: "Bank", in: content)
        XCTAssertEqual(written.history.map { Self.string("Password", in: $0) }, ["first", "second"])
    }

    /// And the claim that actually matters for interop: KeePassXC finds the snapshots where it
    /// looks for them. Its XML export is the probe — it prints `<History>` verbatim, so a passing
    /// assertion here means another client parsed our history, not merely that our own reader can
    /// read our own writer.
    func testKeePassXCReadsTheHistoryWeWrote() async throws {
        let cli = try Self.keePassXCCLIOrSkip()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("passsumo-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("history.kdbx")

        let codec = KDBXKitCodec()
        let credentials = VaultCredentials(password: password, keyFile: nil)
        var created = try codec.makeEmpty(name: "History Vault", credentials: credentials)
        var entry = makeEntry(title: "Bank", password: "before-rotation")
        entry.historyAdditions = [VaultEntrySnapshot(of: entry)]
        entry.password = "after-rotation"
        created.vault.entries = [entry]
        try codec.encode(created.vault, credentials: credentials, origin: created).write(to: path)

        let exported = try Self.run(cli, ["export", "-q", "-f", "xml", path.path], stdin: password + "\n")
        XCTAssertEqual(exported.status, 0, "keepassxc-cli could not open our file:\n\(exported.output)")
        XCTAssertTrue(
            exported.output.contains("before-rotation"),
            "KeePassXC did not find the history snapshot we wrote:\n\(exported.output)"
        )
        XCTAssertFalse(
            exported.output.contains("<History/>"),
            "the entry came back with an empty <History>:\n\(exported.output)"
        )
    }

    private static func keePassXCCLIOrSkip() throws -> String {
        let candidates = [
            "/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli",
            "/opt/homebrew/bin/keepassxc-cli",
            "/usr/local/bin/keepassxc-cli",
        ]
        guard let cli = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("keepassxc-cli is not installed — skipping the external interop check")
        }
        do {
            _ = try run(cli, ["--version"])
        } catch {
            throw XCTSkip("cannot launch a subprocess from this test host (sandboxed?): \(error)")
        }
        return cli
    }

    private static func run(
        _ launchPath: String,
        _ arguments: [String],
        stdin: String? = nil
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        if stdin != nil {
            process.standardInput = Pipe()
        }

        try process.run()
        if let stdin, let input = process.standardInput as? Pipe {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }
        // Read before waiting: a full pipe buffer would otherwise deadlock the child.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
