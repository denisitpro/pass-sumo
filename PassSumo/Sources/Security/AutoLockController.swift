import AppKit
import Foundation
import Observation

/// Why the vault locked. Surfaced so the unlock screen can say "locked because the Mac slept"
/// instead of leaving the user wondering whether they hit something.
enum LockReason: Sendable, Equatable {
    /// `idleTimeout` elapsed with no reported activity.
    case idleTimeout
    /// `NSWorkspace.willSleepNotification`.
    case systemSleep
    /// `com.apple.screenIsLocked` on the distributed notification centre.
    case screenLocked
    /// `NSWorkspace.sessionDidResignActiveNotification` — fast user switching away from us.
    case sessionResignedActive
    /// The user asked for it.
    case userRequested
}

/// Source of the "lock right now" system events.
///
/// Behind a protocol purely so the tests can fire the events synchronously. Posting a real
/// `com.apple.screenIsLocked` on the distributed notification centre from a test would be both
/// antisocial (every other app on the machine listens for it) and unreliable (distributed
/// notifications are delivered asynchronously through `distnoted`, so the test would have to spin a
/// run loop and hope).
@MainActor
protocol LockEventSource: AnyObject {
    /// Starts delivering events to `handler`. Called at most once per instance.
    func start(_ handler: @escaping @MainActor (LockReason) -> Void)
    func stop()
}

/// The production event source.
///
/// Three different notification centres, because macOS puts these three events in three places:
/// - `NSWorkspace.shared.notificationCenter` for sleep and for session activity. These are *not* on
///   `NotificationCenter.default`; registering there is the classic reason "my sleep handler never
///   fires" bugs happen.
/// - `DistributedNotificationCenter.default()` for the screen lock, because `com.apple.screenIsLocked`
///   is posted by loginwindow in another process. It is undocumented — Apple ships no public API for
///   "the screen just locked" — but it is stable, has been posted since OS X 10.7, and is what every
///   password manager and time tracker on the platform uses. Being undocumented, its absence must
///   never be fatal: the idle timeout below is the guarantee, and this is an improvement on it.
@MainActor
final class WorkspaceLockEventSource: LockEventSource {
    /// Token and centre kept together so `stop()` can remove each observer from the centre it was
    /// added to — `NotificationCenter.removeObserver` is per-centre and silently does nothing when
    /// handed a token belonging to a different one.
    private var observers: [(token: any NSObjectProtocol, center: NotificationCenter)] = []

    func start(_ handler: @escaping @MainActor (LockReason) -> Void) {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification, .systemSleep, handler)
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification, .sessionResignedActive, handler)
        observe(
            DistributedNotificationCenter.default(),
            Notification.Name("com.apple.screenIsLocked"),
            .screenLocked,
            handler
        )
    }

    func stop() {
        for observer in observers {
            observer.center.removeObserver(observer.token)
        }
        observers.removeAll()
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        _ reason: LockReason,
        _ handler: @escaping @MainActor (LockReason) -> Void
    ) {
        // `queue: .main` so the block runs on the main queue, and `assumeIsolated` to state the
        // main-actor fact the block's non-isolated signature loses. The alternative — hopping
        // through a `Task` — would leave the app unlocked for an extra turn of the run loop after
        // the machine has already decided to sleep, which is exactly the window this closes.
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler(reason) }
        }
        observers.append((token, center))
    }
}

/// Locks the vault after inactivity, or immediately when the machine says the user has gone away.
///
/// The idle timer and the system events answer different threats. The timer covers "walked away
/// from an unlocked Mac"; the events cover "closed the lid", "hit the lock-screen hotkey" and
/// "switched to another account" — cases where waiting out a five-minute timeout would leave the
/// vault decrypted in a session the user has visibly left.
@MainActor
@Observable
final class AutoLockController {
    /// Seconds of inactivity before locking. 300 is the default because it is what the comparable
    /// apps use and because much shorter turns the app into a nuisance the user disables entirely.
    var idleTimeout: TimeInterval

    private(set) var isLocked: Bool = true
    private(set) var lastLockReason: LockReason?

    /// Seconds until the idle lock fires, for a UI countdown. `nil` while locked or stopped.
    private(set) var secondsUntilIdleLock: Int?

