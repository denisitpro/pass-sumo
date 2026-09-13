import SwiftUI

/// The browser — group sidebar, entry list, entry detail. This is "the screen the user lives in"
/// (per the UI brief this file was written against): everything else in the app is a doorway into
/// or out of it.
///
/// **Two `NavigationSplitView` columns, not three** (issue #49). The entry detail used to be a
/// third `detail:` column, but `NavigationSplitView`'s `columnVisibility` binding on macOS only
/// ever controls the leading columns — there is no first-class way to give the trailing column a
/// show/hide control, which is exactly the gap the owner hit ("the sidebar collapses, why doesn't
/// the right pane?"). Moving entry detail into `.inspector(isPresented:)` instead gives it a real,
/// system-provided show/hide for free, plus a natural place to hang a toolbar toggle and a
/// keyboard shortcut. `isDetailPaneVisible` is that binding.
///
/// Owns ALL cross-column state itself (`selectedGroup`, `selectedEntryID`, `searchText`) rather
/// than letting each column keep its own — a group change has to clear which entry is selected
/// (see the `.onChange(of: selectedGroup)` below), and that coordination only works if one view
/// is the single source of truth for both.
struct VaultBrowserView: View {
    let store: VaultStore
    let clipboard: ClipboardService
    let generator: PasswordGenerator
    /// Read for `noteActivity()`, and told when the toolbar's Lock button is pressed — this view
    /// still never locks anything itself, it reports the request and the controller performs the
    /// lock through its own `onLock` (see `lockRequestedByUser()`). `StatusBar` stopped reading its
    /// countdown when that readout was removed (issue #101); this is a constructor parameter rather
    /// than an environment read for the same reason as before — an environment lookup that silently
    /// resolves to nothing would let the activity-reporting and the Lock button go quietly inert.
    let autoLock: AutoLockController
    /// Read for the generator's saved recipe (`settings.generatorRecipe`, issue #106) — a
    /// constructor parameter for the same reason as `autoLock` above rather than fished out of
    /// `appEnvironment`, so a missing/misconfigured environment can't silently fall the generator
    /// back to `PasswordGenerator.Recipe()`'s hardcoded default the way it already did once. A
    /// reference to `AppSettings` itself, not a `Recipe` snapshot: this view is long-lived for the
    /// whole unlocked session, and the generator sheet is opened fresh from a `.sheet` closure that
    /// reads `settings.generatorRecipe` at presentation time, so a change made in Settings while the
    /// vault stays open is picked up on the next open without this view ever needing to re-render.
    let settings: AppSettings

    /// Optional on purpose: `RootView` always injects it, but the `#Preview` below (and any future
    /// one) constructs this view standalone, and a non-optional `@Environment(AppEnvironment.self)`
    /// traps at render time when nothing supplied it. Everything read off it is menu-bar wiring,
    /// which a preview has no menu bar for anyway.
    @Environment(AppEnvironment.self) private var appEnvironment: AppEnvironment?

