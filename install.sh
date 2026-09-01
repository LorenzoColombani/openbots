#!/bin/sh
# OpenBots installer (v2 — the "Next" rebuild).
#
#   curl -fsSL https://raw.githubusercontent.com/LorenzoColombani/openbots/main/install.sh | sh
#
# Does only what cannot happen before the app exists, and asks nothing:
#   1. full Xcode present? (this build needs Xcode's Swift 6 toolchain; Command
#      Line Tools alone are NOT enough — the installer says so and stops)
#   2. fetch the latest release's source
#   3. build it locally via Scripts/build-preview.sh (unsigned local build:
#      not quarantined, no Gatekeeper warning, code signing disabled)
#   4. copy the app to /Applications
#   5. open it — first-run setup continues in the app (Claude Code CLI, login)
#
# Knobs (all optional): OPENBOTS_REPO=owner/name ·
# OPENBOTS_SOURCE_TARBALL=/path/src.tar.gz (skip the download) ·
# OPENBOTS_APPLICATIONS_DIR=/some/dir (used by the offline installer test;
# the test must never write the real /Applications) · OPENBOTS_NO_OPEN=1
set -eu

REPO="${OPENBOTS_REPO:-LorenzoColombani/openbots}"
APPS_DIR="${OPENBOTS_APPLICATIONS_DIR:-/Applications}"
SOURCE_TARBALL="${OPENBOTS_SOURCE_TARBALL:-}"
APP_NAME="OpenBots Next Preview"

step() { printf '\n==> %s\n' "$1"; }
fail() { printf '\n!! %s\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail "This installer is for macOS."
[ "$(uname -m)" = arm64 ] || fail "This build targets Apple Silicon (arm64)."

# 1. Full Xcode ---------------------------------------------------------------
XCODE_DEV="/Applications/Xcode.app/Contents/Developer"
if [ ! -d "$XCODE_DEV" ]; then
  fail "This build needs full Xcode (Swift 6 toolchain) at /Applications/Xcode.app.
   Command Line Tools alone cannot build it. Install Xcode from the App Store,
   open it once to finish setup, then run this installer again."
fi

# 2. Source -------------------------------------------------------------------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/openbots-install.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/src"
if [ -n "$SOURCE_TARBALL" ]; then
  step "Using source tarball $SOURCE_TARBALL"
  cp "$SOURCE_TARBALL" "$WORK/src.tar.gz"
else
  step "Fetching the latest release of $REPO"
  TAG=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
        | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
  if [ -n "$TAG" ]; then
    URL="https://github.com/$REPO/archive/refs/tags/$TAG.tar.gz"
  else
    URL="https://github.com/$REPO/archive/refs/heads/main.tar.gz"
  fi
  curl -fsSL "$URL" -o "$WORK/src.tar.gz" || fail "Could not download $URL"
fi
tar -xzf "$WORK/src.tar.gz" -C "$WORK/src" --strip-components=1
[ -f "$WORK/src/Scripts/build-preview.sh" ] || fail "That does not look like the app's source (Scripts/build-preview.sh missing)."

# 3. Build --------------------------------------------------------------------
step "Building $APP_NAME (a few minutes on first build)"
( cd "$WORK/src" && /bin/zsh Scripts/build-preview.sh ) || fail "The build failed. Nothing was installed."
BUILT_APP="$WORK/src/.build.noindex/preview/DerivedData/Build/Products/Debug/$APP_NAME.app"
[ -d "$BUILT_APP" ] || fail "Build finished but the app bundle was not found at the expected path."

# 4. Install ------------------------------------------------------------------
step "Copying $APP_NAME.app to $APPS_DIR"
mkdir -p "$APPS_DIR"
rm -rf "$APPS_DIR/$APP_NAME.app"
cp -R "$BUILT_APP" "$APPS_DIR/$APP_NAME.app"

# 5. Open ---------------------------------------------------------------------
if [ "${OPENBOTS_NO_OPEN:-0}" != 1 ]; then
  step "Opening $APP_NAME"
  open "$APPS_DIR/$APP_NAME.app"
fi
step "Done. $APP_NAME is installed at $APPS_DIR/$APP_NAME.app"
