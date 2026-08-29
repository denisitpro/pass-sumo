import AppKit
import Foundation
import XCTest

@testable import PassSumo

// MARK: - Shared test doubles
//
// These live in a `Security*Tests.swift` file rather than a support file because the unit-test
// target picks its sources up by glob. They are shared by `SecurityClipboardTests`,
// `SecurityAutoLockTests` and `SecurityBiometricUnlockTests`, so they are defined once here and the
// tests at the bottom of this file check the doubles themselves — a fake that lies makes every
// suite that uses it lie too, which is the failure mode nobody notices.

/// A clock the tests move by hand.
///
/// Every timed type in `Sources/Security` takes a `@Sendable () -> Date`, which is exactly so that
/// a five-minute auto-lock and a thirty-second clipboard countdown can be exercised in
/// microseconds. Locked because the closure is `@Sendable` and the compiler cannot know the tests
/// are single-threaded; the lock costs nothing at this scale.
final class SecurityTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        current = start
    }

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current += seconds }
    }

    /// Passed straight into the production types.
    var provider: @Sendable () -> Date {
        { [self] in now }
    }
}

/// Stands in for `NSPasteboard.general` so the suite never touches the developer's real clipboard,
/// and so `changeCount` can be moved to simulate another app taking ownership.
@MainActor
final class FakePasteboard: PasteboardWriting {
    private(set) var changeCount: Int = 0
    private(set) var items: [NSPasteboardItem] = []
    private(set) var clearCallCount: Int = 0

    @discardableResult
    func clearContents() -> Int {
        items.removeAll()
        clearCallCount += 1
        changeCount += 1
        return changeCount
    }

    @discardableResult
    func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool {
        items = objects.compactMap { $0 as? NSPasteboardItem }
        changeCount += 1
        return true
    }

    /// Another process (or the user) put something else on the pasteboard.
    func simulateForeignCopy() {
        items.removeAll()
        changeCount += 1
    }

    var currentString: String? { items.first?.string(forType: .string) }
}

/// Fires the "lock now" events synchronously, so the auto-lock tests never post a real
/// `com.apple.screenIsLocked` at the whole machine.
@MainActor
final class FakeLockEventSource: LockEventSource {
    private var handler: ((LockReason) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(_ handler: @escaping @MainActor (LockReason) -> Void) {
        startCount += 1
        self.handler = handler
    }

    func stop() {
        stopCount += 1
        handler = nil
    }

    var isObserving: Bool { handler != nil }

    func fire(_ reason: LockReason) {
        handler?(reason)
    }
}

/// An in-memory `SecretStore`.
///
/// This is what lets the biometric tests run at all: the real store prompts for Touch ID and writes
/// to the login keychain, neither of which belongs in a suite that has to pass unattended in CI.
/// `@unchecked Sendable` because `SecretStore` is `Sendable` (the production store is a stateless
/// struct) while a fake needs mutable state; the `NSLock` makes that sound rather than merely
/// asserted.
final class FakeSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [VaultKeyIdentifier: SecureBytes] = [:]

    /// Set to make the next call fail, so error paths are reachable without a real keychain.
    var nextError: BiometricUnlockError?
    private(set) var retrieveCount = 0
    private(set) var lastReason: String?

    init() {}

    func store(_ secret: SecureBytes, for id: VaultKeyIdentifier) throws {
        if let error = nextError { nextError = nil; throw error }
        lock.withLock { items[id] = secret }
    }

    func retrieve(for id: VaultKeyIdentifier, reason: String) throws -> SecureBytes {
        retrieveCount += 1
        lastReason = reason
        if let error = nextError { nextError = nil; throw error }
        guard let secret = lock.withLock({ items[id] }) else {
            throw BiometricUnlockError.notEnrolledForThisVault
        }
        return secret
    }

    func delete(for id: VaultKeyIdentifier) throws {
        if let error = nextError { nextError = nil; throw error }
        _ = lock.withLock { items.removeValue(forKey: id) }
    }

    func hasSecret(for id: VaultKeyIdentifier) throws -> Bool {
        if let error = nextError { nextError = nil; throw error }
        return lock.withLock { items[id] != nil }
    }
}

// MARK: - Tests of the doubles

final class SecuritySupportTests: XCTestCase {
    func testTestClockAdvancesOnlyWhenAsked() {
        let clock = SecurityTestClock(Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(clock.provider().timeIntervalSince1970, 1000)
        clock.advance(45)
        XCTAssertEqual(clock.provider().timeIntervalSince1970, 1045)
    }

    /// The fake store is the substrate for every biometric test, so its round-trip and its
    /// "nothing stored" behaviour are asserted directly rather than assumed.
    func testFakeSecretStoreRoundTripsAndReportsAbsence() throws {
        let store = FakeSecretStore()
        let id = VaultKeyIdentifier("vault-a")
        XCTAssertFalse(try store.hasSecret(for: id))

        try store.store(SecureBytes(string: "correct horse"), for: id)
        XCTAssertTrue(try store.hasSecret(for: id))
        XCTAssertEqual(try store.retrieve(for: id, reason: "test"), SecureBytes(string: "correct horse"))

        try store.delete(for: id)
        XCTAssertFalse(try store.hasSecret(for: id))
        XCTAssertThrowsError(try store.retrieve(for: id, reason: "test")) { error in
            XCTAssertEqual(error as? BiometricUnlockError, .notEnrolledForThisVault)
        }
    }

    func testFakeSecretStoreKeepsVaultsSeparate() throws {
        let store = FakeSecretStore()
        try store.store(SecureBytes(string: "aaa"), for: VaultKeyIdentifier("a"))
        try store.store(SecureBytes(string: "bbb"), for: VaultKeyIdentifier("b"))
        XCTAssertEqual(try store.retrieve(for: VaultKeyIdentifier("a"), reason: ""), SecureBytes(string: "aaa"))
        XCTAssertEqual(try store.retrieve(for: VaultKeyIdentifier("b"), reason: ""), SecureBytes(string: "bbb"))
    }

    @MainActor
    func testFakePasteboardTracksChangeCount() {
        let pasteboard = FakePasteboard()
        let before = pasteboard.changeCount
        pasteboard.clearContents()
        XCTAssertGreaterThan(pasteboard.changeCount, before)
        pasteboard.simulateForeignCopy()
        XCTAssertGreaterThan(pasteboard.changeCount, before + 1)
    }
}
