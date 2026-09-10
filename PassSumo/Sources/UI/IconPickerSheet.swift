import SwiftUI

/// Picks one of KeePass's 69 built-in icons, for a folder or for an entry (issue #89).
///
/// **A grid, not a menu.** 69 items in a `Menu` is a list nobody can scan and half of which is off
/// the bottom of the screen; a grid of glyphs is the shape the thing being chosen already has, and
/// it is what every other KeePass client presents.
///
/// **Clicking an icon IS the commit.** There is no separate "Choose" button, because a grid cell is
/// not a field being filled in — the click already says which one, and a confirm step would make the
/// user say it twice. Cancel (and Esc, which reaches it through `.cancelAction`) leaves whatever was
/// selected before untouched. That is why the caller passes `onPick` rather than a `Binding`: the
/// sheet must be able to close having changed nothing at all.
///
/// This view does not know whether the pick is applied immediately or held in a draft — the folder
/// path writes it straight through `VaultStore`, the entry path parks it in `EntryEditView`'s own
/// state until Save. Both look the same from here, which is the point of it being one view.
struct IconPickerSheet: View {
    /// What is being re-iconed, for the sheet's title — "Folder Icon" / "Entry Icon".
    let title: String
    /// The index currently in effect, highlighted so the sheet opens showing where the user is.
    ///
    /// An index outside 0…68 (another client's, a future KeePass's) highlights nothing rather than
    /// being snapped to a default: the file's value survives until the user actually picks
    /// something, exactly as `VaultEntry.iconID`'s doc comment requires.
    let selectedIconID: UInt32
    let onPick: (UInt32) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Ten columns, fixed rather than adaptive. Fixed columns give the grid an intrinsic width, so
    /// the sheet sizes itself from the token layer instead of needing a hardcoded `.frame(width:)`;
    /// adaptive columns would fill whatever width they were given and leave nothing to size to.
    /// Ten also divides 69 into seven near-full rows, so the last row is not a lonely remainder.
    private static let columnCount = 10

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.fixed(Metrics.glyphButtonSize), spacing: Spacing.s2),
            count: Self.columnCount
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s6) {
            Text(title)
                .font(Typography.headline)
                .foregroundStyle(Palette.text)

            LazyVGrid(columns: columns, spacing: Spacing.s2) {
                ForEach(Array(StandardIconCatalog.symbolNames.enumerated()), id: \.offset) { iconID, symbolName in
                    cell(iconID: UInt32(iconID), symbolName: symbolName)
                }
            }

            HStack {
                Spacer()
                // The only button on the sheet, and deliberately the quiet role: it commits
                // nothing. `.cancelAction` is what makes Esc close the sheet — SwiftUI does not
                // dismiss a macOS sheet on Esc by itself (see `GeneratorSheet`'s Close).
                Button("Cancel") { dismiss() }
                    .buttonStyle(.tokenQuiet)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("iconPicker.cancel")
            }
        }
        .padding(Spacing.s7)
        .background(Palette.surface)
        .accessibilityIdentifier("iconPicker")
    }

    /// One glyph. A plain `Button` with its own selected treatment rather than `GlyphButtonStyle`,
    /// because that style has no selected state — it draws hover and focus only, and "which one is
    /// currently in effect" is the one thing this grid has to show at rest. It keeps the style's
    /// `glyph-button-size` square and `xs` radius so the cells still measure like every other glyph
    /// control in the app.
    private func cell(iconID: UInt32, symbolName: String) -> some View {
        let isSelected = iconID == selectedIconID
        return Button {
            onPick(iconID)
            dismiss()
        } label: {
            Image(systemName: symbolName)
                .font(Typography.body)
                .foregroundStyle(isSelected ? Palette.rowSelectionText : Palette.textSecondary)
                .frame(width: Metrics.glyphButtonSize, height: Metrics.glyphButtonSize)
                .background(
                    RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
                        .fill(isSelected ? Palette.rowSelectionBackground : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: Radius.xs, style: .continuous))
        }
        .buttonStyle(.plain)
        // The KeePass name is not shown as a label — 69 captions is a wall of text, and the names
        // ("PaperQ", "WorldSocket") are 2003 Windows jargon that means nothing to this app's user.
        // It reaches VoiceOver and the tooltip instead, where it costs no space.
        .help(symbolName)
        .accessibilityLabel(symbolName)
        .accessibilityIdentifier("iconPicker.icon.\(iconID)")
    }
}

#Preview {
    IconPickerSheet(title: "Folder Icon", selectedIconID: VaultGroup.defaultIconID, onPick: { _ in })
}
