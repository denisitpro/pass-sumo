import Foundation

/// A heap buffer that is wiped when the last reference to it goes away.
///
/// This exists for exactly one path: the master password, from the moment it leaves the text
/// field until the KDBX codec has derived the key from it. Everywhere else a plain `String` is
/// fine and this type would just be ceremony.
///
/// **What it actually buys, honestly.** It guarantees that *this* copy of the bytes is zeroed
/// before the memory is returned to the allocator, so the secret does not linger in freed heap
/// pages that a later allocation (or a crash report, or a core dump) can read back. That is the
/// whole of it.
///
/// **What it does not buy, and must never be sold as.**
/// - `init(string:)` takes an already-existing Swift `String`. That string's own storage — plus
///   every intermediate `String` AppKit made while the user typed into an `NSSecureTextField`,
///   plus whatever the text system cached — is outside our control and cannot be scrubbed. The
///   secret is *already* in several places in memory before this type ever sees it.
/// - Swift gives no way to pin a page, so the buffer can be paged out to the encrypted swap file.
/// - Any `String` or `Data` handed back out by `withUnsafeBytes` copies is, again, unscrubbable.
///
/// So: this reduces the *window* and the number of unscrubbed copies. It is not a defence against
/// an attacker who can already read this process's memory. Treat it as hygiene, not as a control.
struct SecureBytes: @unchecked Sendable {
    /// Class-backed so that `deinit` — the only place that can run at "last reference released"
    /// time — has somewhere to live. A `struct` cannot have a `deinit`, and a `[UInt8]` array
    /// would be worse than useless here: array storage is copy-on-write and the standard library
    /// is free to reallocate and copy it behind our back, leaving unscrubbed copies we never
    /// learn about. A manually allocated raw buffer is the only shape where "this exact address
    /// range is the only copy, and I zero it myself" is true.
    private final class Storage {
        let buffer: UnsafeMutableRawBufferPointer

        init(count: Int) {
            // `alignment: 1` — these are opaque bytes, nothing is going to be loaded out of them
            // as a wider type.
            buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: max(count, 1), alignment: 1)
        }

        deinit {
            guard let base = buffer.baseAddress else { return }
            // `memset_s` rather than `memset`: the C standard forbids the compiler from eliding
            // it as a dead store, which is precisely the optimisation that silently defeats
            // hand-rolled scrubbing loops (the buffer is never read again, so a plain `memset` is
            // provably dead and may be removed). Declared in `string.h` and reachable from Swift
            // through the Darwin overlay — verified by compiling against the macOS 26 SDK.
            _ = memset_s(base, buffer.count, 0, buffer.count)
            buffer.deallocate()
        }
    }

    private let storage: Storage

    /// Number of secret bytes. Never the buffer's allocated size — a zero-length secret still
    /// allocates one byte because `UnsafeMutableRawBufferPointer.allocate` dislikes zero.
    let count: Int

    /// Not `Sendable` by the compiler's reckoning because `Storage` holds a mutable raw pointer,
    /// but sound in practice: the bytes are written exactly once, during `init`, and after that
    /// every access is read-only. The only later mutation is `Storage.deinit`, which by
    /// definition runs when no other reference exists. Hence `@unchecked Sendable` on the struct.
    init(_ data: Data) {
        storage = Storage(count: data.count)
        count = data.count
        if !data.isEmpty, let base = storage.buffer.baseAddress {
            data.withUnsafeBytes { source in
                base.copyMemory(from: source.baseAddress!, byteCount: data.count)
            }
        }
    }

    init(_ bytes: [UInt8]) {
        self.init(Data(bytes))
    }

    /// UTF-8, because that is what every KDBX key-derivation path wants.
    ///
    /// See the type doc: the `String` passed in here is already an unscrubbable copy. This
    /// initialiser is the point where we *start* controlling the secret, not the point where the
    /// secret first exists.
    init(string: String) {
        self.init(Data(string.utf8))
    }

    /// Read-only access to the raw bytes. The pointer is valid only for the duration of `body` —
    /// copying it out re-introduces exactly the unscrubbable copy this type exists to limit.
    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeRawBufferPointer(start: storage.buffer.baseAddress, count: count))
    }

    /// Materialises the secret as a `String`, for the one hop where an API demands one (the KDBX
    /// codec's `VaultCredentials.password`). The returned `String` is an ordinary Swift string
    /// and **cannot** be scrubbed — keep it as short-lived as the call site allows. `nil` if the
    /// bytes are not valid UTF-8, which for a password typed by a human they always are.
    func revealedString() -> String? {
        withUnsafeBytes { String(bytes: $0, encoding: .utf8) }
    }
}

extension SecureBytes: Equatable {
    /// Byte comparison for tests and for "did the stored secret round-trip".
    ///
    /// Deliberately **not** constant-time: it short-circuits on the first differing byte, and on
    /// length before that. Never use it to check a user-supplied secret against a stored one —
    /// that is a timing oracle. pass-sumo has no such comparison (KDBX authenticates the password
    /// through the HMAC in the header, not by comparing plaintext), and if one ever appears it
    /// needs a dedicated constant-time helper, not this operator.
    static func == (lhs: SecureBytes, rhs: SecureBytes) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return lhs.withUnsafeBytes { l in
            rhs.withUnsafeBytes { r in
                memcmp(l.baseAddress!, r.baseAddress!, lhs.count) == 0
            }
        }
    }
}
