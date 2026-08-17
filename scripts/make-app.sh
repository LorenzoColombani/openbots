#!/bin/bash
set -e
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
swift build -c release
APP=dist/Agency.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AgencyApp "$APP/Contents/MacOS/Agency"
# The repo ships an original icon (Resources/AppIcon.icns). Swap it by
# replacing that file — scripts/make-icon.swift turns any square image into
# the full .icns set. The icon is optional: without one the app still builds
# and macOS shows the generic icon.
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Agency's own MCP servers travel INSIDE the bundle so the app keeps working if
# the source checkout moves. Plain scripts, not Mach-O: they carry no signature
# of their own and are covered by the bundle seal.
cp -R Resources/mcp "$APP/Contents/Resources/mcp"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Agency</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>com.lorenzo.agency</string>
  <key>CFBundleName</key><string>Agency</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
# STABLE IDENTITY, not ad-hoc (2026-08-13): macOS ties Full Disk Access and
# Automation grants to the code signature. An ad-hoc signature changes on
# EVERY rebuild, so each rebuild silently revoked the permissions just
# granted. Signing with an Apple Development identity keeps the app the
# same app across rebuilds; falls back to ad-hoc if none is present.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')
# --deep is deprecated and unnecessary for a single-binary bundle
if [ -n "$IDENTITY" ]; then
  codesign --force --options runtime --sign "$IDENTITY" "$APP"
  echo "signed as: $IDENTITY"
else
  codesign --force --sign - "$APP"
  echo "signed ad-hoc — macOS permissions will reset on every rebuild"
fi
echo "Built $APP — open with: open $APP"
