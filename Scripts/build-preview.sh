#!/bin/zsh
set -euo pipefail

script_directory=${0:A:h}
repository_root=${script_directory:h}
build_root="$repository_root/.build.noindex/preview"
# Each option below builds into its own isolated output folder, never installed
# or launched automatically. No arbitrary external output path is accepted.
if (( $# == 1 )) && [[ "$1" == "--verification-only" ]]; then
  build_root="$build_root/Verification"
elif (( $# == 1 )) && [[ "$1" == "--run-journal-verification" ]]; then
  build_root="$build_root/RunJournalVerification"
elif (( $# == 1 )) && [[ "$1" == "--shutdown-verification" ]]; then
  build_root="$build_root/ShutdownVerification"
elif (( $# == 1 )) && [[ "$1" == "--outcome-history-verification" ]]; then
  build_root="$build_root/OutcomeHistoryVerification"
elif (( $# == 1 )) && [[ "$1" == "--outcome-history-ui-verification" ]]; then
  build_root="$build_root/OutcomeHistoryUIVerification"
elif (( $# == 1 )) && [[ "$1" == "--integrated-current-app" ]]; then
  build_root="$build_root/IntegratedCurrentApp-20260830"
elif (( $# == 1 )) && [[ "$1" == "--claude-setup" ]]; then
  build_root="$build_root/ClaudeSetup-20260830"
elif (( $# == 1 )) && [[ "$1" == "--work-context-pane" ]]; then
  build_root="$build_root/WorkContextPane-20260830"
elif (( $# == 1 )) && [[ "$1" == "--chat-only" ]]; then
  build_root="$build_root/ChatOnly-20260830"
elif (( $# == 1 )) && [[ "$1" == "--candidate-review" ]]; then
  build_root="$build_root/CandidateReview-20260830"
elif (( $# == 1 )) && [[ "$1" == "--reference-local-slice" ]]; then
  build_root="$build_root/ReferenceLocalSlice-20260830"
elif (( $# == 1 )) && [[ "$1" == "--reference-accessibility" ]]; then
  build_root="$build_root/ReferenceAccessibility-20260830"
elif (( $# == 1 )) && [[ "$1" == "--bot-archive" ]]; then
  build_root="$build_root/BotArchive-20260831"
elif (( $# == 1 )) && [[ "$1" == "--sidebar-order" ]]; then
  build_root="$build_root/SidebarOrder-20260831"
elif (( $# == 1 )) && [[ "$1" == "--claude-connection" ]]; then
  build_root="$build_root/ClaudeConnection-20260831"
elif (( $# == 1 )) && [[ "$1" == "--claude-text-reply" ]]; then
  build_root="$build_root/ClaudeTextReply-20260831"
elif (( $# == 1 )) && [[ "$1" == "--read-only-context" ]]; then
  build_root="$build_root/ReadOnlyContext-20260831"
elif (( $# != 0 )); then
  print -u2 "Usage: Scripts/build-preview.sh [--verification-only|--run-journal-verification|--shutdown-verification|--outcome-history-verification|--outcome-history-ui-verification|--integrated-current-app|--claude-setup|--work-context-pane|--chat-only|--candidate-review|--reference-local-slice|--reference-accessibility|--bot-archive|--sidebar-order|--claude-connection|--claude-text-reply|--read-only-context]"
  exit 64
fi
isolated_home="$build_root/build-home"
isolated_temp="$build_root/tmp"
module_cache="$build_root/ModuleCache"
# Which source this build is, shown in Settings -> Diagnostics. The build number
# becomes the commit's date; a tree with uncommitted changes to tracked files says
# so beside the commit.
if [[ -d "$repository_root/.git" || -f "$repository_root/.git" ]]; then
  source_commit=$(/usr/bin/git -C "$repository_root" rev-parse --short=12 HEAD)
  # Assigned on its own line so a failing git status stops the build (errexit does
  # not see a failure inside [[ ]]) instead of stamping a dirty tree as clean.
  uncommitted=$(/usr/bin/git -C "$repository_root" status --porcelain --untracked-files=no)
  if [[ -n "$uncommitted" ]]; then
    source_commit="$source_commit with uncommitted changes"
  fi
  source_build_number=$(/usr/bin/git -C "$repository_root" log -1 --format=%cd --date=format:%Y.%-m.%-d HEAD)
else
  # A release tarball (install.sh) carries no git history.
  source_commit="release source"
  source_build_number=$(/bin/date +%Y.%-m.%-d)
fi
google_oauth_client_id=""
google_oauth_client_file="$repository_root/.build.noindex/google-oauth-client-id"
if [[ -f "$google_oauth_client_file" ]]; then
  IFS= read -r google_oauth_client_id < "$google_oauth_client_file"
  if ! print -r -- "$google_oauth_client_id" | /usr/bin/grep -Eq '^[A-Za-z0-9-]+\.apps\.googleusercontent\.com$'; then
    print -u2 "Invalid Google Desktop OAuth client id in $google_oauth_client_file"
    exit 65
  fi
fi

# Home builds carry the developer's Apple Development signature. An ad-hoc
# build is a new identity every time it is
# linked, so the Keychain entries the Google helper made on the previous build
# prompt again on every run, Always Allow never sticks, and the helper's
# 2-second cap silently drops both Google servers. Signed, the helper's
# designated requirement is its identifier plus the team, which every rebuild
# keeps. The identity is looked up here, in the real login session, because the
# isolated build home below has no keychain of its own; the login keychain is
# linked into that home so xcodebuild finds the same certificate (a
# `--keychain` flag alone is not enough: Xcode checks the identity before
# codesign runs, through the home's keychain search list).
login_keychain="$HOME/Library/Keychains/login.keychain-db"
signing_identity=$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null \
  | /usr/bin/grep -F '"Apple Development: ' | /usr/bin/head -n 1 \
  | /usr/bin/sed -E 's/^[^"]*"([^"]*)".*$/\1/' || true)
# Without an Apple Development identity (a fresh Mac, CI) the build is signed
# ad hoc: it runs the same, but the Google helper's Keychain approval has to be
# given again after each rebuild.
/bin/mkdir -p "$isolated_home/Library" "$isolated_temp" "$module_cache"
if [[ -z "$signing_identity" || ! -f "$login_keychain" ]]; then
  print -u2 "No Apple Development signing identity found; signing this build ad hoc."
  signing_identity="-"
else
  /bin/ln -sfn "${login_keychain:h}" "$isolated_home/Library/Keychains"
fi

exec /usr/bin/env -i \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  HOME="$isolated_home" \
  CFFIXED_USER_HOME="$isolated_home" \
  XDG_CACHE_HOME="$isolated_home/.cache" \
  CLANG_MODULE_CACHE_PATH="$module_cache/clang" \
  SWIFTPM_MODULECACHE_OVERRIDE="$module_cache/swiftpm" \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin \
  TMPDIR="$isolated_temp" \
  GIT_CONFIG_GLOBAL=/dev/null \
  GIT_CONFIG_NOSYSTEM=1 \
  GIT_TERMINAL_PROMPT=0 \
  GIT_ASKPASS=/usr/bin/false \
  SSH_ASKPASS=/usr/bin/false \
  NETRC=/dev/null \
  /usr/bin/xcodebuild \
    -project "$repository_root/OpenBotsNext.xcodeproj" \
    -scheme OpenBotsPreviewApp \
    -configuration Debug \
    -destination "platform=macOS,arch=arm64" \
    -derivedDataPath "$build_root/DerivedData" \
    OPENBOTS_GOOGLE_OAUTH_CLIENT_ID="$google_oauth_client_id" \
    OPENBOTS_SOURCE_COMMIT="$source_commit" \
    CURRENT_PROJECT_VERSION="$source_build_number" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$signing_identity" \
    build
