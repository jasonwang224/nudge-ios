#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/nudge-checks.XXXXXXXX")"
trap 'rm -rf "$check_dir"' EXIT

plutil -lint "$root/Nudge.xcodeproj/project.pbxproj"
xcrun swiftc -frontend -parse "$root"/Nudge/*.swift
xcrun swiftc -typecheck -parse-as-library -module-name Nudge \
    -target arm64-apple-ios17.4 -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" \
    "$root"/Nudge/*.swift

models=(
    "$root/Nudge/Reminder.swift"
    "$root/Nudge/ReminderDatabase.swift"
    "$root/Nudge/ReminderEditorDraft.swift"
    "$root/Nudge/ReminderLifecycle.swift"
    "$root/Nudge/AgendaPresentation.swift"
    "$root/Nudge/NagDelivery.swift"
    "$root/Nudge/NotificationRequestFactory.swift"
    "$root/Nudge/FiveMinuteSchedule.swift"
    "$root/Nudge/QuickAdjustmentSequence.swift"
    "$root/Nudge/MinuteScheduleReplacement.swift"
)

xcrun swiftc -framework UserNotifications "${models[@]}" "$root/Checks/main.swift" \
    -o "$check_dir/scheduling-checks"
"$check_dir/scheduling-checks"

for suite in Agenda AgendaUI Editor Lifecycle Interactions Calendar FiveMinute QuickAdjustment MinuteReplacement; do
    xcrun swiftc -framework UserNotifications "${models[@]}" "$root/Checks/$suite/main.swift" \
        -o "$check_dir/$suite-checks"
    "$check_dir/$suite-checks"
done
