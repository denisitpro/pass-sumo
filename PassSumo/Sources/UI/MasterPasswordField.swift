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
/// rendering is a near-invisible 1px hairline, which was the owner's actual complaint (issue #32 —
/// "the field is ugly, barely visible"), not just the width bug. It draws its own
/// background/border/focus-ring instead, from the design token layer's `.fieldChrome` (issue #56),
/// sized to read as an input at a glance. The reveal toggle sits INSIDE the field's trailing edge (not a separate button
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
    /// Parent-owned focus, so a caller can put the caret back after something else (the system
    /// Touch ID sheet) stole it. When nil, the field keeps its own `@FocusState`.
    var focused: FocusState<Bool>.Binding? = nil

    @State private var reveal = PasswordRevealState()
    @FocusState private var internallyFocused: Bool

    private var activeFocus: FocusState<Bool>.Binding {
        focused ?? $internallyFocused
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            fieldContent
                .textFieldStyle(.plain)
                .font(Typography.field)
                .foregroundStyle(Palette.text)
                .controlSize(.large)
                .padding(.leading, Spacing.s4)
                .padding(.trailing, Metrics.fieldGlyphInset)
                .frame(height: Metrics.fieldHeight)
                // Border weight, ground and focus ring all come from the token layer's
                // `.fieldChrome` — see `FieldChrome` in `DesignStyles.swift`. Resting state is a
                // `border-strong` line at `field-border-width`, which is what makes the field read
                // as an input at a glance (issue #32); focus swaps to the accent at
                // `border-focus-width` plus the `accent-200` glow.
                .fieldChrome(isFocused: activeFocus.wrappedValue)
                .focused(activeFocus)
                .disabled(isDisabled)
                .accessibilityIdentifier(fieldIdentifier)

            Button {
                reveal.toggle()
            } label: {
                Image(systemName: reveal.isRevealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.tokenGlyph)
            .padding(.trailing, Spacing.s3)
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
        // placeholder gray reads as a whisper (the owner's other complaint). `text-3` is the
        // palette's placeholder tone, and it sits on `surface` — the one ground it clears WCAG AA
        // against (see design/BRAND.md).
        let prompt = Text(placeholder).foregroundStyle(Palette.textTertiary)

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
