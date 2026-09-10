import AppKit

/// The app's ear for Launch Services: a `.kdbx` double-clicked in Finder, `open Something.kdbx`,
/// "Open Recent" in the Dock menu, a file dropped on the Dock icon.
///
/// **The app declared itself the owner of the type and then had nowhere to hear the request
/// (issue #84).** `Resources/Info.plist` (stamped from `project.yml`) claims `app.passsumo.kdbx`
/// with `LSHandlerRank: Owner`, so the system routes every `.kdbx` here — but with no
/// `NSApplicationDelegate` and no `.onOpenURL` anywhere, the only visible effect of a double-click
/// on a *second* database was that the app came to the front still showing the first one.
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
/// different direction. One slot, not a queue: the app holds exactly one vault, so a second
/// request arriving before the first is drained supersedes it.
@MainActor
final class DocumentOpenReceiver: NSObject, NSApplicationDelegate {
    private var handler: ((URL) -> Void)?
    private var pending: URL?

    /// **Issue #16's ⌘T caveat.** macOS turns on automatic window tabbing for every resizable
    /// window by default, which is what installs a system-supplied Window ▸ "New Tab" item bound
    /// to ⌘T — the same chord `AppCommands` now spends on "Copy One-Time Code" (matching
    /// Strongbox). This app is a one-window, three-pane browser with no use for tabs, so turning
    /// tabbing off removes the collision at its source instead of leaving ⌘T merely unclaimed by
    /// our own menus and hoping the system item never appears.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // Only the first file URL. Finder can hand over a multi-selection, and this app has one
        // window holding one vault — opening them all is issue #47, and opening the last one
        // would make which database you land on depend on the order Finder happened to pass.
        guard let url = urls.first(where: { $0.isFileURL }) else { return }
        deliver(url)
    }

    /// Registers the one consumer, and immediately hands it anything that arrived before it was
    /// there. Called once, from `PassSumoApp`'s `.task`.
    func onOpen(_ handler: @escaping (URL) -> Void) {
        self.handler = handler
        if let buffered = pending {
            pending = nil
            handler(buffered)
        }
    }

    private func deliver(_ url: URL) {
        guard let handler else {
            pending = url
            return
        }
        handler(url)
    }
}
