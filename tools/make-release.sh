#!/bin/sh
# The Ledger alone, as the asset a GitHub release carries and Bookbridge
# installs from (Bookbridge > Status & setup > Reading Ledger, and the
# Ledger's own Settings > Check for updates): ledger.koplugin/ at the top of
# the zip, nothing else. make-bundle.sh is the other download -- Ledger and
# Bookbridge together for a first install by hand.
#
#   tools/make-release.sh            -> dist/reading-ledger-<version>.koplugin.zip
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
version=$(sed -n 's/.*version = "\(.*\)".*/\1/p' "$here/ledger.koplugin/_meta.lua")
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp -r "$here/ledger.koplugin" "$stage/"
rm -f "$stage/ledger.koplugin/timing"
find "$stage" -name '.git*' -prune -exec rm -rf {} +
mkdir -p "$here/dist"
out="$here/dist/reading-ledger-$version.koplugin.zip"
rm -f "$out"
(cd "$stage" && zip -qr "$out" ledger.koplugin)
echo "$out ($(du -h "$out" | cut -f1)) -- ledger $version"
