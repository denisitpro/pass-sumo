#!/usr/bin/env bash
#
# interop-check.sh — verify that a .kdbx file our own app wrote can still
# be opened and read by KeePassXC (a different, trusted implementation).
# This is the interop half of the round-trip: make-fixtures.sh produces
# files a THIRD party wrote for OUR codec to read; this script is what CI
# runs against a file OUR codec wrote, to prove KeePassXC can read it back.
#
# Usage:
#   interop-check.sh <database.kdbx> <password> [keyfile]
#
# Exit code is non-zero on any failure (file missing, wrong password,
# corrupt file, keepassxc-cli itself missing, etc).

set -euo pipefail

usage() {
  echo "Usage: $(basename "$0") <database.kdbx> <password> [keyfile]" >&2
  exit 2
}

if [[ $# -lt 2 || $# -gt 3 ]]; then
  usage
fi

DATABASE="$1"
PASSWORD="$2"
KEYFILE="${3:-}"

if [[ ! -f "$DATABASE" ]]; then
  echo "FAIL: database file not found: $DATABASE" >&2
  exit 1
fi

if [[ -n "$KEYFILE" && ! -f "$KEYFILE" ]]; then
  echo "FAIL: key file not found: $KEYFILE" >&2
  exit 1
fi

# --- locate keepassxc-cli ---------------------------------------------------
# Same resolution order as make-fixtures.sh: PATH first (e.g. a Homebrew
# install), then the default macOS .app bundle path, since keepassxc-cli
# is not on PATH by default when KeePassXC is installed as a normal
# Applications-folder app.
if command -v keepassxc-cli >/dev/null 2>&1; then
  KP="$(command -v keepassxc-cli)"
elif [[ -x "/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli" ]]; then
  KP="/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli"
else
  echo "FAIL: keepassxc-cli not found on PATH or at" >&2
  echo "  /Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli" >&2
  echo "Install KeePassXC (https://keepassxc.org) and re-run." >&2
  exit 1
fi

# Wrap keepassxc-cli invocations behind a helper instead of an optional
# array of extra args: /bin/bash on macOS is 3.2, and under `set -u` an
# EMPTY array ("KEY_ARGS=()") expands "${KEY_ARGS[@]}" as an unbound
# variable in that version (fixed only in bash 4.4+), aborting the script
# even when no key file was requested. A plain if/else sidesteps it.
kp_run() {
  if [[ -n "$KEYFILE" ]]; then
    "$KP" "$@" -k "$KEYFILE"
  else
    "$KP" "$@"
  fi
}

echo "Checking interop for: $DATABASE"
echo "Using keepassxc-cli: $KP ($("$KP" --version))"

# --- 1. must open and list at least one entry -------------------------------
# `ls -R` walks every group recursively. keepassxc-cli reads the password
# from stdin when no key file is given (and reads it the same way even
# when one is), so this never blocks on an interactive prompt.
LISTING="$(printf '%s\n' "$PASSWORD" | kp_run ls "$DATABASE" -R 2>&1)" || {
  echo "FAIL: keepassxc-cli could not open/list the database:" >&2
  echo "$LISTING" >&2
  exit 1
}

if [[ -z "$(echo "$LISTING" | tr -d '[:space:]')" ]]; then
  echo "FAIL: database opened but reported no groups/entries at all." >&2
  exit 1
fi

echo "OK: database opened; group/entry listing:"
echo "$LISTING"

# --- 2. must export as well-formed KeePassXC XML ----------------------------
# A second, independent read path: exporting to XML forces KeePassXC to
# walk every group, entry, history item, and attachment reference, which
# `ls` alone does not. NOTE: stderr must stay separate from the XML on
# stdout, or the interactive password-prompt text corrupts the document
# (this bit us while building make-fixtures.sh — see its comments).
XML_OUTPUT="$(mktemp)"
XML_STDERR="$(mktemp)"
trap 'rm -f "$XML_OUTPUT" "$XML_STDERR"' EXIT

if ! printf '%s\n' "$PASSWORD" | kp_run export -f xml "$DATABASE" \
    > "$XML_OUTPUT" 2>"$XML_STDERR"; then
  echo "FAIL: keepassxc-cli could not export the database as XML:" >&2
  cat "$XML_STDERR" >&2
  exit 1
fi

if ! head -c 200 "$XML_OUTPUT" | grep -q "<KeePassFile>"; then
  echo "FAIL: exported XML does not look like a KeePassXC export (no <KeePassFile> root)." >&2
  echo "First bytes of export:" >&2
  head -c 200 "$XML_OUTPUT" >&2
  exit 1
fi

ENTRY_COUNT="$(grep -c "<Entry>" "$XML_OUTPUT" || true)"
echo "OK: exported valid KeePassXC XML ($ENTRY_COUNT <Entry> elements, incl. history snapshots)."

echo "PASS: $DATABASE is readable by keepassxc-cli."
exit 0
