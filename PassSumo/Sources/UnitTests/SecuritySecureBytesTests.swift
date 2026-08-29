import Foundation
import XCTest

@testable import PassSumo

/// `SecureBytes` is deliberately modest — it guarantees that *its own* buffer is zeroed before the
/// memory is reused, and nothing more. There is no way to assert the scrub from Swift (the memory
/// is deallocated in the same `deinit` that wipes it, and reading it afterwards is undefined
/// behaviour, not a test), so what is tested here is the contract callers depend on: the bytes go
/// in and come back out unchanged, for every input shape the master-password path can produce.
final class SecuritySecureBytesTests: XCTestCase {
    func testRoundTripsUTF8Strings() {
        let secret = SecureBytes(string: "correct horse battery staple")
        XCTAssertEqual(secret.count, 28)
        XCTAssertEqual(secret.revealedString(), "correct horse battery staple")
    }

    /// Master passwords are not ASCII. A byte-count-vs-character-count confusion here would
    /// truncate a passphrase and produce a "wrong password" the user cannot explain.
    func testRoundTripsNonASCIIStrings() {
        let passphrase = "пароль-Ünïcode-🔐"
        let secret = SecureBytes(string: passphrase)
        XCTAssertEqual(secret.count, Data(passphrase.utf8).count)
        XCTAssertEqual(secret.revealedString(), passphrase)
    }

    func testRoundTripsArbitraryBytes() {
        let bytes: [UInt8] = [0x00, 0xFF, 0x7F, 0x80, 0x00, 0x01]
        let secret = SecureBytes(bytes)
        XCTAssertEqual(secret.count, 6)
        secret.withUnsafeBytes { XCTAssertEqual(Array($0), bytes) }
    }

    /// Embedded NULs must survive: a KDBX key file's bytes go through this type too, and a
    /// C-string-shaped implementation would silently truncate at the first zero.
    func testPreservesEmbeddedNulBytes() {
        let bytes: [UInt8] = [0x41, 0x00, 0x42]
        SecureBytes(bytes).withUnsafeBytes { XCTAssertEqual(Array($0), bytes) }
    }

    func testHandlesEmptyInput() {
        let empty = SecureBytes(Data())
        XCTAssertEqual(empty.count, 0)
        empty.withUnsafeBytes { XCTAssertEqual($0.count, 0) }
        XCTAssertEqual(empty.revealedString(), "")
    }

    func testEqualityComparesContentNotIdentity() {
        XCTAssertEqual(SecureBytes(string: "same"), SecureBytes(string: "same"))
        XCTAssertNotEqual(SecureBytes(string: "same"), SecureBytes(string: "different"))
        XCTAssertNotEqual(SecureBytes(string: "ab"), SecureBytes(string: "abc"))
        XCTAssertEqual(SecureBytes(Data()), SecureBytes(Data()))
    }

    func testRevealedStringIsNilForNonUTF8Bytes() {
        // 0xFF is not a legal UTF-8 lead byte, so this is a byte sequence with no string form.
        XCTAssertNil(SecureBytes([0xFF, 0xFE]).revealedString())
    }

    /// Copies share the same storage, and the storage is only wiped when the last of them goes
    /// away. If this were wrong, passing a `SecureBytes` to a function would either wipe it early
    /// or duplicate it into an unscrubbed second buffer.
    func testCopiesShareStorageAndStayValid() {
        var original: SecureBytes? = SecureBytes(string: "shared")
        let copy = original!
        original = nil
        XCTAssertEqual(copy.revealedString(), "shared")
    }
}
