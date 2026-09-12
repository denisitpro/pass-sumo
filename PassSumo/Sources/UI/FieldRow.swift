import AppKit
import SwiftUI

/// One label/value row shared everywhere the browser shows "Label: value [copy]" — every field in
/// `EntryDetailView` is one of these, so the reveal/VoiceOver rules below are enforced in exactly
/// one place instead of once per field.
struct FieldRow: View {
    let label: String
    let value: String
    var isMonospaced: Bool = false
    /// Non-nil marks the value as a link (the mockup's `.field .link` treatment, accent-coloured
    /// and clickable) and is what runs when it's clicked — one flag instead of the earlier
    /// `isLink: Bool` + separate action, so link *styling* can never exist without link
    /// *behaviour* (issue #17: the old split let a caller set the colour and forget the click).
    /// `nil` leaves the value as plain, selectable text, same as any other field.
    var onActivateLink: (() -> Void)? = nil
    /// Non-nil marks this as a secret: `value` renders as fixed-width dots unless the bound `Bool`
    /// is `true`. `nil` means "not a secret" — no dots, no reveal toggle, `value` shown plainly.
    var isRevealed: Binding<Bool>?
    var onCopy: (() -> Void)?
    var copyIdentifier: String?
    var revealIdentifier: String?

    private var isSecret: Bool { isRevealed != nil }
    private var isConcealed: Bool { isSecret && isRevealed?.wrappedValue != true }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s5) {
            Text(label)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .frame(width: Metrics.fieldLabelWidth, alignment: .leading)
                // The combined element on `valueContent` already carries this label.
                .accessibilityHidden(true)

            valueContent
                .frame(maxWidth: .infinity, alignment: .leading)
                // ONE combined accessibility element covering label+value only. The copy/reveal
                // buttons below are deliberately kept OUTSIDE it so VoiceOver and XCUITest can
                // still reach each one individually by its own identifier — folding everything
                // into a single element would swallow `detail.copyPassword` /
                // `detail.revealPassword` as separately-findable targets.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                // The VoiceOver VALUE is the literal word "hidden" for a concealed secret — never
                // `value` itself, and never even its length (see `valueContent`'s fixed-width dots
                // below for the same reasoning applied visually). Getting this one line wrong
                // reads a stored password aloud to anyone standing near the user.
                .accessibilityValue(isConcealed ? "hidden" : (value.isEmpty ? "empty" : value))

            if let isRevealed {
                // A quiet glyph, not `.toggleStyle(.button)`: the filled, tinted rendering a
                // button-style toggle gets once on reads as an action of the same weight as Copy
                // beside it, which it is not. Same reasoning as `MasterPasswordField`'s eye.
                Button {
                    isRevealed.wrappedValue.toggle()
                } label: {
                    Image(systemName: isRevealed.wrappedValue ? "eye.slash" : "eye")
                }
                .buttonStyle(.tokenGlyph)
                .help(isRevealed.wrappedValue ? "Hide \(label)" : "Reveal \(label)")
                .accessibilityLabel(isRevealed.wrappedValue ? "Hide \(label)" : "Reveal \(label)")
                .accessibilityIdentifier(revealIdentifier ?? "")
            }

            if let onCopy {
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.tokenGlyph)
                .help("Copy \(label)")
                .accessibilityLabel("Copy \(label)")
                .accessibilityIdentifier(copyIdentifier ?? "")
            }
        }
    }

    @ViewBuilder
    private var valueContent: some View {
        if isConcealed {
            // A fixed run of dots, not `value.count` dots: the *length* of a password is itself
            // information worth not leaking to a shoulder-surfer, so a concealed field always
            // shows the same placeholder regardless of the real value's size.
            Text("••••••••••••")
                .font(isMonospaced ? Typography.monoBody : Typography.body)
                .foregroundStyle(Palette.text)
        } else if value.isEmpty {
            Text("—")
                .font(Typography.body)
                .foregroundStyle(Palette.textTertiary)
        } else if let onActivateLink {
            // A link value is clicked, not selected — the same convention as any hyperlink, and
            // why `.textSelection` is deliberately absent only on this branch; every other value
            // keeps it. `.plain` keeps `TokenButtonSurface`'s padding/fill/border out of this —
            // the row must still look like `FieldRow`'s other values, just as a link.
            // accent700 (#0F5163) is nearly Palette.text (#10242A), so links were invisible
            // (issue #150); accent600 + underline is the glanceable treatment.
            Button(action: onActivateLink) {
                Text(value)
                    .font(isMonospaced ? Typography.monoBody : Typography.body)
                    .foregroundStyle(Palette.accent600)
                    .underline()
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
            // No design token for cursor shape — this is AppKit interop, not a stylistic choice.
            // `.set()` rather than `.push()/.pop()`: a push/pop pair can desync if this row is
            // torn down (entry switched) while still hovered, leaving the pointing hand stuck.
            .onHover { isHovered in
                (isHovered ? NSCursor.pointingHand : NSCursor.arrow).set()
            }
            .accessibilityAddTraits(.isLink)
        } else {
            Text(value)
                .font(isMonospaced ? Typography.monoBody : Typography.body)
                .foregroundStyle(Palette.text)
                .textSelection(.enabled)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 12) {
        FieldRow(label: "Title", value: "GitHub")
        FieldRow(label: "Username", value: "samplecoder", onCopy: {}, copyIdentifier: "detail.copyUsername")
        FieldRow(
            label: "Password", value: "Tr0ub4dor&3", isMonospaced: true,
            isRevealed: .constant(false), onCopy: {}, copyIdentifier: "detail.copyPassword",
            revealIdentifier: "detail.revealPassword"
        )
        FieldRow(label: "Notes", value: "")
    }
    .padding()
}
