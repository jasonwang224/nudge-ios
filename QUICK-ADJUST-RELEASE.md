# 1.1.13 (25): reliable quick time adjustments

Rapid taps on any +/-5-minute, 1-hour, or 1-day button now persist each change and reconcile the latest time after a 0.4-second quiet interval. Existing notification transactions finish serially; an older result cannot replace the latest status. Only generations from the same adjustment burst can reuse an older UI closure.

A narrow one-minute-repeat replacement adds and verifies the changed reminder before retiring its old requests. Every unrelated request, including each duplicate-ID hourly phase, must remain identical. Existing recovery transactions still use the protected recovery path. No notification-budget increase or database-format change is included.

Retired notification cards are cleared in the serialized scheduler before and after replacement. Fresh edits and the Retry alerts button reset the retry budget. Persistent warnings offer shareable read-only details that distinguish missing, extra, content-changed, and trigger-changed records. Strict verification remains enabled.

Validation is performed by scripts/check-source.sh and the IPA workflow: iOS 17.4 typechecking plus scheduling, recurrence, agenda, editor, lifecycle, interactions, calendar, phase matching, rapid-adjustment persistence, and mocked replacement failure/capacity tests. These tests cannot reproduce private iOS notification behavior on the user's phone.

Device check: update over the existing installation, open the app to finish any saved recovery, then test single and rapid taps on all six buttons with one-minute nags and other reminders present. Check the final time, delivery at that time with the app closed, Done/Snooze, and retention of other reminder cards. If recovery remains, use Settings > Notification recovery > Show notification details.
