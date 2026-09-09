import AppKit
import SwiftUI

/// Whether a URL string is "open-able": it must carry a scheme, not just be a parseable string.
/// `URL(string:)` alone happily accepts a bare "example.com" that `NSWorkspace` then silently
/// fails to open. Pulled out as a free function so `EntryDetailView`'s URL row and
/// `EntryListView`'s row context menu (issue #48) share the one scheme test instead of each
/// carrying its own copy that could drift.
enum EntryURLResolver {
    static func resolvedURL(from urlString: String) -> URL? {
        guard !urlString.isEmpty, let url = URL(string: urlString), url.scheme != nil else { return nil }
        return url
    }
}

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

        // This list normally hides the recycle bin (see `Vault.liveEntries`). The one exception is
        // a user who has selected the bin — or a folder inside it — in the sidebar: the group
        // filter has already scoped the result to the bin, so hiding it again would make that
        // column silently return nothing, whether or not anything was typed.
        let isScopedToRecycleBin = groupID.map(vault.recycleBinGroupIDs.contains) == true

        // `Vault.search` deliberately matches across the WHOLE vault, including the password field
        // itself (see `Domain.swift`'s doc comment on `search(_:)` — a differentiator from
        // KeePassium, which doesn't search passwords at all). Intersecting its result with
        // `candidates` keeps that same search behavior while still honoring whichever group is
        // selected, rather than re-implementing a scoped, weaker search here.
        //
        // The EMPTY query goes through it as well rather than short-circuiting to `candidates`.
        // An empty query there already means "no filter" (it returns `liveEntries`), and routing
        // both cases through the one function that knows what excluding the bin means is what
        // keeps them from drifting — which is what had happened: the exclusion existed only on the
        // searching path, so an empty search field listed the bin's contents among the live ones
        // and a delete had no visible effect whatsoever.
        let visible = Set(
            vault.search(query, includingRecycleBin: isScopedToRecycleBin).map(\.id)
        )
        let filtered = candidates.filter { visible.contains($0.id) }

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
    /// own selection handling. Also wired to the row context menu's Edit item and to double-click
    /// (issue #48), so this one closure is every mouse- and keyboard-driven way to reach the same
    /// `VaultBrowserView.openForEdit`.
    var onOpenEntry: (UUID) -> Void
    /// Row context menu actions (issue #48) — each is wired to the SAME handler the toolbar/menu
    /// bar already use (`VaultBrowserView`'s own doc comment on why the toolbar and `AppCommands`
    /// must not grow parallel implementations), never a second copy of the logic.
    var onCopyUsername: (VaultEntry) -> Void
    var onCopyPassword: (VaultEntry) -> Void
    var onDeleteEntry: (UUID) -> Void

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
        // The whole row must be hit-testable, not just its text/icon content (an `HStack`'s
        // `Spacer()` is otherwise a hole in the gesture's hit area), and this must be a
        // `.simultaneousGesture` rather than a plain `.onTapGesture`/`.gesture`: `List(selection:)`
        // on macOS already owns a click gesture for row selection, and an exclusive gesture here
        // would compete with — and can lose to — that built-in one, silently swallowing the double
        // click instead of ever calling `onOpenEntry`. Verified empirically: a plain
        // `.onTapGesture(count: 2)` never fired against a real double-click in this List; this does.
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { onOpenEntry(entry.id) }
        )
        .contextMenu { contextMenuItems(for: entry) }
    }

    /// Mirrors the toolbar/menu-bar actions already available for the selected entry — see
    /// `onOpenEntry`'s doc comment for why nothing here is a new code path. An item that cannot
    /// apply to THIS row (no username, no URL with a scheme) is disabled or absent rather than
    /// present and silently dead, per issue #48's acceptance criteria.
    @ViewBuilder
    private func contextMenuItems(for entry: VaultEntry) -> some View {
        Button("Edit") { onOpenEntry(entry.id) }
            .keyboardShortcut("e", modifiers: .command)

        Button("Copy Username") { onCopyUsername(entry) }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(entry.username.isEmpty)

        Button("Copy Password") { onCopyPassword(entry) }
            .keyboardShortcut("c", modifiers: [.command, .shift])

        if let url = EntryURLResolver.resolvedURL(from: entry.url) {
            Button("Open URL") { NSWorkspace.shared.open(url) }
        }

        Divider()

        Button("Delete", role: .destructive) { onDeleteEntry(entry.id) }
            .keyboardShortcut(.delete, modifiers: [])
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
        onOpenEntry: { _ in },
        onCopyUsername: { _ in },
        onCopyPassword: { _ in },
        onDeleteEntry: { _ in }
    )
}
