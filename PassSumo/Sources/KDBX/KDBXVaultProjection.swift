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
/// attachments, entry history, custom icons, tags, AutoType sequences, foreground/background
/// colours, expiry, usage counts, group notes/expansion state, recycle-bin configuration,
/// `DeletedObjects` tombstones, `Meta` settings, the header's public custom data, and any
/// `CustomData` another client wrote on the database, a group or an entry.
enum KDBXVaultProjection {
    static func vault(from content: KDBXContent) -> Vault {
        let rootGroup = content.database.root.group

        var groups: [VaultGroup] = []
        var entries: [VaultEntry] = []

        // The KDBX root group is a container, not a folder: KeePass clients show its CHILDREN as
        // the top-level folders and never the root itself (KDBXKit's `makeEmpty` even names it
        // after the database). So it maps onto our "nil == root" sentinel — anything filed directly
        // in it becomes a `groupID: nil` entry, and its child groups become `parentID: nil` groups.
        for entry in rootGroup.entries {
            entries.append(vaultEntry(from: entry, groupID: nil))
        }
        for child in rootGroup.groups {
            collect(child, parentID: nil, into: &groups, entries: &entries)
        }

        return Vault(
            name: content.database.meta.databaseName ?? "",
            groups: groups,
            entries: entries
        )
    }

    private static func collect(
        _ group: KDBX.Group,
        parentID: UUID?,
        into groups: inout [VaultGroup],
        entries: inout [VaultEntry]
    ) {
        groups.append(VaultGroup(id: group.uuid, parentID: parentID, name: group.name ?? ""))
        for entry in group.entries {
            entries.append(vaultEntry(from: entry, groupID: group.uuid))
        }
        for child in group.groups {
            collect(child, parentID: group.uuid, into: &groups, entries: &entries)
        }
    }

    /// Projects one entry. `entry.history` is NOT walked: history snapshots carry the same UUID as
    /// their live entry, so surfacing them would produce duplicate `Identifiable` ids and, worse,
    /// make the merge step think the live entry moved. History is preserved wholesale by the merge
    /// instead.
    static func vaultEntry(from entry: KDBX.Entry, groupID: UUID?) -> VaultEntry {
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
            created: times?.creationTime ?? .distantPast,
            modified: times?.lastModificationTime ?? .distantPast
        )
    }
}
