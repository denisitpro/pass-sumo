import SwiftUI

/// One name/value pair being edited. A local, `Identifiable` draft type (NOT `VaultEntry`'s own
/// `[String: String]`) purely so `ForEach` has a stable identity per row while the user is
/// mid-rename of a field's NAME — keying by the dictionary key itself would make SwiftUI lose the
/// row's identity (and any in-progress edit inside it) the instant a keystroke changes that key.
private struct CustomFieldDraft: Identifiable {
    let id = UUID()
    var name: String
    var value: String
}

/// Edit form for a `VaultEntry` — also used for a brand-new one, distinguished only by `isNew`
/// (the title bar and Save's semantics differ slightly; the fields are identical either way).
///
/// **Unsaved edits must not be silently lost if auto-lock fires while this sheet is open.**
/// `VaultStore.upsert` no-ops against a locked store (see its own guard clause) — so without the
/// `.onChange(of: store.state)` handler below, a user who kept typing through an idle timeout
/// would hit Save, watch the sheet close normally, and have no idea the entry was never actually
/// written. What's implemented: the sheet detects the store leaving `.unlocked` and disables Save
/// with a visible banner rather than pretending to succeed. What's deferred to the design-system
/// pass: this reuses the same plain SwiftUI alert-ish banner as everywhere else in this file
/// (no dedicated "recoverable draft" affordance) — recovering the user's typed text into a NEW
/// attempt after the next unlock would need a place to stash it (`UserDefaults` is out per the
/// architecture contract's "never write a plaintext secret" rule, so it would need its own
/// encrypted holding area), which is a real feature, not a UI tweak.
struct EntryEditView: View {
    let originalID: UUID
    let isNew: Bool
    let store: VaultStore
    let clipboard: ClipboardService
    let generator: PasswordGenerator
    var onSave: (VaultEntry) -> Void
    var onDismiss: () -> Void

    @State private var title: String
    @State private var username: String
    @State private var password: String
    @State private var url: String
    @State private var notes: String
    @State private var otpAuthURLText: String
    @State private var customFields: [CustomFieldDraft]
    @State private var groupID: UUID?
    @State private var created: Date

    @State private var isPasswordVisible = false
    @State private var showingGenerator = false
    @State private var wasLockedWhileEditing = false

    init(
        entry: VaultEntry,
        isNew: Bool,
        store: VaultStore,
        clipboard: ClipboardService,
        generator: PasswordGenerator,
        onSave: @escaping (VaultEntry) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.originalID = entry.id
        self.isNew = isNew
        self.store = store
        self.clipboard = clipboard
        self.generator = generator
        self.onSave = onSave
        self.onDismiss = onDismiss
        _title = State(initialValue: entry.title)
        _username = State(initialValue: entry.username)
        _password = State(initialValue: entry.password)
        _url = State(initialValue: entry.url)
        _notes = State(initialValue: entry.notes)
        _otpAuthURLText = State(initialValue: entry.otpAuthURL ?? "")
        _customFields = State(initialValue: entry.customFields
            .sorted { $0.key < $1.key }
            .map { CustomFieldDraft(name: $0.key, value: $0.value) })
        _groupID = State(initialValue: entry.groupID)
        _created = State(initialValue: entry.created)
    }

