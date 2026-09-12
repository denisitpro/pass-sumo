import AppKit
import SwiftUI

/// A one-shot nudge from the menu bar to whichever view owns the UI a command needs but this file
/// does not: an editor sheet, a focused search field, a file-picker flow. Set by `AppCommands`,
/// observed and cleared (`environment.menuRequest = nil`) by the view that can act on it —
/// `RootView` for `.openDatabase` (it is the only view mounted in every store state, and since
/// issue #84 that item is enabled while a vault is open), `WelcomeView` for `.newDatabase`,
/// `VaultBrowserView` (owned separately) for the entry/search ones. A menu command that can act
/// entirely on its own (Save, Lock, Delete Entry,
/// Copy Username/Password) never goes through this — it calls straight into `VaultStore` /
/// `ClipboardService` instead. This exists only for the commands that need a specific view's own
/// state (a sheet's presentation flag, a `@FocusState`) to do their job.
enum MenuRequest: Equatable {
    case openDatabase
    case newDatabase
    case newEntry
    /// Same reasoning as `newEntry`: creating a folder needs `VaultBrowserView`'s own
    /// `groupNamePrompt` state (the name-entry alert), which this file has no view to present.
    case newGroup
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
            // Issue #16: matches Strongbox, which has NO binding at all for "create a database" —
            // a once-in-a-lifetime action — and spends the cheap ⌘N chord on "create an entry"
            // instead, the thing a user actually does hundreds of times. ⌘⇧N here mirrors that
            // priority rather than keeping the once-in-a-lifetime action on the cheap chord.
            Button("New Database…") { environment.menuRequest = .newDatabase }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!canCreateNewDatabase)
            Button("Open Database…") { environment.menuRequest = .openDatabase }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(!canOpenDatabase)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") { Task { await environment.store.save() } }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!isUnlocked)
            Divider()
            // Deliberately without a keyboard shortcut, same reasoning as "Empty Recycle Bin…"
            // below: this is a disclosure command reached a handful of times in a database's life,
            // not a keyboard-first action, and it needs no muscle-memory bridge from another app.
            //
            // It exists because backups moved into the app's sandbox container (issue #26), which
            // is a path — `~/Library/Containers/…/Data/Library/Application Support/PassSumo/
            // Backups` — no user would find or guess. A backup nobody can reach is only half a
            // backup, so the app has to be able to point at it.
            Button("Show Backups in Finder") { showBackupsInFinder() }
                .disabled(environment.backupDirectory == nil)
            Divider()
            // Through the controller, not `store.lock()` directly: the lock has to be RECORDED as
            // deliberate, or the unlock screen cannot tell "the Mac slept" from "I just hit ⌘L"
            // and prompts for Touch ID a second after the user chose to lock (issue #69).
            Button("Lock Database") { environment.autoLock.lockRequestedByUser() }
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
        // copy exactly as-is (see the brief) — these are ADDITIONAL items, matching Strongbox's own
        // bindings (issue #16) so muscle memory from Strongbox transfers directly instead of the
        // user having to relearn where "copy username" lives.
        CommandGroup(after: .pasteboard) {
            Divider()
            // ⌘B, not KeePassXC's ⌘⇧B: Strongbox binds Copy Username to the bare ⌘B chord, and
            // per the owner's instruction this issue matches Strongbox, not KeePassXC.
            Button("Copy Username") { copySelected(\.username) }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(selectedEntry == nil)
            // ⌘⇧C already matched Strongbox before this issue — left as-is.
            Button("Copy Password") { copySelected(\.password) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(selectedEntry == nil)
            Button("Copy URL") { copySelected(\.url) }
                .keyboardShortcut("u", modifiers: .command)
                .disabled(selectedEntry == nil)
            // Platform caveat (recorded in thinks/strongbox-menu-bindings.md): plain ⌘T is the
            // macOS-standard "New Tab" / "Show Fonts" chord, and Strongbox spending it on TOTP is a
            // divergence from the platform, not a convention to copy uncritically. Adopted anyway,
            // because (a) this app has no Font panel and no text-formatting `Commands` that would
            // otherwise claim it, and (b) `DocumentOpenReceiver.applicationDidFinishLaunching`
            // now turns off automatic window tabbing app-wide, so macOS never installs a
            // system-supplied "New Tab" item that ⌘T could collide with. A genuinely empty chord,
            // not just an unclaimed one.
            //
            // Disabled on an entry with no one-time code at all, or one whose `otp` field this
            // build cannot parse — either way there is no code to copy.
            Button("Copy One-Time Code") { copyTOTP() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(selectedEntryTOTPGenerator == nil)
        }

        CommandMenu("Entry") {
            // ⌘N, not ⌘⇧N: Strongbox binds "Create Entry" to the bare ⌘N chord and has NO binding
            // at all for "create a database" (see the shortcut on that item above) — swapped to
            // match.
            Button("New Entry") { environment.menuRequest = .newEntry }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!isUnlocked)
            // Adopted from Strongbox's "Create Group" (⌘G). Same enablement as New Entry: both need
            // an unlocked vault to have somewhere to put the new item.
            Button("New Group") { environment.menuRequest = .newGroup }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(!isUnlocked)
            Button("Edit Entry") {
                if let id = environment.selectedEntryID { environment.menuRequest = .editEntry(id) }
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(selectedEntry == nil)
            Divider()
            // Adopted from Strongbox's "Launch Url" (⌘⇧U). Genuinely disabled, not just greyed for
            // "no selection": `selectedEntryURL` is `nil` for an entry with an empty URL field or
            // one that fails `EntryURLResolver`'s scheme check (e.g. a bare "example.com" with no
            // `https://`), so the item never fires on a value it cannot open.
            Button("Launch URL") { launchSelectedEntryURL() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(selectedEntryURL == nil)
            // Adopted from Strongbox's "Copy Password and Launch Url" (⌘↓) — per the owner's brief,
            // "it is the actual login gesture": one chord does the whole "open the site, paste the
            // password" motion. Copies the password unconditionally (an entry can have a password
            // with no URL) and launches the URL only when one resolves, so a URL-less entry still
            // gets a working copy instead of the combined command refusing to do anything.
            Button("Copy Password and Launch URL") { copyPasswordAndLaunchURL() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(selectedEntry == nil)
            Divider()
            Button("Delete Entry") {
                if let id = environment.selectedEntryID { environment.menuRequest = .deleteEntry(id) }
            }
            // ⌘⌫, not bare ⌫ (issue #16, settling #9 with evidence from the эталон): Strongbox
            // requires ⌘⌫ for "Delete Item", matching Finder's own convention for destructive
            // removal, and dropping the bare-⌫ binding also removes the hazard #9 described — AppKit
            // evaluates menu key equivalents BEFORE the responder chain, so a Backspace typed into
            // the search field used to risk firing this instead of editing the text. ⌘⌫ needs no
            // such carve-out: nothing in this app's text fields binds ⌘⌫.
            //
            // What it does hasn't changed: it raises `.deleteEntry`, and `VaultBrowserView` moves
            // the entry to the recycle bin (undoable, no data lost) or, if it is already in the
            // bin, asks before destroying it.
            .keyboardShortcut(.delete, modifiers: .command)
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

    /// "Open Database…" is no longer scoped to "nothing open yet" (issue #84).
    ///
    /// It used to be, on the grounds that `VaultStore` holds one vault and had no "replace the open
    /// one" flow — but Launch Services can still hand us a `.kdbx` (Open With, a Dock drop; we are
    /// `Alternate`, not Owner — issue #131), so the system can make that request whether or not a
    /// menu item was enabled for it. There is now a replace-the-open-one flow (`VaultOpenRouter`,
    /// including the Save/Discard/Cancel prompt the old comment said this shell did not implement),
    /// and the menu goes through the same one, so greying the item out would only hide a capability
    /// the app already has.
    ///
    /// Still disabled mid-unlock: `VaultOpenRouter` drops a request that arrives while Argon2 is
    /// running (see `Decision.ignore`), and a menu item that is enabled but provably does nothing
    /// is worse than one that is greyed out.
    var canOpenDatabase: Bool {
        if case .unlocking = environment.store.state { return false }
        return true
    }

    /// "New Database…" stays scoped to "nothing open yet", deliberately.
    ///
    /// Creating a database while one is open would blow the open vault away through
    /// `VaultStore.createNew`, which — unlike `select` — has no unsaved-changes guard, and its
    /// sheet lives inside `WelcomeView`, which is unmounted whenever a vault is open. Issue #84 is
    /// about *opening* an existing file; giving Create the same treatment is its own change, with
    /// its own prompt and its own tests, not a side effect of this one.
    var canCreateNewDatabase: Bool {
        if case .empty = environment.store.state { return true }
        return false
    }

    /// Whether the open database has anything in its recycle bin. Drives the enablement of
    /// "Empty Recycle Bin…" so the item is not offered for a database that has no bin, or a bin
    /// that is already empty.
    ///
    /// "Anything" means folders as well as entries. `recycleBinGroupIDs` includes the bin group
    /// itself, so more than one id means a nested folder was deleted — and `Vault.emptyRecycleBin`
    /// removes those, so a menu item disabled for them would refuse work the command can do.
    var hasRecycleBinContent: Bool {
        guard case .unlocked(let vault) = environment.store.state else { return false }
        let binIDs = vault.recycleBinGroupIDs
        guard !binIDs.isEmpty else { return false }
        if binIDs.count > 1 { return true }
        return vault.entries.contains { $0.groupID.map(binIDs.contains) == true }
    }

    var selectedEntry: VaultEntry? {
        guard case .unlocked(let vault) = environment.store.state,
              let id = environment.selectedEntryID
        else { return nil }
        return vault.entries.first { $0.id == id }
    }

    /// The selected entry's URL, resolved the same way `EntryDetailView`'s URL row and
    /// `EntryListView`'s row context menu do (`EntryURLResolver`) — a bare host with no scheme
    /// (`URL(string:)` happily accepts "example.com") is not launchable, so it is treated the same
    /// as "no URL" here rather than handed to `NSWorkspace` to silently fail on.
    var selectedEntryURL: URL? {
        guard let entry = selectedEntry else { return nil }
        return EntryURLResolver.resolvedURL(from: entry.url)
    }

    /// The selected entry's TOTP generator, parsed from `otpAuthURL` the same way `TOTPView`
    /// parses it for display. `nil` for an entry with no one-time code at all, or — via the
    /// deliberately swallowed `try?` — one whose `otp` field this build cannot parse; either way
    /// there is no code to copy, so `Copy One-Time Code` disables rather than firing on nothing.
    var selectedEntryTOTPGenerator: TOTPGenerator? {
        guard let entry = selectedEntry, let otpAuthURL = entry.otpAuthURL, !otpAuthURL.isEmpty
        else { return nil }
        return try? TOTPGenerator(parsing: otpAuthURL)
    }

    private func copySelected(_ field: (VaultEntry) -> String) {
        guard let entry = selectedEntry else { return }
        environment.clipboard.copy(field(entry))
    }

    /// Computes the current one-time code and puts it on the pasteboard. Mirrors
    /// `TOTPView`'s own `(try? generator.code(at:)) ?? "······"` tolerance: the config already
    /// parsed successfully to reach here, so a failure at code-generation time is not expected, and
    /// there is nothing useful to copy if it happens.
    private func copyTOTP() {
        guard let generator = selectedEntryTOTPGenerator, let code = try? generator.code(at: Date())
        else { return }
        environment.clipboard.copy(code)
    }

    private func launchSelectedEntryURL() {
        guard let url = selectedEntryURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Strongbox's "Copy Password and Launch Url" (⌘↓): copies the password unconditionally, then
    /// opens the URL if one resolves. Not gated on `selectedEntryURL != nil` — an entry can have a
    /// password with no URL, and the copy half of the gesture should still work for it.
    private func copyPasswordAndLaunchURL() {
        guard let entry = selectedEntry else { return }
        environment.clipboard.copy(entry.password)
        if let url = selectedEntryURL {
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens the backup directory in Finder, creating it first if no save has needed it yet.
    ///
    /// Creating on demand rather than disabling the item when the directory is absent: an empty
    /// folder answers the user's actual question ("where are my backups?" — "here, and there are
    /// none yet"), whereas a greyed-out menu item answers nothing and looks like a bug. The
    /// creation is inside the app's own container, so it needs no grant and cannot prompt.
    ///
    /// Silent on failure by design — there is no error surface on a menu command, and the only way
    /// this fails is a container the app cannot write, which the next save will report through
    /// `VaultStore.lastBackupError` in language that actually explains the consequence.
    private func showBackupsInFinder() {
        guard let directory = environment.backupDirectory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }
}
