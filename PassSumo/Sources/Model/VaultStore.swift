import Foundation
import Observation

/// Owns the single decrypted `Vault` for the app's lifetime, and everything that touches it:
/// opening/creating/saving a file, and the in-memory edits between saves.
///
/// Injected with `any VaultCodec` + `any VaultFileAccess` (Dependency Inversion) — never
/// constructs either itself, so tests and previews swap in `InMemoryVaultCodec` /
/// `InMemoryVaultFileAccess` with no other change to this type. Deliberately has NO dependency on
/// `Sources/Security` (Touch ID, keychain, autolock timer) — that's a caller's job to layer on top
/// (see the architecture contract); keeping this file free of any Security-framework import is
/// what makes that boundary enforceable at compile time, not just by convention.
@MainActor
@Observable
final class VaultStore {
    /// What's currently on screen. `.locked` carries the URL so a re-prompt (wrong password, a
    /// biometric fallback to manual entry) can retry against the same file without the caller
    /// re-picking it via `NSOpenPanel`. `.unlocking` is its own case — not a bool bolted onto
    /// `.locked` — so the UI can show a distinct "working" state (spinner, disabled fields) while
    /// Argon2 runs, instead of conflating "nothing chosen yet" with "decrypting right now."
    enum State: Equatable {
        case empty
        case locked(URL)
        case unlocking
        case unlocked(Vault)
    }

    private(set) var state: State = .empty
    private(set) var isDirty = false
    private(set) var lastError: VaultError?
    private(set) var currentURL: URL?
    private(set) var lastBackupURL: URL?

    /// Why the last successful save could not make its pre-save backup, or `nil` when it could (or
    /// when there was nothing to back up).
    ///
    /// Separate from `lastError` because the two mean opposite things about the user's data.
    /// `lastError` means the save did NOT happen. This means the save DID happen, but without the
    /// safety net that normally precedes it — the save is not blocked by a failed backup (issue
    /// #26: it used to be, and the result was an app that could not save at all), and the failure
    /// is not swallowed either. `StatusBar` shows it; see `VaultBackupOutcome` for the full policy.
    private(set) var lastBackupError: VaultError?

    private let codec: any VaultCodec
    private let fileAccess: any VaultFileAccess

    /// What `decode`/`makeEmpty` returned for the currently-unlocked vault. Retained only while
    /// unlocked so `save()` can pass it back as `origin`, letting the codec restore whatever it
    /// stashed outside `Vault` (see `VaultCodec`'s hard-requirement doc comment). Cleared by
    /// `lock()` along with `credentials` — see that method's doc comment for why.
    private var decodedOrigin: DecodedVault?

    /// Retained only while unlocked, so `save()` can re-encode without asking the user to
    /// re-enter the master password on every save. Cleared by `lock()`.
    private var credentials: VaultCredentials?

    /// The tail of the save chain: the most recently enqueued save, or `nil` when none is in
    /// flight. See `save()` for why a chain of tasks — rather than a lock, a flag or an `actor` —
    /// is what makes overlapping saves impossible here.
    private var saveChain: Task<Void, Never>?

    /// Counts in-memory edits, so a completing save can tell whether the state it wrote is still
    /// the state in memory. Incremented by `markEdited()` and never reset — only compared.
    ///
    /// Exists because `isDirty` alone cannot answer "did MY change get written": a save encodes a
    /// snapshot and then spends most of a second in Argon2, and an edit landing in that window is
    /// genuinely not on disk. Clearing `isDirty` on that save's success would tell the user
    /// otherwise (issue #27).
    private var editRevision = 0

    init(codec: any VaultCodec, fileAccess: any VaultFileAccess) {
        self.codec = codec
        self.fileAccess = fileAccess
    }

