import SwiftUI

/// A thin bottom bar for `VaultBrowserView` to embed.
///
/// Takes only the plain values it renders — no `VaultStore`, no `AutoLockController`, no
/// `ClipboardService` — so it stays trivially previewable and so the browser owner can drop it in
/// without pulling this file's dependencies along. Whoever embeds it is responsible for reading the
/// live countdowns off `AutoLockController.secondsUntilIdleLock` / `ClipboardService.secondsRemaining`
/// and re-rendering this view each tick; that observation belongs to the embedder, not to a "dumb"
/// status strip.
struct StatusBar: View {
    /// Full path of the open database — pass-sumo shows the machinery on purpose (see `UnlockView`).
    let databasePath: String
    /// Whether `VaultStore.isDirty` is currently true.
    let isDirty: Bool
    /// Seconds left before the idle auto-lock fires, or `nil` when the countdown isn't running
    /// (`AutoLockController.secondsUntilIdleLock`).
    let secondsUntilAutoLock: Int?
    /// Seconds left before the clipboard auto-clears, or `nil` when nothing of ours is on it
    /// (`ClipboardService.secondsRemaining`, `0` meaning "not counting" collapsed to `nil` by the
    /// caller).
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

    var body: some View {
        HStack(spacing: 16) {
            Label(databasePath, systemImage: "lock.doc")
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityIdentifier("statusbar.path")

            if let backupWarning {
                Label(backupWarning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(backupWarning)
                    .accessibilityIdentifier("statusbar.backupWarning")
            }

            if isDirty {
                Label("Unsaved changes", systemImage: "circle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("statusbar.dirty")
            }

            Spacer(minLength: 8)

            if let secondsUntilClipboardClear {
                Label("\(secondsUntilClipboardClear)s", systemImage: "doc.on.clipboard")
                    .accessibilityIdentifier("statusbar.clipboardCountdown")
            }

            if let secondsUntilAutoLock {
                Label(Self.formatted(secondsUntilAutoLock), systemImage: "lock.rotation")
                    .accessibilityIdentifier("statusbar.autoLockCountdown")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .accessibilityIdentifier("statusbar")
    }

    /// `m:ss` — the auto-lock timeout is minutes-scale (default 300s), so a bare second count would
    /// read as a much more alarming number than it is.
    private static func formatted(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

#Preview("Clean") {
    StatusBar(
        databasePath: "/Users/den/Documents/Personal.kdbx",
        isDirty: false,
        secondsUntilAutoLock: 284,
        secondsUntilClipboardClear: nil,
        backupWarning: nil
    )
}

#Preview("Dirty, clipboard counting down") {
    StatusBar(
        databasePath: "/Users/den/Documents/Personal.kdbx",
        isDirty: true,
        secondsUntilAutoLock: 12,
        secondsUntilClipboardClear: 7,
        backupWarning: nil
    )
}

#Preview("Saved without a backup") {
    StatusBar(
        databasePath: "/Users/den/Documents/Personal.kdbx",
        isDirty: false,
        secondsUntilAutoLock: 284,
        secondsUntilClipboardClear: nil,
        backupWarning: "Saved, but no backup: couldn't back up Personal.kdbx before saving: "
            + "the volume is out of space."
    )
}