    private let now: @Sendable () -> Date
    private let eventSource: any LockEventSource
    private let onLock: () -> Void

    private var lastActivity: Date
    private var timer: Timer?
    private var isObserving = false

    /// **Activity is reported by callers via `noteActivity()`; there is deliberately no global
    /// event monitor.**
    ///
    /// `NSEvent.addGlobalMonitorForEvents` is the obvious way to notice that the user is still
    /// there, and it is the wrong one for this app. For keyboard events it requires the process to
    /// be trusted for Accessibility (`AXIsProcessTrusted`), which means prompting the user for the
    /// single most alarming permission macOS has — and a password manager asking to observe all
    /// your keystrokes is exactly what a malicious password manager would ask for. It is also a
    /// direct App Review problem: the entitlement/prompt has to be justified, and "so we can notice
    /// idleness" does not justify system-wide input observation. Finally it does not work under App
    /// Sandbox for keyboard events at all.
    ///
    /// Reporting activity from our own views costs the UI a few `noteActivity()` calls and gives a
    /// strictly better signal anyway: what matters is whether the user is using *the vault*, not
    /// whether some other app is receiving keystrokes.
    init(
        idleTimeout: TimeInterval = 300,
        eventSource: any LockEventSource = WorkspaceLockEventSource(),
        now: @escaping @Sendable () -> Date = Date.init,
        onLock: @escaping () -> Void
    ) {
        self.idleTimeout = idleTimeout
        self.eventSource = eventSource
        self.now = now
        self.onLock = onLock
        self.lastActivity = now()
    }

    // MARK: - Lifecycle

    /// Called when the vault becomes unlocked. Starts the idle countdown and subscribes to the
    /// system events.
    ///
    /// Subscribing here rather than in `init` means a locked app is not holding notification
    /// observers it cannot act on, and — more usefully — it means the controller can be constructed
    /// at app launch without side effects, which is what makes it testable.
    func vaultDidUnlock() {
        isLocked = false
        lastLockReason = nil
        lastActivity = now()
        secondsUntilIdleLock = Int(idleTimeout.rounded())
        if !isObserving {
            isObserving = true
            eventSource.start { [weak self] reason in
                self?.lock(reason: reason)
            }
        }
        armTimer()
    }

    /// The UI calls this on any meaningful interaction — a keystroke in the search field, a click
    /// on an entry, a copy. Cheap by design (one date write) so call sites need not be careful
    /// about how often they call it.
    func noteActivity() {
        guard !isLocked else { return }
        lastActivity = now()
        secondsUntilIdleLock = Int(idleTimeout.rounded())
    }

    /// Locks, unless already locked. Idempotent because three different system events can arrive
    /// for one user action — closing the lid posts `willSleep` *and* `screenIsLocked` — and the
    /// `onLock` callback tears down decrypted state, which must happen exactly once.
    func lock(reason: LockReason) {
        guard !isLocked else { return }
        isLocked = true
        lastLockReason = reason
        secondsUntilIdleLock = nil
        timer?.invalidate()
        timer = nil
        onLock()
    }

    /// Stops the idle timer and unsubscribes. For app teardown; does not itself lock.
    func stop() {
        timer?.invalidate()
        timer = nil
        secondsUntilIdleLock = nil
        if isObserving {
            eventSource.stop()
            isObserving = false
        }
    }

    // MARK: - Ticking

    private func armTimer() {
        timer?.invalidate()
        // One second, matching the countdown's resolution. The timer is only a driver — see `tick`.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            // Self-retiring weak capture, and a main-thread assumption that is a fact for a timer
            // on the main run loop — the reasoning for both is spelled out in `ClipboardService`.
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated { self.tick() }
        }
    }

    /// One second of the idle countdown. Internal because **this is the test seam** — the suite
    /// advances an injected clock and calls this, so a five-minute timeout is verified in no time
    /// at all and with no `Timer` involved.
    func tick() {
        guard !isLocked else { return }
        let idle = now().timeIntervalSince(lastActivity)
        if idle >= idleTimeout {
            lock(reason: .idleTimeout)
        } else {
            secondsUntilIdleLock = max(0, Int((idleTimeout - idle).rounded(.up)))
        }
    }
}
