import XCTest

@testable import PassSumo

/// `PasswordRevealState` (`MasterPasswordField.swift`) is the pure decision behind the reveal
/// toggle on the unlock screen and in `CreateDatabaseSheet`. The rule that matters most — reveal
/// never survives the user's attention leaving the screen — is tested here without needing XCTest
/// to drive a real `NSWindow` through a key-status change, the same reasoning `BiometricUnlockRecovery`
/// is tested under in `SecurityBiometricUnlockTests`.
final class UnlockPasswordRevealTests: XCTestCase {
    func testStartsHidden() {
        XCTAssertFalse(PasswordRevealState().isRevealed)
    }

    func testToggleFlipsRevealedState() {
        var state = PasswordRevealState()
        state.toggle()
        XCTAssertTrue(state.isRevealed)
        state.toggle()
        XCTAssertFalse(state.isRevealed)
    }

    /// The one rule that must never be skipped: whatever the current state, `hide()` always lands
    /// on hidden — never toggles, never a no-op when already hidden.
    func testHideAlwaysLandsOnHiddenRegardlessOfStartingState() {
        var revealed = PasswordRevealState()
        revealed.toggle()
        XCTAssertTrue(revealed.isRevealed)
        revealed.hide()
        XCTAssertFalse(revealed.isRevealed)

        var alreadyHidden = PasswordRevealState()
        alreadyHidden.hide()
        XCTAssertFalse(alreadyHidden.isRevealed)
    }
}