    /// Decrypts `url` and, on success, moves to `.unlocked`. Argon2 key derivation is deliberately
    /// slow (tuned for brute-force resistance, on the order of ~1s) — running it on the main actor
    /// would freeze the whole UI for that second (a visible beachball on every unlock), so the
    /// read + decode happen inside a `Task.detached`, and only the *result* hops back onto the
    /// main actor to update `state`. Never throws: every failure becomes `lastError` and the store
    /// stays in `.locked`.
    func open(url: URL, credentials: VaultCredentials) async {
        state = .unlocking
        lastError = nil

        // Copy dependencies into locals before crossing into the detached task: `self` is
        // `@MainActor`-isolated and must not be captured by a non-isolated closure, but the
        // injected `codec`/`fileAccess` are themselves `Sendable` and safe to hand across.
        let codec = self.codec
        let fileAccess = self.fileAccess
        let result = await Task.detached(priority: .userInitiated) { () -> Result<DecodedVault, VaultError> in
            do {
                let data = try fileAccess.read(from: url)
                let decoded = try codec.decode(fileData: data, credentials: credentials)
                return .success(decoded)
            } catch let error as VaultError {
                return .failure(error)
            } catch {
                return .failure(.io(error.localizedDescription))
            }
        }.value

        switch result {
        case .success(let decoded):
            decodedOrigin = decoded
            self.credentials = credentials
            currentURL = url
            isDirty = false
            state = .unlocked(decoded.vault)
        case .failure(let error):
            lastError = error
            // Stay/return to `.locked` against the SAME url, so a caller can re-prompt in place
            // (e.g. "wrong password, try again") without re-resolving a bookmark or re-picking a
            // file. No vault, no credentials are retained on this path.
            state = .locked(url)
        }
    }

    /// Points the store at `url` and shows it as locked, **without attempting a decode**.
    ///
    /// This is the "the user picked a file, no password has been tried yet" transition. It exists
    /// because `open(url:credentials:)` reaches `.locked` only as its *failure* path, so without
    /// this the only ways to put the unlock screen on screen for a freshly-picked file were to call
    /// `open` with a throwaway password — which burns a full Argon2 derivation for nothing and
    /// flashes a "wrong password" error the user never earned — or to bridge the URL around the
    /// store entirely in app-level state beside `state`, which is exactly the kind of second source
    /// of truth `RootView` is written to not have.
    ///
    /// Drops any retained plaintext (`credentials`, `decodedOrigin`) rather than only flipping the
    /// state flag, for the same reason `lock()` does — see that method's doc comment. `lastError`
    /// is cleared because a freshly picked file has not failed at anything yet; leaving a previous
    /// file's error set would make `UnlockView` open with a red message about a database the user
    /// is no longer looking at.
    ///
    /// **Refuses, rather than silently discarding, when the open vault has unsaved edits (issue
    /// #84).** Dropping `decodedOrigin` is exactly what "close the open database" means here, so
    /// with `isDirty` set this method destroys work the user never agreed to lose. That was
    /// unreachable while "Open Database…" was greyed out for anything but `.empty` and
    /// `WelcomeView` was unmounted the moment a vault opened — routing a Finder open request into
    /// a live vault makes it reachable, so the guard lives HERE and not only in the UI that
    /// prompts. Pass `discardingUnsavedChanges: true` only after the user has actually answered
    /// "Discard" (see `VaultOpenRouter`); the default is what any other caller gets.
    ///
    /// Returns whether the selection happened. `false` means "refused, unsaved changes" — the
    /// store is untouched.
    @discardableResult
    func select(url: URL, discardingUnsavedChanges: Bool = false) -> Bool {
        guard !isDirty || discardingUnsavedChanges else { return false }
        credentials = nil
        decodedOrigin = nil
        isDirty = false
        lastError = nil
        currentURL = url
        state = .locked(url)
        return true
    }

    /// The open database's own stable identity, as the codec understands it, or `nil` when nothing
    /// is unlocked or this codec has no notion of one (`InMemoryVaultCodec`, any future codec).
    ///
    /// **Read-only on purpose: nothing here ever mints or writes an ID.** For KDBX this value lives
    /// in `Meta/CustomData`, so assigning one is a mutation that reaches the user's file on the next
    /// save — merely opening a vault must never do that (see `KDBXKitCodec.assigningDatabaseID`'s
    /// own doc comment). Assignment belongs to the moment the user opts into Touch ID for this
    /// database and is saved deliberately; this accessor only reports what is already there.
    var currentDatabaseID: UUID? {
        guard let decodedOrigin, let identifying = codec as? any DatabaseIdentifyingCodec else { return nil }
        return identifying.databaseID(of: decodedOrigin)
    }

