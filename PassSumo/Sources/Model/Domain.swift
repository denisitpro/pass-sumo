import Foundation

// MARK: - Domain model
//
// Plain value types describing a fully-decrypted KDBX database. These are the ONLY shapes the
// rest of the app (UI, Store) ever touches — codec-specific concepts (XML nodes, header params,
// KDF salts, …) never leak past `Sources/KDBX`'s `VaultCodec` conformance. See `VaultCodec.swift`
// for how anything a codec reads but `Vault` has no field for still survives a save.

/// One password entry. `password` is plaintext here by design — `Vault` only exists in memory
/// while the database is unlocked; nothing in this file ever writes it to disk or a log.
struct VaultEntry: Identifiable, Sendable, Equatable {
    var id: UUID                       // KDBX entry UUID
    var groupID: UUID?                 // parent group; nil == root
    var title: String
    var username: String
    var password: String               // plaintext while unlocked
    var url: String
    var notes: String
    var otpAuthURL: String?            // raw `otpauth://...` taken from the "otp" string field
    var customFields: [String: String] // all other string fields, minus the 5 standard ones + otp
    var created: Date
    var modified: Date
}

/// A folder in the vault's group tree. Flat storage (`parentID`, not nested arrays) so `Vault`
/// stays a plain `Equatable` value type and the UI can rebuild whatever tree shape it needs
/// (sidebar outline, breadcrumb, …) from `Vault.group(_:)` / `rootGroups` without this type
/// having to anticipate the presentation.
struct VaultGroup: Identifiable, Sendable, Equatable {
    var id: UUID
    var parentID: UUID?
    var name: String
}

/// Fully decrypted database content — everything the app can show or edit. Deliberately does NOT
/// model anything a KDBX file can carry that pass-sumo has no UI for yet (attachments, entry
/// history, custom icons, unknown header/XML data); that unmodeled remainder is the codec's job
/// to round-trip via `DecodedVault.opaque`, not this type's job to represent.
struct Vault: Sendable, Equatable {
    var name: String                          // Meta/DatabaseName
    var groups: [VaultGroup]
    var entries: [VaultEntry]
}

/// What's needed to decrypt or create a database. `keyFile` is carried end-to-end even though v1
/// alpha never sets it (see repo CLAUDE.md) — adding it later must not change this type's shape or
/// every codec/store call site again.
struct VaultCredentials: Sendable {
    var password: String
    var keyFile: Data?                        // nil for v1 alpha; keep the parameter
}

/// Every way opening, decoding, or saving a database can fail. Deliberately flat (no nested
/// `Error` wrapping) so `VaultStore.lastError` is directly `Equatable`-comparable in tests and
/// directly displayable by the UI without unwrapping a chain of causes.
enum VaultError: Error, Equatable {
    case wrongCredentials
    case notAKDBXFile
    case unsupportedVersion(String)
    case corrupted(String)
    case unsupportedFeature(String)
    case io(String)
}

// MARK: - Vault convenience lookups

extension Vault {
    /// Entries filed directly under `groupID`. `nil` means the entries pass-sumo shows at the
    /// vault's top level, outside any group — mirrors `VaultEntry.groupID`'s own "nil == root"
    /// convention, not a special case bolted on here.
    func entries(inGroup groupID: UUID?) -> [VaultEntry] {
        entries.filter { $0.groupID == groupID }
    }

    /// The group with `id`, or `nil` if it isn't (or is no longer) part of this vault.
    func group(_ id: UUID) -> VaultGroup? {
        groups.first { $0.id == id }
    }

    /// Groups with no parent — what a sidebar's outline starts drawing from.
    var rootGroups: [VaultGroup] {
        groups.filter { $0.parentID == nil }
    }
}

// MARK: - Search

private extension String {
    /// Case- and diacritic-insensitive comparison key ("Café" and "cafe" fold to the same string).
    /// `.folding` is Foundation's Unicode-aware normalization — cheaper and more correct than a
    /// hand-rolled `lowercased()` + character-by-character strip, and it's what `NSString`'s own
    /// diacritic-insensitive search uses under the hood.
    var searchNormalized: String {
        folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }
}

