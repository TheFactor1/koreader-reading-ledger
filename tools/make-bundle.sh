#!/bin/sh
# One download with everything: the Reading Ledger and Bookbridge, ready to
# unzip into KOReader's plugins folder. Bookbridge comes from its own repo
# (next to this one, or BOOKBRIDGE_DIR) at whatever is checked out there; it
# stays its own plugin inside the zip, so it keeps updating itself and works
# without the Ledger too.
#
#   tools/make-bundle.sh            -> dist/reading-ledger-<version>.zip
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
bb_repo=${BOOKBRIDGE_DIR:-$here/../koreader-bookbridge-plugin}
[ -f "$bb_repo/bookbridge.koplugin/main.lua" ] || { echo "Bookbridge not found at $bb_repo" >&2; exit 1; }
version=$(sed -n 's/.*version = "\(.*\)".*/\1/p' "$here/ledger.koplugin/_meta.lua")
bb_rev=$(git -C "$bb_repo" rev-parse --short HEAD 2>/dev/null || echo unknown)
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp -r "$here/ledger.koplugin" "$stage/"
cp -r "$bb_repo/bookbridge.koplugin" "$stage/"
rm -f "$stage/ledger.koplugin/timing"
find "$stage" -name '.git*' -prune -exec rm -rf {} +
cat > "$stage/INSTALL.txt" <<TXT
Reading Ledger $version (with Bookbridge $bb_rev)

Unzip this into KOReader's plugins folder (on a Kindle: /mnt/us/koreader/plugins/)
so that it holds ledger.koplugin and bookbridge.koplugin side by side, then
restart KOReader.
Open it from the menu: Tools > Reading Ledger. The first time it walks you
through setting up; Bookbridge lives inside it (Settings > Bookbridge).
TXT
mkdir -p "$here/dist"
out="$here/dist/reading-ledger-$version.zip"
rm -f "$out"
(cd "$stage" && zip -qr "$out" INSTALL.txt ledger.koplugin bookbridge.koplugin)
echo "$out ($(du -h "$out" | cut -f1)) -- ledger $version, bookbridge $bb_rev"
