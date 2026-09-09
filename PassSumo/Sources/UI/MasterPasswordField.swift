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
/// of `CreateDatabaseSheet` (issue #32).
///
/// Deliberately does NOT use `.textFieldStyle(.roundedBorder)`: the system's own rounded-border
/// rendering is a near-invisible 1px hairline in both appearances, which was the owner's actual
/// complaint (issue #32 — "the field is ugly, barely visible"), not just the width bug. This draws
/// its own background/border/focus-ring instead, sized to read as an input at a glance in both
/// light and dark. The reveal toggle sits INSIDE the field's trailing edge (not a separate button
/// beside it) as a quiet, borderless glyph — deliberately not `FieldRow`'s `.toggleStyle(.button)`
/// treatment, because that renders as a filled, tinted button once revealed, which next to
/// `Unlock`'s own prominent default-action styling reads as two equally-weighted actions and
/// invites a misclick on the control that doesn't submit anything.
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
    @FocusState private var isFocused: Bool

    /// Room reserved on the trailing edge for the reveal glyph, so typed text never runs under it.
    private static let trailingInset: CGFloat = 34

    var body: some View {
        ZStack(alignment: .trailing) {
            fieldContent
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .controlSize(.large)
                .padding(.vertical, 9)
                .padding(.leading, 10)
                .padding(.trailing, Self.trailingInset)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    // Contrast, not just presence: `.primary` at partial opacity reads as a clear
                    // mid-gray line in light mode and a clear light-gray line in dark mode, instead
                    // of relying on a single fixed gray that only works in one appearance. Focus
                    // swaps to the full-strength accent color and a thicker line — the "clear focus
                    // indication" the brief asks for, owned by this view rather than left to
                    // whatever the platform default happens to render.
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isFocused ? Color.accentColor : Color.primary.opacity(0.32),
                            lineWidth: isFocused ? 2 : 1.25
                        )
                )
                .focused($isFocused)
                .disabled(isDisabled)
                .accessibilityIdentifier(fieldIdentifier)

            Button {
                reveal.toggle()
            } label: {
                Image(systemName: reveal.isRevealed ? "eye.slash" : "eye")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 10)
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
        // A custom `prompt` instead of the plain-string initializer: the system's default
        // placeholder gray reads as a whisper (the owner's other complaint). `.secondary` still
        // reads unambiguously as "nothing typed yet" rather than real content, just not this faint.
        let prompt = Text(placeholder).foregroundStyle(.secondary)

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
            // `label:` still carries the accessible name (VoiceOver), even though macOS never
            // renders it — only `prompt` shows on screen. Dropping it to `EmptyView()` would leave
            // the field with no spoken name once `text` is non-empty (the `prompt` text vanishes
            // with it).
            TextField(text: $text, prompt: prompt) { Text(placeholder) }
                .autocorrectionDisabled(true)
                .textContentType(.password)
        } else {
            SecureField(text: $text, prompt: prompt) { Text(placeholder) }
                .textContentType(.password)
        }
    }
}
