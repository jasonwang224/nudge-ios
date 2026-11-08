# Nudge for iPhone

Native SwiftUI reminder app for the iPhone 11 Pro on iOS 17.4.1. The deployment target is iOS 17.4.

On a Mac with Xcode, run `bash scripts/build-ipa.sh`. GitHub Actions runs the same script on macOS. Download the **Nudge-1.0.6-Unsigned** artifact and extract the IPA. Use a sideloading tool to sign it with a provisioning profile for your iPhone. This is build 8, using the existing `com.jasonwang224.nudge` identifier. Install with the same signing account and app identifier.

## Sound-only nag experiment (1.0.6)

**Settings → Sound-only Nag Test → Sound-only nags** is on by default. For new reminders with a sound selected, the first notification contains the reminder text and the **Done** and **Snooze 15 min** actions. Later nags request only that sound, with no alert text. They use the reminder's selected interval, including two or five minutes. This is a device experiment: verify sound, vibration, and the absence of extra cards on iOS 17.4.1 before relying on it.

The original card keeps its original timestamp. Sound-only nags do not renew it or restore it after dismissal. If it is swiped away, use Nudge to snooze or complete the reminder. A reminder whose sound is **Silent** continues to use normal visible nag notifications; the app does not override Silent with a sound. Turning the experiment off restores visible nags for upcoming alerts.

Snooze stops that reminder's previous queue and schedules a new visible notification after 15 minutes, followed by sound-only nags at its selected interval. Done stops only that reminder's current occurrence. For recurring reminders, the next occurrence keeps its normal schedule. Foreground and reopen cleanup exclude sound-only records when deciding which visible card to keep.

### Upgrade and preservation

This build removes the private expiration bridge. Existing safely-future requests are rewritten without private expiration, under the same identifiers, preserving their original delivery dates and awaiting acceptance without canceling first. Requests within five seconds of delivery can retain their previous behavior. Already-delivered cards from 1.0.5 cannot be changed safely; finish the old experiment reminder and start a fresh test.

Existing reminders continue to use normal visible nags until they are edited and saved, Snoozed, or advance to their next repeating occurrence after Done. This avoids converting followups to sound-only while the original card might still carry the failed expiration setting. A newly saved or Snoozed reminder starts with a visible alert before sound-only followups. The global toggle applies to those eligible reminders; turning it on alone does not convert older reminders.

Optional, backward-compatible `soundOnlyAfterIndex` and `soundOnlyAnchorAccepted` fields record the visible anchor and its acceptance by iOS. Sound-only successors require that saved acceptance: if a permission prompt or scheduling delay misses the planned first alert, the first actually accepted request stays visible. Older records without these fields remain readable and use visible nags. The database file version remains unchanged, with no reset or removal of saved reminders. Existing safeguards preserve data when the database is unreadable and preserve queued alerts if a replacement cannot be accepted. Capacity pruning protects visible anchors, including anchors with a later nag index. The app does not cancel all reminders to switch modes.

### Device test

1. Finish the previous experiment reminder. Open Nudge and allow notifications. In iPhone Settings, enable Lock Screen alerts, sounds, and immediate delivery for Nudge. Use a Focus that allows Nudge. For the audible test, turn off Silent mode and use an audible alert volume.
2. Enable **Sound-only nags**, tap **Start a 2-minute test**, and wait for scheduling to finish. Test buttons use Chime. The first notification arrives in 30 seconds.
3. Close Nudge, including a test after swiping it away, lock the iPhone, and let the screen turn off. Ignore the initial sound and at least two nags. Expand any notification stack before counting: the intended result is one original card, its original timestamp, and later sounds without additional cards. Record whether vibration also occurs; iOS controls it.
4. Hold the original card and select **Snooze 15 min**. Check that the old nags stop, a new visible card arrives after about 15 minutes, and the two-minute sound cadence resumes.
5. Select **Done**. Wait at least one nag interval and confirm the sounds stop for that reminder. Keep a second reminder active to verify isolation.
6. Repeat with **Start a 5-minute test**. Also check one test while Nudge stays open: later sounds must not remove the original actionable card.

**Read notification diagnostics** shows records returned by the iOS notification APIs. It does not inspect the Lock Screen or measure the number of visible cards. The report includes reminder titles and is shared only when you choose to share it.

### Previous expiration experiment

Version 1.0.5 requested the undocumented `expirationDate` property. The iPhone retained expiration values, but the user observed multiple old cards before and after opening Nudge. A diagnostic snapshot reported one delivered record despite those visible cards. That experiment failed its visual goal; API readback is not proof that a Lock Screen notification was removed.

## Scheduling and data

Nudge uses the iPhone's local date, time, and time zone. A recurring 8 AM reminder stays at 8 AM across daylight saving changes. When the clock skips a time in spring, Nudge uses the next available time and shows the adjustment in the editor. When a time occurs twice in fall, Nudge uses the first occurrence. Snooze and nag intervals count elapsed minutes. Nudge refreshes queued alerts when it opens or iOS reports a clock change.

Nudge hands its alerts to iOS in advance. It uses a budget of 60 pending requests, prioritizes one alert per active reminder, and uses the remaining slots for nudges. Sound-only requests still use queue slots. Nudge replenishes those slots when it opens or handles a notification action. With a single reminder on a two-minute interval, the initial queue covers 118 minutes after its first alert. Coverage varies with other reminders. iOS controls presentation, display wake, sound, and vibration; permissions, Focus, Silent mode, and scheduled delivery can affect the result.

Version 1.0.1 moved reminders into a file that is replaced atomically when changes are saved. An unreadable database pauses changes and leaves pending alerts alone. As an upgrade check, create two reminders in the previous build, then install the update over it. Confirm both remain and that completing one from the Lock Screen leaves the other scheduled.

Completed recurring occurrences appear in history. Restoring one creates a one-time reminder for that occurrence and keeps the recurring schedule intact.
