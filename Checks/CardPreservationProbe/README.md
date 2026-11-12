# Card Guard Probe 1.0 (1)

Standalone iPhone experiment for iOS 17.4.1. Bundle `com.jasonwang224.nudge.cardpreservationprobe`. It installs separately from the main app AND the original 5 Min Probe. Sign it with its own identifier; do not change it to the main app's identifier. The runtime guard refuses notification operations under a different identifier (a signing suffix is allowed).

## Test instructions

1. Install/sign `Card-Guard-Probe-1.0-Unsigned.ipa` using your usual sideloading method. Open **Card Guard Probe**, allow notifications, and tap **Create sample cards**.
2. Lock the phone for 90 seconds. Leave **Keep A** and **Keep B** visible. Optionally dismiss ONLY **Dismiss C**. Expand the notification group so you can see individual cards. Take a screenshot to compare their times.
3. Reopen the probe, tap **Install 5-minute nags**, and check its status. If it reports failure, share diagnostics; do not treat it as a pass. If it reports API checks passed, lock the phone and check A and B are still present without a changed time or new sound.
4. The new nag starts 90 seconds after step 3, then every five minutes. Leave it running for two more nags. Each nag should reuse one card while A and B remain. Dismissed C must not return. **Future D** should still arrive 15 minutes after step 1.
5. After two nags, reopen and tap **Repeat preservation check**. Existing cards, including the nag, should stay. This tests updating an already-running five-minute group.
6. Try **Snooze 15 min** on the nag: A and B should stay, and the nag should resume after 15 minutes, then every five minutes. Try **Done**: only the nag stops and its card disappears. Wait ten minutes; A and B should remain. B continues hourly until Reset.
7. For an extended check, let the nag run past +60 and +65 minutes. Then use **Reset this probe** when finished; it removes only this probe's sample cards/schedules.

Opening/refreshing the app reads notifications only. It does not clean up old cards. API record counts do not prove how many Lock Screen cards are visible.

## Failure behavior

This is experimental private API behavior, not a production fix. It first archives the complete original and desired pending schedules in this probe's private Documents directory, pauses pending requests, updates delivered cards without reposting, requires nil-trigger readback plus unchanged content/date, then bulk-submits and verifies the full merged schedule. It never reposts a missing card. If an assertion fails, it stops; test alerts may remain paused, with the journal retained. **Retry interrupted setup** repeats the guarded transaction. If a saved one-time notification is now overdue, Reset and rerun instead of silently replaying it. Interrupted private callbacks are not guaranteed cancelled by a timeout. Wait ten seconds before retrying. Reset is explicit and confirmed.

This does not guarantee atomic recovery after termination, delivery-race safety, or production readiness. It deliberately uses absolute calendar/legacy schedules and rejects unsupported relative interval triggers. No main app database or notification queue is referenced.

## Build

`bash Checks/CardPreservationProbe/build.sh` on macOS with Xcode. Builds one Swift file for arm64 / iOS 17.4, runs schedule-multiset and archive validation checks on macOS, checks the IPA identity, architecture and private selectors. No production sources are compiled. The isolated workflow runs only on `build/card-preservation-probe`.
