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

    /// The same forest, flattened back into a list, each group carrying the "Parent / Child" path
    /// that names it. What a FLAT control needs — the "Move to" menu below, the entry sheet's group
    /// picker — so both show the sidebar's order and the sidebar's nesting without walking the tree
    /// a second way and drifting from it.
    ///
    /// Paths rather than indentation because these controls are `Menu`s and `Picker`s, where two
    /// folders that happen to share a name ("Work / Archive" and "Personal / Archive") would
    /// otherwise be two identical rows with different meanings. Terminates on a cyclic input for
    /// the same reason the outline does: `build(from:)` has already broken the cycle.
    static func paths(from groups: [VaultGroup]) -> [GroupPathItem] {
        var result: [GroupPathItem] = []

        func walk(_ nodes: [GroupTreeNode], prefix: String) {
            for node in nodes {
                let path = prefix.isEmpty ? node.group.name : prefix + " / " + node.group.name
                result.append(GroupPathItem(group: node.group, path: path))
                walk(node.children ?? [], prefix: path)
            }
        }

        walk(build(from: groups), prefix: "")
        return result
    }
}

/// One group plus the path that identifies it in a list with no indentation of its own. Built by
/// `GroupTreeBuilder.paths(from:)`; see that method for why the label is a path.
struct GroupPathItem: Identifiable, Equatable {
    let group: VaultGroup
    let path: String
    var id: UUID { group.id }
}

