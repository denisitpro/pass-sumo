import Foundation
import KDBXKit

/// One-way projection: a decrypted `KDBXContent` down to the small `Vault` shape the rest of the
/// app edits.
///
/// This is deliberately LOSSY, and that is safe only because it is one half of a pair: the original
/// `KDBXContent` is carried forward untouched in `DecodedVault.opaque`, and `KDBXContentMerge`
/// re-applies the user's edits onto THAT object rather than rebuilding a database from what
/// survived this projection. See `KDBXKitCodec` for the full contract.
///
/// What `Vault` does NOT model, and therefore what only survives via the preserved original:
/// entry history, custom icons, tags, AutoType sequences, foreground/background colours, expiry,
/// usage counts, group notes/expansion state, `DeletedObjects` tombstones, `Meta` settings, the
/// header's public custom data, and any `CustomData` another client wrote on the database, a group
/// or an entry.
enum KDBXVaultProjection {
    static func vault(from content: KDBXContent) -> Vault {
        let rootGroup = content.database.root.group

        // Hashing the binary pool once, up front, is what lets every entry below name its
        // attachments by content hash instead of by pool position — see `KDBXBinaryPool`.
        let pool = KDBXBinaryPool(content.innerHeader.binaryContent)
        var blobs: [VaultBlobID: VaultBlob] = [:]
        for blob in pool.blobs { blobs[blob.id] = blob }

        var groups: [VaultGroup] = []
        var entries: [VaultEntry] = []

        // The KDBX root group is a container, not a folder: KeePass clients show its CHILDREN as
        // the top-level folders and never the root itself (KDBXKit's `makeEmpty` even names it
        // after the database). So it maps onto our "nil == root" sentinel — anything filed directly
        // in it becomes a `groupID: nil` entry, and its child groups become `parentID: nil` groups.
        for entry in rootGroup.entries {
            entries.append(vaultEntry(from: entry, groupID: nil, pool: pool, blobs: &blobs))
        }
        for child in rootGroup.groups {
            collect(child, parentID: nil, into: &groups, entries: &entries, pool: pool, blobs: &blobs)
        }

        return Vault(
            name: content.database.meta.databaseName ?? "",
            groups: groups,
            entries: entries,
            blobs: blobs,
            recycleBin: recycleBin(from: content.database.meta)
        )
    }

    /// Reads `Meta`'s recycle-bin pointer.
    ///
    /// Two spellings of "there is no bin yet" have to collapse to the same `nil`: the element being
    /// absent, and the all-zeroes UUID the format defines as the not-created-yet sentinel. Treating
    /// the zero UUID as a real group id would make the app look for a folder that cannot exist and
    /// then create a SECOND bin beside the pointer, which is how a database ends up with two.
    ///
    /// A pointer at a group that is no longer in the tree is left as-is here and handled one level
    /// up: `Vault.recycleBinGroupIDs` reports no bin for a dangling id, and the next delete mints a
    /// fresh bin and repoints `Meta` at it. Another client really can delete the bin folder and
    /// leave the pointer behind, and the alternative — dropping the id during projection — would
    /// discard the evidence that the database ever had a bin before anything asks.
    static func recycleBin(from meta: KDBX.Meta) -> RecycleBinConfiguration {
        // `RecycleBinEnabled` absent means enabled: that is KeePass's own default, and reading an
        // omitted element as "off" would deny the feature to every database whose writer simply
        // never emitted it.
        let isEnabled = meta.recycleBinEnabled ?? true
        guard let uuid = meta.recycleBinUUID, !uuid.isAllZeroes else {
            return RecycleBinConfiguration(isEnabled: isEnabled, groupID: nil)
        }
        return RecycleBinConfiguration(isEnabled: isEnabled, groupID: uuid)
    }

    private static func collect(
        _ group: KDBX.Group,
        parentID: UUID?,
        into groups: inout [VaultGroup],
        entries: inout [VaultEntry],
        pool: KDBXBinaryPool,
        blobs: inout [VaultBlobID: VaultBlob]
    ) {
        groups.append(VaultGroup(id: group.uuid, parentID: parentID, name: group.name ?? ""))
        for entry in group.entries {
            entries.append(vaultEntry(from: entry, groupID: group.uuid, pool: pool, blobs: &blobs))
        }
        for child in group.groups {
            collect(child, parentID: group.uuid, into: &groups, entries: &entries, pool: pool, blobs: &blobs)
        }
    }

    /// Projects one entry. `entry.history` is NOT walked: history snapshots carry the same UUID as
    /// their live entry, so surfacing them would produce duplicate `Identifiable` ids and, worse,
    /// make the merge step think the live entry moved. History is preserved wholesale by the merge
    /// instead.
    static func vaultEntry(
        from entry: KDBX.Entry,
        groupID: UUID?,
        pool: KDBXBinaryPool,
        blobs: inout [VaultBlobID: VaultBlob]
    ) -> VaultEntry {
        // Reveal each protected value exactly once, straight into the field it belongs in. The
        // window cannot be made shorter than this: `VaultEntry.password` is plaintext by design
        // (see Domain.swift — `Vault` only exists while the database is unlocked), so the copy has
        // to happen. What this does avoid is an intermediate `[String: String]` of every field,
        // which would leave a second plaintext copy of the password alive until ARC got round to
        // it. Nothing here is logged, ever.
        func revealed(_ key: String) -> String {
            entry.strings.first { $0.key == key }?.value.withRevealedString { $0 } ?? ""
        }

        let title = revealed(KDBXStandardField.title.rawValue)

        var customFields: [String: String] = [:]
        for string in entry.strings
            where !KDBXStandardField.allKeys.contains(string.key)
            && !KDBXTOTPConvention.reservedKeys.contains(string.key)
        {
            customFields[string.key] = string.value.withRevealedString { $0 }
        }

        // `.distantPast` is the "the file did not record this" sentinel, not a real date. The merge
        // recognizes it and writes `nil` back rather than inventing a year-0001 timestamp in a file
        // that had none — see `KDBXContentMerge.restore(_:into:)`.
        let times = entry.times

        // An entry carrying its payload inline (the KDBX 3.1 shape) has no pool slot to name, so
        // its blob only reaches `Vault.blobs` through this side channel.
        let projected = KDBXAttachments.project(entry.binaries, pool: pool)
        for blob in projected.inlineBlobs where blobs[blob.id] == nil {
            blobs[blob.id] = blob
        }

        return VaultEntry(
            id: entry.uuid,
            groupID: groupID,
            title: title,
            username: revealed(KDBXStandardField.userName.rawValue),
            password: revealed(KDBXStandardField.password.rawValue),
            url: revealed(KDBXStandardField.url.rawValue),
            notes: revealed(KDBXStandardField.notes.rawValue),
            otpAuthURL: KDBXTOTPConvention.readOTPAuthURL(from: entry.strings, label: title),
            customFields: customFields,
            attachments: projected.attachments,
            created: times?.creationTime ?? .distantPast,
            modified: times?.lastModificationTime ?? .distantPast
        )
    }
}
