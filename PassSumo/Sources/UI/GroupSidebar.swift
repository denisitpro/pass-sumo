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

/// What the sidebar's selection can be: the unfiltered "All Entries" row, or one group.
///
/// **An explicit case rather than `nil` for "All Entries" (issue #85).** A macOS `List(selection:)`
/// bound to an `Optional` writes `nil` to mean *deselected*, so a `nil` that ALSO meant "All
/// Entries" gave the list no way to tell "the user picked that row" from "the selection was
/// cleared" — and the row could not reliably become, or stay, the selection once a group had been
/// picked. Binding the list to `GroupSelection?` gives `nil` back its one real meaning.
///
/// `nil` still means something else again one layer down, and deliberately so:
/// `Vault.entries(inGroup: nil)` means "entries with no group at all" (see that method's doc
/// comment), which is not what "All Entries" promises. The two were never the same thing; this type
/// is what stops them being spelled the same way.
enum GroupSelection: Hashable {
    case allEntries
    case group(UUID)

    /// The group something created "here" belongs to — `nil` for `allEntries`, which is
    /// `VaultEntry.groupID`'s own "no group, top level".
    ///
    /// Deliberately NOT used as a filter argument: `EntryListFilter` switches on the case instead,
    /// so the two meanings of `nil` above never meet again in one value.
    var containingGroupID: UUID? {
        switch self {
        case .allEntries: return nil
        case .group(let id): return id
        }
    }
}

/// The left column: "All Entries" plus the group outline, each row showing its own entry count.
///
/// The selection is a `GroupSelection?` rather than a `UUID?` — see that type's doc comment for
/// what went wrong when "All Entries" was spelled `nil`.
struct GroupSidebar: View {
    let vault: Vault
    @Binding var selection: GroupSelection?
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
        List(selection: $selection) {
            sidebarRow(
                label: "All Entries",
                systemImage: "tray.full",
                count: vault.liveEntries.count,
                // Recycled entries are excluded, so this number always equals what selecting this
                // row actually reveals (`EntryListFilter` hides them too). Counting them would
                // leave the count unchanged when an entry is deleted — the same "nothing
                // happened" signal that makes a user press ⌫ a second time.
                isSelected: selection == .allEntries,
                isMuted: false
            )
            // `Optional(_:)`, matching the group rows below: the tag's type must be the binding's
            // `GroupSelection?`, not `GroupSelection`, or the row is tagged with a value the
            // selection can never hold and clicking it does nothing.
            .tag(Optional(GroupSelection.allEntries))
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .accessibilityIdentifier("sidebar.allEntries")

            OutlineGroup(nodes, children: \.children) { node in
                row(for: node)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Palette.sidebar)
        .navigationTitle(vault.name.isEmpty ? "PassSumo" : vault.name)
    }

    /// One sidebar row's contents: icon, label, entry count — all three taking the selection tone
    /// together, as the mockup's `.side-row.is-selected` does.
    private func sidebarRow(
        label: String,
        systemImage: String,
        count: Int,
        isSelected: Bool,
        isMuted: Bool
    ) -> some View {
        let labelColor: Color = isSelected
            ? Palette.rowSelectionText
            : (isMuted ? Palette.textSecondary : Palette.text)
        let quietColor: Color = isSelected
            ? Palette.rowSelectionText
            : (isMuted ? Palette.textTertiary : Palette.textSecondary)

        return HStack(spacing: Spacing.s3) {
            Image(systemName: systemImage)
                .font(Typography.caption)
                .foregroundStyle(quietColor)
            Text(label)
                .font(isSelected ? Typography.bodyMedium : Typography.body)
                .foregroundStyle(labelColor)
                .lineLimit(1)
            Spacer(minLength: Spacing.s2)
            Text("\(count)")
                .font(Typography.monoCaption2)
                .foregroundStyle(quietColor)
        }
        .sidebarRowSurface(isSelected: isSelected)
    }

    /// One folder row. The recycle bin is deliberately NOT styled like the folders around it: it
    /// is the one group where the entries inside are not live credentials, and a user who cannot
    /// tell it apart at a glance is exactly the user who copies a password out of it. It gets the
    /// trash icon (matching the icon id we write into the file for other clients — see
    /// `KDBXRecycleBin`), a de-emphasised label, and the only place "Empty Recycle Bin" is offered.
    @ViewBuilder
    private func row(for node: GroupTreeNode) -> some View {
        let isRecycleBin = node.group.id == recycleBinID
        sidebarRow(
            label: node.group.name,
            systemImage: isRecycleBin ? "trash" : "folder",
            // Direct membership only (not descendants) — matches `entries(inGroup:)`, which
            // `EntryListView` uses for the same group filter, so the number shown here always
            // equals what selecting this row actually reveals.
            count: vault.entries(inGroup: node.group.id).count,
            isSelected: selection == .group(node.group.id),
            // The bin's row is de-emphasised (`.side-row.is-muted`): it is the one group whose
            // contents are not live credentials, and a user who cannot tell it apart at a glance
            // is exactly the user who copies a password out of it.
            isMuted: isRecycleBin
        )
        .tag(Optional(GroupSelection.group(node.group.id)))
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
    @Previewable @State var selection: GroupSelection? = .allEntries
    return NavigationSplitView {
        GroupSidebar(vault: .sample, selection: $selection, onEmptyRecycleBin: {})
    } detail: {
        Text("Detail")
    }
}
