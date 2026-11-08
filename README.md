# Nudge for iPhone

Native SwiftUI test build for the iPhone 11 Pro on iOS 17.4.1. The deployment target is iOS 17.4.

On a Mac with Xcode, run `bash scripts/build-ipa.sh`. GitHub Actions runs the same script on macOS. Download the **Nudge-Test-Unsigned** artifact and extract the IPA. The IPA needs signing with a provisioning profile for your iPhone before it can be installed. A sideloading tool can perform this step. Keep Apple Account credentials in the signing tool and enable Developer Mode on the iPhone when required.

## Lock Screen test

1. Open Nudge and allow notifications. In iPhone Settings, enable Lock Screen alerts and immediate delivery for Nudge. Use a Focus that allows Nudge.
2. In Today, tap **Test in 30 seconds**. Wait for the queue confirmation. Leave the app, lock the iPhone, and let the display go dark.
3. Confirm the first alert arrives. Leave it alone and check for the next nudge two minutes later.
4. Touch and hold the notification and select **Snooze 15 min**. Check that the old nudges stop and a new alert comes about 15 minutes after the tap. The two-minute cadence resumes from that alert.
5. Select **Done** from the Lock Screen. Wait at least two minutes and check that no more nudges arrive for that test reminder. Repeat the test after swiping Nudge away. Also try two reminders to check that finishing one leaves the other scheduled.

Nudge uses the iPhone's local date, time, and time zone. A recurring 8 AM reminder stays at 8 AM across daylight saving changes. When the clock skips a time in spring, Nudge uses the next available time and shows the adjustment in the editor. When a time occurs twice in fall, Nudge uses the first occurrence. Snooze and nag intervals count elapsed minutes. Nudge refreshes queued alerts when it opens or iOS reports a clock change.

Nudge hands its alerts to iOS in advance. The test build uses a budget of 60 pending requests, prioritizes one alert per active reminder, and uses the remaining slots for nudges. Nudge replenishes those slots when it opens or handles a notification action. With a single reminder on a two-minute interval, the initial queue covers 118 minutes after its first alert. Coverage varies with other reminders. iOS controls presentation, display wake, and vibration.
