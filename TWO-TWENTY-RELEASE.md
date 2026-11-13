# 1.1.12 (24): two- and twenty-minute shared-card nags

Extends the existing protected hourly-phase scheduler to 2 and 20 minutes. Two-minute groups use 30 pending entries, twenty-minute groups use 3. Each group shares one request identifier so successive deliveries can update the same card. The supported hourly-phase intervals are now 2, 5, 10, 15, 20 and 30 minutes; one-minute nags retain their separate existing method.

The same safeguards preserve unrelated cards, reserve other reminders' first alerts, validate complete groups, retain accepted anchors, and recover interrupted scheduling without resetting the reminder database. Insufficient capacity still produces an explicit limited-queue warning rather than accepting an incomplete repeating group.

Regression checks cover seven-day fixed-time cadence arithmetic at every starting minute offset for all supported intervals; thirty-phase and three-phase archive recovery; two-minute capacity pressure at 60 and 63 slots; mixed-interval budgets; and Snooze, Done, daily repeats and interval-edit generation isolation. These checks do not establish new-interval behavior on the phone: verify 2- and 20-minute sounds, single-card replacement, preservation of unrelated cards, operation beyond the first hour, Snooze and Done on iOS 17.4.1.

Install over the existing app and open it to update schedules. Do not uninstall to upgrade. As in the previous release, check capacity/recovery status before closing; an interrupted scheduling transaction can pause alerts until recovery runs.
