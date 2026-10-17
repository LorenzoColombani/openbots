#!/bin/sh
# Bootstrap the published release: the immutable commit named by the release
# feed on main, never the moving branch head. No application/data deletion.
# For a local clone: /usr/bin/python3 -I -B -S Scripts/bootstrap-install.py --source .
set -eu
umask 077
[ "$(/usr/bin/uname -s)" = Darwin ] || { echo 'This installer requires macOS.' >&2; exit 1; }
xcode_info=/Applications/Xcode.app/Contents/Info.plist
[ -f "$xcode_info" ] && [ -d /Applications/Xcode.app/Contents/Developer ] || {
  echo 'Install full Xcode 16.3 or later in /Applications and open it once first.' >&2; exit 1; }
xcode_version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$xcode_info" 2>/dev/null || true)
printf '%s\n' "$xcode_version" | /usr/bin/awk -F. '
  $0 !~ /^[0-9]+\.[0-9]+(\.[0-9]+)?$/ { exit 1 }
  { exit !($1 > 16 || ($1 == 16 && $2 >= 3)) }' || {
  echo "OpenBots Next needs Xcode 16.3 or later (found ${xcode_version:-an unreadable version}). Update Xcode and open it once." >&2
  exit 1; }
bootstrap_work=$(/usr/bin/mktemp -d "${TMPDIR:-/private/tmp}/openbots-bootstrap-launch.XXXXXX")
cleanup() {
  # Remove only our two downloaded regular files. Never recursively delete a path.
  /bin/rm -f -- "$bootstrap_work/source-update.json" "$bootstrap_work/bootstrap-install.py"
  /bin/rmdir -- "$bootstrap_work" 2>/dev/null || true
}
trap cleanup EXIT
feed_status=$(/usr/bin/env -i HOME=/nonexistent PATH=/usr/bin:/bin:/usr/sbin:/sbin LANG=C LC_ALL=C \
  /usr/bin/curl -q --silent --show-error --proto '=https' --tlsv1.2 --max-time 30 --max-filesize 8388608 \
  --output "$bootstrap_work/source-update.json" --write-out '%{http_code}' \
  https://raw.githubusercontent.com/LorenzoColombani/openbots/main/docs/updates/source-update.json) || {
  echo 'The release feed could not be downloaded. Check your network connection.' >&2; exit 1; }
[ "$feed_status" != 404 ] || {
  echo 'No published release yet. To build a local clone instead, see docs/INSTALL.md.' >&2; exit 1; }
[ "$feed_status" = 200 ] || { echo "The release feed could not be downloaded (HTTP $feed_status)." >&2; exit 1; }
# Only the commit and the bootstrap's own SHA-256 are read here. The bootstrap
# re-reads the feed, validates it in full, checks the source against its
# inventory and refuses a different commit.
feed_values=$(/usr/bin/python3 -I -B -S -c '
import base64, json, sys
with open(sys.argv[1], "rb") as stream:
    envelope = json.load(stream)
payload = json.loads(base64.b64decode(envelope["payload"], validate=True))
entries = [item["sha256"] for item in payload["files"] if item["path"] == "Scripts/bootstrap-install.py"]
print(payload["sourceCommit"], entries[0] if len(entries) == 1 else "")
' "$bootstrap_work/source-update.json" 2>/dev/null || true)
bootstrap_commit=${feed_values%% *}
bootstrap_sha256=${feed_values#* }
printf '%s %s\n' "$bootstrap_commit" "$bootstrap_sha256" | /usr/bin/grep -Eq '^[a-f0-9]{40} [a-f0-9]{64}$' || {
  echo 'The release feed is malformed.' >&2; exit 1; }
/usr/bin/env -i HOME=/nonexistent PATH=/usr/bin:/bin:/usr/sbin:/sbin LANG=C LC_ALL=C \
  /usr/bin/curl -q --fail --silent --show-error --proto '=https' --tlsv1.2 --max-time 60 \
  "https://raw.githubusercontent.com/LorenzoColombani/openbots/$bootstrap_commit/Scripts/bootstrap-install.py" \
  -o "$bootstrap_work/bootstrap-install.py"
downloaded_sha256=$(/usr/bin/python3 -I -B -S -c '
import hashlib, sys
with open(sys.argv[1], "rb") as stream:
    print(hashlib.sha256(stream.read()).hexdigest())
' "$bootstrap_work/bootstrap-install.py")
[ "$downloaded_sha256" = "$bootstrap_sha256" ] || {
  echo 'The downloaded bootstrap does not match the release feed. Nothing was run.' >&2; exit 1; }
/usr/bin/python3 -I -B -S "$bootstrap_work/bootstrap-install.py" --commit "$bootstrap_commit"
