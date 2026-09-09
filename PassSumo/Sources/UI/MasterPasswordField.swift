import AppKit
import SwiftUI

/// Whether a `MasterPasswordField`'s bound password currently renders as dots or as plaintext.
///
/// Deliberately holds no copy of the password itself — only the `Bool` that decides which of the
/// two SwiftUI text controls renders the SAME `@State` string the caller already owns (see
/// `MasterPasswordField.fieldContent`). Pulled out as its own value type, rather than an inline
/// `@State private var isRevealed` in the view body, so the one rule that must never be skipped —
/// reveal is per-attempt and always resets to hidden, never sticky — is unit-testable without
/// XCTest driving a real `NSWindow` through a key-status change. Same reasoning as
/// `BiometricUnlockRecovery` in `UnlockView.swift`.
struct PasswordRevealState: Equatable {
    private(set) var isRevealed = false

    /// The eye button's action. The only way `isRevealed` ever becomes `true`.
    mutating func toggle() {
        isRevealed.toggle()
    }

    /// Called when the hosting window loses key status or the app deactivates — see
    /// `MasterPasswordField`'s `.onReceive` pair. Idempotent and unconditional: there is no case
    /// where a revealed password should survive the user's attention visibly leaving this screen.
    mutating func hide() {
        isRevealed = false
    }
}

/// A master-password entry field with a reveal toggle, shared by the unlock screen and both fields
/// of `CreateDatabaseSheet` (issue #32). Gives the field real presence — `.large` control size and
/// the system's native bordered/focus-ring appearance — instead of the default-size
/// `.roundedBorder` field that made the product's single most important input look disabled.
///
/// `SecureField` and `TextField` here are bound to the SAME `text` the caller passes in. Revealing
/// never copies the password anywhere else — including into this view's own `PasswordRevealState`,
/// which is a `Bool` and nothing more — it only changes which control renders the one string that
/// already exists.
struct MasterPasswordField: View {
    let placeholder: String
    @Binding var text: String
    var isDisabled = false
    let fieldIdentifier: String
    let revealIdentifier: String

    @State private var reveal = PasswordRevealState()

    var body: some View {
        HStack(spacing: 8) {
            fieldContent
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .disabled(isDisabled)
                .accessibilityIdentifier(fieldIdentifier)

            // Same iconography and modifier shape as `FieldRow`'s reveal toggle, for a consistent
            // reveal affordance across the app.
            Toggle(isOn: Binding(get: { reveal.isRevealed }, set: { _ in reveal.toggle() })) {
                Image(systemName: reveal.isRevealed ? "eye.slash" : "eye")
            }
            .toggleStyle(.button)
            .disabled(isDisabled)
            .help(reveal.isRevealed ? "Hide password" : "Reveal password")
            .accessibilityLabel(reveal.isRevealed ? "Hide password" : "Reveal password")
            .accessibilityIdentifier(revealIdentifier)
        }
        // Two different ways of "not looking at this anymore": another app becomes frontmost, or
        // this window specifically stops being key (a sheet or panel comes up in front of it, or
        // another of the app's own windows is raised). Either one hides a revealed password — the
        // brief's "not left on an unattended screen" requirement — deliberately without trying to
        // scope this to "my window only": over-hiding on some unrelated window's resign-key is a
        // harmless false positive, under-hiding is the actual risk.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            reveal.hide()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            reveal.hide()
        }
    }

    @ViewBuilder
    private var fieldContent: some View {
        if reveal.isRevealed {
            // Revealed mode is the only place a master password is ever rendered as plaintext, so
            // every macOS text-substitution feature that could silently rewrite it is turned off.
            // `.autocorrectionDisabled(true)` is the one SwiftUI modifier macOS actually exposes for
            // this. There is deliberately no separate modifier here for continuous spell-checking,
            // text replacement, or smart quotes/dashes — none exists in SwiftUI on macOS (checked
            // against the installed macOS 26 SDK's SwiftUI/SwiftUICore interface files, not
            // assumed). `.textContentType(.password)` is the one other macOS-11+ hook available: it
            // tells the system text-input stack this field holds a password, the same hint
            // `SecureField` gets implicitly below.
            TextField(placeholder, text: $text)
                .autocorrectionDisabled(true)
                .textContentType(.password)
        } else {
            SecureField(placeholder, text: $text)
                .textContentType(.password)
        }
    }
}
