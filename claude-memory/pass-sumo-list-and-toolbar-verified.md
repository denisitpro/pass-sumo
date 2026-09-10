# List selection and the toolbar band: both settled (2026-09-09)

PR #59 (palette C token layer, issue #56) shipped with two open pixel questions it could not answer
because the display was off-limits. Both are now **settled empirically**, and both came out in
favour of the code as written — no fix was needed for either.

## 1. `List(selection:)` does NOT paint over `.listRowBackground(.clear)`

`EntryListView` and `GroupSidebar` draw their own selected-row ground (`row-sel-bg`, `#D2E9EF`) and
clear the row's default background. The worry was that AppKit's native selection highlight would be
painted on top, making selected rows read as system-tinted.

It is not. Measured: the selected row's pixels are **identical** to the same colour rendered outside
any `List`, byte for byte. True for `.listStyle(.plain)` and `.listStyle(.sidebar)` alike, and true
with the row views' `isEmphasized` forced to `true` (the flag that distinguishes the active-window
accent highlight from the inactive grey one).

Mechanism, for whoever doubts it later: SwiftUI's macOS `List` is a `SwiftUIOutlineListView`
(an `NSTableView`) whose rows are `ListTableRowView`. The table's `selectionHighlightStyle` is left
at `.regular` / `.sourceList` — so the *style* is not what saves us — but `ListTableRowView` defers
its selection drawing to the SwiftUI row background, which `.listRowBackground(.clear)` has emptied.
Forcing `selectionHighlightStyle = .regular` on the row views changed nothing.

## 2. `.toolbarBackground(_:for: .windowToolbar)` DOES take under `.windowToolbarStyle(.unified)`

`VaultBrowserView` tints the toolbar to `sidebar` (`#EFF5F5`) while `PassSumoApp` sets
`.windowToolbarStyle(.unified)`. It works. With the modifier the window gains an
`NSHostingView<PlatformBarBackground>` inside its `NSTitlebarContainerView`,
`titlebarAppearsTransparent` flips to `true`, and the band renders the tint exactly. The control run
— identical scene, modifier removed — has no such view, leaves `titlebarAppearsTransparent` false,
and the band renders the window background instead.

**But the band is 52pt, not the mockup's 44.** That height is AppKit's and there is no SwiftUI knob
for it; `Metrics.toolbarHeight` is consequently a dead token, now annotated as descriptive-only in
both `design/BRAND.md` and `DesignTokens.swift`. Do not try to force 44.

## How they were measured, when the screen is locked

The Mac mini is shared and its session is often screen-locked. **A locked session cannot be
screenshotted**: `CGSSessionScreenIsLocked = 1`, full-screen capture returns only the lock screen,
and per-window capture (`screencapture -l <id>`, and ScreenCaptureKit behind it) fails outright with
"could not create image from window" — even though `CGWindowListCopyWindowInfo` still lists the
app's window.

What still works, because it never touches the window server: **render off-screen and read the
bitmap.** An `NSWindow` that is created but never ordered front, plus
`NSView.cacheDisplay(in:to:)` into an `NSBitmapImageRep`, draws through AppKit's real drawing code
and can be sampled pixel by pixel. For anything scene-shaped (a window toolbar, a titlebar) the
probe has to be a real `.app` bundle with an `@main App` — the modifier is plumbed by the scene, not
by a hosting view.

Two traps that cost time:

- **Always render a control swatch of the same colour in the same image.** The bitmap rep comes back
  in the display's colour space ("Studio Display" here), which shifts every sampled value — `#D2E9EF`
  reads as `#DDECF1` and `#EFF5F5` as `#F3F7F7`. Without the control, that shift is indistinguishable
  from something being composited on top, and it will be misread as a bug.
- Probes belong outside the repo (a scratch dir), not as a test file nobody asked for.

## Still not verified

The **running app's own pixels** have never been compared with the mockup: row rhythm, the inset
hairline in place, the unlock card, the generator sheet, Settings. Those need an unlocked display.
Issue #64 (no focus indicator on any custom button style) is confirmed real by code inspection —
`TokenButtonSurface` and `GlyphButtonSurface` take no focus input at all — but it stays with #64,
because whether the glyph buttons are even in the tab ring cannot be answered without a keyboard on
a live window.
