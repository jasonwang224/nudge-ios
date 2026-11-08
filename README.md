# Nudge for iPhone

Native SwiftUI reminder app for the iPhone 11 Pro on iOS 17.4.1. The deployment target is iOS 17.4.

On a Mac with Xcode, run `bash scripts/build-ipa.sh`. GitHub Actions runs the same script on macOS. Download the **Nudge-1.0.5-Unsigned** artifact and extract the IPA. Use a sideloading tool to sign it with a provisioning profile for your iPhone. This is build 7, using the existing `com.jasonwang224.nudge` identifier. Install with the same signing account and app identifier.

## Experimental notification expiration (1.0.5)

This build enables **Settings → Latest Nag Experiment → Expire previous nags** by default. It probes the undocumented `UNMutableNotificationContent.expirationDate` property. Setting and retaining the property is not proof that iOS 17.4.1 will remove visible cards. The Objective-C bridge checks selectors, catches exceptions, and distinguishes a failed read from a verified empty value. There are no added entitlements, servers, background polling, or database migrations.

The scheduler first submits normal alerts, then requests expiry for a predecessor only when its immediate successor is actually pending. The last accepted alert for each reminder has no expiry. Expiry changes rebuild triggers from original absolute dates and skip alerts within five seconds of delivery. When capacity pruning would break a chain, it first clears and verifies the still-pending predecessor's expiry; it refuses to prune if that predecessor is already delivered or close to delivery. Existing save-before-cancel and unreadable-database safeguards remain in place.

While the experiment is ON, foreground and reopen deduplication are disabled, so they cannot hide an unsuccessful experiment. Done, Snooze, edit, and delete still clear that reminder's retired generation normally. The toggle affects all upcoming reminders. Turning it OFF removes expiry from safely-future current-generation pending alerts; already-delivered or imminent alerts may still expire. It also resumes the older foreground/reopen cleanup.

### Device experiment

1. Finish prior test reminders. Enable the experiment, then tap **Start a 2-minute test**. Wait for scheduling to finish. The first notification arrives in 30 seconds.
2. Leave Nudge (also test swiping it away), lock the iPhone, and let the screen turn off. Ignore the initial alert and at least two nags. Expand any notification stack before counting cards; optionally turn Notification Grouping off in iPhone Settings.
3. Before reopening, record whether older cards disappear, whether a gap occurs before the next card, and whether sound/vibration continue. Expiry is independent of replacement delivery and may be early or batched.
4. Reopen Nudge with the experiment still ON. **Read notification diagnostics** shows delivered cards and requested versus iOS-readback expiry dates. It performs no notification removal. Share/copy the report for investigation; it includes reminder titles.
5. Test **Snooze 15 min**, then **Done**, including a second reminder to verify isolation. Test the five-minute button separately. For a normal-delivery control, finish prior tests, turn the experiment OFF, and create a new test; count cards before reopening.

The device result is unverified until this test is performed. This build remains subject to iOS notification permissions, Focus, scheduled delivery settings, the finite pending queue, and OS delivery timing. The final queued card is intentionally left without an expiry.

Version 1.0.1 moves reminders into a file that is replaced atomically when changes are saved. An unreadable database pauses changes and leaves pending alerts alone. As an upgrade check, create two reminders in the previous build, then install the update over it. Confirm both are still visible and that completing one from the Lock Screen leaves the other scheduled.

## Lock Screen test

1. Open Nudge and allow notifications. In iPhone Settings, enable Lock Screen alerts and immediate delivery for Nudge. Use a Focus that allows Nudge.
2. In **Settings → Lock Screen**, tap **Send a test alert in 30 seconds**. Wait for the queue confirmation. Leave the app, lock the iPhone, and let the display go dark.
3. Confirm the first alert arrives. Leave it alone and check for the next nudge two minutes later.
4. Touch and hold the notification and select **Snooze 15 min**. Check that the old nudges stop and a new alert comes about 15 minutes after the tap. The two-minute cadence resumes from that alert.
5. Select **Done** from the Lock Screen. Wait at least two minutes and check that no more nudges arrive for that test reminder. Repeat the test after swiping Nudge away. Also try two reminders to check that finishing one leaves the other scheduled.

With the expiration experiment OFF, leave Nudge visible while the test reminder alerts twice. Notification Center should keep only the newer alert for that reminder. When you reopen Nudge it also trims duplicates. With the experiment ON, this app-side cleanup is disabled to keep the OS-expiry result observable. iOS can group alerts while the phone is locked.

Nudge uses the iPhone's local date, time, and time zone. A recurring 8 AM reminder stays at 8 AM across daylight saving changes. When the clock skips a time in spring, Nudge uses the next available time and shows the adjustment in the editor. When a time occurs twice in fall, Nudge uses the first occurrence. Snooze and nag intervals count elapsed minutes. Nudge refreshes queued alerts when it opens or iOS reports a clock change.

Nudge hands its alerts to iOS in advance. It uses a budget of 60 pending requests, prioritizes one alert per active reminder, and uses the remaining slots for nudges. Nudge replenishes those slots when it opens or handles a notification action. With a single reminder on a two-minute interval, the initial queue covers 118 minutes after its first alert. Coverage varies with other reminders. iOS controls presentation, display wake, and vibration.

Completed recurring occurrences appear in history. Restoring one creates a one-time reminder for that occurrence and keeps the recurring schedule intact.
