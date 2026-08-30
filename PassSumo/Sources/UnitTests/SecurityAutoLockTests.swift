import Foundation
import XCTest

@testable import PassSumo

/// Driven entirely by `FakeLockEventSource` and a hand-moved clock, so a five-minute timeout and
/// three different system notifications are exercised without a single real timer or a single real
/// notification post. Posting a genuine `com.apple.screenIsLocked` from a test would signal every
/// other app on the machine.
@MainActor
final class SecurityAutoLockTests: XCTestCase {
    private var clock: SecurityTestClock!
    private var events: FakeLockEventSource!
    private var lockCount = 0
    private var controller: AutoLockController!

    override func setUp() async throws {
        try await super.setUp()
        clock = SecurityTestClock()
        events = FakeLockEventSource()
        lockCount = 0
        controller = AutoLockController(
            idleTimeout: 300,
            eventSource: events,
            now: clock.provider,
            onLock: { [self] in lockCount += 1 }
        )
    }

    // MARK: - Initial state

    func testStartsLockedAndDoesNotObserveUntilUnlocked() {
        XCTAssertTrue(controller.isLocked)
        XCTAssertNil(controller.lastLockReason)
        XCTAssertFalse(events.isObserving, "subscribed to system events while still locked")
    }

    func testUnlockingStartsObservingAndTheCountdown() {
        controller.vaultDidUnlock()
        XCTAssertFalse(controller.isLocked)
        XCTAssertTrue(events.isObserving)
        XCTAssertEqual(controller.secondsUntilIdleLock, 300)
    }

    // MARK: - Idle timeout

    func testLocksAfterTheIdleTimeoutElapses() {
        controller.vaultDidUnlock()
        clock.advance(299)
        controller.tick()
        XCTAssertFalse(controller.isLocked)
        XCTAssertEqual(controller.secondsUntilIdleLock, 1)

        clock.advance(1)
        controller.tick()
        XCTAssertTrue(controller.isLocked)
        XCTAssertEqual(controller.lastLockReason, .idleTimeout)
        XCTAssertEqual(lockCount, 1)
        XCTAssertNil(controller.secondsUntilIdleLock)
    }

    /// `noteActivity()` is the whole activity signal — there is deliberately no global event
    /// monitor — so a controller that ignored it would lock a user mid-typing.
    func testActivityResetsTheCountdown() {
        controller.vaultDidUnlock()
        clock.advance(290)
        controller.tick()
        controller.noteActivity()
        XCTAssertEqual(controller.secondsUntilIdleLock, 300)

        clock.advance(299)
        controller.tick()
        XCTAssertFalse(controller.isLocked, "activity did not push the deadline out")

        clock.advance(1)
        controller.tick()
        XCTAssertTrue(controller.isLocked)
    }

    func testActivityWhileLockedIsIgnored() {
        controller.vaultDidUnlock()
        clock.advance(300)
        controller.tick()
        XCTAssertTrue(controller.isLocked)

        controller.noteActivity()
        XCTAssertTrue(controller.isLocked, "noteActivity() unlocked the vault")
        XCTAssertNil(controller.secondsUntilIdleLock)
    }

    func testTickWhileLockedDoesNotFireOnLockAgain() {
        controller.vaultDidUnlock()
        clock.advance(300)
        controller.tick()
        clock.advance(300)
        controller.tick()
        XCTAssertEqual(lockCount, 1)
    }

    // MARK: - Immediate system events

    /// Each of the three system events locks at once rather than waiting out the timeout: the user
    /// has visibly left the session, and five minutes of decrypted vault in a slept or switched-away
    /// session is exactly what this class exists to prevent.
    func testEachSystemEventLocksImmediately() {
        for reason in [LockReason.systemSleep, .screenLocked, .sessionResignedActive] {
            let clock = SecurityTestClock()
            let events = FakeLockEventSource()
            var locks = 0
            let controller = AutoLockController(
                idleTimeout: 300, eventSource: events, now: clock.provider, onLock: { locks += 1 }
            )
            controller.vaultDidUnlock()

            events.fire(reason)

            XCTAssertTrue(controller.isLocked, "\(reason) did not lock")
            XCTAssertEqual(controller.lastLockReason, reason)
            XCTAssertEqual(locks, 1)
        }
    }

    /// Closing the lid posts `willSleep` *and* `screenIsLocked`. `onLock` tears down decrypted
    /// state, so it must run exactly once no matter how many events describe the same departure.
    func testOverlappingSystemEventsLockOnlyOnce() {
        controller.vaultDidUnlock()
        events.fire(.systemSleep)
        events.fire(.screenLocked)
        events.fire(.sessionResignedActive)
        XCTAssertEqual(lockCount, 1)
        XCTAssertEqual(controller.lastLockReason, .systemSleep, "a later event overwrote the real reason")
    }

    func testExplicitLockIsRecordedAsUserRequested() {
        controller.vaultDidUnlock()
        controller.lock(reason: .userRequested)
        XCTAssertTrue(controller.isLocked)
        XCTAssertEqual(controller.lastLockReason, .userRequested)
        XCTAssertEqual(lockCount, 1)
    }

    // MARK: - Re-unlock and teardown

    func testUnlockingAgainClearsTheReasonAndReusesTheExistingSubscription() {
        controller.vaultDidUnlock()
        events.fire(.systemSleep)
        XCTAssertEqual(controller.lastLockReason, .systemSleep)

        controller.vaultDidUnlock()
        XCTAssertFalse(controller.isLocked)
        XCTAssertNil(controller.lastLockReason)
        XCTAssertEqual(events.startCount, 1, "re-subscribed on every unlock — observers would accumulate")
    }

    func testStopUnsubscribesWithoutLocking() {
        controller.vaultDidUnlock()
        controller.stop()
        XCTAssertEqual(events.stopCount, 1)
        XCTAssertFalse(events.isObserving)
        XCTAssertFalse(controller.isLocked, "stop() locked the vault; that is lock()'s job")
        XCTAssertEqual(lockCount, 0)
    }

    func testChangingTheTimeoutTakesEffectOnTheNextActivity() {
        controller.vaultDidUnlock()
        controller.idleTimeout = 60
        controller.noteActivity()
        XCTAssertEqual(controller.secondsUntilIdleLock, 60)

        clock.advance(60)
        controller.tick()
        XCTAssertTrue(controller.isLocked)
    }
}
