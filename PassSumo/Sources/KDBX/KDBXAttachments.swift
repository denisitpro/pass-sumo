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

    /// First slot carrying a given payload. "First" matters: when the source file already contains
    /// two byte-identical slots, every reference we mint points at the earlier one, and the later
    /// one is left untouched for whichever entry already referenced it.
    private var slotByBlobID: [VaultBlobID: UInt32]

    /// Hashes every payload once. Linear in total attachment bytes (SHA-256 runs at GB/s, so a
    /// vault with tens of megabytes of attachments costs milliseconds), and it happens inside the
    /// same off-main-actor decode that already pays for Argon2.
    init(_ contents: [InnerHeader.BinaryContent]) {
        self.contents = contents
        blobIDs = contents.map { VaultBlobID(hashing: $0.data) }
        slotByBlobID = [:]
        for (index, id) in blobIDs.enumerated() where slotByBlobID[id] == nil {
            slotByBlobID[id] = UInt32(index)
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

    /// The slot holding `blob`, appending a new one if the payload is not pooled yet.
    ///
    /// `isProtected` is applied only to a freshly appended slot: an existing slot's flag belongs to
    /// whichever client wrote it, and flipping it would rewrite a payload other entries share.
    mutating func slot(for blob: VaultBlob, isProtected: Bool) -> UInt32 {
        if let existing = slotByBlobID[blob.id] { return existing }
        let index = UInt32(contents.count)
        contents.append(InnerHeader.BinaryContent(shouldBeProtected: isProtected, data: blob.bytes))
        blobIDs.append(blob.id)
        slotByBlobID[blob.id] = index
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

        for binary in binaries {
            switch binary.value {
            case .ref(let index):
                guard let slot = pool.slot(at: index) else { continue }
                attachments.append(VaultAttachment(
                    name: binary.key,
                    blobID: slot.blobID,
                    byteCount: slot.byteCount,
                    isProtected: slot.isProtected
                ))
            case .inline(let data, let isProtected):
                let blob = VaultBlob(bytes: data)
                inlineBlobs.append(blob)
                attachments.append(VaultAttachment(
                    name: binary.key,
                    blobID: blob.id,
                    byteCount: data.count,
                    isProtected: isProtected
                ))
            }
        }

        return (attachments, inlineBlobs)
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
    /// ref, which KDBXKit's writer would refuse outright; that can only happen for a `Vault`
    /// assembled by hand, never for one this codec projected.
    static func merge(
        _ attachments: [VaultAttachment],
        into base: [KDBX.ProtectedBinary],
        blobs: [VaultBlobID: VaultBlob],
        pool: inout KDBXBinaryPool
    ) -> [KDBX.ProtectedBinary] {
        let projected = project(base, pool: pool).attachments
        guard attachments != projected else { return base }

        return attachments.compactMap { attachment in
            guard let blob = blobs[attachment.blobID] else { return nil }
            let slot = pool.slot(for: blob, isProtected: attachment.isProtected)
            return KDBX.ProtectedBinary(key: attachment.name, value: .ref(slot))
        }
    }
}
