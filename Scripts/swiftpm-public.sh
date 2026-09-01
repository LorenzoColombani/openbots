#!/bin/zsh
set -euo pipefail

usage() {
  echo "Usage: Scripts/swiftpm-public.sh {package|build|test|run} [arguments ...]" >&2
}

if (( $# == 0 )); then
  usage
  exit 64
fi

swiftpm_command=$1
shift

case "$swiftpm_command" in
  package|build|test|run)
    ;;
  *)
    echo "Refusing unsupported SwiftPM command. Use package, build, test, or run." >&2
    usage
    exit 64
    ;;
esac

# The caller cannot weaken the public-resource authentication boundary.
swiftpm_has_explicit_scratch=0
for argument in "$@"; do
  case "$argument" in
    --enable-keychain|--enable-netrc|--netrc-file|--netrc-file=*)
      echo "Refusing an argument that enables an ambient credential provider." >&2
      exit 64
      ;;
    --cache-path|--cache-path=*|--config-path|--config-path=*|--security-path|--security-path=*)
      echo "Refusing an argument that overrides a wrapper-owned isolation path." >&2
      exit 64
      ;;
    --scratch-path|--scratch-path=*)
      swiftpm_has_explicit_scratch=1
      ;;
  esac
done

# Public dependencies must be fetched anonymously. Launch from an allowlist-first
# environment and a disposable project-local home so ambient tokens, netrc,
# Git configuration, SSH agents/keys, proxies, and provider sessions are
# structurally unavailable rather than removed one name at a time.
script_dir=${0:A:h}
project_root=${script_dir:h}
swiftpm_scratch_arguments=()
if (( ! swiftpm_has_explicit_scratch )); then
  # A plain build/test must not silently fall back to SwiftPM's .build folder
  # outside the project's named high-churn boundary.
  swiftpm_scratch_arguments=(--scratch-path "$project_root/.build.noindex/swiftpm-default")
fi
isolated_home="$project_root/.build.noindex/swiftpm-home"
isolated_tmp="$project_root/.build.noindex/swiftpm-tmp"
module_cache="$project_root/.build.noindex/swiftpm-module-cache"
shared_cache="$project_root/.build.noindex/swiftpm-shared/cache"
shared_config="$project_root/.build.noindex/swiftpm-shared/config"
shared_security="$project_root/.build.noindex/swiftpm-shared/security"
umask 077
mkdir -p \
  "$isolated_home" "$isolated_tmp" "$module_cache" \
  "$shared_cache" "$shared_config" "$shared_security"
chmod 700 \
  "$isolated_home" "$isolated_tmp" "$module_cache" \
  "$shared_cache" "$shared_config" "$shared_security"

developer_directory=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
swiftpm_environment=(
  "HOME=$isolated_home"
  "USER=openbots-public-build"
  "LOGNAME=openbots-public-build"
  "PATH=/usr/bin:/bin:/usr/sbin:/sbin"
  "TMPDIR=$isolated_tmp"
  "LANG=C"
  "LC_ALL=C"
  "DEVELOPER_DIR=$developer_directory"
  "CLANG_MODULE_CACHE_PATH=$module_cache/clang"
  "SWIFT_MODULECACHE_PATH=$module_cache/swift"
  "SWIFTPM_MODULECACHE_OVERRIDE=$module_cache/swiftpm"
  "GIT_TERMINAL_PROMPT=0"
  "GCM_INTERACTIVE=Never"
  "GIT_ASKPASS=/usr/bin/false"
  "SSH_ASKPASS=/usr/bin/false"
  "GIT_SSH_COMMAND=/usr/bin/ssh -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityFile=/dev/null -o IdentityAgent=none"
  "GIT_CONFIG_NOSYSTEM=1"
  "GIT_CONFIG_GLOBAL=/dev/null"
  "GIT_CONFIG_COUNT=2"
  "GIT_CONFIG_KEY_0=credential.helper"
  "GIT_CONFIG_VALUE_0="
  "GIT_CONFIG_KEY_1=http.extraHeader"
  "GIT_CONFIG_VALUE_1="
)

exec /usr/bin/env -i "${swiftpm_environment[@]}" /usr/bin/xcrun swift "$swiftpm_command" \
  "${swiftpm_scratch_arguments[@]}" \
  --cache-path "$shared_cache" \
  --config-path "$shared_config" \
  --security-path "$shared_security" \
  --disable-keychain \
  --disable-netrc \
  "$@"
