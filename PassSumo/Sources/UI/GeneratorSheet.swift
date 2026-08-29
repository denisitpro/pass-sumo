import SwiftUI

/// Standalone password-generator sheet. Opened from two places with different meanings for "Use":
/// the browser toolbar (no target field exists there — see `VaultBrowserView`'s call site, where
/// "Use" just copies) and `EntryEditView`'s "Generate" button (where "Use" fills the password field
/// being edited). Both meanings are expressed as the `onUse` closure so this view stays agnostic
/// about which one it's in.
///
/// Reads its starting `Recipe` from whatever the caller hands it and never persists a change back —
/// there is no `Settings`/`SettingsStore` type in this repo yet (checked before writing this file),
/// so "remember the user's last recipe" is deferred to whoever adds one; until then every open
/// starts from `PasswordGenerator.Recipe`'s own defaults (20 chars, every class on, ambiguous
/// glyphs excluded — see that type's doc comment).
struct GeneratorSheet: View {
    let generator: PasswordGenerator
    let clipboard: ClipboardService
    var onUse: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var recipe: PasswordGenerator.Recipe
    @State private var result = ""
    @State private var error: PasswordGenerator.GeneratorError?

    init(
        generator: PasswordGenerator,
        recipe: PasswordGenerator.Recipe = .init(),
        clipboard: ClipboardService,
        onUse: @escaping (String) -> Void
    ) {
        self.generator = generator
        self.clipboard = clipboard
        self.onUse = onUse
        _recipe = State(initialValue: recipe)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Generate Password")
                .font(.headline)

            resultField

            VStack(alignment: .leading, spacing: 4) {
                Text("Length: \(recipe.length)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Lowercase (a–z)", isOn: $recipe.lowercase)
                Toggle("Uppercase (A–Z)", isOn: $recipe.uppercase)
                Toggle("Digits (0–9)", isOn: $recipe.digits)
                Toggle("Symbols (!#$%…)", isOn: $recipe.symbols)
                Toggle("Exclude ambiguous characters (0 O 1 l I)", isOn: $recipe.excludeAmbiguous)
            }

            Text("Entropy: \(Int(generator.strengthBits(for: recipe).rounded())) bits")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("generator.entropy")

            HStack {
                Button("Regenerate", action: regenerate)
                    .accessibilityIdentifier("generator.regenerate")
                    .keyboardShortcut("r", modifiers: .command)

                Spacer()

                Button("Copy") { clipboard.copy(result) }
                    .accessibilityIdentifier("generator.copy")
                    .disabled(result.isEmpty)

                Button("Use") {
                    onUse(result)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("generator.use")
                .disabled(result.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear(perform: regenerate)
        // `Recipe` is `Equatable` (see `PasswordGenerator.swift`) specifically so this can fire on
        // ANY toggle/length change without listing each `@State` var separately — a new recipe
        // means the on-screen password no longer matches what the controls say, so it must be
        // redrawn immediately rather than waiting for the user to notice and hit Regenerate.
        .onChange(of: recipe, regenerate)
    }

    @ViewBuilder
    private var resultField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.isEmpty ? " " : result)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityIdentifier("generator.result")

            if let error {
                Text(errorMessage(for: error))
                    .font(.caption)
                    .foregroundStyle(.red)
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
