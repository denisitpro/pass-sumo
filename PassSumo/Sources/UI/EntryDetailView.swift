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
        onEdit: {}
    )
    .frame(width: 480, height: 640)
}
