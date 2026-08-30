import SwiftUI

/// The three-column browser — group sidebar, entry list, entry detail. This is "the screen the
/// user lives in" (per the UI brief this file was written against): everything else in the app is
/// a doorway into or out of it.
///
/// Owns ALL cross-column state itself (`selectedGroupID`, `selectedEntryID`, `searchText`) rather
/// than letting each column keep its own — a group change has to clear which entry is selected
/// (see the `.onChange(of: selectedGroupID)` below), and that coordination only works if one view
/// is the single source of truth for both.
struct VaultBrowserView: View {
    let store: VaultStore
    let clipboard: ClipboardService
    let generator: PasswordGenerator
    /// Only ever read for its countdown and for `noteActivity()` — this view never locks anything
    /// itself. It is a constructor parameter rather than an environment read because `StatusBar`
    /// showing a real number is not optional behaviour, and an environment lookup that silently
    /// resolves to nothing would degrade to exactly the hardcoded `nil` this replaced.
    let autoLock: AutoLockController

    /// Optional on purpose: `RootView` always injects it, but the `#Preview` below (and any future
    /// one) constructs this view standalone, and a non-optional `@Environment(AppEnvironment.self)`
    /// traps at render time when nothing supplied it. Everything read off it is menu-bar wiring,
    /// which a preview has no menu bar for anyway.
    @Environment(AppEnvironment.self) private var appEnvironment: AppEnvironment?

    @State private var selectedGroupID: UUID?
    @State private var selectedEntryID: UUID?
    @State private var searchText = ""
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showingGenerator = false
    @State private var editingEntry: EditingEntry?
    /// The entry a permanent delete has been requested for, held until the user confirms. Nothing
    /// destroys an entry without passing through here first — see `requestDelete(_:)`.
    @State private var pendingPermanentDeletion: VaultEntry?
    @State private var isConfirmingEmptyRecycleBin = false
    /// Drives `.searchFocused` so the Focus Search command (⌘F) has something to move focus TO —
    /// `.searchable` presents the field but gives no other handle on its focus state.
    @FocusState private var isSearchFocused: Bool

    init(
        store: VaultStore,
        clipboard: ClipboardService,
        generator: PasswordGenerator,
        autoLock: AutoLockController
    ) {
        self.store = store
        self.clipboard = clipboard
        self.generator = generator
        self.autoLock = autoLock
    }

    /// What `EntryEditView` is editing right now: a brand-new entry, or an existing one opened for
    /// edit. `Identifiable` so it can drive `.sheet(item:)`, which (unlike `.sheet(isPresented:)`)
    /// can't accidentally re-present stale state left over from a previously edited entry.
    private struct EditingEntry: Identifiable {
        var entry: VaultEntry
        var isNew: Bool
        var id: UUID { entry.id }
    }

    /// The vault to render. Empty when the store isn't `.unlocked` — this view is only ever
    /// SHOWN while unlocked (that's the app shell's job to arrange), but reading `store.state`
    /// defensively here rather than force-unwrapping means a lock arriving mid-render (auto-lock,
    /// a system sleep event) degrades to an empty screen instead of a crash.
    private var vault: Vault {
        if case .unlocked(let vault) = store.state { return vault }
        return Vault(name: "", groups: [], entries: [])
    }

    private var isLocked: Bool {
        if case .unlocked = store.state { return false }
        return true
    }