    /// The master password behind the currently-unlocked vault, or `nil` if nothing is unlocked.
    ///
    /// **The one legitimate reason anything outside this type reads it back:** handing it to
    /// `BiometricUnlock.enable(masterPassword:for:)` at the exact moment the user opts into Touch
    /// ID (see `UnlockView`/`SettingsView`). Returned as a plain `String`, not `SecureBytes` — this
    /// type deliberately has no dependency on `Sources/Security` (see this file's own doc comment),
    /// and `credentials.password` is already a `String` retained here for `save()`'s own sake, so
    /// this exposes no new copy of the secret beyond what already exists in memory. The caller —
    /// always UI-layer code, which already depends on both `Sources/Model` and `Sources/Security` —
    /// must wrap the result in `SecureBytes` immediately and let it go out of scope as soon as
    /// `enable(...)` returns; never retain it in `@State` or anywhere longer-lived.
    var currentMasterPassword: String? {
        guard case .unlocked = state else { return nil }
        return credentials?.password
    }

    /// Assigns a stable database ID to the currently-unlocked vault if it does not already have
    /// one, and immediately saves — see `KDBXKitCodec.assigningDatabaseID`'s doc comment on why
    /// assignment must always be paired with a deliberate save rather than becoming a silent side
    /// effect of some unrelated mutation. Returns the ID (existing or freshly minted), or `nil`
    /// when nothing is unlocked, the codec has no notion of a stable identity at all
    /// (`InMemoryVaultCodec` — the `-ui-testing 1` seam included), or the save fails.
    ///
    /// The one caller today is the Touch ID enrollment flow: enabling Touch ID is the first moment
    /// a stable identity is actually needed, so it is also the first moment writing one to the
    /// user's file is justified. Everywhere else opening/browsing a vault must stay a pure read.
    func assignDatabaseIDIfNeeded() async -> UUID? {
        guard case .unlocked = state, let origin = decodedOrigin,
              let assigning = codec as? any DatabaseAssigningCodec
        else { return nil }

        if let existing = assigning.databaseID(of: origin) { return existing }
        guard let (updated, id) = assigning.assigningDatabaseID(to: origin) else { return nil }

        decodedOrigin = updated
        await save()
        // `save()` reports failure through `lastError`, not a thrown error — mirror that here
        // rather than inventing a second failure channel. If the write did not succeed, the
        // freshly-minted ID exists only in memory: handing it to the keychain layer as if it were
        // durable would let the next launch read `Meta/CustomData` back as `nil` and permanently
        // orphan the keychain item this ID was about to be stored under.
        guard lastError == nil else { return nil }
        return id
    }

    /// Creates a brand-new, empty database and unlocks it in memory immediately. Nothing is
    /// written to disk here — `makeEmpty` only builds the in-memory `DecodedVault`; the first
    /// `save()` is what actually creates the file, and (per `VaultFileAccess.write`'s contract)
    /// there is nothing to back up for that first save since the file doesn't exist yet.
    func createNew(at url: URL, credentials: VaultCredentials) async {
        state = .unlocking
        lastError = nil

        let codec = self.codec
        let name = url.deletingPathExtension().lastPathComponent
        let result = await Task.detached(priority: .userInitiated) { () -> Result<DecodedVault, VaultError> in
            do {
                return .success(try codec.makeEmpty(name: name, credentials: credentials))
            } catch let error as VaultError {
                return .failure(error)
            } catch {
                return .failure(.io(error.localizedDescription))
            }
        }.value

        switch result {
        case .success(let decoded):
            decodedOrigin = decoded
            self.credentials = credentials
            currentURL = url
            // Nothing is on disk yet: the first `save()` is not optional, it's how this database
            // starts existing at all.
            markEdited()
            state = .unlocked(decoded.vault)
        case .failure(let error):
            lastError = error
            state = .empty
        }
    }

