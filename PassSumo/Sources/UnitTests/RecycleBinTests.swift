import KDBXKit
import XCTest
@testable import PassSumo

/// Recycle-bin tests, at all three levels the feature spans: the pure domain rules (`Vault`), the
/// mutation policy the UI actually calls (`VaultStore`), and what reaches the `.kdbx` file
/// (`KDBXKitCodec`).
///
/// The last of those is the one that matters for interop: KeePassXC, KeePassium and Strongbox all
/// recognise a bin by `Meta/RecycleBinUUID`, so a bin we create is only really a bin if that
/// pointer comes back out of the saved bytes.
///
/// Lives in its own file, in the existing `Sources/UnitTests` directory, so no `project.yml` edit
/// is needed.
@MainActor
final class RecycleBinTests: XCTestCase {
    // MARK: - Fixtures

    private func makeEntry(title: String, groupID: UUID? = nil, password: String = "") -> VaultEntry {
        VaultEntry(
            id: UUID(),
            groupID: groupID,
            title: title,
            username: "",
            password: password,
            url: "",
            notes: "",
            otpAuthURL: nil,
            customFields: [:],
            created: Date(timeIntervalSince1970: 0),
            modified: Date(timeIntervalSince1970: 0)
        )
    }

    private func makeVault(entries: [VaultEntry], groups: [VaultGroup] = []) -> Vault {
        Vault(name: "Test", groups: groups, entries: entries)
    }

    private func makeStore(_ vault: Vault) async -> VaultStore {
        let codec = InMemoryVaultCodec()
        let fileAccess = InMemoryVaultFileAccess()
        let credentials = VaultCredentials(password: "recycle-bin-tests", keyFile: nil)
        let url = URL(fileURLWithPath: "/recycle-bin-tests/vault.kdbx")
        let encoded = try! codec.encode(vault, credentials: credentials, origin: nil)
        _ = try! fileAccess.write(encoded, to: url)
        let store = VaultStore(codec: codec, fileAccess: fileAccess)
        await store.open(url: url, credentials: credentials)
        return store
    }

    private func unlockedVault(of store: VaultStore) throws -> Vault {
        guard case .unlocked(let vault) = store.state else {
            throw XCTSkip("store is not unlocked: \(store.state)")
        }
        return vault
    }

    // MARK: - Domain rules

    func testMoveToRecycleBinRelocatesTheEntryRatherThanRemovingIt() throws {
        var vault = makeVault(entries: [makeEntry(title: "Gmail")])
        let id = vault.entries[0].id

        XCTAssertTrue(vault.moveToRecycleBin(entryID: id))

        XCTAssertEqual(vault.entries.count, 1, "the entry must still exist — it moved, it was not deleted")
        let binID = try XCTUnwrap(vault.recycleBin.groupID, "a bin group must have been created")
        XCTAssertEqual(vault.entries[0].groupID, binID)
        XCTAssertEqual(
            vault.group(binID)?.name, Vault.recycleBinGroupName,
            "the bin must carry the name every KeePass-family client uses, or it reads as an ordinary folder"
        )
    }

    /// The bin is created on the FIRST delete and reused after that. A second bin group would give
    /// the database two folders competing for one `Meta/RecycleBinUUID` pointer.
    func testTheRecycleBinGroupIsCreatedOnceAndReused() throws {
        var vault = makeVault(entries: [makeEntry(title: "A"), makeEntry(title: "B")])
        XCTAssertNil(vault.recycleBin.groupID, "a fresh vault has no bin until something is deleted")

        XCTAssertTrue(vault.moveToRecycleBin(entryID: vault.entries[0].id))
        let firstBin = try XCTUnwrap(vault.recycleBin.groupID)
        XCTAssertTrue(vault.moveToRecycleBin(entryID: vault.entries[1].id))

        XCTAssertEqual(vault.recycleBin.groupID, firstBin)
        XCTAssertEqual(vault.groups.filter { $0.id == firstBin }.count, 1)
        XCTAssertEqual(vault.groups.count, 1, "exactly one bin group, no duplicates")
    }

