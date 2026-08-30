import Foundation
import KDBXKit

// MARK: - TOTP storage conventions

/// How one KDBX entry stores its TOTP secret.
///
/// KDBX does not specify TOTP at all, so every client invented its own storage and the field names
/// are the only thing distinguishing them. Two are in the wild and this codec must read both:
///
/// 1. **`otp`** — a single string field holding a whole `otpauth://totp/...` URI. This is what
///    current KeePassXC writes and what PassSumo writes for entries that had no TOTP before.
///    Verified empirically against KeePassXC 2.7.12 on 2026-08-29: injecting a lone `otp` field
///    into an entry's XML, re-importing, and running `keepassxc-cli show --totp` produced a live
///    rotating code.
/// 2. **`TOTP Seed` + `TOTP Settings`** — the older split pair (base32 secret; `period;digits`).
///    Written by the old KeePass "TOTP" plugin lineage, still emitted by some Strongbox and
///    keepass2-android files. Verified in the same experiment that KeePassXC 2.7.12 still *reads*
///    this pair and produced the identical code from it.
///
/// **The convention a file already uses is never rewritten into the other one.** Converting a
/// user's `TOTP Seed`/`TOTP Settings` pair into an `otp` field would look harmless — KeePassXC
/// reads both — but it silently breaks every OTHER client that only understands the split form,
/// and the user finds out when a second factor they cannot regenerate stops appearing. Preserving
/// the incoming shape is a data-safety rule, not a stylistic one, so it lives here rather than
/// being reimplemented at each call site.
enum KDBXTOTPConvention: Sendable, Equatable {
    /// One `otp` string field with a complete `otpauth://` URI.
    case otpURL
    /// `TOTP Seed` (+ optional `TOTP Settings`).
    case seedAndSettings
    /// No TOTP fields at all. A newly-added secret is written as `.otpURL`.
    case absent

    static let otpURLKey = "otp"
    static let seedKey = "TOTP Seed"
    static let settingsKey = "TOTP Settings"

    /// Field names that belong to a TOTP convention and must therefore NOT be surfaced as
    /// `VaultEntry.customFields` — they are storage for `otpAuthURL`, not user-authored attributes.
    static let reservedKeys: Set<String> = [otpURLKey, seedKey, settingsKey]

    static func detect(in strings: [KDBX.ProtectedString]) -> KDBXTOTPConvention {
        // `otp` wins when both are present: an entry carrying both is one a modern client already
        // migrated, and the URI is the richer of the two (it can express issuer, algorithm, digits
        // the split form has no room for).
        if strings.contains(where: { $0.key == otpURLKey }) { return .otpURL }
        if strings.contains(where: { $0.key == seedKey }) { return .seedAndSettings }
        return .absent
    }
}

// MARK: - Reading

extension KDBXTOTPConvention {
    /// The entry's TOTP as an `otpauth://` URI, whichever way the file stores it, or `nil` when the
    /// entry has no TOTP (or stores one this codec cannot faithfully express as a URI).
    ///
    /// `label` is used only to build the URI's human-readable label when synthesizing one from the
    /// split form, which has nowhere to record it — pass the entry's title.
    static func readOTPAuthURL(from strings: [KDBX.ProtectedString], label: String) -> String? {
        switch detect(in: strings) {
        case .otpURL:
            return strings.first { $0.key == otpURLKey }?.value.withRevealedString { $0 }

        case .seedAndSettings:
            guard let seed = strings.first(where: { $0.key == seedKey })?
                .value.withRevealedString({ $0 }), !seed.isEmpty
            else { return nil }
            let settings = strings.first { $0.key == settingsKey }?.value.withRevealedString { $0 }
            return synthesizeURL(seed: seed, settings: settings, label: label)

        case .absent:
            return nil
        }
    }

