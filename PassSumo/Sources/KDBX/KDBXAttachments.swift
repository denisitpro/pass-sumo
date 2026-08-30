import Foundation
import KDBXKit

/// The database-wide binary pool, indexed both ways: by pool slot (what an entry's `<Binary Ref>`
/// names) and by content hash (what a `VaultAttachment` names).
///
/// KDBX 4 keeps every attachment payload exactly once in the inner header and lets entries point
/// at slots by position, so two entries carrying the same screenshot cost one payload. That is the
/// shape `Vault.blobs` mirrors, and this type is the translation between the two.
///
/// **Slots are only ever appended, never removed, reordered or renumbered.** A `<Binary Ref="3">`
/// is a positional index, and the entries holding one are not only the live entries this codec
/// rebuilds — every history snapshot on every entry carries its own `binaries` array with its own
/// refs, and those snapshots are preserved wholesale and never rewritten (see `KDBXContentMerge`).
/// Compacting the pool to reclaim a payload whose last live reference was removed would silently
/// repoint every one of those refs at the wrong payload, or past the end of the pool — KDBXKit's
/// writer refuses the latter outright (`danglingBinaryRef`), so the *visible* outcome would be a
/// vault that no longer saves. Hence the deliberate behaviour: **removing the last reference to a
/// payload leaves an orphan in the pool**, which is what KeePass and KeePassXC do as well. The
/// file stops shrinking; nothing breaks. Reclaiming that space needs a whole-database rewrite that
/// renumbers history too — a separate feature, not a side effect of removing one attachment.
struct KDBXBinaryPool {
    /// The pool as it will be written back to `InnerHeader.binaryContent`.
    private(set) var contents: [InnerHeader.BinaryContent]

    /// Content hash of each slot, parallel to `contents`.
    private var blobIDs: [VaultBlobID]

    /// What identifies a reusable slot: the payload AND its protected flag.
    ///
    /// Keying on the payload alone silently DOWNGRADES protection. A foreign pool can hold the
    /// same bytes twice — slot 3 unprotected, slot 7 protected — and an entry can reference slot
    /// 7. Re-emitting that entry's list (which happens as soon as any of its attachments change)
    /// would look the payload up, find slot 3 because it comes first, and write the payload out
    /// unprotected, in direct contradiction of what `VaultAttachment.isProtected` promises.
    private struct SlotKey: Hashable {
        var blobID: VaultBlobID
        var isProtected: Bool
    }

    /// First slot carrying a given payload at a given protection level. "First" matters: when the
    /// source file already contains two identical slots, every reference we mint points at the
    /// earlier one, and the later one is left untouched for whichever entry already referenced it.
    private var slotByPayload: [SlotKey: UInt32]

    /// Hashes every payload once. Linear in total attachment bytes (SHA-256 runs at GB/s, so a
    /// vault with tens of megabytes of attachments costs milliseconds), and it happens inside the
    /// same off-main-actor decode that already pays for Argon2.
    init(_ contents: [InnerHeader.BinaryContent]) {
        self.contents = contents
        blobIDs = contents.map { VaultBlobID(hashing: $0.data) }
        slotByPayload = [:]
        for (index, id) in blobIDs.enumerated() {
            let key = SlotKey(blobID: id, isProtected: contents[index].shouldBeProtected)
            if slotByPayload[key] == nil { slotByPayload[key] = UInt32(index) }
        }
    }

    /// Every pooled payload as a domain blob, ready to seed `Vault.blobs`.
    var blobs: [VaultBlob] {
        contents.map { VaultBlob(bytes: $0.data) }
    }

    /// The slot's payload description, or `nil` for a reference past the end of the pool — which a
    /// file written by a buggy client can genuinely contain, and which must degrade to "this entry
    /// has one fewer attachment" rather than trapping on an out-of-bounds subscript.
    func slot(at index: UInt32) -> (blobID: VaultBlobID, byteCount: Int, isProtected: Bool)? {
        guard index < contents.count else { return nil }
        let position = Int(index)
        return (blobIDs[position], contents[position].data.count, contents[position].shouldBeProtected)
    }

