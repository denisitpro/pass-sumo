import AppKit
import SwiftUI

/// Pure decision behind the password-reveal reset rule, pulled out of the view so
/// `BrowserLogicTests` can verify it without driving real SwiftUI state.
///
/// The product rule (see `EntryDetailView`'s doc comment) is simple on purpose: a reveal never
/// survives a selection change or a lock. This function states that as data — given what was
/// revealed and what changed, should it still read as revealed — rather than as an imperative
/// "set it back to false" scattered across two `onChange` handlers.
enum RevealPolicy {
    static func revealAfterSelectionChange(
        wasRevealed: Bool,
        previousEntryID: UUID?,
        currentEntryID: UUID?,
        isLocked: Bool
    ) -> Bool {
        guard wasRevealed else { return false }
        if isLocked { return false }
        return previousEntryID == currentEntryID
    }

    /// The same rule for the per-field reveals of an entry's protected custom fields, which are
    /// tracked as a set of field names rather than one `Bool`. It delegates rather than restating
    /// the rule: a revealed custom field is a revealed secret, and there is no reason for it to
    /// outlive a lock or a selection change when a revealed password does not.
    static func revealsAfterSelectionChange(
        _ revealed: Set<String>,
        previousEntryID: UUID?,
        currentEntryID: UUID?,
        isLocked: Bool
    ) -> Set<String> {
        revealAfterSelectionChange(
            wasRevealed: !revealed.isEmpty,
            previousEntryID: previousEntryID,
            currentEntryID: currentEntryID,
            isLocked: isLocked
        ) ? revealed : []
    }
}

/// Decides whether an attachment's bytes may be handed to an image decoder for an inline preview.
///
/// **A security-posture decision, not a formatting one.** The payload comes out of a `.kdbx` file
/// that may have been received from someone else, and ImageIO's format parsers are one of the most
/// productive memory-corruption surfaces on the platform. `NSImage(data:)` sniffs the bytes itself
/// and will reach for whatever codec the system has — TIFF, BMP, ICNS, PDF, raw camera formats —
/// so handing it every payload turns "select an entry" into "run an unbounded set of decoders over
/// attacker-chosen bytes". For an app whose positioning is deliberate attack-surface minimisation
/// (no AutoFill, no browser extension, both excluded on exactly this reasoning — see repo
/// CLAUDE.md), that is an expansion nobody signed off on.
///
/// A preview therefore requires all three of:
///
/// 1. an extension on a short allow-list — what the file claims to be;
/// 2. a magic number that AGREES with that extension — what the bytes claim. Both must say the
///    same thing, so neither a renamed payload nor a mislabelled one reaches a decoder that was
///    not vetted for it;
/// 3. a payload no larger than `maximumPreviewByteCount`.
///
/// PNG and JPEG only. They are the formats this feature was designed around (screenshots, and
/// photographed or scanned documents), they are the best-exercised decoders of the set, and each
/// has one unambiguous signature. Anything else simply gets no thumbnail — it is still listed,
/// sized, and exportable, so nothing is lost but the picture. Adding a format here is a deliberate
/// act: an extension, its signature, and a reason.
enum AttachmentPreviewPolicy {
    /// Payload ceiling for a preview: 8 MB.
    ///
    /// Not one of the security checks — a memory one. A decoded bitmap costs width × height × 4
    /// bytes however well the file compressed, so a PNG at the 25 MB per-attachment cap can expand
    /// into hundreds of megabytes of pixels on the main thread to draw a 220×140 thumbnail. 8 MB
    /// covers the screenshots and document scans this is for with room to spare.
    static let maximumPreviewByteCount = 8 * 1024 * 1024

