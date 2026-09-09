import SwiftUI

// ============================================================================
// The design token layer — the ONLY file in this target where a colour literal
// or a raw dimension may appear.
//
// Canonical source: `design/BRAND.md` (palette C, "Steel Cyan"), which in turn
// took its values from `design/mockups/palette-variants.html` — the shared
// `:root` block merged with `:root[data-palette="C"]`. This file is a
// HAND-WRITTEN mirror, deliberately: there is no codegen step, so a value
// change edits BRAND.md and this file in the same PR (see
// ~/.claude/playbook/design.md).
//
// Every value here is LIGHT-ONLY. There is exactly one value per token, which
// is why `PassSumoApp` pins the window to the light appearance — issue #57
// tracks the dark ramp and the removal of that pin. Do not add a
// `colorScheme`-dependent branch here piecemeal; the dark set is decided as a
// set, not derived by inverting this one.
//
// Never invent a value. If a view needs a colour or a size that is not here,
// it goes into BRAND.md first, as a named token with a stated role.
// ============================================================================

extension Color {
    /// `0xRRGGBB` → `Color`, in sRGB at full opacity.
    ///
    /// Deliberately `fileprivate`: it exists so `Palette` below can be written as the same hex
    /// values `design/BRAND.md` owns, and keeping it invisible outside this file is what stops
    /// another view from smuggling a literal past the token layer.
    fileprivate init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

// MARK: - Colour

/// Every colour in the app. Grouped exactly as `design/BRAND.md` groups them, so the two can be
/// diffed by eye.
enum Palette {
    // MARK: Accent ramp

    /// Tinted hover ground behind a bordered accent control.
    static let accent50 = Color(hex: 0xECF6F9)
    static let accent100 = Color(hex: 0xD2E9EF)
    /// The focus glow drawn outside a focused field or button.
    static let accent200 = Color(hex: 0xA4D4DF)
    /// Border of a hovered accent control.
    static let accent300 = Color(hex: 0x6CB7C8)
    static let accent400 = Color(hex: 0x3A96AB)
    static let accent500 = Color(hex: 0x1B7A90)
    /// **The accent.** Primary button fill, focus ring, caret, progress fill, and the app-wide tint.
    static let accent600 = Color(hex: 0x14657A)
    /// Primary button hover fill; also link text and the label of a selected row.
    static let accent700 = Color(hex: 0x0F5163)
    static let accent800 = Color(hex: 0x0B3E4C)
    static let accent900 = Color(hex: 0x072C36)

    // MARK: Neutrals

    /// The ground behind a centred card — Welcome, Unlock, a sheet's backdrop.
    static let canvas = Color(hex: 0xF6FAFA)
    /// Cards, sheets, the entry list, the detail pane.
    static let surface = Color(hex: 0xFFFFFF)
    /// Inset wells: the search field, the OTP card, the generator's result, a hover ground.
    static let sunken = Color(hex: 0xEDF3F4)
    /// The group sidebar, the toolbar and the status bar all share one tone.
    static let sidebar = Color(hex: 0xEFF5F5)
    /// Hairlines: pane dividers, row separators, card edges.
    static let border = Color(hex: 0xDAE4E6)
    /// Control edges: a field's border, a secondary button's border, the toolbar separator.
    static let borderStrong = Color(hex: 0xBFCED1)

    // MARK: Text

    /// Primary content.
    static let text = Color(hex: 0x10242A)
    /// Field labels, secondary metadata, the label of a quiet button.
    static let textSecondary = Color(hex: 0x4E6169)
    /// Placeholders, captions, byte counts.
    ///
    /// **Only on `surface`.** Measured contrast: 4.69:1 on `surface`, but 4.46:1 on `canvas`,
    /// 4.25:1 on `sidebar` and 4.18:1 on `sunken` — all three below WCAG AA's 4.5:1 for normal
    /// text. Anything quiet on those grounds uses `textSecondary` instead. See `design/BRAND.md`.
    static let textTertiary = Color(hex: 0x64777E)

    // MARK: Selection

    static let rowSelectionBackground = Color(hex: 0xD2E9EF)
    static let rowSelectionText = Color(hex: 0x0F5163)

    // MARK: Semantic — identical in all three candidate palettes

    static let success = Color(hex: 0x157F4F)
    static let successBackground = Color(hex: 0xE6F4EC)
    static let warning = Color(hex: 0xA06400)
    static let warningBackground = Color(hex: 0xFBF1DE)
    static let danger = Color(hex: 0xB3261E)
    static let dangerBackground = Color(hex: 0xFBE9E7)

    static let strengthWeak = Color(hex: 0xC0392B)
    static let strengthFair = Color(hex: 0xC77D0A)
    static let strengthGood = Color(hex: 0x2A7F62)
    static let strengthStrong = Color(hex: 0x157F4F)

    /// The TOTP countdown once it is nearly out of time.
    static let totpExpiring = Color(hex: 0xC0392B)

    static let white = Color(hex: 0xFFFFFF)
}

// MARK: - Type

/// The type scale. Sizes only — the mockup's line heights are recorded in `design/BRAND.md` but
/// SwiftUI's `Text` has no equivalent knob at this level, so nothing here consumes them.
enum Typography {
    /// The raw point sizes, for the rare view that needs to size something to match text rather
    /// than to render text (a glyph, a reserved width).
    enum Size {
        static let caption2: CGFloat = 11
        static let caption: CGFloat = 12
        static let body: CGFloat = 13
        static let field: CGFloat = 15
        static let headline: CGFloat = 17
        static let title3: CGFloat = 20
        static let title2: CGFloat = 24
    }