    /// Optional because that is what a macOS `List(selection:)` binds to — `nil` is its "nothing is
    /// selected", which ⌘-clicking the selected row produces. It starts at `.allEntries` so the
    /// screen opens on the unfiltered list with that row visibly picked; see `GroupSelection` for
    /// why "All Entries" is a case of its own rather than the `nil` it used to be (issue #85).
    @State private var selectedGroup: GroupSelection? = .allEntries
    @State private var selectedEntryID: UUID?
    /// **Issue #34: nothing in this file may clear this as a side effect of opening an entry.**
    /// `openForEdit(_:)` only ever assigns `editingEntry`; selecting a row only ever assigns
    /// `selectedEntryID`. Neither touches `searchText`, and that absence of a code path IS the
    /// fix — the natural "type a query, look at a result, go back, look at the next" flow needs
    /// the query to survive every entry it opens along the way. The two moments that legitimately
    /// DO clear it are the user's own action on the search field (Escape — see `searchField`) and a
    /// lock, which the `.empty`/`.locked` switch in `RootView` handles for free: it unmounts this
    /// whole view, and remounting it after the next unlock starts a fresh `@State` at `""`.
    /// Shipping this as a preference — as Strongbox once did — is explicitly what issue #34
    /// rejects; there is no toggle to keep in sync.
    @State private var searchText = ""
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Whether the entry-detail inspector is shown. Seeded from `AppSettings.detailPaneVisible` on
    /// appear and mirrored back on change (same one-way-mirror pattern the menu-bar wiring below
    /// uses for `selectedEntryID`) rather than reading `appEnvironment` directly in the binding
    /// passed to `.inspector` — `.inspector` needs a plain `Binding<Bool>` it can write to on every
    /// toggle, and `appEnvironment` is `nil` in the `#Preview` below and in any other context with
    /// no environment, where this still needs to work with a sensible default.
    @State private var isDetailPaneVisible = true
    @State private var showingGenerator = false
    @State private var editingEntry: EditingEntry?
    /// The entry a permanent delete has been requested for, held until the user confirms. Nothing
    /// destroys an entry without passing through here first — see `requestDelete(_:)`.
    @State private var pendingPermanentDeletion: VaultEntry?
    /// The folder a permanent delete has been requested for. Its own property rather than one
    /// shared with the entry above: the two dialogs say different things — a folder takes its whole
    /// subtree with it — and a single property holding either would turn "which am I confirming"
    /// into a question the view has to answer at render time.
    @State private var pendingPermanentGroupDeletion: VaultGroup?
    @State private var isConfirmingEmptyRecycleBin = false
    @State private var groupNamePrompt: GroupNamePrompt?
    /// The text in the rename prompt. Seeded from the folder's current name when the prompt
    /// opens rather than being derived, because a `TextField` needs somewhere of its own to put
    /// what the user types. Create no longer uses this — that path is `GroupEditSheet`.
    @State private var groupNameDraft = ""
    /// Create-folder sheet (issue #129). Its own state rather than a case of `groupNamePrompt`,
    /// because create is a real sheet with a name and an icon, and rename stays the name-only
    /// alert. `Identifiable` so `.sheet(item:)` cannot re-present a cancelled draft.
    @State private var newGroupRequest: NewGroupRequest?
    /// The folder whose icon picker is open (issue #89). The folder itself rather than its id, so
    /// the sheet can read the icon currently in effect without looking it up again — and
    /// `Identifiable`, so it drives `.sheet(item:)` and cannot re-present a folder that has since
    /// been deleted, the same reason `editingEntry` is shaped that way.
    ///
    /// A sheet rather than a submenu of 69 items inside the context menu already open: a menu that
    /// long is unusable, and a grid is the shape the choice has.
    @State private var groupIconTarget: VaultGroup?
    /// What the Focus Search command (⌘F, declared once in `AppCommands`) moves focus TO, and what
    /// `searchField` draws its focus ring from. It was already this view's own `@FocusState` when
    /// the field was `.searchable`'s; replacing that with a hand-rolled field (issue #87) swapped
    /// `.searchFocused` for a plain `.focused` and changed nothing else about the shortcut.
    @FocusState private var isSearchFocused: Bool

    init(
        store: VaultStore,
        clipboard: ClipboardService,
        generator: PasswordGenerator,
        autoLock: AutoLockController,
        settings: AppSettings
    ) {
        self.store = store
        self.clipboard = clipboard
        self.generator = generator
        self.autoLock = autoLock
        self.settings = settings
    }

    /// Factored out of `body`'s `.sheet(isPresented: $showingGenerator)` closure purely so the
    /// wiring is assertable without rendering (issue #106) — a test constructs a `VaultBrowserView`
    /// with a `settings` whose `generatorRecipe` is known, calls this directly, and checks the
    /// result's `openingRecipe`. If this ever goes back to hardcoding
    /// `GeneratorSheet(generator:, clipboard:)` with no `recipe:`, that assertion fails instead of
    /// the bug shipping invisibly again.
    func makeGeneratorSheet() -> GeneratorSheet {
        GeneratorSheet(
            generator: generator,
            recipe: settings.generatorRecipe,
            clipboard: clipboard,
            // Issue #129: a tweak in this sheet is the saved default, not a one-off. The
            // callback is the only write — GeneratorSheet never touches UserDefaults itself.
            onRecipeChanged: { settings.generatorRecipe = $0 }
        )
    }

    /// What `EntryEditView` is editing right now: a brand-new entry, or an existing one opened for
    /// edit. `Identifiable` so it can drive `.sheet(item:)`, which (unlike `.sheet(isPresented:)`)
    /// can't accidentally re-present stale state left over from a previously edited entry.
    private struct EditingEntry: Identifiable {
        var entry: VaultEntry
        var isNew: Bool
        var id: UUID { entry.id }
    }

    /// Rename's name-only alert. Create used to share this type (they asked the same question
    /// through the same single control); issue #129 split them because create now also picks an
    /// icon, which an `NSAlert` cannot host.
    private enum GroupNamePrompt: Equatable {
        case rename(UUID)
    }

    /// One presentation of `GroupEditSheet`. `id` is minted at construction so `.sheet(item:)`
    /// treats two consecutive creates as two items even when they share a parent.
    private struct NewGroupRequest: Identifiable {
        let parentID: UUID?
        let id = UUID()
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