    /// Re-encodes the current vault and writes it via `fileAccess`. Passes `decodedOrigin` as
    /// `origin` so the codec can restore whatever it stashed outside `Vault` on the last
    /// decode/create — see `VaultCodec`'s hard-requirement doc comment. A no-op (no throw, no
    /// disk access, no error set) when nothing is unlocked — there's nothing to save.
    ///
    /// **Saves are serialised, and by construction rather than by luck (issue #27).** `@MainActor`
    /// alone does not serialise this: the real work is an awaited `Task.detached`, and the main
    /// actor is released at that suspension, so a second `save()` used to walk straight in and
    /// encode-and-write alongside the first. Each write is atomic, so the file was never torn — but
    /// one rename won and the loser's edits were silently discarded while its `save()` reported
    /// success.
    ///
    /// The mechanism is a chain of tasks: each call reads the current tail, appends a task that
    /// awaits that tail before doing any work of its own, and publishes itself as the new tail.
    /// That read-modify-write of `saveChain` happens with **no suspension point in between**, so
    /// main-actor isolation makes it atomic and the chain is a total order — task N's work cannot
    /// begin until task N-1 has fully returned. Preferred over an `actor` owning the write (an
    /// actor would have to take its snapshot before the hop, i.e. as of when the save was
    /// *requested*, and would then resurrect stale state) and over a hand-rolled async semaphore
    /// (more continuation and cancellation machinery to get right, for a guarantee the language
    /// already gives here). The expensive part still runs in a detached task, so a queued save
    /// waits off the main actor and the UI never blocks on Argon2.
    ///
    /// A save asked for while another is in flight therefore **waits and then writes the latest
    /// state** — it is never dropped, and never coalesced into the in-flight save. Coalescing was
    /// rejected: the in-flight save has already taken its snapshot, so it provably does *not*
    /// contain edits made after it started, and folding a later request into it would report
    /// success for exactly the edits it did not write.
    func save() async {
        let predecessor = saveChain
        let link = Task { @MainActor in
            // Nothing above this line touches the vault: the whole point is that the snapshot is
            // taken by `performSave()` AFTER the predecessor is done.
            if let predecessor { await predecessor.value }
            await self.performSave()
        }
        saveChain = link
        await link.value
        // Only the tail clears the chain. A save that already has a successor must leave
        // `saveChain` alone, or the next caller would link onto `nil` and run alongside it.
        if saveChain == link { saveChain = nil }
    }

    /// The actual encode-and-write. **Only ever called from inside the chain `save()` builds** —
    /// calling it directly would reintroduce exactly the overlap that chain exists to prevent.
    private func performSave() async {
        // Snapshot HERE, not in `save()`: a queued save must encode the vault as of when it RUNS.
        // Snapshotting at request time would write whatever the vault looked like before the wait
        // and silently undo every edit made during it.
        guard case .unlocked(let vault) = state,
              let url = currentURL,
              let credentials
        else { return }

        let codec = self.codec
        let fileAccess = self.fileAccess
        let origin = decodedOrigin
        let revision = editRevision
        let result = await Task.detached(priority: .userInitiated) { () -> Result<VaultBackupOutcome, VaultError> in
            do {
                let data = try codec.encode(vault, credentials: credentials, origin: origin)
                return .success(try fileAccess.write(data, to: url))
            } catch let error as VaultError {
                return .failure(error)
            } catch {
                return .failure(.io(error.localizedDescription))
            }
        }.value

        switch result {
        case .success(let backup):
            // The save succeeded either way — `write` reports a failed backup as a value rather
            // than by throwing, precisely so a backup problem cannot cost the user their edits.
            // Both properties are assigned on every path so neither can be read as a stale claim
            // about the save that just happened.
            lastBackupURL = backup.url
            lastBackupError = backup.error
            // Clear `isDirty` only if the snapshot this save wrote is still what's in memory. An
            // edit that landed while the KDF was running is genuinely NOT on disk; reporting the
            // vault as clean would be this save claiming credit for work it never wrote.
            if editRevision == revision { isDirty = false }
            lastError = nil
        case .failure(let error):
            lastError = error
            // Deliberately leave `isDirty` untouched: a failed save must not let the caller believe
            // the in-memory edits are safely on disk.
        }
    }

