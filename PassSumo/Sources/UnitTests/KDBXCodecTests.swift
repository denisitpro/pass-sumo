import KDBXKit
import XCTest
@testable import PassSumo

/// Tests for the real KDBX codec (`Sources/KDBX`), against real `.kdbx` files.
///
/// Two independent bodies of evidence, because neither alone is enough:
///
/// - **Read direction** — files under `Fixtures/` written by `keepassxc-cli` 2.7.12, plus two KDBX
///   4.1 databases redistributed from KDBXKit's own test resources. The KDBX 4 ones are the weaker
///   evidence and are labelled as such where they are used: they came from the same project as the
///   parser, so they cannot catch a bug the library agrees with itself about. `keepassxc-cli`
///   cannot create a KDBX 4 file at all (see `Fixtures/README.md`), which is why there is no
///   independent KDBX 4 read fixture.
/// - **Write direction** — the strong evidence, and it depends on nothing of ours: our codec writes
///   a file, and `keepassxc-cli` (which *reads* KDBX 4 perfectly well) is asked whether it opens
///   and what is in it.
final class KDBXCodecTests: XCTestCase {
    private let codec = KDBXKitCodec()

    // Published test passwords. These files ship in the repo and contain no real secrets.
    private static let kpxcPassword = "correct horse battery staple"
    private static let kdbxKitPassword = "123"

    private func credentials(_ password: String, keyFile: Data? = nil) -> VaultCredentials {
        VaultCredentials(password: password, keyFile: keyFile)
    }

