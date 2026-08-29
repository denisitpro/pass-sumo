#!/usr/bin/env bash
#
# make-fixtures.sh — regenerate the KDBX interop test fixtures under
# PassSumo/Sources/UnitTests/Fixtures/ using KeePassXC's own CLI.
#
# Why: our KDBX codec must be tested against files written by a different,
# trusted implementation, not only against itself. This script drives
# `keepassxc-cli` to build those files from scratch, deterministically as
# far as the CLI allows.
#
# IMPORTANT — read this before "fixing" the fixture matrix:
# `keepassxc-cli` (verified against the exact binary this script uses, see
# `keepassxc-cli --version` below) exposes NO flag anywhere — not on
# `db-create`, `db-edit`, or `import` — to choose the KDBX format version,
# the key-derivation function, or the cipher. Every database it creates is
# unconditionally KDBX 3.1, AES-KDF, AES-256. This was confirmed by:
#   - reading every `--help` screen for db-create/db-edit/import/add/edit,
#   - parsing the actual header bytes of CLI-created files (version field
#     decodes to 3.1 every time, with or without --decryption-time),
#   - `keepassxc-cli db-info` reporting "KDF: AES (N rounds)" / "Cipher:
#     AES 256-bit" every time,
#   - probing invented flag names (--kdf, --cipher, --algorithm, --format,
#     --argon2, --argon2id, --chacha20, --kdbx4, ...) and getting "Unknown
#     option" for every one of them.
# So this script can only ever produce ONE point in the KDBX4 test matrix
# requested for this fixture set: none of it, because it cannot write
# KDBX4 at all. See Fixtures/README.md for the full explanation of what
# could and could not be produced, and why.
#
# Prerequisites: `keepassxc-cli` (found on PATH, or at the default macOS
# app bundle path) and `python3` (used only for XML text-splicing and raw
# byte-flipping — both jobs the CLI itself has no command for).

set -euo pipefail

# --- locate keepassxc-cli --------------------------------------------------
# Prefer PATH (e.g. a Homebrew install) but fall back to the macOS .app
# bundle, since keepassxc-cli is not on PATH by default when KeePassXC is
# installed as a normal Applications-folder app.
if command -v keepassxc-cli >/dev/null 2>&1; then
  KP="$(command -v keepassxc-cli)"
elif [[ -x "/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli" ]]; then
  KP="/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli"
else
  echo "ERROR: keepassxc-cli not found on PATH or at" >&2
  echo "  /Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli" >&2
  echo "Install KeePassXC (https://keepassxc.org) and re-run." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 not found (needed for XML splicing / byte-flipping)." >&2
  exit 1
fi

echo "Using keepassxc-cli: $KP"
echo "Version: $("$KP" --version)"

# --- paths ------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/../Sources/UnitTests/Fixtures"
mkdir -p "$FIXTURES_DIR"
FIXTURES_DIR="$(cd "$FIXTURES_DIR" && pwd)"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
cd "$WORK_DIR"

# The single published fixture password. Not a real secret — see README.md.
PW='correct horse battery staple'

