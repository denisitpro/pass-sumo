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
    /// Mirrors `VaultFieldValue.isProtected`, and is why this sheet has a per-field lock button:
    /// without one, every custom field pass-sumo ever created would render concealed forever,
    /// because the codec used to force new custom fields into a protected class regardless of
    /// what the field actually holds.
    var isProtected: Bool
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
    /// The entry this form was opened on. `save()` copies this and assigns only the fields the
    /// form owns (issue #95), so a modelled field the form does not name cannot be silently
    /// reset to its default — which is what rebuilding via `VaultEntry(...)` did to `iconID`
    /// the week it landed (#89).
    let original: VaultEntry
    let isNew: Bool
    let store: VaultStore
    let clipboard: ClipboardService
    let generator: PasswordGenerator
    var onSave: (VaultEntry) -> Void
    var onDismiss: () -> Void
    /// Optional so existing call sites still compile (the browser is another lane). The only
    /// persist path for a recipe tweak made here — this view never writes `UserDefaults` itself;
    /// `AppSettings.generatorRecipe` already does on `didSet`.
    var onRecipeChanged: ((PasswordGenerator.Recipe) -> Void)? = nil

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
    /// discards both together. Seeded from `original` and written back in `save()`; everything
    /// else on the entry rides through the copy untouched (issue #95).
    @State private var iconID: UInt32
    /// Seeded from the caller's saved default (`AppSettings.generatorRecipe`) and then owned here
    /// so generate-now and the settings sheet share one live recipe (issue #129). Tweaks inside
    /// the sheet write back through `onRecipeChanged` — they used to be one-off (issue #106).
    @State private var generatorRecipe: PasswordGenerator.Recipe
    /// Set when generate-now's recipe cannot be satisfied, shown under the password row the same
    /// way `GeneratorSheet` reports an impossible recipe. Cleared on the next successful generate.
    @State private var generatorError: PasswordGenerator.GeneratorError?

    @State private var isPasswordVisible = false
    @State private var showingGenerator = false
    /// Presentation state for the icon picker, held here beside `showingGenerator` rather than
    /// inside the button that raises it. Both sheets are then attached at this view's own body
    /// level, which is the arrangement already proven to work from inside a nested control — a
    /// `.sheet` hung off a button in a `ScrollView` is a different, less-travelled path.
    @State private var showingIconPicker = false
    @State private var wasLockedWhileEditing = false
    @FocusState private var isPasswordFocused: Bool

    init(
        entry: VaultEntry,
        isNew: Bool,
        store: VaultStore,
        clipboard: ClipboardService,
        generator: PasswordGenerator,
        generatorRecipe: PasswordGenerator.Recipe,
        onSave: @escaping (VaultEntry) -> Void,
        onDismiss: @escaping () -> Void,
        onRecipeChanged: ((PasswordGenerator.Recipe) -> Void)? = nil
    ) {
        self.original = entry
        self.isNew = isNew
        self.store = store
        self.clipboard = clipboard
        self.generator = generator
        self.onSave = onSave
        self.onDismiss = onDismiss
        self.onRecipeChanged = onRecipeChanged
        _title = State(initialValue: entry.title)
        _username = State(initialValue: entry.username)
        _password = State(initialValue: entry.password)
        _url = State(initialValue: entry.url)
        _notes = State(initialValue: entry.notes)
        _otpAuthURLText = State(initialValue: entry.otpAuthURL ?? "")
        _customFields = State(initialValue: entry.customFields
            .sorted { $0.key < $1.key }
            .map {
                CustomFieldDraft(name: $0.key, value: $0.value.value, isProtected: $0.value.isProtected)
            })
        _attachments = State(initialValue: entry.attachments.map { AttachmentDraft(attachment: $0) })
        _groupID = State(initialValue: entry.groupID)
        _iconID = State(initialValue: entry.iconID)
        _generatorRecipe = State(initialValue: generatorRecipe)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.s5) {
                Text(isNew ? "New Entry" : "Edit Entry")
                    .font(Typography.headline)
                    .foregroundStyle(Palette.text)

                if wasLockedWhileEditing {
                    Label(
                        "The vault locked while you were editing. This entry was NOT saved.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(Typography.body)
                    .foregroundStyle(Palette.danger)
                }
            }
            .padding(.horizontal, Spacing.s7)
            .padding(.top, Spacing.s7)
            .padding(.bottom, Spacing.s5)

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.s6) {
                    headerRow
                    labeled("Username") {
                        EditLineField(placeholder: "Username", text: $username, identifier: "edit.username")
                    }
                    passwordBlock
                    totpBlock
                    labeled("URL") {
                        EditLineField(placeholder: "URL", text: $url, identifier: "edit.url")
                    }
                    if !isNew {
                        labeled("Group") { groupPicker }
                    }
                    notesBlock
                    customFieldsBlock
                    attachmentsBlock
                }
                .padding(.horizontal, Spacing.s7)
                .padding(.bottom, Spacing.s6)
            }

            Divider().overlay(Palette.border)

            footer
                .padding(.horizontal, Spacing.s7)
                .padding(.vertical, Spacing.s5)
        }
        .frame(minWidth: 420, minHeight: 480)
        .background(Palette.surface)
        .onChange(of: store.state) { _, newState in
            guard case .unlocked = newState else {
                wasLockedWhileEditing = true
                return
            }
        }
        .sheet(isPresented: $showingGenerator) {
            makeGeneratorSheet()
        }
        .sheet(isPresented: $showingIconPicker) {
            // Writes into this form's draft, not into the store: an icon picked here is undone by
            // Cancel along with everything else typed on the form, and reaches the vault only
            // through `save()`. A folder's picker commits immediately instead, because a folder has
            // no form and no Save — see `IconPickerSheet`.
            IconPickerSheet(title: "Entry Icon", selectedIconID: iconID) { iconID = $0 }
        }
    }

    /// Icon + title on one row. The icon IS the control that opens the picker — not a trailing
    /// "Change…" next to a separate Icon label, which is what made this look like a grouped Form
    /// row (issue #129). No favourite star: there is no favourite model.
    private var headerRow: some View {
        HStack(alignment: .center, spacing: Spacing.s4) {
            Button {
                showingIconPicker = true
            } label: {
                Image(
                    systemName: StandardIconCatalog.symbolName(
                        for: iconID,
                        fallingBackTo: VaultEntry.defaultIconID
                    )
                )
            }
            .buttonStyle(.tokenSecondary)
            .help("Change icon")
            .accessibilityLabel("Change icon")
            .accessibilityIdentifier("edit.icon")

            EditLineField(placeholder: "Title", text: $title, identifier: "edit.title")
        }
    }

    private var passwordBlock: some View {
        labeled("Password") {
            VStack(alignment: .leading, spacing: Spacing.s2) {
                HStack(spacing: Spacing.s3) {
                    passwordField
                    revealButton
                    generateNowButton
                    generatorSettingsButton
                }
                strengthMeter
                if let generatorError {
                    Text(errorMessage(for: generatorError))
                        .font(Typography.caption)
                        .foregroundStyle(Palette.danger)
                        .accessibilityIdentifier("edit.generatorError")
                }
            }
        }
    }

    /// Trailing of the password row, not a labelled "Generate…" that opened the sheet. Identifier
    /// stays `edit.generate` so existing e2e that click it still have a target — they now fill
    /// the field instead of presenting `GeneratorSheet`.
    private var generateNowButton: some View {
        Button {
            _ = generatePasswordNow()
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.tokenGlyph)
        .help("Generate password")
        .accessibilityLabel("Generate password")
        .accessibilityIdentifier("edit.generate")
    }

    private var generatorSettingsButton: some View {
        Button {
            showingGenerator = true
        } label: {
            Image(systemName: "gearshape")
        }
        .buttonStyle(.tokenGlyph)
        .help("Generator settings")
        .accessibilityLabel("Generator settings")
        .accessibilityIdentifier("edit.generatorSettings")
    }

    private var footer: some View {
        HStack {
            Button("Cancel", action: onDismiss)
                .buttonStyle(.tokenQuiet)
                .keyboardShortcut(.escape)
                .accessibilityIdentifier("edit.cancel")

            Spacer()

            Button("Save", action: save)
                .buttonStyle(.tokenPrimary)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(wasLockedWhileEditing)
                .accessibilityIdentifier("edit.save")
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

    private var groupPicker: some View {
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
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("edit.group")
    }

    private var notesBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.s2) {
            sectionTitle("Notes")
            TextEditor(text: $notes)
                .font(Typography.body)
                .foregroundStyle(Palette.text)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 80)
                .padding(Spacing.s4)
                .sunkenWell()
                .accessibilityIdentifier("edit.notes")
        }
    }

    private var totpBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.s2) {
            sectionTitle("One-Time Password")
            // Placeholder is deliberately human. The field still accepts an otpauth URI or a
            // bare base32 secret (`TOTPGenerator`); storage stays KeePassXC's `otp` field. The
            // jargon belongs in `docs/feature.md`, not in the control the user types into.
            EditLineField(
                placeholder: "Authenticator secret",
                text: $otpAuthURLText,
                identifier: "edit.totp",
                monospaced: true
            )
        }
    }

    private var customFieldsBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.s3) {
            sectionTitle("Custom Fields")
            ForEach($customFields) { $field in
                HStack(spacing: Spacing.s4) {
                    TextField("Name", text: $field.name)
                    TextField("Value", text: $field.value)
                    // A quiet glyph, not a `Toggle` — same reasoning as `FieldRow`'s eye: a
                    // switch or a filled button-style toggle in every row would read as
                    // heavier than Delete beside it. The label states the ACTION, so
                    // VoiceOver announces what pressing it does rather than a bare state.
                    Button {
                        field.isProtected.toggle()
                    } label: {
                        Image(systemName: field.isProtected ? "lock.fill" : "lock.open")
                    }
                    .buttonStyle(.tokenGlyph)
                    .help(field.isProtected
                        ? "Stored as a secret — hidden until revealed. Click to store in the clear."
                        : "Stored in the clear. Click to store as a secret.")
                    .accessibilityLabel(field.isProtected
                        ? "Store in the clear"
                        : "Store as a secret")
                    Button(role: .destructive) {
                        customFields.removeAll { $0.id == field.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.tokenDestructiveGlyph)
                }
            }
            Button("Add Field") {
                // Protected by default, which is where the codec's old hardcoded
                // `defaultProtected: true` moved to: a password manager's custom attributes
                // hold recovery codes and security answers far more often than trivia, so the
                // safe default is to conceal. Unlike before, the user can now turn it off.
                customFields.append(CustomFieldDraft(name: "", value: "", isProtected: true))
            }
            .buttonStyle(.tokenSecondary)
            .accessibilityIdentifier("edit.addField")
        }
    }

    /// Add / remove / export attachments. Preview still lives only in `EntryDetailView` — issue
    /// #52 separated "why no export" from "why no preview": a save-panel write is a user-initiated
    /// egress the same way it is in the detail view, but rendering the payload on screen would
    /// still put a second copy of secret bytes where nobody asked to look at it, so that part of
    /// the original reasoning stands and preview stays detail-view-only.
    private var attachmentsBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.s3) {
            sectionTitle("Attachments")
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
                .buttonStyle(.tokenSecondary)
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
        Group {
            if isPasswordVisible {
                TextField("Password", text: $password)
            } else {
                SecureField("Password", text: $password)
            }
        }
        .textFieldStyle(.plain)
        .font(Typography.monoField)
        .foregroundStyle(Palette.text)
        .padding(.horizontal, Spacing.s4)
        .frame(height: Metrics.fieldHeight)
        .fieldChrome(isFocused: isPasswordFocused)
        .focused($isPasswordFocused)
        .accessibilityIdentifier("edit.password")
    }

    private var revealButton: some View {
        Button {
            isPasswordVisible.toggle()
        } label: {
            Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
        }
        .buttonStyle(.tokenGlyph)
        .help(isPasswordVisible ? "Hide password" : "Reveal password")
        // Mirrors `detail.revealPassword` in `EntryDetailView`/`FieldRow` — that one had an id,
        // this one didn't, which was a real gap (issue #6's e2e run): there was no way to read
        // this field's real value from a test without it, since a concealed `SecureField`'s
        // accessibility value is a run of bullets, not the password.
        .accessibilityIdentifier("edit.revealPassword")
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
    /// Starts from `original` and assigns only the fields the form owns (issue #95). The previous
    /// shape — `VaultEntry(...)` with the fields this method happened to name — silently wrote
    /// every unmentioned modelled field back as its default; `iconID` was the first casualty
    /// (#89). Copy-then-assign makes that class of bug impossible for fields nobody has added
    /// yet. `VaultStore.upsert` still owns `modified` / `historyAdditions` / `passwordLastChanged`
    /// on the way into the store; what this returns to `onSave` is the copy after the form's
    /// assignments, so a test can see exactly what the form produced.
    func save() {
        guard !wasLockedWhileEditing else { return }

        var fields: [String: VaultFieldValue] = [:]
        // Last-write-wins on a duplicate name rather than crashing: two drafts can legitimately
        // share a name for a moment while the user is mid-rename, and `Dictionary(uniqueKeysWithValues:)`
        // would trap on that instead of just resolving to one value.
        for field in customFields where !field.name.isEmpty {
            fields[field.name] = VaultFieldValue(value: field.value, isProtected: field.isProtected)
        }

        var entry = original
        entry.groupID = groupID
        entry.title = title
        entry.username = username
        entry.password = password
        entry.url = url
        entry.notes = notes
        entry.otpAuthURL = otpAuthURLText.isEmpty ? nil : otpAuthURLText
        entry.customFields = fields
        entry.iconID = iconID
        entry.attachments = attachments.map(\.attachment)
        // Only the payloads picked in this session travel with the entry: everything else is
        // already in the vault's pool, and `upsert` ignores a blob it already holds anyway.
        store.upsert(entry, addingBlobs: attachments.compactMap(\.addedBlob))
        onSave(entry)
        onDismiss()
    }

    /// Fills `password` from the current recipe without opening the sheet (issue #129).
    ///
    /// Returns the generated value so a unit test can assert on length without rendering; `nil`
    /// means the recipe was impossible and `generatorError` holds the reason — same sentences
    /// `GeneratorSheet` already shows, never a crash and never a silent no-op.
    @discardableResult
    func generatePasswordNow() -> String? {
        do {
            let generated = try generator.generate(generatorRecipe)
            password = generated
            generatorError = nil
            return generated
        } catch let failure as PasswordGenerator.GeneratorError {
            generatorError = failure
            return nil
        } catch {
            // `generate(_:)`'s signature only ever throws `GeneratorError` — this branch exists
            // purely because `catch` must be exhaustive, not because another error type can
            // actually reach it.
            return nil
        }
    }

    /// Factored out of `body`'s `.sheet(isPresented: $showingGenerator)` closure purely so the
    /// wiring is assertable without rendering (issue #106) — a test constructs an `EntryEditView`
    /// with a known `generatorRecipe`, calls this directly, and checks the result's
    /// `openingRecipe`. If this ever goes back to hardcoding `GeneratorSheet(generator:, clipboard:)`
    /// with no `recipe:`, that assertion fails instead of the bug shipping invisibly again.
    ///
    /// `onUse` still fills the password field (the sheet's "Use"); `onRecipeChanged` both updates
    /// the live recipe generate-now reads and forwards to the caller so Settings persists.
    func makeGeneratorSheet() -> GeneratorSheet {
        GeneratorSheet(
            generator: generator,
            recipe: generatorRecipe,
            clipboard: clipboard,
            onUse: { password = $0 },
            onRecipeChanged: { newRecipe in
                generatorRecipe = newRecipe
                onRecipeChanged?(newRecipe)
            }
        )
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

    @ViewBuilder
    private func labeled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s2) {
            Text(title)
                .font(Typography.captionMedium)
                .foregroundStyle(Palette.textSecondary)
            content()
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(Typography.bodySemibold)
            .foregroundStyle(Palette.text)
    }
}

/// A single-line field with the token chrome. Local to this file because the edit sheet is the
/// one screen that left `Form(.grouped)` (issue #129); Unlock already has `MasterPasswordField`.
private struct EditLineField: View {
    let placeholder: String
    @Binding var text: String
    var identifier: String
    var monospaced = false
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(monospaced ? Typography.monoField : Typography.field)
            .foregroundStyle(Palette.text)
            .padding(.horizontal, Spacing.s4)
            .frame(height: Metrics.fieldHeight)
            .fieldChrome(isFocused: isFocused)
            .focused($isFocused)
            .accessibilityIdentifier(identifier)
    }
}

#Preview {
    EntryEditView(
        entry: Vault.sample.entries[0],
        isNew: false,
        store: VaultStore(codec: InMemoryVaultCodec(), fileAccess: InMemoryVaultFileAccess()),
        clipboard: ClipboardService(),
        generator: PasswordGenerator(),
        generatorRecipe: PasswordGenerator.Recipe(),
        onSave: { _ in },
        onDismiss: {}
    )
}