    /// Locks the vault: drops the decrypted `Vault` AND the retained `VaultCredentials` (not just
    /// a flip to `.locked`). Both are plaintext secrets living in this process's memory — a state
    /// flag alone would leave them reachable by anything that can inspect that memory (a debugger
    /// attach, a crash report, a memory-disclosure exploit) even though the UI shows "locked."
    /// `decodedOrigin` is dropped too since a codec may embed decrypted material in it (e.g.
    /// attachment bytes) that has no business surviving a lock either.
    func lock() {
        credentials = nil
        decodedOrigin = nil
        isDirty = false
        if let url = currentURL {
            state = .locked(url)
        } else {
            state = .empty
        }
    }

    /// Inserts a new entry, or replaces an existing one matched by `id`, stamping `modified` to
    /// now and marking the vault dirty. No-op when nothing is unlocked.
    ///
    /// `blobs` carries the payloads of any attachment the caller just added, because
    /// `VaultEntry.attachments` holds references only (see `VaultAttachment`) — an entry whose
    /// blob never reached the pool would render as a named attachment with nothing behind it.
    /// Blobs already in the pool are left alone: the id IS the content hash, so re-adding an
    /// identical payload is a no-op by construction rather than a second copy.
    func upsert(_ entry: VaultEntry, addingBlobs blobs: [VaultBlob] = []) {
        guard case .unlocked(var vault) = state else { return }
        var stamped = entry
        stamped.modified = Date()
        for blob in blobs where vault.blobs[blob.id] == nil {
            vault.blobs[blob.id] = blob
        }
        if let index = vault.entries.firstIndex(where: { $0.id == entry.id }) {
            vault.entries[index] = stamped
        } else {
            vault.entries.append(stamped)
        }
        decodedOrigin?.vault = vault
        state = .unlocked(vault)
        markEdited()
    }

    // MARK: - Groups

    /// Creates a folder under `parentID` (`nil` = the vault's top level) and returns it, or `nil`
    /// when nothing was created.
    ///
    /// `nil` covers three refusals: nothing is unlocked, the name is blank, or `parentID` names a
    /// group this vault does not have. A blank name is refused rather than defaulted to something
    /// — a folder called "" is indistinguishable from a bug in every client that opens the file
    /// afterwards, and what to say about it is the caller's decision, not this type's.
    @discardableResult
    func addGroup(named name: String, parentID: UUID?) -> VaultGroup? {
        guard case .unlocked(var vault) = state else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let parentID, !vault.groups.contains(where: { $0.id == parentID }) { return nil }

        let group = VaultGroup(id: UUID(), parentID: parentID, name: trimmed)
        vault.groups.append(group)
        commit(vault)
        return group
    }

    /// Renames a folder.
    ///
    /// A no-op — and deliberately not a dirty vault — when nothing is unlocked, the id matches
    /// nothing, the name is blank, or it is the name the folder already has. The last of those is
    /// the one worth stating: a rename that changed nothing would otherwise leave the user with an
    /// unsaved-changes flag and a save to make for no reason.
    func renameGroup(_ groupID: UUID, to name: String) {
        guard case .unlocked(var vault) = state,
              let index = vault.groups.firstIndex(where: { $0.id == groupID })
        else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, vault.groups[index].name != trimmed else { return }
        vault.groups[index].name = trimmed
        commit(vault)
    }

    /// Re-parents a folder, subtree and all, and reports whether it moved.
    ///
    /// **A move into the folder's own descendant is refused** — see `Vault.canMoveGroup` for why
    /// the encoder's cycle guard must never be the thing that catches that.
    @discardableResult
    func moveGroup(_ groupID: UUID, under newParentID: UUID?) -> Bool {
        guard case .unlocked(var vault) = state,
              vault.moveGroup(groupID, under: newParentID)
        else { return false }
        commit(vault)
        return true
    }

    // MARK: - Deletion

