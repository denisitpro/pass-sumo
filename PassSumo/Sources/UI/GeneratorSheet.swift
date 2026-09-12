import SwiftUI

/// Standalone password-generator sheet. Opened from two places with a genuinely different meaning
/// for "Use": `EntryEditView`'s generator-settings gear, where "Use" fills the password field being
/// edited, and `VaultBrowserView`'s toolbar, where there is no field to fill at all. It used to
/// paper over that second case by making "Use" just copy — identical to the "Copy" button right
/// next to it, with nothing on screen saying so (issue #45: the owner could not tell them apart
/// because, from the toolbar, they were not meaningfully apart). `onUse` is therefore OPTIONAL:
/// the caller with a real field to fill passes a closure, the caller with nothing to fill passes
/// `nil`, and this view hides "Use" entirely rather than disabling it with no explanation — it
/// stays agnostic about which caller it's in either way.
///
/// Reads its starting `Recipe` from whatever the caller hands it. A tweak made *inside* the sheet
/// — dragging the length slider, flipping a class off — is forwarded through `onRecipeChanged` so
/// the caller's saved default and the next generate-now both pick it up (issue #129, Strongbox's
/// two-control pattern). That supersedes issue #106's one-off choice: opening the sheet is no
/// longer a throwaway generation, it is also the settings UI. This view still never writes
/// `UserDefaults` itself — the callback is the only persist path, and `AppSettings.generatorRecipe`
/// already writes on `didSet`. `PasswordGenerator.Recipe()`'s own hardcoded defaults (20 chars,
/// every class on, ambiguous glyphs excluded — see that type's doc comment) are used only where no
/// caller-supplied recipe exists at all, e.g. `#Preview`s and pre-#106 test fixtures.
struct GeneratorSheet: View {
    let generator: PasswordGenerator
    let clipboard: ClipboardService
    var onUse: ((String) -> Void)?
    /// Optional so existing call sites still compile. Invoked on every recipe edit (the same
    /// `onChange(of: recipe)` that regenerates), never from this type's own storage.
    var onRecipeChanged: ((PasswordGenerator.Recipe) -> Void)? = nil

    /// The `Recipe` this sheet was constructed with — distinct from the live-edited `@State private
    /// var recipe` below, and kept as its own plain, non-`@State` property so a caller's wiring is
    /// assertable directly on a freshly-constructed instance without rendering (issue #106: neither
    /// `EntryEditView` nor `VaultBrowserView` passed a `recipe:` at all, `GeneratorSheet` silently
    /// fell back to `Recipe()`'s default, and nothing about `GeneratorSheet` itself would ever have
    /// caught that — the regression test for this lives at each caller, checking this property).
    let openingRecipe: PasswordGenerator.Recipe

    @Environment(\.dismiss) private var dismiss

    @State private var recipe: PasswordGenerator.Recipe
    @State private var result = ""
    @State private var error: PasswordGenerator.GeneratorError?

    init(
        generator: PasswordGenerator,
        recipe: PasswordGenerator.Recipe = .init(),
        clipboard: ClipboardService,
        onUse: ((String) -> Void)? = nil,
        onRecipeChanged: ((PasswordGenerator.Recipe) -> Void)? = nil
    ) {
        self.generator = generator
        self.clipboard = clipboard
        self.onUse = onUse
        self.onRecipeChanged = onRecipeChanged
        self.openingRecipe = recipe
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
        // The same hook is the persist path (issue #129): a slider tick is a settings change, not
        // a one-off for this generation.
        .onChange(of: recipe) {
            regenerate()
            onRecipeChanged?(recipe)
        }
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
