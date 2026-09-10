import Foundation
import KDBXKit

// MARK: - Standard string-field keys

/// The five string-field keys KDBX reserves for the fields every client shows in its entry editor.
/// They are plain dictionary keys inside `Entry/String` like any other attribute — the format gives
/// them no special marking — so "standard field" versus "custom field" is purely a matter of
/// matching these exact, case-sensitive names. Getting the spelling wrong (`Username` for
/// `UserName`, say) does not fail: it silently demotes the field to a custom attribute that every
/// other client then shows in the wrong place.
enum KDBXStandardField: String, CaseIterable, Sendable {
    case title = "Title"
    case userName = "UserName"
    case password = "Password"
    case url = "URL"
    case notes = "Notes"

    /// Every key `VaultEntry` maps onto a dedicated property, so `customFields` can exclude them.
    static let allKeys: Set<String> = Set(allCases.map(\.rawValue))
}

// MARK: - Protection class

extension KDBX.ProtectedString.Value {
    /// Re-boxes `string` in the SAME on-disk protection class this value already uses.
    ///
    /// The case names are a trap and this helper exists so the trap is sprung in exactly one place.
    /// KDBXKit's `XMLDocumentWriter` serializes them as:
    ///
    /// - `.unprotected` and `.lazyInnerCipher` → `Protected="True"`, i.e. the value IS encrypted
    ///   with the inner random stream. `.unprotected` means "not yet encrypted, sitting in memory
    ///   as plaintext" — it does NOT mean "written in the clear".
    /// - `.protectedInMemory` → written as plain XML text with a `ProtectInMemory="True"` hint.
    ///   Despite the name this is the LESS protected of the two on disk.
    /// - `.regular` → plain XML text, no attribute.
    ///
    /// A field read from a real KDBX file comes back as `.lazyInnerCipher` (still ciphertext,
    /// decrypted on demand). Writing an edited password back as `.protectedInMemory` because the
    /// name sounded safest would strip the inner-stream protection from every password in the
    /// vault — hence: preserve the class, never pick one by name.
    func reboxed(with string: String) -> KDBX.ProtectedString.Value {
        switch self {
        // `.lazyInnerCipher` has no fresh-value form: its payload is ciphertext bound to the
        // reader's keystream offset. `.unprotected` is the correct destination — the writer
        // re-encrypts it against the newly generated inner key, which is exactly what should
        // happen to a value the user just changed.
        case .lazyInnerCipher, .unprotected: .unprotected(string)
        case .protectedInMemory: .protectedInMemory(string)
        case .regular: .regular(string)
        }
    }

    /// The class to write a field in when there is no existing class to preserve — either the
    /// field is new, or the user just changed its protection and the old class no longer matches
    /// the intent.
    ///
    /// `protected: true` yields `.unprotected`, which — per the mapping above — is the
    /// inner-stream-encrypted form. Callers pass the database's own `MemoryProtection` preference
    /// for the standard fields so a new field matches what the rest of the vault does, and
    /// `VaultFieldValue.isProtected` for a custom one.
    static func canonical(_ string: String, protected: Bool) -> KDBX.ProtectedString.Value {
        protected ? .unprotected(string) : .regular(string)
    }

    /// Whether this value is a secret — the single `Bool` `VaultFieldValue` carries.
    ///
    /// Read off KDBXKit's own reader and writer (`XMLDocumentReader.parseProtectedString`,
    /// `XMLDocumentWriter.write(_:to:)`), never off the case names, which mislead here as badly
    /// as they do in `reboxed(with:)` above:
    ///
    /// - `.lazyInnerCipher` — what the reader emits for every `Protected="True"` node, and what
    ///   the writer re-emits as `Protected="True"`. Encrypted on disk: a secret.
    /// - `.unprotected` — the writer emits this as `Protected="True"` too, and the reader
    ///   produces it for a `Protected="True"` node with an empty value. A secret, despite the
    ///   name.
    /// - `.protectedInMemory` — `ProtectInMemory="True"`, written as cleartext XML, so NOT
    ///   encrypted on disk. It still counts as a secret here: the attribute is the file author's
    ///   statement that the field is sensitive, and revealing it in the UI merely because its
    ///   bytes happen to be cleartext would disclose exactly what the marking asks us not to.
    /// - `.regular` — cleartext with no attribute at all. The only genuinely non-secret case.
    var isProtected: Bool {
        switch self {
        case .lazyInnerCipher, .unprotected, .protectedInMemory: true
        case .regular: false
        }
    }
}

