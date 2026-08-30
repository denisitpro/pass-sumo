import AppKit
import Foundation
import XCTest

@testable import PassSumo

/// The whole suite runs against `FakePasteboard` and a hand-moved clock (both in
/// `SecuritySupportTests.swift`), so it never touches the developer's real clipboard and never
/// waits for a `Timer`. Total wall-clock cost is microseconds; nothing here sleeps.
@MainActor
final class SecurityClipboardTests: XCTestCase {
    private var pasteboard: FakePasteboard!
    private var clock: SecurityTestClock!
    private var service: ClipboardService!

    override func setUp() async throws {
        try await super.setUp()
        pasteboard = FakePasteboard()
        clock = SecurityTestClock()
        service = ClipboardService(pasteboard: pasteboard, clearInterval: 30, now: clock.provider)
    }

    // MARK: - Sensitivity markers

    /// Both markers must be present, and they are not interchangeable: `com.apple.is-sensitive` is
    /// what keeps the item out of Universal Clipboard, `org.nspasteboard.ConcealedType` is what
    /// third-party clipboard managers look at. Losing either one silently reopens a different leak,
    /// and the string content would still look right — hence a test on the item itself.
    func testCopiedItemCarriesBothSensitivityMarkers() {
        let item = ClipboardService.makeItem(secret: "hunter2")
        XCTAssertEqual(item.string(forType: .string), "hunter2")
        XCTAssertTrue(item.types.contains(ClipboardService.SensitivityMarker.concealed))
        XCTAssertTrue(item.types.contains(ClipboardService.SensitivityMarker.isSensitive))
    }

    func testSensitivityMarkerIdentifiersAreTheAgreedStrings() {
        // Spelled out because they are magic strings with no SDK constants: a typo would disable
        // the protection with no compile error and no runtime symptom.
        XCTAssertEqual(ClipboardService.SensitivityMarker.concealed.rawValue, "org.nspasteboard.ConcealedType")
        XCTAssertEqual(ClipboardService.SensitivityMarker.isSensitive.rawValue, "com.apple.is-sensitive")
    }

    // MARK: - Copy

    func testCopyWritesTheSecretAndStartsTheCountdown() {
        service.copy("s3cret")
        XCTAssertEqual(pasteboard.currentString, "s3cret")
        XCTAssertTrue(service.isHoldingSecret)
        XCTAssertEqual(service.secondsRemaining, 30)
    }

    func testCountdownTracksTheInjectedClock() {
        service.copy("s3cret")
        clock.advance(10)
        service.tick()
        XCTAssertEqual(service.secondsRemaining, 20)
        clock.advance(19)
        service.tick()
        XCTAssertEqual(service.secondsRemaining, 1)
        XCTAssertTrue(service.isHoldingSecret)
    }

    func testClearsWhenTheIntervalElapses() {
        service.copy("s3cret")
        clock.advance(30)
        service.tick()
        XCTAssertNil(pasteboard.currentString)
        XCTAssertFalse(service.isHoldingSecret)
        XCTAssertEqual(service.secondsRemaining, 0)
    }

    func testPerCopyIntervalOverridesTheDefault() {
        service.copy("s3cret", clearAfter: 5)
        XCTAssertEqual(service.secondsRemaining, 5)
        clock.advance(4)
        service.tick()
        XCTAssertEqual(pasteboard.currentString, "s3cret")
        clock.advance(1)
        service.tick()
        XCTAssertNil(pasteboard.currentString)
    }

    // MARK: - The `changeCount` guard

    /// The single most important behaviour here. A user copies a password, then twenty seconds
    /// later copies a paragraph they were writing. When our timer fires it must leave that
    /// paragraph alone — a security feature that silently destroys the user's own clipboard data is
    /// worse than the leak it prevents.
    func testDoesNotClearWhenSomethingElseTookOverThePasteboard() {
        service.copy("s3cret")
        pasteboard.simulateForeignCopy()
        let clearsBefore = pasteboard.clearCallCount

        clock.advance(60)
        service.tick()

        XCTAssertEqual(pasteboard.clearCallCount, clearsBefore, "cleared a pasteboard that was no longer ours")
        XCTAssertFalse(service.isHoldingSecret)
        XCTAssertEqual(service.secondsRemaining, 0)
    }

    func testClearNowReportsWhetherItActuallyCleared() {
        service.copy("s3cret")
        XCTAssertTrue(service.clearNow())

        service.copy("s3cret")
        pasteboard.simulateForeignCopy()
        XCTAssertFalse(service.clearNow())
    }

    func testClearNowWithNothingCopiedIsANoOp() {
        let clearsBefore = pasteboard.clearCallCount
        XCTAssertFalse(service.clearNow())
        XCTAssertEqual(pasteboard.clearCallCount, clearsBefore)
    }

    // MARK: - Re-arming

    /// Copying again restarts the countdown instead of leaving the first copy's deadline in place.
    /// Without this, the second secret would be wiped early — and the `changeCount` guard cannot
    /// catch it, because both copies are ours.
    func testCopyingAgainRestartsTheCountdown() {
        service.copy("first")
        clock.advance(25)
        service.tick()
        XCTAssertEqual(service.secondsRemaining, 5)

        service.copy("second")
        XCTAssertEqual(service.secondsRemaining, 30)

        clock.advance(10)
        service.tick()
        XCTAssertEqual(pasteboard.currentString, "second")
        XCTAssertEqual(service.secondsRemaining, 20)
    }

    func testCancelAutoClearStopsTheCountdownButLeavesTheSecret() {
        service.copy("s3cret")
        service.cancelAutoClear()
        XCTAssertEqual(service.secondsRemaining, 0)
        XCTAssertFalse(service.isHoldingSecret)

        clock.advance(600)
        service.tick()
        XCTAssertEqual(pasteboard.currentString, "s3cret", "cancelled countdown still cleared the pasteboard")
    }

    func testTickBeforeAnyCopyDoesNothing() {
        clock.advance(600)
        service.tick()
        XCTAssertEqual(service.secondsRemaining, 0)
        XCTAssertEqual(pasteboard.clearCallCount, 0)
    }
}
