import SwiftUI

/// Standalone password-generator sheet. Opened from two places with a genuinely different meaning
/// for "Use": `EntryEditView`'s "Generate" button, where "Use" fills the password field being
/// edited, and `VaultBrowserView`'s toolbar, where there is no field to fill at all. It used to
/// paper over that second case by making "Use" just copy — identical to the "Copy" button right
/// next to it, with nothing on screen saying so (issue #45: the owner could not tell them apart
/// because, from the toolbar, they were not meaningfully apart). `onUse` is therefore OPTIONAL:
/// the caller with a real field to fill passes a closure, the caller with nothing to fill passes
/// `nil`, and this view hides "Use" entirely rather than disabling it with no explanation — it
/// stays agnostic about which caller it's in either way.
///
/// Reads its starting `Recipe` from whatever the caller hands it and never persists a change back —
/// there is no `Settings`/`SettingsStore` type in this repo yet (checked before writing this file),
/// so "remember the user's last recipe" is deferred to whoever adds one; until then every open
/// starts from `PasswordGenerator.Recipe`'s own defaults (20 chars, every class on, ambiguous
/// glyphs excluded — see that type's doc comment).
struct GeneratorSheet: View {
    let generator: PasswordGenerator
    let clipboard: ClipboardService
    var onUse: ((String) -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var recipe: PasswordGenerator.Recipe
    @State private var result = ""
    @State private var error: PasswordGenerator.GeneratorError?

    init(
        generator: PasswordGenerator,
        recipe: PasswordGenerator.Recipe = .init(),
        clipboard: ClipboardService,
        onUse: ((String) -> Void)? = nil
    ) {
        self.generator = generator
        self.clipboard = clipboard
        self.onUse = onUse
        _recipe = State(initialValue: recipe)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s6) {
            Text("Generate Password")
                .font(Typography.headline)
                .foregroundStyle(Palette.text)

            resultField

            VStack(alignment: .leading, spacing: Spacing.s2) {
                Text("Length: \(recipe.length)")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                // 4...64: `PasswordGenerator` itself has no upper bound, but a slider needs one —
                // 64 comfortably covers every real site's field-length cap while keeping the
                // slider usable at a small drag distance.
                Slider(
                    value: Binding(
                        get: { Double(recipe.length) },
                        set: { recipe.length = Int($0.rounded()) }
                    ),
                    in: 4...64,
                    step: 1
                )
                .accessibilityIdentifier("generator.length")
            }

            VStack(alignment: .leading, spacing: Spacing.s3) {
                Toggle("Lowercase (a–z)", isOn: $recipe.lowercase)
                Toggle("Uppercase (A–Z)", isOn: $recipe.uppercase)
                Toggle("Digits (0–9)", isOn: $recipe.digits)
                Toggle("Symbols (!#$%…)", isOn: $recipe.symbols)
                Toggle("Exclude ambiguous characters (0 O 1 l I)", isOn: $recipe.excludeAmbiguous)
            }
            .font(Typography.body)
            .foregroundStyle(Palette.text)

            Text("Entropy: \(Int(generator.strengthBits(for: recipe).rounded())) bits")
                .font(Typography.monoCaption2)
                .foregroundStyle(Palette.textTertiary)
                .accessibilityIdentifier("generator.entropy")

            VStack(alignment: .trailing, spacing: Spacing.s2) {
                Divider().overlay(Palette.border)

                HStack(spacing: Spacing.s3) {
                    Button("Regenerate", action: regenerate)
                        .buttonStyle(.tokenSecondary)
                        .accessibilityIdentifier("generator.regenerate")
                        .keyboardShortcut("r", modifiers: .command)

                    Spacer()

                    // Leftmost of the trailing group, and the odd one out stylistically on
                    // purpose: this dismisses without doing anything to the result, unlike Copy
                    // and Use beside it. `.cancelAction` is what keeps Esc working — SwiftUI does
                    // not dismiss a macOS sheet on Esc by itself; a button bound to it is what does.
                    Button("Close") { dismiss() }
                        .buttonStyle(.tokenQuiet)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("generator.close")

                    // Copy puts the result on the clipboard (through the app's one
                    // `ClipboardService`, auto-clear and concealed-pasteboard markers included —
                    // see that type) and leaves the sheet open, e.g. to keep tweaking the recipe.
                    Button("Copy") { clipboard.copy(result) }
                        // Primary when it is the only committing action on the sheet (opened from
                        // the toolbar, with no field to fill), secondary when "Use" is beside it.
                        .actionButtonStyle(isPrimary: onUse == nil)
                        .accessibilityIdentifier("generator.copy")
                        .disabled(result.isEmpty)

                    // Use exists only where there is something to use it ON — see this type's own
                    // doc comment on why `onUse` is optional rather than a toolbar-only "Use" that
                    // silently did the same thing as Copy.
                    if let onUse {
                        Button("Use") {
                            onUse(result)
                            dismiss()
                        }
                        .buttonStyle(.tokenPrimary)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("generator.use")
                        .disabled(result.isEmpty)
                    }
                }

                // Issue #3's "show the machinery" rule: the countdown that follows a Copy is real
                // app behavior, not a fixed constant, so this reads the live, user-configurable
                // value rather than restating whatever `ClipboardService`'s own default happens to
                // be right now.
                Text("Clipboard clears after \(Int(clipboard.clearInterval))s")
                    .font(Typography.monoCaption2)
                    .foregroundStyle(Palette.textTertiary)
                    .accessibilityIdentifier("generator.clipboardTimeout")
            }
        }
        .padding(Spacing.s7)
        .frame(width: 380)
        .background(Palette.surface)
        .onAppear(perform: regenerate)
        // `Recipe` is `Equatable` (see `PasswordGenerator.swift`) specifically so this can fire on
        // ANY toggle/length change without listing each `@State` var separately — a new recipe
        // means the on-screen password no longer matches what the controls say, so it must be
        // redrawn immediately rather than waiting for the user to notice and hit Regenerate.
        .onChange(of: recipe, regenerate)
    }

    @ViewBuilder
    private var resultField: some View {
        VStack(alignment: .leading, spacing: Spacing.s2) {
            Text(result.isEmpty ? " " : result)
                .font(Typography.monoField)
                .foregroundStyle(Palette.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.s4)
                .sunkenWell()
                .accessibilityIdentifier("generator.result")

            if let error {
                Text(errorMessage(for: error))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.danger)
            }
        }
    }

    private func regenerate() {
        do {
            result = try generator.generate(recipe)
            error = nil
        } catch let failure as PasswordGenerator.GeneratorError {
            error = failure
            result = ""
        } catch {
            // `generate(_:)`'s signature only ever throws `GeneratorError` — this branch exists
            // purely because `catch` must be exhaustive, not because another error type can
            // actually reach it.
            result = ""
        }
    }

    private func errorMessage(for error: PasswordGenerator.GeneratorError) -> String {
        switch error {
        case .noCharacterClassEnabled:
            return "Turn on at least one character class."
        case .lengthTooShort(let minimum):
            return "Length must be at least \(minimum) to include one of each enabled class."
        case .randomSourceUnavailable:
            return "The system's secure random generator is unavailable right now."
        }
    }
}

#Preview {
    GeneratorSheet(generator: PasswordGenerator(), clipboard: ClipboardService(), onUse: { _ in })
}
