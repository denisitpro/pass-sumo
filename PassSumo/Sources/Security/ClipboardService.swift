import AppKit
import Foundation
import Observation

/// The slice of `NSPasteboard` this service uses.
///
/// A protocol here is not architecture for its own sake — it is the only way to unit-test the
/// service without trashing whatever the developer had on their real clipboard when they ran
/// `make test`, and without the test's assertions racing every other app on the machine that
/// writes to `NSPasteboard.general`. The member list is copied verbatim from `NSPasteboard`, so the
/// production conformance below is empty.
@MainActor
protocol PasteboardWriting: AnyObject {
    /// Monotonic counter bumped by *any* process that takes ownership of the pasteboard. This is
    /// the whole basis of the "only clear what is still ours" rule below.
    var changeCount: Int { get }
    @discardableResult func clearContents() -> Int
    @discardableResult func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool
}

extension NSPasteboard: PasteboardWriting {}

/// Copies a secret to the system pasteboard and takes it back out again after a short interval.
///
/// The auto-clear is the point of the type. A password sitting on the clipboard indefinitely is
/// readable by every process on the machine (the pasteboard has no access control on macOS beyond
/// the paste-notification banner), gets picked up by clipboard-history utilities, and syncs to the
/// user's other devices over Universal Clipboard. The markers below address the last two; the timer
/// addresses the first.
@MainActor
@Observable
final class ClipboardService {
    /// Custom pasteboard types that ask other software not to retain the contents.
    enum SensitivityMarker {
        /// **A community convention, not an Apple API.** `org.nspasteboard.ConcealedType` comes
        /// from nspasteboard.org, a de-facto agreement between third-party clipboard managers
        /// (Maccy, Copy'em, Flycut, Alfred, Keyboard Maestro and others honour it) that an item
        /// carrying this type must not be recorded in clipboard history. Nothing in macOS enforces
        /// it and nothing obliges any app to look at it — a clipboard manager that ignores it is
        /// not violating anything. It is worth setting because the managers users actually run do
        /// honour it, but it must never be described to a user as protection.
        static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

        /// **Apple's own key**, though an undocumented one — `com.apple.is-sensitive` is what
        /// Apple's first-party software (Keychain Access, Passwords, Safari's password autofill)
        /// puts on password items, and it is the flag that keeps an item out of Universal
        /// Clipboard and out of the pasteboard's cross-device sync. "Apple's" here means "shipped
        /// and honoured by Apple's own code", not "in the published SDK": there is no constant for
        /// it in `NSPasteboard`, so it is a string we spell ourselves and it could in principle
        /// change. Distinguishing the two markers matters — one is a request to third parties, the
        /// other is a request to the OS — and neither is a guarantee.
        static let isSensitive = NSPasteboard.PasteboardType("com.apple.is-sensitive")
    }

    /// How long a copied secret survives. 30 s is long enough to switch to a browser and paste,
    /// short enough that a locked-and-walked-away Mac is not holding a password.
    var clearInterval: TimeInterval

    /// Seconds left before the auto-clear fires, for the UI's countdown. `0` when nothing of ours
    /// is on the pasteboard.
    private(set) var secondsRemaining: Int = 0

    /// True while a secret we wrote is still (as far as `changeCount` can tell) on the pasteboard.
    private(set) var isHoldingSecret: Bool = false

    private let pasteboard: any PasteboardWriting
    private let now: @Sendable () -> Date

    /// `changeCount` at the moment we wrote. Anything else on the pasteboard afterwards bumps it,
    /// and that is how `clearNow()` knows to keep its hands off.
    private var ownedChangeCount: Int?
    private var expiry: Date?
    private var timer: Timer?

    /// `now` is injected so the tests can move time in whole minutes without waiting; `pasteboard`
    /// so they do not touch the user's real clipboard. Everything else is a plain value.
    init(
        pasteboard: any PasteboardWriting = NSPasteboard.general,
        clearInterval: TimeInterval = 30,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.pasteboard = pasteboard
        self.clearInterval = clearInterval
        self.now = now
    }

    // MARK: - Item construction