    /// Fixtures reach the bundle through a folder reference (see `project.yml`), so the directory
    /// structure under `Fixtures/` is preserved and addressed with `subdirectory:`.
    private func fixture(_ name: String, subdirectory: String = "Fixtures") throws -> Data {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: name, withExtension: "kdbx", subdirectory: subdirectory),
            "fixture \(subdirectory)/\(name).kdbx is not in the test bundle — check the "
                + "PassSumoUnitTests `sources` folder reference in project.yml"
        )
        return try Data(contentsOf: url)
    }

    // MARK: - Reading

    /// A KDBX 4.1 / Argon2id / AES-256 database opens and yields its content.
    ///
    /// Weak evidence by construction: this fixture is KDBXKit's own. It is here because it is the
    /// only KDBX 4 file we have from outside this repo at all, and because a failure would still be
    /// a real failure — it just cannot prove correctness on its own. `testWrittenFileOpensInKeePassXC`
    /// is the assertion that carries the weight.
    func testOpensKDBX4ArgonAESDatabase() throws {
        let decoded = try codec.decode(
            fileData: try fixture("simple-argon2id-aes256", subdirectory: "Fixtures/kdbxkit"),
            credentials: credentials(Self.kdbxKitPassword)
        )

        XCTAssertEqual(decoded.vault.name, "test2")
        XCTAssertEqual(decoded.vault.entries.map(\.title), ["hello"])
        // The KDBX root group is a container, not a folder — it maps onto the `nil` parent
        // sentinel, so a database with no user-made folders has zero `VaultGroup`s.
        XCTAssertEqual(decoded.vault.groups.count, 0)
        XCTAssertEqual(decoded.vault.entries.first?.groupID, nil)
    }

    /// The nested-group / multi-entry shape, including non-ASCII content.
    func testOpensKDBX4RichDatabaseWithNestedGroups() throws {
        let decoded = try codec.decode(
            fileData: try fixture("kpxc-rich", subdirectory: "Fixtures/kdbxkit"),
            credentials: credentials(Self.kdbxKitPassword)
        )
        let vault = decoded.vault

        XCTAssertEqual(Set(vault.groups.map(\.name)), ["Work", "Servers"])
        let work = try XCTUnwrap(vault.groups.first { $0.name == "Work" })
        let servers = try XCTUnwrap(vault.groups.first { $0.name == "Servers" })
        XCTAssertNil(work.parentID, "Work is a top-level folder")
        XCTAssertEqual(servers.parentID, work.id, "Servers is nested inside Work")

        XCTAssertEqual(
            Set(vault.entries.map(\.title)),
            ["hello", "GitHub", "Unicode 测试 🌍", "Prod"]
        )
        // Round-tripping non-ASCII is not decoration: a UTF-8 bug here corrupts real vaults.
        let unicode = try XCTUnwrap(vault.entries.first { $0.title == "Unicode 测试 🌍" })
        XCTAssertEqual(unicode.notes, "汉字 + 🌸 + ñ")
        XCTAssertEqual(unicode.username, "用户")

        let prod = try XCTUnwrap(vault.entries.first { $0.title == "Prod" })
        XCTAssertEqual(prod.groupID, servers.id, "entries carry the id of the group holding them")
    }

    /// KeePassXC's own output — a KDBX 3.1 file, since `keepassxc-cli` cannot produce anything else.
    /// This asserts what is ACTUALLY true (KDBXKit reads 3.1), rather than assuming a rejection.
    func testOpensKeePassXCWrittenKDBX31Database() throws {
        let decoded = try codec.decode(
            fileData: try fixture("kdbx3-aeskdf-aes256"),
            credentials: credentials(Self.kpxcPassword)
        )
        let vault = decoded.vault

        XCTAssertEqual(Set(vault.groups.map(\.name)), ["Email", "Work", "Finance"])
        XCTAssertTrue(vault.entries.contains { $0.title == "Gmail" })
        XCTAssertTrue(vault.entries.contains { $0.title == "Почта 📧" })

        let vpn = try XCTUnwrap(vault.entries.first { $0.title == "VPN Access" })
        // Custom string fields land in `customFields` regardless of whether the file marked them
        // memory-protected — protection is an on-disk property, not part of the domain model.
        XCTAssertEqual(Set(vpn.customFields.keys), ["Recovery Code", "Security Answer"])
    }

    func testWrongPasswordThrowsWrongCredentialsAndLeaksNothing() throws {
        let data = try fixture("kdbx3-aeskdf-aes256")
        let wrongPassword = "definitely-not-the-password"

        XCTAssertThrowsError(
            try codec.decode(fileData: data, credentials: credentials(wrongPassword))
        ) { error in
            guard let vaultError = error as? VaultError else {
                return XCTFail("expected VaultError, got \(type(of: error))")
            }
            XCTAssertEqual(vaultError, .wrongCredentials)
            // The error must not become a channel for the thing it is about. `.wrongCredentials`
            // carries no payload precisely so it cannot; assert on the rendered string too, since
            // that is what would reach a log or a crash report.
            let rendered = String(describing: vaultError)
            XCTAssertFalse(rendered.contains(wrongPassword))
            XCTAssertFalse(rendered.contains(Self.kpxcPassword))
        }
    }

    /// A file with a flipped byte must be reported as damaged — and, more importantly, must not
    /// take the process down with it. An uncatchable trap on malformed input is the crash class the
    /// pinned KDBXKit revision exists to eliminate (see project.yml), so this test's real assertion
    /// is that it reaches its own last line at all.
    func testCorruptedFileThrowsCorruptedWithoutTrapping() throws {
        let data = try fixture("kdbx3-corrupted")

        XCTAssertThrowsError(
            try codec.decode(fileData: data, credentials: credentials(Self.kpxcPassword))
        ) { error in
            guard case .corrupted = error as? VaultError else {
                return XCTFail("expected .corrupted, got \(error)")
            }
        }
    }

    /// Malformed headers of the shapes that historically trapped: truncation at every prefix
    /// length, and a length field rewritten to values that overflow or go negative when read as
    /// signed. Every one must throw; none may abort the process.
    func testMalformedHeadersThrowWithoutTrapping() throws {
        let good = try fixture("simple-argon2id-aes256", subdirectory: "Fixtures/kdbxkit")

        var candidates: [Data] = []
        candidates.append(Data())
        candidates.append(Data([0x00]))
        for length in stride(from: 4, through: 256, by: 4) {
            candidates.append(good.prefix(length))
        }
        // Rewrite the 4-byte length of the FIRST header field (offset 12 is its type byte, 13..16
        // its UInt32 length) to values a signed reader sees as huge or negative.
        for pattern in [Data([0xFF, 0xFF, 0xFF, 0xFF]), Data([0x00, 0x00, 0x00, 0x80])] {
            var mutated = good
            mutated.replaceSubrange(13 ..< 17, with: pattern)
            candidates.append(mutated)
        }

        for (index, candidate) in candidates.enumerated() {
            XCTAssertThrowsError(
                try codec.decode(fileData: candidate, credentials: credentials(Self.kdbxKitPassword)),
                "malformed input #\(index) (\(candidate.count) bytes) decoded instead of throwing"
            ) { error in
                XCTAssertTrue(error is VaultError, "leaked a non-VaultError: \(error)")
            }
        }
    }

    func testNonKDBXDataIsReportedAsNotAKDBXFile() throws {
        let data = Data("this is a text file, not a password database".utf8)
        XCTAssertThrowsError(
            try codec.decode(fileData: data, credentials: credentials("whatever"))
        ) { error in
            XCTAssertEqual(error as? VaultError, .notAKDBXFile)
        }
    }

    // MARK: - Argon2 v1.0

    /// KDBXKit's Argon2 binding hard-codes version 0x13, so a v1.0 database would derive the wrong
    /// key from the right password. At the pinned revision the header parse rejects v1.0 before
    /// that can happen, which turns it into a generic "header is damaged" — accurate to the parser,
    /// useless to the user, and indistinguishable from a genuinely broken file.
    ///
    /// The fixture is built here rather than shipped, because no tool available on this machine can
    /// write an Argon2 v1.0 database: `keepassxc-cli` cannot even write KDBX 4. Instead a real
    /// KDBX 4 header's KDF parameter `V` is patched from `0x13` to `0x10` in place. That is a
    /// legitimate construction — `V` lives in the CLEARTEXT outer header, and the header parse
    /// (which is what rejects it) runs before the header digest is checked, so the patch reaches
    /// exactly the code path a real v1.0 file would.
    func testArgon2Version1_0IsReportedAsUnsupportedRatherThanWrongPassword() throws {
        let good = try fixture("simple-argon2id-aes256", subdirectory: "Fixtures/kdbxkit")
        let patched = try XCTUnwrap(
            Self.patchingArgon2Version(in: good, to: 0x10),
            "could not find the Argon2 `V` parameter in the fixture header"
        )

        XCTAssertTrue(
            KDBXArgon2VersionProbe.detectsArgon2Version1_0(in: patched),
            "the probe must recognise the patched header"
        )
        XCTAssertFalse(
            KDBXArgon2VersionProbe.detectsArgon2Version1_0(in: good),
            "and must NOT fire on the unpatched v1.3 original"
        )

        XCTAssertThrowsError(
            try codec.decode(fileData: patched, credentials: credentials(Self.kdbxKitPassword))
        ) { error in
            guard case let .unsupportedFeature(message) = error as? VaultError else {
                return XCTFail("expected .unsupportedFeature, got \(error)")
            }
            // The whole point is that the user is told what to do, and is NOT told their password
            // is wrong.
            XCTAssertTrue(message.contains("Argon2 version 1.0"))
            XCTAssertTrue(message.contains("KeePassXC"))
        }
    }

    /// Finds the VariantDictionary record `<0x04><nameLen=1>"V"<valueLen=4><version LE>` in the
    /// cleartext header and rewrites its value.
    private static func patchingArgon2Version(in data: Data, to version: UInt8) -> Data? {
        let needle: [UInt8] = [
            0x04,                          // value type: UInt32
            0x01, 0x00, 0x00, 0x00,        // name length (Int32 LE) = 1
            0x56,                          // "V"
            0x04, 0x00, 0x00, 0x00,        // value length (Int32 LE) = 4
            0x13, 0x00, 0x00, 0x00,        // Argon2 version 1.3
        ]
        let bytes = Array(data.prefix(4096))
        guard bytes.count > needle.count else { return nil }
        for start in 0 ... (bytes.count - needle.count) where Array(bytes[start ..< start + needle.count]) == needle {
            var patched = data
            patched[data.startIndex + start + needle.count - 4] = version
            return patched
        }
        return nil
    }

    // MARK: - Lossless round trip

    /// The single most important test in the project.
    ///
    /// Opens a KeePassXC-written database that carries an attachment, entry history and
    /// `Meta/CustomData` — none of which `Vault` models — changes ONE entry's password, saves, and
    /// reopens. The changed password must be there, and every unmodelled thing must still be there
    /// too. The assertions go through the codec's own opaque state rather than `Vault`, because
    /// `Vault` cannot see any of it; that is the entire point.
    func testRoundTripPreservesAttachmentHistoryAndCustomData() throws {
        let original = try fixture("kpxc-rich", subdirectory: "Fixtures/kdbxkit")
        let creds = credentials(Self.kdbxKitPassword)
        let decoded = try codec.decode(fileData: original, credentials: creds)

        let before = try XCTUnwrap(Self.kdbxContent(of: decoded))
        let beforeGitHub = try XCTUnwrap(Self.entry(titled: "GitHub", in: before))
        XCTAssertFalse(beforeGitHub.binaries.isEmpty, "fixture precondition: GitHub has an attachment")
        XCTAssertFalse(beforeGitHub.history.isEmpty, "fixture precondition: GitHub has history")
        XCTAssertFalse(before.database.meta.customData.isEmpty, "fixture precondition: Meta/CustomData")

        var vault = decoded.vault
        let index = try XCTUnwrap(vault.entries.firstIndex { $0.title == "GitHub" })
        let newPassword = "rotated-2026-08-29"
        XCTAssertNotEqual(vault.entries[index].password, newPassword)
        vault.entries[index].password = newPassword

        let saved = try codec.encode(vault, credentials: creds, origin: decoded)
        let reopened = try codec.decode(fileData: saved, credentials: creds)

        // 1. The edit landed.
        let reopenedGitHub = try XCTUnwrap(reopened.vault.entries.first { $0.title == "GitHub" })
        XCTAssertEqual(reopenedGitHub.password, newPassword)

        // 2. Nothing else about the vault moved.
        XCTAssertEqual(Set(reopened.vault.entries.map(\.title)), Set(decoded.vault.entries.map(\.title)))
        XCTAssertEqual(Set(reopened.vault.groups.map(\.name)), Set(decoded.vault.groups.map(\.name)))
        XCTAssertEqual(reopened.vault.name, decoded.vault.name)

        // 3. The unmodelled data survived — attachment bytes, every history snapshot, and the
        //    `Meta/CustomData` items no part of pass-sumo understands.
        let after = try XCTUnwrap(Self.kdbxContent(of: reopened))
        let afterGitHub = try XCTUnwrap(Self.entry(titled: "GitHub", in: after))

        XCTAssertEqual(afterGitHub.binaries, beforeGitHub.binaries, "attachment reference changed")
        XCTAssertEqual(after.innerHeader.binaryContent, before.innerHeader.binaryContent,
                       "attachment CONTENT changed — the binary pool must survive byte for byte")
        XCTAssertEqual(afterGitHub.history.count, beforeGitHub.history.count, "history lost snapshots")
        XCTAssertEqual(
            afterGitHub.history.map { Self.string("Password", in: $0) },
            beforeGitHub.history.map { Self.string("Password", in: $0) },
            "history snapshots must keep their own old passwords, not inherit the new one"
        )
        XCTAssertEqual(
            after.database.meta.customData.map(\.key).sorted(),
            before.database.meta.customData.map(\.key).sorted()
        )
        XCTAssertEqual(
            after.database.meta.customData.first { $0.key == "KPXC_RANDOM_SLUG" }?.value,
            before.database.meta.customData.first { $0.key == "KPXC_RANDOM_SLUG" }?.value,
            "another client's custom data must come back byte-identical"
        )

        // 4. Untouched entries keep their unmodelled per-entry state too.
        let beforeProd = try XCTUnwrap(Self.entry(titled: "Prod", in: before))
        let afterProd = try XCTUnwrap(Self.entry(titled: "Prod", in: after))
        XCTAssertEqual(afterProd.autoType, beforeProd.autoType)
        XCTAssertEqual(afterProd.tags, beforeProd.tags)
        XCTAssertEqual(afterProd.iconID, beforeProd.iconID)
        XCTAssertEqual(afterProd.times?.creationTime, beforeProd.times?.creationTime)
    }

    /// Two consecutive saves of the same content must not produce the same bytes. This is the
    /// regression guard for the defect that forced the exact-revision pin: an inner random-stream
    /// key reused across saves means both files' protected fields are XORed with the SAME keystream,
    /// and anyone holding both recovers the plaintext without the password.
    func testConsecutiveSavesProduceDifferentCiphertext() throws {
        let creds = credentials(Self.kdbxKitPassword)
        let decoded = try codec.decode(
            fileData: try fixture("simple-argon2id-aes256", subdirectory: "Fixtures/kdbxkit"),
            credentials: creds
        )
        let first = try codec.encode(decoded.vault, credentials: creds, origin: decoded)
        let second = try codec.encode(decoded.vault, credentials: creds, origin: decoded)

        XCTAssertNotEqual(first, second, "salts/nonces/inner key were not regenerated on save")
        // …and both must still open, i.e. the difference is fresh randomness, not damage.
        XCTAssertEqual(try codec.decode(fileData: first, credentials: creds).vault, decoded.vault)
        XCTAssertEqual(try codec.decode(fileData: second, credentials: creds).vault, decoded.vault)
    }

    // MARK: - TOTP

    /// Both conventions read into `otpAuthURL`, and a save leaves each entry storing its secret the
    /// way it already did. Silently migrating a `TOTP Seed`/`TOTP Settings` pair to an `otp` field
    /// would keep working in KeePassXC and break every client that only speaks the split form —
    /// which is why "preserve the convention" is asserted here and not just documented.
    func testTOTPConventionsAreReadAndPreservedAcrossASave() throws {
        let creds = credentials(Self.kpxcPassword)
        let decoded = try codec.decode(
            fileData: try fixture("kdbx3-totp-conventions", subdirectory: "Fixtures/totp"),
            credentials: creds
        )

        let urlStyle = try XCTUnwrap(decoded.vault.entries.first { $0.title == "OtpURLStyle" })
        let splitStyle = try XCTUnwrap(decoded.vault.entries.first { $0.title == "SeedSettingsStyle" })
        XCTAssertTrue(try XCTUnwrap(urlStyle.otpAuthURL).hasPrefix("otpauth://totp/"))
        // The split form has no URI to read, so one is synthesized from the seed and settings.
        let synthesized = try XCTUnwrap(splitStyle.otpAuthURL)
        XCTAssertTrue(synthesized.contains("secret=JBSWY3DPEHPK3PXP"))
        XCTAssertTrue(synthesized.contains("period=30"))
        XCTAssertTrue(synthesized.contains("digits=6"))

        // Neither convention's storage fields may show up as user-visible custom attributes.
        XCTAssertTrue(urlStyle.customFields.isEmpty)
        XCTAssertTrue(splitStyle.customFields.isEmpty)

        // Edit something ELSE on the split-form entry, so the save is a realistic one.
        var vault = decoded.vault
        let index = try XCTUnwrap(vault.entries.firstIndex { $0.title == "SeedSettingsStyle" })
        vault.entries[index].password = "changed-password"

        let saved = try codec.encode(vault, credentials: creds, origin: decoded)
        let reopened = try codec.decode(fileData: saved, credentials: creds)
        let after = try XCTUnwrap(Self.kdbxContent(of: reopened))

        let afterURLStyle = try XCTUnwrap(Self.entry(titled: "OtpURLStyle", in: after))
        XCTAssertEqual(Self.string("otp", in: afterURLStyle), urlStyle.otpAuthURL)
        XCTAssertNil(Self.string("TOTP Seed", in: afterURLStyle))

        let afterSplit = try XCTUnwrap(Self.entry(titled: "SeedSettingsStyle", in: after))
        XCTAssertEqual(Self.string("TOTP Seed", in: afterSplit), "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(Self.string("TOTP Settings", in: afterSplit), "30;6")
        XCTAssertNil(Self.string("otp", in: afterSplit), "the split form must NOT be migrated to `otp`")
        XCTAssertEqual(Self.string("Password", in: afterSplit), "changed-password")
    }

    /// A TOTP added to an entry that had none is written as `otp` + `otpauth://` URI — the
    /// convention current KeePassXC uses.
    func testNewTOTPIsWrittenAsAnOTPURLField() throws {
        let creds = credentials(Self.kdbxKitPassword)
        let decoded = try codec.decode(
            fileData: try fixture("simple-argon2id-aes256", subdirectory: "Fixtures/kdbxkit"),
            credentials: creds
        )

        var vault = decoded.vault
        let url = "otpauth://totp/hello?secret=JBSWY3DPEHPK3PXP&period=30&digits=6"
        vault.entries[0].otpAuthURL = url

        let saved = try codec.encode(vault, credentials: creds, origin: decoded)
        let reopened = try codec.decode(fileData: saved, credentials: creds)

        XCTAssertEqual(reopened.vault.entries[0].otpAuthURL, url)
        let entry = try XCTUnwrap(Self.entry(titled: "hello", in: try XCTUnwrap(Self.kdbxContent(of: reopened))))
        XCTAssertEqual(Self.string("otp", in: entry), url)
    }

    // MARK: - Editing

    func testAddedRenamedAndDeletedContentIsApplied() throws {
        let creds = credentials(Self.kdbxKitPassword)
        let decoded = try codec.decode(
            fileData: try fixture("kpxc-rich", subdirectory: "Fixtures/kdbxkit"),
            credentials: creds
        )

        var vault = decoded.vault
        let newGroup = VaultGroup(id: UUID(), parentID: nil, name: "Added Folder")
        vault.groups.append(newGroup)
        vault.entries.append(VaultEntry(
            id: UUID(),
            groupID: newGroup.id,
            title: "Added Entry",
            username: "someone",
            password: "s3cret",
            url: "https://example.invalid",
            notes: "",
            otpAuthURL: nil,
            customFields: ["Recovery Code": "abcd-efgh"],
            created: Date(),
            modified: Date()
        ))
        let removed = try XCTUnwrap(vault.entries.first { $0.title == "Prod" })
        vault.entries.removeAll { $0.id == removed.id }

        let reopened = try codec.decode(
            fileData: try codec.encode(vault, credentials: creds, origin: decoded),
            credentials: creds
        )

        XCTAssertTrue(reopened.vault.groups.contains { $0.name == "Added Folder" })
        let added = try XCTUnwrap(reopened.vault.entries.first { $0.title == "Added Entry" })
        XCTAssertEqual(added.password, "s3cret")
        XCTAssertEqual(added.customFields["Recovery Code"], "abcd-efgh")
        XCTAssertFalse(reopened.vault.entries.contains { $0.title == "Prod" })

        // A deletion has to leave a tombstone, or the next KeePassXC merge resurrects the entry
        // as one "the other replica has and this one is missing".
        let content = try XCTUnwrap(Self.kdbxContent(of: reopened))
        XCTAssertTrue(
            content.database.root.deletedObjects.contains { $0.uuid == removed.id },
            "deleting an entry must record a DeletedObjects tombstone"
        )
    }

    // MARK: - Creating

    func testMakeEmptyProducesASaveableAndReopenableDatabase() throws {
        let creds = credentials("a-brand-new-master-password")
        let created = try codec.makeEmpty(name: "Fresh Vault", credentials: creds)

        XCTAssertEqual(created.vault.name, "Fresh Vault")
        XCTAssertTrue(created.vault.entries.isEmpty)
        XCTAssertTrue(created.vault.groups.isEmpty, "the KDBX root group is not a user-visible folder")

        let saved = try codec.encode(created.vault, credentials: creds, origin: created)
        let reopened = try codec.decode(fileData: saved, credentials: creds)
        XCTAssertEqual(reopened.vault.name, "Fresh Vault")

        XCTAssertThrowsError(try codec.decode(fileData: saved, credentials: credentials("wrong"))) {
            XCTAssertEqual($0 as? VaultError, .wrongCredentials)
        }
    }

    // MARK: - Stable database identity

    /// The Keychain/Touch ID layer needs an identifier that survives saves, moves and iCloud
    /// relocation. Opening a vault must NEVER mint one as a side effect — that would make a read
    /// dirty the user's file.
    func testDatabaseIDIsAbsentUntilExplicitlyAssignedAndThenSurvivesASave() throws {
        let creds = credentials(Self.kdbxKitPassword)
        let decoded = try codec.decode(
            fileData: try fixture("simple-argon2id-aes256", subdirectory: "Fixtures/kdbxkit"),
            credentials: creds
        )
        XCTAssertNil(codec.databaseID(of: decoded), "decode must not assign an id")

        let assigned = try XCTUnwrap(codec.assigningDatabaseID(to: decoded))
        XCTAssertEqual(codec.databaseID(of: assigned.vault), assigned.id)
        // Idempotent: asking again returns the same id rather than a second one.
        let again = try XCTUnwrap(codec.assigningDatabaseID(to: assigned.vault))
        XCTAssertEqual(again.id, assigned.id)

        let saved = try codec.encode(assigned.vault.vault, credentials: creds, origin: assigned.vault)
        let reopened = try codec.decode(fileData: saved, credentials: creds)
        XCTAssertEqual(codec.databaseID(of: reopened), assigned.id)

        // It is stored where other clients preserve it, and a further save does not disturb it.
        let content = try XCTUnwrap(Self.kdbxContent(of: reopened))
        XCTAssertEqual(
            content.database.meta.customData.first { $0.key == KDBXKitCodec.databaseIDKey }?.value,
            assigned.id.uuidString
        )
        let resaved = try codec.decode(
            fileData: try codec.encode(reopened.vault, credentials: creds, origin: reopened),
            credentials: creds
        )
        XCTAssertEqual(codec.databaseID(of: resaved), assigned.id, "the id must not change on save")
    }

    // MARK: - External interop

    /// The strong evidence: a file OUR codec wrote, opened by KeePassXC.
    ///
    /// Nothing here trusts KDBXKit — `keepassxc-cli` is an independent implementation, and it reads
    /// KDBX 4 even though it cannot create one. Skips (rather than fails) when the binary is absent
    /// so the suite still passes on a machine without KeePassXC, and also when the host process is
    /// sandboxed and cannot spawn a subprocess at all (which is the case under `make test-signed`,
    /// but not under `make test`, whose host is unsigned and therefore unsandboxed).
    func testWrittenFileOpensInKeePassXC() throws {
        let cli = try Self.keePassXCCLIOrSkip()

        let password = "interop-test-password"
        let creds = credentials(password)
        var created = try codec.makeEmpty(name: "Interop Vault", credentials: creds)

        let group = VaultGroup(id: UUID(), parentID: nil, name: "Work")
        created.vault.groups = [group]
        created.vault.entries = [
            VaultEntry(
                id: UUID(), groupID: group.id, title: "GitHub", username: "denisitpro",
                password: "hunter2-but-longer", url: "https://github.com/login", notes: "written by PassSumo",
                otpAuthURL: "otpauth://totp/GitHub:denisitpro?secret=JBSWY3DPEHPK3PXP&period=30&digits=6",
                customFields: [:], created: Date(), modified: Date()
            ),
            VaultEntry(
                id: UUID(), groupID: nil, title: "Root Level", username: "u", password: "p",
                url: "", notes: "", otpAuthURL: nil, customFields: [:],
                created: Date(), modified: Date()
            ),
        ]

        let saved = try codec.encode(created.vault, credentials: creds, origin: created)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("passsumo-interop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("written-by-passsumo.kdbx")
        try saved.write(to: path)

        // 1. The repo's own interop gate, if it is there — a single pass/fail verdict.
        if let script = Self.interopCheckScript() {
            let result = try Self.run("/bin/bash", [script.path, path.path, password])
            XCTAssertEqual(result.status, 0, "interop-check.sh rejected our file:\n\(result.output)")
        }

        // 2. And the specific content, so a green run means more than "it decrypted".
        let listing = try Self.run(cli, ["ls", "-R", path.path], stdin: password + "\n")
        XCTAssertEqual(listing.status, 0, "keepassxc-cli could not open our file:\n\(listing.output)")
        XCTAssertTrue(listing.output.contains("Root Level"), "missing root entry:\n\(listing.output)")
        XCTAssertTrue(listing.output.contains("Work/"), "missing group:\n\(listing.output)")
        XCTAssertTrue(listing.output.contains("GitHub"), "missing grouped entry:\n\(listing.output)")

        // 3. KeePassXC generating a live code from the TOTP we wrote is the only proof that our
        //    `otp` field is genuinely the convention it understands, rather than a string that
        //    merely looks right.
        let totp = try Self.run(cli, ["show", "-t", path.path, "/Work/GitHub"], stdin: password + "\n")
        XCTAssertEqual(totp.status, 0, "keepassxc-cli could not read our TOTP:\n\(totp.output)")
        let code = totp.output.split(separator: "\n").last.map(String.init) ?? ""
        XCTAssertEqual(code.count, 6, "expected a 6-digit TOTP, got \(totp.output)")
        XCTAssertTrue(code.allSatisfy(\.isNumber), "expected digits, got \(code)")
    }

    // MARK: - Helpers

    private static func kdbxContent(of decoded: DecodedVault) -> KDBXContent? {
        (decoded.opaque as? KDBXOrigin)?.content
    }

    private static func entry(titled title: String, in content: KDBXContent) -> KDBX.Entry? {
        var found: KDBX.Entry?
        content.database.visitEntries(in: content.database.root.group) { entry in
            if found == nil, string("Title", in: entry) == title { found = entry }
        }
        return found
    }

    private static func string(_ key: String, in entry: KDBX.Entry) -> String? {
        entry.strings.first { $0.key == key }?.value.withRevealedString { $0 }
    }

    private static func keePassXCCLIOrSkip() throws -> String {
        let candidates = [
            "/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli",
            "/opt/homebrew/bin/keepassxc-cli",
            "/usr/local/bin/keepassxc-cli",
        ]
        guard let cli = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("keepassxc-cli is not installed — skipping the external interop check")
        }
        // A signed, sandboxed test host cannot spawn anything. Probe once so the skip reason says
        // so, instead of every assertion below failing for a reason that has nothing to do with the
        // codec.
        do {
            _ = try run(cli, ["--version"])
        } catch {
            throw XCTSkip("cannot launch a subprocess from this test host (sandboxed?): \(error)")
        }
        return cli
    }

    private static func interopCheckScript() -> URL? {
        // #filePath points into the source tree; the script is a sibling of Sources/.
        let scripts = URL(fileURLWithPath: #filePath)          // …/Sources/UnitTests/KDBXCodecTests.swift
            .deletingLastPathComponent()                        // …/Sources/UnitTests
            .deletingLastPathComponent()                        // …/Sources
            .deletingLastPathComponent()                        // …/PassSumo
            .appendingPathComponent("scripts/interop-check.sh")
        return FileManager.default.isExecutableFile(atPath: scripts.path) ? scripts : nil
    }

    private static func run(
        _ launchPath: String,
        _ arguments: [String],
        stdin: String? = nil
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        if stdin != nil {
            process.standardInput = Pipe()
        }

        try process.run()
        if let stdin, let input = process.standardInput as? Pipe {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }
        // Read before waiting: a full pipe buffer would otherwise deadlock the child.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
