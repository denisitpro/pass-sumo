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
    func select(url: URL) {
        credentials = nil
        decodedOrigin = nil
        isDirty = false
        lastError = nil
        currentURL = url
        state = .locked(url)
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
            isDirty = true
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
    func save() async {
        guard case .unlocked(let vault) = state,
              let url = currentURL,
              let credentials
        else { return }

        let codec = self.codec
        let fileAccess = self.fileAccess
        let origin = decodedOrigin
        let result = await Task.detached(priority: .userInitiated) { () -> Result<URL?, VaultError> in
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
        case .success(let backupURL):
            lastBackupURL = backupURL
            isDirty = false
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
        isDirty = true
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
        isDirty = true
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

extension KDBXKitCodec: DatabaseIdentifyingCodec {}
