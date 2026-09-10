import Foundation
import XCTest

@testable import PassSumo

/// `AppVersionInfo.current(infoDictionary:osVersion:)` never touches `Bundle.main`/`ProcessInfo`
/// directly in these tests — every input is supplied explicitly, per its own doc comment.
final class SettingsAppVersionInfoTests: XCTestCase {
    private let osVersion = OperatingSystemVersion(majorVersion: 15, minorVersion: 1, patchVersion: 2)

    func testAssemblesSummaryFromACompletePlist() {
        let info = AppVersionInfo.current(
            infoDictionary: [
                "CFBundleShortVersionString": "1.2.3",
                "CFBundleVersion": "42",
                "GitRevision": "abc1234",
            ],
            osVersion: osVersion
        )

        XCTAssertEqual(info.shortVersion, "1.2.3")
        XCTAssertEqual(info.build, "42")
        XCTAssertEqual(info.gitRevision, "abc1234")
        XCTAssertEqual(info.osVersion, "15.1.2")
        XCTAssertEqual(info.summary, "PassSumo 1.2.3 (build 42) · abc1234 · macOS 15.1.2")
    }

    /// The repo currently has no git tags at all, so `git describe --tags --abbrev=0` in
    /// project.yml's stamping phase has nothing to describe and the template's own placeholder
    /// (`"0.0.0"`) is what a real unsigned build shows today — not a hypothetical.
    func testMissingPlistFallsBackToProjectYmlPlaceholders() {
        let info = AppVersionInfo.current(infoDictionary: nil, osVersion: osVersion)

        XCTAssertEqual(info.shortVersion, AppVersionInfo.unknownShortVersion)
        XCTAssertEqual(info.build, AppVersionInfo.unknownBuild)
        XCTAssertEqual(info.gitRevision, AppVersionInfo.unknownGitRevision)
        XCTAssertEqual(info.summary, "PassSumo 0.0.0 (build 1) · dev · macOS 15.1.2")
    }

    /// A plist present but missing just the `GitRevision` key — e.g. a stamping phase that ran but
    /// whose `PlistBuddy` add/set both failed — falls back only for that one field, independently
    /// of the other two.
    func testMissingSingleKeyFallsBackOnlyForThatField() {
        let info = AppVersionInfo.current(
            infoDictionary: [
                "CFBundleShortVersionString": "1.0.0",
                "CFBundleVersion": "7",
            ],
            osVersion: osVersion
        )

        XCTAssertEqual(info.shortVersion, "1.0.0")
        XCTAssertEqual(info.build, "7")
        XCTAssertEqual(info.gitRevision, AppVersionInfo.unknownGitRevision)
    }

    /// A key present with the wrong type (e.g. a plist edited by hand) is treated the same as a
    /// missing key rather than crashing on a forced cast.
    func testWrongValueTypeFallsBackLikeAMissingKey() {
        let info = AppVersionInfo.current(
            infoDictionary: ["CFBundleShortVersionString": 123],
            osVersion: osVersion
        )

        XCTAssertEqual(info.shortVersion, AppVersionInfo.unknownShortVersion)
    }
}
