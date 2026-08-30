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

    @State private var isPasswordRevealed = false
    @State private var lastSeenEntryID: UUID?
    /// Payload-derived row state, keyed by `VaultAttachment.id`. Rebuilt only when the attachment
    /// list itself changes — never inside `body`; see `rebuildAttachmentRows()`.
    @State private var attachmentRows: [String: AttachmentRowState] = [:]
    /// Set when a "Save As…" write fails, cleared on selection change. A failed export used to be
    /// invisible; see `export(_:suggestedName:)`.
    @State private var exportError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                VStack(alignment: .leading, spacing: 6) {
                    FieldRow(label: "Title", value: entry.title)
                    FieldRow(
                        label: "Username", value: entry.username,
                        onCopy: { clipboard.copy(entry.username) },
                        copyIdentifier: "detail.copyUsername"
                    )
                    FieldRow(
                        label: "Password", value: entry.password, isMonospaced: true,
                        isRevealed: $isPasswordRevealed,
                        onCopy: { clipboard.copy(entry.password) },
                        copyIdentifier: "detail.copyPassword",
                        revealIdentifier: "detail.revealPassword"
                    )
                    urlRow
                    FieldRow(label: "Notes", value: entry.notes)
                }

                if let otpAuthURL = entry.otpAuthURL {
                    TOTPView(otpAuthURL: otpAuthURL, clipboard: clipboard)
                }

                if !entry.customFields.isEmpty {
                    customFieldsSection
                }

                if !entry.attachments.isEmpty {
                    attachmentsSection
                }

                metadataSection
            }
            .padding(20)
        }
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
            lastSeenEntryID = newValue
        }
        .onChange(of: isLocked) { _, locked in
            isPasswordRevealed = RevealPolicy.revealAfterSelectionChange(
                wasRevealed: isPasswordRevealed,
                previousEntryID: lastSeenEntryID,
                currentEntryID: entry.id,
                isLocked: locked
            )
        }
    }

    private var header: some View {
        HStack {
            Text(entry.title.isEmpty ? "Untitled" : entry.title)
                .font(.title2.weight(.semibold))
            Spacer()
            Button {
                onEdit()
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .accessibilityIdentifier("detail.edit")
            .keyboardShortcut("e", modifiers: .command)
        }
    }

    /// A scheme is required, not just a parseable string: `URL(string:)` alone happily accepts a
    /// bare "example.com" that `NSWorkspace` then silently fails to open. Requiring a scheme is
    /// what keeps `openURL` from no-oping on the common case of a user having pasted a bare domain
    /// into the URL field, instead of surfacing a button that looks live but does nothing.
    private var resolvedURL: URL? {
        guard !entry.url.isEmpty, let url = URL(string: entry.url), url.scheme != nil else { return nil }
        return url
    }

    private var urlRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            FieldRow(label: "URL", value: entry.url)
            if let resolvedURL {
                Button {
                    NSWorkspace.shared.open(resolvedURL)
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(.plain)
                .help("Open URL")
                .accessibilityLabel("Open URL")
                .accessibilityIdentifier("detail.openURL")
            }
        }
    }

    private var customFieldsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Custom Fields")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            // No per-field "protected" flag survives into `VaultEntry.customFields` — it's a flat
            // `[String: String]` (see `Domain.swift`) — so unlike Password above there is no
            // signal here to conceal any of these by default; every custom field renders plainly.
            // Concealing protected custom fields too needs that flag carried into the domain model
            // first, which is a KDBX-layer change, not something this view can invent on its own.
            ForEach(entry.customFields.keys.sorted(), id: \.self) { key in
                FieldRow(label: key, value: entry.customFields[key] ?? "", isMonospaced: true)
            }
        }
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Attachments")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(entry.attachments) { attachment in
                attachmentRow(attachment)
            }
            if let exportError {
                Label(exportError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
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
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "paperclip")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.name)
                    Text(Self.byteFormatter.string(fromByteCount: Int64(attachment.byteCount)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Button {
                    // Resolved at the moment of export rather than held on the row: one plaintext
                    // copy, alive only for the duration of the write.
                    guard let payload = resolveAttachment(attachment) else { return }
                    exportError = Self.export(payload, suggestedName: attachment.name)
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.plain)
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
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .accessibilityIdentifier("detail.attachmentPreview.\(attachment.name)")
            }
        }
        .accessibilityIdentifier("detail.attachment.\(attachment.name)")
    }

    /// Writes `payload` wherever the user points the save panel, returning a message to show when
    /// the write fails and `nil` otherwise.
    ///
    /// `runModal` rather than a sheet: this view has no window reference to attach one to, and a
    /// modal panel also guarantees the payload does not outlive the interaction inside a captured
    /// completion handler.
    ///
    /// A failed write used to be swallowed, which is the worst outcome available here: the user
    /// watched a save panel accept a destination and leaves believing their passport scan is on
    /// disk when nothing is there. It is not theoretical either — `.atomic` writes a sibling temp
    /// file in the destination directory first, which a powerbox-granted URL can plausibly refuse.
    /// Surfacing the error is the fix; changing the write strategy on that guess is not. The
    /// message carries the filename and the system's own reason, never any payload bytes.
    private static func export(_ payload: Data, suggestedName: String) -> String? {
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

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Metadata")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
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
