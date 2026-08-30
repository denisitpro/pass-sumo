import SwiftUI

/// Shows the current TOTP code for an entry's `otpAuthURL`, refreshed once a second.
///
/// **`TimelineView(.periodic)`, not a hand-rolled `Timer`.** A `Timer` keeps firing (and this view
/// keeps recomputing an HMAC) even while its window is fully occluded by another window or the
/// user has switched Spaces — wasted CPU for a code nobody can see. `TimelineView` is driven by
/// the same scheduling SwiftUI already suspends for occluded/inactive windows, so the ticking
/// naturally stops and resumes with visibility at no cost to this view, with no lifecycle code of
/// our own to get wrong (`ClipboardService`'s and `AutoLockController`'s `Timer`s need an explicit
/// weak-self/invalidate dance for exactly this reason — a `TimelineView` needs none of it).
struct TOTPView: View {
    let otpAuthURL: String
    let clipboard: ClipboardService

    /// Parsed once, in `init`, rather than re-parsed on every tick — the URL doesn't change while
    /// this view is on screen, and `TOTPGenerator(parsing:)` isn't free (base32 decode, query
    /// parsing). A parse failure becomes `.failure` here so `body` can show an inline error
    /// instead of crashing on an entry some other KDBX client wrote with a shape we don't expect.
    private let generatorResult: Result<TOTPGenerator, Error>

    init(otpAuthURL: String, clipboard: ClipboardService) {
        self.otpAuthURL = otpAuthURL
        self.clipboard = clipboard
        do {
            generatorResult = .success(try TOTPGenerator(parsing: otpAuthURL))
        } catch {
            generatorResult = .failure(error)
        }
    }

    var body: some View {
        Group {
            switch generatorResult {
            case .failure:
                Label("Invalid one-time code", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case .success(let generator):
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    // `try?` rather than propagating: the config already parsed successfully in
                    // `init`, so a failure here would mean the secret bytes themselves are
                    // somehow malformed at code-generation time — not expected, but "show nothing
                    // useful for one tick" beats crashing the whole detail screen over it.
                    let code = (try? generator.code(at: context.date)) ?? "······"
                    let remaining = generator.secondsRemaining(at: context.date)

                    HStack(spacing: 10) {
                        Text(Self.grouped(code))
                            .font(.system(.title3, design: .monospaced))

                        ProgressView(value: Double(remaining), total: Double(generator.config.period))
                            .progressViewStyle(.linear)
                            .frame(width: 40)
                            .tint(remaining <= 5 ? .red : .accentColor)

                        Text("\(remaining)s")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .leading)

                        Button {
                            // `code` is the value already computed above for THIS tick — copying
                            // it rather than calling `generator.code(at:)` again guarantees the
                            // copied string matches what's on screen even if the tap lands right
                            // on a period boundary.
                            clipboard.copy(code)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                        .help("Copy one-time code")
                        .accessibilityLabel("Copy one-time code")
                    }
                }
            }
        }
        .accessibilityIdentifier("detail.totp")
    }

    /// "123456" -> "123 456": splits at the midpoint for the even digit counts that actually occur
    /// (6 and 8 — see `TOTPConfig.digits`'s own doc comment), and after the first half for the
    /// rare odd count (7) rather than declining to group it. Internal (not private) so
    /// `BrowserLogicTests` can verify the grouping without driving a `TimelineView`.
    static func grouped(_ code: String) -> String {
        guard code.count > 3 else { return code }
        let mid = code.index(code.startIndex, offsetBy: (code.count + 1) / 2)
        return "\(code[code.startIndex..<mid]) \(code[mid...])"
    }
}

#Preview {
    TOTPView(
        otpAuthURL: "otpauth://totp/Google:demo@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Google",
        clipboard: ClipboardService()
    )
    .padding()
}

#Preview("Invalid URL") {
    // `host` is "hotp", not "totp" — a guaranteed `TOTPError.notATOTPURL`, exercising the inline
    // error path without relying on a string that merely happens to fail base32 decoding.
    TOTPView(otpAuthURL: "otpauth://hotp/Example?secret=JBSWY3DPEHPK3PXP", clipboard: ClipboardService())
        .padding()
}
