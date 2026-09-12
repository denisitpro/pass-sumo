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

    private func makeEntry(
        _ id: String,
        group: String?,
        title: String,
        password: String = "",
        passwordLastChanged: Date? = nil
    ) -> VaultEntry {
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
            modified: Date(timeIntervalSince1970: 0),
            passwordLastChanged: passwordLastChanged
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

    // MARK: - GroupTreeBuilder.paths (issue #88)

    func testGroupPathsFollowTheOutlineOrderAndSpellTheFullPath() {
        let root = makeGroup("00000000-0000-0000-0000-000000000001", parent: nil, name: "Work")
        let child = makeGroup("00000000-0000-0000-0000-000000000002", parent: "00000000-0000-0000-0000-000000000001", name: "Clients")
        let sibling = makeGroup("00000000-0000-0000-0000-000000000003", parent: nil, name: "Archive")

        let paths = GroupTreeBuilder.paths(from: [root, child, sibling])

        // Depth-first, siblings sorted by name — the order the sidebar draws, so a flat control
        // built from this reads as the same tree rather than as a differently-ordered list.
        XCTAssertEqual(paths.map(\.path), ["Archive", "Work", "Work / Clients"])
        XCTAssertEqual(paths.map(\.id), [sibling.id, root.id, child.id])
    }

    /// Two folders of the same name in different places are what the path is FOR: as bare names
    /// they would be two identical rows in a picker, and picking one would be a coin toss.
    func testGroupPathsDistinguishSameNamedFoldersInDifferentPlaces() {
        let work = makeGroup("00000000-0000-0000-0000-000000000001", parent: nil, name: "Work")
        let personal = makeGroup("00000000-0000-0000-0000-000000000002", parent: nil, name: "Personal")
        let workArchive = makeGroup("00000000-0000-0000-0000-000000000003", parent: "00000000-0000-0000-0000-000000000001", name: "Archive")
        let personalArchive = makeGroup("00000000-0000-0000-0000-000000000004", parent: "00000000-0000-0000-0000-000000000002", name: "Archive")

        let paths = GroupTreeBuilder.paths(from: [work, personal, workArchive, personalArchive])

        XCTAssertEqual(Set(paths.map(\.path)).count, paths.count, "no two rows may read the same")
        XCTAssertEqual(paths.first { $0.id == workArchive.id }?.path, "Work / Archive")
        XCTAssertEqual(paths.first { $0.id == personalArchive.id }?.path, "Personal / Archive")
    }

    /// Same guarantee the outline gives: a cyclic `parentID` must not cost a group its row, and
    /// must not hang the walk.
    func testGroupPathsListEveryGroupOnceEvenThroughACycle() {
        let a = makeGroup("00000000-0000-0000-0000-0000000000a1", parent: "00000000-0000-0000-0000-0000000000a2", name: "A")
        let b = makeGroup("00000000-0000-0000-0000-0000000000a2", parent: "00000000-0000-0000-0000-0000000000a1", name: "B")

        let paths = GroupTreeBuilder.paths(from: [a, b])

        XCTAssertEqual(Set(paths.map(\.id)), [a.id, b.id])
        XCTAssertEqual(paths.count, 2, "once each, not once per way round the cycle")
    }

    // MARK: - GroupSelection (issue #85)

    /// The defect this type exists to remove: "All Entries" used to be spelled `nil`, which is also
    /// what a macOS `List(selection:)` writes for "nothing is selected", so the two were literally
    /// the same value and the row could not be picked again once a group had been. Being able to
    /// distinguish them is the whole fix, so it is asserted directly rather than inferred from the
    /// filter's output.
    func testAllEntriesIsADistinctValueFromAnEmptySelection() {
        let selected: GroupSelection? = .allEntries
        XCTAssertNotNil(selected)
        XCTAssertNotEqual(selected, GroupSelection?.none)
    }

    func testAllEntriesIsADistinctValueFromEveryGroup() {
        let groupID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        XCTAssertNotEqual(GroupSelection.allEntries, .group(groupID))
        XCTAssertEqual(GroupSelection.group(groupID), .group(groupID))
        XCTAssertNotEqual(
            GroupSelection.group(groupID),
            .group(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        )
    }

    /// `containingGroupID` is where a new entry lands, NOT a filter argument — and its `nil` is
    /// `VaultEntry.groupID`'s "no group, top level", the meaning `EntryListFilter` deliberately
    /// does not use. See `GroupSelection`'s doc comment on the two `nil`s.
    func testContainingGroupIDIsNilForAllEntriesAndTheGroupOtherwise() {
        let groupID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        XCTAssertNil(GroupSelection.allEntries.containingGroupID)
        XCTAssertEqual(GroupSelection.group(groupID).containingGroupID, groupID)
    }

    /// Selecting a group and then coming back to "All Entries" — the exact round trip the owner
    /// could not perform. What the filter returns for the second `.allEntries` must be what it
    /// returned for the first, not what the group filter returned.
    func testSelectingAGroupAndReturningToAllEntriesRestoresTheUnfilteredList() {
        let groupID = UUID(uuidString: "00000000-0000-0000-0000-000000000090")!
        let vault = Vault(
            name: "Test",
            groups: [makeGroup("00000000-0000-0000-0000-000000000090", parent: nil, name: "Email")],
            entries: [
                makeEntry("00000000-0000-0000-0000-000000000091", group: groupID.uuidString, title: "InGroup"),
                makeEntry("00000000-0000-0000-0000-000000000092", group: nil, title: "Ungrouped"),
            ]
        )

        let atStart = EntryListFilter.apply(to: vault, selection: .allEntries, query: "")
        XCTAssertEqual(atStart.map(\.title), ["InGroup", "Ungrouped"], "fixture precondition")

        let inGroup = EntryListFilter.apply(to: vault, selection: .group(groupID), query: "")
        XCTAssertEqual(inGroup.map(\.title), ["InGroup"], "fixture precondition")

        let backToAll = EntryListFilter.apply(to: vault, selection: .allEntries, query: "")
        XCTAssertEqual(backToAll.map(\.title), atStart.map(\.title))
    }

    /// The collision the refactor had to preserve rather than tidy away: "All Entries" shows
    /// everything, whereas `entries(inGroup: nil)` — which is what a `.group` selection would mean
    /// if the two `nil`s had been merged — shows only the entries with no group at all.
    func testAllEntriesIsNotTheSameFilterAsTheTopLevelGroup() {
        let groupID = UUID(uuidString: "00000000-0000-0000-0000-000000000095")!
        let vault = Vault(
            name: "Test",
            groups: [],
            entries: [
                makeEntry("00000000-0000-0000-0000-000000000096", group: groupID.uuidString, title: "InGroup"),
                makeEntry("00000000-0000-0000-0000-000000000097", group: nil, title: "Ungrouped"),
            ]
        )

        XCTAssertEqual(
            EntryListFilter.apply(to: vault, selection: .allEntries, query: "").map(\.title),
            ["InGroup", "Ungrouped"]
        )
        XCTAssertEqual(vault.entries(inGroup: nil).map(\.title), ["Ungrouped"])
    }

    // MARK: - EntryListFilter

    func testEntryListFilterWithNoGroupAndNoQueryReturnsEverything() {
        let vault = Vault(
            name: "Test",
            groups: [],
            entries: [makeEntry("00000000-0000-0000-0000-000000000010", group: nil, title: "Alpha")]
        )
        let result = EntryListFilter.apply(to: vault, selection: .allEntries, query: "")
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
        let result = EntryListFilter.apply(to: vault, selection: .group(groupID), query: "")
        XCTAssertEqual(result.map(\.title), ["InGroup"])
    }

    /// Issue #143: a parent folder with everything in a child used to look empty.
    func testEntryListFilterIncludesDescendantEntries() {
        let parentID = UUID(uuidString: "00000000-0000-0000-0000-000000000040")!
        let childID = UUID(uuidString: "00000000-0000-0000-0000-000000000041")!
        let vault = Vault(
            name: "Test",
            groups: [
                makeGroup("00000000-0000-0000-0000-000000000040", parent: nil, name: "Parent"),
                makeGroup("00000000-0000-0000-0000-000000000041", parent: "00000000-0000-0000-0000-000000000040", name: "Child"),
            ],
            entries: [
                makeEntry("00000000-0000-0000-0000-000000000042", group: "00000000-0000-0000-0000-000000000040", title: "InParent"),
                makeEntry("00000000-0000-0000-0000-000000000043", group: "00000000-0000-0000-0000-000000000041", title: "InChild"),
                makeEntry("00000000-0000-0000-0000-000000000044", group: nil, title: "Ungrouped"),
            ]
        )
        XCTAssertEqual(
            Set(vault.subtreeGroupIDs(of: parentID)),
            Set([parentID, childID])
        )
        XCTAssertEqual(
            Set(EntryListFilter.apply(to: vault, selection: .group(parentID), query: "").map(\.title)),
            Set(["InParent", "InChild"])
        )
        XCTAssertEqual(
            EntryListFilter.apply(to: vault, selection: .group(childID), query: "").map(\.title),
            ["InChild"]
        )
    }

    /// The screenshot that kept issue #143 open after #145: parent `group1` showed 0 while nested
    /// `group2` showed 1. Both walks must agree, the parent badge is 1, and selecting the parent
    /// lists that same entry — asserted at the filter layer because that is what the list column
    /// actually renders.
    func testParentFolderCountEqualsLiveDescendantEntries() {
        let parent = makeGroup("00000000-0000-0000-0000-0000000000b1", parent: nil, name: "group1")
        let child = makeGroup(
            "00000000-0000-0000-0000-0000000000b2",
            parent: "00000000-0000-0000-0000-0000000000b1",
            name: "group2"
        )
        let vault = Vault(
            name: "Test",
            groups: [parent, child],
            entries: [
                makeEntry(
                    "00000000-0000-0000-0000-0000000000b3",
                    group: "00000000-0000-0000-0000-0000000000b2",
                    title: "Nested"
                ),
            ]
        )

        XCTAssertEqual(Set(vault.subtreeGroupIDs(of: parent.id)), [parent.id, child.id])
        XCTAssertEqual(Set(vault.groupSubtreeIDs(of: parent.id)), [parent.id, child.id])
        XCTAssertEqual(vault.entries(inSubtreeOf: parent.id).map(\.title), ["Nested"])
        XCTAssertEqual(vault.entries(inSubtreeOf: child.id).map(\.title), ["Nested"])
        XCTAssertEqual(
            EntryListFilter.apply(to: vault, selection: .group(parent.id), query: "").map(\.title),
            ["Nested"]
        )
        XCTAssertEqual(
            vault.entries(inSubtreeOf: parent.id).count,
            EntryListFilter.apply(to: vault, selection: .group(parent.id), query: "").count,
            "the badge and the list it labels must never disagree"
        )
    }

    /// A live parent must not count recycled descendants even if the bin has been re-homed under
    /// it. Selecting the bin itself still lists them.
    func testParentFolderSubtreeCountExcludesTheRecycleBin() throws {
        let parent = makeGroup("00000000-0000-0000-0000-0000000000c1", parent: nil, name: "group1")
        let child = makeGroup(
            "00000000-0000-0000-0000-0000000000c2",
            parent: "00000000-0000-0000-0000-0000000000c1",
            name: "group2"
        )
        var vault = Vault(
            name: "Test",
            groups: [parent, child],
            entries: [
                makeEntry(
                    "00000000-0000-0000-0000-0000000000c3",
                    group: "00000000-0000-0000-0000-0000000000c2",
                    title: "LiveNested"
                ),
                makeEntry(
                    "00000000-0000-0000-0000-0000000000c4",
                    group: "00000000-0000-0000-0000-0000000000c1",
                    title: "Doomed"
                ),
            ]
        )
        XCTAssertTrue(vault.moveToRecycleBin(entryID: vault.entries[1].id))
        let binID = try XCTUnwrap(vault.recycleBin.groupID)
        XCTAssertTrue(vault.moveGroup(binID, under: parent.id))

        XCTAssertEqual(vault.entries(inSubtreeOf: parent.id).map(\.title), ["LiveNested"])
        XCTAssertEqual(
            EntryListFilter.apply(to: vault, selection: .group(parent.id), query: "").map(\.title),
            ["LiveNested"]
        )
        XCTAssertEqual(
            EntryListFilter.apply(to: vault, selection: .group(binID), query: "").map(\.title),
            ["Doomed"]
        )
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
        let result = EntryListFilter.apply(to: vault, selection: .group(groupID), query: "git")
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
        let result = EntryListFilter.apply(to: vault, selection: .allEntries, query: "sunsetharbor")
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
        let result = EntryListFilter.apply(to: vault, selection: .allEntries, query: "")
        XCTAssertEqual(result.map(\.title), ["Apple", "mango", "zebra"])
    }

    // MARK: - EntryListFilter and issue #34 (search query survives opening an entry)

    /// `EntryListFilter.apply` is a pure function of `(vault, selection, query)` — nothing about
    /// "an entry is currently open for editing" or "an entry was just selected" is part of its
    /// input, which is exactly why `VaultBrowserView.openForEdit`/row selection have no way to
    /// perturb it: there is no shared state between them to perturb. This test pins the query and
    /// the result set across the same edit-and-return round trip the issue describes — saving an
    /// edit runs through `VaultStore.upsert`, which replaces the entry in place and bumps
    /// `modified`, so the fixture mirrors that mutation rather than only re-calling `apply` with
    /// nothing changed at all.
    func testSearchResultSurvivesOpeningAndSavingAnEntryFromWithinTheResults() throws {
        let query = "git"
        var vault = Vault(
            name: "Test",
            groups: [],
            entries: [
                makeEntry("00000000-0000-0000-0000-000000000080", group: nil, title: "GitHub"),
                makeEntry("00000000-0000-0000-0000-000000000081", group: nil, title: "GitLab"),
                makeEntry("00000000-0000-0000-0000-000000000082", group: nil, title: "Unrelated"),
            ]
        )

        let before = EntryListFilter.apply(to: vault, selection: .allEntries, query: query)
        XCTAssertEqual(before.map(\.title), ["GitHub", "GitLab"], "fixture precondition")

        // Simulate "opened GitHub for editing, changed nothing that affects the filter, saved" —
        // the one thing `upsert` unconditionally does even on a no-op edit.
        let openedIndex = try XCTUnwrap(vault.entries.firstIndex { $0.title == "GitHub" })
        vault.entries[openedIndex].modified = Date()

        let after = EntryListFilter.apply(to: vault, selection: .allEntries, query: query)
        XCTAssertEqual(query, "git", "the query itself must never be touched by opening an entry")
        XCTAssertEqual(after.map(\.title), before.map(\.title), "the result set must survive unchanged")
    }

    // MARK: - EntryListFilter and password-change sorting (issue #33)

    func testSortingByPasswordChangedNewestFirstOrdersKnownDatesDescending() {
        let vault = Vault(
            name: "Test",
            groups: [],
            entries: [
                makeEntry("00000000-0000-0000-0000-000000000070", group: nil, title: "Older",
                          passwordLastChanged: Date(timeIntervalSince1970: 100)),
                makeEntry("00000000-0000-0000-0000-000000000071", group: nil, title: "Newer",
                          passwordLastChanged: Date(timeIntervalSince1970: 200)),
            ]
        )
        let result = EntryListFilter.apply(
            to: vault, selection: .allEntries, query: "", sortOrder: .passwordChangedNewestFirst
        )
        XCTAssertEqual(result.map(\.title), ["Newer", "Older"])
    }

    func testSortingByPasswordChangedOldestFirstOrdersKnownDatesAscending() {
        let vault = Vault(
            name: "Test",
            groups: [],
            entries: [
                makeEntry("00000000-0000-0000-0000-000000000072", group: nil, title: "Newer",
                          passwordLastChanged: Date(timeIntervalSince1970: 200)),
                makeEntry("00000000-0000-0000-0000-000000000073", group: nil, title: "Older",
                          passwordLastChanged: Date(timeIntervalSince1970: 100)),
            ]
        )
        let result = EntryListFilter.apply(
            to: vault, selection: .allEntries, query: "", sortOrder: .passwordChangedOldestFirst
        )
        XCTAssertEqual(result.map(\.title), ["Older", "Newer"])
    }

    /// The honest-edge-case requirement from the issue: an entry with no derivable date must not
    /// be silently treated as the oldest (sorting to the bottom of "newest first") or the newest
    /// (sorting to the top of "oldest first") — it goes into its own trailing bucket in BOTH
    /// directions instead, alphabetically ordered since it carries no date to rank it by.
    func testEntriesWithNoDerivableDateFormATrailingUnknownBucketInBothDirections() {
        let vault = Vault(
            name: "Test",
            groups: [],
            entries: [
                makeEntry("00000000-0000-0000-0000-000000000074", group: nil, title: "Zebra Unknown"),
                makeEntry("00000000-0000-0000-0000-000000000075", group: nil, title: "Apple Unknown"),
                makeEntry("00000000-0000-0000-0000-000000000076", group: nil, title: "Known",
                          passwordLastChanged: Date(timeIntervalSince1970: 100)),
            ]
        )
        XCTAssertEqual(
            EntryListFilter.apply(to: vault, selection: .allEntries, query: "", sortOrder: .passwordChangedNewestFirst)
                .map(\.title),
            ["Known", "Apple Unknown", "Zebra Unknown"]
        )
        XCTAssertEqual(
            EntryListFilter.apply(to: vault, selection: .allEntries, query: "", sortOrder: .passwordChangedOldestFirst)
                .map(\.title),
            ["Known", "Apple Unknown", "Zebra Unknown"]
        )
    }

    // MARK: - EntryListFilter and the recycle bin

    /// The bug this exists for: the bin exclusion lived only on the SEARCH path, so with an empty
    /// search field — the default — a recycled entry stayed in the list, in the same alphabetical
    /// position, still selected, with the detail pane unchanged. A delete had no visible effect at
    /// all, which reads as "the keystroke did not register" and invites a second ⌫ — and the second
    /// one is the permanent delete, whose confirmation dialog puts the destructive button first.
    func testEntryListFilterHidesRecycledEntriesFromTheUnfilteredList() {
        var vault = Vault(
            name: "Test",
            groups: [],
            entries: [
                makeEntry("00000000-0000-0000-0000-000000000060", group: nil, title: "Live"),
                makeEntry("00000000-0000-0000-0000-000000000061", group: nil, title: "Deleted"),
            ]
        )
        let recycledID = vault.entries[1].id
        XCTAssertTrue(vault.moveToRecycleBin(entryID: recycledID))

        let result = EntryListFilter.apply(to: vault, selection: .allEntries, query: "")
        XCTAssertEqual(result.map(\.title), ["Live"], "a recycled entry must leave the list")
    }

    /// The sidebar's "All Entries" badge has to agree with the list beside it, or the count is the
    /// one thing on screen that still refuses to move when an entry is deleted.
    func testAllEntriesCountExcludesTheRecycleBin() {
        var vault = Vault(
            name: "Test",
            groups: [],
            entries: [
                makeEntry("00000000-0000-0000-0000-000000000062", group: nil, title: "Live"),
                makeEntry("00000000-0000-0000-0000-000000000063", group: nil, title: "Deleted"),
            ]
        )
        XCTAssertTrue(vault.moveToRecycleBin(entryID: vault.entries[1].id))

        XCTAssertEqual(vault.liveEntries.count, 1, "the count GroupSidebar shows for All Entries")
        XCTAssertEqual(vault.entries.count, 2, "the recycled entry is still IN the vault, just not live")
        XCTAssertEqual(
            vault.liveEntries.count,
            EntryListFilter.apply(to: vault, selection: .allEntries, query: "").count,
            "the badge and the list it labels must never disagree"
        )
    }

    /// Selecting the bin is the one context where its contents must show — otherwise that column
    /// silently returns nothing and the user cannot reach what they deleted.
    func testEntryListFilterShowsTheBinsContentsWhenTheBinIsSelected() throws {
        var vault = Vault(
            name: "Test",
            groups: [],
            entries: [
                makeEntry("00000000-0000-0000-0000-000000000064", group: nil, title: "Live"),
                makeEntry("00000000-0000-0000-0000-000000000065", group: nil, title: "Deleted"),
            ]
        )
        XCTAssertTrue(vault.moveToRecycleBin(entryID: vault.entries[1].id))
        let binID = try XCTUnwrap(vault.recycleBin.groupID)

        XCTAssertEqual(
            EntryListFilter.apply(to: vault, selection: .group(binID), query: "").map(\.title), ["Deleted"]
        )
        XCTAssertEqual(
            EntryListFilter.apply(to: vault, selection: .group(binID), query: "delet").map(\.title), ["Deleted"],
            "searching WITHIN the selected bin must still reach its contents"
        )
    }

    /// A database that never had anything deleted has no bin group, and must behave exactly as it
    /// did before the exclusion existed — nothing hidden, nothing reordered.
    func testEntryListFilterIsUnchangedForADatabaseWithNoRecycleBin() {
        let vault = Vault(
            name: "Test",
            groups: [],
            entries: [
                makeEntry("00000000-0000-0000-0000-000000000066", group: nil, title: "Beta"),
                makeEntry("00000000-0000-0000-0000-000000000067", group: nil, title: "Alpha"),
            ]
        )
        XCTAssertTrue(vault.recycleBinGroupIDs.isEmpty, "fixture precondition: no bin group")
        XCTAssertEqual(
            EntryListFilter.apply(to: vault, selection: .allEntries, query: "").map(\.title),
            ["Alpha", "Beta"]
        )
        XCTAssertEqual(vault.liveEntries.count, 2)
    }

    /// Same for a database whose owner switched the bin off in another client: nothing was ever
    /// moved into a bin, so there is nothing to hide.
    func testEntryListFilterIsUnchangedForADatabaseWithTheBinDisabled() {
        var vault = Vault(
            name: "Test",
            groups: [],
            entries: [makeEntry("00000000-0000-0000-0000-000000000068", group: nil, title: "Only")]
        )
        vault.recycleBin.isEnabled = false
        XCTAssertFalse(vault.moveToRecycleBin(entryID: vault.entries[0].id))

        XCTAssertEqual(EntryListFilter.apply(to: vault, selection: .allEntries, query: "").map(\.title), ["Only"])
        XCTAssertEqual(vault.liveEntries.count, 1)
    }

    /// `VaultBrowserView.requestDelete` decides whether to clear the selection by asking this
    /// filter whether the entry is still visible. That is the feedback the user gets, so the answer
    /// has to be "no" for an ordinary delete and "yes" while the bin itself is on screen.
    func testARecycledEntryStopsBeingVisibleWhichIsWhatClearsTheSelection() throws {
        var vault = Vault(
            name: "Test",
            groups: [],
            entries: [makeEntry("00000000-0000-0000-0000-000000000069", group: nil, title: "Doomed")]
        )
        let id = vault.entries[0].id
        XCTAssertTrue(vault.moveToRecycleBin(entryID: id))
        let binID = try XCTUnwrap(vault.recycleBin.groupID)

        XCTAssertFalse(
            EntryListFilter.apply(to: vault, selection: .allEntries, query: "").contains { $0.id == id },
            "All Entries: the row must go, which is what drops the selection"
        )
        XCTAssertTrue(
            EntryListFilter.apply(to: vault, selection: .group(binID), query: "").contains { $0.id == id },
            "the bin itself: the entry is right there, so the selection follows it"
        )
    }

    // MARK: - AttachmentPreviewPolicy

    /// The allow-list decision, not a formatting one — see the type's doc comment. These cases pin
    /// down that the filename and the bytes must AGREE before any decoder sees the payload.
    func testAttachmentPreviewAllowsAPNGWhoseBytesAgreeWithItsName() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: 0, count: 32))
        XCTAssertTrue(AttachmentPreviewPolicy.allowsPreview(name: "recovery.png", bytes: png))
        XCTAssertTrue(AttachmentPreviewPolicy.allowsPreview(name: "RECOVERY.PNG", bytes: png))
    }

    func testAttachmentPreviewRefusesBytesThatDoNotMatchTheExtension() {
        // A payload renamed to `.png`. Handing this to `NSImage(data:)` is how an unvetted decoder
        // gets reached: it sniffs the bytes itself and ignores the name entirely.
        let notAnImage = Data([0x25, 0x50, 0x44, 0x46, 0x2D] + [UInt8](repeating: 0, count: 32))
        XCTAssertFalse(AttachmentPreviewPolicy.allowsPreview(name: "invoice.png", bytes: notAnImage))
    }

    func testAttachmentPreviewRefusesAFormatOutsideTheAllowList() {
        // A real, valid GIF — refused because GIF is not on the list, not because it is malformed.
        let gif = Data(Array("GIF89a".utf8) + [UInt8](repeating: 0, count: 32))
        XCTAssertFalse(AttachmentPreviewPolicy.allowsPreview(name: "animation.gif", bytes: gif))
    }

    func testAttachmentPreviewRefusesAPayloadOverThePreviewCap() {
        var oversized = Data([0xFF, 0xD8, 0xFF])
        oversized.append(Data(count: AttachmentPreviewPolicy.maximumPreviewByteCount))
        XCTAssertFalse(AttachmentPreviewPolicy.allowsPreview(name: "scan.jpg", bytes: oversized))
    }

    func testAttachmentPreviewRefusesAnExtensionlessPayload() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertFalse(AttachmentPreviewPolicy.allowsPreview(name: "screenshot", bytes: png))
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

    /// The set-valued form used for protected custom fields (issue #65). It must obey the same
    /// rule the single `Bool` does, which is why it delegates — a revealed recovery code is no
    /// less a revealed secret than a revealed password.
    func testRevealPolicyKeepsCustomFieldRevealsForTheSameEntryWhileUnlocked() {
        let id = UUID()
        XCTAssertEqual(
            RevealPolicy.revealsAfterSelectionChange(
                ["Security Answer"], previousEntryID: id, currentEntryID: id, isLocked: false
            ),
            ["Security Answer"]
        )
    }

    func testRevealPolicyClearsCustomFieldRevealsOnSelectionChangeAndOnLock() {
        let id = UUID()
        XCTAssertEqual(
            RevealPolicy.revealsAfterSelectionChange(
                ["Security Answer"], previousEntryID: UUID(), currentEntryID: UUID(), isLocked: false
            ),
            []
        )
        XCTAssertEqual(
            RevealPolicy.revealsAfterSelectionChange(
                ["Security Answer"], previousEntryID: id, currentEntryID: id, isLocked: true
            ),
            []
        )
    }

    // MARK: - GeneratorSheet's optional "Use" (issue #45)

    /// `VaultBrowserView`'s toolbar presentation has no field to fill, so it passes no `onUse` at
    /// all — this is what makes `GeneratorSheet` hide "Use" instead of offering a button that
    /// silently duplicates "Copy", which was the whole reason the owner couldn't tell them apart.
    func testGeneratorSheetHasNoUseActionWhenTheCallerProvidesNone() {
        let sheet = GeneratorSheet(generator: PasswordGenerator(), clipboard: ClipboardService())
        XCTAssertNil(sheet.onUse)
    }

    /// `EntryEditView`'s generator-settings call site has a password field to fill, so it provides
    /// `onUse` — this is what makes "Use" appear there.
    func testGeneratorSheetHasAUseActionWhenTheCallerProvidesOne() {
        let sheet = GeneratorSheet(generator: PasswordGenerator(), clipboard: ClipboardService(), onUse: { _ in })
        XCTAssertNotNil(sheet.onUse)
    }

    func testGeneratorSheetForwardsRecipeChangesWhenTheCallerProvidesACallback() {
        let sheet = GeneratorSheet(
            generator: PasswordGenerator(),
            clipboard: ClipboardService(),
            onRecipeChanged: { _ in }
        )
        XCTAssertNotNil(sheet.onRecipeChanged)
    }

    // MARK: - Generator recipe wiring (issue #106, persist path issue #129)
    //
    // Persisting the recipe (`AppSettings.generatorRecipe` round-tripping through `UserDefaults`)
    // was already covered by `AppShellTests` and passed throughout #106's life — that defect was
    // entirely that neither call site below ever read the saved value back. These tests drive
    // the actual `EntryEditView`/`VaultBrowserView` construction and call its real method, the same
    // "build the real view, call its real method, no rendering" pattern `EntryEditSaveTests.save()`
    // already uses, and assert on `GeneratorSheet.openingRecipe` — the one observable trace the
    // plumbing leaves on a freshly-constructed sheet. If either call site goes back to hardcoding
    // `GeneratorSheet(generator:, clipboard:)` with no `recipe:`, these fail.
    //
    // Issue #129 adds generate-now (fills the field, no sheet) and `onRecipeChanged` so a tweak
    // inside the sheet is no longer one-off. The edit-form tests below cover that seam; the
    // browser's toolbar call site is another lane and still only has to pass `openingRecipe`.

    /// A fresh scratch `UserDefaults` suite per test, removed in a `defer` — never
    /// `UserDefaults.standard`, which is the app's real preferences domain. Mirrors
    /// `AppShellTests`' own private helper of the same shape.
    private func makeScratchSettings() -> (settings: AppSettings, cleanup: () -> Void) {
        let suiteName = "app.passsumo.tests.\(UUID().uuidString)"
        guard let scratch = UserDefaults(suiteName: suiteName) else {
            XCTFail("could not create a scratch UserDefaults suite")
            return (AppSettings(), {})
        }
        return (AppSettings(defaults: scratch), { scratch.removePersistentDomain(forName: suiteName) })
    }

    func testEntryEditViewOpensTheGeneratorWithItsInjectedRecipe() {
        var recipe = PasswordGenerator.Recipe()
        recipe.length = 42
        recipe.symbols = false

        let editor = EntryEditView(
            entry: makeEntry("00000000-0000-0000-0000-0000000000e1", group: nil, title: "Router"),
            isNew: false,
            store: VaultStore(codec: InMemoryVaultCodec(), fileAccess: InMemoryVaultFileAccess()),
            clipboard: ClipboardService(pasteboard: FakePasteboard()),
            generator: PasswordGenerator(),
            generatorRecipe: recipe,
            onSave: { _ in },
            onDismiss: {}
        )

        XCTAssertEqual(editor.makeGeneratorSheet().openingRecipe, recipe)
        XCTAssertNotNil(editor.makeGeneratorSheet().onUse)
        XCTAssertNotNil(
            editor.makeGeneratorSheet().onRecipeChanged,
            "the sheet must be able to write the live recipe back, even if the caller passed no persist callback"
        )
    }

    /// Generate-now uses the recipe handed in, not `Recipe()`'s hardcoded 20, and does not need
    /// SwiftUI to be rendered to do it.
    func testGeneratePasswordNowUsesTheInjectedRecipeLength() {
        var recipe = PasswordGenerator.Recipe()
        recipe.length = 32

        let editor = EntryEditView(
            entry: makeEntry("00000000-0000-0000-0000-0000000000e2", group: nil, title: "Router"),
            isNew: false,
            store: VaultStore(codec: InMemoryVaultCodec(), fileAccess: InMemoryVaultFileAccess()),
            clipboard: ClipboardService(pasteboard: FakePasteboard()),
            generator: PasswordGenerator(),
            generatorRecipe: recipe,
            onSave: { _ in },
            onDismiss: {}
        )

        let generated = editor.generatePasswordNow()
        XCTAssertEqual(generated?.count, 32)
    }

    /// An impossible recipe must not crash and must not pretend to have filled the field.
    func testGeneratePasswordNowReturnsNilForAnImpossibleRecipe() {
        var recipe = PasswordGenerator.Recipe()
        recipe.lowercase = false
        recipe.uppercase = false
        recipe.digits = false
        recipe.symbols = false

        let editor = EntryEditView(
            entry: makeEntry("00000000-0000-0000-0000-0000000000e3", group: nil, title: "Router"),
            isNew: false,
            store: VaultStore(codec: InMemoryVaultCodec(), fileAccess: InMemoryVaultFileAccess()),
            clipboard: ClipboardService(pasteboard: FakePasteboard()),
            generator: PasswordGenerator(),
            generatorRecipe: recipe,
            onSave: { _ in },
            onDismiss: {}
        )

        XCTAssertNil(editor.generatePasswordNow())
    }

    /// The sheet's `onRecipeChanged` is the persist path (issue #129). A caller that hands one in
    /// must actually receive the recipe the sheet reports — that is the only write; this view
    /// never touches `UserDefaults`.
    func testEntryEditViewForwardsGeneratorRecipeChanges() {
        var persisted: PasswordGenerator.Recipe?
        var recipe = PasswordGenerator.Recipe()
        recipe.length = 20

        let editor = EntryEditView(
            entry: makeEntry("00000000-0000-0000-0000-0000000000e4", group: nil, title: "Router"),
            isNew: false,
            store: VaultStore(codec: InMemoryVaultCodec(), fileAccess: InMemoryVaultFileAccess()),
            clipboard: ClipboardService(pasteboard: FakePasteboard()),
            generator: PasswordGenerator(),
            generatorRecipe: recipe,
            onSave: { _ in },
            onDismiss: {},
            onRecipeChanged: { persisted = $0 }
        )

        var updated = recipe
        updated.length = 40
        editor.makeGeneratorSheet().onRecipeChanged?(updated)
        XCTAssertEqual(persisted?.length, 40)
    }

    /// Same regression, at `VaultBrowserView`'s own toolbar call site — the one with no entry-edit
    /// form around it, so it has no field-filling reason to exist and no other way to reach a
    /// `Recipe` except the injected `settings`.
    func testVaultBrowserViewOpensTheGeneratorWithTheSettingsRecipe() {
        var recipe = PasswordGenerator.Recipe()
        recipe.length = 55
        recipe.lowercase = false

        let (settings, cleanup) = makeScratchSettings()
        defer { cleanup() }
        settings.generatorRecipe = recipe

        let browser = VaultBrowserView(
            store: VaultStore(codec: InMemoryVaultCodec(), fileAccess: InMemoryVaultFileAccess()),
            clipboard: ClipboardService(pasteboard: FakePasteboard()),
            generator: PasswordGenerator(),
            // `FakeLockEventSource`, never the real `WorkspaceLockEventSource` default — this
            // controller is an unused constructor dependency here, and registering for real
            // `NSWorkspace` notifications is exactly the side effect `SecurityAutoLockTests`'s own
            // doc comment warns a test must not risk.
            autoLock: AutoLockController(eventSource: FakeLockEventSource(), onLock: {}),
            settings: settings
        )

        let sheet = browser.makeGeneratorSheet()
        XCTAssertEqual(sheet.openingRecipe, recipe)
        XCTAssertNotNil(sheet.onRecipeChanged, "toolbar generator must persist recipe tweaks (#129)")

        var updated = recipe
        updated.length = 40
        sheet.onRecipeChanged?(updated)
        XCTAssertEqual(settings.generatorRecipe.length, 40)
    }
}
