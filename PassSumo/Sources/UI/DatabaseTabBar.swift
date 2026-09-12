import SwiftUI

/// Database tabs inside the one window (issue #47). Filename as the title; a lock glyph when the
/// tab is still locked; a dot when it has unsaved edits. This is a custom bar, not NSWindow
/// tabbing — automatic window tabbing stays off so ⌘T remains Copy One-Time Code.
struct DatabaseTabBar: View {
    let environment: AppEnvironment

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.s1) {
                ForEach(environment.sessionList.sessions) { session in
                    DatabaseTab(
                        title: session.title,
                        isSelected: session.id == environment.sessionList.selectedID,
                        isDirty: session.store.isDirty,
                        isUnlocked: session.isUnlocked,
                        onSelect: { environment.sessionList.select(session.id) },
                        onClose: { _ = environment.sessionList.requestClose(session.id) }
                    )
                }
            }
            .padding(.horizontal, Spacing.s2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.sidebar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Palette.border)
                .frame(height: Metrics.hairline)
        }
        .accessibilityIdentifier("root.tabs")
    }
}

private struct DatabaseTab: View {
    let title: String
    let isSelected: Bool
    let isDirty: Bool
    let isUnlocked: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: Spacing.s2) {
            Button(action: onSelect) {
                HStack(spacing: Spacing.s2) {
                    if !isUnlocked {
                        Image(systemName: "lock.fill")
                            .font(Typography.caption2)
                            .foregroundStyle(Palette.textSecondary)
                            .accessibilityHidden(true)
                    }
                    Text(title)
                        .font(isSelected ? Typography.bodyMedium : Typography.body)
                        .foregroundStyle(isSelected ? Palette.text : Palette.textSecondary)
                        .lineLimit(1)
                    if isDirty {
                        Circle()
                            .fill(Palette.accent600)
                            .frame(width: Spacing.s2, height: Spacing.s2)
                            .accessibilityLabel("Unsaved changes")
                    }
                }
            }
            .buttonStyle(.plain)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(Typography.caption2)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: Metrics.glyphButtonSize, height: Metrics.glyphButtonSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(title)")
            .accessibilityIdentifier("root.tab.close")
        }
        .padding(.leading, Spacing.s4)
        .padding(.trailing, Spacing.s2)
        .padding(.vertical, Spacing.s2)
        .background(isSelected ? Palette.surface : Palette.sidebar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isSelected ? Palette.accent600 : Palette.sidebar)
                .frame(height: Metrics.hairline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("root.tab.\(title)")
    }
}
