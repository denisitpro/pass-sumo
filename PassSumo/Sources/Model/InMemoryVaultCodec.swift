import Foundation

/// No-crypto fake `VaultCodec` for SwiftUI previews and `-ui-testing` XCUITest launches (the real
/// crypto lives in `Sources/KDBX`, owned separately — see the architecture contract). Deterministic
/// and in-memory: no Argon2, no file format, no timing characteristic to accidentally depend on.
///
/// There's no real ciphertext for `encode` to produce, so it can't literally serialize `vault`
/// into `fileData` and have `decode` recover it independent of any in-process state — instead a
/// dictionary keyed by password stands in for "the encrypted bytes," which is exactly what the
/// architecture contract asks for ("keeps a dictionary keyed by password"). The practical effect
/// is the same shape a real KDF gives you: present the wrong password and there's no matching
/// entry, so decode fails closed with `.wrongCredentials` — without paying for one.
final class InMemoryVaultCodec: VaultCodec, @unchecked Sendable {
    // `@unchecked`: `storage` is only ever touched while holding `lock`. A plain lock rather than
    // an actor because `VaultCodec`'s requirements are synchronous `throws`, not `async throws` —
    // matching the real KDBX codec's shape, where `VaultStore` is the one deciding to run Argon2
    // off the main actor, not the codec itself.
    private let lock = NSLock()
    private var storage: [String: Vault] = [:]   // keyed by password

    init() {}

    func decode(fileData: Data, credentials: VaultCredentials) throws -> DecodedVault {
        guard let handle = String(data: fileData, encoding: .utf8) else {
            throw VaultError.notAKDBXFile
        }
        lock.lock(); defer { lock.unlock() }
        // `handle` is the password this vault was last `encode`d with. A mismatch against the
        // credentials just presented covers both a genuinely wrong password AND `fileData` that
        // was never produced by this codec's `encode` at all — both are `.wrongCredentials` to a
        // caller, same as a real KDF failing to derive the right key.
        guard handle == credentials.password, let vault = storage[handle] else {
            throw VaultError.wrongCredentials
        }
        return DecodedVault(vault: vault, opaque: nil)
    }

    func encode(_ vault: Vault, credentials: VaultCredentials, origin: DecodedVault?) throws -> Data {
        lock.lock()
        storage[credentials.password] = vault
        lock.unlock()
        guard let data = credentials.password.data(using: .utf8) else {
            throw VaultError.io("password is not representable as UTF-8")
        }
        return data
    }

    func makeEmpty(name: String, credentials: VaultCredentials) throws -> DecodedVault {
        let empty = Vault(name: name, groups: [], entries: [])
        lock.lock()
        storage[credentials.password] = empty
        lock.unlock()
        return DecodedVault(vault: empty, opaque: nil)
    }
}
