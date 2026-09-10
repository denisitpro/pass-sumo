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
    /// The entry's built-in KDBX icon index (issue #89).
    ///
    /// `@State`, not the `let` it was while the picker did not exist: the form now owns it, so an
    /// icon chosen here is part of the same uncommitted draft as the title beside it, and Cancel
    /// discards both together. It is seeded from the entry and — like every other field on this
    /// form — has to be named explicitly in `save()`, which builds a whole new `VaultEntry` and
    /// silently defaults any field it forgets. See `save()`'s own doc comment.
    @State private var iconID: UInt32
    @State private var created: Date

    @State private var isPasswordVisible = false
    @State private var showingGenerator = false
    /// Presentation state for the icon picker, held here beside `showingGenerator` rather than
    /// inside the button that raises it. Both sheets are then attached at this view's own body
    /// level, which is the arrangement already proven to work from inside this `Form` — a `.sheet`
    /// hung off a control nested in a `Section` is a different, less-travelled path, and this file
    /// is not the place to find out where it stops working.
    @State private var showingIconPicker = false
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
        _iconID = State(initialValue: entry.iconID)
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
                    .font(Typography.body)
                    .foregroundStyle(Palette.danger)
                }
            }

            Section {
                TextField("Title", text: $title)
                    .accessibilityIdentifier("edit.title")
                iconField
                TextField("Username", text: $username)
                    .accessibilityIdentifier("edit.username")

                passwordField
                strengthMeter

                Button("Generate…") { showingGenerator = true }
                    .accessibilityIdentifier("edit.generate")

                TextField("URL", text: $url)
                    .accessibilityIdentifier("edit.url")

                // Until this existed an entry could never change folder (issue #88): `groupID` was
                // seeded from the entry, passed back to `save()` unchanged, and nothing between the
                // two ever wrote to it.
                Picker("Group", selection: $groupID) {
                    // `VaultEntry.groupID`'s own "nil == the vault's top level", spelled for a user
                    // rather than left as an absent row — without it there is no way back OUT of a
                    // folder once an entry is in one.
                    Text("No Group").tag(UUID?.none)
                    ForEach(groupOptions) { option in
                        Text(option.path).tag(UUID?.some(option.group.id))
                    }
                }
                .accessibilityIdentifier("edit.group")
            }

            Section("Notes") {
                TextEditor(text: $notes)
                    .frame(minHeight: 80)
                    .accessibilityIdentifier("edit.notes")
            }

            Section("One-Time Password") {
                TextField("otpauth:// URL or base32 secret", text: $otpAuthURLText)
                    .font(Typography.monoBody)
                    .accessibilityIdentifier("edit.totp")
            }

            Section("Custom Fields") {
                ForEach($customFields) { $field in
                    HStack(spacing: Spacing.s4) {
                        TextField("Name", text: $field.name)
                        TextField("Value", text: $field.value)
                        Button(role: .destructive) {
                            customFields.removeAll { $0.id == field.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.tokenDestructiveGlyph)
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
        .sheet(isPresented: $showingIconPicker) {
            // Writes into this form's draft, not into the store: an icon picked here is undone by
            // Cancel along with everything else typed on the form, and reaches the vault only
            // through `save()`. A folder's picker commits immediately instead, because a folder has
            // no form and no Save — see `IconPickerSheet`.
            IconPickerSheet(title: "Entry Icon", selectedIconID: iconID) { iconID = $0 }
        }
    }

    /// The icon row, directly under Title because it is the other half of what identifies the entry
    /// in the list — the row draws the two together.
    ///
    /// A button that opens the grid rather than the grid inline: this form is already long, and
    /// seven rows of glyphs wedged in among the identity fields would push everything else down for
    /// a setting most edits never touch. The button's own label is the icon currently in effect, so
    /// the form still answers "which one is it?" without opening anything.
    private var iconField: some View {
        LabeledContent("Icon") {
            Button {
                showingIconPicker = true
            } label: {
                HStack(spacing: Spacing.s4) {
                    Image(
                        systemName: StandardIconCatalog.symbolName(
                            for: iconID,
                            fallingBackTo: VaultEntry.defaultIconID
                        )
                    )
                    .font(Typography.body)
                    .frame(width: Metrics.rowIconSlot)
                    Text("Change…")
                }
            }
            .buttonStyle(.tokenSecondary)
            .accessibilityIdentifier("edit.icon")
        }
    }

    /// The folders this entry can be filed in, in the sidebar's own order and each labelled with
    /// its full path — `GroupTreeBuilder.paths(from:)` does both, so this picker and the sidebar
    /// can never disagree about the shape of the tree.
    ///
    /// **The recycle bin and its contents ARE listed here**, unlike in the sidebar's "Move to"
    /// menu, which filters them out. That menu relocates a folder the user chose to move; this
    /// picker also has to be able to show where the entry already is, and an entry sitting in the
    /// bin whose own group was missing from the list would render as a picker with nothing
    /// selected — and no way to read, let alone change, where it is.
    ///
    /// Read from the store on each body pass rather than snapshotted at init. The sheet is modal,
    /// so the only thing that can reshape the tree underneath it is a lock — and a lock already
    /// disables Save and raises the banner, so whatever the picker does from that point on cannot
    /// reach the vault.
    private var groupOptions: [GroupPathItem] {
        guard case .unlocked(let vault) = store.state else { return [] }
        return GroupTreeBuilder.paths(from: vault.groups)
    }

    /// Add / remove / export attachments. Preview still lives only in `EntryDetailView` — issue
    /// #52 separated "why no export" from "why no preview": a save-panel write is a user-initiated
    /// egress the same way it is in the detail view, but rendering the payload on screen would
    /// still put a second copy of secret bytes where nobody asked to look at it, so that part of
    /// the original reasoning stands and preview stays detail-view-only.
    private var attachmentsSection: some View {
        Section("Attachments") {
            ForEach($attachments) { $draft in
                HStack(spacing: Spacing.s4) {
                    Image(systemName: "paperclip")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                    Text(draft.attachment.name)
                        .font(Typography.body)
                        .foregroundStyle(Palette.text)
                    Spacer(minLength: 0)
                    Text(Self.byteFormatter.string(fromByteCount: Int64(draft.attachment.byteCount)))
                        .font(Typography.monoCaption2)
                        .foregroundStyle(Palette.textTertiary)
                    // Export before remove: the destructive control must not be the first thing
                    // under the cursor for a row whose other action is harmless.
                    Button {
                        exportAttachment(draft)
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .buttonStyle(.tokenGlyph)
                    .help("Save this attachment to a file")
                    .accessibilityLabel("Save attachment")
                    .accessibilityIdentifier("edit.saveAttachment.\(draft.attachment.name)")

                    Button(role: .destructive) {
                        attachments.removeAll { $0.id == draft.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.tokenDestructiveGlyph)
                    .accessibilityLabel("Remove attachment")
                    .accessibilityIdentifier("edit.removeAttachment.\(draft.attachment.name)")
                }
            }

            Button("Add File...") { addAttachments() }
                .accessibilityIdentifier("edit.addAttachment")

            if let attachmentError {
                Label(attachmentError, systemImage: "exclamationmark.triangle.fill")
                    .font(Typography.body)
                    .foregroundStyle(Palette.danger)
                    .accessibilityIdentifier("edit.attachmentError")
            }
        }
    }

    /// Picks one or more files and takes them in as attachments.
    ///
    /// **Sizes are checked before anything is read, and the WHOLE selection is sized before the
    /// first read.** Asking the filesystem for a size first means a 4 GB file picked by accident is
    /// refused with a sentence instead of being pulled into memory in full and only then rejected —
    /// the hang the limit exists to prevent. Sizing the whole selection first is the same argument
    /// one level up: this panel allows multiple selection, so a per-file cap on its own lets one ⌘A
    /// over a photo folder put an unbounded total into the vault, every file individually legal.
    /// `VaultAttachment.screenBatch` holds both rules, and its doc comment the reasoning.
    ///
    /// What is left here is only what needs the filesystem: asking for each declared size, and
    /// reading the files that survived the screen.
    private func addAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }

        attachmentError = nil
        let picked = panel.urls
        // The names here are the files as picked, not the de-duplicated ones: these messages are
        // about files on disk, and nothing has been taken in yet for them to collide with.
        let screened = VaultAttachment.screenBatch(
            declaredSizes: picked.map { url in
                (
                    name: url.lastPathComponent,
                    byteCount: try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                )
            }
        )
        var problems = screened.problems.map(Self.message(for:))

        for index in screened.accepted {
            let url = picked[index]
            let name = uniqueAttachmentName(for: url.lastPathComponent)
            do {
                guard let bytes = try? Data(contentsOf: url) else {
                    throw VaultAttachmentError.unreadable(name: name)
                }
                // Re-checked against the bytes actually read: `fileSizeKey` is a snapshot of a file
                // that can change between the two calls, and the limit has to hold on what we are
                // really about to put in the vault.
                let made = try VaultAttachment.make(name: name, bytes: bytes)
                attachments.append(AttachmentDraft(attachment: made.attachment, addedBlob: made.blob))
            } catch let error as VaultAttachmentError {
                problems.append(Self.message(for: error))
            } catch {
                problems.append("\(name) could not be attached.")
            }
        }

        attachmentError = problems.isEmpty ? nil : problems.joined(separator: "\n")
    }

    /// Writes one attachment's bytes through `AttachmentExporter` — the same `NSSavePanel` path
    /// `EntryDetailView` uses, reused rather than duplicated (issue #52). Resolved on demand,
    /// exactly like the detail view's own export button, rather than pre-resolved into cached row
    /// state: this sheet has no `rebuildAttachmentRows()`-style machinery, and adding one purely to
    /// mirror the detail view would be more code than a rare click justifies.
    private func exportAttachment(_ draft: AttachmentDraft) {
        guard let payload = payload(for: draft) else {
            attachmentError = "\(draft.attachment.name) could not be exported."
            return
        }
        attachmentError = AttachmentExporter.export(payload, suggestedName: draft.attachment.name)
    }

    /// An attachment's bytes, from wherever they currently live. A file added THIS session carries
    /// its own bytes in `addedBlob` (see that property's doc comment — it is not pooled into the
    /// vault until `save()` calls `upsert`); anything already in the vault resolves through the
    /// store's own state, the same `Vault.bytes(for:)` indirection `VaultBrowserView` hands
    /// `EntryDetailView` as `resolveAttachment`.
    private func payload(for draft: AttachmentDraft) -> Data? {
        if let addedBlob = draft.addedBlob { return addedBlob.bytes }
        guard case .unlocked(let vault) = store.state else { return nil }
        return vault.bytes(for: draft.attachment)
    }

    /// Gives a second `Screenshot.png` a numeric suffix rather than letting it silently replace (or
    /// collide with) the first. The format does not enforce the uniqueness — see
    /// `VaultAttachment.name` — but `VaultAttachment.id` is the name, so this app does, on both
    /// ways in: here for a file the user picks, and in `KDBXAttachments.project` for one another
    /// client wrote.
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
        case let .batchTooLarge(totalByteCount, limit):
            let actual = byteFormatter.string(fromByteCount: Int64(totalByteCount))
            let cap = byteFormatter.string(fromByteCount: Int64(limit))
            return "That selection is \(actual) in total. One batch of attachments is limited to "
                + "\(cap), so nothing was attached — add them a few files at a time."
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
        HStack(spacing: Spacing.s4) {
            Group {
                if isPasswordVisible {
                    TextField("Password", text: $password)
                } else {
                    SecureField("Password", text: $password)
                }
            }
            .font(Typography.monoBody)
            .accessibilityIdentifier("edit.password")

            Button {
                isPasswordVisible.toggle()
            } label: {
                Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
            }
            .buttonStyle(.tokenGlyph)
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
        return VStack(alignment: .leading, spacing: Spacing.s1) {
            ProgressView(value: min(bits, 100), total: 100)
                .tint(strengthColor(for: bits))
            Text(password.isEmpty ? "No password" : "~\(Int(bits)) bits (rough guide)")
                .font(Typography.monoCaption2)
                .foregroundStyle(Palette.textTertiary)
        }
    }

    /// Thresholds unchanged; only the colours moved onto the token layer's strength ramp.
    private func strengthColor(for bits: Double) -> Color {
        switch bits {
        case ..<40: return Palette.strengthWeak
        case ..<70: return Palette.strengthFair
        default: return Palette.strengthStrong
        }
    }

    /// Not `private`, so `EntryEditSaveTests` can drive the real thing.
    ///
    /// This method's failure mode is silence: it builds a whole new `VaultEntry` from the fields
    /// the form owns, so a modelled field it does not name is written back as that field's
    /// default — no compiler error, no warning, just the user's data quietly replaced on their
    /// next edit. `iconID` did exactly that between its landing in the model and this line
    /// (issue #89). The one assertion that catches it has to go through `save()` itself; the
    /// alternatives (checking the captured property, or an XCUITest) either miss the bug or are
    /// the focus-stealing suite this project does not run on every change.
    func save() {
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
            // Named, not defaulted — see the `iconID` property. A new entry's starts at the
            // default, because that is what the blank entry this form was opened on carries.
            iconID: iconID,
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
