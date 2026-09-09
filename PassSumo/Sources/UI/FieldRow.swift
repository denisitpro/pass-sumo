import SwiftUI

/// One label/value row shared everywhere the browser shows "Label: value [copy]" — every field in
/// `EntryDetailView` is one of these, so the reveal/VoiceOver rules below are enforced in exactly
/// one place instead of once per field.
struct FieldRow: View {
    let label: String
    let value: String
    var isMonospaced: Bool = false
    /// Renders the value in the accent, the mockup's `.field .link` treatment — for a value that
    /// points somewhere (the URL row). Presentation only: it does not make the text clickable, and
    /// the button that actually opens the URL still lives beside the row in `EntryDetailView`.
    var isLink: Bool = false
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
        } else {
            Text(value)
                .font(isMonospaced ? Typography.monoBody : Typography.body)
                .foregroundStyle(isLink ? Palette.accent700 : Palette.text)
                .textSelection(.enabled)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 12) {
        FieldRow(label: "Title", value: "GitHub")
        FieldRow(label: "Username", value: "denisitpro", onCopy: {}, copyIdentifier: "detail.copyUsername")
        FieldRow(
            label: "Password", value: "Tr0ub4dor&3", isMonospaced: true,
            isRevealed: .constant(false), onCopy: {}, copyIdentifier: "detail.copyPassword",
            revealIdentifier: "detail.revealPassword"
        )
        FieldRow(label: "Notes", value: "")
    }
    .padding()
}