    /// The slot holding `blob` AT `isProtected`, appending a new one if there isn't one yet.
    ///
    /// An existing slot's flag is never flipped: it belongs to whichever client wrote it, and
    /// rewriting it would change how a payload other entries share is written. So the flag is part
    /// of what makes a slot reusable rather than something applied on top of a match. Both
    /// directions matter and both are refusals to reuse:
    ///
    /// - a protected reference must not be satisfied by an unprotected slot (the downgrade this
    ///   keying exists to stop);
    /// - an unprotected reference must not be satisfied by a protected slot either, which would
    ///   quietly upgrade another client's binary and change the bytes it reads back.
    ///
    /// The earlier code deliberately let a NEW attachment asking for protection settle for an
    /// existing unprotected slot, to avoid a second copy of the payload. That trade is no longer
    /// worth taking: it is the same downgrade, differing only in whether the protected reference
    /// came from the file or from this session, and every new attachment defaults to protected
    /// (`VaultAttachment.make`), so the case is common rather than exotic. The cost is one
    /// duplicated payload in the pool in the rare file that already stored it both ways — bounded,
    /// append-only, and invisible to every client, unlike a secret written out in the clear.
    mutating func slot(for blob: VaultBlob, isProtected: Bool) -> UInt32 {
        let key = SlotKey(blobID: blob.id, isProtected: isProtected)
        if let existing = slotByPayload[key] { return existing }
        let index = UInt32(contents.count)
        contents.append(InnerHeader.BinaryContent(shouldBeProtected: isProtected, data: blob.bytes))
        blobIDs.append(blob.id)
        slotByPayload[key] = index
        return index
    }
}

// MARK: - Projection and merge

/// Translates one entry's `<Binary>` list between KDBX's shape and `VaultEntry.attachments`.
enum KDBXAttachments {
    /// Projects an entry's attachments, plus any payload it carries INLINE rather than through the
    /// pool.
    ///
    /// Inline binaries are the KDBX 3.1 shape (and are legal on a 4.x entry too). KDBXKit already
    /// normalises a 3.1 file's `<Meta><Binaries>` pool into `InnerHeader.binaryContent` and
    /// rewrites the refs, so what reaches here as `.inline` is genuinely per-entry data. It has no
    /// pool slot to name, so its blob is returned separately for the caller to fold into
    /// `Vault.blobs`; the entry keeps its inline form on disk unless the user edits its
    /// attachments.
    static func project(
        _ binaries: [KDBX.ProtectedBinary],
        pool: KDBXBinaryPool
    ) -> (attachments: [VaultAttachment], inlineBlobs: [VaultBlob]) {
        var attachments: [VaultAttachment] = []
        var inlineBlobs: [VaultBlob] = []
        var takenNames: Set<String> = []

        for binary in binaries {
            let name = disambiguate(binary.key, against: &takenNames)
            switch binary.value {
            case .ref(let index):
                guard let slot = pool.slot(at: index) else { continue }
                attachments.append(VaultAttachment(
                    name: name,
                    blobID: slot.blobID,
                    byteCount: slot.byteCount,
                    isProtected: slot.isProtected
                ))
            case .inline(let data, let isProtected):
                let blob = VaultBlob(bytes: data)
                inlineBlobs.append(blob)
                attachments.append(VaultAttachment(
                    name: name,
                    blobID: blob.id,
                    byteCount: data.count,
                    isProtected: isProtected
                ))
            }
        }

        return (attachments, inlineBlobs)
    }