/// What a group row's context menu asks its owner to do.
///
/// One closure carrying this, rather than four separate closures. The sidebar deliberately holds no
/// `VaultStore` — see `GroupSidebar.onEmptyRecycleBin` for the rule and why — so every one of these
/// is a REQUEST, and keeping them in one type keeps that boundary a single visible thing instead of
/// four parameters that can each drift into something that acts on its own.
enum GroupCommand: Equatable {
    /// A new folder under `parentID`; `nil` is the vault's top level.
    case create(parentID: UUID?)
    case rename(UUID)
    /// Open the icon picker for this folder. A request to PRESENT, not the pick itself: the sheet
    /// belongs where this screen's other sheets and alerts live (`VaultBrowserView`), the same
    /// place `rename` goes to raise its name prompt.
    case changeIcon(UUID)
    case move(UUID, toParent: UUID?)
    case delete(UUID)
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
    /// Where every group edit this sidebar can start goes. A closure for the same reason
    /// `onEmptyRecycleBin` is one: deleting a folder takes its entries with it, and the view that
    /// can destroy something must not also be the view that decides to.
    var onGroupCommand: (GroupCommand) -> Void

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
            // `List(selection:)` + `OutlineGroup` on macOS does not write this binding on a
            // click (issue #129). Programmatic `selection = .group(created.id)` already
            // worked, which is why a newly created folder appeared selected while a mouse
            // click on All Entries / another group did nothing. Write it ourselves.
            // `.onTapGesture` is left-click only, so it does not steal the context menu.
            // `nil` is "deselected", not All Entries (issue #85).
            .onTapGesture { selection = .allEntries }
            .contextMenu {
                Button("New Group…") { onGroupCommand(.create(parentID: nil)) }
                    .accessibilityIdentifier("sidebar.allEntries.newGroup")
            }

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
                // A fixed slot, because the glyph is no longer one of three known-similar symbols
                // — it is whichever of the 69 the folder's `iconID` names, and those run 8pt to
                // 21pt wide at this size. Without it every label in the column starts at a
                // different x. See `Metrics.rowIconSlot`.
                .frame(width: Metrics.rowIconSlot)
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
    /// tell it apart at a glance is exactly the user who copies a password out of it. It gets a
    /// de-emphasised label and the only place "Empty Recycle Bin" is offered.
    ///
    /// **The glyph is no longer one of them** (issue #89). It used to be picked by identity —
    /// `trash` for the bin, `folder` for everything else — which drew the same two symbols however
    /// a database's owner had actually iconed their folders. It now comes from the group's own
    /// `iconID` through `VaultGroup.symbolName`, and the bin falls out of that table rather than
    /// being special-cased: it carries `iconID` 43, which maps to the same `trash` this row drew
    /// before. The identity check that remains is about the muted treatment only.
    @ViewBuilder
    private func row(for node: GroupTreeNode) -> some View {
        let isRecycleBin = node.group.id == recycleBinID
        sidebarRow(
            label: node.group.name,
            systemImage: node.group.symbolName,
            // Subtree, not direct membership (issue #143) — matches `EntryListFilter`, so
            // the number shown here always equals what selecting this row actually reveals.
            count: vault.entries(inSubtreeOf: node.group.id).count,
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
        // Same reason as All Entries above: the List does not consume the click, so
        // the binding is written here. Menu stays after the tap so a right-click still
        // reaches `.contextMenu` rather than being eaten as a tap.
        .onTapGesture { selection = .group(node.group.id) }
        .contextMenu {
            if isRecycleBin {
                Button("Empty Recycle Bin", role: .destructive, action: onEmptyRecycleBin)
                    .accessibilityIdentifier("sidebar.emptyRecycleBin")
            } else {
                Button("New Group…") { onGroupCommand(.create(parentID: node.group.id)) }
                    .accessibilityIdentifier("sidebar.newGroup")
                Button("Rename…") { onGroupCommand(.rename(node.group.id)) }
                    .accessibilityIdentifier("sidebar.renameGroup")
                // Beside Rename, because it is the same kind of act: naming the folder, in the
                // other of the two ways KDBX lets a folder be named. The recycle bin is left out
                // for the same reason it has no Rename — its name and its icon are what make it
                // recognisable as the bin to every other client that opens the file.
                Button("Change Icon…") { onGroupCommand(.changeIcon(node.group.id)) }
                    .accessibilityIdentifier("sidebar.changeGroupIcon")
                moveMenu(for: node.group)
                Divider()
                Button("Delete Group", role: .destructive) { onGroupCommand(.delete(node.group.id)) }
                    .accessibilityIdentifier("sidebar.deleteGroup")
            }
        }
    }

    /// The non-drag way to re-parent a folder. Drag and drop is the macOS-native gesture and is
    /// deliberately not here — it is its own issue (see #88's out-of-scope list), and without this
    /// menu `VaultStore.moveGroup` would have no way of being reached at all.
    ///
    /// Two things are filtered out of the destinations, for two different reasons:
    ///
    /// - **Anything `Vault.canMoveGroup` refuses** — the folder itself and its own descendants.
    ///   Offering a destination the model will decline is a menu item that does nothing when
    ///   clicked, which reads as a broken app rather than as a rule.
    /// - **The recycle bin and everything in it.** Filing a live folder in there is a delete wearing
    ///   a move's clothes; "Delete Group" is the affordance for that, and it is the one that asks.
    ///   The bin's own contents keep this menu, though — with the bin excluded, what is left is
    ///   exactly the set of places a recycled folder can be RESTORED to.
    @ViewBuilder
    private func moveMenu(for group: VaultGroup) -> some View {
        let recycled = vault.recycleBinGroupIDs
        let destinations = GroupTreeBuilder.paths(from: vault.groups).filter { candidate in
            !recycled.contains(candidate.group.id)
                && candidate.group.id != group.parentID
                && vault.canMoveGroup(group.id, under: candidate.group.id)
        }
        let canGoToTopLevel = group.parentID != nil

        Menu("Move to") {
            if canGoToTopLevel {
                Button("Top Level") { onGroupCommand(.move(group.id, toParent: nil)) }
                    .accessibilityIdentifier("sidebar.moveGroup.topLevel")
            }
            ForEach(destinations) { destination in
                Button(destination.path) {
                    onGroupCommand(.move(group.id, toParent: destination.group.id))
                }
                .accessibilityIdentifier("sidebar.moveGroup.\(destination.group.id)")
            }
        }
        .disabled(destinations.isEmpty && !canGoToTopLevel)
    }
}

#Preview {
    @Previewable @State var selection: GroupSelection? = .allEntries
    return NavigationSplitView {
        GroupSidebar(
            vault: .sample,
            selection: $selection,
            onEmptyRecycleBin: {},
            onGroupCommand: { _ in }
        )
    } detail: {
        Text("Detail")
    }
}