extension Vault {
    /// Full-text search across every entry, matching `query` case- and diacritic-insensitively
    /// against title, username, URL, notes, every custom field's name AND value, **and the
    /// password itself**.
    ///
    /// Searching the password is a DELIBERATE product differentiator, not an oversight: KeePassium
    /// (a direct competitor for this exact user — see repo CLAUDE.md's positioning notes)
    /// explicitly does not search the password field. A user who half-remembers a password (or is
    /// hunting down every entry that reuses one they now know is compromised) can find it here;
    /// that use case is worth more than the theoretical risk of a password briefly existing as a
    /// search-index comparison string in memory it already lived in anyway.
    ///
    /// An empty query returns every entry — the natural "no filter applied" behavior a search
    /// field should have when the user hasn't typed anything.
    func search(_ query: String) -> [VaultEntry] {
        let needle = query.searchNormalized
        guard !needle.isEmpty else { return entries }

        return entries.filter { entry in
            if entry.title.searchNormalized.contains(needle) { return true }
            if entry.username.searchNormalized.contains(needle) { return true }
            if entry.url.searchNormalized.contains(needle) { return true }
            if entry.notes.searchNormalized.contains(needle) { return true }
            // See the doc comment above: this line is the differentiator, keep it.
            if entry.password.searchNormalized.contains(needle) { return true }
            for (name, value) in entry.customFields {
                if name.searchNormalized.contains(needle) { return true }
                if value.searchNormalized.contains(needle) { return true }
            }
            return false
        }
    }
}

// MARK: - Sample data

/// Force-unwraps a UUID string literal. Safe ONLY here: every call site below is a hardcoded,
/// visually-inspected-valid literal used for fixture data — never a value that came from a data
/// path (file, network, user input), which is where a force-unwrap would be a real crash risk.
private func fixedUUID(_ string: String) -> UUID {
    UUID(uuidString: string)!
}

/// Parses a fixed ISO-8601 instant for fixture data. Never `Date()`: `Vault.sample` backs both
/// SwiftUI previews and the `-ui-testing` XCUITest fixture (see architecture contract), and both
/// need byte-identical data across runs — a wall-clock timestamp would make any date-based
/// snapshot or accessibility assertion flaky by construction.
private func fixedDate(_ isoString: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    // Every literal below is a valid, inspected ISO-8601 string; `?? .distantPast` only exists to
    // give the function a total (non-optional, non-crashing) signature.
    return formatter.date(from: isoString) ?? .distantPast
}

extension Vault {
    /// Deterministic demo database: 3 groups, 20 entries, fixed UUIDs and dates throughout.
    /// Backs SwiftUI previews (`#Preview`) and the `-ui-testing` launch fixture used by
    /// `PassSumoUITests` — see the architecture contract's Testing section. A couple of entries
    /// carry `otpAuthURL` (valid-looking base32 TOTP secrets) and a couple carry `customFields`,
    /// so previews/UI tests exercise those code paths without needing a real KDBX file.
    static let sample: Vault = {
        let groupEmail = VaultGroup(
            id: fixedUUID("10000000-0000-0000-0000-000000000001"),
            parentID: nil,
            name: "Email"
        )
        let groupWork = VaultGroup(
            id: fixedUUID("10000000-0000-0000-0000-000000000002"),
            parentID: nil,
            name: "Work"
        )
        let groupFinance = VaultGroup(
            id: fixedUUID("10000000-0000-0000-0000-000000000003"),
            parentID: nil,
            name: "Finance"
        )

        // `created`/`modified` are close together for almost every entry (a database that was
        // populated once and rarely edited, which is the common case) — realistic without needing
        // per-entry hand-tuned history.
        func stamped(_ isoString: String) -> (created: Date, modified: Date) {
            let date = fixedDate(isoString)
            return (date, date)
        }

        var entries: [VaultEntry] = []

        // MARK: Email (7)

        let emailDates1 = stamped("2025-11-02T09:14:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("20000000-0000-0000-0000-000000000001"),
            groupID: groupEmail.id,
            title: "Gmail Personal",
            username: "den.larkin@gmail.com",
            password: "Tr0ub4dor&3-gmail",
            url: "https://accounts.google.com",
            notes: "Recovery phone on file. 2FA via authenticator app.",
            // Classic RFC-style demo secret (base32(\"Hello!\\xDE\\xAD\\xBE\\xEF\")), reused across
            // OTP libraries' own docs — deliberately recognizable as a placeholder, not a real seed.
            otpAuthURL: "otpauth://totp/Google:den.larkin@gmail.com?secret=JBSWY3DPEHPK3PXP&issuer=Google&algorithm=SHA1&digits=6&period=30",
            customFields: [:],
            created: emailDates1.created,
            modified: emailDates1.modified
        ))

