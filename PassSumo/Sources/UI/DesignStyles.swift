import SwiftUI

// ============================================================================
// The component layer: the buttons, surfaces, fields and rows the approved
// mockup (`design/mockups/palette-variants.html`, palette C) actually shows,
// expressed as `ButtonStyle`/`ViewModifier` conformances so no view hand-rolls
// its own appearance.
//
// Every value used here comes from `DesignTokens.swift`. This file contains no
// literals, and neither does any view — that invariant is what makes a palette
// change a one-file edit.
// ============================================================================

// MARK: - Buttons

/// Everything that distinguishes one button kind from another, as data.
///
/// A new button kind adds a value of this type plus a two-line `ButtonStyle`; it never edits the
/// shared surface below. Hover and press share one visual state deliberately — the mockup defines
/// a hover treatment and no pressed treatment, and reusing hover keeps this from inventing one.
private struct ButtonAppearance {
    var fill: Color
    var hoverFill: Color
    var border: Color
    var hoverBorder: Color
    var label: Color
    var hoverLabel: Color
    var font: Font = Typography.bodyMedium
    var horizontalPadding: CGFloat = Spacing.s5
    var verticalPadding: CGFloat = Spacing.s2
    var cornerRadius: CGFloat = Radius.sm
}

/// Draws a `ButtonAppearance`. Private on purpose: callers reach it through one of the concrete
/// styles below, never by describing an appearance of their own at the call site.
private struct TokenButtonSurface: View {
    let configuration: ButtonStyleConfiguration
    let appearance: ButtonAppearance

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    private var isHighlighted: Bool { isEnabled && (isHovered || configuration.isPressed) }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: appearance.cornerRadius, style: .continuous)
    }

    var body: some View {
        configuration.label
            .font(appearance.font)
            .foregroundStyle(isHighlighted ? appearance.hoverLabel : appearance.label)
            .padding(.horizontal, appearance.horizontalPadding)
            .padding(.vertical, appearance.verticalPadding)
            .background(shape.fill(isHighlighted ? appearance.hoverFill : appearance.fill))
            .overlay(
                shape.strokeBorder(
                    isHighlighted ? appearance.hoverBorder : appearance.border,
                    lineWidth: Metrics.hairline
                )
            )
            .contentShape(shape)
            .opacity(isEnabled ? 1 : Metrics.disabledOpacity)
            .onHover { isHovered = $0 }
    }
}

/// The filled primary action — the mockup's `.btn-primary`. **One per screen**: the accent is what
/// says "this is the thing to do", and two of them on one screen says nothing.
struct PrimaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TokenButtonSurface(
            configuration: configuration,
            appearance: ButtonAppearance(
                fill: Palette.accent600,
                hoverFill: Palette.accent700,
                border: Palette.accent600,
                hoverBorder: Palette.accent700,
                label: Palette.white,
                hoverLabel: Palette.white
            )
        )
    }
}

/// The bordered secondary action — the mockup's `.btn`. Everything that is a real action but not
/// *the* action: Cancel, Copy, Regenerate, Edit.
struct SecondaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TokenButtonSurface(
            configuration: configuration,
            appearance: ButtonAppearance(
                fill: Palette.surface,
                hoverFill: Palette.sunken,
                border: Palette.borderStrong,
                hoverBorder: Palette.borderStrong,
                label: Palette.text,
                hoverLabel: Palette.text
            )
        )
    }
}

/// A borderless, quiet action — the mockup's `.btn-plain`. For a control that dismisses or
/// navigates rather than committing anything: Close, a recent-file row.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TokenButtonSurface(
            configuration: configuration,
            appearance: ButtonAppearance(
                fill: .clear,
                hoverFill: Palette.sunken,
                border: .clear,
                hoverBorder: .clear,
                label: Palette.textSecondary,
                hoverLabel: Palette.text
            )
        )
    }
}

/// A destructive action stated in words. Bordered rather than filled: a filled red button is the
/// most clickable thing on the screen, which is the opposite of what a delete wants to be.
struct DestructiveActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TokenButtonSurface(
            configuration: configuration,
            appearance: ButtonAppearance(
                fill: Palette.surface,
                hoverFill: Palette.dangerBackground,
                border: Palette.borderStrong,
                hoverBorder: Palette.danger,
                label: Palette.danger,
                hoverLabel: Palette.danger
            )
        )
    }
}

