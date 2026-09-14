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
    /// Set when the save that would have written the current edits did not happen at all
    /// (`VaultStore.lastError`, worded by `VaultError.displayMessage` — issue #203). `nil` once
    /// there is nothing unwritten to report: `VaultStore` clears `lastError` the moment a save
    /// succeeds, and the caller reads that live, so this follows automatically.
    ///
    /// Persistent, for the same reason `backupWarning` is (see below) — a failed save is a
    /// condition that outlives the moment it happened: the vault stays dirty until the *next*
    /// successful save, and a dismissable alert acknowledged once would leave the app looking idle
    /// while a real save keeps failing underneath it (the same "swallowed failure" shape issue #26
    /// rejected for the backup case). It reuses `VaultError.displayMessage` rather than a second
    /// set of sentences for the same errors — `UnlockView` and `CreateDatabaseSheet` already render
    /// exactly that string for the same type, and `.externallyModified`'s own wording was written
    /// with this readout in mind (see that case's doc comment: "this string is also what a status
    /// readout would show").
    ///
    /// Styled in `Palette.danger` — the text, not just the icon — unlike `backupWarning`'s
    /// icon-only tint below. The two mean opposite things about the user's data (a backup warning
    /// means the edits ARE on disk, just without the extra copy; this means they are NOT on disk at
    /// all), and `danger` measures 5.93:1 against this band's `sidebar` ground — above WCAG AA's
    /// 4.5:1 for normal text, unlike `warning`'s 4.41:1 that forced the icon-only compromise below.
    let saveError: String?
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

            if let saveError {
                // Text AND icon in `danger` — see `saveError`'s own doc comment on why this one,
                // unlike `backupWarning` below, can afford full-sentence contrast on this ground.
                Label {
                    Text(saveError)
                        .foregroundStyle(Palette.danger)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.danger)
                }
                .help(saveError)
                .accessibilityIdentifier("statusbar.saveError")
            }

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
        saveError: nil,
        backupWarning: nil
    )
}

#Preview("Dirty, clipboard counting down") {
    StatusBar(
        databasePath: "/Users/demo/Documents/Family Passwords.kdbx",
        isDirty: true,
        secondsUntilClipboardClear: 7,
        saveError: nil,
        backupWarning: nil
    )
}

#Preview("Saved without a backup") {
    StatusBar(
        databasePath: "/Users/demo/Documents/Family Passwords.kdbx",
        isDirty: false,
        secondsUntilClipboardClear: nil,
        saveError: nil,
        backupWarning: "Saved, but no backup: couldn't back up Personal.kdbx before saving: "
            + "the volume is out of space."
    )
}

#Preview("Failed save") {
    // Issue #203: nothing was written at all — the message a failed ⌘S or a failed automatic
    // save (issue #172) both now show, via `VaultError.displayMessage`.
    StatusBar(
        databasePath: "/Users/demo/Documents/Family Passwords.kdbx",
        isDirty: true,
        secondsUntilClipboardClear: nil,
        saveError: "This database was changed on disk by another app or Mac. "
            + "Your unsaved changes are still here, but nothing was written.",
        backupWarning: nil
    )
}

#Preview("Failed save AND a prior backup warning") {
    // The crowded case decision 4 (issue #203) has to answer: a save can fail outright while an
    // OLDER, still-unresolved backup warning from the last save that DID succeed is still showing
    // — `lastError` and `lastBackupError` are independent properties, so both can be non-nil at
    // once. Checked here at 900pt, the narrowest an unlocked-tab window is ever allowed to get
    // (`PassSumoApp.body`'s `.frame(minWidth: isBrowserOpen ? 900 : 520, ...)`), not just at a
    // comfortable one.
    StatusBar(
        databasePath: "/Users/demo/Documents/Family Passwords.kdbx",
        isDirty: true,
        secondsUntilClipboardClear: 42,
        saveError: "Couldn't read the file: the volume is no longer available.",
        backupWarning: "Saved, but no backup: couldn't back up Personal.kdbx before saving: "
            + "the volume is out of space."
    )
    .frame(width: 900)
}
