import AppKit
import SwiftUI

/// One attachment being edited.
///
/// Mirrors `CustomFieldDraft` below and exists for the same `ForEach` identity reason, plus one of
/// its own: `addedBlob` is the payload of a file picked in THIS session, which has to travel to
/// `VaultStore.upsert` alongside the entry because `VaultAttachment` carries only a reference (see
/// its doc comment). It is `nil` for an attachment that was already in the vault — that payload is
/// already pooled, and re-carrying it here would put a second plaintext copy of it in memory for
/// as long as the sheet stays open.
private struct AttachmentDraft: Identifiable {
    let id = UUID()
    var attachment: VaultAttachment
    var addedBlob: VaultBlob?
}

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
    @State private var attachments: [AttachmentDraft]
    /// Set when a picked file was refused (too large, unreadable) and shown inline. A string
    /// rather than the `VaultAttachmentError` itself: the view needs the sentence, and keeping the
    /// mapping at the point of failure is what lets the message name the specific file.
    @State private var attachmentError: String?
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
        _attachments = State(initialValue: entry.attachments.map { AttachmentDraft(attachment: $0) })
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

            attachmentsSection
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

    /// Add / remove attachments. Viewing, previewing and exporting them lives in
    /// `EntryDetailView` — this sheet is only the mutation surface, which is why there is no
    /// preview here: rendering the payload would put a second copy of secret bytes on screen in a
    /// context where nobody asked to look at it.
    private var attachmentsSection: some View {
        Section("Attachments") {
            ForEach($attachments) { $draft in
                HStack(spacing: 8) {
                    Image(systemName: "paperclip")
                        .foregroundStyle(.secondary)
                    Text(draft.attachment.name)
                    Spacer()
                    Text(Self.byteFormatter.string(fromByteCount: Int64(draft.attachment.byteCount)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button(role: .destructive) {
                        attachments.removeAll { $0.id == draft.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove attachment")
                    .accessibilityIdentifier("edit.removeAttachment.\(draft.attachment.name)")
                }
            }

            Button("Add File...") { addAttachments() }
                .accessibilityIdentifier("edit.addAttachment")

            if let attachmentError {
                Label(attachmentError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("edit.attachmentError")
            }
        }
    }

    /// Picks one or more files and takes them in as attachments.
    ///
    /// **The size check happens before the read, not after.** Asking the filesystem for the size
    /// first means a 4 GB file picked by accident is refused with a sentence, instead of being
    /// pulled into memory in full and only then rejected — which is the hang the limit exists to
    /// prevent in the first place. See `VaultAttachment.maximumByteCount` for the number and the
    /// reasoning behind it.
    private func addAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }

        attachmentError = nil
        for url in panel.urls {
            let name = uniqueAttachmentName(for: url.lastPathComponent)
            do {
                let declaredSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard declaredSize <= VaultAttachment.maximumByteCount else {
                    throw VaultAttachmentError.tooLarge(
                        name: name,
                        byteCount: declaredSize,
                        limit: VaultAttachment.maximumByteCount
                    )
                }
                guard let bytes = try? Data(contentsOf: url) else {
                    throw VaultAttachmentError.unreadable(name: name)
                }
                // Re-checked against the bytes actually read: `fileSizeKey` is a snapshot of a file
                // that can change between the two calls, and the limit has to hold on what we are
                // really about to put in the vault.
                let made = try VaultAttachment.make(name: name, bytes: bytes)
                attachments.append(AttachmentDraft(attachment: made.attachment, addedBlob: made.blob))
            } catch let error as VaultAttachmentError {
                attachmentError = Self.message(for: error)
            } catch {
                attachmentError = "\(name) could not be attached."
            }
        }
    }

    /// KDBX requires an entry's attachment names to be unique, so a second `Screenshot.png` gets a
    /// numeric suffix rather than silently replacing (or colliding with) the first.
    private func uniqueAttachmentName(for name: String) -> String {
        let taken = Set(attachments.map(\.attachment.name))
        guard taken.contains(name) else { return name }

        let url = URL(fileURLWithPath: name)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for suffix in 2 ... 999 {
            let candidate = ext.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(ext)"
            if !taken.contains(candidate) { return candidate }
        }
        return "\(stem) \(UUID().uuidString)"
    }

    private static func message(for error: VaultAttachmentError) -> String {
        switch error {
        case let .tooLarge(name, byteCount, limit):
            let actual = byteFormatter.string(fromByteCount: Int64(byteCount))
            let cap = byteFormatter.string(fromByteCount: Int64(limit))
            return "\(name) is \(actual). Attachments are limited to \(cap) — the whole database "
                + "is held in memory while unlocked and rewritten on every save."
        case let .unreadable(name):
            return "\(name) could not be read."
        }
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

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
            attachments: attachments.map(\.attachment),
            created: created,
            // `VaultStore.upsert` stamps its own `modified` to `Date()` regardless of what's
            // passed here — this value only needs to be a valid placeholder, never the real one.
            modified: created
        )
        // Only the payloads picked in this session travel with the entry: everything else is
        // already in the vault's pool, and `upsert` ignores a blob it already holds anyway.
        store.upsert(entry, addingBlobs: attachments.compactMap(\.addedBlob))
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