/// A borderless square icon button — the mockup's `.icon-btn`. Copy, reveal, export, open-URL,
/// remove: every glyph-only control in the app.
struct GlyphButtonStyle: ButtonStyle {
    /// Turns the hover ground red — for a glyph that removes something.
    var isDestructive = false

    func makeBody(configuration: Configuration) -> some View {
        GlyphButtonSurface(configuration: configuration, isDestructive: isDestructive)
    }
}

private struct GlyphButtonSurface: View {
    let configuration: ButtonStyleConfiguration
    let isDestructive: Bool

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    private var isHighlighted: Bool { isEnabled && (isHovered || configuration.isPressed) }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
    }

    var body: some View {
        configuration.label
            .font(Typography.body)
            .foregroundStyle(highlightForeground)
            .frame(width: Metrics.glyphButtonSize, height: Metrics.glyphButtonSize)
            .background(shape.fill(isHighlighted ? highlightBackground : .clear))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : Metrics.disabledOpacity)
            .onHover { isHovered = $0 }
    }

    private var highlightForeground: Color {
        guard isHighlighted else { return Palette.textSecondary }
        return isDestructive ? Palette.danger : Palette.text
    }

    private var highlightBackground: Color {
        isDestructive ? Palette.dangerBackground : Palette.sunken
    }
}

extension ButtonStyle where Self == PrimaryActionButtonStyle {
    /// The one accent-filled action on a screen.
    static var tokenPrimary: PrimaryActionButtonStyle { PrimaryActionButtonStyle() }
}

extension ButtonStyle where Self == SecondaryActionButtonStyle {
    static var tokenSecondary: SecondaryActionButtonStyle { SecondaryActionButtonStyle() }
}

extension ButtonStyle where Self == QuietButtonStyle {
    static var tokenQuiet: QuietButtonStyle { QuietButtonStyle() }
}

extension ButtonStyle where Self == DestructiveActionButtonStyle {
    static var tokenDestructive: DestructiveActionButtonStyle { DestructiveActionButtonStyle() }
}

/// Picks the primary or the secondary style for a control whose weight depends on whether a more
/// important action exists beside it — the generator's "Copy" is the committing action when there
/// is no "Use", and a secondary one when there is.
private struct AdaptiveActionStyle: ViewModifier {
    let isPrimary: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isPrimary {
            content.buttonStyle(.tokenPrimary)
        } else {
            content.buttonStyle(.tokenSecondary)
        }
    }
}

extension View {
    func actionButtonStyle(isPrimary: Bool) -> some View {
        modifier(AdaptiveActionStyle(isPrimary: isPrimary))
    }
}

extension ButtonStyle where Self == GlyphButtonStyle {
    static var tokenGlyph: GlyphButtonStyle { GlyphButtonStyle() }

    /// A glyph whose hover ground turns red — for one that removes something.
    static var tokenDestructiveGlyph: GlyphButtonStyle { GlyphButtonStyle(isDestructive: true) }
}

// MARK: - Surfaces

/// A raised card on the canvas — the mockup's `.unlock-card` and `.sheet`.
private struct CardSurface: ViewModifier {
    let cornerRadius: CGFloat
    let isFloating: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background(shape.fill(Palette.surface))
            .overlay(isFloating ? nil : shape.strokeBorder(Palette.border, lineWidth: Metrics.hairline))
            .elevation(isFloating ? [Elevation.sheet] : Elevation.card)
    }
}

/// An inset well on a surface — the mockup's `.result`, `.otp` and `.search`.
private struct SunkenWell: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background(shape.fill(Palette.sunken))
            .overlay(shape.strokeBorder(Palette.border, lineWidth: Metrics.hairline))
    }
}

/// A text field's border, ground and focus ring — the mockup's `.pw-field`.
///
/// The field owns its own chrome rather than using `.textFieldStyle(.roundedBorder)`, because the
/// system's rendering is a near-invisible hairline; see `MasterPasswordField`'s doc comment for
/// the full account (issue #32).
private struct FieldChrome: ViewModifier {
    let isFocused: Bool
    let isError: Bool

