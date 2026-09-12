import AppKit

/// The app's ear for Launch Services: a `.kdbx` double-clicked in Finder, `open Something.kdbx`,
/// "Open Recent" in the Dock menu, a file dropped on the Dock icon.
///
/// **The app declared a document type and then had nowhere to hear the request (issue #84).**
/// `Resources/Info.plist` (stamped from `project.yml`) claims `app.passsumo.kdbx` as an
/// *imported* UTI with `LSHandlerRank: Alternate` (issue #131 — Owner is deferred to #132),
/// so Finder double-click is not ours, but Open With and a Dock drop still are. With no
/// `NSApplicationDelegate` and no `.onOpenURL` anywhere, the only visible effect of dropping
/// a *second* database on the Dock icon used to be that the app came to the front still
/// showing the first one.
///
/// An `NSApplicationDelegate` rather than SwiftUI's `.onOpenURL`: `application(_:open:)` is the
/// documented AppKit callback for a Launch Services file open, and it is the one that covers the
/// Dock-drop path as well. Installed by `@NSApplicationDelegateAdaptor` in `PassSumoApp`, which
/// constructs it — hence the parameterless `init` and the handler being *set* afterwards rather
/// than injected.
///
/// **The buffer is the reason this is a type and not a closure.** On a cold launch the system
/// delivers the URL before the window (and therefore its `.task`) exists, so a request that
/// arrives before `onOpen(_:)` is wired would simply be lost — which is the same bug from a
/// different direction. A queue, not one slot: issue #47 opens every file as a tab, so a
/// multi-selection handed over before the handler is wired must not collapse to the last URL.
@MainActor
final class DocumentOpenReceiver: NSObject, NSApplicationDelegate {
    private var handler: ((URL) -> Void)?
    private var pending: [URL] = []

    /// **Issue #16's ⌘T caveat.** macOS turns on automatic window tabbing for every resizable
    /// window by default, which is what installs a system-supplied Window ▸ "New Tab" item bound
    /// to ⌘T — the same chord `AppCommands` now spends on "Copy One-Time Code" (matching
    /// Strongbox). Database tabs (issue #47) are a custom bar inside the one window, not
    /// NSWindow tabbing, so this stays off.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // Issue #47: every file URL becomes a tab. Finder can hand over a multi-selection;
        // opening only the first (or only the last) was the single-vault leftover.
        for url in urls where url.isFileURL {
            deliver(url)
        }
    }

    /// Registers the one consumer, and immediately hands it anything that arrived before it was
    /// there. Called once, from `PassSumoApp`'s `.task`.
    func onOpen(_ handler: @escaping (URL) -> Void) {
        self.handler = handler
        let buffered = pending
        pending = []
        buffered.forEach(handler)
    }

    private func deliver(_ url: URL) {
        guard let handler else {
            pending.append(url)
            return
        }
        handler(url)
    }
}
