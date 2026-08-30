import AppKit
import SwiftUI

/// A one-shot nudge from the menu bar to whichever view owns the UI a command needs but this file
/// does not: an editor sheet, a focused search field, a file-picker flow. Set by `AppCommands`,
/// observed and cleared (`environment.menuRequest = nil`) by the view that can act on it —
/// `WelcomeView` for the two database-picking cases, `VaultBrowserView` (owned separately) for the
/// entry/search ones. A menu command that can act entirely on its own (Save, Lock, Delete Entry,
/// Copy Username/Password) never goes through this — it calls straight into `VaultStore` /
/// `ClipboardService` instead. This exists only for the commands that need a specific view's own
/// state (a sheet's presentation flag, a `@FocusState`) to do their job.
enum MenuRequest: Equatable {
    case openDatabase
    case newDatabase
    case newEntry
    case editEntry(UUID)
    /// Delete goes through this channel even though `VaultStore.delete` needs nothing from a view,
    /// because deciding whether to delete at all can. `VaultStore.plannedDeletion` reports that
    /// deleting an entry ALREADY in the recycle bin is permanent, and a permanent delete must be
    /// confirmed — and the confirmation dialog belongs to `VaultBrowserView`, not to a `Commands`
    /// body that has no view to present from.
    case deleteEntry(UUID)
    /// Same reasoning as `deleteEntry`: emptying the bin destroys entries outright, so it has to
    /// pass through the view that owns the confirmation.
    case emptyRecycleBin
    case focusSearch
}

/// The app's keyboard-first command surface: every action here has a shortcut, per the brief that
/// this file is the keyboard-first surface for pass-sumo. A shortcut that could act on nothing
/// (no vault open, no entry selected) is disabled rather than left to silently no-op — see each
/// group's `enabled(for:)` below.
struct AppCommands: Commands {
    @Bindable var environment: AppEnvironment

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Database…") { environment.menuRequest = .newDatabase }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!canStartNewOrOpen)
            Button("Open Database…") { environment.menuRequest = .openDatabase }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(!canStartNewOrOpen)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") { Task { await environment.store.save() } }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!isUnlocked)
            Divider()
            Button("Lock Database") { environment.store.lock() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(!isUnlocked)
            Divider()
            // AppKit's own window action, dispatched through the responder chain (nil target) —
            // there is no `WindowGroup`-supplied Close item once this group is replaced, so this is
            // what keeps ⌘W working at all.
            Button("Close") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: .command)
        }

        // Deliberately `.after(.pasteboard)`, not `.replacing(.pasteboard)`: ⌘C stays the system
        // copy exactly as-is (see the brief) — these are two ADDITIONAL items with KeePassXC's own
        // long-standing bindings (⌘⇧B / ⌘⇧C), chosen so muscle memory from KeePassXC transfers
        // directly instead of the user having to relearn where "copy username" lives.
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Username") { copySelected(\.username) }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(selectedEntry == nil)
            Button("Copy Password") { copySelected(\.password) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(selectedEntry == nil)
        }

        CommandMenu("Entry") {
            Button("New Entry") { environment.menuRequest = .newEntry }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!isUnlocked)
            Button("Edit Entry") {
                if let id = environment.selectedEntryID { environment.menuRequest = .editEntry(id) }
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(selectedEntry == nil)
            Button("Delete Entry") {
                if let id = environment.selectedEntryID { environment.menuRequest = .deleteEntry(id) }
            }
            // Bare ⌫, matching the brief and Finder/Mail's own convention for "delete the selection"
            // — no ⌘ modifier, since this needs no muscle-memory bridge to another app.
            //
            // A bare ⌫ menu item is a known hazard: AppKit evaluates menu key equivalents BEFORE
            // the responder chain, so a Backspace typed into the search field can fire this instead
            // of editing the text. That is filed separately and is not made worse here — but note
            // what this binding now does. It used to call `store.delete` straight through, which
            // erased the entry. It now raises `.deleteEntry`, and `VaultBrowserView` moves the entry
            // to the recycle bin (undoable, no data lost) or, if it is already in the bin, asks
            // before destroying it. Whichever way the hazard is eventually fixed, the keystroke can
            // no longer silently take a password with it.
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(selectedEntry == nil)
            Divider()
            // Deliberately without a keyboard shortcut. The sidebar's context menu on the bin is
            // the discoverable path; this exists so the action is reachable without knowing to
            // right-click, and an unassigned destructive command cannot be hit by accident.
            Button("Empty Recycle Bin…") { environment.menuRequest = .emptyRecycleBin }
                .disabled(!hasRecycleBinContent)
        }

        CommandGroup(after: .toolbar) {
            Button("Focus Search") { environment.menuRequest = .focusSearch }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!isUnlocked)
        }
    }

    // MARK: - Enablement
    //
    // Not `private`: `AppShellTests` constructs an `AppCommands` value directly and reads these to
    // verify the enablement logic without driving any UI (XCUITest is for that) — see that file.

    var isUnlocked: Bool {
        if case .unlocked = environment.store.state { return true }
        return false
    }

    /// New/Open are scoped to "nothing open yet" — v1's `VaultStore` holds exactly one vault at a
    /// time and has no "replace the open one" flow, so offering these while a database is already
    /// picked, open, or mid-unlock would be a shortcut that either does nothing useful or needs a
    /// discard-changes prompt this app shell does not implement. A single `case .empty` check is
    /// enough now that picking a file goes through `VaultStore.select(url:)` and immediately lands
    /// in `.locked` — it used to also have to consult an app-level bridge that held the picked URL
    /// while `store.state` still read `.empty`.
    var canStartNewOrOpen: Bool {
        if case .empty = environment.store.state { return true }
        return false
    }

    /// Whether the open database has anything in its recycle bin. Drives the enablement of
    /// "Empty Recycle Bin…" so the item is not offered for a database that has no bin, or a bin
    /// that is already empty.
    var hasRecycleBinContent: Bool {
        guard case .unlocked(let vault) = environment.store.state else { return false }
        let binIDs = vault.recycleBinGroupIDs
        guard !binIDs.isEmpty else { return false }
        return vault.entries.contains { $0.groupID.map(binIDs.contains) == true }
    }

    var selectedEntry: VaultEntry? {
        guard case .unlocked(let vault) = environment.store.state,
              let id = environment.selectedEntryID
        else { return nil }
        return vault.entries.first { $0.id == id }
    }

    private func copySelected(_ field: (VaultEntry) -> String) {
        guard let entry = selectedEntry else { return }
        environment.clipboard.copy(field(entry))
    }
}
