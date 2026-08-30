import XCTest
@testable import PassSumo

/// Pure-logic tests for `Sources/UI`'s helpers — no view driving, no XCUITest. Each of these is a
/// free function specifically so it's testable this way; see the doc comment on each type under
/// test for why the behavior being checked matters.
@MainActor
final class BrowserLogicTests: XCTestCase {
    // MARK: - Fixtures

    private func makeGroup(_ id: String, parent: String?, name: String) -> VaultGroup {
        VaultGroup(
            id: UUID(uuidString: id)!,
            parentID: parent.map { UUID(uuidString: $0)! },
            name: name
        )
    }

    private func makeEntry(_ id: String, group: String?, title: String, password: String = "") -> VaultEntry {
        VaultEntry(
            id: UUID(uuidString: id)!,
            groupID: group.map { UUID(uuidString: $0)! },
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

    /// Every group id present anywhere in the forest, recursively — used to assert "nothing got
    /// dropped" without caring about the tree's exact shape.
    private func flattenIDs(_ nodes: [GroupTreeNode]) -> Set<UUID> {
        var result: Set<UUID> = []
        for node in nodes {
            result.insert(node.id)
            result.formUnion(flattenIDs(node.children ?? []))
        }
        return result
    }

    // MARK: - GroupTreeBuilder

    func testGroupTreeBuilderNestsMultipleLevels() {
        let root = makeGroup("00000000-0000-0000-0000-000000000001", parent: nil, name: "Root")
        let child = makeGroup("00000000-0000-0000-0000-000000000002", parent: "00000000-0000-0000-0000-000000000001", name: "Child")
        let grandchild = makeGroup("00000000-0000-0000-0000-000000000003", parent: "00000000-0000-0000-0000-000000000002", name: "Grandchild")

        let nodes = GroupTreeBuilder.build(from: [root, child, grandchild])

        XCTAssertEqual(nodes.count, 1, "only Root has no parent, so it's the only top-level node")
        XCTAssertEqual(nodes[0].id, root.id)
        XCTAssertEqual(nodes[0].children?.count, 1)
        XCTAssertEqual(nodes[0].children?[0].id, child.id)
        XCTAssertEqual(nodes[0].children?[0].children?[0].id, grandchild.id)
        XCTAssertEqual(flattenIDs(nodes), [root.id, child.id, grandchild.id])
    }

    func testGroupTreeBuilderPromotesOrphanedParentIDToRoot() {
        // `parent` points at a UUID that isn't any group in this vault at all — the exact shape a
        // dangling `parentID` takes after another KDBX client deletes a group.
        let orphan = makeGroup(
            "00000000-0000-0000-0000-000000000004",
            parent: "ffffffff-ffff-ffff-ffff-ffffffffffff",
            name: "Orphan"
        )

        let nodes = GroupTreeBuilder.build(from: [orphan])

        XCTAssertEqual(nodes.count, 1, "a dangling parentID must not make the group vanish")
        XCTAssertEqual(nodes[0].id, orphan.id)
        XCTAssertNil(nodes[0].children)
    }

    func testGroupTreeBuilderDoesNotDropOrLoopOnASelfParent() {
        let selfParented = makeGroup(
            "00000000-0000-0000-0000-000000000005",
            parent: "00000000-0000-0000-0000-000000000005",
            name: "Weird"
        )

        // The real assertion here is "this returns at all" — a naive implementation recurses
        // forever on a group that is its own parent.
        let nodes = GroupTreeBuilder.build(from: [selfParented])

        XCTAssertEqual(flattenIDs(nodes), [selfParented.id])
    }

    func testGroupTreeBuilderBreaksATwoGroupCycleWithoutDroppingEither() {
        // A -> parent B, B -> parent A: neither one is a "true" root, so both would vanish from a
        // naive root/child split. Every group must still appear exactly once in the forest.
        let a = makeGroup("00000000-0000-0000-0000-0000000000a1", parent: "00000000-0000-0000-0000-0000000000a2", name: "A")
        let b = makeGroup("00000000-0000-0000-0000-0000000000a2", parent: "00000000-0000-0000-0000-0000000000a1", name: "B")

        let nodes = GroupTreeBuilder.build(from: [a, b])

        XCTAssertEqual(flattenIDs(nodes), [a.id, b.id])
        // Not asserting which of A/B ends up as the "root" — that's an implementation detail of
        // how the cycle gets broken, not a contract worth pinning down.
        XCTAssertEqual(nodes.count, 1, "the cycle must resolve to one root with one child, not two duplicate roots")
    }

    func testGroupTreeBuilderSortsSiblingsByName() {
        let zebra = makeGroup("00000000-0000-0000-0000-00000000000a", parent: nil, name: "Zebra")
        let apple = makeGroup("00000000-0000-0000-0000-00000000000b", parent: nil, name: "Apple")

        let nodes = GroupTreeBuilder.build(from: [zebra, apple])

        XCTAssertEqual(nodes.map(\.group.name), ["Apple", "Zebra"])
    }

    // MARK: - EntryListFilter

    func testEntryListFilterWithNoGroupAndNoQueryReturnsEverything() {
        let vault = Vault(
            name: "Test",
            groups: [],
            entries: [makeEntry("00000000-0000-0000-0000-000000000010", group: nil, title: "Alpha")]
        )
        let result = EntryListFilter.apply(to: vault, groupID: nil, query: "")
        XCTAssertEqual(result.map(\.title), ["Alpha"])
    }

    func testEntryListFilterByGroupOnlyShowsThatGroupsEntries() {
        let groupID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        let vault = Vault(
            name: "Test",
            groups: [],
            entries: [
                makeEntry("00000000-0000-0000-0000-000000000021", group: groupID.uuidString, title: "InGroup"),
                makeEntry("00000000-0000-0000-0000-000000000022", group: nil, title: "OutsideGroup"),
            ]
        )
        let result = EntryListFilter.apply(to: vault, groupID: groupID, query: "")
        XCTAssertEqual(result.map(\.title), ["InGroup"])
    }

    func testEntryListFilterCombinesGroupAndSearchAsAnIntersection() {
        let groupID = UUID(uuidString: "00000000-0000-0000-0000-000000000030")!
        let otherGroupID = UUID(uuidString: "00000000-0000-0000-0000-000000000031")!
        let vault = Vault(
            name: "Test",
            groups: [],
            entries: [
                makeEntry("00000000-0000-0000-0000-000000000032", group: groupID.uuidString, title: "GitHub"),
                makeEntry("00000000-0000-0000-0000-000000000033", group: groupID.uuidString, title: "GitLab"),
                // Matches the query but is in the OTHER group — must be excluded by the filter.
                makeEntry("00000000-0000-0000-0000-000000000034", group: otherGroupID.uuidString, title: "GitHub Actions"),
            ]
        )
        let result = EntryListFilter.apply(to: vault, groupID: groupID, query: "git")
        XCTAssertEqual(Set(result.map(\.title)), ["GitHub", "GitLab"])
    }

    func testEntryListFilterSearchesThePasswordField() {
        // The differentiator called out in `Domain.swift`'s `Vault.search` doc comment — verified
        // here too since `EntryListFilter` is what the actual list screen calls.
        let vault = Vault(
            name: "Test",
            groups: [],
            entries: [makeEntry("00000000-0000-0000-0000-000000000040", group: nil, title: "Anything", password: "sunsetHarbor88")]
        )
        let result = EntryListFilter.apply(to: vault, groupID: nil, query: "sunsetharbor")
        XCTAssertEqual(result.map(\.title), ["Anything"])
    }

    func testEntryListFilterSortsAlphabeticallyByTitleCaseInsensitively() {
        let vault = Vault(
            name: "Test",
            groups: [],
            entries: [
                makeEntry("00000000-0000-0000-0000-000000000050", group: nil, title: "zebra"),
                makeEntry("00000000-0000-0000-0000-000000000051", group: nil, title: "Apple"),
                makeEntry("00000000-0000-0000-0000-000000000052", group: nil, title: "mango"),
            ]
        )
        let result = EntryListFilter.apply(to: vault, groupID: nil, query: "")
        XCTAssertEqual(result.map(\.title), ["Apple", "mango", "zebra"])
    }

    // MARK: - TOTPView.grouped

    func testTOTPGroupingSplitsSixDigitsInHalf() {
        XCTAssertEqual(TOTPView.grouped("123456"), "123 456")
    }

    func testTOTPGroupingSplitsEightDigitsInHalf() {
        XCTAssertEqual(TOTPView.grouped("12345678"), "1234 5678")
    }

    func testTOTPGroupingHandlesTheRareSevenDigitCase() {
        XCTAssertEqual(TOTPView.grouped("1234567"), "1234 567")
    }

    func testTOTPGroupingLeavesShortCodesAlone() {
        XCTAssertEqual(TOTPView.grouped("123"), "123")
    }

    // MARK: - RevealPolicy

    func testRevealPolicyKeepsRevealedForTheSameEntryWhileUnlocked() {
        let id = UUID()
        XCTAssertTrue(RevealPolicy.revealAfterSelectionChange(
            wasRevealed: true, previousEntryID: id, currentEntryID: id, isLocked: false
        ))
    }

    func testRevealPolicyResetsWhenTheSelectionChanges() {
        XCTAssertFalse(RevealPolicy.revealAfterSelectionChange(
            wasRevealed: true, previousEntryID: UUID(), currentEntryID: UUID(), isLocked: false
        ))
    }

    func testRevealPolicyResetsWhenTheVaultLocksEvenForTheSameEntry() {
        let id = UUID()
        XCTAssertFalse(RevealPolicy.revealAfterSelectionChange(
            wasRevealed: true, previousEntryID: id, currentEntryID: id, isLocked: true
        ))
    }

    func testRevealPolicyStaysFalseIfItWasNeverRevealed() {
        let id = UUID()
        XCTAssertFalse(RevealPolicy.revealAfterSelectionChange(
            wasRevealed: false, previousEntryID: id, currentEntryID: id, isLocked: false
        ))
    }
}
