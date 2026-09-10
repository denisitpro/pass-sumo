import XCTest
@testable import PassSumo

/// What `EntryEditView.save()` actually writes back.
///
/// `save()` does not mutate the entry it was opened on — it builds a **new** `VaultEntry` from the
/// fields the form owns. That makes every modelled field the form does not name a silent data-loss
/// candidate: the initialiser's default value applies, nothing warns, and the user's value is gone
/// the next time they fix a typo. `iconID` was exactly that between landing in the model and being
/// threaded through this form (issue #89), and this is the assertion that catches it.
///
/// Deliberately not an XCUITest: the point is what the save path produces, which is answerable
/// in-process, and `make e2e` steals focus and is not run on every change. It does drive a real
/// `EntryEditView` rather than a re-implementation of its logic, because a test that rebuilt the
/// entry itself would agree with itself about which fields exist — which is the whole bug.
@MainActor
final class EntryEditSaveTests: XCTestCase {
    private func makeUnlockedStore(containing entry: VaultEntry) async throws -> VaultStore {
        let codec = InMemoryVaultCodec()
        let fileAccess = InMemoryVaultFileAccess()
        let credentials = VaultCredentials(password: "entry-edit-tests", keyFile: nil)
        let url = URL(fileURLWithPath: "/entry-edit-tests/vault.kdbx")
        let vault = Vault(name: "Edit", groups: [], entries: [entry])
        _ = try fileAccess.write(try codec.encode(vault, credentials: credentials, origin: nil), to: url)
        let store = VaultStore(codec: codec, fileAccess: fileAccess)
        await store.open(url: url, credentials: credentials)
        return store
    }

    private func makeEditor(
        for entry: VaultEntry,
        in store: VaultStore,
        onSave: @escaping (VaultEntry) -> Void
    ) -> EntryEditView {
        EntryEditView(
            entry: entry,
            isNew: false,
            store: store,
            // A fake pasteboard (from `SecuritySupportTests`) even though `save()` never copies
            // anything: the form takes a real `ClipboardService`, and a unit test must not be able
            // to touch the developer's actual clipboard by accident.
            clipboard: ClipboardService(pasteboard: FakePasteboard()),
            generator: PasswordGenerator(),
            onSave: onSave,
            onDismiss: {}
        )
    }

    private func entry(iconID: UInt32) -> VaultEntry {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        return VaultEntry(
            id: UUID(),
            groupID: nil,
            title: "Router",
            username: "admin",
            password: "hunter2",
            url: "https://192.168.1.1",
            notes: "",
            otpAuthURL: nil,
            customFields: [:],
            iconID: iconID,
            created: created,
            modified: created
        )
    }

    /// Editing an entry must not silently re-icon it.
    ///
    /// 3 (`NetworkServer`) is deliberately not `VaultEntry.defaultIconID`, so the bug this guards
    /// against — the form leaving `iconID` to its default — fails here instead of passing by
    /// coincidence. Both what the callback hands back and what landed in the store are checked:
    /// the callback is what the browser re-selects on, the store is what gets encoded to the file.
    ///
    /// `iconID` is now `@State` rather than the `let` it was when this test was written, because
    /// the picker landed and the form owns the value (issue #89). That is why `title` is asserted
    /// alongside it: `title` has always been `@State`, so if reading the seeded value of one out
    /// here ever stopped working, this test would say so instead of quietly passing on a default
    /// that happened to match.
    func testEditingAnEntryPreservesItsBuiltInIcon() async throws {
        let original = entry(iconID: 3)
        let store = try await makeUnlockedStore(containing: original)

        var handedBack: VaultEntry?
        let editor = makeEditor(for: original, in: store) { handedBack = $0 }
        editor.save()

        XCTAssertEqual(handedBack?.iconID, 3, "the edited entry lost its icon on the way out of the form")
        XCTAssertEqual(handedBack?.title, "Router", "the form's seeded @State did not reach save()")
        guard case .unlocked(let vault) = store.state else {
            return XCTFail("store is not unlocked: \(store.state)")
        }
        XCTAssertEqual(
            vault.entries.first { $0.id == original.id }?.iconID, 3,
            "the icon that reaches the file is the store's copy, and it was reset to the default"
        )
    }

    /// The same path with the default icon, so the test above cannot pass merely because something
    /// hardcodes 3, and to pin the other half of the contract: an entry that never had an icon
    /// still comes out with 0 rather than acquiring one.
    func testEditingAnEntryWithoutAnIconLeavesItAtTheDefault() async throws {
        let original = entry(iconID: VaultEntry.defaultIconID)
        let store = try await makeUnlockedStore(containing: original)

        var handedBack: VaultEntry?
        let editor = makeEditor(for: original, in: store) { handedBack = $0 }
        editor.save()

        XCTAssertEqual(handedBack?.iconID, VaultEntry.defaultIconID)
    }
}