    private var selectedEntry: VaultEntry? {
        guard let selectedEntryID else { return nil }
        return vault.entries.first { $0.id == selectedEntryID }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            GroupSidebar(
                vault: vault,
                selectedGroupID: $selectedGroupID,
                onEmptyRecycleBin: { isConfirmingEmptyRecycleBin = true }
            )
            .accessibilityIdentifier("browser.sidebar")
        } content: {
            EntryListView(
                vault: vault,
                groupID: selectedGroupID,
                searchText: $searchText,
                selectedEntryID: $selectedEntryID,
                onOpenEntry: { id in openForEdit(id) }
            )
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search entries and passwords")
            .searchFocused($isSearchFocused)
            .accessibilityIdentifier("browser.search")
        } detail: {
            Group {
                if let selectedEntry {
                    EntryDetailView(
                        entry: selectedEntry,
                        clipboard: clipboard,
                        isLocked: isLocked,
                        // The one capability the detail view needs from the vault, handed over as
                        // a function instead of the vault itself — see its `resolveAttachment`.
                        resolveAttachment: { vault.bytes(for: $0) },
                        onEdit: { openForEdit(selectedEntry.id) }
                    )
                } else {
                    ContentUnavailableView(
                        "No Entry Selected",
                        systemImage: "lock.doc",
                        description: Text("Choose an entry from the list.")
                    )
                }
            }
            .accessibilityIdentifier("browser.detail")
        }
        .onChange(of: selectedGroupID) {
            // Switching groups can leave `selectedEntryID` pointing at an entry that's no longer
            // in view (or, for "All Entries", pointing at nothing new) — clear it so the detail
            // column never shows an entry the list column doesn't have selected any more.
            selectedEntryID = nil
        }
        // MARK: Menu-bar wiring
        //
        // The selection stays this view's own `@State` (the columns coordinate through it — see the
        // type's doc comment); what happens here is a one-way MIRROR of it into `AppEnvironment`,
        // which is the only thing `AppCommands` can see from outside the view tree. Without this,
        // Edit/Delete/Copy Username/Copy Password are permanently disabled no matter what is
        // selected, because their `.disabled(selectedEntry == nil)` reads a value nothing ever wrote.
        .onChange(of: selectedEntryID) {
            appEnvironment?.selectedEntryID = selectedEntryID
            // The idle countdown is only honest if something reports that the user is still here,
            // and `AutoLockController` deliberately has no global event monitor to notice on its own
            // (see its `init` doc comment on why observing system-wide input is the wrong ask for a
            // password manager). Moving through the list is the cheapest truthful signal this view
            // has; `noteActivity()` already no-ops while locked, so no guard is needed here.
            autoLock.noteActivity()
        }
        .onChange(of: searchText) { autoLock.noteActivity() }
        // Deliberately `.onAppear` rather than `.onChange(..., initial: true)`: this writes to an
        // `@Observable` the menu bar also reads, and the initial-fire variant runs inside the same
        // update pass that is producing this body. Establishing the starting value (nil) here keeps
        // a stale id from a previous unlock/lock cycle from outliving the browser that set it.
        .onAppear { appEnvironment?.selectedEntryID = selectedEntryID }
        // A lock (idle timer, "Lock Database", lid close) unmounts this view while `selectedEntryID`
        // is still set. Clearing the mirror here is what stops a menu command from acting on a
        // selection belonging to a vault that is no longer decrypted.
        .onDisappear { appEnvironment?.selectedEntryID = nil }
        .onChange(of: vault.entries.count) {
            // ⌫ in `AppCommands` calls `store.delete` directly and has no way to reach this view's
            // `@State`, so the deleted id would otherwise survive as a selection pointing at nothing.
            if let selectedEntryID, !vault.entries.contains(where: { $0.id == selectedEntryID }) {
                self.selectedEntryID = nil
            }
        }
        .onChange(of: menuRequest) { _, request in handle(request) }
        // These buttons carry NO `.keyboardShortcut` except the generator's. Every other shortcut
        // they used to declare is also declared by `AppCommands` — and ⌘N meant two different things
        // in the two places (New Database in the menu, New Entry here), which is a conflict, not a
        // duplicate. `AppCommands` is the single keyboard surface; the toolbar is the pointer
        // surface. ⌘⇧G stays because the generator has no menu item at all, so this is its only binding.
        .toolbar {
            ToolbarItemGroup {
                Button {
                    editingEntry = EditingEntry(entry: makeBlankEntry(), isNew: true)
                } label: {
                    Label("New Entry", systemImage: "plus")
                }
                .accessibilityIdentifier("browser.newEntry")

                Button(role: .destructive) {
                    guard let selectedEntryID else { return }
                    requestDelete(selectedEntryID)
                } label: {
                    Label("Delete Entry", systemImage: "trash")
                }
                .accessibilityIdentifier("browser.deleteEntry")
                .disabled(selectedEntryID == nil)

                Button {
                    showingGenerator = true
                } label: {
                    Label("Generator", systemImage: "wand.and.stars")
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])

                Button {
                    store.lock()
                } label: {
                    Label("Lock", systemImage: "lock")
                }
                .accessibilityIdentifier("browser.lock")

                Button {
                    Task { await store.save() }
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .accessibilityIdentifier("browser.save")
                .disabled(!store.isDirty)
            }
        }
        .sheet(item: $editingEntry) { editing in
            EntryEditView(
                entry: editing.entry,
                isNew: editing.isNew,
                store: store,
                clipboard: clipboard,
                generator: generator,
                onSave: { saved in selectedEntryID = saved.id },
                onDismiss: { editingEntry = nil }
            )
        }
        .confirmationDialog(
            "Delete Permanently?",
            isPresented: Binding(
                get: { pendingPermanentDeletion != nil },
                set: { if !$0 { pendingPermanentDeletion = nil } }
            ),
            presenting: pendingPermanentDeletion
        ) { entry in
            Button("Delete Permanently", role: .destructive) {
                store.permanentlyDelete(entryID: entry.id)
                if selectedEntryID == entry.id { selectedEntryID = nil }
                pendingPermanentDeletion = nil
            }
            .accessibilityIdentifier("browser.confirmPermanentDelete")
            Button("Cancel", role: .cancel) { pendingPermanentDeletion = nil }
        } message: { entry in
            Text(
                "“\(entry.title.isEmpty ? "Untitled" : entry.title)” is already in the Recycle Bin. "
                    + "Deleting it now removes it from this database for good — there is no undo."
            )
        }
        .confirmationDialog(
            "Empty Recycle Bin?",
            isPresented: $isConfirmingEmptyRecycleBin
        ) {
            Button("Empty Recycle Bin", role: .destructive) {
                store.emptyRecycleBin()
                selectedEntryID = nil
            }
            .accessibilityIdentifier("browser.confirmEmptyRecycleBin")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Everything in the Recycle Bin is removed from this database for good. "
                    + "There is no undo."
            )
        }
        .sheet(isPresented: $showingGenerator) {
            // Opened from the toolbar, with no target field to fill — "Use" here just copies to
            // the clipboard and closes, same as "Copy" without the extra click. The field-filling
            // meaning of "Use" only exists at `EntryEditView`'s own "Generate…" call site.
            GeneratorSheet(generator: generator, clipboard: clipboard, onUse: { clipboard.copy($0) })
        }
        // Both countdowns are live values, not placeholders: `AutoLockController` and
        // `ClipboardService` are each `@Observable` and tick their own published second counters, so
        // reading them straight out of the body is what re-renders this bar once per second. `nil`
        // in either slot means "not counting" — locked/stopped for auto-lock, nothing of ours on the
        // pasteboard for the clipboard (`secondsRemaining` reports that as `0`, which `StatusBar`
        // asks the caller to collapse to `nil`).
        .safeAreaInset(edge: .bottom) {
            StatusBar(
                databasePath: store.currentURL?.path ?? "",
                isDirty: store.isDirty,
                secondsUntilAutoLock: autoLock.secondsUntilIdleLock,
                secondsUntilClipboardClear: clipboard.secondsRemaining > 0 ? clipboard.secondsRemaining : nil
            )
        }
    }

    /// Read through a computed property rather than `onChange(of: appEnvironment?.menuRequest)` so
    /// the observed value is a plain `MenuRequest?` instead of a doubly-optional
    /// `MenuRequest??` that would compare "no environment" equal to "no request pending".
    private var menuRequest: MenuRequest? { appEnvironment?.menuRequest }

    /// Acts on a menu command that needs THIS view's own state to do its job — a sheet's
    /// presentation flag, the search field's focus — and then clears the request, which is what
    /// makes a second identical command (⌘⇧N twice in a row) register as a new change rather than
    /// being swallowed as "same value".
    private func handle(_ request: MenuRequest?) {
        guard let request, let appEnvironment else { return }
        switch request {
        case .newEntry:
            editingEntry = EditingEntry(entry: makeBlankEntry(), isNew: true)
        case .editEntry(let id):
            openForEdit(id)
        case .deleteEntry(let id):
            requestDelete(id)
        case .emptyRecycleBin:
            isConfirmingEmptyRecycleBin = true
        case .focusSearch:
            isSearchFocused = true
        case .openDatabase, .newDatabase:
            // `WelcomeView`'s cases. It is never mounted at the same time as this view (`RootView`
            // switches on `store.state`), so returning without clearing is correct — clearing here
            // would only ever discard a request its real owner has not seen yet.
            return
        }
        appEnvironment.menuRequest = nil
    }

    /// The single entry point for deleting an entry from this screen — the toolbar button and the
    /// ⌫ menu command both land here.
    ///
    /// A first delete MOVES the entry into the recycle bin: nothing is lost, the entry is still
    /// there to drag back out, so asking would be ceremony for an undoable act. A delete of
    /// something already in the bin is the destructive one, and that always goes through the
    /// confirmation below — never straight to the store. `VaultStore.plannedDeletion` is what
    /// decides which of the two this is, so the rule lives in one place rather than being
    /// re-derived by every caller.
    ///
    /// The selection is deliberately NOT cleared on a recycle: the entry still exists, and leaving
    /// it selected is what shows the user where it went.
    private func requestDelete(_ id: UUID) {
        switch store.plannedDeletion(forEntry: id) {
        case .recycled:
            store.delete(entryID: id)
            // The entry moved into the bin, so unless the bin is what is on screen it just left
            // the list column — and a selection pointing at a row the list no longer shows leaves
            // the detail column displaying an entry the user cannot see selected anywhere. The
            // existing `onChange(of: vault.entries.count)` cleanup cannot catch this: the count
            // did not change, only the placement did.
            let stillVisible = EntryListFilter
                .apply(to: vault, groupID: selectedGroupID, query: searchText)
                .contains { $0.id == id }
            if !stillVisible { selectedEntryID = nil }
        case .permanent:
            pendingPermanentDeletion = vault.entries.first { $0.id == id }
        case nil:
            return
        }
    }

    private func openForEdit(_ id: UUID) {
        guard let entry = vault.entries.first(where: { $0.id == id }) else { return }
        editingEntry = EditingEntry(entry: entry, isNew: false)
    }

    /// A brand-new entry starts inside whatever group is currently selected — the natural
    /// "New Entry" expectation is that it lands where you're already looking, not always at the
    /// vault's top level regardless of context. `id`/`created`/`modified` are placeholders:
    /// `VaultStore.upsert` treats this as an insert (no existing entry with that `id`) and stamps
    /// `modified` itself.
    private func makeBlankEntry() -> VaultEntry {
        let now = Date()
        return VaultEntry(
            id: UUID(),
            groupID: selectedGroupID,
            title: "",
            username: "",
            password: "",
            url: "",
            notes: "",
            otpAuthURL: nil,
            customFields: [:],
            created: now,
            modified: now
        )
    }
}

#Preview {
    let codec = InMemoryVaultCodec()
    let fileAccess = InMemoryVaultFileAccess()
    let credentials = VaultCredentials(password: "preview", keyFile: nil)
    let url = URL(fileURLWithPath: "/tmp/preview.kdbx")
    // Round-trip `Vault.sample` through the fakes exactly the way a real launch would (encode,
    // write, then `open` decodes it back) rather than reaching for `createNew`, which only ever
    // produces an EMPTY vault — this preview needs real sample data to be useful.
    let encoded = try! codec.encode(.sample, credentials: credentials, origin: nil)
    _ = try! fileAccess.write(encoded, to: url)
    let store = VaultStore(codec: codec, fileAccess: fileAccess)
    Task { @MainActor in await store.open(url: url, credentials: credentials) }

    return VaultBrowserView(
        store: store,
        clipboard: ClipboardService(),
        generator: PasswordGenerator(),
        autoLock: AutoLockController(onLock: { [weak store] in store?.lock() })
    )
}
