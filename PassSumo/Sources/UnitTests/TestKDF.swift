import Foundation
import KDBXKit
@testable import PassSumo

/// A deliberately cheap key derivation, for unit tests that **create** databases.
///
/// `KDBXKitCodec.productionKDF` is ~0.9 s of intentional work per created database, and it is paid
/// again on every save — so a suite that creates a few dozen would spend a minute on a cost it is
/// not testing. Worse, a `make test` that slow is what eventually argues for weakening the real
/// tuple, which is the opposite of what issue #178 was about.
///
/// AES-KDF with one round rather than a low-cost Argon2: this has to be cheap by construction, not
/// cheap by being tuned down, so that nobody reads it as an opinion about Argon2 parameters. What
/// the codec does with the KDF it is handed is identical either way — the parameters go into the
/// header and back out through `UnlockData.computeUnlockKey`.
///
/// The one thing this must never become is the default. Tests that assert on the *production*
/// parameters have to build `KDBXKitCodec()` with no argument, or they would be asserting on this.
enum TestKDF {
    /// Fixed salt, one round. No secret in this repo is protected by it.
    @Sendable static func cheap() throws -> KDFParameters {
        .aes(.init(salt: Data(repeating: 0x2A, count: 32), rounds: 1), additional: [:])
    }

    /// A codec whose created databases use ``cheap()``. Everything else is the real codec.
    static func codec() -> KDBXKitCodec {
        KDBXKitCodec(newDatabaseKDF: cheap)
    }
}