    /// What deleting a given entry would actually DO, so the UI can decide whether to ask first.
    ///
    /// Split out from `delete(entryID:)` rather than folded into it because the two outcomes carry
    /// completely different stakes: moving an entry to the bin is undoable by dragging it back and
    /// needs no ceremony, while a permanent delete destroys the only copy of a password and must
    /// never happen without an explicit confirmation. A single `delete` that silently did either
    /// depending on where the entry happened to sit would make the destructive case reachable by a
    /// keystroke with no prompt at all.
    enum Deletion: Equatable {
        case recycled
        case permanent
    }

    /// What `delete(entryID:)` would do, or `nil` when there is no such entry to delete.
    func plannedDeletion(forEntry entryID: UUID) -> Deletion? {
        guard case .unlocked(let vault) = state,
              let entry = vault.entries.first(where: { $0.id == entryID })
        else { return nil }
        if vault.recycleBin.isEnabled, !vault.isInRecycleBin(entry) { return .recycled }
        return .permanent
    }

    /// Deletes the entry per `plannedDeletion(forEntry:)`: moves it to the recycle bin where that
    /// applies, otherwise removes it outright.
    ///
    /// **Callers MUST have confirmed with the user when `plannedDeletion` reports `.permanent`.**
    /// This method does not prompt — it has no UI to prompt with — and will not refuse.
    ///
    /// No-op when nothing is unlocked, or the id doesn't match anything currently in the vault:
    /// deleting an already-gone entry is not an error condition worth surfacing.
    func delete(entryID: UUID) {
        guard case .unlocked(var vault) = state,
              vault.entries.contains(where: { $0.id == entryID })
        else { return }

        if !vault.moveToRecycleBin(entryID: entryID) {
            vault.removePermanently(entryID: entryID)
        }
        commit(vault)
    }

    /// Removes the entry outright regardless of where it sits, bypassing the recycle bin. Same
    /// confirmation obligation as above — this is the one that cannot be undone.
    func permanentlyDelete(entryID: UUID) {
        guard case .unlocked(var vault) = state,
              vault.entries.contains(where: { $0.id == entryID })
        else { return }
        vault.removePermanently(entryID: entryID)
        commit(vault)
    }

    /// What `delete(groupID:)` would do, or `nil` when the folder must not be deleted at all.
    ///
    /// `nil` carries more weight here than it does for an entry, where it only ever means "no such
    /// entry". Besides that, it covers the recycle bin itself and any folder the bin is nested
    /// inside: neither can be recycled (the bin would become its own ancestor) and neither may be
    /// deleted outright (that destroys the bin, and `Meta/RecycleBinUUID` with it). See
    /// `Vault.moveToRecycleBin(groupID:)`. A caller offers no delete for those rather than picking
    /// one of the two wrong answers.
    func plannedDeletion(forGroup groupID: UUID) -> Deletion? {
        guard case .unlocked(let vault) = state,
              vault.groups.contains(where: { $0.id == groupID })
        else { return nil }
        if let binID = vault.recycleBin.groupID, vault.groupSubtreeIDs(of: groupID).contains(binID) {
            return nil
        }
        if vault.recycleBin.isEnabled, !vault.recycleBinGroupIDs.contains(groupID) { return .recycled }
        return .permanent
    }

    /// Deletes the folder — entries, nested folders and all — per `plannedDeletion(forGroup:)`.
    ///
    /// **Callers MUST have confirmed with the user when `plannedDeletion` reports `.permanent`**,
    /// exactly as for an entry. This method does not prompt and will not refuse.
    ///
    /// Written as a switch on the plan rather than as `delete(entryID:)`'s "try to recycle, else
    /// remove outright". For an entry those two are the same thing, because every refusal
    /// `moveToRecycleBin` can return IS a permanent delete. For a folder there is a third refusal —
    /// the bin itself, or a folder containing it — and letting that fall through to "else remove
    /// outright" would turn a case that must do nothing into the most destructive act in the app.
    func delete(groupID: UUID) {
        guard case .unlocked(var vault) = state else { return }
        switch plannedDeletion(forGroup: groupID) {
        case .recycled:
            _ = vault.moveToRecycleBin(groupID: groupID)
        case .permanent:
            vault.removePermanently(groupID: groupID)
        case nil:
            return
        }
        commit(vault)
    }

