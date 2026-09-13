import SwiftUI

/// The very first thing a user with no database open sees.
///
/// Two actions and nothing else — no onboarding carousel, no upsell banner. That restraint is not
/// an oversight; it IS the product's positioning (repo CLAUDE.md: "what Strongbox was before the
/// feature creep"). Any third action added to this screen later should be treated as a decision
/// that needs its own justification, not a natural extension of this one.
struct WelcomeView: View {
    let environment: AppEnvironment

    @State private var pickerError: String?
    @State private var recents: [RecentDatabase] = []

    var body: some View {
        VStack(spacing: Spacing.s8) {
            VStack(spacing: Spacing.s4) {
                Image(systemName: "lock.shield")
                    .font(.system(size: Metrics.heroGlyphSize, weight: .light))
                    .foregroundStyle(Palette.accent600)
                Text("PassSumo")
                    .font(Typography.title2)
                    .foregroundStyle(Palette.text)
            }

            VStack(spacing: Spacing.s5) {
                Button("Open Database…") { openExistingDatabase() }
                    .buttonStyle(.tokenPrimary)
                    .accessibilityIdentifier("welcome.open")

                Button("Create New Database…") { environment.menuRequest = .newDatabase }
                    .buttonStyle(.tokenSecondary)
                    .accessibilityIdentifier("welcome.create")
            }

            if let pickerError {
                Text(pickerError)
                    .font(Typography.body)
                    .foregroundStyle(Palette.danger)
                    .accessibilityIdentifier("welcome.error")
            }

            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.s2) {
                    Text("Recent")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                    ForEach(recents) { recent in
                        Button {
                            environment.openRouter.requestOpen(recent.url)
                        } label: {
                            Label(recent.url.lastPathComponent, systemImage: "clock")
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.tokenQuiet)
                        .accessibilityIdentifier("welcome.recent.\(recent.id)")
                    }
                }
                .frame(maxWidth: 320)
            }
        }
        .padding(Spacing.s10)
        .cardSurface()
        .padding(Spacing.s10)
        // The card's width breathes with the window instead of being pinned to one fixed size in
        // an unbounded canvas (issue #102) — see `Metrics.authCardWidthFraction`'s doc comment for
        // why this, and not a capped window, is the fix: this view shares `PassSumoApp`'s
        // `WindowGroup` with the vault browser, which needs the window free to be much larger than
        // this screen's content.
        .containerRelativeFrame(.horizontal) { width, _ in
            min(max(width * Metrics.authCardWidthFraction, Metrics.authCardMinWidth), Metrics.authCardMaxWidth)
        }
        .frame(minHeight: Metrics.authCardMinHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surface)
        .task { loadRecents() }
        // `.openDatabase` and `.newDatabase` are deliberately absent: `RootView` owns both for
        // every store state (issue #84 for Open, issue #165 for Create), including this one.
        // Handling `.openDatabase` here as well would run two open panels for one ⌘O. This
        // button raises `.newDatabase` so it shares that one sheet with File → New and the
        // tab-bar + menu, rather than presenting a second copy.
    }

    /// The panel itself, including the "never a pre-set default path" rule App Review cares about,
    /// lives in `DatabaseFilePicker` — this view and `RootView` both need it (see that type).
    private func openExistingDatabase() {
        pickerError = nil
        guard let url = DatabaseFilePicker.chooseExistingDatabase() else { return }
        // Through the router, not `store.select` directly, so this button obeys the same rule as a
        // Finder double-click and a ⌘O — one implementation, three entry points (issue #84). From
        // this screen the store is `.empty`, so the decision is always `.open`; routing anyway is
        // what keeps that true by construction rather than by the caller remembering it.
        environment.openRouter.requestOpen(url)
    }

    private func loadRecents() {
        recents = environment.recentDatabaseBookmarks.compactMap { bookmark in
            environment.resolveRecentDatabase(bookmark).map { RecentDatabase(url: $0) }
        }
    }
}

private struct RecentDatabase: Identifiable {
    let url: URL
    var id: String { url.path }
}

#Preview("Welcome") {
    WelcomeView(environment: .uiTesting())
}