    func testMoveToRecycleBinRefusesWhenTheDatabaseHasTheBinDisabled() {
        var vault = makeVault(entries: [makeEntry(title: "Gmail")])
        vault.recycleBin.isEnabled = false

        XCTAssertFalse(
            vault.moveToRecycleBin(entryID: vault.entries[0].id),
            "a disabled bin must report failure so the caller deletes permanently instead"
        )
        XCTAssertNil(vault.recycleBin.groupID, "no bin group may be created in a database that opted out")
        XCTAssertTrue(vault.groups.isEmpty)
    }

    func testMoveToRecycleBinRefusesForAnEntryAlreadyInTheBin() {
        var vault = makeVault(entries: [makeEntry(title: "Gmail")])
        let id = vault.entries[0].id
        XCTAssertTrue(vault.moveToRecycleBin(entryID: id))

        XCTAssertFalse(
            vault.moveToRecycleBin(entryID: id),
            "there is no second bin to move it to — this case is a permanent delete"
        )
    }

    /// The search rule this feature exists for: a deleted password must not turn up next to live
    /// ones, visually identical, ready to be copied and pasted somewhere it no longer works.
    func testRecycledEntriesAreExcludedFromSearch() throws {
        var vault = makeVault(entries: [
            makeEntry(title: "Gmail", password: "shared-secret"),
            makeEntry(title: "Gmail Old", password: "shared-secret"),
        ])
        let staleID = vault.entries[1].id
        XCTAssertTrue(vault.moveToRecycleBin(entryID: staleID))

        XCTAssertEqual(vault.search("Gmail").map(\.id), [vault.entries[0].id])
        XCTAssertEqual(
            vault.search("shared-secret").map(\.id), [vault.entries[0].id],
            "the password search differentiator must respect the bin too"
        )
        // An empty query is "no filter applied", not "show me the bin as well".
        XCTAssertEqual(vault.search("").map(\.id), [vault.entries[0].id])
    }

    func testSearchCanBeAskedToIncludeTheRecycleBin() throws {
        var vault = makeVault(entries: [makeEntry(title: "Gmail"), makeEntry(title: "Gmail Old")])
        XCTAssertTrue(vault.moveToRecycleBin(entryID: vault.entries[1].id))

        XCTAssertEqual(
            Set(vault.search("Gmail", includingRecycleBin: true).map(\.id)),
            Set(vault.entries.map(\.id)),
            "the opt-in is what lets a user search inside the bin they explicitly selected"
        )
    }

    /// Entries in a folder NESTED inside the bin are in the bin too — a user who deletes a whole
    /// folder in another client leaves exactly this shape behind.
    func testEntriesInAFolderNestedInsideTheBinAreAlsoExcludedFromSearch() throws {
        var vault = makeVault(entries: [makeEntry(title: "Live")])
        XCTAssertTrue(vault.moveToRecycleBin(entryID: vault.entries[0].id))
        let binID = try XCTUnwrap(vault.recycleBin.groupID)

        let nested = VaultGroup(id: UUID(), parentID: binID, name: "Deleted Work")
        vault.groups.append(nested)
        let buried = makeEntry(title: "Buried", groupID: nested.id)
        vault.entries.append(buried)

        XCTAssertTrue(vault.recycleBinGroupIDs.contains(nested.id))
        XCTAssertTrue(vault.search("Buried").isEmpty)
    }

