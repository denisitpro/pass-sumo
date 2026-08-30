import XCTest
@testable import PassSumo

/// Fast, deterministic tests for `Vault`'s pure domain logic — no filesystem, no crypto. Kept
/// separate from `VaultStoreTests` (which does touch a temp directory) so this file stays a
/// sub-millisecond smoke test of the model layer.
final class ModelDomainTests: XCTestCase {
    private func makeEntry(
        id: UUID = UUID(),
        title: String = "",
        username: String = "",
        password: String = "",
        notes: String = "",
        customFields: [String: String] = [:]
    ) -> VaultEntry {
        VaultEntry(
            id: id,
            groupID: nil,
            title: title,
            username: username,
            password: password,
            url: "",
            notes: notes,
            otpAuthURL: nil,
            customFields: customFields,
            created: Date(timeIntervalSince1970: 0),
            modified: Date(timeIntervalSince1970: 0)
        )
    }

    func testSearchFindsMatchInPasswordField() {
        // The whole point of searching the password field (see `Vault.search`'s doc comment) is
        // that a user can find an entry by a password they remember, not just its title/username.
        let entry = makeEntry(title: "Random Site", password: "correct-horse-battery-staple")
        let decoy = makeEntry(title: "Unrelated Site", password: "hunter2")
        let vault = Vault(name: "Test", groups: [], entries: [entry, decoy])

        XCTAssertEqual(vault.search("battery-staple").map(\.id), [entry.id])
        XCTAssertTrue(vault.search("no-such-password").isEmpty)
    }

    func testSearchIsCaseAndDiacriticInsensitive() {
        let entry = makeEntry(title: "Café Résumé")
        let vault = Vault(name: "Test", groups: [], entries: [entry])

        XCTAssertEqual(vault.search("resume").map(\.id), [entry.id])
        XCTAssertEqual(vault.search("RESUME").map(\.id), [entry.id])
        XCTAssertEqual(vault.search("résumé").map(\.id), [entry.id])
    }

    func testSearchMatchesCustomFieldNameAndValue() {
        let entry = makeEntry(title: "AWS", customFields: ["Account ID": "482910337201"])
        let vault = Vault(name: "Test", groups: [], entries: [entry])

        XCTAssertEqual(vault.search("Account ID").map(\.id), [entry.id])
        XCTAssertEqual(vault.search("482910337201").map(\.id), [entry.id])
    }

    func testEmptyQueryReturnsEverything() {
        let vault = Vault.sample
        XCTAssertEqual(vault.search("").count, vault.entries.count)
        XCTAssertFalse(vault.entries.isEmpty, "sanity check: the fixture itself must be non-empty")
    }

    func testSampleDataIsInternallyConsistent() {
        let vault = Vault.sample
        XCTAssertEqual(vault.entries.count, 20)
        XCTAssertEqual(vault.rootGroups.count, 3)

        // A dangling `groupID` would silently orphan an entry from every group-filtered UI list.
        for entry in vault.entries {
            if let groupID = entry.groupID {
                XCTAssertNotNil(vault.group(groupID), "entry '\(entry.title)' references a missing group")
            }
        }
    }

    func testEntriesInGroupFiltersToThatGroupOnly() {
        let vault = Vault.sample
        guard let emailGroup = vault.rootGroups.first(where: { $0.name == "Email" }) else {
            return XCTFail("sample data must include an Email group")
        }
        let emailEntries = vault.entries(inGroup: emailGroup.id)
        XCTAssertFalse(emailEntries.isEmpty)
        XCTAssertTrue(emailEntries.allSatisfy { $0.groupID == emailGroup.id })
        XCTAssertLessThan(emailEntries.count, vault.entries.count)
    }
}
