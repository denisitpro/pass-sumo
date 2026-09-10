import XCTest

@testable import PassSumo

/// `ButtonSurfaceState` (`DesignStyles.swift`) is the pure appearance resolution behind
/// `TokenButtonSurface` and `GlyphButtonSurface` — pulled out precisely so the combination of
/// hover, press, focus and enablement is testable without driving SwiftUI's real hover or focus
/// system (issue #64).
final class ButtonSurfaceStateTests: XCTestCase {
    func testRestingStateIsNeitherHighlightedNorRinged() {
        let state = ButtonSurfaceState(isEnabled: true, isHovered: false, isPressed: false, isFocused: false)
        XCTAssertFalse(state.isHighlighted)
        XCTAssertFalse(state.showsFocusRing)
    }

    func testHoverAndPressBothHighlightButNeitherDrawsTheRing() {
        let hovered = ButtonSurfaceState(isEnabled: true, isHovered: true, isPressed: false, isFocused: false)
        XCTAssertTrue(hovered.isHighlighted)
        XCTAssertFalse(hovered.showsFocusRing)

        let pressed = ButtonSurfaceState(isEnabled: true, isHovered: false, isPressed: true, isFocused: false)
        XCTAssertTrue(pressed.isHighlighted)
        XCTAssertFalse(pressed.showsFocusRing)
    }

    /// The reason `showsFocusRing` exists as its own property rather than folding into
    /// `isHighlighted`: the mockup's `:focus-visible` is a separate pseudo-class from `:hover`, so a
    /// keyboard-focused control that is also under the pointer must show both treatments at once.
    func testFocusRingIsOrthogonalToHoverAndPress() {
        let focusedOnly = ButtonSurfaceState(isEnabled: true, isHovered: false, isPressed: false, isFocused: true)
        XCTAssertFalse(focusedOnly.isHighlighted)
        XCTAssertTrue(focusedOnly.showsFocusRing)

        let focusedAndHovered = ButtonSurfaceState(isEnabled: true, isHovered: true, isPressed: false, isFocused: true)
        XCTAssertTrue(focusedAndHovered.isHighlighted)
        XCTAssertTrue(focusedAndHovered.showsFocusRing)
    }

    /// A disabled control never highlights, whatever the pointer is doing — matching the existing
    /// hover/press rule this test locks in the same way for the newly added focus input.
    func testDisablingSuppressesHighlightRegardlessOfHoverOrPress() {
        let state = ButtonSurfaceState(isEnabled: false, isHovered: true, isPressed: true, isFocused: false)
        XCTAssertFalse(state.isHighlighted)
    }
}
