#!/bin/sh
# Offline test for install.sh. Uses a local source tarball and a TEMPORARY
# Applications root — it must NEVER write the real /Applications, launch the
# app, or touch the network.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/openbots-install-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
step() { printf '\n==> %s\n' "$1"; }

step "Packing the working tree as a source tarball"
tar -czf "$WORK/src.tar.gz" -C "$HERE" --exclude ".git" --exclude ".build*" --exclude ".gate-evidence*" .

step "Running install.sh against a temporary Applications root"
BEFORE=$(ls /Applications | shasum)
OPENBOTS_SOURCE_TARBALL="$WORK/src.tar.gz" \
OPENBOTS_APPLICATIONS_DIR="$WORK/Applications" \
OPENBOTS_NO_OPEN=1 \
  sh "$HERE/install.sh"

step "Asserting the result"
[ -d "$WORK/Applications/OpenBots Next Preview.app" ] || { echo "!! app missing from temp root"; exit 1; }
AFTER=$(ls /Applications | shasum)
[ "$BEFORE" = "$AFTER" ] || { echo "!! real /Applications changed"; exit 1; }
echo "OK: installed into the temp root only."
