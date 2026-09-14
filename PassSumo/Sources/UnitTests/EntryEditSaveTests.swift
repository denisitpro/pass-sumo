import XCTest
@testable import PassSumo

/// What `EntryEditView.save()` actually writes back.
///
/// `save()` copies the entry it was opened on and assigns only the fields the form owns (issue
/// #95). The previous shape — building a **new** `VaultEntry` from those fields — made every
/// modelled field the form did not name a silent data-loss candidate: the initialiser's default
/// applied, nothing warned, and the user's value was gone the next time they fixed a typo.
/// `iconID` was exactly that between landing in the model and being threaded through this form
/// (issue #89). These assertions go through `save()` itself so a regression cannot hide behind a
/// reimplementation that agrees with itself about which fields exist.
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
        isNew: Bool = false,
        onSave: @escaping (VaultEntry) -> Void,
        onDismiss: @escaping () -> Void = {}
    ) -> EntryEditView {
        EntryEditView(
            entry: entry,
            isNew: isNew,
            store: store,
            // A fake pasteboard (from `SecuritySupportTests`) even though `save()` never copies
            // anything: the form takes a real `ClipboardService`, and a unit test must not be able
            // to touch the developer's actual clipboard by accident.
            clipboard: ClipboardService(pasteboard: FakePasteboard()),
            generator: PasswordGenerator(),
            generatorRecipe: PasswordGenerator.Recipe(),
            // `FakeLockEventSource` so constructing the form cannot register for real
            // `NSWorkspace` notifications; nothing here drives the idle clock.
            autoLock: AutoLockController(eventSource: FakeLockEventSource(), onLock: { _ in }),
            onSave: onSave,
            onDismiss: onDismiss
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

    /// A modelled field the form does not name must ride through `save()` unchanged.
    ///
    /// `passwordLastChanged` is derived at decode time and is not a control on this form — the
    /// previous `VaultEntry(...)` rebuild dropped it on the floor because the initialiser
    /// defaults it to `nil`. Copy-then-assign (issue #95) is what makes a field nobody has
    /// added a control for yet survive the same way.
    func testSavePreservesFieldsTheFormDoesNotOwn() async throws {
        var original = entry(iconID: 3)
        original.passwordLastChanged = Date(timeIntervalSince1970: 1_600_000_000)
        let store = try await makeUnlockedStore(containing: original)

        var handedBack: VaultEntry?
        let editor = makeEditor(for: original, in: store) { handedBack = $0 }
        editor.save()

        XCTAssertEqual(
            handedBack?.passwordLastChanged, original.passwordLastChanged,
            "a field the form does not edit was reset because save() rebuilt the entry"
        )
        XCTAssertEqual(handedBack?.id, original.id)
        XCTAssertEqual(handedBack?.created, original.created)
        XCTAssertEqual(handedBack?.iconID, 3)
        XCTAssertEqual(handedBack?.title, "Router")
    }

    /// Issue #148: a colliding title stays on the sheet. `upsert` owns the rule; this is the
    /// form's half — no `onSave`, no dismiss, vault unchanged.
    func testSaveRefusesADuplicateTitleAndDoesNotDismiss() async throws {
        let existing = entry(iconID: 3)
        let store = try await makeUnlockedStore(containing: existing)

        var colliding = existing
        colliding.id = UUID()

        var saved = false
        var dismissed = false
        let editor = makeEditor(
            for: colliding,
            in: store,
            isNew: true,
            onSave: { _ in saved = true },
            onDismiss: { dismissed = true }
        )

        XCTAssertEqual(editor.save(), .duplicateTitle)
        XCTAssertFalse(saved)
        XCTAssertFalse(dismissed)
        guard case .unlocked(let vault) = store.state else {
            return XCTFail("store is not unlocked: \(store.state)")
        }
        XCTAssertEqual(vault.entries.map(\.id), [existing.id])
    }

    func testSaveRefusesAnEmptyTitleAndDoesNotDismiss() async throws {
        let existing = entry(iconID: 3)
        let store = try await makeUnlockedStore(containing: existing)

        var blank = existing
        blank.id = UUID()
        blank.title = ""

        var saved = false
        var dismissed = false
        let editor = makeEditor(
            for: blank,
            in: store,
            isNew: true,
            onSave: { _ in saved = true },
            onDismiss: { dismissed = true }
        )

        XCTAssertEqual(editor.save(), .emptyTitle)
        XCTAssertFalse(saved)
        XCTAssertFalse(dismissed)
        guard case .unlocked(let vault) = store.state else {
            return XCTFail("store is not unlocked: \(store.state)")
        }
        XCTAssertEqual(vault.entries.count, 1)
    }

    // MARK: - Issue #174: TOTP validated before it can reach `upsert`

    /// Garbage TOTP text used to be written through verbatim (audit M3) — full validation existed
    /// but ran only at display time (`TOTPView`), so this surfaced later as "Invalid one-time
    /// code" instead of being caught here, at the point the user typed it.
    ///
    /// `@` is outside the base32 alphabet in every case, so `Base32.decode` fails on the very
    /// first character regardless of what follows — this does not depend on the rest of the
    /// string being "totp-shaped" at all.
    func testSaveRefusesAnInvalidTOTPAndDoesNotDismiss() async throws {
        let original = entry(iconID: 3)
        let store = try await makeUnlockedStore(containing: original)

        var invalid = original
        invalid.otpAuthURL = "@@not-a-valid-secret@@"

        var saved = false
        var dismissed = false
        let editor = makeEditor(
            for: invalid,
            in: store,
            onSave: { _ in saved = true },
            onDismiss: { dismissed = true }
        )

        XCTAssertNil(editor.save(), "no store-side EntryUpsertError — the save never reached the store")
        XCTAssertFalse(saved)
        XCTAssertFalse(dismissed)
        guard case .unlocked(let vault) = store.state else {
            return XCTFail("store is not unlocked: \(store.state)")
        }
        XCTAssertNil(vault.entries.first?.otpAuthURL, "the store's copy must be untouched")
    }

    /// The normal case: a full KeePassXC-style `otpauth://totp/...` URI must still save. Verifies
    /// the fix does not overcorrect into refusing what already worked.
    func testSaveAcceptsAValidOTPAuthURI() async throws {
        let original = entry(iconID: 3)
        let store = try await makeUnlockedStore(containing: original)

        var updated = original
        updated.otpAuthURL = "otpauth://totp/Example:alice@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Example"

        var handedBack: VaultEntry?
        var dismissed = false
        let editor = makeEditor(
            for: updated,
            in: store,
            onSave: { handedBack = $0 },
            onDismiss: { dismissed = true }
        )

        XCTAssertNil(editor.save())
        XCTAssertTrue(dismissed)
        XCTAssertEqual(handedBack?.otpAuthURL, updated.otpAuthURL)
    }

    /// The older, wrapper-less convention (issue #174's acceptance criteria call this out by
    /// name): a bare base32 secret with no `otpauth://` scheme must still save, exactly the
    /// fallback path `TOTPGenerator(parsing:)` already documents.
    func testSaveAcceptsABareBase32TOTPSecret() async throws {
        let original = entry(iconID: 3)
        let store = try await makeUnlockedStore(containing: original)

        var updated = original
        updated.otpAuthURL = "JBSWY3DPEHPK3PXP"

        var handedBack: VaultEntry?
        let editor = makeEditor(for: updated, in: store, onSave: { handedBack = $0 })

        XCTAssertNil(editor.save())
        XCTAssertEqual(handedBack?.otpAuthURL, "JBSWY3DPEHPK3PXP")
    }

    // MARK: - Issue #174: custom-field names validated before they can reach `upsert`

    /// A reserved name (audit M4) is refused rather than silently dropped. Reachable end-to-end
    /// because `VaultEntry.customFields` is a dictionary, so a single reserved key fits in it —
    /// unlike the duplicate case below, which cannot be reproduced this way (see
    /// `CustomFieldNameError`'s own doc comment).
    func testSaveRefusesAReservedCustomFieldNameAndDoesNotDismiss() async throws {
        let original = entry(iconID: 3)
        let store = try await makeUnlockedStore(containing: original)

        var invalid = original
        invalid.customFields = ["Password": .plain("shadow-password")]

        var saved = false
        var dismissed = false
        let editor = makeEditor(
            for: invalid,
            in: store,
            onSave: { _ in saved = true },
            onDismiss: { dismissed = true }
        )

        XCTAssertNil(editor.save())
        XCTAssertFalse(saved)
        XCTAssertFalse(dismissed)
        guard case .unlocked(let vault) = store.state else {
            return XCTFail("store is not unlocked: \(store.state)")
        }
        XCTAssertEqual(vault.entries.first?.customFields, [:], "the store's copy must be untouched")
    }

    /// `EntryEditView.customFieldNameError(for:)` driven directly, not through `save()`: a real
    /// `EntryEditView` is always seeded from `entry.customFields`, a `[String: VaultFieldValue]`
    /// dictionary that cannot hold two drafts sharing a name, so the `.duplicate` case can only be
    /// reproduced by calling the pure check itself. This is the seam `CustomFieldNameError`'s doc
    /// comment describes, not a production back door — the function is the same one `save()` calls.
    func testCustomFieldNameErrorFlagsAReservedNameAndADuplicate() {
        XCTAssertEqual(EntryEditView.customFieldNameError(for: ["Notes"]), .reserved("Notes"))
        XCTAssertEqual(EntryEditView.customFieldNameError(for: ["otp"]), .reserved("otp"))
        XCTAssertEqual(
            EntryEditView.customFieldNameError(for: ["Recovery Code", "Recovery Code"]),
            .duplicate("Recovery Code")
        )
        XCTAssertNil(
            EntryEditView.customFieldNameError(for: ["", "", "Recovery Code"]),
            "blank names (an unnamed \"Add Field\" row) never collide with each other or with a reserved word"
        )
    }
}
