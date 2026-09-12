import KDBXKit
import XCTest
@testable import PassSumo

/// Creating, renaming, deleting and moving a folder (issue #88), at the three levels the feature
/// spans: the pure domain rules (`Vault`), the policy the UI calls (`VaultStore`), and what reaches
/// the `.kdbx` file (`KDBXKitCodec`).
///
/// Written as a sibling of `RecycleBinTests` rather than folded into it, and deliberately reusing
/// its shape: deleting a folder IS a recycle-bin operation, and the two files are meant to be read
/// together. Lives in the existing `Sources/UnitTests` directory, so no `project.yml` edit is
/// needed.
@MainActor
final class GroupManagementTests: XCTestCase {
    // MARK: - Fixtures

    private func makeEntry(title: String, groupID: UUID? = nil) -> VaultEntry {
        VaultEntry(
            id: UUID(),
            groupID: groupID,
            title: title,
            username: "",
            password: "",
            url: "",
            notes: "",
            otpAuthURL: nil,
            customFields: [:],
            created: Date(timeIntervalSince1970: 0),
            modified: Date(timeIntervalSince1970: 0)
        )
    }

    private func makeVault(groups: [VaultGroup] = [], entries: [VaultEntry] = []) -> Vault {
        Vault(name: "Test", groups: groups, entries: entries)
    }