# Remove previously generated fixtures so this script is re-runnable from
# scratch. README.md is hand-maintained, not generated, so it is untouched.
rm -f "$FIXTURES_DIR"/*.kdbx "$FIXTURES_DIR"/*.key

# --- 1. build the content-rich seed database --------------------------------
# `-p` on db-create prompts for the password on stdin (no --set-password
# value flag exists), so we pipe it twice (enter + confirm). No
# --decryption-time flag is passed on purpose: leaving it unset gives the
# CLI's fixed built-in default of 1,000,000 AES-KDF rounds, which unlocks
# in ~25ms on this machine. Passing the *minimum* allowed
# --decryption-time (100ms) actually produced MORE rounds (13M+, ~130ms)
# on this hardware, i.e. slower — so omitting the flag is the fastest,
# lowest-round option this CLI can produce, which is what a sub-couple-
# -second unit test suite needs.
SEED="$WORK_DIR/seed.kdbx"
printf '%s\n%s\n' "$PW" "$PW" | "$KP" db-create -p "$SEED"

# Three groups plus the root group the CLI creates automatically.
for g in Email Work Finance; do
  printf '%s\n' "$PW" | "$KP" mkdir "$SEED" "$g"
done

# Six entries spread across the three groups. `add`'s positional "entry"
# argument is a path ("Group/Title"), so group placement and title are set
# in one go; -u/--url/--notes set the plain fields; -p prompts (stdin) for
# the entry's own password separately from the database's unlock password.
printf '%s\n%s\n' "$PW" 'Gmail-Str0ngPass!1' | "$KP" add "$SEED" "Email/Gmail" \
  -u "alice@example.com" --url "https://mail.google.com" \
  --notes "Personal email account." -p

# Non-ASCII entry: Cyrillic + emoji in the title AND in the notes, to catch
# UTF-8 encoding bugs in our codec. The literal characters below are typed
# directly (not \U escapes) because /bin/bash on macOS is 3.2, which does
# not support \U Unicode escapes inside $'...' — those would otherwise be
# stored as the literal 8-character escape sequence instead of the emoji.
printf '%s\n%s\n' "$PW" 'MailRu-P@r0l-99' | "$KP" add "$SEED" "Email/Почта 📧" \
  -u "boris@example.com" --url "https://example.com/mail" \
  --notes "Личная почта с эмодзи 🔒📬 для проверки кодировки." -p

# This entry gets a TOTP `otp` field spliced in below (add/edit have no
# flag for it at all).
printf '%s\n%s\n' "$PW" 'GitHub-2FA-Pass-42' | "$KP" add "$SEED" "Work/GitHub" \
  -u "alice" --url "https://github.com" \
  --notes "Source control account." -p

# This entry gets two custom string fields spliced in below (one
# protected), for the same reason: no CLI flag for custom attributes.
printf '%s\n%s\n' "$PW" 'VPN-Access-Key-7788' | "$KP" add "$SEED" "Work/VPN Access" \
  -u "alice.vpn" --url "https://vpn.example.com" \
  --notes "Corporate VPN credentials." -p

# This entry gets a file attachment and is edited twice below to build up
# entry history.
printf '%s\n%s\n' "$PW" 'RootInit-0001' | "$KP" add "$SEED" "Work/Server Login" \
  -u "root" --url "ssh://10.0.0.5" \
  --notes "Production server root login." -p

printf '%s\n%s\n' "$PW" 'Bank-Vault-55731' | "$KP" add "$SEED" "Finance/Bank Account" \
  -u "alice.bank" --url "https://bank.example.com" \
  --notes "Primary checking account." -p

# --- file attachment ----------------------------------------------------
ATTACHMENT_SRC="$WORK_DIR/readme-attachment.txt"
printf 'This is a small attachment fixture used to test binary attachment round-tripping.\n' \
  > "$ATTACHMENT_SRC"
printf '%s\n' "$PW" | "$KP" attachment-import "$SEED" "Work/Server Login" \
  "readme-attachment.txt" "$ATTACHMENT_SRC"

# --- entry history: edit the same entry's password twice ----------------
# Each `edit -p` call pushes the entry's *current* state into <History>
# before applying the new value, so two edits leave two prior snapshots
# behind (on top of the attachment-import snapshot) and the final live
# password is the third value below.
printf '%s\n%s\n' "$PW" 'TempPass-History-1' | "$KP" edit "$SEED" "Work/Server Login" -p
printf '%s\n%s\n' "$PW" 'FinalServerPass-2026' | "$KP" edit "$SEED" "Work/Server Login" -p

# --- 2. export to XML, splice in TOTP + custom fields, reimport ---------
# `add`/`edit` cannot set arbitrary custom string attributes or the `otp`
# field (there is no flag for either), so we round-trip through KeePassXC's
# own XML export/import instead — the same mechanism the GUI uses for
# database import/export, so it stays a "trusted implementation" file, not
# something we hand-crafted from nothing.
#
# NOTE: stderr must NOT be merged into the exported XML (`2>&1`) — the
# interactive password-prompt text that `keepassxc-cli` writes to stderr
# would land inside the XML file and corrupt it. Keep stdout and stderr
# separate here.
SEED_XML="$WORK_DIR/seed.xml"
printf '%s\n' "$PW" | "$KP" export -f xml "$SEED" > "$SEED_XML" 2>/dev/null

SPLICED_XML="$WORK_DIR/seed-spliced.xml"
python3 - "$SEED_XML" "$SPLICED_XML" <<'PYEOF'
import sys
from xml.sax.saxutils import escape

src, dst = sys.argv[1], sys.argv[2]
with open(src, encoding="utf-8") as f:
    xml = f.read()


def inject_into_entry_by_title(xml_text, title, injected_xml):
    """Insert extra <String> elements just before the closing </Entry> tag
    of the (first) entry whose Title matches. Entries that have not yet
    been edited have no <History> sub-entries sharing the same title, so
    the first match is always the live entry for GitHub / VPN Access here."""
    idx = xml_text.index(f"<Value>{title}</Value>")
    close_idx = xml_text.index("</Entry>", idx)
    return xml_text[:close_idx] + injected_xml + xml_text[close_idx:]


# KeePassXC's real TOTP convention (verified empirically: `keepassxc-cli
# show --totp` computes a live code from exactly this shape): a single
# plain string field named "otp" holding a full otpauth:// URI. NOT split
# "TOTP Seed"/"TOTP Settings" fields (that was the older keepass2-totp
# plugin convention) — see Fixtures/README.md.
otp_uri = ("otpauth://totp/GitHub:alice?secret=JBSWY3DPEHPK3PXP&issuer=GitHub"
           "&algorithm=SHA1&digits=6&period=30")
otp_field = f"<String><Key>otp</Key><Value>{escape(otp_uri)}</Value></String>"
xml = inject_into_entry_by_title(xml, "GitHub", otp_field)

# Two custom string fields, one memory-protected (ProtectInMemory="True")
# and one not — this attribute is preserved through KeePassXC's XML
# import, confirmed by re-exporting and checking `show --all -s`.
custom_fields = (
    "<String><Key>Recovery Code</Key><Value>ABC-123-XYZ</Value></String>"
    '<String><Key>Security Answer</Key>'
    '<Value ProtectInMemory="True">my-secret-answer</Value></String>'
)
xml = inject_into_entry_by_title(xml, "VPN Access", custom_fields)

with open(dst, "w", encoding="utf-8") as f:
    f.write(xml)
PYEOF

GOOD="$FIXTURES_DIR/kdbx3-aeskdf-aes256.kdbx"
printf '%s\n%s\n' "$PW" "$PW" | "$KP" import "$SPLICED_XML" "$GOOD" -p
echo "Wrote $GOOD"

# --- 3. key-file fixture: same content, plus a generated key file -------
# `db-edit --set-key-file <path>` auto-generates a fresh key file at that
# path if none exists yet — no separate "generate a keyfile" command is
# needed.
KEYFILE_DB="$FIXTURES_DIR/kdbx3-keyfile.kdbx"
KEYFILE_KEY="$FIXTURES_DIR/kdbx3-keyfile.key"
cp "$GOOD" "$KEYFILE_DB"
printf '%s\n' "$PW" | "$KP" db-edit "$KEYFILE_DB" --set-key-file "$KEYFILE_KEY"
echo "Wrote $KEYFILE_DB (+ $KEYFILE_KEY)"

# --- 4. deliberately corrupted fixture -----------------------------------
# Flip one byte well inside the encrypted/hashed body (not in the header,
# and past the 32-byte StreamStartBytes verification zone right after the
# header — corrupting *that* zone is indistinguishable from a wrong
# password to KDBX3's reader). See README.md for the exact offset and the
# exact error text this produces.
CORRUPTED="$FIXTURES_DIR/kdbx3-corrupted.kdbx"
python3 - "$GOOD" "$CORRUPTED" <<'PYEOF'
import struct
import sys

src, dst = sys.argv[1], sys.argv[2]
with open(src, "rb") as f:
    data = bytearray(f.read())

# Walk the KDBX3 TLV header (1-byte id, 2-byte little-endian length, then
# that many bytes of data) to find where it ends (id == 0) and the
# encrypted body begins.
pos = 12  # 4-byte sig1 + 4-byte sig2 + 4-byte version
while True:
    field_id = data[pos]
    length = struct.unpack("<H", bytes(data[pos + 1:pos + 3]))[0]
    pos = pos + 3 + length
    if field_id == 0:
        break
header_end = pos

offset = header_end + 100  # comfortably inside the encrypted body
data[offset] ^= 0xFF

with open(dst, "wb") as f:
    f.write(data)

print(f"header_end={header_end} corrupted_byte_offset={offset}")
PYEOF
echo "Wrote $CORRUPTED"

echo ""
echo "Done. Fixtures written to: $FIXTURES_DIR"
echo ""
echo "REMINDER: this CLI cannot produce any KDBX4 fixture (no KDF/cipher/"
echo "format-version flags exist on db-create/db-edit/import) — see"
echo "Fixtures/README.md for the full explanation."
