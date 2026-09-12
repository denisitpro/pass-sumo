import XCTest
@testable import PassSumo

/// Issue #148: live entry titles must be unique within a database.
///
/// KeePass itself does not require this, so a file another client wrote may already contain
/// collisions. Opening those files must still work and must not rewrite titles; we only refuse
/// to SAVE a colliding (or empty) title of our own. Enforced in `VaultStore.upsert`.
@MainActor
final class EntryTitleUniquenessTests: XCTestCase {
    private func makeEntry(
        id: UUID = UUID(),
        title: String,
        groupID: UUID? = nil,
        username: String = ""
    ) -> VaultEntry {
        VaultEntry(
            id: id,
            groupID: groupID,
            title: title,
            username: username,
            password: "",
            url: "",
            notes: "",
            otpAuthURL: nil,
            customFields: [:],
            created: Date(timeIntervalSince1970: 0),
            modified: Date(timeIntervalSince1970: 0)
        )
    }

    private func makeStore(entries: [VaultEntry] = [], groups: [VaultGroup] = []) async -> VaultStore {
        let codec = InMemoryVaultCodec()
        let fileAccess = InMemoryVaultFileAccess()
        let credentials = VaultCredentials(password: "title-uniqueness-tests", keyFile: nil)
        let url = URL(fileURLWithPath: "/title-uniqueness-tests/\(UUID().uuidString).kdbx")
        let vault = Vault(name: "Titles", groups: groups, entries: entries)
        _ = try! fileAccess.write(try! codec.encode(vault, credentials: credentials, origin: nil), to: url)
        let store = VaultStore(codec: codec, fileAccess: fileAccess)
        await store.open(url: url, credentials: credentials)
        return store
    }

    private struct VaultIsLocked: Error {}

    private func unlockedVault(of store: VaultStore) throws -> Vault {
        guard case .unlocked(let vault) = store.state else { throw VaultIsLocked() }
        return vault
    }

    // MARK: - Collide / unique

    func testUpsertRefusesACollidingLiveTitle() async throws {
        let store = await makeStore()
        XCTAssertNil(store.upsert(makeEntry(title: "Bank")))

        let refused = store.upsert(makeEntry(title: "Bank"))
        XCTAssertEqual(refused, .duplicateTitle)

        let vault = try unlockedVault(of: store)
        XCTAssertEqual(vault.entries.map(\.title), ["Bank"], "the colliding insert must not land")
    }

    func testUpsertAcceptsDistinctTitles() async throws {
        let store = await makeStore()
        XCTAssertNil(store.upsert(makeEntry(title: "Bank")))
        XCTAssertNil(store.upsert(makeEntry(title: "PayPal")))

        let vault = try unlockedVault(of: store)
        XCTAssertEqual(Set(vault.entries.map(\.title)), ["Bank", "PayPal"])
    }

    func testCollisionIsCaseInsensitiveAndTrimmed() async throws {
        let store = await makeStore()
        XCTAssertNil(store.upsert(makeEntry(title: "Bank")))

        XCTAssertEqual(store.upsert(makeEntry(title: "bank")), .duplicateTitle)
        XCTAssertEqual(store.upsert(makeEntry(title: "BANK")), .duplicateTitle)
        XCTAssertEqual(store.upsert(makeEntry(title: " Bank ")), .duplicateTitle)
        XCTAssertEqual(try unlockedVault(of: store).entries.count, 1)
    }

    func testEmptyAndWhitespaceTitlesAreRefused() async throws {
        let store = await makeStore()
        XCTAssertEqual(store.upsert(makeEntry(title: "")), .emptyTitle)
        XCTAssertEqual(store.upsert(makeEntry(title: "   ")), .emptyTitle)
        XCTAssertEqual(store.upsert(makeEntry(title: "\n\t")), .emptyTitle)
        XCTAssertTrue(try unlockedVault(of: store).entries.isEmpty)
        XCTAssertFalse(store.isDirty, "a refused upsert must not mark the vault dirty")
    }

    // MARK: - Self-edit

