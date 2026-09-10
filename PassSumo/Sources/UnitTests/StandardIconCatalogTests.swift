import AppKit
import XCTest
@testable import PassSumo

/// Tests for the KDBX icon-index → SF Symbol table (`Sources/Icons`, issue #89).
///
/// The one that matters is `testEverySymbolNameResolves`. A misspelled SF Symbol name is a string
/// literal that compiles, links, ships, and then draws **nothing at all** — `Image(systemName:)`
/// renders an empty view rather than complaining, so a typo in this table would reach the App Store
/// as a blank square in the icon picker and nowhere else. There is no compiler check for it, which
/// is exactly why there is a test.
final class StandardIconCatalogTests: XCTestCase {
    /// KeePass's built-in set is 0…68 and the table is indexed by id, so a dropped or duplicated
    /// line silently shifts every icon after it onto the wrong index — a database would open with
    /// its icons subtly wrong rather than obviously broken.
    func testCatalogCoversAllSixtyNineStandardIcons() {
        XCTAssertEqual(StandardIconCatalog.symbolNames.count, 69)
    }

    /// Every name is a symbol this OS actually has.
    ///
    /// `NSImage(systemSymbolName:accessibilityDescription:)` is the check rather than SwiftUI's
    /// `Image(systemName:)` because it is the only one of the two that answers: it returns `nil`
    /// for a name that does not exist, where the SwiftUI view happily renders nothing.
    func testEverySymbolNameResolves() {
        for (iconID, name) in StandardIconCatalog.symbolNames.enumerated() {
            XCTAssertNotNil(
                NSImage(systemSymbolName: name, accessibilityDescription: nil),
                "icon \(iconID) names \"\(name)\", which is not an SF Symbol on this system — it "
                    + "would draw as an empty space with no error anywhere"
            )
        }
    }

    /// Duplicates are allowed on purpose (KeePass's set is finer-grained than SF Symbols in a few
    /// places), but not many of them: a table that collapsed onto a handful of glyphs would make
    /// the picker useless. 60 distinct names out of 69 is the floor, not a target.
    func testSymbolNamesAreOverwhelminglyDistinct() {
        let distinct = Set(StandardIconCatalog.symbolNames)
        XCTAssertGreaterThanOrEqual(distinct.count, 60, "too many icon ids share one symbol")
    }

    /// The two indices that already have an appearance in the shipping app.
    ///
    /// `GroupSidebar` currently hardcodes `trash` for the recycle bin and `folder` for every other
    /// folder. The bin's row is the one pass-sumo also *writes* an icon id for
    /// (`KDBXRecycleBin.iconID`), so once the sidebar reads this table instead, id 43 has to
    /// produce the same glyph it draws today — otherwise adopting the table changes a screen
    /// nobody asked to change.
    func testRecycleBinAndFolderKeepTheirCurrentAppearance() {
        XCTAssertEqual(StandardIconCatalog.symbolName(for: KDBXRecycleBin.iconID), "trash")
        XCTAssertEqual(StandardIconCatalog.symbolName(for: VaultGroup.defaultIconID), "folder")
    }

    /// An index outside the set is not an error to swallow with a stand-in of the catalog's
    /// choosing: entries and folders fall back differently, so the caller decides.
    func testUnknownIconIDHasNoSymbol() {
        XCTAssertNil(StandardIconCatalog.symbolName(for: 69))
        XCTAssertNil(StandardIconCatalog.symbolName(for: .max))
        XCTAssertNotNil(StandardIconCatalog.symbolName(for: 68), "68 is the last real index")
    }
}