    /// Allowed extension → the byte signature that must be present as well.
    private static let signaturesByExtension: [String: [UInt8]] = [
        "png": [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
        "jpg": [0xFF, 0xD8, 0xFF],
        "jpeg": [0xFF, 0xD8, 0xFF],
    ]

    static func allowsPreview(name: String, bytes: Data) -> Bool {
        guard bytes.count <= maximumPreviewByteCount else { return false }
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        guard let signature = signaturesByExtension[ext] else { return false }
        return bytes.starts(with: signature)
    }
}

/// Writes an attachment's bytes wherever the user points a save panel — the single egress for
/// attachment payloads, shared by `EntryDetailView` and `EntryEditView` (issue #52: the edit sheet
/// used to offer only the destructive remove action, with no way to export while editing).
///
/// **Attachment bytes are secret material** (repo CLAUDE.md): this goes through `NSSavePanel`
/// only, never a temp file, never the pasteboard — matching the same reasoning as
/// `AttachmentPreviewPolicy` just above.
///
/// `runModal` rather than a sheet: the caller is a plain SwiftUI view with no window reference to
/// attach one to, and a modal panel also guarantees the payload does not outlive the interaction
/// inside a captured completion handler.
///
/// A failed write used to be swallowed, which is the worst outcome available here: the user
/// watched a save panel accept a destination and leaves believing their passport scan is on disk
/// when nothing is there. It is not theoretical either — `.atomic` writes a sibling temp file in
/// the destination directory first, which a powerbox-granted URL can plausibly refuse. Surfacing
/// the error is the fix; changing the write strategy on that guess is not. The message carries the
/// filename and the system's own reason, never any payload bytes.
enum AttachmentExporter {
    static func export(_ payload: Data, suggestedName: String) -> String? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try payload.write(to: url, options: [.atomic])
            return nil
        } catch {
            return "\(suggestedName) could not be saved: \(error.localizedDescription)"
        }
    }
}

/// Everything one attachment row needs that depends on the payload, resolved once per attachment
/// list rather than once per render. See `EntryDetailView.rebuildAttachmentRows()`.
private struct AttachmentRowState {
    /// Whether the blob pool could resolve the payload at all — drives the export button.
    var isResolvable: Bool
    /// The inline preview, when `AttachmentPreviewPolicy` allows one and the decode succeeded.
    var preview: Image?
}

/// Read-only presentation of the selected entry — every field visible at once, per the product
/// brief: this is the densest screen and the one that matters most, so nothing here is progressive
/// disclosure except the password itself (see below).
///
/// **Copy is the default action; reveal is the exception — a product decision, not a style
/// choice.** The overwhelmingly common thing a user does with a stored password is paste it
/// somewhere, never read it; defaulting to concealed with a copy button up front means the normal
/// path never puts plaintext on screen at all, and the reveal toggle exists only for the rarer "I
/// need to type this by hand" case. `isPasswordRevealed` resets to `false` on every selection
/// change and on every lock via `RevealPolicy` above, so a revealed password from entry A never
/// bleeds into the view of entry B, and a lock always leaves the screen in its safe default.
struct EntryDetailView: View {
    let entry: VaultEntry
    let clipboard: ClipboardService
    /// Whether the vault is locked right now. A plain `Bool` rather than the whole `VaultStore` —
    /// this read-only screen only ever needs to know when to snap the reveal back off; handing it
    /// the store would let it reach for things it has no business doing (upsert, delete, save).
    let isLocked: Bool
    /// Resolves an attachment's payload bytes. A closure rather than the whole `Vault` (or its
    /// blob pool) for the same reason `isLocked` is a bare `Bool` above: this screen needs exactly
    /// one capability from the vault, and handing it the vault would let it reach for things a
    /// read-only detail view has no business touching.
    var resolveAttachment: (VaultAttachment) -> Data?
    var onEdit: () -> Void

    /// Optional on purpose: the `#Preview` below constructs this view standalone, and a
    /// non-optional `@Environment(AppEnvironment.self)` traps at render time when nothing
    /// supplied it. Username / password / TOTP copies go through it when present (issue #167).
    @Environment(AppEnvironment.self) private var appEnvironment: AppEnvironment?