    private var borderColor: Color {
        if isError { return Palette.danger }
        return isFocused ? Palette.accent600 : Palette.borderStrong
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        return content
            .background(shape.fill(Palette.surface))
            .overlay(
                shape.strokeBorder(
                    borderColor,
                    lineWidth: isFocused ? Metrics.focusRingWidth : Metrics.fieldBorderWidth
                )
            )
            // The soft outer glow, drawn only on focus — `0 0 0 3px var(--accent-200)` in the
            // mockup, which is a spread with no blur, i.e. a ring rather than a shadow.
            .overlay(
                shape
                    .inset(by: -Metrics.focusGlowWidth / 2)
                    .strokeBorder(
                        isFocused ? Palette.accent200 : .clear,
                        lineWidth: Metrics.focusGlowWidth
                    )
            )
    }
}

extension View {
    /// A raised card on the canvas. `isFloating` picks the sheet shadow (and drops the hairline)
    /// for something presented over a scrim.
    func cardSurface(cornerRadius: CGFloat = Radius.lg, isFloating: Bool = false) -> some View {
        modifier(CardSurface(cornerRadius: cornerRadius, isFloating: isFloating))
    }

    /// An inset well on a surface.
    func sunkenWell(cornerRadius: CGFloat = Radius.sm) -> some View {
        modifier(SunkenWell(cornerRadius: cornerRadius))
    }

    /// A text field's border, ground and focus ring.
    func fieldChrome(isFocused: Bool, isError: Bool = false) -> some View {
        modifier(FieldChrome(isFocused: isFocused, isError: isError))
    }
}

// MARK: - List rows

/// One row of the entry list — fixed height, its own ground, and an inset separator.
///
/// The separator is drawn here as an overlay rather than left to `List`, because the mockup insets
/// it to the row's leading padding (`.entry-row::after { left: var(--space-5) }`) and pins it to
/// the pane's trailing edge, which `listRowSeparator` cannot express on its own.
private struct EntryRowSurface: ViewModifier {
    let isSelected: Bool
    let showsSeparator: Bool

    @State private var isHovered = false

    private var background: Color {
        if isSelected { return Palette.rowSelectionBackground }
        return isHovered ? Palette.sunken : Palette.surface
    }

    func body(content: Content) -> some View {
        content
            .frame(height: Metrics.entryRowHeight)
            .padding(.horizontal, Spacing.s5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .overlay(alignment: .bottomLeading) {
                if showsSeparator {
                    Palette.border
                        .frame(height: Metrics.hairline)
                        .padding(.leading, Spacing.s5)
                }
            }
            .onHover { isHovered = $0 }
    }
}

/// One row of the group sidebar — fixed height and a rounded selection pill.
private struct SidebarRowSurface: ViewModifier {
    let isSelected: Bool

    @State private var isHovered = false

    private var background: Color {
        if isSelected { return Palette.rowSelectionBackground }
        return isHovered ? Palette.sunken : .clear
    }

    func body(content: Content) -> some View {
        content
            .frame(height: Metrics.sidebarRowHeight)
            .padding(.horizontal, Spacing.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(background)
            )
            .onHover { isHovered = $0 }
    }
}

extension View {
    /// Applies the entry list's row appearance. Pair it with `.listRowInsets(EdgeInsets())` and
    /// `.listRowSeparator(.hidden)` so the row owns its own padding and hairline.
    func entryRowSurface(isSelected: Bool, showsSeparator: Bool = true) -> some View {
        modifier(EntryRowSurface(isSelected: isSelected, showsSeparator: showsSeparator))
    }

    /// Applies the group sidebar's row appearance.
    func sidebarRowSurface(isSelected: Bool) -> some View {
        modifier(SidebarRowSurface(isSelected: isSelected))
    }
}

// MARK: - Bands

/// The toolbar / status bar tone, with a hairline on the edge that faces the content.
private struct WindowBand: ViewModifier {
    let height: CGFloat
    let edge: Edge

    func body(content: Content) -> some View {
        content
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .background(Palette.sidebar)
            .overlay(alignment: edge == .top ? .top : .bottom) {
                Palette.border.frame(height: Metrics.hairline)
            }
    }
}

extension View {
    /// The status bar band: `sidebar` ground, fixed height, hairline along its top edge.
    func statusBarBand() -> some View {
        modifier(WindowBand(height: Metrics.statusBarHeight, edge: .top))
    }
}
