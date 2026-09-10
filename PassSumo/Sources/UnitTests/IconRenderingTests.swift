import XCTest
@testable import PassSumo

/// The rendering half of issue #89: turning a stored `iconID` into the symbol a row draws, and
/// changing a folder's icon through `VaultStore`.
///
/// A sibling of `StandardIconCatalogTests` rather than more of it: that file is about the TABLE —
/// that it has 69 entries and that every name is a real SF Symbol. This one is about what the app
/// does with it, which is a different failure mode. Neither is a test of what any of it looks like;
/// nothing in this suite can be.
@MainActor
final class IconRenderingTests: XCTestCase {
    // MARK: - Fixtures

    private func makeStore(_ vault: Vault) async -> VaultStore {
        let codec = InMemoryVaultCodec()
        let fileAccess = InMemoryVaultFileAccess()
        let credentials = VaultCredentials(password: "icon-rendering-tests", keyFile: nil)
        let url = URL(fileURLWithPath: "/icon-rendering-tests/vault.kdbx")
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

    private func makeEntry(iconID: UInt32) -> VaultEntry {
        VaultEntry(
            id: UUID(),
            groupID: nil,
            title: "Router",
            username: "",
            password: "",
            url: "",
            notes: "",
            otpAuthURL: nil,
            customFields: [:],
            iconID: iconID,
            created: Date(timeIntervalSince1970: 0),
            modified: Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: - Resolution

    /// The owner's question behind this issue — "встроенные иконки, если нет у папки своих" — needs
    /// no invention: "no icon of its own" is already a value in the file, and it is the folder.
    func testAFolderWithNoIconOfItsOwnDrawsAFolder() {
        let group = VaultGroup(id: UUID(), parentID: nil, name: "Work")

        XCTAssertEqual(group.iconID, VaultGroup.defaultIconID, "48 is what the format writes")
        XCTAssertEqual(group.symbolName, "folder")
    }

    /// The same for an entry, whose default is a different index and a different glyph.
    func testAnEntryWithNoIconOfItsOwnDrawsAKey() {
        XCTAssertEqual(VaultEntry.defaultIconID, 0)
        XCTAssertEqual(makeEntry(iconID: VaultEntry.defaultIconID).symbolName, "key")
    }

    /// An icon that WAS chosen is the one drawn — the whole point of the issue, and the assertion
    /// that would fail if either resolver quietly ignored its own item's `iconID`.
    func testAChosenIconIsTheOneDrawn() {
        let group = VaultGroup(id: UUID(), parentID: nil, name: "Servers", iconID: 3)

        XCTAssertEqual(group.symbolName, "server.rack")
        XCTAssertEqual(makeEntry(iconID: 19).symbolName, "envelope")
    }

    /// An index outside 0…68 has to draw SOMETHING, and each kind of item falls back to its own
    /// default rather than to one shared stand-in — a folder from a future KeePass must not turn
    /// into a key.
    ///
    /// Not hypothetical: `IconID` is a 32-bit integer in the format, KeePass has extended the set
    /// before, and whatever the file says is written back untouched.
    func testAnIndexThisBuildCannotDrawFallsBackByKind() {
        let group = VaultGroup(id: UUID(), parentID: nil, name: "From The Future", iconID: 200)

        XCTAssertEqual(group.symbolName, "folder")
        XCTAssertEqual(makeEntry(iconID: .max).symbolName, "key")
    }

    /// The fallback lookup is total. Both real callers pass a `defaultIconID` that is in range, so
    /// this exercises the branch that exists only so a future caller cannot turn a bad integer into
    /// an out-of-bounds crash in a password manager.
    func testTheFallbackLookupNeverSubscriptsPastTheTable() {
        XCTAssertEqual(
            StandardIconCatalog.symbolName(for: .max, fallingBackTo: .max),
            StandardIconCatalog.symbolNames[0]
        )
    }

    // MARK: - The recycle bin, no longer special-cased

    /// `GroupSidebar` used to pick its glyph by identity: `trash` if the row was the bin, `folder`
    /// otherwise. It now reads `VaultGroup.symbolName` for every row, so the bin's appearance
    /// depends on the bin actually carrying icon 43 — which is a fact about the data, checkable
    /// here, rather than a fact about a view, which is not.
    ///
    /// Driven through a real delete so it is the bin the app CREATES that is checked, not one
    /// hand-built in the test with the answer already written into it.
    func testTheRecycleBinDrawsTrashWithoutBeingSpecialCased() async throws {
        let entry = makeEntry(iconID: VaultEntry.defaultIconID)
        let store = await makeStore(Vault(name: "Test", groups: [], entries: [entry]))

        store.delete(entryID: entry.id)

        let vault = try unlockedVault(of: store)
        let binID = try XCTUnwrap(vault.recycleBin.groupID, "the delete should have created a bin")
        let bin = try XCTUnwrap(vault.group(binID))
        XCTAssertEqual(bin.iconID, KDBXRecycleBin.iconID)
        XCTAssertEqual(
            bin.symbolName, "trash",
            "the sidebar drops its `isRecycleBin ? \"trash\" : \"folder\"` special case on the "
                + "strength of this — if the bin stops resolving to trash, it silently becomes an "
                + "ordinary-looking folder full of deleted passwords"
        )
    }

    // MARK: - VaultStore.setGroupIcon

    private func makeStoreWithOneFolder() async -> (store: VaultStore, groupID: UUID) {
        let group = VaultGroup(id: UUID(), parentID: nil, name: "Work")
        let store = await makeStore(Vault(name: "Test", groups: [group], entries: []))
        return (store, group.id)
    }

    func testSettingAFolderIconChangesItAndMarksTheVaultDirty() async throws {
        let (store, groupID) = await makeStoreWithOneFolder()
        XCTAssertFalse(store.isDirty, "precondition")

        store.setGroupIcon(groupID, to: 37)

        XCTAssertEqual(try unlockedVault(of: store).group(groupID)?.iconID, 37)
        XCTAssertTrue(store.isDirty)
    }

    /// Re-picking the icon a folder already wears must not manufacture a save — the same rule
    /// `renameGroup` follows, and for the same reason: the user would be left with an
    /// unsaved-changes flag and nothing to write.
    func testPickingTheIconAlreadyInEffectIsNotAnEdit() async throws {
        let (store, groupID) = await makeStoreWithOneFolder()

        store.setGroupIcon(groupID, to: VaultGroup.defaultIconID)

        XCTAssertFalse(store.isDirty)
    }

    func testSettingTheIconOfAFolderThatIsNotThereDoesNothing() async throws {
        let (store, _) = await makeStoreWithOneFolder()

        store.setGroupIcon(UUID(), to: 37)

        XCTAssertFalse(store.isDirty)
    }

    /// Every mutator on the store is a no-op while locked; this one is no exception. The picker
    /// sheet can be open when auto-lock fires, and a write that appeared to succeed against a
    /// locked store is the failure mode `EntryEditView`'s banner exists for.
    func testSettingAFolderIconDoesNothingWhileLocked() async throws {
        let (store, groupID) = await makeStoreWithOneFolder()
        store.lock()

        store.setGroupIcon(groupID, to: 37)

        XCTAssertFalse(store.isDirty)
    }

    /// An index outside KeePass's set is accepted rather than refused. This app's picker can only
    /// ever offer the 69 it can draw, so nothing reaches here with a stranger value today — but the
    /// setter is not the place to enforce it, and the value round-trips to the file either way.
    func testAnIndexOutsideTheStandardSetIsStoredRatherThanRefused() async throws {
        let (store, groupID) = await makeStoreWithOneFolder()

        store.setGroupIcon(groupID, to: 200)

        XCTAssertEqual(try unlockedVault(of: store).group(groupID)?.iconID, 200)
    }
}
