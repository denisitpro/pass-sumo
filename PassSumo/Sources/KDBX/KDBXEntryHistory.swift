import Foundation
import KDBXKit

/// Enforces KDBX's two `<History>` retention limits — `Meta/HistoryMaxItems` and
/// `Meta/HistoryMaxSize` — on an entry's history list (issue #75).
///
/// Writing snapshots without this grows a vault without bound: every password rotation adds a
/// full copy of the entry, forever, to a file that is decrypted into memory in one piece on unlock
/// and re-encrypted in one piece on every save.
///
/// **Trimming only ever runs on an entry pass-sumo added a snapshot to.** That is a deliberate
/// asymmetry, not an oversight. Both limits are frequently ABSENT from `Meta`, and the values used
/// for an absent element are a convention we adopt (`defaultMaxItems`, `defaultMaxSizeBytes`), not
/// anything the file said — so applying them to an entry the user never touched would let a save
/// that changed one password quietly delete another client's history from an unrelated entry,
/// using a cap that database never declared. `KDBXContentMerge` calls this only where it appends,
/// which also preserves the "an unedited entry's bytes are identical" guarantee the round-trip
/// tests assert.
///
/// The caps still apply to inherited snapshots of the entry that WAS edited, because that is the
/// convention: KeePass and KeePassXC trim the whole list on the edit that grew it, oldest first.
enum KDBXEntryHistory {
    /// What `HistoryMaxItems` means when `Meta` does not say — KeePass's and KeePassXC's own
    /// default. Ten snapshots is what a user coming from either of those clients already has.
    static let defaultMaxItems = 10

    /// What `HistoryMaxSize` means when `Meta` does not say: 6 MiB, again KeePass's own default.
    static let defaultMaxSizeBytes = 6 * 1024 * 1024

    /// `history` trimmed to fit both caps, oldest snapshots dropped first.
    ///
    /// - Parameters:
    ///   - history: The full list to retain from — the file's own snapshots followed by the ones
    ///     this save is adding, oldest first, which is the order KDBX stores them in.
    ///   - meta: The database's own `Meta`; both caps are read from it, neither is written back.
    ///     Writing an absent element would stamp `SettingsChanged` into a save that changed no
    ///     setting, the same trap `applyRecycleBinPointer` documents.
    ///   - liveBinaries: The binaries the LIVE entry is being written with. Their payloads are in
    ///     the file whatever history does, so a snapshot that merely shares one costs nothing and
    ///     must not be charged for it — this is what keeps an untouched attachment from evicting
    ///     ten snapshots of the password beside it.
    ///   - pool: The binary pool, to resolve a `<Binary Ref>` to a payload size.
    static func trimmed(
        _ history: [KDBX.Entry],
        meta: KDBX.Meta,
        liveBinaries: [KDBX.ProtectedBinary],
        pool: KDBXBinaryPool
    ) -> [KDBX.Entry] {
        let byCount = trimmedByCount(history, cap: meta.historyMaxItems)
        return trimmedBySize(byCount, cap: meta.historyMaxSize, liveBinaries: liveBinaries, pool: pool)
    }

    /// Keeps at most `HistoryMaxItems` snapshots, dropping the oldest.
    ///
    /// `0` is a real, meaningful value and not a mistake to guard against: KeePass writes it to
    /// mean "keep no history at all", and a database whose owner set that must not get history
    /// back from us. Negative values are the format's "unlimited" sentinel and reach here as
    /// `.unlimited` (KDBXKit's reader normalises them), so they are not a number to compare.
    private static func trimmedByCount(
        _ history: [KDBX.Entry],
        cap: KDBX.ValueOrUnlimited<UInt32>?
    ) -> [KDBX.Entry] {
        let limit: Int
        switch cap {
        case .unlimited: return history
        case let .value(maxItems): limit = Int(maxItems)
        case nil: limit = defaultMaxItems
        }
        guard history.count > limit else { return history }
        return Array(history.suffix(limit))
    }

    /// Keeps the newest snapshots that fit inside `HistoryMaxSize`.
    ///
    /// Walks newest to oldest, accumulating each snapshot's estimated contribution, and cuts the
    /// list at the first snapshot that would put the total over the cap — so the ones the user is
    /// most likely to want back are the ones that survive. A single snapshot bigger than the whole
    /// budget therefore takes the rest with it, which is the honest reading of a byte budget and
    /// what KeePassXC does with the same input.
    private static func trimmedBySize(
        _ history: [KDBX.Entry],
        cap: KDBX.ValueOrUnlimited<UInt64>?,
        liveBinaries: [KDBX.ProtectedBinary],
        pool: KDBXBinaryPool
    ) -> [KDBX.Entry] {
        let limit: Int
        switch cap {
        case .unlimited: return history
        case let .value(maxSize): limit = Int(clamping: maxSize)
        case nil: limit = defaultMaxSizeBytes
        }

        // Seeded with what the live entry already pays for, then grown as older snapshots are
        // charged: the pool stores each payload exactly once, so ten snapshots of one attachment
        // cost the file one copy and charging ten would trim history for bytes that are not there.
        var chargedPayloads = Set(payloadIDs(of: liveBinaries, in: pool))
        var total = 0
        var kept = 0
        for snapshot in history.reversed() {
            total += weight(of: snapshot, chargedPayloads: &chargedPayloads, pool: pool)
            if total > limit { break }
            kept += 1
        }
        guard kept < history.count else { return history }
        return Array(history.suffix(kept))
    }

    /// Estimated bytes one snapshot adds to the file: its string fields plus any attachment
    /// payload nothing else in the file is already paying for.
    ///
    /// An estimate, deliberately, and the same kind KeePassXC uses: weighing a snapshot exactly
    /// would mean serializing, compressing and encrypting it to find out, on every save. Counted
    /// are the two things that actually vary by orders of magnitude — field text and attachment
    /// payloads. Not counted are tags, AutoType associations and per-entry custom data, which are
    /// bounded and tiny beside either.
    ///
    /// Values are measured through `withRevealedString`, so a historical password's plaintext
    /// exists only for the length of that call and only to be counted, never copied out.
    private static func weight(
        of snapshot: KDBX.Entry,
        chargedPayloads: inout Set<VaultBlobID>,
        pool: KDBXBinaryPool
    ) -> Int {
        var bytes = snapshot.strings.reduce(0) { total, string in
            total + string.key.utf8.count + string.value.withRevealedString { $0.utf8.count }
        }
        for binary in snapshot.binaries {
            switch binary.value {
            case let .ref(index):
                guard let slot = pool.slot(at: index) else { continue }
                guard chargedPayloads.insert(slot.blobID).inserted else { continue }
                bytes += slot.byteCount
            case let .inline(data, _):
                // An inline payload is genuinely this snapshot's own copy — no pool slot shares
                // it, so it is charged every time.
                bytes += data.count
            }
            bytes += binary.key.utf8.count
        }
        return bytes
    }

    /// The pooled payloads a binary list references. Inline payloads have no pool identity and are
    /// left out: they cannot be shared, so nothing else can already be paying for them.
    private static func payloadIDs(
        of binaries: [KDBX.ProtectedBinary],
        in pool: KDBXBinaryPool
    ) -> [VaultBlobID] {
        binaries.compactMap { binary in
            guard case let .ref(index) = binary.value else { return nil }
            return pool.slot(at: index)?.blobID
        }
    }
}
