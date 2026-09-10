import Foundation
import KDBXKit

/// Derives when an entry's PASSWORD last changed by walking its KDBX `<History>` — issue #33's
/// accurate alternative to `Times/LastModificationTime`, which bumps on ANY field edit and so
/// cannot tell "the password rotated" from "a note got fixed".
///
/// The derivation leans on one fact about how `KDBXKit`'s own CLI takes a snapshot
/// (`EntryHistory.snapshot`, mirrored by every other KeePass-family client): a history entry is a
/// straight copy of the live entry taken immediately BEFORE an edit is applied, with its `Times`
/// left untouched. So a snapshot's own `lastModificationTime` is not "when this version was
/// retired" — it is "when this version *became* current", i.e. exactly the moment its password
/// took effect. Walking `history` from newest to oldest and stopping at the first snapshot whose
/// password differs from today's therefore lands on the oldest snapshot that still agrees with
/// the live password — its `lastModificationTime` is the answer.
enum KDBXPasswordHistory {
    /// - Parameters:
    ///   - currentPassword: The entry's live `Password` value, already revealed.
    ///   - currentModified: The live entry's own `Times.lastModificationTime`, used ONLY as a
    ///     fallback for the one case history alone cannot date: the very last save is what
    ///     changed the password (no surviving snapshot shares the new value at all).
    ///   - history: `Entry.history`, oldest first, exactly as KDBXKit models it.
    /// - Returns: `nil` when there is nothing to derive from (no history at all — see
    ///   `VaultEntry.passwordLastChanged`'s doc comment for why this must not fall back to a
    ///   fabricated date). Otherwise the derived date, which for a history trimmed by another
    ///   client's `HistoryMaxItems` is a LOWER BOUND — the real change could predate the oldest
    ///   snapshot that survived, but never postdates it.
    static func lastChanged(
        currentPassword: String,
        currentModified: Date?,
        history: [KDBX.Entry]
    ) -> Date? {
        guard !history.isEmpty else { return nil }

        // The oldest snapshot found so far (walking backwards) whose password still matches the
        // live value — i.e. the current best guess at "when the current password era began".
        var oldestMatchingTime: Date?
        var foundADifference = false

        for snapshot in history.reversed() {
            guard password(of: snapshot) == currentPassword else {
                foundADifference = true
                break
            }
            oldestMatchingTime = snapshot.times?.lastModificationTime ?? oldestMatchingTime
        }

        guard foundADifference else {
            // Every retained snapshot already holds today's password. Either the database has
            // never rotated it, or the snapshot that WOULD have differed was trimmed away by
            // another client's `HistoryMaxItems` — either way, the oldest survivor's own time is
            // the best (lower-bound) answer available.
            return oldestMatchingTime
        }

        // The newest history snapshot already differs, so nothing in `history` dates the change
        // — it happened on the save that produced the CURRENT state, and that save's own
        // modification time is not a guess here: the comparison above is what confirms it,
        // exactly as `oldestMatchingTime` confirms the earlier snapshots that DID still match.
        return oldestMatchingTime ?? currentModified
    }

    private static func password(of entry: KDBX.Entry) -> String {
        entry.strings
            .first { $0.key == KDBXStandardField.password.rawValue }?
            .value.withRevealedString { $0 } ?? ""
    }
}
