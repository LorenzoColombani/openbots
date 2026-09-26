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

step "A malformed Google client ID is refused before anything is built"
if OPENBOTS_GOOGLE_OAUTH_CLIENT_ID="not-a-client-id" OPENBOTS_SOURCE_TARBALL="$WORK/src.tar.gz" \
   OPENBOTS_APPLICATIONS_DIR="$WORK/Applications" OPENBOTS_NO_OPEN=1 sh "$HERE/install.sh" 2>/dev/null; then
  echo "!! a malformed client ID was accepted"; exit 1
fi
[ ! -e "$WORK/Applications" ] || { echo "!! something was installed after a refusal"; exit 1; }

step "Running install.sh against a temporary Applications root, with a Google client ID"
BEFORE=$(ls /Applications | shasum)
CLIENT_ID="1234-installertest.apps.googleusercontent.com"
OPENBOTS_GOOGLE_OAUTH_CLIENT_ID="$CLIENT_ID" \
OPENBOTS_SOURCE_TARBALL="$WORK/src.tar.gz" \
OPENBOTS_APPLICATIONS_DIR="$WORK/Applications" \
OPENBOTS_NO_OPEN=1 \
  sh "$HERE/install.sh"

step "Asserting the result"
[ -d "$WORK/Applications/OpenBots Next.app" ] || { echo "!! app missing from temp root"; exit 1; }
BUILT_ID=$(/usr/libexec/PlistBuddy -c "Print :OpenBotsGoogleOAuthClientID" "$WORK/Applications/OpenBots Next.app/Contents/Info.plist")
[ "$BUILT_ID" = "$CLIENT_ID" ] || { echo "!! the app carries Google client ID '$BUILT_ID'"; exit 1; }
AFTER=$(ls /Applications | shasum)
[ "$BEFORE" = "$AFTER" ] || { echo "!! real /Applications changed"; exit 1; }
echo "OK: installed into the temp root only."
