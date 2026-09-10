import AppKit
import UniformTypeIdentifiers

/// The one `NSOpenPanel` for picking an existing `.kdbx`.
///
/// Shared because there are now two call sites that cannot see each other: `WelcomeView`'s own
/// "Open Database…" button, and `RootView`'s handling of the menu item of the same name — which
/// has to live in `RootView` because the menu is reachable while a vault is open and `WelcomeView`
/// is unmounted then (issue #84). A second copy of the panel setup is a second place for the rule
/// below to be forgotten.
enum DatabaseFilePicker {
    /// Runs the modal panel and returns the chosen file, or `nil` if the user cancelled.
    ///
    /// **Never a pre-set default path.** A sibling app by the same developer was rejected under App
    /// Review Guideline 2.4.5(i) for shipping a file-access entitlement backed only by a remembered
    /// default path, with no picker anywhere in the flow. A user-driven `NSOpenPanel` invocation is
    /// what justifies pass-sumo's read/write file entitlement to a reviewer, so `panel.directoryURL`
    /// is deliberately never set here — the panel must always ask, never assume.
    @MainActor
    static func chooseExistingDatabase() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let kdbxType = UTType(filenameExtension: "kdbx") {
            panel.allowedContentTypes = [kdbxType]
        }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
