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

/// How `EntryListView` orders its rows — issue #33 adds the password-change options alongside the
/// original alphabetical one. A flat enum rather than a `(field, direction)` pair: four fixed,
/// named combinations are simpler to reason about and to bind a `Picker` to than a cross product
/// most of which nothing needs.
enum EntryListSortOrder: String, CaseIterable, Identifiable, Sendable {
    case titleAscending
    case titleDescending
    case passwordChangedNewestFirst
    case passwordChangedOldestFirst

    var id: String { rawValue }

    var label: String {
        switch self {
        case .titleAscending: return "Title (A–Z)"
        case .titleDescending: return "Title (Z–A)"
        case .passwordChangedNewestFirst: return "Password Changed (Newest First)"
        case .passwordChangedOldestFirst: return "Password Changed (Oldest First)"
        }
    }
}

/// Combines the sidebar's group filter with the search query into the exact list `EntryListView`
/// shows. Pulled out as a free function (see `BrowserLogicTests`) so the one tricky bit — a group
/// filter and a search query compose as an INTERSECTION, not as "search wins" or "group wins" — has
/// a fast unit test instead of only being checkable by typing into the running app.
enum EntryListFilter {
    static func apply(
        to vault: Vault,
        selection: GroupSelection,
        query: String,
        sortOrder: EntryListSortOrder = .titleAscending
    ) -> [VaultEntry] {
        let candidates: [VaultEntry]
        // This list normally hides the recycle bin (see `Vault.liveEntries`). The one exception is
        // a user who has selected the bin — or a folder inside it — in the sidebar: the group
        // filter has already scoped the result to the bin, so hiding it again would make that
        // column silently return nothing, whether or not anything was typed.
        let isScopedToRecycleBin: Bool

        // Switched on, rather than first reduced to an optional group id: "All Entries" means "no
        // group filter at all", which is NOT `entries(inGroup: nil)`'s "only entries with no group
        // at all" (see that method's doc comment). Those two used to be spelled the same way, and
        // issue #85 is what that cost; the switch is what keeps them apart.
        switch selection {
        case .allEntries:
            candidates = vault.entries
            isScopedToRecycleBin = false
        case .group(let id):
            candidates = vault.entries(inGroup: id)
            isScopedToRecycleBin = vault.recycleBinGroupIDs.contains(id)
        }

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

        return sorted(filtered, by: sortOrder)
    }

