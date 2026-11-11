# Five-minute shared-identifier probe

Separate test app for iPhone 11 Pro, iOS 17.4.1. Display name: **5 Min Probe**.
Bundle identifier: `com.jasonwang224.nudge.fiveminuteprobe`, version 1.0 (1).
This app must be installed separately; do not override its bundle identifier with the main app's identifier when signing. The runtime disables notification operations unless the bundle identifier matches the probe (or a signing suffix on it). No app group or shared database access is included.

Start schedules its first alert 90 seconds later, followed by five-minute nags. Twelve legacy hourly triggers have staggered first dates and the same request identifier. The private bulk setter is intentionally restricted to this isolated app, because inspected iOS code clears delivered local notifications in the calling bundle before replacing its pending schedule.

The app reads back and validates every phase's actual trigger date, repeat unit, identifier and phase metadata. On failed validation or missing callback, cancellation is requested for probe-owned alerts. A successful callback alone is not accepted as success. No finite individual-alert fallback is scheduled: this is a test of the specific shared-ID mechanism.

## Device test

1. Sideload the unsigned IPA under its own identifier. Keep the main app installed.
2. Open **5 Min Probe** and allow notifications. Enable Lock Screen and Sounds for this app. Use audible notification settings for the sound check.
3. Tap **Start in 90 seconds**. Wait for the message that iOS retained 12 phases.
4. Close the test app and lock the phone. Do not dismiss or act on the first card.
5. Observe the first alert and the next two, five minutes apart. Check the expanded notification list as well as the collapsed group: there should be one card, not a stack hiding older cards.
6. For the repeat-boundary check, continue through +60 and +65 minutes from the first alert.
7. Open the probe and share its diagnostics. Opening/refreshing is read-only and does not clear or reschedule notifications. API record counts do not prove visible card count.
8. Tap **Stop test**, or use **Done** on its notification. **Snooze 15 min** cancels this test and schedules a fresh test beginning 15 minutes later. Old notification actions are ignored using the run token.

Pending phases, visible replacement, sound delivery, second-hour repeat, stop/snooze while locked, reboot and daylight-saving behavior require device testing. Source research is based mainly on iOS 18.2 implementation and iOS 17.0/17.0.3 declarations; none substitutes for this iOS 17.4.1 test.

## Build

Run `bash Checks/FiveMinuteProbe/build.sh` on macOS with Xcode.
The workflow builds only this standalone SwiftUI source, not the production app.
