# Nudge development and release notes

[Back to Nudge](../README.md)

This document preserves the build instructions, audit notes, and development history from the original README. The current release is 1.1.8 (20). Sections explicitly labeled as experiments describe older builds and are not instructions for the current app.

Native SwiftUI reminder app for the iPhone 11 Pro on iOS 17.4.1. The deployment target is iOS 17.4.

On a Mac with Xcode, run `bash scripts/build-ipa.sh`. GitHub Actions runs the same script on macOS, checking agenda/calendar behavior, notifications, and database safeguards before building. Download the **Nudge-1.1.8-Unsigned** artifact and extract the IPA. Use a sideloading tool to sign it with a provisioning profile for your iPhone. This is build 20, using the existing `com.jasonwang224.nudge` identifier. Install over the existing app with the same signing account and app identifier to retain its reminders, then open the app once to refresh queued notifications.

## Version 1.1.8 (20)

The **1 min** Nag Me option tests an iOS legacy repeating trigger with one request identifier per reminder occurrence. The app verifies that iOS accepted a repeating request and falls back to individual alerts if needed. Confirm card reuse on the iOS 17.4.1 Lock Screen before relying on it.

## Version 1.1.6 (18)

The time adjustment submenu and the confirmed Done action animate with Reduce Motion enabled.

## Version 1.1.5 (17)

The original Glass is available alongside Digital Glass. Time adjustments and confirmed completions animate in the agenda.

## Version 1.1.4 (16)

Glass uses the Awesome Notification sound by KoiRoylers.

## Version 1.1.3 (15)

Time adjustments animate when expanded or collapsed. Completing a reminder from the agenda opens a Cancel or Done confirmation, and the list animates after the completion is saved. Digital Chime is available as a notification sound.

## Version 1.1.2 (14)

- Yearly is available in the reminder editor and default settings. February 29 uses February 28 in common years and returns to February 29 in leap years.

## Version 1.1.1 (13)

- Every reminder on a future date in Today has a Done control. Completed items appear under the date you marked, and recurring rows use the same repeat label.
- Marking a future repeat Done leaves the current occurrence and its queued alerts in place. As the series advances, it skips the completed date and schedules the next eligible occurrence.

## Version 1.1.0 (12)

- Tap a reminder row to open or close the time menu. Each valid adjustment saves immediately and keeps the row in place until the menu closes. The three dots contain the full editor.
- Tapping a current Lock Screen alert opens the reminder’s menu on Today or Upcoming. Later choices start from now for a fired reminder. Choices that would schedule a past time are disabled.
- A quick adjustment affects the current occurrence. Repeat schedules retain their original time. The saved adjustment is an optional field in the version 1 database.

## Version 1.0.9 (11)

- The number pad’s Done button formats typed times, such as `300` to `3:00`.
- Lock Screen alerts show reminder notes when present. The generated hold instructions are gone, and queued alerts are refreshed in place.
- Settings removes the test alert card.

## Version 1.0.8 (10) — whole-app audit fixes

This release includes the independently reviewed editor, agenda, lifecycle, and calendar fixes below. It retains normal visible nag notifications, Done, and Snooze 15 min. The database format remains version 1 with backward-compatible optional fields; no reminder reset is required.

- Creating from a future date in Today now starts the editor on that date. Today/Tomorrow/day-name shortcuts refresh across midnight and calculate from the current phone date when tapped. The highlighted card has the same eligible actions as normal rows. Today filters completion history by completion date; Upcoming retains all history.
- Changing repeat patterns reanchors the series to the displayed date. Changing only the time preserves month-end anchors. Repeat edits preserve an active Snooze; changing its actual date/time reschedules it and ends that Snooze.
- Weekdays and custom repeat rules validate the initial date. Unchanged older schedules remain editable. Custom defaults retain at least one selected day. Time entry rejects malformed input, stays blank for new reminders, and handles noon/midnight through AM/PM.
- Repeated Save taps cannot create duplicate reminders. Full editor snapshots reject stale edits while allowing internal scheduling confirmations to finish.
- A saved reminder retains its calendar system when the phone changes calendars, while still following the phone's time zone. Legacy migration recognizes Gregorian (including equivalent ISO dates), Buddhist, and Japanese schedules only when the saved absolute date identifies one safely. Other or ambiguous legacy calendars remain untouched and can be confirmed by explicitly changing the date or time. Newly saved schedules record their calendar identity directly.
- Open Nudge after changing the phone's calendar system so it can repair any queued calendar trigger whose interpretation no longer matches the saved due date. Behavior during a calendar-system change with Nudge closed still needs device validation.
- During the repeated daylight-saving hour, a newly selected time uses the second occurrence if the first is already past and the second is still future. That choice survives saving and refreshing; later recurring dates return to the first occurrence.
- Snooze is available only after a reminder is due, so it cannot bring tomorrow's reminder forward. Expired snoozes show their actual expiration time.
- Nag Off cancels obsolete followups even for overdue reminders with no future primary. Editing such a reminder preserves its existing actionable card; its displayed old title may remain until that card is dismissed.
- Explicit Done/Delete/notification-off cancellation runs even when notification permission is denied. Done settles in-flight scheduling, gathers older queued generations left by failed edits, rechecks the current occurrence, and saves exact completion-stop records atomically. The added optional field preserves existing version-1 database compatibility. Notification removal remains scoped; missing data never authorizes clearing alerts.
- Scheduling failures and queue capacity warnings are visible from the agenda. Notifications-off cards do not promise an alert.