    func testEmptyRecycleBinRemovesContentsButKeepsTheBinGroup() throws {
        var vault = makeVault(entries: [makeEntry(title: "Keep"), makeEntry(title: "Toss")])
        let keptID = vault.entries[0].id
        XCTAssertTrue(vault.moveToRecycleBin(entryID: vault.entries[1].id))
        let binID = try XCTUnwrap(vault.recycleBin.groupID)
        let nested = VaultGroup(id: UUID(), parentID: binID, name: "Deleted Work")
        vault.groups.append(nested)
        vault.entries.append(makeEntry(title: "Buried", groupID: nested.id))

        vault.emptyRecycleBin()

        XCTAssertEqual(vault.entries.map(\.id), [keptID])
        XCTAssertFalse(vault.groups.contains { $0.id == nested.id }, "folders inside the bin go too")
        XCTAssertTrue(
            vault.groups.contains { $0.id == binID },
            "the bin group itself stays — Meta/RecycleBinUUID still points at it"
        )
    }

    // MARK: - VaultStore policy

    func testStoreDeleteMovesToTheBinAndReportsItAsRecycled() async throws {
        let store = await makeStore(makeVault(entries: [makeEntry(title: "Gmail")]))
        let id = try unlockedVault(of: store).entries[0].id

        XCTAssertEqual(store.plannedDeletion(forEntry: id), .recycled)
        store.delete(entryID: id)

        let vault = try unlockedVault(of: store)
        XCTAssertEqual(vault.entries.count, 1)
        XCTAssertEqual(vault.entries[0].groupID, vault.recycleBin.groupID)
        XCTAssertTrue(store.isDirty)
    }

    func testStoreReportsASecondDeleteAsPermanentAndThenPerformsIt() async throws {
        let store = await makeStore(makeVault(entries: [makeEntry(title: "Gmail")]))
        let id = try unlockedVault(of: store).entries[0].id
        store.delete(entryID: id)

        XCTAssertEqual(
            store.plannedDeletion(forEntry: id), .permanent,
            "this is the value the UI keys its confirmation off — getting it wrong destroys data silently"
        )
        store.delete(entryID: id)
        XCTAssertTrue(try unlockedVault(of: store).entries.isEmpty)
    }

    func testStorePermanentlyDeleteBypassesTheBin() async throws {
        let store = await makeStore(makeVault(entries: [makeEntry(title: "Gmail")]))
        let vault = try unlockedVault(of: store)
        let id = vault.entries[0].id

        store.permanentlyDelete(entryID: id)

        let after = try unlockedVault(of: store)
        XCTAssertTrue(after.entries.isEmpty)
        XCTAssertNil(after.recycleBin.groupID, "a permanent delete must not create a bin on the way past")
    }

    func testStoreDeleteRemovesOutrightWhenTheDatabaseHasTheBinDisabled() async throws {
        var seed = makeVault(entries: [makeEntry(title: "Gmail")])
        seed.recycleBin.isEnabled = false
        let store = await makeStore(seed)
        let id = try unlockedVault(of: store).entries[0].id

        XCTAssertEqual(store.plannedDeletion(forEntry: id), .permanent)
        store.delete(entryID: id)

        let after = try unlockedVault(of: store)
        XCTAssertTrue(after.entries.isEmpty)
        XCTAssertNil(after.recycleBin.groupID)
        XCTAssertTrue(after.groups.isEmpty, "no bin folder may appear in a database that opted out")
    }

    func testStoreEmptyRecycleBinIsANoOpWhenThereIsNothingToEmpty() async throws {
        let store = await makeStore(makeVault(entries: [makeEntry(title: "Gmail")]))
        XCTAssertFalse(store.isDirty)

        store.emptyRecycleBin()

        XCTAssertFalse(store.isDirty, "an idle Empty must not manufacture unsaved changes")
        XCTAssertEqual(try unlockedVault(of: store).entries.count, 1)
    }

    // MARK: - What reaches the file

