#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
output="$root/artifacts"
temp="$(mktemp -d)"
trap 'rm -rf "$temp"' EXIT
app="$temp/Payload/CardPreservationProbe.app"
mkdir -p "$app" "$output"
source="$root/Checks/CardPreservationProbe/main.swift"
python3 - "$source" "$temp/validation.swift" "$root/Checks/CardPreservationProbe/validation-tests.swift" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
function = source.split('private func schedulesMatch(', 1)[1].split('@MainActor private final class Probe:', 1)[0]
pathlib.Path(sys.argv[2]).write_text('import Foundation\nimport UserNotifications\nprivate func schedulesMatch(' + function + pathlib.Path(sys.argv[3]).read_text())
PY
xcrun --sdk macosx swiftc -swift-version 5 "$temp/validation.swift" -o "$temp/validation"
"$temp/validation"
sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos swiftc -target arm64-apple-ios17.4 -sdk "$sdk" \
  -swift-version 5 -parse-as-library -O "$source" -o "$app/CardPreservationProbe"

cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDisplayName</key><string>Card Guard Probe</string>
<key>CFBundleExecutable</key><string>CardPreservationProbe</string>
<key>CFBundleIdentifier</key><string>com.jasonwang224.nudge.cardpreservationprobe</string>
<key>CFBundleName</key><string>CardPreservationProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
<key>MinimumOSVersion</key><string>17.4</string>
<key>LSRequiresIPhoneOS</key><true/>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
<key>UISupportedInterfaceOrientations</key><array><string>UIInterfaceOrientationPortrait</string></array>
<key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST
plutil -lint "$app/Info.plist"
test "$(xcrun lipo -archs "$app/CardPreservationProbe")" = "arm64"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")" = "com.jasonwang224.nudge.cardpreservationprobe"
test "$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$app/Info.plist")" = "17.4"
test ! -e "$app/Nudge"
test ! -e "$app/embedded.mobileprovision"
ipa="$output/Card-Guard-Probe-1.0-Unsigned.ipa"
rm -f "$ipa"
(cd "$temp" && zip -qry "$ipa" Payload)
unzip -tq "$ipa"
python3 - "$ipa" <<'PY'
import plistlib, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    assert z.testzip() is None
    assert not any("Nudge.app/" in n for n in z.namelist())
    p = plistlib.loads(z.read("Payload/CardPreservationProbe.app/Info.plist"))
    assert p["CFBundleIdentifier"] == "com.jasonwang224.nudge.cardpreservationprobe"
    assert p["MinimumOSVersion"] == "17.4"
    assert p["CFBundleShortVersionString"] == "1.0" and p["CFBundleVersion"] == "1"
    b = z.read("Payload/CardPreservationProbe.app/CardPreservationProbe")
    assert b"setNotificationRequests:completionHandler:" in b
    assert b"triggerWithDate:timeZone:repeatInterval:repeatCalendar:" in b
    assert b"replaceContentForRequestWithIdentifier:replacementContent:completionHandler:" in b
    assert not any("entitlements" in n.lower() for n in z.namelist())
print("Verified isolated arm64 iOS 17.4 card preservation probe IPA.")
PY

