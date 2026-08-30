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
        .onChange(of: entry.id) { oldValue, newValue in
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

    /// The entry's attachments: name, size, an inline preview when the payload is an image, and a
    /// per-attachment export.
    ///
    /// **Nothing here writes a payload anywhere the user did not choose.** Attachment bytes are
    /// secret material — a scan of a passport, a screenshot of recovery codes — so the preview is
    /// built from the in-memory `Data` via `NSImage(data:)` rather than by staging a temp file for
    /// Quick Look (which would leave plaintext under `/tmp` outliving the lock), payloads never
    /// reach the pasteboard, and nothing about them is logged. "Save As..." is the single egress,
    /// and it is user-driven through `NSSavePanel` — which is also what makes the sandbox grant
    /// that write legitimate.
    private var attachmentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Attachments")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(entry.attachments) { attachment in
                attachmentRow(attachment)
            }
        }
        .accessibilityIdentifier("detail.attachments")
    }

    private func attachmentRow(_ attachment: VaultAttachment) -> some View {
        // Resolved once per row render rather than separately for the preview and the export, so
        // there is one plaintext copy in flight instead of two.
        let payload = resolveAttachment(attachment)
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
                    guard let payload else { return }
                    Self.export(payload, suggestedName: attachment.name)
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
                .disabled(payload == nil)
            }

            if let payload, let image = NSImage(data: payload) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 220, maxHeight: 140, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .accessibilityIdentifier("detail.attachmentPreview.\(attachment.name)")
            }
        }
        .accessibilityIdentifier("detail.attachment.\(attachment.name)")
    }

    /// Writes `payload` wherever the user points the save panel.
    ///
    /// `runModal` rather than a sheet: this view has no window reference to attach one to, and a
    /// modal panel also guarantees the payload does not outlive the interaction inside a captured
    /// completion handler. A failed write is swallowed for now — the panel has already vetted the
    /// destination, and the alternative (an alert this read-only view would have to own) is UI the
    /// design pass in issue #3 should place, not something to improvise here.
    private static func export(_ payload: Data, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? payload.write(to: url, options: [.atomic])
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