    /// Builds an `otpauth://totp/<label>?secret=…` URI out of the split form.
    ///
    /// Returns `nil` when `TOTP Settings` is present but is not the plain numeric `period;digits`
    /// form — most often KeePassXC's Steam variant, `30;S`, whose 5-character alphabet no
    /// `digits=` parameter can express. Refusing to guess is deliberate: emitting `digits=5` there
    /// would hand the user a URI that generates *wrong codes*, which is worse than showing none.
    /// The underlying fields are still round-tripped untouched on save, so nothing is lost — the
    /// entry simply has no `otpAuthURL` in our model.
    private static func synthesizeURL(seed: String, settings: String?, label: String) -> String? {
        var period = 30
        var digits = 6

        if let settings, !settings.isEmpty {
            let parts = settings.split(separator: ";", omittingEmptySubsequences: false)
            guard let first = parts.first, let parsedPeriod = Int(first), parsedPeriod > 0 else { return nil }
            period = parsedPeriod
            if parts.count > 1 {
                guard let parsedDigits = Int(parts[1]), parsedDigits > 0 else { return nil }
                digits = parsedDigits
            }
        }

        var components = URLComponents()
        components.scheme = "otpauth"
        components.host = "totp"
        // URLComponents percent-encodes the path for us, which matters: titles routinely contain
        // spaces, `/` and non-ASCII, and hand-rolling that encoding is how these URIs get corrupted.
        components.path = "/" + (label.isEmpty ? "PassSumo" : label)
        components.queryItems = [
            URLQueryItem(name: "secret", value: seed),
            URLQueryItem(name: "period", value: String(period)),
            URLQueryItem(name: "digits", value: String(digits)),
        ]
        return components.url?.absoluteString
    }
}

// MARK: - Writing

extension KDBXTOTPConvention {
    /// Applies `otpAuthURL` to `strings`, keeping whatever convention `strings` already used.
    ///
    /// Callers must only reach this when the URL actually changed — see `KDBXEntryStrings`, which
    /// compares against what `readOTPAuthURL` produced from the same base and leaves the fields
    /// byte-identical when nothing was edited.
    static func write(_ otpAuthURL: String?, into strings: [KDBX.ProtectedString]) -> [KDBX.ProtectedString] {
        let convention = detect(in: strings)
        var result = strings

        guard let otpAuthURL, !otpAuthURL.isEmpty else {
            // TOTP removed: drop every field of whichever convention was in use, so no half-record
            // is left behind for another client to resurrect a dead secret from.
            result.removeAll { reservedKeys.contains($0.key) }
            return result
        }

        switch convention {
        case .seedAndSettings:
            if let split = splitURL(otpAuthURL) {
                result.setValue(split.seed, forKey: seedKey, defaultProtected: true)
                result.setValue(split.settings, forKey: settingsKey, defaultProtected: false)
            } else {
                // The new URI carries something the split form cannot hold (no `secret`, or a
                // non-numeric digit count). Converting the entry to `otp` is the ONLY way to keep
                // the user's data; dropping it or writing a truncated pair would lose a second
                // factor. This is the single, documented exception to "never change the
                // convention" — and it is a widening, since KeePassXC reads `otp` too.
                result.removeAll { $0.key == seedKey || $0.key == settingsKey }
                result.setValue(otpAuthURL, forKey: otpURLKey, defaultProtected: true)
            }

        case .otpURL, .absent:
            result.setValue(otpAuthURL, forKey: otpURLKey, defaultProtected: true)
        }

        return result
    }

    /// Decomposes an `otpauth://` URI back into the split form's two field values, or `nil` when it
    /// cannot be expressed that way.
    private static func splitURL(_ url: String) -> (seed: String, settings: String)? {
        guard
            let components = URLComponents(string: url),
            let secret = components.queryItems?.first(where: { $0.name.lowercased() == "secret" })?.value,
            !secret.isEmpty
        else { return nil }

        let query = components.queryItems ?? []
        func intValue(_ name: String, default fallback: Int) -> Int? {
            guard let raw = query.first(where: { $0.name.lowercased() == name })?.value else { return fallback }
            guard let value = Int(raw), value > 0 else { return nil }
            return value
        }
        guard
            let period = intValue("period", default: 30),
            let digits = intValue("digits", default: 6)
        else { return nil }

        return (secret, "\(period);\(digits)")
    }
}

// MARK: - String-field mutation

extension [KDBX.ProtectedString] {
    /// Sets `key` to `value`, preserving the field's existing on-disk protection class if the field
    /// is already there and using `defaultProtected` only when creating it.
    ///
    /// Position is preserved for an existing key rather than the field being removed and re-appended:
    /// KDBX's inner random stream is consumed in document order, and while KDBXKit's writer
    /// recomputes those offsets correctly either way, keeping the order stable also keeps diffs
    /// against another client's copy of the same vault readable.
    mutating func setValue(_ value: String, forKey key: String, defaultProtected: Bool) {
        if let index = firstIndex(where: { $0.key == key }) {
            // Skip the rewrite when nothing changed — this keeps an untouched field's
            // `.lazyInnerCipher` box intact instead of decrypting and re-encrypting it for nothing.
            let unchanged = self[index].value.withRevealedString { $0 == value }
            guard !unchanged else { return }
            self[index].value = self[index].value.reboxed(with: value)
        } else {
            append(KDBX.ProtectedString(
                key: key,
                value: .forNewField(value, protected: defaultProtected)
            ))
        }
    }
}
