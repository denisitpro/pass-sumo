//
// Copyright (c) 2025, Denis Dzyubenko <denis@ddenis.info>
//
// SPDX-License-Identifier: BSD-2-Clause
//

import Foundation

extension Date {
    /// The .NET DateTime epoch: `0001-01-01 00:00:00 UTC`.
    ///
    /// Used as the reference point for date encoding in KDBX files, which follow the
    /// .NET serialization format for date values.
    private static let dotNetEpoch = DateComponents(
        calendar: Calendar(identifier: .gregorian),
        timeZone: TimeZone(secondsFromGMT: 0),
        year: 1,
        month: 1,
        day: 1,
        hour: 0,
        minute: 0,
        second: 0
    ).date!

    /// Every whole-second offset a KDBX timestamp can express: from the epoch
    /// itself up to .NET's `DateTime.MaxValue` (`9999-12-31T23:59:59`, i.e.
    /// 3155378975999999999 ticks / 10^7).
    ///
    /// This is a narrower constraint than "fits in an `Int64`". KeePass writes
    /// `(long)(value - epoch).TotalSeconds` and reads it back through
    /// `new DateTime(...)`, which throws outside `DateTime.MinValue ...
    /// DateTime.MaxValue` — so an offset outside this range is not a timestamp
    /// any KDBX reader can use, however well it fits in the wire type.
    static let dotNetEpochSecondsRange: ClosedRange<Int64> = 0 ... 315_537_897_599

    /// The number of seconds between this date and the .NET epoch
    /// (`0001-01-01T00:00:00Z`), rounded to the nearest second — or `nil` when
    /// that offset is outside ``dotNetEpochSecondsRange``.
    ///
    /// Optional rather than `Int64` because `Int64(someDouble)` **traps** when
    /// the `Double` is out of `Int64`'s range, and this conversion is reachable
    /// from file content. The reader deliberately accepts whatever `Int64` a
    /// file declares (being stricter than the file format is how issue #30 made
    /// an intact database unopenable), so `Date(secondsSinceDotNetEpoch: .max)`
    /// is a date this library will hand back — and `Double(Int64.max)` rounds
    /// *up* to 2^63, one past what `Int64` can hold. A vault carrying that
    /// value opened fine and then killed the process on the next save, leaving
    /// it permanently unsavable (pass-sumo issue #176).
    ///
    /// A non-`nil` value is exactly how KDBX encodes that date. `nil` means no
    /// encoding exists at all, and the caller has to decide what to put in the
    /// file instead — see ``clampedSecondsSinceDotNetEpoch``.
    var secondsSinceDotNetEpoch: Int64? {
        let seconds = timeIntervalSince(Self.dotNetEpoch).rounded()
        guard
            seconds >= Double(Self.dotNetEpochSecondsRange.lowerBound),
            seconds <= Double(Self.dotNetEpochSecondsRange.upperBound)
        else {
            // Also the NaN / infinity exit: every comparison against NaN is
            // false, so a non-finite interval fails the first guard.
            return nil
        }
        return Int64(seconds)
    }

    /// ``secondsSinceDotNetEpoch``, pinned to the nearest end of
    /// ``dotNetEpochSecondsRange`` when the date is outside it. Total by
    /// construction: there is no input for which this traps.
    ///
    /// For the writer, which has no way to say "this timestamp was nonsense" in
    /// the file format and must not turn a hostile value into an unsavable
    /// database. `0001-01-01` and `9999-12-31` are unmistakably sentinels, not
    /// dates a user could mistake for their own data.
    var clampedSecondsSinceDotNetEpoch: Int64 {
        if let seconds = secondsSinceDotNetEpoch {
            return seconds
        }
        // Ordered so that NaN lands on the lower bound: it compares greater
        // than nothing, so a `>` test sends it there rather than letting an
        // unordered value claim the year 9999 by falling through to `.max`.
        return timeIntervalSince(Self.dotNetEpoch) > Double(Self.dotNetEpochSecondsRange.upperBound)
            ? Self.dotNetEpochSecondsRange.upperBound
            : Self.dotNetEpochSecondsRange.lowerBound
    }

    /// Creates a `Date` from the number of seconds since the .NET epoch (`0001-01-01T00:00:00Z`).
    ///
    /// This is used to decode timestamp values found in KeePass KDBX documents.
    ///
    /// - Parameter seconds: The number of seconds since the .NET epoch.
    init(secondsSinceDotNetEpoch seconds: Int64) {
        self = Self.dotNetEpoch.addingTimeInterval(TimeInterval(seconds))
    }
}