    private let codec = KDBXKitCodec()
    private static let kdbxKitPassword = "123"

    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: name, withExtension: "kdbx", subdirectory: "Fixtures/kdbxkit"),
            "fixture Fixtures/kdbxkit/\(name).kdbx is not in the test bundle"
        )
        return try Data(contentsOf: url)
    }

    private func kdbxCredentials() -> VaultCredentials {
        VaultCredentials(password: Self.kdbxKitPassword, keyFile: nil)
    }

    private static func content(of decoded: DecodedVault) -> KDBXContent? {
        (decoded.opaque as? KDBXOrigin)?.content
    }

    private static func group(_ id: UUID, in content: KDBXContent) -> KDBX.Group? {
        var found: KDBX.Group?
        content.database.visitGroups(in: content.database.root.group) { group in
            if group.uuid == id { found = group }
        }
        return found
    }

    /// The interop assertion. A bin we create must come back out of the saved bytes as
    /// `Meta/RecycleBinUUID` pointing at a real group — that pointer is the ONLY thing other
    /// clients use to tell the bin apart from an ordinary folder.
    func testRecyclingAnEntryWritesTheMetaPointerAndSurvivesAReload() throws {
        let creds = kdbxCredentials()
        let decoded = try codec.decode(fileData: try fixture("kpxc-rich"), credentials: creds)

        var vault = decoded.vault
        let victim = try XCTUnwrap(vault.entries.first)
        XCTAssertTrue(vault.moveToRecycleBin(entryID: victim.id))
        let binID = try XCTUnwrap(vault.recycleBin.groupID)

        let saved = try codec.encode(vault, credentials: creds, origin: decoded)
        let reopened = try codec.decode(fileData: saved, credentials: creds)

        XCTAssertEqual(reopened.vault.recycleBin.groupID, binID)
        XCTAssertTrue(reopened.vault.recycleBin.isEnabled)

        let content = try XCTUnwrap(Self.content(of: reopened))
        XCTAssertEqual(content.database.meta.recycleBinUUID, binID, "Meta/RecycleBinUUID")
        XCTAssertEqual(content.database.meta.recycleBinEnabled, true, "Meta/RecycleBinEnabled")
        XCTAssertNotNil(content.database.meta.recycleBinChanged, "Meta/RecycleBinChanged")

        let bin = try XCTUnwrap(Self.group(binID, in: content))
        XCTAssertEqual(bin.name, Vault.recycleBinGroupName)
        XCTAssertEqual(
            bin.iconID, KDBXRecycleBin.iconID,
            "without the trash icon other clients draw the bin as an ordinary folder"
        )
        XCTAssertEqual(bin.enableSearching, .value(false), "the format's own hide-from-search flag")

        // The entry MOVED — it is inside the bin, and its move is recorded the way KDBX merge
        // tooling expects.
        let moved = try XCTUnwrap(reopened.vault.entries.first { $0.id == victim.id })
        XCTAssertEqual(moved.groupID, binID)
        let kdbxEntry = try XCTUnwrap(bin.entries.first { $0.uuid == victim.id })
        XCTAssertNotNil(kdbxEntry.times?.locationChanged, "Times/LocationChanged must be stamped on a move")
        XCTAssertNotNil(kdbxEntry.previousParentGroup, "PreviousParentGroup is what 'restore' reads")

        // A recycle is not a deletion: no tombstone may be written, or a merge with another
        // replica would treat the entry as gone rather than moved.
        XCTAssertFalse(
            content.database.root.deletedObjects.contains { $0.uuid == victim.id },
            "moving to the bin must not record a DeletedObjects tombstone"
        )
    }

    /// The "someone else's database" rule: `RecycleBinEnabled = false` is a decision made in
    /// another client, and saving must not quietly reverse it.
    func testADatabaseWithTheBinDisabledIsNeverGivenOne() throws {
        let creds = kdbxCredentials()
        let opened = try codec.decode(fileData: try fixture("kpxc-rich"), credentials: creds)

        // Build the "bin disabled" starting point by turning the flag off in the decoded content
        // and saving it — the fixtures on disk all have the bin enabled, and this is the only way
        // to get an honestly-encoded disabled database without shipping another fixture.
        var origin = try XCTUnwrap(opened.opaque as? KDBXOrigin)
        origin.content.database.meta.recycleBinEnabled = false
        var seeded = opened
        seeded.opaque = origin
        seeded.vault.recycleBin.isEnabled = false
        let disabledBytes = try codec.encode(seeded.vault, credentials: creds, origin: seeded)

        let disabled = try codec.decode(fileData: disabledBytes, credentials: creds)
        XCTAssertFalse(disabled.vault.recycleBin.isEnabled, "precondition: the bin really is off")

        var vault = disabled.vault
        let victim = try XCTUnwrap(vault.entries.first)
        XCTAssertFalse(vault.moveToRecycleBin(entryID: victim.id))
        vault.removePermanently(entryID: victim.id)

        let saved = try codec.encode(vault, credentials: creds, origin: disabled)
        let reopened = try codec.decode(fileData: saved, credentials: creds)
        let content = try XCTUnwrap(Self.content(of: reopened))

        XCTAssertEqual(
            content.database.meta.recycleBinEnabled, false,
            "RecycleBinEnabled must still be false — we do not re-enable someone else's setting"
        )
        XCTAssertNil(reopened.vault.recycleBin.groupID)
        XCTAssertFalse(
            reopened.vault.groups.contains { $0.name == Vault.recycleBinGroupName },
            "no bin folder may be created in a database that opted out"
        )
        XCTAssertFalse(reopened.vault.entries.contains { $0.id == victim.id })
        // A real deletion, unlike a recycle, DOES get a tombstone so a merge does not resurrect it.
        XCTAssertTrue(content.database.root.deletedObjects.contains { $0.uuid == victim.id })
    }

    /// KDBX spells "no bin yet" as an all-zeroes `RecycleBinUUID`. Reading that as a real group id
    /// would send deleted entries into a group that cannot exist.
    func testAnAllZeroesRecycleBinUUIDReadsAsNoBin() throws {
        let creds = kdbxCredentials()
        // `KDBXContent.makeEmpty` is exactly this shape: enabled, pointer all zeroes.
        let empty = try codec.makeEmpty(name: "Fresh", credentials: creds)
        let content = try XCTUnwrap(Self.content(of: empty))

        XCTAssertEqual(content.database.meta.recycleBinUUID?.isAllZeroes, true, "precondition")
        XCTAssertNil(empty.vault.recycleBin.groupID)
        XCTAssertTrue(empty.vault.recycleBin.isEnabled)
        XCTAssertTrue(empty.vault.recycleBinGroupIDs.isEmpty)
    }

    /// Emptying the bin is the destructive one, and it must leave the tombstones a two-way merge
    /// needs — otherwise the next sync resurrects everything the user just threw away.
    func testEmptyingTheBinRemovesEntriesFromTheFileAndRecordsTombstones() throws {
        let creds = kdbxCredentials()
        let decoded = try codec.decode(fileData: try fixture("kpxc-rich"), credentials: creds)

        var vault = decoded.vault
        let victim = try XCTUnwrap(vault.entries.first)
        XCTAssertTrue(vault.moveToRecycleBin(entryID: victim.id))
        vault.emptyRecycleBin()

        let saved = try codec.encode(vault, credentials: creds, origin: decoded)
        let reopened = try codec.decode(fileData: saved, credentials: creds)
        let content = try XCTUnwrap(Self.content(of: reopened))

        XCTAssertFalse(reopened.vault.entries.contains { $0.id == victim.id })
        XCTAssertTrue(
            content.database.root.deletedObjects.contains { $0.uuid == victim.id },
            "without a tombstone a KDBX merge resurrects the entry from the other replica"
        )
        XCTAssertNotNil(
            reopened.vault.recycleBin.groupID,
            "the emptied bin group stays — Meta/RecycleBinUUID still points at it"
        )
    }
}
