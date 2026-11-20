#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
output="$root/artifacts"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/nudge-build.XXXXXXXX")"
trap 'rm -rf "$tmp"' EXIT

bash "$root/scripts/check-source.sh"

xcodebuild -project "$root/Nudge.xcodeproj" -target Nudge -configuration Release \
    -sdk iphoneos "CONFIGURATION_BUILD_DIR=$tmp/products" "OBJROOT=$tmp/obj" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ARCHS=arm64 build

app="$tmp/products/Nudge.app"
test "$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$app/Info.plist")" = "17.4"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Info.plist")" = "1.1.25"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")" = "com.jasonwang224.nudge"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Info.plist")" = "37"
test -s "$app/Glass.wav"
test -s "$app/DigitalGlass.wav"
test -s "$app/DigitalChime.wav"
test "$(xcrun lipo -archs "$app/Nudge")" = "arm64"

mkdir -p "$tmp/Payload" "$output"
ditto "$app" "$tmp/Payload/Nudge.app"
ipa="$output/Nudge-1.1.25-Unsigned.ipa"
rm -f "$ipa"
(cd "$tmp" && zip -qry "$ipa" Payload)
unzip -tq "$ipa"
printf 'Built %s\n' "$ipa"