    /// Builds the pasteboard item for `secret`: the plain text, plus both sensitivity markers.
    ///
    /// `static` and pure so the markers are testable without a pasteboard of any kind — the thing
    /// most likely to regress here is someone "tidying up" one of the two custom types away, and a
    /// test that only checks the string content would not notice.
    ///
    /// The markers carry an empty `Data` payload deliberately: consumers check for the *presence*
    /// of the type, and putting anything in the payload would only invite something to try to read
    /// it as the secret.
    static func makeItem(secret: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(secret, forType: .string)
        item.setData(Data(), forType: SensitivityMarker.concealed)
        item.setData(Data(), forType: SensitivityMarker.isSensitive)
        return item
    }

    // MARK: - Copy / clear

    /// Puts `secret` on the pasteboard and (re)starts the countdown.
    ///
    /// Copying again while a countdown is running restarts it rather than stacking a second timer —
    /// otherwise the first copy's timer would wipe the second copy's content early, which is the
    /// exact bug the `changeCount` check cannot catch (both copies are "ours").
    func copy(_ secret: String, clearAfter interval: TimeInterval? = nil) {
        let effectiveInterval = interval ?? clearInterval
        pasteboard.clearContents()
        pasteboard.writeObjects([Self.makeItem(secret: secret)])

        ownedChangeCount = pasteboard.changeCount
        isHoldingSecret = true
        expiry = now().addingTimeInterval(effectiveInterval)
        secondsRemaining = max(0, Int(ceil(effectiveInterval)))
        armTimer()
    }

    /// Clears the pasteboard **only if it still holds what we put there**.
    ///
    /// The `changeCount` comparison is the important half. Without it, a user who copies a password
    /// and then, twenty seconds later, copies a paragraph of text they were writing would watch
    /// that paragraph silently vanish from their clipboard — data loss caused by a security
    /// feature, which is the worst kind. `changeCount` is bumped by any owner change from any
    /// process, so an inequality means someone else owns the pasteboard now and it is not ours to
    /// touch.
    ///
    /// Returns whether the pasteboard was actually cleared.
    @discardableResult
    func clearNow() -> Bool {
        defer { resetCountdown() }
        guard let owned = ownedChangeCount, pasteboard.changeCount == owned else { return false }
        pasteboard.clearContents()
        return true
    }

    /// Stops the countdown and forgets ownership, leaving the secret on the pasteboard.
    ///
    /// For the "keep it until I say otherwise" affordance. Separate from `clearNow()` because the
    /// two have opposite effects on the pasteboard and collapsing them into one flagged method
    /// would make every call site read ambiguously.
    func cancelAutoClear() {
        resetCountdown()
    }

    private func resetCountdown() {
        timer?.invalidate()
        timer = nil
        expiry = nil
        ownedChangeCount = nil
        isHoldingSecret = false
        secondsRemaining = 0
    }

    // MARK: - Ticking

    private func armTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            // Two things are going on in these three lines.
            //
            // The `guard`/`invalidate` pair is the deinit this class cannot have: a scheduled
            // `Timer` is retained by the run loop, so with only a weak capture it would go on
            // firing into a nil `self` forever after the service is released. A `deinit` cannot do
            // the tidying instead — `deinit` is nonisolated and `timer` is main-actor state, which
            // Swift 6 rightly refuses — so the timer retires itself.
            //
            // `assumeIsolated` states a fact rather than a hope: a timer scheduled on the main run
            // loop only ever fires on the main thread. The alternative, hopping through a `Task`,
            // would add a turn of latency and let ticks arrive out of order.
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated { self.tick() }
        }
    }

    /// One second of the countdown. Internal rather than private **because it is the test seam**:
    /// the suite drives this directly with a moved clock, so the whole clipboard behaviour is
    /// verifiable in microseconds instead of waiting 30 real seconds for a `Timer`. The `Timer`
    /// above exists only to call this in production.
    func tick() {
        guard let expiry else { return }
        let remaining = expiry.timeIntervalSince(now())
        if remaining <= 0 {
            clearNow()
        } else {
            secondsRemaining = max(1, Int(ceil(remaining)))
        }
    }
}
