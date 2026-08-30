import SwiftUI

/// Combines the sidebar's group filter with the search query into the exact list `EntryListView`
/// shows. Pulled out as a free function (see `BrowserLogicTests`) so the one tricky bit — a group
/// filter and a search query compose as an INTERSECTION, not as "search wins" or "group wins" — has
/// a fast unit test instead of only being checkable by typing into the running app.
enum EntryListFilter {
    static func apply(to vault: Vault, groupID: UUID?, query: String) -> [VaultEntry] {
        // `groupID == nil` means "All Entries" (no filter) here — NOT `entries(inGroup: nil)`'s
        // meaning of "only entries with no group at all". See `GroupSidebar`'s doc comment for why
        // the two `nil`s intentionally diverge.
        let candidates = groupID.map(vault.entries(inGroup:)) ?? vault.entries

        // Searching normally hides the recycle bin (see `Vault.search`). The one exception is a
        // user who has selected the bin — or a folder inside it — in the sidebar and is searching
        // within it: the group filter has already scoped the result to the bin, so hiding it again
        // would make that column silently return nothing no matter what was typed.
        let isScopedToRecycleBin = groupID.map(vault.recycleBinGroupIDs.contains) == true

        let filtered: [VaultEntry]
        if query.isEmpty {
            filtered = candidates
        } else {
            // `Vault.search` deliberately matches across the WHOLE vault, including the password
            // field itself (see `Domain.swift`'s doc comment on `search(_:)` — a differentiator
            // from KeePassium, which doesn't search passwords at all). Intersecting its result
            // with `candidates` keeps that same search behavior while still honoring whichever
            // group is selected, rather than re-implementing a scoped, weaker search here.
            let matched = Set(
                vault.search(query, includingRecycleBin: isScopedToRecycleBin).map(\.id)
            )
            filtered = candidates.filter { matched.contains($0.id) }
        }

        // Alphabetical by title, case-insensitively, tie-broken by id for a deterministic order
        // when two entries share a title — the target user has hundreds of entries (repo
        // CLAUDE.md positioning notes), and scanning a dense list by eye needs a stable, predictable
        // order far more than it needs "most recently modified first".
        return filtered.sorted { lhs, rhs in
            let comparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

/// The middle column: a dense, filterable list of entries. `.searchable` itself is attached by
/// `VaultBrowserView` (the brief's own instruction — it belongs to the column, not this view), so
/// this type only consumes `searchText`, it doesn't present the search field.
struct EntryListView: View {
    let vault: Vault
    let groupID: UUID?
    @Binding var searchText: String
    @Binding var selectedEntryID: UUID?
    /// Return opens the selected entry for editing — arrow-key movement comes free from `List`'s
    /// own selection handling, so this closure is the only extra wiring this view needs for the
    /// brief's "arrow keys move the selection, Return opens edit".
    var onOpenEntry: (UUID) -> Void

    private var entries: [VaultEntry] {
        EntryListFilter.apply(to: vault, groupID: groupID, query: searchText)
    }

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "No Entries" : "No Results",
                    systemImage: searchText.isEmpty ? "tray" : "magnifyingglass",
                    description: Text(
                        searchText.isEmpty
                            ? "This group has no entries yet."
                            : "No entry matches “\(searchText)”."
                    )
                )
            } else {
                List(entries, selection: $selectedEntryID) { entry in
                    row(for: entry)
                        .accessibilityIdentifier("list.entry.\(entry.id)")
                }
                .onKeyPress(.return) {
                    guard let selectedEntryID else { return .ignored }
                    onOpenEntry(selectedEntryID)
                    return .handled
                }
            }
        }
        .accessibilityIdentifier("browser.list")
    }

    private func row(for entry: VaultEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title.isEmpty ? "Untitled" : entry.title)
                if !entry.username.isEmpty {
                    Text(entry.username)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if entry.otpAuthURL != nil {
                Image(systemName: "clock.badge.checkmark")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Has a one-time code")
            }
        }
        // Dense rows on purpose — hundreds of entries is the expected scale (repo CLAUDE.md
        // positioning notes), so this list favors information density over generous row padding.
        .padding(.vertical, 1)
    }
}

#Preview {
    @Previewable @State var searchText = ""
    @Previewable @State var selection: UUID?
    return EntryListView(
        vault: .sample,
        groupID: nil,
        searchText: $searchText,
        selectedEntryID: $selection,
        onOpenEntry: { _ in }
    )
}