    /// Weights in use across the whole design: nothing lighter than 400, nothing bolder than 600.
    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// The system monospace face — for anything the user reads character by character: a password,
    /// a path, a UUID, a byte count, a TOTP code.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static let caption2 = sans(Size.caption2)
    static let caption = sans(Size.caption)
    static let captionMedium = sans(Size.caption, weight: .medium)
    /// The default.
    static let body = sans(Size.body)
    static let bodyMedium = sans(Size.body, weight: .medium)
    static let bodySemibold = sans(Size.body, weight: .semibold)
    /// Text the user types.
    static let field = sans(Size.field)
    static let headline = sans(Size.headline, weight: .semibold)
    static let title3 = sans(Size.title3, weight: .semibold)
    static let title2 = sans(Size.title2, weight: .semibold)

    static let monoCaption2 = mono(Size.caption2)
    static let monoCaption = mono(Size.caption)
    static let monoBody = mono(Size.body)
    static let monoField = mono(Size.field)
    static let monoTitle3 = mono(Size.title3)
}

// MARK: - Spacing

/// The spacing scale — `2 · 4 · 6 · 8 · 12 · 16 · 20 · 24 · 32 · 40`. There is deliberately
/// nothing between the steps and nothing above `s10`.
enum Spacing {
    static let s1: CGFloat = 2
    static let s2: CGFloat = 4
    static let s3: CGFloat = 6
    static let s4: CGFloat = 8
    static let s5: CGFloat = 12
    static let s6: CGFloat = 16
    static let s7: CGFloat = 20
    static let s8: CGFloat = 24
    static let s9: CGFloat = 32
    static let s10: CGFloat = 40
}

// MARK: - Radii

/// Corner radii: chips and thumbnails, buttons and wells, text fields, cards, progress tracks.
enum Radius {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let md: CGFloat = 8
    static let lg: CGFloat = 10
    static let pill: CGFloat = 999
}

// MARK: - Structural sizes

/// Sizes that carry structure rather than rhythm: line weights and the fixed heights of the
/// window's horizontal bands.
enum Metrics {
    static let hairline: CGFloat = 1
    static let focusRingWidth: CGFloat = 2
    static let entryRowHeight: CGFloat = 34
    static let sidebarRowHeight: CGFloat = 26
    static let toolbarHeight: CGFloat = 44
    static let statusBarHeight: CGFloat = 26

    // The control sizes the mockup's component CSS pins but its `:root` token block does not name.
    // Recorded here (and in `design/BRAND.md`) rather than left as literals in the views.

    /// Width of the soft glow drawn outside a focused control — the mockup's `0 0 0 3px`.
    static let focusGlowWidth: CGFloat = 3
    /// A text field's resting border weight. Heavier than a hairline on purpose: the system's
    /// own 1px rounded-border rendering was the owner's original complaint in issue #32.
    static let fieldBorderWidth: CGFloat = 1.25
    /// A single-line text field's height.
    static let fieldHeight: CGFloat = 38
    /// Room reserved on a field's trailing edge for an inline glyph, so typed text never runs
    /// underneath it.
    static let fieldGlyphInset: CGFloat = 34
    /// A borderless icon button's hit target.
    static let glyphButtonSize: CGFloat = 24
    /// The large lock/shield glyph a centred card is headed by — the mockup's `.big-lock`.
    static let heroGlyphSize: CGFloat = 40
    /// The label column of a label/value field row.
    static let fieldLabelWidth: CGFloat = 90

    /// How far a disabled control is faded.
    ///
    /// **The one value in this file with no counterpart in the approved mockup** — the mockup has
    /// no disabled state, and a custom `ButtonStyle` gets no automatic dimming from SwiftUI, so a
    /// disabled primary action would otherwise look pressable. Flagged as such in
    /// `design/BRAND.md`; replace it with whatever the full design system decides (issue #3).
    static let disabledOpacity: Double = 0.4
}

// MARK: - Elevation

/// Shadows and the modal scrim. One ink at three opacities.
enum Elevation {
    /// The ink behind every shadow and the scrim — `rgba(16,24,40,·)` in the mockup.
    static let ink = Color(hex: 0x101828)

    struct Shadow {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat
    }

    /// Two stacked layers, as in the mockup's `--shadow-card`.
    ///
    /// CSS blur-radius and SwiftUI's shadow `radius` are not the same quantity. The numbers are
    /// kept as the mockup writes them rather than converted, because a converted number would be
    /// a value nobody approved.
    static let card: [Shadow] = [
        Shadow(color: ink.opacity(0.06), radius: 2, x: 0, y: 1),
        Shadow(color: ink.opacity(0.10), radius: 3, x: 0, y: 1),
    ]

    static let sheet = Shadow(color: ink.opacity(0.18), radius: 32, x: 0, y: 12)

    static let scrim = ink.opacity(0.16)
}

extension View {
    /// Applies a stack of `Elevation` shadow layers in order.
    func elevation(_ layers: [Elevation.Shadow]) -> some View {
        layers.reduce(AnyView(self)) { view, layer in
            AnyView(view.shadow(color: layer.color, radius: layer.radius, x: layer.x, y: layer.y))
        }
    }

    func elevation(_ layer: Elevation.Shadow) -> some View {
        shadow(color: layer.color, radius: layer.radius, x: layer.x, y: layer.y)
    }
}
