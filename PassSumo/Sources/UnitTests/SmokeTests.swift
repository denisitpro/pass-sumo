import XCTest

/// Proves the harness itself: PassSumoUnitTests is hosted (TEST_HOST/BUNDLE_LOADER) inside a
/// real, signed PassSumo.app process, so `Bundle.main` here is the app's bundle, not the test
/// bundle's own. Every other unit test in this suite depends on that wiring being correct.
final class SmokeTests: XCTestCase {
    func testBundleIdentifierIsTheApp() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "app.passsumo")
    }
}