    @State private var isPasswordRevealed = false
    /// Names of the protected custom fields currently revealed. A set of names rather than one
    /// flag per row so revealing one secret does not reveal the rest, and so the reveal state
    /// clears wholesale on a lock or a selection change (see `RevealPolicy`).
    @State private var revealedCustomFields: Set<String> = []
    @State private var lastSeenEntryID: UUID?
    /// Payload-derived row state, keyed by `VaultAttachment.id`. Rebuilt only when the attachment
    /// list itself changes — never inside `body`; see `rebuildAttachmentRows()`.
    @State private var attachmentRows: [String: AttachmentRowState] = [:]
    /// Set when a "Save As…" write fails, cleared on selection change. A failed export used to be
    /// invisible; see `export(_:suggestedName:)`.
    @State private var exportError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.s6) {
                header

                VStack(alignment: .leading, spacing: Spacing.s3) {
                    FieldRow(label: "Title", value: entry.title)
                    FieldRow(
                        label: "Username", value: entry.username,
                        onCopy: { copy(entry.username, notice: "Copied username") },
                        copyIdentifier: "detail.copyUsername"
                    )
                    FieldRow(
                        label: "Password", value: entry.password, isMonospaced: true,
                        isRevealed: $isPasswordRevealed,
                        onCopy: { copy(entry.password, notice: "Copied password") },
                        copyIdentifier: "detail.copyPassword",
                        revealIdentifier: "detail.revealPassword"
                    )
                    urlRow
                    FieldRow(label: "Notes", value: entry.notes)
                }

                if let otpAuthURL = entry.otpAuthURL {
                    TOTPView(
                        otpAuthURL: otpAuthURL,
                        onCopy: { copy($0, notice: "Copied one-time code") }
                    )
                }

                if !entry.customFields.isEmpty {
                    customFieldsSection
                }

                if !entry.attachments.isEmpty {
                    attachmentsSection
                }

                metadataSection
            }
            .padding(Spacing.s7)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.surface)
        .onAppear { lastSeenEntryID = entry.id }
        // `initial: true` so the first render is the build, not a render that decodes. Keyed on
        // the attachment LIST rather than on `entry.id`: an edit that adds or removes one keeps
        // the same entry id, and nothing else about an entry can change what these rows show.
        .onChange(of: entry.attachments, initial: true) { _, _ in rebuildAttachmentRows() }
        .onChange(of: entry.id) { oldValue, newValue in
            exportError = nil
            isPasswordRevealed = RevealPolicy.revealAfterSelectionChange(
                wasRevealed: isPasswordRevealed,
                previousEntryID: oldValue,
                currentEntryID: newValue,
                isLocked: isLocked
            )
            revealedCustomFields = RevealPolicy.revealsAfterSelectionChange(
                revealedCustomFields,
                previousEntryID: oldValue,
                currentEntryID: newValue,
                isLocked: isLocked
            )
            lastSeenEntryID = newValue
        }
        .onChange(of: isLocked) { _, locked in
            isPasswordRevealed = RevealPolicy.revealAfterSelectionChange(
                wasRevealed: isPasswordRevealed,
                previousEntryID: lastSeenEntryID,
                currentEntryID: entry.id,
                isLocked: locked
            )
            revealedCustomFields = RevealPolicy.revealsAfterSelectionChange(
                revealedCustomFields,
                previousEntryID: lastSeenEntryID,
                currentEntryID: entry.id,
                isLocked: locked
            )
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.s5) {
            Text(entry.title.isEmpty ? "Untitled" : entry.title)
                .font(Typography.title3)
                .foregroundStyle(Palette.text)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                onEdit()
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .buttonStyle(.tokenSecondary)
            .accessibilityIdentifier("detail.edit")
            .keyboardShortcut("e", modifiers: .command)
        }
    }

    /// The mockup's `.section-head`: a quiet caption over a hairline that separates one group of
    /// fields from the next. One function so all three sections cannot drift apart.
    private func sectionHeading(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s5) {
            Palette.border.frame(height: Metrics.hairline)
            Text(title)
                .font(Typography.captionMedium)
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(.top, Spacing.s3)
    }

    /// Shared with `EntryListView`'s row context menu (issue #48) — see `EntryURLResolver`'s own
    /// doc comment for why the scheme test lives there instead of being duplicated here.
    private var resolvedURL: URL? {
        EntryURLResolver.resolvedURL(from: entry.url)
    }

    private func openResolvedURL() {
        guard let resolvedURL else { return }
        NSWorkspace.shared.open(resolvedURL)
    }

    /// Issue #17: the URL value itself now opens on click (`FieldRow.onActivateLink`), matching
    /// Strongbox. The adjacent glyph button stays rather than being removed as redundant: a plain
    /// clicked value has no keyboard-focus stop on macOS (only controls do), so a Tab-only user —
    /// sighted, not using VoiceOver — would lose the ability to open the URL at all if this were
    /// the sole affordance. `detail.openURL` keeps naming the button; the value's own click and
    /// VoiceOver action are unnamed extras, not a replacement for it.
    private var urlRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s4) {
            FieldRow(
                label: "URL", value: entry.url,
                // A closure literal, not a bare `openResolvedURL` method reference: the ternary
                // with `nil` otherwise defeats the type checker (a real failure seen here, not a
                // style preference — see the compiler's own "please submit a bug report").
                onActivateLink: resolvedURL != nil ? { openResolvedURL() } : nil
            )
            if resolvedURL != nil {
                Button(action: openResolvedURL) {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(.tokenGlyph)
                .help("Open URL")
                .accessibilityLabel("Open URL")
                .accessibilityIdentifier("detail.openURL")
            }
        }
    }

    private var customFieldsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s3) {
            sectionHeading("Custom Fields")
            // A protected custom field is concealed exactly like Password above: `isRevealed` is
            // non-nil only for those, which is the single signal `FieldRow` uses to decide between
            // dots-plus-an-eye and plain text. The flag is the file's own marking (or the user's
            // choice in the edit sheet) carried through `VaultFieldValue` — this view does not
            // guess which fields are secrets, and must not start.
            //
            // Copy is on EVERY row, secret or not, and concealing a field without it would have
            // inverted the rule concealment exists to serve (`design/ux-rules.md`): copy up front
            // is what keeps the normal path from ever putting plaintext on screen, so a concealed
            // row whose only affordance is the eye forces exactly the disclosure the dots prevent.
            // A plain custom field gets one too — Username is not a secret and has always had it.
            ForEach(entry.customFields.keys.sorted(), id: \.self) { key in
                let field = entry.customFields[key] ?? .plain("")
                FieldRow(
                    label: key,
                    value: field.value,
                    isMonospaced: true,
                    isRevealed: field.isProtected ? revealBinding(forCustomField: key) : nil,
                    onCopy: { clipboard.copy(field.value) },
                    copyIdentifier: "detail.copyCustomField.\(key)",
                    revealIdentifier: "detail.revealCustomField.\(key)"
                )
            }
        }
    }

    /// Username / password / TOTP copies go through `AppEnvironment.copy` so the toast and the
    /// pasteboard write cannot diverge. Previews have no environment and fall back to `clipboard`.
    private func copy(_ value: String, notice: String) {
        if let appEnvironment {
            appEnvironment.copy(value, notice: notice)
        } else {
            clipboard.copy(value)
        }
    }

    /// Reveal state for one custom field, projected out of `revealedCustomFields`. A computed
    /// `Binding` rather than a `@State` per row because the rows are a `ForEach` over a dictionary
    /// whose keys change as the user edits the entry.
    private func revealBinding(forCustomField key: String) -> Binding<Bool> {
        Binding(
            get: { revealedCustomFields.contains(key) },
            set: { isRevealed in
                if isRevealed {
                    revealedCustomFields.insert(key)
                } else {
                    revealedCustomFields.remove(key)
                }
            }
        )
    }

    /// The entry's attachments: name, size, an inline preview for a payload that is allowed one,
    /// and a per-attachment export.
    ///
    /// **Nothing here writes a payload anywhere the user did not choose.** Attachment bytes are
    /// secret material — a scan of a passport, a screenshot of recovery codes — so the preview is
    /// built from the in-memory `Data` rather than by staging a temp file for Quick Look (which
    /// would leave plaintext under `/tmp` outliving the lock), payloads never reach the pasteboard,
    /// and nothing about them is logged. "Save As..." is the single egress, and it is user-driven
    /// through `NSSavePanel` — which is also what makes the sandbox grant that write legitimate.
    ///
    /// Which payloads get decoded at all is `AttachmentPreviewPolicy`'s decision; read it before
    /// widening anything here.
    private var attachmentsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s4) {
            sectionHeading("Attachments")
            ForEach(entry.attachments) { attachment in
                attachmentRow(attachment)
            }
            if let exportError {
                Label(exportError, systemImage: "exclamationmark.triangle.fill")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.danger)
                    .accessibilityIdentifier("detail.exportError")
            }
        }
        .accessibilityIdentifier("detail.attachments")
    }

    /// Resolves each attachment's payload once per attachment list and keeps only what the row
    /// needs: whether it resolved, and its preview image.
    ///
    /// Deliberately NOT done inside `body`. `resolveAttachment` is a closure, which SwiftUI's
    /// structural comparison cannot diff, so this view re-evaluates whenever its parent does — and
    /// `VaultBrowserView.body` re-evaluates on every keystroke in the search field. Decoding in
    /// `body` meant one image rebuilt per attachment per typed character, on the main thread.
    private func rebuildAttachmentRows() {
        var rows: [String: AttachmentRowState] = [:]
        for attachment in entry.attachments {
            guard let payload = resolveAttachment(attachment) else {
                rows[attachment.id] = AttachmentRowState(isResolvable: false, preview: nil)
                continue
            }
            var preview: Image?
            if AttachmentPreviewPolicy.allowsPreview(name: attachment.name, bytes: payload),
               let image = NSImage(data: payload) {
                preview = Image(nsImage: image)
            }
            rows[attachment.id] = AttachmentRowState(isResolvable: true, preview: preview)
        }
        attachmentRows = rows
    }

    private func attachmentRow(_ attachment: VaultAttachment) -> some View {
        // Everything payload-dependent is read from state built by `rebuildAttachmentRows()`; this
        // function must not touch `resolveAttachment` itself. Absent state means the rebuild has
        // not run yet, which reads as "not resolvable" for one frame and then corrects itself.
        let state = attachmentRows[attachment.id]
        return VStack(alignment: .leading, spacing: Spacing.s3) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s4) {
                Image(systemName: "paperclip")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                VStack(alignment: .leading, spacing: Spacing.s1) {
                    Text(attachment.name)
                        .font(Typography.body)
                        .foregroundStyle(Palette.text)
                    Text(Self.byteFormatter.string(fromByteCount: Int64(attachment.byteCount)))
                        .font(Typography.monoCaption2)
                        .foregroundStyle(Palette.textTertiary)
                }
                Spacer(minLength: 0)
                Button {
                    // Resolved at the moment of export rather than held on the row: one plaintext
                    // copy, alive only for the duration of the write.
                    guard let payload = resolveAttachment(attachment) else { return }
                    exportError = AttachmentExporter.export(payload, suggestedName: attachment.name)
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.tokenGlyph)
                .help("Save this attachment to a file")
                .accessibilityLabel("Save attachment")
                // Identifiers are keyed by the attachment's NAME, which KDBX already requires to
                // be unique within one entry — the same property that makes it `VaultAttachment`'s
                // `id`. Deliberately not keyed by the blob hash: that would put a fingerprint of
                // secret bytes into the accessibility tree, where anything able to read the tree
                // could then correlate the same file across vaults.
                .accessibilityIdentifier("detail.saveAttachment.\(attachment.name)")
                .disabled(state?.isResolvable != true)
            }

            if let preview = state?.preview {
                preview
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 220, maxHeight: 140, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.xs, style: .continuous))
                    .accessibilityIdentifier("detail.attachmentPreview.\(attachment.name)")
            }
        }
        .accessibilityIdentifier("detail.attachment.\(attachment.name)")
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s3) {
            sectionHeading("Metadata")
            // The product deliberately shows the machinery — timestamps and the raw KDBX entry
            // UUID — rather than hiding it behind an "advanced" disclosure. Positioning note (repo
            // CLAUDE.md): this app's user wants to see how the database is actually built, not be
            // shielded from it the way a more consumer-facing password manager would.
            FieldRow(label: "Created", value: Self.dateFormatter.string(from: entry.created))
            FieldRow(label: "Modified", value: Self.dateFormatter.string(from: entry.modified))
            FieldRow(label: "UUID", value: entry.id.uuidString, isMonospaced: true)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

#Preview {
    EntryDetailView(
        entry: Vault.sample.entries[0],
        clipboard: ClipboardService(),
        isLocked: false,
        resolveAttachment: { Vault.sample.bytes(for: $0) },
        onEdit: {}
    )
    .frame(width: 480, height: 640)
}