    /// Makes `name` unique within the entry being projected, suffixing a repeat the same way
    /// `EntryEditView` does when the user adds a file whose name is already taken.
    ///
    /// The format does not guarantee uniqueness — a duplicate `<Binary Key>` is a validation
    /// warning, not a rejection — but `VaultAttachment.id` is the name, and duplicate
    /// `Identifiable` ids make `ForEach` render the wrong rows and warn at runtime. Renaming here
    /// rather than at every consumer means the domain model has the property its `id` claims,
    /// whatever another client wrote.
    ///
    /// This costs nothing for the overwhelmingly normal file: no repeats means no renames, so
    /// `merge`'s "did the list change" comparison still sees the entry's attachments as identical
    /// to what `project` produces, and the entry's binaries are re-emitted byte-identically. Only
    /// a file that already had the duplicate — and could not be displayed correctly anyway — sees
    /// the second copy written back under a suffixed key, and then only if the user edits it.
    private static func disambiguate(_ name: String, against taken: inout Set<String>) -> String {
        func claim(_ candidate: String) -> String {
            taken.insert(candidate)
            return candidate
        }

        guard taken.contains(name) else { return claim(name) }

        let url = URL(fileURLWithPath: name)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for suffix in 2 ... 999 {
            let candidate = ext.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(ext)"
            if !taken.contains(candidate) { return claim(candidate) }
        }
        return claim("\(stem) \(UUID().uuidString)")
    }

    /// Rewrites one entry's `<Binary>` list from `attachments`.
    ///
    /// **Returns `base` untouched when the attachment list did not change.** That is the whole
    /// interop guarantee for this feature: an untouched entry keeps its binaries byte-identical —
    /// inline payloads stay inline, refs keep pointing at the slots they already pointed at, and
    /// the pool does not grow. The comparison is against what `project` would produce from `base`,
    /// so it compares like with like (same technique the TOTP field uses in `KDBXEntryStrings`),
    /// rather than trying to guess equivalence between two different on-disk encodings.
    ///
    /// When it did change, every attachment is emitted as a pool reference — the 4.x shape, which
    /// is the only shape this codec writes anyway (`KDBXKitCodec` always writes 4.1). An
    /// attachment whose blob is missing from `blobs` is dropped rather than emitted as a dangling
    /// ref, which KDBXKit's writer would refuse outright.
    ///
    /// **The unchanged path drops a dangling ref too**, which is why it filters `base` rather than
    /// returning it verbatim. A `<Binary Ref>` past the end of the pool — a real thing a buggy
    /// writer leaves behind — is skipped by `project`, so the projected list can equal the entry's
    /// list while `base` still carries the bad ref. Returning it untouched made the whole database
    /// unsaveable (the writer throws `danglingBinaryRef`) with no way for the user to find the
    /// cause, because the same skip hides that attachment from the UI. Dropping it costs nothing:
    /// it named a payload that does not exist.
    ///
    /// That filter does NOT weaken the byte-identical guarantee. It removes only binaries the pool
    /// cannot resolve, of which a well-formed file has none, so for every such file it returns an
    /// array equal to `base` — which is what `testUneditedDatabaseRoundTripsWithAnIdenticalBinaryPool`
    /// and `testRoundTripPreservesAttachmentHistoryAndCustomData` assert against real fixtures.
    static func merge(
        _ attachments: [VaultAttachment],
        into base: [KDBX.ProtectedBinary],
        blobs: [VaultBlobID: VaultBlob],
        pool: inout KDBXBinaryPool
    ) -> [KDBX.ProtectedBinary] {
        let projected = project(base, pool: pool).attachments
        guard attachments != projected else {
            return base.filter { isResolvable($0, in: pool) }
        }

        return attachments.compactMap { attachment in
            guard let blob = blobs[attachment.blobID] else { return nil }
            let slot = pool.slot(for: blob, isProtected: attachment.isProtected)
            return KDBX.ProtectedBinary(key: attachment.name, value: .ref(slot))
        }
    }

    /// Whether the pool can actually resolve this binary. Inline payloads carry their own bytes and
    /// always can; a `ref` past the end of the pool never can.
    private static func isResolvable(_ binary: KDBX.ProtectedBinary, in pool: KDBXBinaryPool) -> Bool {
        guard case .ref(let index) = binary.value else { return true }
        return pool.slot(at: index) != nil
    }
}
