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
        customFields: [String: VaultFieldValue] = [:]
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
        let entry = makeEntry(title: "AWS", customFields: ["Account ID": .plain("482910337201")])
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

    // MARK: - Fixture-data privacy guard

    /// `Vault.sample` ships inside the `PassSumo` app target, not a test target — every
    /// email-shaped string in it is user-visible, in the running app, in SwiftUI previews, and in
    /// the `-ui-testing` seeded fixture the App Store screenshots come from. A real personal email
    /// address was once committed here (see repo root `CLAUDE.md`, "Gotchas worth recording").
    ///
    /// The only domains allowed after an `@` (or its URL-encoded form `%40`) anywhere in
    /// sample/demo/mockup data are the ones RFC 2606 reserves for exactly this purpose — they can
    /// never resolve to, or collide with, a real mailbox. This is deliberately a domain ALLOWLIST,
    /// not a denylist of the specific strings that leaked before: a denylist would have to spell
    /// out the real name/domain it exists to keep out of a source-available repo, which defeats
    /// its own purpose. An allowlist catches any real domain reintroduced later, by anyone, without
    /// ever naming what it is protecting against.
    func testFixtureDataUsesOnlyReservedPlaceholderEmailDomains() throws {
        let allowedDomains: Set<String> = ["example.com", "example.org", "example.net", "example.edu"]
        let emailPattern = try NSRegularExpression(
            pattern: #"[A-Za-z0-9._%+-]+(?:@|%40)([A-Za-z0-9.-]+\.[A-Za-z]{2,})"#
        )

        func checkNoDisallowedDomain(in text: String, source: String, line: UInt = #line) {
            let nsText = text as NSString
            let matches = emailPattern.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            for match in matches {
                let domain = nsText.substring(with: match.range(at: 1)).lowercased()
                XCTAssertTrue(
                    allowedDomains.contains(domain),
                    "\(source) contains an email-shaped string on a non-placeholder domain " +
                        "(\(domain)) — use example.com/example.org (RFC 2606) for fixture/sample/" +
                        "mockup data instead of any real domain",
                    line: line
                )
            }
        }

        // 1. The shipping sample vault itself, as parsed — what the app/previews/screenshots
        //    actually render.
        for entry in Vault.sample.entries {
            checkNoDisallowedDomain(in: entry.username, source: "Vault.sample '\(entry.title)' username")
            if let otp = entry.otpAuthURL {
                checkNoDisallowedDomain(in: otp, source: "Vault.sample '\(entry.title)' otpAuthURL")
            }
            for (key, field) in entry.customFields {
                checkNoDisallowedDomain(in: field.value, source: "Vault.sample '\(entry.title)' field '\(key)'")
            }
        }

        // 2. `PassSumoUITests`' hand-copy of some of those values (`UITestSupport.swift` — it
        //    cannot `@testable import PassSumo`, see its own doc comment) can drift independently.
        // 3. Any HTML mockup under `design/mockups/` — outside `PassSumo/`, but still reference
        //    material for the shipped screens (see `design/README.md`).
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // …/PassSumo/Sources/UnitTests
            .deletingLastPathComponent()  // …/PassSumo/Sources
            .deletingLastPathComponent()  // …/PassSumo
            .deletingLastPathComponent()  // repo root

        let uiTestSupportURL = repoRoot.appendingPathComponent("PassSumo/Sources/UITests/UITestSupport.swift")
        let uiTestSupportText = try XCTUnwrap(
            try? String(contentsOf: uiTestSupportURL, encoding: .utf8),
            "could not read \(uiTestSupportURL.path)"
        )
        checkNoDisallowedDomain(in: uiTestSupportText, source: "UITestSupport.swift")

        let mockupsDir = repoRoot.appendingPathComponent("design/mockups")
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: mockupsDir, includingPropertiesForKeys: nil),
            "could not enumerate \(mockupsDir.path)"
        )
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "html" {
            let text = try XCTUnwrap(
                try? String(contentsOf: fileURL, encoding: .utf8),
                "could not read \(fileURL.path)"
            )
            checkNoDisallowedDomain(in: text, source: fileURL.lastPathComponent)
        }
    }
}