    var body: some View {
        Form {
            if wasLockedWhileEditing {
                Section {
                    Label(
                        "The vault locked while you were editing. This entry was NOT saved.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.red)
                }
            }

            Section {
                TextField("Title", text: $title)
                    .accessibilityIdentifier("edit.title")
                TextField("Username", text: $username)
                    .accessibilityIdentifier("edit.username")

                passwordField
                strengthMeter

                Button("Generate…") { showingGenerator = true }
                    .accessibilityIdentifier("edit.generate")

                TextField("URL", text: $url)
                    .accessibilityIdentifier("edit.url")
            }

            Section("Notes") {
                TextEditor(text: $notes)
                    .frame(minHeight: 80)
                    .accessibilityIdentifier("edit.notes")
            }

            Section("One-Time Password") {
                TextField("otpauth:// URL or base32 secret", text: $otpAuthURLText)
                    .font(.system(.body, design: .monospaced))
                    .accessibilityIdentifier("edit.totp")
            }

            Section("Custom Fields") {
                ForEach($customFields) { $field in
                    HStack {
                        TextField("Name", text: $field.name)
                        TextField("Value", text: $field.value)
                        Button(role: .destructive) {
                            customFields.removeAll { $0.id == field.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button("Add Field") {
                    customFields.append(CustomFieldDraft(name: "", value: ""))
                }
                .accessibilityIdentifier("edit.addField")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 480)
        .navigationTitle(isNew ? "New Entry" : "Edit Entry")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onDismiss)
                    .accessibilityIdentifier("edit.cancel")
                    .keyboardShortcut(.escape)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .accessibilityIdentifier("edit.save")
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(wasLockedWhileEditing)
            }
        }
        .onChange(of: store.state) { _, newState in
            guard case .unlocked = newState else {
                wasLockedWhileEditing = true
                return
            }
        }
        .sheet(isPresented: $showingGenerator) {
            GeneratorSheet(generator: generator, clipboard: clipboard, onUse: { password = $0 })
        }
    }

    @ViewBuilder
    private var passwordField: some View {
        HStack {
            Group {
                if isPasswordVisible {
                    TextField("Password", text: $password)
                } else {
                    SecureField("Password", text: $password)
                }
            }
            .accessibilityIdentifier("edit.password")

            Button {
                isPasswordVisible.toggle()
            } label: {
                Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
            }
            .buttonStyle(.plain)
            .help(isPasswordVisible ? "Hide password" : "Reveal password")
        }
    }

    /// Fed by `PasswordGenerator.strength(of:)` — that method's own doc comment is explicit that
    /// this is a rough, generous UPPER bound (character-class counting, no dictionary, no
    /// leaked-password list), never a zxcvbn-grade estimate. The label below says "rough guide" for
    /// exactly that reason; presenting a bare number with no qualifier would overstate what it
    /// means for a password a user typed by hand rather than one this app generated.
    private var strengthMeter: some View {
        let bits = generator.strength(of: password)
        return VStack(alignment: .leading, spacing: 2) {
            ProgressView(value: min(bits, 100), total: 100)
                .tint(strengthColor(for: bits))
            Text(password.isEmpty ? "No password" : "~\(Int(bits)) bits (rough guide)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func strengthColor(for bits: Double) -> Color {
        switch bits {
        case ..<40: return .red
        case ..<70: return .orange
        default: return .green
        }
    }

    private func save() {
        guard !wasLockedWhileEditing else { return }

        var fields: [String: String] = [:]
        // Last-write-wins on a duplicate name rather than crashing: two drafts can legitimately
        // share a name for a moment while the user is mid-rename, and `Dictionary(uniqueKeysWithValues:)`
        // would trap on that instead of just resolving to one value.
        for field in customFields where !field.name.isEmpty {
            fields[field.name] = field.value
        }

        let entry = VaultEntry(
            id: originalID,
            groupID: groupID,
            title: title,
            username: username,
            password: password,
            url: url,
            notes: notes,
            otpAuthURL: otpAuthURLText.isEmpty ? nil : otpAuthURLText,
            customFields: fields,
            created: created,
            // `VaultStore.upsert` stamps its own `modified` to `Date()` regardless of what's
            // passed here — this value only needs to be a valid placeholder, never the real one.
            modified: created
        )
        store.upsert(entry)
        onSave(entry)
        onDismiss()
    }
}

#Preview {
    EntryEditView(
        entry: Vault.sample.entries[0],
        isNew: false,
        store: VaultStore(codec: InMemoryVaultCodec(), fileAccess: InMemoryVaultFileAccess()),
        clipboard: ClipboardService(),
        generator: PasswordGenerator(),
        onSave: { _ in },
        onDismiss: {}
    )
}
