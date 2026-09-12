import SwiftUI

/// Names a new folder and, optionally, picks its built-in icon (issue #129).
///
/// **Create only.** Rename stays the name-only alert on `VaultBrowserView`, and Change Icon on an
/// existing folder stays that view's `groupIconTarget` sheet. This type exists so the create path
/// can offer an icon without turning the rename alert into a second form.
///
/// The sheet collects a name and an icon index; it does not create the folder itself. The caller
/// owns `VaultStore.addGroup` so this view stays a form, the same split `IconPickerSheet` uses.
struct GroupEditSheet: View {
    var onConfirm: (String, UInt32) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var iconID: UInt32 = VaultGroup.defaultIconID
    @State private var showingIconPicker = false
    @FocusState private var isNameFocused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Create is disabled rather than allowed to no-op: `addGroup` already refuses a blank name,
    /// and a live button that silently does nothing is the thing the alert path could not prevent
    /// (AppKit does not honour `.disabled` on an alert button).
    private var canCreate: Bool { !trimmedName.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s6) {
            Text("New Group")
                .font(Typography.headline)
                .foregroundStyle(Palette.text)

            TextField(
                text: $name,
                prompt: Text("Name").foregroundStyle(Palette.textTertiary)
            ) {
                // Carries the accessible name; macOS renders only `prompt`. Same reasoning as
                // `MasterPasswordField.fieldContent`.
                Text("Name")
            }
            .textFieldStyle(.plain)
            .font(Typography.field)
            .foregroundStyle(Palette.text)
            .padding(.horizontal, Spacing.s4)
            .frame(height: Metrics.fieldHeight)
            .fieldChrome(isFocused: isNameFocused)
            .focused($isNameFocused)
            .onSubmit(confirmIfAllowed)
            .accessibilityIdentifier("browser.groupName")

            Button {
                showingIconPicker = true
            } label: {
                HStack(spacing: Spacing.s4) {
                    Image(
                        systemName: StandardIconCatalog.symbolName(
                            for: iconID,
                            fallingBackTo: VaultGroup.defaultIconID
                        )
                    )
                    .font(Typography.body)
                    .frame(width: Metrics.rowIconSlot)
                    Text("Change…")
                }
            }
            .buttonStyle(.tokenSecondary)
            .accessibilityIdentifier("browser.newGroup.icon")

            HStack(spacing: Spacing.s3) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.tokenQuiet)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create", action: confirmIfAllowed)
                    .buttonStyle(.tokenPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
                    .accessibilityIdentifier("browser.confirmGroupName")
            }
        }
        .padding(Spacing.s7)
        .frame(width: 380)
        .background(Palette.surface)
        .onAppear { isNameFocused = true }
        .sheet(isPresented: $showingIconPicker) {
            IconPickerSheet(
                title: "Folder Icon",
                selectedIconID: iconID,
                onPick: { iconID = $0 }
            )
        }
    }

    private func confirmIfAllowed() {
        guard canCreate else { return }
        onConfirm(trimmedName, iconID)
        dismiss()
    }
}

#Preview {
    GroupEditSheet { _, _ in }
}
