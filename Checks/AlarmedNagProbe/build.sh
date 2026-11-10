#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
output="$root/artifacts"
temp="$(mktemp -d)"
trap 'rm -rf "$temp"' EXIT
app="$temp/Payload/AlarmedNagProbe.app"
mkdir -p "$app" "$output"

xcrun --sdk iphoneos swiftc -target arm64-apple-ios17.4 \
  -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" -swift-version 5 -parse-as-library -O \
  "$root/Checks/AlarmedNagProbe/main.swift" -o "$app/AlarmedNagProbe"

cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key><string>Nag Probe</string>
  <key>CFBundleExecutable</key><string>AlarmedNagProbe</string>
  <key>CFBundleIdentifier</key><string>com.jasonwang224.nudge.nagprobe</string>
  <key>CFBundleName</key><string>AlarmedNagProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
  <key>MinimumOSVersion</key><string>17.4</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>UIDeviceFamily</key><array><integer>1</integer></array>
  <key>UIApplicationSceneManifest</key>
  <dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
  <key>UILaunchScreen</key><dict/>
</dict>
</plist>
PLIST
plutil -lint "$app/Info.plist"
test "$(xcrun lipo -archs "$app/AlarmedNagProbe")" = "arm64"
ipa="$output/Alarmed-Nag-Probe-Unsigned.ipa"
(cd "$temp" && zip -qry "$ipa" Payload)
unzip -tq "$ipa"