    /// The selection the rest of the screen filters by. An empty sidebar selection resolves to
    /// "show everything" — that is what the list showed before anything was picked, and it is the
    /// only answer that cannot leave the user staring at a column filtered to nothing they chose.
    private var groupSelection: GroupSelection { selectedGroup ?? .allEntries }

    private var selectedEntry: VaultEntry? {
        guard let selectedEntryID else { return nil }
        return vault.entries.first { $0.id == selectedEntryID }
    }

    /// The trailing column: the entry list, with the entry detail hanging off it as an inspector.
    ///
    /// A named member rather than written inline in `body`'s `detail:` closure, and not as a style
    /// preference: `body` is long enough that the Swift type-checker gives up on the whole
    /// expression ("unable to type-check this expression in reasonable time") once anything more is
    /// added to it. Splitting a chunk out gives the solver a boundary it can finish inside.
    private var detailColumn: some View {
        EntryListView(
            vault: vault,
            selection: groupSelection,
            searchText: $searchText,
            selectedEntryID: $selectedEntryID,
            onOpenEntry: { id in openForEdit(id) },
            onCopyUsername: { entry in clipboard.copy(entry.username) },
            onCopyPassword: { entry in clipboard.copy(entry.password) },
            onDeleteEntry: { id in requestDelete(id) },
            onNewEntry: startNewEntry
        )
        .inspector(isPresented: $isDetailPaneVisible) {
            Group {
                if let selectedEntry {
                    EntryDetailView(
                        entry: selectedEntry,
                        clipboard: clipboard,
                        isLocked: isLocked,
                        // The one capability the detail view needs from the vault, handed over
                        // as a function instead of the vault itself — see its
                        // `resolveAttachment`.
                        resolveAttachment: { vault.bytes(for: $0) },
                        onEdit: { openForEdit(selectedEntry.id) }
                    )
                } else {
                    ContentUnavailableView(
                        "No Entry Selected",
                        systemImage: "lock.doc",
                        description: Text("Choose an entry from the list.")
                    )
                    .foregroundStyle(Palette.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.surface)
            .accessibilityIdentifier("browser.detail")
            // On the inspector's CONTENT, which is where this modifier is read from — not on
            // the view carrying `.inspector` itself.
            //
            // Without a width range the inspector sits at SwiftUI's unconfigured default and
            // its divider does not drag at all (issue #86). The three numbers are measured
            // against what `EntryDetailView` actually renders, not copied from another app:
            //
            // **min 400.** The pane's one row that cannot reflow is `TOTPView`: an `HStack` of
            // fixed-size parts with no flexible member. At the widest code an `otpauth://` URI
            // may ask for (8 digits) it measures 343pt — "One-time" 53 + `s5` + the code 111
            // plus 18 of `tracking` + `s5` + the 40pt progress bar + `s5` + the 24pt seconds
            // slot + `s5` + a 24pt copy glyph + `s5` of well padding each side — and the pane
            // adds `s7` of its own padding on both sides, putting the clipping floor at 383.
            // 400 is that floor rounded up. Everything else reflows: a `FieldRow` value wraps,
            // an attachment preview is capped at 220, the header title truncates to one line.
            //
            // **ideal 480.** The width `EntryDetailView`'s own `#Preview` frames at, i.e. the
            // one this layout was eyeballed against. It is also where the Metadata section's
            // KDBX entry UUID — 289pt of 13pt monospace, the longest fixed string in the pane
            // — first fits beside its 90pt label on one line (431pt needed).
            //
            // **max 640.** Past this the extra width reaches only wrapped prose: at 640 a
            // Notes value already runs about 81 characters per line, which is past a
            // comfortable measure rather than short of one. Everything else — labels, glyphs,
            // the preview cap — is fixed and stops using the room long before.
            .inspectorColumnWidth(min: 400, ideal: 480, max: 640)
        }
    }

    /// The screen itself — the two columns, their toolbar, and the state each column has to keep in
    /// step with the other. Everything this screen *presents* on top of it (the edit sheet, the
    /// generator, the confirmations, the status bar) is chained onto it in `body`.
    ///
    /// The split is not decorative: written as one chain, `body` is past what the Swift type-checker
    /// will finish ("unable to type-check this expression in reasonable time"), and it fails on
    /// whichever link it happened to give up inside rather than on the one just added. Keep the two
    /// halves roughly balanced when adding to either.
    private var browserContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            GroupSidebar(
                vault: vault,
                selection: $selectedGroup,
                onEmptyRecycleBin: { isConfirmingEmptyRecycleBin = true },
                onGroupCommand: { handle($0) },
                onDropEntry: handleEntryDrop
            )
            .accessibilityIdentifier("browser.sidebar")
            // Same rule as the inspector's `.inspectorColumnWidth` below (issue #86): without a
            // width range this column sits at SwiftUI's unconfigured default and its divider does
            // not drag at all (issue #101). The numbers are measured against what `GroupSidebar`
            // actually renders (`measure_sidebar.swift`, AppKit `NSAttributedString.size()` against
            // the exact `Typography`/`Metrics` tokens the row uses), not copied from another app:
            //
            // **min 165.** The two things this column must never truncate are its fixed system
            // rows — "All Entries" and "Recycle Bin" are product-chosen labels, not user data, so
            // they get the same "must always read cleanly" treatment `EntryDetailView`'s TOTP row
            // got — and the entry-count column beside them. At `Typography.bodyMedium` (the font a
            // SELECTED row uses) "Recycle Bin" is the wider of the two, at 71.6pt; a live vault's
            // count can plausibly run to 3 digits (repo CLAUDE.md: "managing hundreds of
            // passwords"), 20.4pt at `Typography.monoCaption2`. Add the fixed row furniture around
            // them — `Metrics.rowIconSlot` (20) + the icon/label `Spacing.s3` gap (6) + the
            // label/count `Spacer(minLength: Spacing.s2)` (4) + the row's own `Spacing.s3` padding
            // on both sides (12, from `SidebarRowSurface`) — and the content itself needs 134pt.
            // The rest of the number is the one thing this measurement script cannot see: `List`'s
            // own `.sidebar`-style margin and the leading indent `OutlineGroup` reserves for a
            // disclosure triangle once any group has a subgroup (very plausible for this app's own
            // "hundreds of passwords, organized" user) — estimated, not measured, at 31pt. Dragging
            // the divider to its stop in the running app confirms the column clamps at exactly this
            // 165 (read back via Accessibility Inspector: `{58, 58}, {165, 596}`) with no truncation
            // for the fixture's own (shorter) group names; the "Recycle Bin"-length worst case above
            // is the content math, not a screen a full pass happened to land on.
            //
            // **ideal 220.** No mockup constrains this (`design/mockups/palette-variants.html` is a
            // palette reference only — see `claude-memory/pass-sumo-design-system-docs.md`), so this
            // is the conventional macOS Finder/Mail sidebar width: comfortably wider than a typical
            // real group name (e.g. "Passwords" at 64.8pt) plus its count, with room to spare before
            // anything has to reflow.
            //
            // **max 320.** A sidebar row carries far less than the inspector's prose-bearing fields
            // — a short label and a number, nothing that benefits from wrapping — so it is capped at
            // about half the inspector's 640: past this point extra width only stretches empty
            // trailing space between a group's name and its count.
            .navigationSplitViewColumnWidth(min: 165, ideal: 220, max: 320)
        } detail: {
            detailColumn
                // Without a floor this column can be dragged to zero and SwiftUI crashes
                // (issue #139). 165 + 220 + 400 = 785, which still fits the browser window's
                // 900pt minimum.
                .navigationSplitViewColumnWidth(min: 220, ideal: 360)
        }
        // The toolbar shares the sidebar's tone, as the mockup's `.toolbar` does — otherwise the
        // window's chrome is the one band still painted by the system.
        .toolbarBackground(Palette.sidebar, for: .windowToolbar)
        .onAppear {
            isDetailPaneVisible = appEnvironment?.settings.detailPaneVisible ?? true
        }
        .onChange(of: isDetailPaneVisible) { _, newValue in
            appEnvironment?.settings.detailPaneVisible = newValue
        }
        .onChange(of: selectedGroup) {
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
        .onChange(of: vault.groups.count) {
            // A folder can vanish out from under the selection two ways — permanently deleted, or
            // emptied away with the recycle bin it was sitting in — and a selection pointing at a
            // group that no longer exists filters the list column to nothing, with no row
            // highlighted to explain why. Same shape as the entry cleanup above, and for the same
            // reason: the code that removed the group cannot reach this view's `@State`.
            if let id = selectedGroup?.containingGroupID,
               !vault.groups.contains(where: { $0.id == id }) {
                selectedGroup = .allEntries
            }
        }
        .onChange(of: menuRequest) { _, request in handle(request) }
        // These buttons carry NO `.keyboardShortcut` except the generator's and the detail-pane
        // toggle's. Every other shortcut they used to declare is also declared by `AppCommands` —
        // and ⌘N meant two different things in the two places (New Database in the menu, New Entry
        // here), which is a conflict, not a duplicate. `AppCommands` is the single keyboard surface;
        // the toolbar is the pointer surface. ⌘⇧G stays because the generator has no menu item at
        // all, so this is its only binding — same reasoning for ⌥⌘I below (issue #49): toggling the
        // inspector is this view's own `@State`, with no menu-bar equivalent to conflict with.
        .toolbar {
            // `.principal` is the toolbar's centre on macOS, and a centred item is the whole point
            // of issue #87 — `.searchable`'s own placements cannot reach it. Declared before the
            // button group only for readability; the system positions it, not the declaration
            // order.
            ToolbarItem(placement: .principal) {
                searchField
            }

            // Own `.primaryAction` item, not a member of the group below. A centred `.principal`
            // search field eats the automatic-placement overflow on a normal window, which is how
            // Lock disappeared behind the chevron (issue #129). `.primaryAction` is the trailing
            // slot that does not overflow. No `.keyboardShortcut` here: `AppCommands` already
            // binds ⌘L (Strongbox, issue #16).
            ToolbarItem(placement: .primaryAction) {
                Button {
                    // The controller, not `store.lock()` — see `AutoLockController.lockRequestedByUser()`.
                    // This is the one thing this view does through `autoLock` besides reading its
                    // countdown, and it is not "this view locks the vault": it reports that the
                    // user asked, and the controller's `onLock` is still what performs it.
                    autoLock.lockRequestedByUser()
                } label: {
                    Label("Lock", systemImage: "lock")
                }
                .accessibilityIdentifier("browser.lock")
            }

            ToolbarItemGroup {
                Button {
                    startNewEntry()
                } label: {
                    Label("New Entry", systemImage: "plus")
                }
                .accessibilityIdentifier("browser.newEntry")

                Button {
                    handle(.create(parentID: newGroupParentID))
                } label: {
                    Label("New Group", systemImage: "folder.badge.plus")
                }
                .accessibilityIdentifier("browser.newGroup")

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
                    Task { await store.save() }
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .accessibilityIdentifier("browser.save")
                .disabled(!store.isDirty)

                Button {
                    isDetailPaneVisible.toggle()
                } label: {
                    Label(
                        isDetailPaneVisible ? "Hide Detail" : "Show Detail",
                        systemImage: "sidebar.trailing"
                    )
                }
                // ⌥⌘I is the platform convention for toggling an inspector (Safari's Web Inspector
                // uses the same binding, for the same action, in a different app). Checked against
                // `AppCommands.swift`: nothing there binds "i" or uses `.option` at all, so this
                // does not collide with anything already in this app.
                .keyboardShortcut("i", modifiers: [.command, .option])
                .accessibilityIdentifier("browser.toggleDetail")
            }
        }
    }

    var body: some View {
        browserContent
            .sheet(item: $editingEntry) { editing in
                EntryEditView(
                    entry: editing.entry,
                    isNew: editing.isNew,
                    store: store,
                    clipboard: clipboard,
                    generator: generator,
                    // Read here, inside the sheet's own content closure — which SwiftUI re-invokes
                    // fresh every time `editingEntry` becomes non-nil — so this always reflects
                    // whatever was most recently saved in Settings, not a value snapshotted once
                    // when `VaultBrowserView` itself was constructed (issue #106).
                    generatorRecipe: settings.generatorRecipe,
                    onSave: { saved in selectedEntryID = saved.id },
                    onDismiss: { editingEntry = nil },
                    onRecipeChanged: { settings.generatorRecipe = $0 }
                )
            }
            // A folder's icon commits straight through the store, unlike an entry's, which the
            // edit form holds as a draft until Save. That is not an inconsistency in the picker: a
            // folder has no form and no Save, so its context menu behaves the way "Move to" beside
            // it already does — the click IS the commit, and Esc backs out having changed nothing.
            .sheet(item: $groupIconTarget) { group in
                IconPickerSheet(
                    title: "Folder Icon",
                    selectedIconID: group.iconID,
                    onPick: { store.setGroupIcon(group.id, to: $0) }
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
            .sheet(item: $newGroupRequest) { request in
                GroupEditSheet { name, iconID in
                    commitNewGroup(named: name, iconID: iconID, parentID: request.parentID)
                }
            }
            // No disabled state on Rename. An alert's buttons are rendered by AppKit from a
            // description, not laid out as views, so `.disabled` on one is not reliably honoured —
            // and it is not needed: `VaultStore.renameGroup` refuses a blank name itself, so
            // confirming an empty field closes the alert and changes nothing. Create is a real
            // sheet (`GroupEditSheet`) and disables its own button instead.
            .alert(
                "Rename Group",
                isPresented: isShowingGroupNamePrompt,
                presenting: groupNamePrompt
            ) { prompt in
                TextField("Name", text: $groupNameDraft)
                    .accessibilityIdentifier("browser.groupName")
                Button("Rename") { commitGroupName(prompt) }
                    .accessibilityIdentifier("browser.confirmGroupName")
                Button("Cancel", role: .cancel) { groupNamePrompt = nil }
            }
            .confirmationDialog(
                "Delete Folder Permanently?",
                isPresented: isShowingPermanentGroupDeletion,
                presenting: pendingPermanentGroupDeletion
            ) { group in
                Button("Delete Permanently", role: .destructive) {
                    store.permanentlyDelete(groupID: group.id)
                    pendingPermanentGroupDeletion = nil
                }
                .accessibilityIdentifier("browser.confirmPermanentGroupDelete")
                Button("Cancel", role: .cancel) { pendingPermanentGroupDeletion = nil }
            } message: { group in
                Text(Self.permanentGroupDeletionMessage(for: group))
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
                // Opened from the toolbar, with no target field to fill — `onUse` is `nil` so
                // `GeneratorSheet` hides "Use" entirely rather than offering a button that just
                // duplicates "Copy" with no explanation (issue #45). The field-filling meaning of
                // "Use" only exists at `EntryEditView`'s own "Generate…" call site.
                makeGeneratorSheet()
            }
            // The clipboard countdown is a live value, not a placeholder: `ClipboardService` is
            // `@Observable` and ticks its own published second counter, so reading it straight out of
            // the body is what re-renders this bar once per second. `nil` means "not counting" —
            // nothing of ours is on the pasteboard (`secondsRemaining` reports that as `0`, which
            // `StatusBar` asks the caller to collapse to `nil`). The auto-lock countdown that used to
            // sit beside it was removed from `StatusBar` (issue #101) — see that type's doc comment
            // on `secondsUntilClipboardClear` for why one countdown stayed and the other didn't.
            .safeAreaInset(edge: .bottom) {
                StatusBar(
                    databasePath: store.currentURL?.path ?? "",
                    isDirty: store.isDirty,
                    secondsUntilClipboardClear: clipboard.secondsRemaining > 0 ? clipboard.secondsRemaining : nil,
                    // A failed pre-save backup no longer blocks the save (issue #26), so this is the
                    // one place the user learns it happened. Persistent rather than a transient alert:
                    // the condition persists — an unwritable container fails every save — and an alert
                    // dismissed once would leave the app quietly saving without backups thereafter.
                    backupWarning: store.lastBackupError?.backupFailureMessage
                )
            }
    }

    /// One string, used as both the field's visible placeholder and its accessible name.
    private static let searchPrompt = "Search entries and passwords"

    /// The toolbar's search field — hand-rolled, because `.searchable`'s placement cannot be
    /// steered to the toolbar's centre, and centred is where Strongbox (this project's behavioural
    /// reference — see `claude-memory/pass-sumo-strongbox-is-the-reference.md`) puts it. Issue #87.
    ///
    /// What the system field gave for free, and what replaces it, one for one:
    ///
    /// - **⌘F.** Unchanged. `AppCommands` already owns the only "Focus Search" binding and raises
    ///   `.focusSearch`, which `handle(_:)` below turns into `isSearchFocused = true`. Nothing here
    ///   declares a shortcut — the toolbar is the pointer surface, `AppCommands` the keyboard one.
    /// - **Escape.** `.onExitCommand`, which is AppKit's `cancelOperation(_:)` reaching the focused
    ///   field through the responder chain — the hook Escape actually travels on in a text control,
    ///   unlike `.onKeyPress(.escape)`.
    /// - **Focus ring and ground.** The token layer's `.searchFieldChrome`, which composes the
    ///   `sunken` well the design system assigns this field with the one shared `FocusRing`. No
    ///   second ring is drawn here.
    ///
    /// The mockup's `.search` has no clear button and neither does this: Escape and ⌘A-delete are
    /// the two ways out, and adding a glyph the approved design does not show is not this issue's
    /// to decide.
    private var searchField: some View {
        HStack(spacing: Spacing.s3) {
            Image(systemName: "magnifyingglass")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)

            TextField(
                text: $searchText,
                // `text-2`, not the mockup's `text-3`: this placeholder sits on `sunken`, where
                // `text-3` measures 4.18:1 and misses WCAG AA. `design/BRAND.md`'s contrast rule
                // scopes `text-3` to `surface` only — which is why `MasterPasswordField`, whose
                // field IS on `surface`, keeps it and this one does not.
                prompt: Text(Self.searchPrompt).foregroundStyle(Palette.textSecondary)
            ) {
                // Carries the accessible name; macOS renders only `prompt`. Same reasoning as
                // `MasterPasswordField.fieldContent` — dropping it would leave the field unnamed to
                // VoiceOver as soon as the placeholder disappears behind typed text.
                Text(Self.searchPrompt)
            }
            .textFieldStyle(.plain)
            .font(Typography.caption)
            .foregroundStyle(Palette.text)
            .focused($isSearchFocused)
            .onExitCommand {
                searchText = ""
                isSearchFocused = false
            }
            // On the field itself, not on the column. Under `.searchable` this identifier sat on
            // the content column because the system's toolbar item did not inherit it, which is
            // the gap `Sources/UITests/README.md` recorded; a field of our own can carry it.
            .accessibilityIdentifier("browser.search")
        }
        .padding(.horizontal, Spacing.s3)
        .frame(width: Metrics.searchFieldWidth, height: Metrics.searchFieldHeight)
        .searchFieldChrome(isFocused: isSearchFocused)
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
            startNewEntry()
        case .newGroup:
            // Same call the toolbar's "New Group" button makes (see `newGroupParentID`'s own doc
            // comment for where the folder lands).
            handle(.create(parentID: newGroupParentID))
        case .editEntry(let id):
            openForEdit(id)
        case .deleteEntry(let id):
            requestDelete(id)
        case .emptyRecycleBin:
            isConfirmingEmptyRecycleBin = true
        case .focusSearch:
            isSearchFocused = true
        case .openDatabase, .newDatabase:
            // `RootView`'s cases. Clearing here would discard a request its owner has not acted
            // on yet — this view is mounted under RootView while a vault is unlocked, which is
            // exactly when those two items stay enabled (issue #84 / #165).
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
    /// The selection is dropped when the recycled entry leaves the visible list — which is the
    /// entire visible effect of a recycle: the row disappears and the detail column empties. It is
    /// kept when the bin itself is what is on screen, because there the entry has not gone
    /// anywhere the user cannot see, and following it is more useful than clearing.
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
                .apply(to: vault, selection: groupSelection, query: searchText)
                .contains { $0.id == id }
            if !stillVisible { selectedEntryID = nil }
        case .permanent:
            pendingPermanentDeletion = vault.entries.first { $0.id == id }
        case nil:
            return
        }
    }

    /// The two group dialogs' presentation bindings, and the sentence one of them shows, lifted
    /// out of `body` as named members.
    ///
    /// Not tidying: with all three written inline the Swift type-checker gives up on `body`
    /// altogether ("unable to type-check this expression in reasonable time"). Each nested
    /// `Binding(get:set:)` and each `+`-concatenated interpolation multiplies what it has to solve,
    /// and this `body` is already long. Anything added here should go the same way.
    private var isShowingGroupNamePrompt: Binding<Bool> {
        Binding(
            get: { groupNamePrompt != nil },
            set: { if !$0 { groupNamePrompt = nil } }
        )
    }

    private var isShowingPermanentGroupDeletion: Binding<Bool> {
        Binding(
            get: { pendingPermanentGroupDeletion != nil },
            set: { if !$0 { pendingPermanentGroupDeletion = nil } }
        )
    }

    private static func permanentGroupDeletionMessage(for group: VaultGroup) -> String {
        let name = group.name.isEmpty ? "Untitled" : group.name
        return "“\(name)” is already in the Recycle Bin. Deleting it now removes it, "
            + "every folder inside it and every entry they hold from this database for good — "
            + "there is no undo."
    }

    /// Where a group command from the sidebar's context menu or the toolbar is acted on.
    ///
    /// Create and rename stop here to ask for a name; move goes straight to the store, because
    /// `Vault.canMoveGroup` has already refused every illegal destination before the menu drew it;
    /// delete goes through `requestDeleteGroup`, which is where the confirmation rule lives.
    private func handle(_ command: GroupCommand) {
        switch command {
        case .create(let parentID):
            newGroupRequest = NewGroupRequest(parentID: parentID)
        case .rename(let id):
            guard let group = vault.group(id) else { return }
            groupNameDraft = group.name
            groupNamePrompt = .rename(id)
        case .changeIcon(let id):
            groupIconTarget = vault.group(id)
        case .move(let id, let parentID):
            store.moveGroup(id, under: parentID)
        case .delete(let id):
            requestDeleteGroup(id)
        }
    }

    /// Drop of a list row onto a sidebar folder (issue #142). Always goes through `VaultStore` —
    /// a view that wrote `groupID` itself would skip the recycle-bin rule and the dirty flag.
    ///
    /// Returns `true` when the payload names a real entry, even if the entry was already in that
    /// folder: a bounce-back on a legal destination reads as a broken drop, not as a no-op.
    private func handleEntryDrop(_ entryID: UUID, _ destination: GroupSelection) -> Bool {
        guard vault.entries.contains(where: { $0.id == entryID }) else { return false }
        _ = store.moveEntry(entryID, toGroup: destination.containingGroupID)
        // Same "the row left the visible list" cleanup as `requestDelete`: moving out of the
        // current filter (or into the bin while All Entries is selected) must not leave the
        // detail column pointing at an entry the list no longer shows. `entries.count` does
        // not change, so the existing onChange cannot catch this.
        let stillVisible = EntryListFilter
            .apply(to: vault, selection: groupSelection, query: searchText)
            .contains { $0.id == entryID }
        if !stillVisible, selectedEntryID == entryID {
            selectedEntryID = nil
        }
        return true
    }

    private func commitGroupName(_ prompt: GroupNamePrompt) {
        switch prompt {
        case .rename(let id):
            store.renameGroup(id, to: groupNameDraft)
        }
        groupNamePrompt = nil
    }

    /// Selecting the new folder is what makes "New Group" visibly do something: the row appears in
    /// the sidebar AND the list column switches to it, empty, ready for the entry the user is
    /// about to put there.
    private func commitNewGroup(named name: String, iconID: UInt32, parentID: UUID?) {
        if let created = store.addGroup(named: name, parentID: parentID, iconID: iconID) {
            selectedGroup = .group(created.id)
        }
        newGroupRequest = nil
    }

    /// Where a new folder created from the toolbar goes: under whatever the sidebar is pointed at —
    /// the same "it appears where you are already looking" rule `makeBlankEntry()` follows — except
    /// inside the recycle bin, where a brand-new folder would be born deleted. That falls back to
    /// the top level.
    private var newGroupParentID: UUID? {
        guard let id = groupSelection.containingGroupID,
              !vault.recycleBinGroupIDs.contains(id)
        else { return nil }
        return id
    }

    /// The single entry point for deleting a folder from this screen, applying the same three tiers
    /// `requestDelete` applies to an entry: a first delete moves the folder and everything in it to
    /// the recycle bin and asks nothing, a delete of something already in the bin is the destructive
    /// one and always goes through the confirmation, and the bin itself — or a folder the bin sits
    /// inside — is not deletable at all. `VaultStore.plannedDeletion(forGroup:)` decides which.
    ///
    /// Unlike an entry's, the selection is NOT dropped on a recycle. The folder is still on screen —
    /// a row under the bin, with its entries still in it — so following it is more useful than
    /// clearing. A permanent delete does remove the row, and `onChange(of: vault.groups.count)`
    /// above is what catches that.
    private func requestDeleteGroup(_ id: UUID) {
        switch store.plannedDeletion(forGroup: id) {
        case .recycled:
            store.delete(groupID: id)
        case .permanent:
            pendingPermanentGroupDeletion = vault.group(id)
        case nil:
            return
        }
    }

    private func startNewEntry() {
        editingEntry = EditingEntry(entry: makeBlankEntry(), isNew: true)
    }

    /// Copies the stored entry as-is. Must not generate a password — issue #147 pre-fills
    /// new entries only, and overwriting one the user already has is the defect that issue
    /// exists to avoid.
    private func openForEdit(_ id: UUID) {
        guard let entry = vault.entries.first(where: { $0.id == id }) else { return }
        editingEntry = EditingEntry(entry: entry, isNew: false)
    }

    /// A brand-new entry starts inside whatever group is currently selected — the natural
    /// "New Entry" expectation is that it lands where you're already looking, not always at the
    /// vault's top level regardless of context. `id`/`created`/`modified` are placeholders:
    /// `VaultStore.upsert` treats this as an insert (no existing entry with that `id`) and stamps
    /// `modified` itself.
    ///
    /// The password is pre-filled from the saved generator recipe (issue #147). Editing an
    /// existing entry never comes through here — `openForEdit` copies the stored entry as-is —
    /// so this cannot overwrite a password the user already has. If generate throws (no class
    /// enabled, CSPRNG down) the field stays empty rather than crashing; the user can still
    /// type or regenerate from the form. Notes-only entries may clear it before Save; this
    /// path does not force a password to exist forever.
    ///
    /// Internal rather than private so a unit test can construct a `VaultBrowserView` with a
    /// known recipe, call this directly, and check the password — same seam as `makeGeneratorSheet`.
    func makeBlankEntry() -> VaultEntry {
        let now = Date()
        let password = (try? generator.generate(settings.generatorRecipe)) ?? ""
        return VaultEntry(
            id: UUID(),
            groupID: groupSelection.containingGroupID,
            title: "",
            username: appEnvironment?.settings.defaultUsername ?? "",
            password: password,
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
        autoLock: AutoLockController(onLock: { [weak store] in store?.lock() }),
        settings: AppSettings()
    )
}