    func testEditingAnEntryWithoutChangingItsTitleSucceeds() async throws {
        let store = await makeStore()
        let entry = makeEntry(title: "Bank")
        XCTAssertNil(store.upsert(entry))

        var edited = entry
        edited.username = "teller"
        XCTAssertNil(store.upsert(edited))

        let vault = try unlockedVault(of: store)
        XCTAssertEqual(vault.entries.count, 1)
        XCTAssertEqual(vault.entries[0].username, "teller")
    }

    func testImportedDuplicateMayBeSavedIfItsTitleIsUnchanged() async throws {
        let first = makeEntry(title: "Untitled", username: "one")
        let second = makeEntry(title: "Untitled", username: "two")
        let store = await makeStore(entries: [first, second])

        var edited = first
        edited.username = "one-renamed"
        XCTAssertNil(store.upsert(edited), "an imported duplicate must still be editable")

        let vault = try unlockedVault(of: store)
        XCTAssertEqual(vault.entries.map(\.title), ["Untitled", "Untitled"])
        XCTAssertEqual(
            vault.entries.first { $0.id == first.id }?.username, "one-renamed"
        )
    }

    func testChangingAnImportedDuplicateOntoAnotherCollisionIsRefused() async throws {
        let untitled = makeEntry(title: "Untitled")
        let otherUntitled = makeEntry(title: "Untitled")
        let paypal = makeEntry(title: "PayPal")
        let store = await makeStore(entries: [untitled, otherUntitled, paypal])

        var edited = untitled
        edited.title = "PayPal"
        XCTAssertEqual(store.upsert(edited), .duplicateTitle)

        let vault = try unlockedVault(of: store)
        XCTAssertEqual(
            vault.entries.first { $0.id == untitled.id }?.title, "Untitled",
            "a refused rename must leave the imported title in place"
        )
    }

    // MARK: - Recycle bin

    func testANamesakeInTheRecycleBinDoesNotBlockALiveSave() async throws {
        let store = await makeStore()
        let recycled = makeEntry(title: "Bank")
        XCTAssertNil(store.upsert(recycled))
        store.delete(entryID: recycled.id)
        XCTAssertTrue(
            try unlockedVault(of: store).isInRecycleBin(try XCTUnwrap(
                try unlockedVault(of: store).entries.first { $0.id == recycled.id }
            ))
        )

        XCTAssertNil(store.upsert(makeEntry(title: "Bank")), "a binned namesake is allowed")
        let vault = try unlockedVault(of: store)
        XCTAssertEqual(vault.liveEntries.filter { $0.title == "Bank" }.count, 1)
        XCTAssertEqual(vault.entries.filter { $0.title == "Bank" }.count, 2)
    }

    // MARK: - Open does not rewrite

    func testImportedDuplicatesStillDecodeAndAreNotRewrittenOnUnlock() async throws {
        let first = makeEntry(title: "Untitled")
        let second = makeEntry(title: "Untitled")
        let store = await makeStore(entries: [first, second])

        XCTAssertFalse(store.isDirty, "opening duplicates must not rewrite the vault")
        let vault = try unlockedVault(of: store)
        XCTAssertEqual(vault.entries.count, 2)
        XCTAssertEqual(vault.entries.map(\.title), ["Untitled", "Untitled"])
        XCTAssertEqual(vault.entries.map(\.id), [first.id, second.id])
    }

    /// The same invariant through the real codec: a KDBX file that already contains two live
    /// entries with the same title must decode, and the titles must come back unchanged.
    func testImportedDuplicatesStillDecodeThroughKDBXKitCodec() throws {
        let codec = KDBXKitCodec()
        let credentials = VaultCredentials(password: "dup-title-kdbx", keyFile: nil)
        var decoded = try codec.makeEmpty(name: "Duplicates", credentials: credentials)
        let first = makeEntry(title: "Untitled")
        let second = makeEntry(title: "Untitled")
        decoded.vault.entries = [first, second]

        let bytes = try codec.encode(decoded.vault, credentials: credentials, origin: decoded)
        let reopened = try codec.decode(fileData: bytes, credentials: credentials)

        XCTAssertEqual(reopened.vault.entries.map(\.title), ["Untitled", "Untitled"])
        XCTAssertEqual(Set(reopened.vault.entries.map(\.id)), [first.id, second.id])
    }
}