`bash scripts/check-source.sh` parses and type-checks the complete app against iOS 17.4 without building an app. It executes seven source test suites covering editor validation and defaults, repeat/date projections, agenda sections, calendar/time-zone changes, complete reminder lifecycles and persistence, and 420 repeat/nag/sound/notification combinations. The IPA build script runs this same suite before packaging each release.

The checks exercise the production helpers used by the SwiftUI views and store. Native layout, Dynamic Type, VoiceOver, system permissions, actual audio/haptics, and closed-app Lock Screen delivery still require simulator/device testing. Source tests do not substitute for those runtime checks. Restoring a completed past occurrence returns it to Needs attention at its original time; it does not invent a new due time or change the active recurring series.

## Version 1.0.7 (9)

Settings no longer contains the notification preview or the sound-only experiment section. Sound-only mode is disabled in the app regardless of the previous saved toggle. On opening this version, reconciliation replaces safely-future sound-only requests with normal visible nags under the same identifiers; reminders are preserved. Nags use full notifications with the selected sound and existing Done and Snooze 15 min actions. Multiple cards can accumulate while the app is closed. The single-notification investigation is on hold; this release introduces no new notification experiment.

The Today date strip now shows planned recurring occurrences on future days, including daily, weekday, weekly, monthly, and custom repeats. Dates and indicator dots use the same calendar projection. Future previews keep the original reminder as their source; they cannot complete or snooze today's occurrence. Editing and deleting a future preview targets the repeating reminder. Projections do not add database records or change notification scheduling. Completing the current occurrence still advances the actual recurring schedule.

The `checks/**` workflow runs calendar, notification, and database checks plus iOS Swift type checking. It does not build an app or package an IPA.

## Alarmed investigation — research only

The strongest untried candidate is one full-content repeating notification with a stable identifier. Published iOS 18.2 code [reposts the same record](https://github.com/EthanArbuckle/iPhone17-1_18.2_22C152_Restore/blob/e26ed4563f78871c59d2d96856756a65d62517e5/System/Library/PrivateFrameworks/UserNotificationsCore.framework/UNCLocalNotificationClient.m#L916), and BulletinBoard [reuses the existing bulletin ID](https://github.com/EthanArbuckle/iPhone17-1_18.2_22C152_Restore/blob/e26ed4563f78871c59d2d96856756a65d62517e5/System/Library/PrivateFrameworks/BulletinBoard.framework/BBServer.m#L10150). This supports a test candidate, not a verified result on iOS 17.4.1 or proof of Alarmed's implementation.

The legacy trigger supports a chosen future first date followed by minute repeats. A modern repeating interval supports two or five minutes, but its first delivery is one interval after scheduling; a separate arbitrary future start remains unresolved. Alarmed's [developer workaround](https://yoctoville.com/workarounds) distinguishes Relentless one-minute mode from custom Nag-Me even at the same interval. No Alarmed binary was available for direct inspection, and no repeating-request experiment was built.

Both previous experiments failed on the user's iOS 17.4.1 device. The expiration property survived readback while old cards remained visible. In the sound-only test, the first full alert sounded but subsequent textless requests did not. An inspected iOS 18.2 [background-delivery path explicitly logs sound suppression for notifications without alert content](https://github.com/EthanArbuckle/iPhone17-1_18.2_22C152_Restore/blob/e26ed4563f78871c59d2d96856756a65d62517e5/System/Library/PrivateFrameworks/UserNotificationsCore.framework/UNCLocalNotificationRepository.m#L469); that matches the symptom but is not direct proof of the 17.4.1 implementation.

## Archived sound-only nag experiment (1.0.6)

The following describes the previously built 1.0.6 IPA, not the current source. Its sound-only behavior failed the device test and is disabled in 1.0.7.

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

Nudge uses the iPhone's local date, time, and time zone. A recurring 8 AM reminder stays at 8 AM across daylight saving changes. When the clock skips a time in spring, Nudge uses the next available time and shows the adjustment in the editor. Recurring dates use the first occurrence of a repeated fall time; an explicitly created reminder can use the second occurrence when the first is already past. Snooze and nag intervals count elapsed minutes. Nudge refreshes queued alerts when it opens or iOS reports a clock change.

Nudge hands its alerts to iOS in advance. It uses a budget of 60 pending requests, prioritizes one alert per active reminder, and uses the remaining slots for nudges. Sound-only requests still use queue slots. Nudge replenishes those slots when it opens or handles a notification action. With a single reminder on a two-minute interval, the initial queue covers 118 minutes after its first alert. Coverage varies with other reminders. iOS controls presentation, display wake, sound, and vibration; permissions, Focus, Silent mode, and scheduled delivery can affect the result.

Version 1.0.1 moved reminders into a file that is replaced atomically when changes are saved. An unreadable database pauses changes and leaves pending alerts alone. As an upgrade check, create two reminders in the previous build, then install the update over it. Confirm both remain and that completing one from the Lock Screen leaves the other scheduled.

Completed recurring occurrences appear in history. Restoring one creates a one-time reminder for that occurrence and keeps the recurring schedule intact.
