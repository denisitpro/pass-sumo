import SwiftUI

/// One node of the group outline built from `Vault.groups`' flat `parentID` list. `Vault` stores
/// groups flat, not as a nested tree (see `VaultGroup`'s doc comment in `Domain.swift`) precisely
/// so a presentation layer rebuilds whatever shape it needs — this is the sidebar's shape.
struct GroupTreeNode: Identifiable, Equatable {
    let group: VaultGroup
    /// `nil`, not empty, for a leaf — matches `OutlineGroup`'s own idiom for "no disclosure
    /// triangle", rather than every leaf carrying an allocated-but-unused empty array.
    var children: [GroupTreeNode]?
    var id: UUID { group.id }
}

/// Builds `Vault.groups`' flat, `parentID`-linked list into the tree `GroupSidebar` walks with
/// `OutlineGroup`. Pulled out as a free function (see `BrowserLogicTests`) because getting this
/// wrong — dropping a group, or looping forever on a cycle — is a correctness bug that deserves a
/// fast unit test, not something only ever caught by eyeballing the sidebar.
enum GroupTreeBuilder {
    static func build(from groups: [VaultGroup]) -> [GroupTreeNode] {
        let byID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        var childrenByParent: [UUID: [VaultGroup]] = [:]
        var rootGroups: [VaultGroup] = []

        for group in groups {
            // A group is a root if it has no parent, its parent no longer exists in this vault
            // (another KDBX client can delete a group and leave a dangling `parentID` behind on
            // its former children), or its parent is itself — a degenerate case treated as a root
            // instead of an infinite loop.
            if let parentID = group.parentID, parentID != group.id, byID[parentID] != nil {
                childrenByParent[parentID, default: []].append(group)
            } else {
                rootGroups.append(group)
            }
        }

        var visited: Set<UUID> = []

        func makeNode(for group: VaultGroup) -> GroupTreeNode {
            visited.insert(group.id)
            let children = (childrenByParent[group.id] ?? [])
                .filter { !visited.contains($0.id) } // breaks any remaining parent/child cycle
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map(makeNode)
            return GroupTreeNode(group: group, children: children.isEmpty ? nil : children)
        }

        var nodes = rootGroups
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map(makeNode)

        // A group is unreachable from any true root only via a parent/child cycle (A's parent is
        // B, B's parent is A). Rather than silently drop those groups, surface each one still
        // unvisited as its own root — every group handed to this function ends up SOMEWHERE in the
        // returned forest, which is the hard guarantee `BrowserLogicTests` checks. Iterated by
        // input order, and re-checked per group, so a cycle's second member (already absorbed as
        // the first member's child by `makeNode` above) isn't also added as a duplicate root.
        for group in groups where !visited.contains(group.id) {
            nodes.append(makeNode(for: group))
        }

        return nodes
    }
}

/// The left column: "All Entries" plus the group outline, each row showing its own entry count.
///
/// Selecting "All Entries" clears `selectedGroupID` to `nil`. That's a DIFFERENT meaning of `nil`
/// than `Vault.entries(inGroup:)` uses (there, `nil` means "top-level entries with no group at
/// all" — see that method's doc comment) — this view and `EntryListView` deliberately treat
/// `selectedGroupID == nil` as "no filter, show everything" instead, which is what the "All
/// Entries" label actually promises.
struct GroupSidebar: View {
    let vault: Vault
    @Binding var selectedGroupID: UUID?
    /// Asks the owner to empty the recycle bin. A closure rather than a `VaultStore` reference
    /// because emptying is destructive and needs a confirmation, and the confirmation belongs
    /// where the rest of this screen's alerts live (`VaultBrowserView`) — a sidebar that could
    /// call `store.emptyRecycleBin()` directly is one refactor away from doing it without asking.
    var onEmptyRecycleBin: () -> Void

    private var nodes: [GroupTreeNode] {
        GroupTreeBuilder.build(from: vault.groups)
    }

    /// The bin group's id, or `nil` when this database has never had anything deleted.
    private var recycleBinID: UUID? { vault.recycleBin.groupID }

    var body: some View {
        List(selection: $selectedGroupID) {
            HStack {
                Label("All Entries", systemImage: "tray.full")
                Spacer()
                // Recycled entries are excluded, so this number always equals what selecting this
                // row actually reveals (`EntryListFilter` hides them too). Counting them would
                // leave the count unchanged when an entry is deleted — the same "nothing
                // happened" signal that makes a user press ⌫ a second time.
                Text("\(vault.liveEntries.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .tag(UUID?.none)
            .accessibilityIdentifier("sidebar.allEntries")

            OutlineGroup(nodes, children: \.children) { node in
                row(for: node)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(vault.name.isEmpty ? "PassSumo" : vault.name)
    }

    /// One folder row. The recycle bin is deliberately NOT styled like the folders around it: it
    /// is the one group where the entries inside are not live credentials, and a user who cannot
    /// tell it apart at a glance is exactly the user who copies a password out of it. It gets the
    /// trash icon (matching the icon id we write into the file for other clients — see
    /// `KDBXRecycleBin`), a de-emphasised label, and the only place "Empty Recycle Bin" is offered.
    @ViewBuilder
    private func row(for node: GroupTreeNode) -> some View {
        let isRecycleBin = node.group.id == recycleBinID
        HStack {
            Label(node.group.name, systemImage: isRecycleBin ? "trash" : "folder")
                .foregroundStyle(isRecycleBin ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            Spacer()
            // Direct membership only (not descendants) — matches `entries(inGroup:)`, which
            // `EntryListView` uses for the same group filter, so the number shown here always
            // equals what selecting this row actually reveals.
            Text("\(vault.entries(inGroup: node.group.id).count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .tag(Optional(node.group.id))
        .accessibilityIdentifier(
            isRecycleBin ? "sidebar.recycleBin" : "sidebar.group.\(node.group.id)"
        )
        .contextMenu {
            if isRecycleBin {
                Button("Empty Recycle Bin", role: .destructive, action: onEmptyRecycleBin)
                    .accessibilityIdentifier("sidebar.emptyRecycleBin")
            }
        }
    }
}

#Preview {
    @Previewable @State var selection: UUID?
    return NavigationSplitView {
        GroupSidebar(vault: .sample, selectedGroupID: $selection, onEmptyRecycleBin: {})
    } detail: {
        Text("Detail")
    }
}
