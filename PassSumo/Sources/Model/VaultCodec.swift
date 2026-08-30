import Foundation

/// Reads and writes a whole `.kdbx` file. One conforming type per supported codec — today that's
/// the real KDBX 4.x codec (`Sources/KDBX`, owned separately) plus `InMemoryVaultCodec` in this
/// file's sibling, a no-crypto fake for SwiftUI previews and `-ui-testing` XCUITest runs.
///
/// HARD REQUIREMENT: `decode` followed by `encode` of an UNTOUCHED file must not lose entries,
/// fields, attachments, history, custom data, or icons written by another KDBX client (KeePassXC,
/// KeePassium, Strongbox, …). `Vault` only models the fields pass-sumo's UI edits — everything
/// else a codec reads but can't represent in `Vault` MUST survive by round-tripping through
/// `DecodedVault.opaque` instead of being silently dropped on save. This is the interop guarantee
/// the whole product depends on (repo CLAUDE.md: "Interop is a hard requirement").
protocol VaultCodec: Sendable {
    /// Decode a whole `.kdbx` file. Throws `VaultError`. May be slow — Argon2 key derivation is
    /// deliberately expensive (~1s) — so callers MUST run this off the main actor
    /// (see `VaultStore.open`, which does).
    func decode(fileData: Data, credentials: VaultCredentials) throws -> DecodedVault

    /// Re-encode `vault` back into file bytes. `origin` is what `decode` (or `makeEmpty`) returned
    /// for this same database; passing it back lets the codec restore whatever it stashed in
    /// `opaque` for fields `Vault` does not model. `origin` is `nil` only when a codec is asked to
    /// encode a `Vault` it never itself produced (not expected in normal `VaultStore` use, but not
    /// forbidden — a conforming codec should still produce a valid, if minimal, file).
    func encode(_ vault: Vault, credentials: VaultCredentials, origin: DecodedVault?) throws -> Data

    /// A brand-new, empty database — no entries, no groups beyond whatever the format requires
    /// (e.g. KDBX's implicit root group).
    func makeEmpty(name: String, credentials: VaultCredentials) throws -> DecodedVault
}

/// Marker for a codec's private round-trip state, stashed in `DecodedVault.opaque` between a
/// `decode` and the matching `encode`. Deliberately empty — it exists only to give `opaque` a
/// named, `Sendable`-constrained type instead of an unconstrained `any Sendable`; see
/// `DecodedVault.opaque`'s doc comment for why that's worth doing.
///
/// A codec that needs round-trip state defines its own private struct/class conforming to this
/// (e.g. the KDBX codec's `struct KDBXOrigin: VaultCodecState { let xmlDocument: ...; let headerParams: ... }`)
/// and casts it back out with `origin?.opaque as? KDBXOrigin` on encode.
protocol VaultCodecState: Sendable {}

/// Carrier returned by `decode`/`makeEmpty`: the parsed `Vault` plus whatever the codec needs to
/// round-trip losslessly on the next `encode`.
struct DecodedVault: Sendable {
    var vault: Vault

    /// Codec-private round-trip state — e.g. the original XML tree, unmodeled header params,
    /// attachments/history/custom icons the codec read but `Vault` has no field for.
    ///
    /// **Deviation from the architecture contract**, which specifies `opaque: (any Sendable)?`:
    /// an unconstrained `any Sendable` existential still typechecks in that slot (the box itself
    /// is `Sendable`), but it gives every codec author the same footgun — nothing stops
    /// `opaque = 42` from compiling when a codec's `encode` actually expects its own state type,
    /// and a mismatched `as?` downcast then fails silently (falls to the `nil` branch) instead of
    /// at the call site where the mistake was made. Narrowing the existential to the
    /// `VaultCodecState` marker protocol keeps the SAME intent — opaque, codec-owned, `Sendable`,
    /// stashed on decode and read back on encode — while giving each codec a self-documenting type
    /// to conform its own state struct to. `InMemoryVaultCodec` doesn't need this at all (its
    /// round-trip is a plain dictionary lookup, no unmodeled data to carry), so it always leaves
    /// this `nil`.
    var opaque: (any VaultCodecState)?
}
