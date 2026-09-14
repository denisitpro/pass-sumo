//
// Copyright (c) 2026, Denis Dzyubenko <denis@ddenis.info>
//
// SPDX-License-Identifier: BSD-2-Clause
//

import Foundation
import Testing
@testable import KDBXKit

/// A KDBX date element carries a raw `Int64`, and the reader hands back
/// whatever the file declared. Converting that back on save used to go through
/// `Int64(someDouble)`, which **traps** — so a file whose `<Times>` said
/// `Int64.max` opened fine and then killed the process on the next save,
/// leaving the vault permanently unsavable (pass-sumo issue #176).
///
/// These tests pin the two halves of the fix: the conversion is total, and the
/// writer substitutes a date every KDBX reader can parse rather than failing
/// the save.
@Suite(".NET date range")
struct DotNetDateRangeTests {
    /// AES-KDF with a single round: this suite is about dates, and a real
    /// Argon2 cost would add seconds per round trip for nothing.
    private static let cheapKDF = KDFParameters.aes(
        .init(salt: Data(repeating: 7, count: 32), rounds: 1),
        additional: [:]
    )

    /// The largest offset a .NET `DateTime` — and therefore a KDBX timestamp —
    /// can hold: `9999-12-31T23:59:59`.
    private static let maxRepresentable: Int64 = 315_537_897_599

    // MARK: - The conversion is total

    @Test("An ordinary date converts to seconds and back")
    func ordinaryDateRoundTrips() throws {
        let date = Date(secondsSinceDotNetEpoch: 63_884_389_441)
        #expect(date.secondsSinceDotNetEpoch == 63_884_389_441)
        #expect(date.clampedSecondsSinceDotNetEpoch == 63_884_389_441)
    }

    @Test("Int64.max — the hostile timestamp — converts to nil instead of trapping")
    func hostileMaximumDoesNotTrap() {
        // `Double(Int64.max)` rounds *up* to 2^63, one past what Int64 holds,
        // which is precisely why the old `Int64(...)` trapped here.
        let date = Date(secondsSinceDotNetEpoch: .max)
        #expect(date.secondsSinceDotNetEpoch == nil)
        #expect(date.clampedSecondsSinceDotNetEpoch == Self.maxRepresentable)
    }

    @Test("Int64.min converts to nil and clamps to the epoch")
    func hostileMinimumDoesNotTrap() {
        let date = Date(secondsSinceDotNetEpoch: .min)
        #expect(date.secondsSinceDotNetEpoch == nil)
        #expect(date.clampedSecondsSinceDotNetEpoch == 0)
    }

    @Test("A non-finite interval clamps to the epoch rather than the far end")
    func nonFiniteClampsLow() {
        // Every comparison against NaN is false, so an unordered value must not
        // be allowed to fall through to the `.max` branch and claim the year
        // 9999 as its timestamp.
        let nan = Date(timeIntervalSinceReferenceDate: .nan)
        #expect(nan.secondsSinceDotNetEpoch == nil)
        #expect(nan.clampedSecondsSinceDotNetEpoch == 0)
    }

    @Test("The range boundary itself is representable; one second past it is not")
    func boundaryIsInclusive() {
        #expect(Date(secondsSinceDotNetEpoch: Self.maxRepresentable).secondsSinceDotNetEpoch == Self.maxRepresentable)
        #expect(Date(secondsSinceDotNetEpoch: Self.maxRepresentable + 1).secondsSinceDotNetEpoch == nil)
    }

    @Test("Foundation's sentinel dates stay inside the representable range")
    func foundationSentinelsAreRepresentable() {
        // `.distantPast` is the epoch itself, and the projection layer above
        // this library uses it as its "the file did not record this" sentinel —
        // so a clamp that moved it would rewrite ordinary vaults.
        #expect(Date.distantPast.secondsSinceDotNetEpoch == 0)
        #expect(Date.distantFuture.secondsSinceDotNetEpoch != nil)
    }

    // MARK: - The writer survives one, end to end

    @Test("A vault carrying Int64.max timestamps writes and reopens")
    func hostileTimestampsSurviveAWriteReadRoundTrip() throws {
        let hostile = Date(secondsSinceDotNetEpoch: .max)
        var content = KDBXContent.makeEmpty(databaseName: "Hostile", kdf: Self.cheapKDF)
        // A Meta stamp: nothing above this library models it, so it is purely
        // round-tripped — exactly the path that made the vault unsavable.
        content.database.meta.masterKeyChanged = hostile
        var entry = KDBX.Entry(uuid: UUID())
        var times = KDBX.Times(creationTime: hostile, lastModificationTime: hostile)
        times.expiryTime = hostile
        entry.times = times
        content.database.root.group.entries.append(entry)

        let unlock = UnlockData(masterPassword: "pw")
        let stream = OutputStream(toMemory: ())
        stream.open()
        try KDBXWriter(to: stream).write(content, unlockData: unlock)
        let bytes = stream.property(forKey: .dataWrittenToMemoryStreamKey) as! Data
        stream.close()

        let reopened = try KDBXReader.parse(bytes, unlockData: unlock)
        let expected = Date(secondsSinceDotNetEpoch: Self.maxRepresentable)
        #expect(reopened.database.meta.masterKeyChanged == expected)
        let reopenedEntry = try #require(reopened.database.root.group.entries.first)
        #expect(reopenedEntry.times?.creationTime == expected)
        #expect(reopenedEntry.times?.expiryTime == expected)
    }
}