// MARK: - Write-side protection policy

/// Where a string-field write gets its on-disk protection class from.
///
/// Two cases, because the two kinds of field answer "how protected?" from different places. A
/// standard field's protection is a property of the database (`Meta/MemoryProtection`), never a
/// per-field choice, so an existing one must keep exactly the class the file gave it. A custom
/// field's protection IS a per-field user choice (`VaultFieldValue.isProtected`), so a change to
/// it has to actually move the field — which preserving the original class, on its own, would
/// silently ignore.
enum KDBXFieldProtection: Sendable {
    /// No per-field intent to honour: an existing field keeps its exact class, and a field this
    /// entry did not have before is created protected iff `whenNew`.
    case fromFile(whenNew: Bool)

    /// The user's per-field choice. An existing field whose class already agrees with `intent`
    /// keeps that exact class — so a `ProtectInMemory` field survives a value edit as
    /// `ProtectInMemory` rather than being promoted — and one that disagrees moves to the
    /// canonical class for the new intent.
    case chosen(_ intent: Bool)

    /// The flag to use for a field that is not in the entry yet. Both cases carry one.
    var whenNew: Bool {
        switch self {
        case let .fromFile(whenNew): whenNew
        case let .chosen(intent): intent
        }
    }
}

extension Optional where Wrapped == KDBX.MemoryProtectionConfig {
    /// The database's `MemoryProtection` preference for one standard field.
    ///
    /// Defaults follow KeePass's own: only `Password` is protected unless the file says otherwise.
    /// A `nil` config (the element is optional in the schema) means "no preference recorded", not
    /// "protect nothing" — so the same defaults apply.
    func protects(_ field: KDBXStandardField) -> Bool {
        switch field {
        case .title: self?.protectTitle ?? false
        case .userName: self?.protectUserName ?? false
        case .password: self?.protectPassword ?? true
        case .url: self?.protectURL ?? false
        case .notes: self?.protectNotes ?? false
        }
    }
}

// MARK: - Recycle bin

/// The KDBX-side constants for the recycle bin. The pointer itself (`Meta/RecycleBinUUID`,
/// `Meta/RecycleBinEnabled`, `Meta/RecycleBinChanged`) is already modelled by KDBXKit as three
/// `Meta` properties; what is left over is the folder's own presentation, which the format does
/// not derive from the pointer and every client sets by hand.
enum KDBXRecycleBin {
    /// KeePass's built-in icon index for the recycle-bin folder. Not cosmetic: a bin folder
    /// carrying the default folder icon shows up in KeePass/KeePassXC as an ordinary folder that
    /// merely happens to be named by `Meta`, which is exactly the ambiguity the feature exists to
    /// remove.
    static let iconID: UInt32 = 43
}

extension UUID {
    /// KDBX's "not set" sentinel for a UUID-valued `Meta` field: all sixteen bytes zero.
    ///
    /// Spelled out here rather than reached for in KDBXKit because the library's own equivalent
    /// (`UUID.isZero`) is internal to that module. A one-line predicate is a smaller liability
    /// than widening someone else's API surface for it.
    var isAllZeroes: Bool {
        withUnsafeBytes(of: uuid) { bytes in bytes.allSatisfy { $0 == 0 } }
    }
}
