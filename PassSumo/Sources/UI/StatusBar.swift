import SwiftUI

/// A thin bottom bar for `VaultBrowserView` to embed.
///
/// Takes only the plain values it renders — no `VaultStore`, no `AutoLockController`, no
/// `ClipboardService` — so it stays trivially previewable and so the browser owner can drop it in
/// without pulling this file's dependencies along. Whoever embeds it is responsible for reading the
/// live countdown off `ClipboardService.secondsRemaining` and re-rendering this view each tick; that
/// observation belongs to the embedder, not to a "dumb" status strip.
struct StatusBar: View {
    /// Full path of the open database — pass-sumo shows the machinery on purpose (see `UnlockView`).
    let databasePath: String
    /// Whether `VaultStore.isDirty` is currently true.
    let isDirty: Bool
    /// Seconds left before the clipboard auto-clears, or `nil` when nothing of ours is on it
    /// (`ClipboardService.secondsRemaining`, `0` meaning "not counting" collapsed to `nil` by the
    /// caller).
    ///
    /// **Kept, unlike the auto-lock countdown (issue #101) that used to sit beside it.** The two
    /// looked like the same kind of peripheral ticking, but they are not: auto-lock is a background
    /// safeguard the user never has to act on before it fires, while this one reports a deadline
    /// the user is actively racing — paste the secret before it clears, or it's gone. That is a
    /// real decision this readout serves (how much longer do I have), not motion for its own sake,
    /// so it stays.
    let secondsUntilClipboardClear: Int?
    /// Set when the last save went through but its pre-save backup did not
    /// (`VaultStore.lastBackupError`, worded by `VaultError.backupFailureMessage`). `nil` in the
    /// normal case.
    ///
    /// Lives here rather than in an alert because the condition is not momentary: a backup fails
    /// because the app's container cannot be written, which is true of the next save too. A
    /// dismissable alert would be acknowledged once and the app would go on saving unprotected in
    /// silence — the "swallowed failure" half of issue #26's policy, arrived at from the other side.
    let backupWarning: String?
    /// Compact running-build stamp (`AppVersionInfo.shortLabel`). Defaulted so previews and the
    /// one production call site stay short; tests pass an explicit string rather than reading
    /// `Bundle.main`.
    var buildLabel: String = AppVersionInfo.current().shortLabel

    var body: some View {
        HStack(spacing: Spacing.s5) {
            // The path is monospaced and middle-truncated: this is machinery the product shows on
            // purpose, and the tail (the filename) is the half worth keeping when it doesn't fit.
            Label {
                Text(databasePath)
                    .font(Typography.monoCaption2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: "lock.doc")
            }
            .accessibilityIdentifier("statusbar.path")

            if let backupWarning {
                // `warning` tints the ICON only. It measures 4.41:1 against this band's `sidebar`
                // ground — below WCAG AA for normal text — so the sentence itself stays in `text`
                // (14.6:1). See design/BRAND.md's contrast note.
                Label {
                    Text(backupWarning)
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.warning)
                }
                .help(backupWarning)
                .accessibilityIdentifier("statusbar.backupWarning")
            }

            if isDirty {
                Label {
                    Text("Unsaved changes")
                } icon: {
                    Image(systemName: "circle.fill")
                        .foregroundStyle(Palette.warning)
                }
                .accessibilityIdentifier("statusbar.dirty")
            }

            Spacer(minLength: Spacing.s4)

            if let secondsUntilClipboardClear {
                Label {
                    Text("\(secondsUntilClipboardClear)s").font(Typography.monoCaption2)
                } icon: {
                    Image(systemName: "doc.on.clipboard")
                }
                .accessibilityIdentifier("statusbar.clipboardCountdown")
            }

            // Trailing on purpose: the empty bottom-right corner of ShotSumo_2026-09-12_18-12-38,
            // so a leftover 143 vs a current 163 is readable without opening Settings (issue #153).
            // Same colour as the rest of this band (`textSecondary`) — `textTertiary` fails AA on
            // `sidebar` ground (design/BRAND.md).
            Text(buildLabel)
                .font(Typography.monoCaption2)
                .lineLimit(1)
                .accessibilityIdentifier("statusbar.build")
        }
        .font(Typography.caption)
        .foregroundStyle(Palette.textSecondary)
        .padding(.horizontal, Spacing.s5)
        .statusBarBand()
        .accessibilityIdentifier("statusbar")
    }
}

#Preview("Clean") {
    StatusBar(
        databasePath: "/Users/demo/Documents/Family Passwords.kdbx",
        isDirty: false,
        secondsUntilClipboardClear: nil,
        backupWarning: nil
    )
}

#Preview("Dirty, clipboard counting down") {
    StatusBar(
        databasePath: "/Users/demo/Documents/Family Passwords.kdbx",
        isDirty: true,
        secondsUntilClipboardClear: 7,
        backupWarning: nil
    )
}

#Preview("Saved without a backup") {
    StatusBar(
        databasePath: "/Users/demo/Documents/Family Passwords.kdbx",
        isDirty: false,
        secondsUntilClipboardClear: nil,
        backupWarning: "Saved, but no backup: couldn't back up Personal.kdbx before saving: "
            + "the volume is out of space."
    )
}
