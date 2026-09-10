import KDBXKit
import XCTest
@testable import PassSumo

/// Pure-logic tests for `KDBXPasswordHistory.lastChanged` (issue #33) — a fixture-built
/// `KDBX.Entry.history`, no vault, no codec, no file. See that type's doc comment for the
/// walk-backwards algorithm these pin down.
final class KDBXPasswordHistoryTests: XCTestCase {
    private func snapshot(password: String, at date: Date) -> KDBX.Entry {
        KDBX.Entry(
            uuid: UUID(),
            times: KDBX.Times(lastModificationTime: date),
            strings: [KDBX.ProtectedString(key: "Password", value: .regular(password))]
        )
    }

    private let t0 = Date(timeIntervalSince1970: 0)
    private let t1 = Date(timeIntervalSince1970: 1_000)
    private let t2 = Date(timeIntervalSince1970: 2_000)

    /// No `<History>` at all — the honest "unknown" case issue #33 explicitly calls out: this
    /// must NOT fall back to `created` or to `currentModified`, both of which would fabricate a
    /// date the file gives no evidence for.
    func testNoHistoryIsUnknown() {
        let result = KDBXPasswordHistory.lastChanged(
            currentPassword: "current",
            currentModified: t2,
            history: []
        )
        XCTAssertNil(result)
    }

    /// The core scenario from the issue's own write-up: password changed at t1 (history[0] still
    /// shows the OLD password "A"; history[1] already shows "B", the same as current), then an
    /// unrelated edit at t2 bumped `modified` without touching the password. The derived date must
    /// be t1 — history[1]'s own time — not t2, which `Times/LastModificationTime` would wrongly
    /// report as "when the password changed".
    func testMiddleHistoryEntryIsFoundWhenALaterEditDidNotTouchThePassword() {
        let result = KDBXPasswordHistory.lastChanged(
            currentPassword: "B",
            currentModified: t2,
            history: [
                snapshot(password: "A", at: t0),
                snapshot(password: "B", at: t1),
            ]
        )
        XCTAssertEqual(result, t1)
    }

    /// The newest history snapshot already differs from the live password — the password changed
    /// on the very last save, which history alone cannot date (nothing in `history` carries the
    /// NEW value). `currentModified` is the correct fallback here, confirmed rather than guessed:
    /// the comparison against `history` is what establishes that this save is the one that changed
    /// it.
    func testMostRecentHistoryDifferingFallsBackToCurrentModified() {
        let result = KDBXPasswordHistory.lastChanged(
            currentPassword: "B",
            currentModified: t2,
            history: [snapshot(password: "A", at: t0)]
        )
        XCTAssertEqual(result, t2)
    }

    /// Trimmed history: another client's `HistoryMaxItems` dropped the snapshot that would have
    /// shown a DIFFERENT password, leaving only survivors that already match the live value. The
    /// derived date is the oldest survivor's own time — a lower bound (the real change could be
    /// older still), never `nil` and never a fabricated exact date.
    func testTrimmedHistoryWhereEverySurvivorAlreadyMatchesReturnsTheOldestSurvivorAsALowerBound() {
        let result = KDBXPasswordHistory.lastChanged(
            currentPassword: "B",
            currentModified: t2,
            history: [snapshot(password: "B", at: t1)]
        )
        XCTAssertEqual(result, t1)
    }

    /// A history entry that is missing its own `Times` (legacy data, or a snapshot from a client
    /// that omitted it) must not crash the walk — it degrades to treating that snapshot's date as
    /// unrecorded rather than throwing the whole derivation off.
    func testASnapshotWithNoRecordedTimeDoesNotCrashTheWalk() {
        let noTimes = KDBX.Entry(
            uuid: UUID(),
            strings: [KDBX.ProtectedString(key: "Password", value: .regular("B"))]
        )
        let result = KDBXPasswordHistory.lastChanged(
            currentPassword: "B",
            currentModified: t2,
            history: [noTimes]
        )
        XCTAssertNil(result, "the only survivor matched but carried no time, so there is nothing to report")
    }
}
