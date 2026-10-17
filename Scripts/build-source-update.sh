#!/bin/zsh
# Build authenticated source with this Mac's own development identity.
# The app has no remote package dependency; nothing is fetched before signing.
set -euo pipefail
umask 077
script_directory=${0:A:h}
source_root=${script_directory:h}
source_commit_value=''
source_build_value=''
source_version_value=''
source_team_value=''
source_google_value=''
typeset -A received_flags
while (( $# )); do
  (( $# >= 2 )) || { print -u2 'Incomplete source build arguments.'; exit 64; }
  [[ -z ${received_flags[$1]-} ]] || { print -u2 'Duplicate source build argument.'; exit 64; }
  received_flags[$1]=1
  case "$1" in
    --commit) source_commit_value=$2 ;;
    --build) source_build_value=$2 ;;
    --version) source_version_value=$2 ;;
    --team) source_team_value=$2 ;;
    --google-client-id) source_google_value=$2 ;;
    *) print -u2 'Unsupported source build argument.'; exit 64 ;;
  esac
  shift 2
done
/usr/bin/python3 -I -S "$script_directory/source-update-sign.py" arguments \
  --commit "$source_commit_value" --build "$source_build_value" --version "$source_version_value" \
  --team "$source_team_value" --google-client-id "$source_google_value"
[[ -d /Applications/Xcode.app/Contents/Developer ]] || { print -u2 'Full Xcode is required to build updates.'; exit 66; }
/usr/bin/python3 -I -B -S "$script_directory/source-update-sign.py" toolchain

source_signing_keychain="$HOME/Library/Keychains/login.keychain-db"
source_signing_identity=$(/usr/bin/python3 -I -S "$script_directory/source-update-sign.py" choose \
  --team "$source_team_value" --keychain "$source_signing_keychain")

# Xcode uses only local packages and an isolated home with no Keychain
# directory attached.
source_build_root="$source_root/.build.noindex/source-update"
source_build_home="$source_build_root/build-home"
source_build_tmp="$source_build_root/tmp"
/usr/bin/python3 -I -S "$script_directory/source-update-sign.py" prepare-directories --source "$source_root"

/usr/bin/env -i \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  HOME="$source_build_home" CFFIXED_USER_HOME="$source_build_home" \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin \
  TMPDIR="$source_build_tmp" LANG=C LC_ALL=C \
  CLANG_MODULE_CACHE_PATH="$source_build_root/ModuleCache/clang" \
  SWIFTPM_MODULECACHE_OVERRIDE="$source_build_root/ModuleCache/swiftpm" \
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 \
  GIT_ASKPASS=/usr/bin/false SSH_ASKPASS=/usr/bin/false NETRC=/dev/null \
  /usr/bin/xcodebuild -project "$source_root/OpenBotsNext.xcodeproj" -scheme OpenBotsPreviewApp \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$source_build_root" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  OPENBOTS_SOURCE_COMMIT="$source_commit_value" CURRENT_PROJECT_VERSION="$source_build_value" \
  MARKETING_VERSION="$source_version_value" OPENBOTS_GOOGLE_OAUTH_CLIENT_ID="$source_google_value" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  ENABLE_HARDENED_RUNTIME=YES ENABLE_DEBUG_DYLIB=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  SWIFT_SERIALIZE_DEBUGGING_OPTIONS=NO COPY_PHASE_STRIP=YES STRIP_INSTALLED_PRODUCT=YES \
  'OTHER_SWIFT_FLAGS=$(inherited) -debug-prefix-map "$(SRCROOT)=/OpenBotsSource" -file-prefix-map "$(SRCROOT)=/OpenBotsSource"' \
  'OTHER_CFLAGS=$(inherited) -fdebug-prefix-map="$(SRCROOT)"=/OpenBotsSource -ffile-prefix-map="$(SRCROOT)"=/OpenBotsSource' \
  build

source_built_app="$source_build_root/Build/Products/Release/OpenBots Next.app"
# Intermediate ad-hoc output is never launched or installed. Every native
# executable and enclosing code bundle is signed inside out with the same local
# identity, preserving reviewed entitlements and library validation.
/usr/bin/python3 -I -S "$script_directory/source-update-sign.py" sign \
  --app "$source_built_app" --identity "$source_signing_identity" --team "$source_team_value" \
  --keychain "$source_signing_keychain" --commit "$source_commit_value" --build "$source_build_value" \
  --version "$source_version_value" --google-client-id "$source_google_value"
print 'SOURCE_UPDATE_BUILD_READY'