    /// Removes the folder and everything inside it outright, bypassing the bin. Same confirmation
    /// obligation as `permanentlyDelete(entryID:)` — this is the one that cannot be undone.
    func permanentlyDelete(groupID: UUID) {
        guard case .unlocked(var vault) = state,
              vault.groups.contains(where: { $0.id == groupID })
        else { return }
        let before = (vault.entries.count, vault.groups.count)
        vault.removePermanently(groupID: groupID)
        // `removePermanently(groupID:)` refuses to take the recycle bin (see its doc comment), so
        // this can legitimately change nothing — and an unchanged vault must not be marked dirty.
        guard (vault.entries.count, vault.groups.count) != before else { return }
        commit(vault)
    }

    /// Permanently removes everything in the recycle bin. No-op when the vault has no bin, or the
    /// bin is already empty — in which case nothing is marked dirty either, so an idle "Empty"
    /// does not manufacture a save.
    func emptyRecycleBin() {
        guard case .unlocked(var vault) = state else { return }
        let before = (vault.entries.count, vault.groups.count)
        vault.emptyRecycleBin()
        guard (vault.entries.count, vault.groups.count) != before else { return }
        commit(vault)
    }

    /// Publishes an edited vault: mirrors it into the retained origin (so the next `save()` merges
    /// against the same object the codec handed us), swaps the state, and marks dirty.
    private func commit(_ vault: Vault) {
        decodedOrigin?.vault = vault
        state = .unlocked(vault)
        markEdited()
    }

    /// Records that the in-memory vault changed: dirty, and one revision further on than any save
    /// currently in flight captured. The two always move together — see `editRevision`.
    private func markEdited() {
        isDirty = true
        editRevision += 1
    }
}

/// The one thing `VaultStore.currentDatabaseID` needs from a codec, and nothing else.
///
/// Deliberately a *separate*, narrow protocol rather than a new member on `VaultCodec` (Interface
/// Segregation): a stable in-file identifier is a KDBX-specific affordance — `InMemoryVaultCodec`
/// has no file and no `Meta/CustomData` to keep one in — so folding it into `VaultCodec` would
/// force every conformer to answer a question most of them cannot. The conformance below is
/// declared here, not in `Sources/KDBX`, so the codec module stays unaware that anything asks this
/// of it; `KDBXKitCodec.databaseID(of:)` already has exactly this signature, so the conformance is
/// empty.
protocol DatabaseIdentifyingCodec: Sendable {
    /// The database's own stable UUID, or `nil` if it has never been assigned one. Must be a pure
    /// read — see `VaultStore.currentDatabaseID` for why assigning one here would be a bug.
    func databaseID(of decoded: DecodedVault) -> UUID?
}

/// The one additional thing `VaultStore.assignDatabaseIDIfNeeded()` needs from a codec.
///
/// A *separate* protocol from `DatabaseIdentifyingCodec` (Interface Segregation), not an extra
/// requirement bolted onto it: reading an ID and minting one are different privileges — the read
/// is safe at any time (`VaultStore.currentDatabaseID`), the write is a mutation that must only
/// happen at a caller's deliberate request. Keeping them separate means a future read-only
/// caller's type signature can ask for `any DatabaseIdentifyingCodec` and be handed something that
/// is architecturally incapable of assigning an ID, rather than merely trusted not to call it.
protocol DatabaseAssigningCodec: DatabaseIdentifyingCodec {
    /// Returns `decoded` with a freshly generated database ID, or unchanged if it already has one.
    /// See `KDBXKitCodec.assigningDatabaseID`'s own doc comment for the full reasoning (in
    /// particular: why this must never be called except in response to an explicit save).
    func assigningDatabaseID(to decoded: DecodedVault) -> (vault: DecodedVault, id: UUID)?
}

extension KDBXKitCodec: DatabaseAssigningCodec {}