        let emailDates2 = stamped("2025-11-02T09:20:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("20000000-0000-0000-0000-000000000002"),
            groupID: groupEmail.id,
            title: "iCloud",
            username: "den.larkin@icloud.com",
            password: "Purple-Kayak-77-Bridge",
            url: "https://appleid.apple.com",
            notes: "",
            otpAuthURL: nil,
            customFields: [:],
            created: emailDates2.created,
            modified: emailDates2.modified
        ))

        let emailDates3 = stamped("2025-11-03T18:02:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("20000000-0000-0000-0000-000000000003"),
            groupID: groupEmail.id,
            title: "ProtonMail",
            username: "den.larkin@proton.me",
            password: "Fj29!qzWmL-proton",
            url: "https://mail.proton.me",
            notes: "Privacy-focused backup mailbox.",
            otpAuthURL: nil,
            customFields: [:],
            created: emailDates3.created,
            modified: emailDates3.modified
        ))

        let emailDates4 = stamped("2025-11-04T08:45:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("20000000-0000-0000-0000-000000000004"),
            groupID: groupEmail.id,
            title: "Outlook",
            username: "d.larkin@outlook.com",
            password: "Q7#mVxRt-outlook22",
            url: "https://outlook.live.com",
            notes: "",
            otpAuthURL: nil,
            customFields: [:],
            created: emailDates4.created,
            modified: emailDates4.modified
        ))

        let emailDates5 = stamped("2025-11-04T08:50:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("20000000-0000-0000-0000-000000000005"),
            groupID: groupEmail.id,
            title: "Fastmail",
            username: "den@fastmail.com",
            password: "N4vy-Cobalt-Otter",
            url: "https://www.fastmail.com",
            notes: "",
            otpAuthURL: nil,
            customFields: [:],
            created: emailDates5.created,
            modified: emailDates5.modified
        ))

        let emailDates6 = stamped("2025-11-05T21:11:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("20000000-0000-0000-0000-000000000006"),
            groupID: groupEmail.id,
            title: "Yahoo Mail",
            username: "denlarkin@yahoo.com",
            password: "Sunset-88-Harbor!",
            url: "https://login.yahoo.com",
            notes: "Old inbox, kept for a couple of newsletter subscriptions.",
            otpAuthURL: nil,
            customFields: [:],
            created: emailDates6.created,
            modified: emailDates6.modified
        ))

        let emailDates7 = stamped("2025-11-06T10:30:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("20000000-0000-0000-0000-000000000007"),
            groupID: groupEmail.id,
            title: "Zoho Mail",
            username: "den.larkin@zohomail.com",
            password: "Gr4nite-Falcon-09",
            url: "https://mail.zoho.com",
            notes: "",
            otpAuthURL: nil,
            customFields: ["Recovery Email": "den.recovery@zohomail.com"],
            created: emailDates7.created,
            modified: emailDates7.modified
        ))

        // MARK: Work (7)

        let workDates1 = stamped("2025-10-14T13:05:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("20000000-0000-0000-0000-000000000008"),
            groupID: groupWork.id,
            title: "GitHub",
            username: "denisitpro",
            password: "8vC!zQ2mLp-github",
            url: "https://github.com/login",
            notes: "",
            otpAuthURL: "otpauth://totp/GitHub:denisitpro?secret=KRSXG5CTMVRXEZLU&issuer=GitHub&algorithm=SHA1&digits=6&period=30",
            customFields: ["SSH Key Fingerprint": "SHA256:tZ4kR3F1n9pLwQxM7vC2sB8hY5aU0eD6jK1oI3rT9nQ"],
            created: workDates1.created,
            modified: workDates1.modified
        ))

        let workDates2 = stamped("2025-10-14T13:20:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("20000000-0000-0000-0000-000000000009"),
            groupID: groupWork.id,
            title: "Atlassian (Jira)",
            username: "den.larkin@cointelegraph.com",
            password: "R3d-Kestrel-Path41",
            url: "https://id.atlassian.com",
            notes: "",
            otpAuthURL: nil,
            customFields: [:],
            created: workDates2.created,
            modified: workDates2.modified
        ))

        let workDates3 = stamped("2025-10-15T09:00:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("2000000a-0000-0000-0000-00000000000a"),
            groupID: groupWork.id,
            title: "Slack",
            username: "den.larkin@cointelegraph.com",
            password: "Bl4ck-Anchor-Dune7",
            url: "https://cointelegraph.slack.com",
            notes: "",
            otpAuthURL: nil,
            customFields: [:],
            created: workDates3.created,
            modified: workDates3.modified
        ))

        let workDates4 = stamped("2025-10-16T16:40:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("2000000b-0000-0000-0000-00000000000b"),
            groupID: groupWork.id,
            title: "AWS Console",
            username: "den.larkin",
            password: "Xk9#mQ2vTz-aws!",
            url: "https://console.aws.amazon.com",
            notes: "IAM user, not root — root creds are not in this vault.",
            otpAuthURL: nil,
            customFields: ["Account ID": "482910337201", "Role": "Admin"],
            created: workDates4.created,
            modified: workDates4.modified
        ))

        let workDates5 = stamped("2025-10-17T11:25:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("2000000c-0000-0000-0000-00000000000c"),
            groupID: groupWork.id,
            title: "Google Workspace Admin",
            username: "admin@cointelegraph.com",
            password: "Vw8!zRp4-workspace",
            url: "https://admin.google.com",
            notes: "",
            otpAuthURL: nil,
            customFields: [:],
            created: workDates5.created,
            modified: workDates5.modified
        ))

        let workDates6 = stamped("2025-10-18T15:00:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("2000000d-0000-0000-0000-00000000000d"),
            groupID: groupWork.id,
            title: "Figma",
            username: "den.larkin@cointelegraph.com",
            password: "Teal-Osprey-63!",
            url: "https://www.figma.com/login",
            notes: "",
            otpAuthURL: nil,
            customFields: [:],
            created: workDates6.created,
            modified: workDates6.modified
        ))

        let workDates7 = stamped("2025-10-19T08:10:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("2000000e-0000-0000-0000-00000000000e"),
            groupID: groupWork.id,
            title: "Notion",
            username: "den.larkin@cointelegraph.com",
            password: "Amber-Trellis-902",
            url: "https://www.notion.so/login",
            notes: "",
            otpAuthURL: nil,
            customFields: [:],
            created: workDates7.created,
            modified: workDates7.modified
        ))

        // MARK: Finance (6)

        let financeDates1 = stamped("2025-09-01T07:30:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("2000000f-0000-0000-0000-00000000000f"),
            groupID: groupFinance.id,
            title: "Chase Bank",
            username: "denlarkin",
            password: "Chase!Willow-2025",
            url: "https://secure.chase.com",
            notes: "Primary checking + savings.",
            otpAuthURL: nil,
            customFields: [:],
            created: financeDates1.created,
            modified: financeDates1.modified
        ))

        let financeDates2 = stamped("2025-09-02T12:00:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("20000010-0000-0000-0000-000000000010"),
            groupID: groupFinance.id,
            title: "Fidelity Investments",
            username: "den.larkin",
            password: "Fj3#Marlin-Fidelity",
            url: "https://login.fidelity.com",
            notes: "401k rollover + brokerage.",
            otpAuthURL: nil,
            customFields: [:],
            created: financeDates2.created,
            modified: financeDates2.modified
        ))

        let financeDates3 = stamped("2025-09-03T19:45:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("20000011-0000-0000-0000-000000000011"),
            groupID: groupFinance.id,
            title: "Coinbase",
            username: "den.larkin@cointelegraph.com",
            password: "Zx7!Quartz-Coinbase",
            url: "https://www.coinbase.com/signin",
            notes: "",
            otpAuthURL: "otpauth://totp/Coinbase:den.larkin%40cointelegraph.com?secret=MFRGGZDFMZTWQ2LK&issuer=Coinbase&algorithm=SHA1&digits=6&period=30",
            customFields: [:],
            created: financeDates3.created,
            modified: financeDates3.modified
        ))

        let financeDates4 = stamped("2025-09-04T14:15:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("20000012-0000-0000-0000-000000000012"),
            groupID: groupFinance.id,
            title: "PayPal",
            username: "den.larkin@gmail.com",
            password: "P4yPal-Cinder-19",
            url: "https://www.paypal.com/signin",
            notes: "",
            otpAuthURL: nil,
            customFields: [:],
            created: financeDates4.created,
            modified: financeDates4.modified
        ))

        let financeDates5 = stamped("2025-09-05T10:05:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("20000013-0000-0000-0000-000000000013"),
            groupID: groupFinance.id,
            title: "Wise",
            username: "den.larkin@gmail.com",
            password: "Wise-Petrel-4471",
            url: "https://wise.com/login",
            notes: "USD/EUR transfers for contractor payments.",
            otpAuthURL: nil,
            customFields: [:],
            created: financeDates5.created,
            modified: financeDates5.modified
        ))

        let financeDates6 = stamped("2025-09-06T17:50:00Z")
        entries.append(VaultEntry(
            id: fixedUUID("20000014-0000-0000-0000-000000000014"),
            groupID: groupFinance.id,
            title: "Vanguard",
            username: "denlarkin",
            password: "V4ngu4rd-Meridian",
            url: "https://investor.vanguard.com",
            notes: "IRA.",
            otpAuthURL: nil,
            customFields: [:],
            created: financeDates6.created,
            modified: financeDates6.modified
        ))

        return Vault(
            name: "Demo Vault",
            groups: [groupEmail, groupWork, groupFinance],
            entries: entries
        )
    }()
}
