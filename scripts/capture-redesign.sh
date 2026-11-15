#!/bin/bash
# Preview-only edits and sample reminders stay in a temporary copy, never the IPA.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/app-redesign.XXXXXXXX")"
device=""
cleanup() {
  if [ -n "$device" ]; then xcrun simctl shutdown "$device" >/dev/null 2>&1 || true; xcrun simctl delete "$device" >/dev/null 2>&1 || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT
ditto "$root/Nudge" "$tmp/Nudge"
ditto "$root/Nudge.xcodeproj" "$tmp/Nudge.xcodeproj"
python3 - "$tmp" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1])
p=root/'Nudge/NudgeHome.swift'
s=p.read_text()
s=s.replace('@State private var tab: Tab = .today',
            '@State private var tab: Tab = CommandLine.arguments.contains("--settings") ? .settings : .today')
s=s.replace('@State private var editor: EditorItem?',
            '@State private var editor: EditorItem? = CommandLine.arguments.contains("--editor") ? EditorItem() : nil')
p.write_text(s)
p=root/'Nudge/NudgeApp.swift'
s=p.read_text().replace('.task { store.refresh() }', '')
s=s.replace('if phase == .active { store.refresh() }', '')
p.write_text(s)
p=root/'Nudge/ReminderEditor.swift'
p.write_text(p.read_text().replace('reminder?.title ?? ""', 'reminder?.title ?? "Pick up groceries"'))
PY
xcodebuild -project "$tmp/Nudge.xcodeproj" -target Nudge -configuration Debug \
  -sdk iphonesimulator "CONFIGURATION_BUILD_DIR=$tmp/products" "OBJROOT=$tmp/obj" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build >"$tmp/build.log" 2>&1 || { tail -100 "$tmp/build.log"; exit 1; }
runtime="$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin)["runtimes"] if x.get("isAvailable") and "iOS" in x["name"]]; print(sorted(r,key=lambda x:tuple(map(int,x["version"].split("."))))[-1]["identifier"])')"
device="$(xcrun simctl create 'App redesign 375pt' com.apple.CoreSimulator.SimDeviceType.iPhone-11-Pro "$runtime")"
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b
xcrun simctl status_bar "$device" override --time "9:05" --batteryState charged --batteryLevel 100
xcrun simctl install "$device" "$tmp/products/Nudge.app"
data="$(xcrun simctl get_app_container "$device" com.jasonwang224.nudge data)"
mkdir -p "$data/Library/Application Support/Nudge" "$root/artifacts/redesign"
cat >"$tmp/main.swift" <<'SWIFT'
import Foundation
var p = ReminderPreferences()
p.repeatRule = .daily
let calendar = Calendar.autoupdatingCurrent
let now = Date.now
let next = now.addingTimeInterval(25 * 60)
func item(_ title: String, date: Date) -> Reminder {
    var r = Reminder(title: title, notes: "", due: date, repeatAnchor: date, preferences: p)
    let c = calendar.dateComponents([.hour, .minute], from: date)
    r.phoneSchedule = PhoneSchedule(day: date, hour: c.hour!, minute: c.minute!)
    return r
}
var snapshot = ReminderSnapshot()
snapshot.reminders = [
    item("Feed cat", date: next),
    item("Pick up groceries", date: now.addingTimeInterval(60 * 60)),
    item("Clean litter", date: now.addingTimeInterval(90 * 60)),
    item("Brush Nova’s teeth", date: now.addingTimeInterval(120 * 60))
]
try JSONEncoder().encode(snapshot.validated()).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
SWIFT
models=(Reminder UpNextCountdown ReminderDatabase ReminderEditorDraft ReminderLifecycle AgendaPresentation NagDelivery NotificationRequestFactory FiveMinuteSchedule QuickAdjustmentSequence MinuteScheduleReplacement NotificationUpdateLog NotificationContentEquivalence)
sources=()
for name in "${models[@]}"; do sources+=("$root/Nudge/$name.swift"); done
xcrun swiftc -framework UserNotifications "${sources[@]}" "$tmp/main.swift" -o "$tmp/fixtures"
"$tmp/fixtures" "$data/Library/Application Support/Nudge/Reminders-v1.json"
for screen in today settings editor; do
  xcrun simctl terminate "$device" com.jasonwang224.nudge >/dev/null 2>&1 || true
  xcrun simctl launch "$device" com.jasonwang224.nudge "--$screen"
  sleep 3
  xcrun simctl io "$device" screenshot "$root/artifacts/redesign/$screen.png"
done
xcrun simctl terminate "$device" com.jasonwang224.nudge >/dev/null 2>&1 || true
xcrun simctl ui "$device" appearance dark
xcrun simctl launch "$device" com.jasonwang224.nudge --today
sleep 3
xcrun simctl io "$device" screenshot "$root/artifacts/redesign/today-dark.png"
xcrun simctl terminate "$device" com.jasonwang224.nudge >/dev/null 2>&1 || true
xcrun simctl ui "$device" appearance light
xcrun simctl ui "$device" content_size accessibility-extra-extra-extra-large
xcrun simctl launch "$device" com.jasonwang224.nudge --today
sleep 3
xcrun simctl io "$device" screenshot "$root/artifacts/redesign/today-accessibility.png"
