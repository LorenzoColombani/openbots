#!/bin/zsh
set -euo pipefail

script_directory=${0:A:h}
repository_root=${script_directory:h}
build_root="$repository_root/.build.noindex/preview"
# Keep the coordinator's handed-over normal bundle unchanged while compiling
# subsequent source. This is another isolated build output, never installed or
# launched automatically. No arbitrary external output path is accepted.
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

/bin/mkdir -p "$isolated_home" "$isolated_temp" "$module_cache"

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
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build
