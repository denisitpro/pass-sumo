import AppKit
import SwiftUI
import XCTest
@testable import PassSumo

/// Issue #172 — **leaving an unlocked vault must not cost the user their edits, and must not
/// leave a password on the pasteboard.**
///
/// Against `SessionLockPolicy`, `VaultSessionList` and `DocumentOpenReceiver` directly: no window,
/// no timer, no real `NSWorkspace` notification, and — the point of the last one — no
/// `NSApplication` run loop. The quit decision is a value returned by the tab list, so the whole
/// of it is assertable here; only `NSApp.reply(toApplicationShouldTerminate:)` itself lives in
/// `RootView`, where a test cannot follow.
@MainActor
final class SessionLockAndQuitTests: XCTestCase {

    // `nonisolated(unsafe)` for the reason the neighbouring suites give: XCTest's
    // `setUpWithError`/`tearDownWithError` are `nonisolated`, and XCTest runs setUp, the test body
    // and tearDown strictly one after another for a given instance.
    nonisolated(unsafe) private var tempDirectory: URL!

    override nonisolated func setUpWithError() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PassSumoSessionLockTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectory = directory
    }

    override nonisolated func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
    }

    // MARK: - Test doubles and helpers

    /// `InMemoryVaultFileAccess` with a switch that makes every later `write` throw, so "the save
    /// failed" is a fact the test establishes rather than a situation it has to contrive out of
    /// the real filesystem.
    ///
    /// `@unchecked Sendable`: the one flag is only ever read/written under `lock`, the same bargain
    /// the fake it delegates to makes for its own storage.
    private final class RefusingVaultFileAccess: VaultFileAccess, @unchecked Sendable {
        private let lock = NSLock()
        private var refusing = false
        private let backing = InMemoryVaultFileAccess()

        var refusesWrites: Bool {
            get { lock.lock(); defer { lock.unlock() }; return refusing }
            set { lock.lock(); refusing = newValue; lock.unlock() }
        }

        func read(from url: URL) throws -> Data { try backing.read(from: url) }

        @discardableResult
        func write(_ data: Data, to url: URL) throws -> VaultBackupOutcome {
            guard !refusesWrites else { throw VaultError.io("the volume went away") }
            return try backing.write(data, to: url)
        }

        func bookmark(for url: URL) throws -> Data { try backing.bookmark(for: url) }

        func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
            try backing.resolveBookmark(data)
        }

        func backupDirectory(for url: URL?) -> URL? { backing.backupDirectory(for: url) }
    }

    /// One session's worth of the wiring `VaultSession.init` builds, with the event source and the
    /// clock swapped for the fakes — a real `WorkspaceLockEventSource` would register this test for
    /// every sleep and screen-lock notification on the machine.
    private struct Harness {
        let store: VaultStore
        let pasteboard: FakePasteboard
        let clipboard: ClipboardService
        let policy: SessionLockPolicy
        let controller: AutoLockController
        let events: FakeLockEventSource
        let clock: SecurityTestClock
        let fileAccess: RefusingVaultFileAccess
    }

    private func makeHarness() -> Harness {
        let fileAccess = RefusingVaultFileAccess()
        let store = VaultStore(codec: InMemoryVaultCodec(), fileAccess: fileAccess)
        let pasteboard = FakePasteboard()
        let clipboard = ClipboardService(pasteboard: pasteboard)
        let policy = SessionLockPolicy(store: store, clipboard: clipboard)
        let clock = SecurityTestClock()
        let events = FakeLockEventSource()
        let controller = AutoLockController(
            idleTimeout: 300,
            eventSource: events,
            now: clock.provider,
            onLock: { policy.handleLock(reason: $0) }
        )
        policy.controller = controller
        return Harness(
            store: store,
            pasteboard: pasteboard,
            clipboard: clipboard,
            policy: policy,
            controller: controller,
            events: events,
            clock: clock,
            fileAccess: fileAccess
        )
    }

    private func unlockedVault(in harness: Harness, named name: String = "vault.kdbx") async {
        let url = tempDirectory.appendingPathComponent(name)
        await harness.store.createNew(at: url, credentials: VaultCredentials(password: "pw", keyFile: nil))
        await harness.store.save()
        XCTAssertFalse(harness.store.isDirty, "precondition: the vault starts saved")
        harness.controller.vaultDidUnlock()
    }

    private func edit(_ store: VaultStore, title: String = "Unsaved") {
        store.upsert(
            VaultEntry(
                id: UUID(), groupID: nil, title: title, username: "", password: "",
                url: "", notes: "", otpAuthURL: nil, customFields: [:],
                created: Date(timeIntervalSince1970: 0), modified: Date(timeIntervalSince1970: 0)
            )
        )
        XCTAssertTrue(store.isDirty, "precondition: the edit must leave the vault dirty")
    }

    /// The automatic lock path hands off to an unstructured `Task` (see `SessionLockPolicy`), so
    /// there is no handle to await. Bounded, so a regression fails in about two seconds instead of
    /// parking the whole suite.
    private func waitUntil(
        _ description: String,
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for \(description)", file: file, line: line)
    }

    // MARK: - Automatic lock saves rather than discarding (finding H1)

    func testIdleLockSavesADirtyVaultBeforeDroppingIt() async {
        let harness = makeHarness()
        await unlockedVault(in: harness)
        edit(harness.store)

        harness.clock.advance(300)
        harness.controller.tick()

        await waitUntil("the vault to lock") { !harness.store.isDirty }
        XCTAssertFalse(harness.store.isDirty, "the edits must be on disk, not discarded")
        XCTAssertNil(harness.store.lastError)
        if case .locked = harness.store.state {} else {
            XCTFail("the vault must end up locked once its edits are saved")
        }
    }

    func testSleepSavesADirtyVaultBeforeDroppingIt() async {
        let harness = makeHarness()
        await unlockedVault(in: harness)
        edit(harness.store)

        harness.events.fire(.systemSleep)

        await waitUntil("the vault to lock") { !harness.store.isDirty }
        if case .locked = harness.store.state {} else {
            XCTFail("sleep must still lock the vault; it just has to save it first")
        }
    }

    func testACleanVaultIsDroppedSynchronouslyOnSleep() async {
        let harness = makeHarness()
        await unlockedVault(in: harness)

        harness.events.fire(.systemSleep)

        // No `waitUntil`: with nothing to save there is no `Task` hop, which is the property
        // `WorkspaceLockEventSource` gives up a run-loop turn to preserve.
        if case .locked = harness.store.state {} else {
            XCTFail("a clean vault must be locked by the time the event handler returns")
        }
    }

    // MARK: - A failed auto-save keeps the vault (finding H1)

    func testAFailedAutoSaveKeepsTheVaultUnlockedAndStillDirty() async {
        let harness = makeHarness()
        await unlockedVault(in: harness)
        edit(harness.store)
        harness.fileAccess.refusesWrites = true

        await harness.policy.saveThenLock()

        XCTAssertTrue(harness.store.isDirty, "a failed save must not report the edits as written")
        if case .unlocked = harness.store.state {} else {
            XCTFail("the vault must stay unlocked: its edits exist nowhere else")
        }
        XCTAssertNotNil(harness.store.lastError, "the failure has to be surfaced, not swallowed")
    }

    /// The controller flips itself to locked before calling the handler, so a declined lock has to
    /// put it back — otherwise the idle clock is dead and nothing ever tries to lock again.
    func testAFailedAutoSaveReArmsTheIdleClock() async {
        let harness = makeHarness()
        await unlockedVault(in: harness)
        edit(harness.store)
        harness.fileAccess.refusesWrites = true

        harness.clock.advance(300)
        harness.controller.tick()
        await waitUntil("the declined lock to re-arm the clock") { !harness.controller.isLocked }

        XCTAssertFalse(harness.controller.isLocked)
        XCTAssertNil(harness.controller.lastLockReason, "no lock happened, so no reason to report")
        XCTAssertEqual(harness.controller.secondsUntilIdleLock, 300)

        // The retry is a full idle period later, and it locks once the write works again.
        harness.fileAccess.refusesWrites = false
        harness.clock.advance(300)
        harness.controller.tick()
        await waitUntil("the retry to lock") { !harness.store.isDirty }
        if case .locked = harness.store.state {} else {
            XCTFail("a save that starts working must lock the vault on the next round")
        }
    }

    // MARK: - The pasteboard (finding M1)

    func testLockingClearsAPasswordWePutOnThePasteboard() async {
        let harness = makeHarness()
        await unlockedVault(in: harness)
        harness.clipboard.copy("hunter2")
        XCTAssertEqual(harness.pasteboard.currentString, "hunter2")

        harness.policy.handleLock(reason: .userRequested)

        XCTAssertNil(harness.pasteboard.currentString, "a lock must not leave the password behind")
        XCTAssertFalse(harness.clipboard.isHoldingSecret)
    }

    func testAFailedAutoSaveStillClearsThePasteboard() async {
        let harness = makeHarness()
        await unlockedVault(in: harness)
        edit(harness.store)
        harness.fileAccess.refusesWrites = true
        harness.clipboard.copy("hunter2")

        harness.policy.handleLock(reason: .idleTimeout)

        // The vault stays (asserted above); the pasteboard does not. The user is away either way.
        XCTAssertNil(harness.pasteboard.currentString)
    }

    func testLockingLeavesAPasteboardSomebodyElseOwnsAlone() async {
        let harness = makeHarness()
        await unlockedVault(in: harness)
        harness.clipboard.copy("hunter2")
        harness.pasteboard.simulateForeignCopy()

        harness.policy.handleLock(reason: .systemSleep)

        XCTAssertEqual(
            harness.pasteboard.clearCallCount, 1,
            "only the `copy` itself may have cleared: wiping what another app owns is data loss"
        )
    }

    // MARK: - ⌘L through the tab list

    private func makeList(fileAccess: any VaultFileAccess = InMemoryVaultFileAccess())
        -> (list: VaultSessionList, pasteboard: FakePasteboard, clipboard: ClipboardService) {
        let pasteboard = FakePasteboard()
        let clipboard = ClipboardService(pasteboard: pasteboard)
        let list = VaultSessionList(
            codec: InMemoryVaultCodec(),
            fileAccess: fileAccess,
            autoLockTimeout: 300,
            clipboard: clipboard
        )
        return (list, pasteboard, clipboard)
    }

    private func openVault(at name: String, in list: VaultSessionList) async -> VaultSession {
        let url = tempDirectory.appendingPathComponent(name)
        let session = list.open(url)
        await session.store.createNew(at: url, credentials: VaultCredentials(password: "pw", keyFile: nil))
        await session.store.save()
        XCTAssertTrue(session.isUnlocked, "precondition: \(name) is unlocked")
        XCTAssertFalse(session.store.isDirty, "precondition: \(name) starts clean")
        return session
    }

    func testLockingACleanTabLocksItAndClearsThePasteboard() async {
        let (list, pasteboard, clipboard) = makeList()
        let session = await openVault(at: "clean.kdbx", in: list)
        list.select(session.id)
        clipboard.copy("hunter2")
        XCTAssertEqual(pasteboard.currentString, "hunter2", "precondition: a password is on it")

        // Through the session's own controller, which is what proves `VaultSession.init` wired the
        // policy into `onLock` rather than leaving `store.lock()` there.
        session.autoLock.lockRequestedByUser()

        XCTAssertFalse(session.isUnlocked)
        XCTAssertNil(pasteboard.currentString)
    }

    func testLockingADirtyTabAsksFirst() async {
        let (list, _, _) = makeList()
        let session = await openVault(at: "dirty.kdbx", in: list)
        edit(session.store)

        XCTAssertEqual(list.requestLock(session.id), .confirmUnsavedChanges)
        XCTAssertEqual(list.unsavedChangesLockID, session.id)
        XCTAssertTrue(session.isUnlocked, "nothing may be dropped before the user answers")
        XCTAssertTrue(session.store.isDirty)
    }

    func testCancellingTheLockPromptLeavesTheVaultOpen() async {
        let (list, _, _) = makeList()
        let session = await openVault(at: "dirty.kdbx", in: list)
        edit(session.store)
        _ = list.requestLock(session.id)

        list.cancelLock()

        XCTAssertNil(list.unsavedChangesLockID)
        XCTAssertTrue(session.isUnlocked)
        XCTAssertTrue(session.store.isDirty)
    }

    func testDiscardingAtTheLockPromptLocksTheDirtyVault() async {
        let (list, _, _) = makeList()
        let session = await openVault(at: "dirty.kdbx", in: list)
        edit(session.store)
        _ = list.requestLock(session.id)

        list.discardThenLockPending()

        XCTAssertNil(list.unsavedChangesLockID)
        XCTAssertFalse(session.isUnlocked, "Discard is the one answer that may drop the edits")
        XCTAssertEqual(
            session.autoLock.lastLockReason, .userRequested,
            "the unlock screen must be able to tell this from an automatic lock (issue #69)"
        )
    }

    func testSavingAtTheLockPromptWritesThenLocks() async {
        let (list, _, _) = makeList()
        let session = await openVault(at: "dirty.kdbx", in: list)
        edit(session.store)
        _ = list.requestLock(session.id)

        await list.saveThenLockPending()

        XCTAssertNil(list.unsavedChangesLockID)
        XCTAssertFalse(session.store.isDirty)
        XCTAssertFalse(session.isUnlocked)
    }

    func testAFailedSaveAtTheLockPromptLeavesTheVaultUnlocked() async {
        let fileAccess = RefusingVaultFileAccess()
        let (list, _, _) = makeList(fileAccess: fileAccess)
        let session = await openVault(at: "dirty.kdbx", in: list)
        edit(session.store)
        _ = list.requestLock(session.id)
        fileAccess.refusesWrites = true

        await list.saveThenLockPending()

        XCTAssertTrue(session.store.isDirty, "a failed save must not clear the dirty flag")
        XCTAssertTrue(session.isUnlocked)
        XCTAssertNotNil(session.store.lastError)
    }

    func testLockingIgnoresATabThatIsAlreadyLocked() async {
        let (list, _, _) = makeList()
        let session = list.open(tempDirectory.appendingPathComponent("locked.kdbx"))

        XCTAssertEqual(list.requestLock(session.id), .ignored)
        XCTAssertNil(list.unsavedChangesLockID)
    }

    // MARK: - ⌘Q

    func testQuittingWithNothingDirtyGoesStraightThroughAndClearsThePasteboard() async {
        let (list, pasteboard, clipboard) = makeList()
        let session = await openVault(at: "clean.kdbx", in: list)
        list.select(session.id)
        clipboard.copy("hunter2")
        XCTAssertEqual(pasteboard.currentString, "hunter2", "precondition: a password is on it")

        XCTAssertEqual(list.requestQuit(), .quitNow)
        XCTAssertFalse(list.isQuitPending)
        XCTAssertNil(pasteboard.currentString, "the pasteboard is the one thing that outlives us")
    }

    func testQuittingWithUnsavedChangesParksTheRequest() async {
        let (list, _, _) = makeList()
        let session = await openVault(at: "dirty.kdbx", in: list)
        edit(session.store)

        XCTAssertEqual(list.requestQuit(), .confirmUnsavedChanges)
        XCTAssertTrue(list.isQuitPending)
        XCTAssertEqual(list.dirtySessions.map(\.id), [session.id])
        XCTAssertTrue(session.isUnlocked, "nothing may be dropped while the prompt is up")
    }

    /// A second ⌘Q while the prompt is up must not park a second request: the one reply the prompt
    /// will send would answer only one of them, and the other would hang the app for good.
    func testASecondQuitRequestIsCancelledRatherThanParked() async {
        let (list, _, _) = makeList()
        let session = await openVault(at: "dirty.kdbx", in: list)
        edit(session.store)
        XCTAssertEqual(list.requestQuit(), .confirmUnsavedChanges)

        XCTAssertEqual(list.requestQuit(), .alreadyAsking)
        XCTAssertTrue(list.isQuitPending, "the FIRST request and its prompt must survive")
    }

    func testCancellingTheQuitPromptLeavesEveryVaultIntact() async {
        let (list, _, _) = makeList()
        let session = await openVault(at: "dirty.kdbx", in: list)
        edit(session.store)
        _ = list.requestQuit()

        list.endQuitRequest()

        XCTAssertFalse(list.isQuitPending)
        XCTAssertEqual(list.sessions.count, 1)
        XCTAssertTrue(session.isUnlocked)
        XCTAssertTrue(session.store.isDirty, "Cancel keeps the edits exactly where they were")
    }

    func testSavingForQuitWritesEveryDirtyTab() async {
        let (list, _, _) = makeList()
        let first = await openVault(at: "one.kdbx", in: list)
        let second = await openVault(at: "two.kdbx", in: list)
        edit(first.store, title: "First")
        edit(second.store, title: "Second")
        _ = list.requestQuit()

        let mayQuit = await list.saveDirtySessionsForQuit()

        XCTAssertTrue(mayQuit)
        XCTAssertTrue(list.dirtySessions.isEmpty)
    }

    func testAFailedSaveRefusesTheQuit() async {
        let fileAccess = RefusingVaultFileAccess()
        let (list, _, _) = makeList(fileAccess: fileAccess)
        let session = await openVault(at: "dirty.kdbx", in: list)
        edit(session.store)
        _ = list.requestQuit()
        fileAccess.refusesWrites = true

        let mayQuit = await list.saveDirtySessionsForQuit()

        XCTAssertFalse(mayQuit, "quitting anyway would discard exactly the edits Save asked to keep")
        XCTAssertTrue(session.store.isDirty)
        XCTAssertNotNil(session.store.lastError)
    }

    // MARK: - The terminate seam, with no NSApp spun

    func testTheDelegateAsksTheHandlerForItsTerminateReply() {
        let receiver = DocumentOpenReceiver()
        var asked = 0
        receiver.onShouldTerminate {
            asked += 1
            return .terminateLater
        }

        XCTAssertEqual(receiver.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        XCTAssertEqual(asked, 1)
    }

    /// Before any handler is wired — a terminate request during launch — the app must quit the way
    /// it always did. Inventing a `.terminateLater` nobody can answer would be an app that cannot
    /// be quit at all.
    func testTerminatingWithNoHandlerWiredQuitsImmediately() {
        XCTAssertEqual(
            DocumentOpenReceiver().applicationShouldTerminate(NSApplication.shared),
            .terminateNow
        )
    }

    // MARK: - Typing in the edit sheet is not idleness

    func testTypingInTheEditSheetReportsActivity() {
        let clock = SecurityTestClock()
        let controller = AutoLockController(
            idleTimeout: 300,
            eventSource: FakeLockEventSource(),
            now: clock.provider,
            onLock: { _ in }
        )
        controller.vaultDidUnlock()
        let editor = EntryEditView(
            entry: Vault.sample.entries[0],
            isNew: false,
            store: VaultStore(codec: InMemoryVaultCodec(), fileAccess: InMemoryVaultFileAccess()),
            clipboard: ClipboardService(pasteboard: FakePasteboard()),
            generator: PasswordGenerator(),
            generatorRecipe: PasswordGenerator.Recipe(),
            autoLock: controller,
            onSave: { _ in },
            onDismiss: {}
        )

        clock.advance(200)
        controller.tick()
        XCTAssertEqual(controller.secondsUntilIdleLock, 100, "precondition: the clock has run down")

        var typed = ""
        let field = editor.notingActivity(Binding(get: { typed }, set: { typed = $0 }))
        field.wrappedValue = "a password nobody has finished typing yet"

        XCTAssertEqual(
            controller.secondsUntilIdleLock, 300,
            "a keystroke in the sheet must reset the idle countdown"
        )
        XCTAssertEqual(typed, "a password nobody has finished typing yet", "and still reach the field")
    }
}