    /// Case-insensitive title comparison, tie-broken by id for a deterministic order when two
    /// entries share a title — the target user has hundreds of entries (repo CLAUDE.md positioning
    /// notes), and scanning a dense list by eye needs a stable, predictable order. The tie-break
    /// always runs ascending regardless of `ascending`, so descending title order doesn't also
    /// silently reverse which of two same-titled rows comes first.
    private static func titleOrdering(ascending: Bool) -> (VaultEntry, VaultEntry) -> Bool {
        { lhs, rhs in
            let comparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if comparison != .orderedSame {
                return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// Issue #33: sorting by password-change date has to answer a question the alphabetical order
    /// never faced — what to do with an entry that has NO derivable date. Silently sorting it to
    /// either end would misrepresent it as "just changed" or "most overdue", so entries with a
    /// `nil` `passwordLastChanged` are split into their own trailing group (alphabetical, so it is
    /// at least scannable) rather than participating in the date ordering at all.
    private static func sorted(_ entries: [VaultEntry], by order: EntryListSortOrder) -> [VaultEntry] {
        switch order {
        case .titleAscending:
            return entries.sorted(by: titleOrdering(ascending: true))
        case .titleDescending:
            return entries.sorted(by: titleOrdering(ascending: false))
        case .passwordChangedNewestFirst, .passwordChangedOldestFirst:
            let dated = entries.filter { $0.passwordLastChanged != nil }
            let undated = entries.filter { $0.passwordLastChanged == nil }
            let newestFirst = order == .passwordChangedNewestFirst
            let sortedDated = dated.sorted { lhs, rhs in
                guard let lhsDate = lhs.passwordLastChanged, let rhsDate = rhs.passwordLastChanged
                else { return false }
                if lhsDate != rhsDate { return newestFirst ? lhsDate > rhsDate : lhsDate < rhsDate }
                return titleOrdering(ascending: true)(lhs, rhs)
            }
            return sortedDated + undated.sorted(by: titleOrdering(ascending: true))
        }
    }
}

/// The middle column: a dense, filterable list of entries. `.searchable` itself is attached by
/// `VaultBrowserView` (the brief's own instruction — it belongs to the column, not this view), so
/// this type only consumes `searchText`, it doesn't present the search field.
struct EntryListView: View {
    let vault: Vault
    /// Which sidebar row is in effect. Non-optional here on purpose: "nothing is selected" is a
    /// state of the SIDEBAR's binding, and `VaultBrowserView` resolves it to `.allEntries` before
    /// this column ever sees it — see its `groupSelection`.
    let selection: GroupSelection
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

    /// Local to this column, unlike `searchText`/`selectedEntryID`: nothing outside the list cares
    /// how its rows are ordered, so it does not belong on `VaultBrowserView`'s cross-column state
    /// (see that type's doc comment on what DOES have to live up there and why).
    @State private var sortOrder: EntryListSortOrder = .titleAscending

    private var entries: [VaultEntry] {
        EntryListFilter.apply(to: vault, selection: selection, query: searchText, sortOrder: sortOrder)
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
                .foregroundStyle(Palette.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.surface)
            } else {
                List(entries, selection: $selectedEntryID) { entry in
                    row(for: entry, isLast: entry.id == entries.last?.id)
                        .accessibilityIdentifier("list.entry.\(entry.id)")
                        // The row draws its own ground, height, padding and inset hairline (see
                        // `entryRowSurface`), so `List` must contribute none of the three: no
                        // insets, no separator, no default row background.
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Palette.surface)
                .onKeyPress(.return) {
                    guard let selectedEntryID else { return .ignored }
                    onOpenEntry(selectedEntryID)
                    return .handled
                }
            }
        }
        .accessibilityIdentifier("browser.list")
        // A toolbar contribution from a middle-column view, merged by SwiftUI into the same
        // toolbar `VaultBrowserView` populates — the sort order is this column's own concern (see
        // `sortOrder`'s doc comment), so it is declared here rather than threaded up as one more
        // binding on `VaultBrowserView`'s already-large cross-column state.
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Sort By", selection: $sortOrder) {
                        ForEach(EntryListSortOrder.allCases) { order in
                            Text(order.label).tag(order)
                        }
                    }
                } label: {
                    Label("Sort By", systemImage: "arrow.up.arrow.down")
                }
                .accessibilityIdentifier("list.sortMenu")
            }
        }
    }

    private func row(for entry: VaultEntry, isLast: Bool) -> some View {
        let isSelected = entry.id == selectedEntryID
        // Title and sub-line are pushed together into the mockup's 34pt row: 13/17 over 11/13, so
        // both fit without the row growing. Dense on purpose — hundreds of entries is the expected
        // scale (repo CLAUDE.md positioning notes).
        return HStack(spacing: Spacing.s4) {
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.title.isEmpty ? "Untitled" : entry.title)
                    .font(isSelected ? Typography.bodyMedium : Typography.body)
                    .foregroundStyle(isSelected ? Palette.rowSelectionText : Palette.text)
                    .lineLimit(1)
                if !entry.username.isEmpty {
                    Text(entry.username)
                        .font(Typography.caption2)
                        .foregroundStyle(isSelected ? Palette.rowSelectionText : Palette.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if entry.otpAuthURL != nil {
                Image(systemName: "clock.badge.checkmark")
                    .font(Typography.caption)
                    .foregroundStyle(isSelected ? Palette.rowSelectionText : Palette.textTertiary)
                    .accessibilityLabel("Has a one-time code")
            }
        }
        .entryRowSurface(isSelected: isSelected, showsSeparator: !isLast)
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
        selection: .allEntries,
        searchText: $searchText,
        selectedEntryID: $selection,
        onOpenEntry: { _ in },
        onCopyUsername: { _ in },
        onCopyPassword: { _ in },
        onDeleteEntry: { _ in }
    )
}