    private func makeStore(_ vault: Vault) async -> VaultStore {
        let codec = InMemoryVaultCodec()
        let fileAccess = InMemoryVaultFileAccess()
        let credentials = VaultCredentials(password: "group-management-tests", keyFile: nil)
        let url = URL(fileURLWithPath: "/group-management-tests/vault.kdbx")
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

    /// Work → Clients → Acme, plus one entry filed in the deepest folder, which is what makes
    /// "the whole subtree came along" an assertion about data and not just about `parentID`.
    private struct Tree {
        var vault: Vault
        var work: UUID
        var clients: UUID
        var acme: UUID
        var buried: UUID
    }

    private func makeTree() -> Tree {
        let work = VaultGroup(id: UUID(), parentID: nil, name: "Work")
        let clients = VaultGroup(id: UUID(), parentID: work.id, name: "Clients")
        let acme = VaultGroup(id: UUID(), parentID: clients.id, name: "Acme")
        let buried = makeEntry(title: "Acme VPN", groupID: acme.id)
        return Tree(
            vault: makeVault(groups: [work, clients, acme], entries: [buried]),
            work: work.id,
            clients: clients.id,
            acme: acme.id,
            buried: buried.id
        )
    }

    // MARK: - Domain: the subtree walk

    func testGroupSubtreeIDsCollectsEveryDescendant() {
        let tree = makeTree()

        XCTAssertEqual(tree.vault.groupSubtreeIDs(of: tree.work), [tree.work, tree.clients, tree.acme])
        XCTAssertEqual(tree.vault.groupSubtreeIDs(of: tree.clients), [tree.clients, tree.acme])
        XCTAssertEqual(tree.vault.groupSubtreeIDs(of: tree.acme), [tree.acme])
    }

    /// The reason the walk is a fixed-point expansion and not recursion: another KDBX client can
    /// leave a parent cycle behind, and this must terminate on one.
    func testGroupSubtreeIDsTerminatesOnACycle() {
        let a = VaultGroup(id: UUID(), parentID: nil, name: "A")
        let b = VaultGroup(id: UUID(), parentID: a.id, name: "B")
        var cyclic = a
        cyclic.parentID = b.id
        let vault = makeVault(groups: [cyclic, b])

        XCTAssertEqual(vault.groupSubtreeIDs(of: cyclic.id), [cyclic.id, b.id])
    }

    // MARK: - Domain: the cycle refusal

    /// **The refusal issue #88 exists to make impossible from the UI.** `KDBXContentMerge` has a
    /// cycle guard, but it survives the file by dropping a branch of the tree — so it must never be
    /// what catches a move the user was allowed to ask for.
    func testAGroupCannotBeMovedIntoItsOwnDescendant() {
        var tree = makeTree()

        XCTAssertFalse(tree.vault.canMoveGroup(tree.work, under: tree.clients), "one level down")
        XCTAssertFalse(tree.vault.canMoveGroup(tree.work, under: tree.acme), "two levels down")
        XCTAssertFalse(tree.vault.canMoveGroup(tree.work, under: tree.work), "into itself")

        XCTAssertFalse(tree.vault.moveGroup(tree.work, under: tree.acme))
        XCTAssertNil(
            tree.vault.group(tree.work)?.parentID,
            "a refused move must leave the tree exactly as it was"
        )
        XCTAssertEqual(tree.vault.group(tree.acme)?.parentID, tree.clients)
    }

    func testAGroupCanBeMovedToAnUnrelatedParentOrToTheTopLevel() {
        var tree = makeTree()
        let archive = VaultGroup(id: UUID(), parentID: nil, name: "Archive")
        tree.vault.groups.append(archive)

        XCTAssertTrue(tree.vault.moveGroup(tree.clients, under: archive.id))
        XCTAssertEqual(tree.vault.group(tree.clients)?.parentID, archive.id)
        // Acme was never touched, and is still under Clients — the subtree travelled with it.
        XCTAssertEqual(tree.vault.group(tree.acme)?.parentID, tree.clients)
        XCTAssertEqual(tree.vault.groupSubtreeIDs(of: archive.id), [archive.id, tree.clients, tree.acme])

        XCTAssertTrue(tree.vault.moveGroup(tree.clients, under: nil))
        XCTAssertNil(tree.vault.group(tree.clients)?.parentID)
    }

    func testMovingAGroupToWhereItAlreadyIsChangesNothing() {
        var tree = makeTree()

        XCTAssertTrue(
            tree.vault.canMoveGroup(tree.clients, under: tree.work),
            "it is a legal destination — merely the one it is already at"
        )
        XCTAssertFalse(
            tree.vault.moveGroup(tree.clients, under: tree.work),
            "false is what stops the caller marking a vault dirty for a move that did not happen"
        )
    }

    func testMovingAnUnknownGroupOrToAnUnknownParentIsRefused() {
        var tree = makeTree()
        let stranger = UUID()

        XCTAssertFalse(tree.vault.canMoveGroup(stranger, under: tree.work))
        XCTAssertFalse(tree.vault.canMoveGroup(tree.acme, under: stranger))
        XCTAssertFalse(tree.vault.moveGroup(tree.acme, under: stranger))
        XCTAssertEqual(tree.vault.group(tree.acme)?.parentID, tree.clients)
    }

    // MARK: - Domain: deleting a folder

    func testDeletingAFolderMovesTheWholeSubtreeIntoTheBin() throws {
        var tree = makeTree()

        XCTAssertTrue(tree.vault.moveToRecycleBin(groupID: tree.work))

        let binID = try XCTUnwrap(tree.vault.recycleBin.groupID)
        XCTAssertEqual(tree.vault.group(tree.work)?.parentID, binID)
        // Nothing was removed and nothing was re-parented but the folder itself: the subtree is in
        // the bin because its root is.
        XCTAssertEqual(tree.vault.groups.count, 4, "three folders plus the bin")
        XCTAssertEqual(tree.vault.entries.count, 1)
        XCTAssertEqual(tree.vault.group(tree.acme)?.parentID, tree.clients)
        for id in [tree.work, tree.clients, tree.acme] {
            XCTAssertTrue(tree.vault.recycleBinGroupIDs.contains(id), "every level counts as binned")
        }
        XCTAssertTrue(
            tree.vault.liveEntries.isEmpty,
            "the entry three folders down is deleted as far as the user is concerned"
        )
        XCTAssertTrue(tree.vault.search("Acme").isEmpty)
    }

    /// Undo is the reverse assignment, which is the property that makes recycling a folder safe to
    /// do without a confirmation.
    func testAFolderCanBeRestoredOutOfTheBin() throws {
        var tree = makeTree()
        XCTAssertTrue(tree.vault.moveToRecycleBin(groupID: tree.work))

        XCTAssertTrue(tree.vault.moveGroup(tree.work, under: nil))

        XCTAssertNil(tree.vault.group(tree.work)?.parentID)
        XCTAssertEqual(tree.vault.liveEntries.map(\.id), [tree.buried])
    }

    func testDeletingAFolderIsRefusedWhenTheDatabaseHasTheBinDisabled() {
        var tree = makeTree()
        tree.vault.recycleBin.isEnabled = false

        XCTAssertFalse(tree.vault.moveToRecycleBin(groupID: tree.work))
        XCTAssertNil(tree.vault.recycleBin.groupID, "no bin folder in a database that opted out")
        XCTAssertEqual(tree.vault.groups.count, 3)
    }

    func testDeletingAFolderAlreadyInTheBinIsRefusedSoTheCallerDeletesPermanently() throws {
        var tree = makeTree()
        XCTAssertTrue(tree.vault.moveToRecycleBin(groupID: tree.work))

        XCTAssertFalse(tree.vault.moveToRecycleBin(groupID: tree.work), "the folder itself")
        XCTAssertFalse(tree.vault.moveToRecycleBin(groupID: tree.acme), "and anything under it")
    }

    /// The bin cannot be recycled into itself, and cannot be recycled into a copy of itself either
    /// — there is only one, and `Meta/RecycleBinUUID` points at it.
    func testTheRecycleBinItselfCannotBeDeleted() throws {
        var tree = makeTree()
        XCTAssertTrue(tree.vault.moveToRecycleBin(groupID: tree.acme))
        let binID = try XCTUnwrap(tree.vault.recycleBin.groupID)

        XCTAssertFalse(tree.vault.moveToRecycleBin(groupID: binID))
        tree.vault.removePermanently(groupID: binID)
        XCTAssertTrue(
            tree.vault.groups.contains { $0.id == binID },
            "removing the bin would leave Meta/RecycleBinUUID pointing at nothing"
        )
    }

    /// The layout only another client can produce: the bin nested inside an ordinary folder.
    /// Recycling that folder would make the bin its own ancestor.
    func testAFolderThatCONTAINSTheBinCannotBeDeletedEitherWay() throws {
        var tree = makeTree()
        XCTAssertTrue(tree.vault.moveToRecycleBin(groupID: tree.acme))
        let binID = try XCTUnwrap(tree.vault.recycleBin.groupID)
        // Re-home the bin under Work, which is what leaves the shape under test.
        XCTAssertTrue(tree.vault.moveGroup(binID, under: tree.work))

        XCTAssertFalse(tree.vault.moveToRecycleBin(groupID: tree.work))
        tree.vault.removePermanently(groupID: tree.work)
        XCTAssertTrue(tree.vault.groups.contains { $0.id == binID })
        XCTAssertTrue(tree.vault.groups.contains { $0.id == tree.work })
    }

    func testPermanentlyRemovingAFolderTakesItsSubtreeAndEveryEntryInIt() {
        var tree = makeTree()
        let survivor = makeEntry(title: "Elsewhere")
        tree.vault.entries.append(survivor)

        tree.vault.removePermanently(groupID: tree.work)

        XCTAssertTrue(tree.vault.groups.isEmpty, "the folder and both levels beneath it")
        XCTAssertEqual(tree.vault.entries.map(\.id), [survivor.id])
    }

    // MARK: - VaultStore: create, rename, move

    func testStoreAddGroupCreatesItUnderTheChosenParentAndMarksTheVaultDirty() async throws {
        let tree = makeTree()
        let store = await makeStore(tree.vault)

        let created = try XCTUnwrap(store.addGroup(named: "Suppliers", parentID: tree.work))

        XCTAssertEqual(created.name, "Suppliers")
        XCTAssertEqual(created.parentID, tree.work)
        XCTAssertEqual(created.iconID, VaultGroup.defaultIconID)
        XCTAssertEqual(try unlockedVault(of: store).group(created.id), created)
        XCTAssertTrue(store.isDirty)
    }

    func testStoreAddGroupHonoursANonDefaultIconID() async throws {
        let store = await makeStore(makeVault())
        // 37 is KeePass's Homebanking icon, well away from the default folder (48).
        let created = try XCTUnwrap(store.addGroup(named: "Bank", parentID: nil, iconID: 37))

        XCTAssertEqual(created.iconID, 37)
        XCTAssertEqual(try unlockedVault(of: store).group(created.id)?.iconID, 37)
    }

    func testStoreAddGroupTrimsTheNameAndRefusesABlankOne() async throws {
        let store = await makeStore(makeVault())

        let padded = try XCTUnwrap(store.addGroup(named: "  Work  ", parentID: nil))
        XCTAssertEqual(padded.name, "Work")

        XCTAssertNil(store.addGroup(named: "   ", parentID: nil), "a folder called \"\" is a bug in every client that opens the file")
        XCTAssertEqual(try unlockedVault(of: store).groups.count, 1)
    }

    func testStoreAddGroupRefusesAParentThatIsNotInTheVault() async throws {
        let store = await makeStore(makeVault())

        XCTAssertNil(store.addGroup(named: "Orphan", parentID: UUID()))
        XCTAssertTrue(try unlockedVault(of: store).groups.isEmpty)
        XCTAssertFalse(store.isDirty)
    }

    func testStoreAddGroupIsANoOpAgainstALockedStore() async throws {
        let store = await makeStore(makeVault())
        store.lock()

        XCTAssertNil(store.addGroup(named: "Work", parentID: nil))
        XCTAssertFalse(store.isDirty)
    }

    func testStoreRenameGroupRenamesItAndLeavesAnUnchangedNameAlone() async throws {
        let tree = makeTree()
        let store = await makeStore(tree.vault)

        store.renameGroup(tree.work, to: "  Day Job  ")
        XCTAssertEqual(try unlockedVault(of: store).group(tree.work)?.name, "Day Job")
        XCTAssertTrue(store.isDirty)

        await store.save()
        XCTAssertFalse(store.isDirty, "precondition for the no-op assertions below")

        store.renameGroup(tree.work, to: "Day Job")
        XCTAssertFalse(store.isDirty, "renaming to the current name must not manufacture a save")
        store.renameGroup(tree.work, to: "   ")
        XCTAssertFalse(store.isDirty)
        XCTAssertEqual(try unlockedVault(of: store).group(tree.work)?.name, "Day Job")
    }

    func testStoreMoveGroupRefusesADescendantAndLeavesTheVaultClean() async throws {
        let tree = makeTree()
        let store = await makeStore(tree.vault)

        XCTAssertFalse(store.moveGroup(tree.work, under: tree.acme))

        XCTAssertNil(try unlockedVault(of: store).group(tree.work)?.parentID)
        XCTAssertFalse(store.isDirty, "a refused move is not an edit")
    }

    func testStoreMoveGroupPerformsALegalMove() async throws {
        let tree = makeTree()
        let store = await makeStore(tree.vault)

        XCTAssertTrue(store.moveGroup(tree.acme, under: nil))

        XCTAssertNil(try unlockedVault(of: store).group(tree.acme)?.parentID)
        XCTAssertTrue(store.isDirty)
    }

    // MARK: - VaultStore: the deletion policy

    func testStorePlansAFirstFolderDeleteAsRecycledAndASecondAsPermanent() async throws {
        let tree = makeTree()
        let store = await makeStore(tree.vault)

        XCTAssertEqual(store.plannedDeletion(forGroup: tree.work), .recycled)
        store.delete(groupID: tree.work)

        let recycled = try unlockedVault(of: store)
        XCTAssertEqual(recycled.group(tree.work)?.parentID, recycled.recycleBin.groupID)
        XCTAssertEqual(
            store.plannedDeletion(forGroup: tree.work), .permanent,
            "this is the value the UI keys its confirmation off — getting it wrong destroys data silently"
        )

        store.delete(groupID: tree.work)
        let gone = try unlockedVault(of: store)
        XCTAssertFalse(gone.groups.contains { $0.id == tree.work })
        XCTAssertFalse(gone.groups.contains { $0.id == tree.acme }, "the subtree went with it")
        XCTAssertTrue(gone.entries.isEmpty)
    }

    func testStorePlansNoDeletionAtAllForTheBinOrAFolderContainingIt() async throws {
        let tree = makeTree()
        let store = await makeStore(tree.vault)
        store.delete(groupID: tree.acme)
        let binID = try XCTUnwrap(try unlockedVault(of: store).recycleBin.groupID)

        XCTAssertNil(store.plannedDeletion(forGroup: binID), "the bin is emptied, never deleted")

        XCTAssertTrue(store.moveGroup(binID, under: tree.work))
        XCTAssertNil(
            store.plannedDeletion(forGroup: tree.work),
            "recycling it would make the bin its own ancestor; deleting it outright would destroy the bin"
        )

        // And the store honours its own plan rather than falling through to the destructive branch.
        store.delete(groupID: tree.work)
        let after = try unlockedVault(of: store)
        XCTAssertTrue(after.groups.contains { $0.id == tree.work })
        XCTAssertTrue(after.groups.contains { $0.id == binID })
    }

    func testStorePermanentlyDeleteFolderTakesEverythingInsideItAndRefusesTheBin() async throws {
        let tree = makeTree()
        let store = await makeStore(tree.vault)
        store.delete(groupID: tree.acme)
        let binID = try XCTUnwrap(try unlockedVault(of: store).recycleBin.groupID)
        await store.save()
        XCTAssertFalse(store.isDirty, "precondition")

        store.permanentlyDelete(groupID: binID)
        XCTAssertFalse(store.isDirty, "a refused delete must not manufacture unsaved changes")
        XCTAssertTrue(try unlockedVault(of: store).groups.contains { $0.id == binID })

        store.permanentlyDelete(groupID: tree.work)
        let after = try unlockedVault(of: store)
        XCTAssertTrue(store.isDirty)
        XCTAssertFalse(after.groups.contains { $0.id == tree.work })
        XCTAssertFalse(after.groups.contains { $0.id == tree.clients })
        // Acme was recycled first, so it is a child of the BIN by now, not of Clients — and a
        // permanent delete of Work must not reach across into the bin and take it.
        XCTAssertTrue(after.groups.contains { $0.id == tree.acme })
        XCTAssertEqual(after.entries.map(\.id), [tree.buried])
    }

    func testStoreDeleteFolderRemovesItOutrightWhenTheDatabaseHasTheBinDisabled() async throws {
        var tree = makeTree()
        tree.vault.recycleBin.isEnabled = false
        let store = await makeStore(tree.vault)

        XCTAssertEqual(store.plannedDeletion(forGroup: tree.work), .permanent)
        store.delete(groupID: tree.work)

        let after = try unlockedVault(of: store)
        XCTAssertTrue(after.groups.isEmpty, "no bin folder may appear in a database that opted out")
        XCTAssertTrue(after.entries.isEmpty)
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

    /// The interop assertion for a folder pass-sumo created: it has to come back out of the saved
    /// bytes as a real nested `<Group>` with a name and a UUID, in the right place, or it is not a
    /// folder any other client will show.
    func testAGroupCreatedHereSurvivesAnEncodeAndReloadAtTheRightDepth() throws {
        let creds = kdbxCredentials()
        let decoded = try codec.decode(fileData: try fixture("kpxc-rich"), credentials: creds)

        var vault = decoded.vault
        let parent = VaultGroup(id: UUID(), parentID: nil, name: "PassSumo Top")
        let child = VaultGroup(id: UUID(), parentID: parent.id, name: "PassSumo Nested")
        vault.groups.append(contentsOf: [parent, child])

        let saved = try codec.encode(vault, credentials: creds, origin: decoded)
        let reopened = try codec.decode(fileData: saved, credentials: creds)

        XCTAssertEqual(reopened.vault.group(parent.id)?.name, "PassSumo Top")
        XCTAssertEqual(reopened.vault.group(child.id)?.parentID, parent.id)

        let content = try XCTUnwrap(Self.content(of: reopened))
        let writtenParent = try XCTUnwrap(Self.group(parent.id, in: content))
        XCTAssertEqual(writtenParent.name, "PassSumo Top")
        XCTAssertEqual(
            writtenParent.groups.map(\.uuid), [child.id],
            "the child has to be nested INSIDE the parent element, not merely reference it"
        )
        XCTAssertNotNil(writtenParent.times?.creationTime, "a group with no times reads as damaged")
    }

    /// Renaming and moving must not be spelled as delete-and-recreate: the group keeps its UUID, so
    /// every other client's reference to it — and a merge with another replica — still resolves.
    func testRenamingAndMovingAFolderKeepsItsUUIDAndStampsTheMove() throws {
        let creds = kdbxCredentials()
        let decoded = try codec.decode(fileData: try fixture("kpxc-rich"), credentials: creds)

        var vault = decoded.vault
        let victim = try XCTUnwrap(vault.groups.first { $0.parentID != nil } ?? vault.groups.first)
        let originalParent = victim.parentID
        vault.groups[try XCTUnwrap(vault.groups.firstIndex { $0.id == victim.id })].name = "Renamed By PassSumo"
        XCTAssertTrue(vault.moveGroup(victim.id, under: nil))

        let saved = try codec.encode(vault, credentials: creds, origin: decoded)
        let reopened = try codec.decode(fileData: saved, credentials: creds)
        let content = try XCTUnwrap(Self.content(of: reopened))

        XCTAssertEqual(reopened.vault.group(victim.id)?.name, "Renamed By PassSumo")
        XCTAssertNil(reopened.vault.group(victim.id)?.parentID)

        let written = try XCTUnwrap(Self.group(victim.id, in: content))
        if originalParent != nil {
            XCTAssertNotNil(written.times?.locationChanged, "Times/LocationChanged must be stamped on a move")
            XCTAssertNotNil(written.previousParentGroup, "PreviousParentGroup is what 'restore' reads")
        }
        XCTAssertFalse(
            content.database.root.deletedObjects.contains { $0.uuid == victim.id },
            "a rename or a move must not look like a deletion to a merge"
        )
    }

    /// Recycling a folder is a move, and emptying the bin afterwards is the deletion — so the
    /// tombstones a two-way merge needs appear at the second step and not before.
    func testRecyclingAFolderWritesNoTombstoneButEmptyingTheBinWritesOneForEveryThingInIt() throws {
        let creds = kdbxCredentials()
        let decoded = try codec.decode(fileData: try fixture("kpxc-rich"), credentials: creds)

        var vault = decoded.vault
        let victim = try XCTUnwrap(vault.groups.first)
        let doomedEntries = vault.entries
            .filter { $0.groupID.map(vault.groupSubtreeIDs(of: victim.id).contains) == true }
            .map(\.id)
        XCTAssertTrue(vault.moveToRecycleBin(groupID: victim.id))

        let recycled = try codec.encode(vault, credentials: creds, origin: decoded)
        let afterRecycle = try codec.decode(fileData: recycled, credentials: creds)
        let recycledContent = try XCTUnwrap(Self.content(of: afterRecycle))
        XCTAssertEqual(afterRecycle.vault.group(victim.id)?.parentID, afterRecycle.vault.recycleBin.groupID)
        XCTAssertFalse(
            recycledContent.database.root.deletedObjects.contains { $0.uuid == victim.id },
            "the folder moved; a tombstone here would tell a merge it was destroyed"
        )

        var emptied = afterRecycle.vault
        emptied.emptyRecycleBin()
        let saved = try codec.encode(emptied, credentials: creds, origin: afterRecycle)
        let reopened = try codec.decode(fileData: saved, credentials: creds)
        let content = try XCTUnwrap(Self.content(of: reopened))

        XCTAssertFalse(reopened.vault.groups.contains { $0.id == victim.id })
        XCTAssertTrue(content.database.root.deletedObjects.contains { $0.uuid == victim.id })
        for entryID in doomedEntries {
            XCTAssertTrue(
                content.database.root.deletedObjects.contains { $0.uuid == entryID },
                "without a tombstone a KDBX merge resurrects the entry from the other replica"
            )
        }
    }
}
