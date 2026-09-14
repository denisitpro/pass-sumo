import KDBXKit
import XCTest
@testable import PassSumo

/// A KDBX `<Times>` element is a raw `Int64` on disk, and the reader hands back whatever the file
/// declared. A file saying `Int64.max` therefore opened fine, survived the merge verbatim, and then
/// **trapped** on the next save inside the vendored library's `Int64(Double)` conversion — so the
/// vault could never be saved again (issue #176, audit finding H4).
///
/// This suite is the end-to-end half of the fix: not the conversion in isolation (that lives in the
/// vendored package's own `DotNetDateRangeTests`) but a real save through `KDBXKitCodec`, which is
/// the path that actually killed the process.
///
/// The hostile value is injected into the decoded model rather than into a fixture file on purpose:
/// our own writer can no longer emit one, so there is no way to bake such a file with our own
/// tools. The in-memory state built here is exactly what `KDBXReader` produces for a file whose
/// `<CreationTime>` says `Int64.max` — the library keeps accepting those, because a reader stricter
/// than the format is what made an intact database unopenable in issue #30.
final class HostileTimestampTests: XCTestCase {
    private let codec = TestKDF.codec()

    /// `9999-12-31T23:59:59` as whole seconds since `0001-01-01T00:00:00Z` — .NET's
    /// `DateTime.MaxValue`, and the largest offset a KDBX date element can express.
    private static let maxRepresentableSeconds: TimeInterval = 315_537_897_599

    /// A `Date` whose offset from the .NET epoch overflows `Int64`: what a `<Times>` element saying
    /// `Int64.max` decodes to. `Double(Int64.max)` rounds *up* to 2^63, one past what `Int64` can
    /// hold, which is precisely what the old conversion trapped on.
    private static let hostileDate = Date(timeIntervalSinceReferenceDate: Double(Int64.max))

    /// Foundation's `Date.distantPast` is `0001-01-01 00:00:00 +0000` — the same instant as the
    /// .NET epoch KDBX counts from, verified to the second. Asserting that premise here means a
    /// Foundation change shows up as an obvious failure instead of silently skewing every
    /// expectation below by the amount it moved.
    func testDistantPastIsTheDotNetEpochThisSuiteMeasuresFrom() throws {
        let viaComponents = try XCTUnwrap(
            DateComponents(
                calendar: Calendar(identifier: .gregorian),
                timeZone: TimeZone(secondsFromGMT: 0),
                year: 1, month: 1, day: 1, hour: 0, minute: 0, second: 0
            ).date
        )
        XCTAssertEqual(Date.distantPast.timeIntervalSince(viaComponents), 0, accuracy: 1)
    }

    /// The acceptance criterion of issue #176, stated as a test: a vault carrying an unrepresentable
    /// timestamp saves. It does not trap, and it does not become permanently unsavable either.
    func testSavingAVaultWithAnInt64MaxTimestampDoesNotTrapAndWritesARepresentableDate() throws {
        let creds = VaultCredentials(password: "hostile-timestamp", keyFile: nil)
        var created = try codec.makeEmpty(name: "Hostile", credentials: creds)

        // Two poisoned surfaces, because they reach the writer by different routes. `MasterKeyChanged`
        // is a Meta stamp nothing in the domain model represents, so it only ever passes through the
        // preserved original; an entry's `created`/`modified` are modelled, so they reach the file
        // through `KDBXContentMerge`.
        var origin = try XCTUnwrap(created.opaque as? KDBXOrigin)
        origin.content.database.meta.masterKeyChanged = Self.hostileDate
        created = DecodedVault(vault: created.vault, opaque: origin)
        created.vault.entries = [
            VaultEntry(
                id: UUID(), groupID: nil, title: "Poisoned", username: "u", password: "p",
                url: "", notes: "", otpAuthURL: nil, customFields: [:],
                created: Self.hostileDate, modified: Self.hostileDate
            ),
        ]

        // Before the fix this line killed the test process outright — an `XCTAssertNoThrow` would
        // not have caught it, because a trap is not a Swift error.
        let saved = try codec.encode(created.vault, credentials: creds, origin: created)

        let reopened = try codec.decode(fileData: saved, credentials: creds)
        let entry = try XCTUnwrap(reopened.vault.entries.first)
        XCTAssertEqual(
            entry.created.timeIntervalSince(.distantPast),
            Self.maxRepresentableSeconds,
            accuracy: 1,
            "an unrepresentable timestamp must be written as the nearest date a KDBX reader can parse"
        )
        XCTAssertEqual(entry.modified.timeIntervalSince(.distantPast), Self.maxRepresentableSeconds, accuracy: 1)

        let reopenedOrigin = try XCTUnwrap(reopened.opaque as? KDBXOrigin)
        let masterKeyChanged = try XCTUnwrap(reopenedOrigin.content.database.meta.masterKeyChanged)
        XCTAssertEqual(masterKeyChanged.timeIntervalSince(.distantPast), Self.maxRepresentableSeconds, accuracy: 1)

        // The written file has to be openable by a *second* save too: a clamp that produced another
        // unrepresentable value would only move the trap one save further out.
        XCTAssertNoThrow(try codec.encode(reopened.vault, credentials: creds, origin: reopened))
    }
}
