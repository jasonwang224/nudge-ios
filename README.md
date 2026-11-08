# Nudge for iPhone

Native SwiftUI reminder app for the iPhone 11 Pro on iOS 17.4.1. The deployment target is iOS 17.4.

On a Mac with Xcode, run `bash scripts/build-ipa.sh`. GitHub Actions runs the same script on macOS. Download the **Nudge-1.0.1-Unsigned** artifact and extract the IPA. Use a sideloading tool to sign it with a provisioning profile for your iPhone. Install over the existing app with the same signing account and app identifier to keep your reminders.

Version 1.0.1 moves reminders into a file that is replaced atomically when changes are saved. An unreadable database pauses changes and leaves pending alerts alone. As an upgrade check, create two reminders in the previous build, then install the update over it. Confirm both are still visible and that completing one from the Lock Screen leaves the other scheduled.

## Lock Screen test

1. Open Nudge and allow notifications. In iPhone Settings, enable Lock Screen alerts and immediate delivery for Nudge. Use a Focus that allows Nudge.
2. In **Settings → Lock Screen**, tap **Send a test alert in 30 seconds**. Wait for the queue confirmation. Leave the app, lock the iPhone, and let the display go dark.
3. Confirm the first alert arrives. Leave it alone and check for the next nudge two minutes later.
4. Touch and hold the notification and select **Snooze 15 min**. Check that the old nudges stop and a new alert comes about 15 minutes after the tap. The two-minute cadence resumes from that alert.
5. Select **Done** from the Lock Screen. Wait at least two minutes and check that no more nudges arrive for that test reminder. Repeat the test after swiping Nudge away. Also try two reminders to check that finishing one leaves the other scheduled.

Nudge uses the iPhone's local date, time, and time zone. A recurring 8 AM reminder stays at 8 AM across daylight saving changes. When the clock skips a time in spring, Nudge uses the next available time and shows the adjustment in the editor. When a time occurs twice in fall, Nudge uses the first occurrence. Snooze and nag intervals count elapsed minutes. Nudge refreshes queued alerts when it opens or iOS reports a clock change.

Nudge hands its alerts to iOS in advance. It uses a budget of 60 pending requests, prioritizes one alert per active reminder, and uses the remaining slots for nudges. Nudge replenishes those slots when it opens or handles a notification action. With a single reminder on a two-minute interval, the initial queue covers 118 minutes after its first alert. Coverage varies with other reminders. iOS controls presentation, display wake, and vibration.

Completed recurring occurrences appear in history. Restoring one creates a one-time reminder for that occurrence and keeps the recurring schedule intact.
