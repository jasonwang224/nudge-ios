import Foundation

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
}
func current(_ snapshot: ReminderSnapshot, _ id: UUID) -> Reminder {
    snapshot.reminders.first { $0.id == id }!
}
let now = date(7, 9)
var preferences = ReminderPreferences()
preferences.repeatRule = .daily
var daily = Reminder(title: "Feed cat", notes: "Original", due: date(7, 8), repeatAnchor: date(1, 8), preferences: preferences)
daily.phoneSchedule = PhoneSchedule(day: date(1, 8), hour: 8, minute: 0, calendar: calendar)
let dailyDueComponents = calendar.dateComponents([.era, .year, .month, .day], from: daily.due)
daily.phoneSchedule?.day = dailyDueComponents
let unrelated = Reminder(title: "Unrelated", notes: "Keep me", due: date(8, 18), repeatAnchor: date(8, 18), preferences: ReminderPreferences())
let original = ReminderSnapshot(reminders: [daily, unrelated])
let november9 = date(9, 8)
let projectedNinth = ReminderOccurrence.entries(reminders: original.reminders, on: november9, now: now, calendar: calendar)
    .first { $0.reminder.id == daily.id && $0.isProjected }!
let markedNinth = ReminderLifecycle.completingProjected(projectedNinth, in: original, now: now, calendar: calendar)!
let seriesWithNinthDone = current(markedNinth.snapshot, daily.id)
precondition(markedNinth.retiring == nil && markedNinth.snapshot.stoppedNotificationGenerations == nil)
precondition(seriesWithNinthDone.generation == daily.generation && seriesWithNinthDone.alertDate == daily.alertDate)
precondition(current(markedNinth.snapshot, unrelated.id) == unrelated)
precondition(ReminderLifecycle.completingProjected(projectedNinth, in: markedNinth.snapshot, now: now, calendar: calendar) == nil)
precondition(ReminderLifecycle.completingProjected(ReminderOccurrence(daily, projectedDate: date(9, 7)),
    in: original, now: now, calendar: calendar) == nil, "Done requires the actual occurrence shown for the selected date.")
let ninthAgenda = AgendaPresentation(reminders: markedNinth.snapshot.reminders, todayOnly: true,
    selectedDay: november9, now: now, calendar: calendar)
precondition(ninthAgenda.visible.isEmpty && ninthAgenda.completed.count == 1)
let ninthHistory = ninthAgenda.completed[0]
precondition(ninthHistory.alertDate == november9 && ninthHistory.completedAt == now)
precondition(AgendaPresentation(reminders: markedNinth.snapshot.reminders, todayOnly: true,
    selectedDay: nil, now: now, calendar: calendar).completed.isEmpty)
precondition(ReminderOccurrence.entries(reminders: [seriesWithNinthDone], on: date(10, 8), now: now,
    calendar: calendar).first?.date == date(10, 8))
let markedBytes = try JSONEncoder().encode(markedNinth.snapshot)
let reloadedMarked = try JSONDecoder().decode(ReminderSnapshot.self, from: markedBytes).validated()
precondition(reloadedMarked == markedNinth.snapshot)
let seriesAfterSeventh = ReminderLifecycle.completing(seriesWithNinthDone, in: reloadedMarked, now: now, calendar: calendar)!
let eighth = current(seriesAfterSeventh.snapshot, daily.id)
precondition(eighth.alertDate == date(8, 8), "Completing the ninth ahead of time must preserve the eighth.")
let seriesAfterEighth = ReminderLifecycle.completing(eighth, in: seriesAfterSeventh.snapshot, now: now, calendar: calendar)!
let tenth = current(seriesAfterEighth.snapshot, daily.id)
precondition(tenth.alertDate == date(10, 8) && tenth.precompletedDays == nil,
             "The series must skip the completed ninth and keep its original time on the tenth.")
precondition(AgendaPresentation(reminders: seriesAfterEighth.snapshot.reminders, todayOnly: true,
    selectedDay: date(8, 8), now: now, calendar: calendar).completed.count == 1)
let restoredNinth = ReminderLifecycle.restoring(ninthHistory, in: markedNinth.snapshot, now: now)!
let restoredNinthReminder = current(restoredNinth.snapshot, ninthHistory.id)
precondition(restoredNinthReminder.completedForDay == nil && restoredNinthReminder.alertDate == november9
             && restoredNinthReminder.preferences.repeatRule == .never)
precondition(restoredNinthReminder.phoneSchedule?.dueDate(calendar: calendar) == november9)
precondition(current(restoredNinth.snapshot, daily.id) == seriesWithNinthDone)
let futureOneOffDone = ReminderLifecycle.completing(unrelated, in: original, now: now, calendar: calendar)!
precondition(AgendaPresentation(reminders: futureOneOffDone.snapshot.reminders, todayOnly: true,
    selectedDay: unrelated.due, now: now, calendar: calendar).completed.map(\.id) == [unrelated.id])
var weeklyWithDone = daily
weeklyWithDone.preferences.repeatRule = .weekly
weeklyWithDone.repeatAnchor = daily.due
weeklyWithDone.phoneSchedule?.anchorDay = dailyDueComponents
weeklyWithDone.precompletedDays = [ReminderDay(date(14, 8), calendar: calendar), ReminderDay(date(21, 8), calendar: calendar)]
precondition(weeklyWithDone.nextOccurrence(after: now, calendar: calendar) == date(28, 8))

precondition(AgendaPresentation.includesToday(daily, now: now, calendar: calendar))
precondition(!AgendaPresentation.includesToday(unrelated, now: now, calendar: calendar))
precondition(ReminderLifecycle.adjusting(daily, by: .fiveMinutes, direction: .earlier,
    in: original, now: now, calendar: calendar) == nil)
let firstShift = ReminderLifecycle.adjusting(daily, by: .fiveMinutes, direction: .later,
    in: original, now: now, calendar: calendar)!
let firstMoved = current(firstShift.snapshot, daily.id)
precondition(firstMoved.alertDate == date(7, 9, 5) && firstShift.retiring == daily)
precondition(ReminderLifecycle.adjusting(daily, by: .fiveMinutes, direction: .later,
    in: firstShift.snapshot, now: now, calendar: calendar) == nil, "A stale row cannot move a newer occurrence.")
let secondShift = ReminderLifecycle.adjusting(firstMoved, by: .hour, direction: .later,
    in: firstShift.snapshot, now: now, calendar: calendar)!
let moved = current(secondShift.snapshot, daily.id)
precondition(moved.alertDate == date(7, 10, 5) && moved.generation != firstMoved.generation)
precondition(moved.due == daily.due && moved.phoneSchedule == daily.phoneSchedule && moved.repeatAnchor == daily.repeatAnchor)
precondition(current(secondShift.snapshot, unrelated.id) == unrelated)
precondition(AlertPlan(reminders: secondShift.snapshot.reminders, now: now).alerts.first?.date == moved.alertDate)
precondition(!AgendaPresentation.canSnooze(ReminderOccurrence(moved), now: now))
let moveToTomorrow = ReminderLifecycle.adjusting(moved, by: .day, direction: .later,
    in: secondShift.snapshot, now: now, calendar: calendar)!
let tomorrowMoved = current(moveToTomorrow.snapshot, daily.id)
precondition(tomorrowMoved.alertDate == date(8, 10, 5))
precondition(!AgendaPresentation.includesToday(tomorrowMoved, now: now, calendar: calendar))
let movedDone = ReminderLifecycle.completing(tomorrowMoved, in: moveToTomorrow.snapshot,
    now: date(8, 10, 6), calendar: calendar)!
let nextAfterMove = current(movedDone.snapshot, daily.id)
precondition(nextAfterMove.adjustedDue == nil && nextAfterMove.alertDate == date(9, 8),
             "Moving an occurrence must not change the series time.")
let moveBytes = try JSONEncoder().encode(moveToTomorrow.snapshot)
let decodedMove = try JSONDecoder().decode(ReminderSnapshot.self, from: moveBytes).validated()
precondition(decodedMove == moveToTomorrow.snapshot)
let spring = calendar.date(from: DateComponents(year: 2027, month: 3, day: 13, hour: 9))!
let springNext = calendar.date(from: DateComponents(year: 2027, month: 3, day: 14, hour: 9))!
precondition(ReminderTimeShift.day.date(from: spring, direction: .later, now: now, calendar: calendar) == springNext)

precondition(ReminderLifecycle.snoozing(unrelated, in: original, now: now) == nil,
             "Snooze must not move tomorrow's reminder to fifteen minutes from now.")

let snooze = ReminderLifecycle.snoozing(daily, in: original, now: now)!
let snoozed = current(snooze.snapshot, daily.id)
precondition(snoozed.snoozedUntil == now.addingTimeInterval(900))
precondition(snoozed.due == daily.due && snoozed.repeatAnchor == daily.repeatAnchor && snoozed.phoneSchedule == daily.phoneSchedule)
precondition(snoozed.generation != daily.generation && snooze.retiring == daily)
precondition(current(snooze.snapshot, unrelated.id) == unrelated)
precondition(ReminderLifecycle.snoozing(daily, in: snooze.snapshot, now: now) == nil)
precondition(ReminderLifecycle.completing(daily, in: snooze.snapshot, now: now, calendar: calendar) == nil)

// Editing metadata or the repeat pattern must not undo a user's active Snooze.
var edited = snoozed
edited.notes = "Changed note"
let noteEdit = try ReminderLifecycle.saving(edited, replacing: snoozed.generation, expecting: snoozed,
                                          in: snooze.snapshot, now: now)
precondition(current(noteEdit.snapshot, daily.id).snoozedUntil == snoozed.snoozedUntil)
precondition(current(noteEdit.snapshot, daily.id).phoneSchedule?.anchorDay == daily.phoneSchedule?.anchorDay)
edited.preferences.repeatRule = .weekly
edited.repeatAnchor = edited.due
let editedDay = edited.phoneSchedule!.day
edited.phoneSchedule?.anchorDay = editedDay
let patternEdit = try ReminderLifecycle.saving(edited, replacing: snoozed.generation, expecting: snoozed,
                                             in: snooze.snapshot, now: now)
let weekly = current(patternEdit.snapshot, daily.id)
precondition(weekly.snoozedUntil == snoozed.snoozedUntil, "Changing only recurrence must preserve Snooze.")
precondition(weekly.phoneSchedule?.anchorDay == weekly.phoneSchedule?.day)
precondition(weekly.nextOccurrence(after: now, calendar: calendar) == date(14, 8))

edited.due = date(7, 10)
edited.phoneSchedule = PhoneSchedule(day: edited.due, hour: 10, minute: 0, calendar: calendar)
let rescheduled = try ReminderLifecycle.saving(edited, replacing: snoozed.generation, expecting: snoozed,
                                             in: snooze.snapshot, now: now)
precondition(current(rescheduled.snapshot, daily.id).snoozedUntil == nil)
precondition(current(rescheduled.snapshot, daily.id).repeatAnchor == edited.due)

// Done advances the series, creates one independent history item, and invalidates
// the old notification action so repeated taps cannot complete the next day.
let completionTime = now.addingTimeInterval(120)
let done = ReminderLifecycle.completing(snoozed, in: snooze.snapshot, now: completionTime, calendar: calendar)!
let nextDay = current(done.snapshot, daily.id)
let history = done.snapshot.reminders.first { $0.completedAt != nil }!
precondition(nextDay.due == date(8, 8) && nextDay.completedAt == nil && nextDay.snoozedUntil == nil)
precondition(nextDay.phoneSchedule?.anchorDay == daily.phoneSchedule?.anchorDay)
precondition(history.id != daily.id && history.due == daily.due && history.completedAt == completionTime)
precondition(done.snapshot.reminders.count == 3 && current(done.snapshot, unrelated.id) == unrelated)
precondition(ReminderLifecycle.completing(snoozed, in: done.snapshot, now: completionTime, calendar: calendar) == nil)
let snoozedNag = PendingNudge(ScheduledAlert(reminder: snoozed, index: 1, date: now).identifier)!
let nextDayNag = PendingNudge(ScheduledAlert(reminder: nextDay, index: 1, date: nextDay.due).identifier)!
let unrelatedNag = PendingNudge(ScheduledAlert(reminder: unrelated, index: 1, date: unrelated.due).identifier)!
let completedGenerations = done.snapshot.stoppedNotificationGenerations ?? []
precondition(snoozedNag.canRetire(current: [daily.id: nextDay], deletedIDs: [], queuedReplacement: [],
                                stoppedGenerations: completedGenerations, now: now),
             "Done must stop the completed recurring occurrence even when permission prevents its next alert.")
precondition(!nextDayNag.canRetire(current: [daily.id: nextDay], deletedIDs: [], queuedReplacement: [],
                                 stoppedGenerations: completedGenerations, now: now))
precondition(!unrelatedNag.canRetire(current: [unrelated.id: unrelated], deletedIDs: [], queuedReplacement: [],
                                   stoppedGenerations: completedGenerations, now: now))
let beforeSnoozeNag = PendingNudge(ScheduledAlert(reminder: daily, index: 1, date: now).identifier)!
precondition(!beforeSnoozeNag.canRetire(current: [daily.id: snoozed], deletedIDs: [], queuedReplacement: [],
                                      stoppedGenerations: snooze.snapshot.stoppedNotificationGenerations ?? [], now: now),
             "Snooze still needs an accepted replacement; only explicit completion adds stop evidence.")
let tomorrow = ReminderOccurrence.entries(reminders: done.snapshot.reminders, on: date(8, 0), now: now, calendar: calendar)
precondition(tomorrow.filter { $0.reminder.id == daily.id }.count == 1)
precondition(tomorrow.first { $0.reminder.id == daily.id }?.isProjected == false)

let undo = ReminderLifecycle.restoring(history, in: done.snapshot, now: completionTime)!
let restored = current(undo.snapshot, history.id)
precondition(restored.completedAt == nil && restored.preferences.repeatRule == .never)
precondition(restored.due == history.due && restored.snoozedUntil == nil)
precondition(current(undo.snapshot, daily.id) == nextDay, "Restoring history must not alter the ongoing series.")
precondition(ReminderLifecycle.restoring(history, in: undo.snapshot, now: completionTime) == nil)
let deletion = ReminderLifecycle.deleting(restored, in: undo.snapshot)!
precondition(deletion.snapshot.deletedIDs.contains(restored.id))
precondition(deletion.snapshot.reminders.count == 2 && current(deletion.snapshot, daily.id) == nextDay)
do {
    _ = try ReminderLifecycle.saving(restored, replacing: nil, in: deletion.snapshot, now: now)
    preconditionFailure("Saving a deleted identifier must not resurrect it.")
} catch ReminderLifecycle.Problem.deleted {}

// Turning nags off after the first alert must stop pending nags without deleting
// the only delivered card. Its existing Done/Snooze identity stays valid.
var off = daily
off.preferences.nagMinutes = 0
off.title = "Updated cat reminder"
let stopNags = try ReminderLifecycle.saving(off, replacing: daily.generation, expecting: daily, in: original, now: now)
let noNags = current(stopNags.snapshot, daily.id)
precondition(noNags.generation == daily.generation && stopNags.retiring == nil)
precondition(AlertPlan(reminders: [noNags], now: now).alerts.isEmpty)
let oldNag = PendingNudge(ScheduledAlert(reminder: daily, index: 2, date: now).identifier)!
precondition(oldNag.canRetire(current: [daily.id: noNags], deletedIDs: [], queuedReplacement: [], now: now))
precondition(ReminderLifecycle.completing(daily, in: stopNags.snapshot, now: now, calendar: calendar) != nil,
             "The retained card's Done action must still work.")

do {
    _ = try ReminderLifecycle.saving(off, replacing: daily.generation, expecting: daily, in: stopNags.snapshot, now: now)
    preconditionFailure("Same-generation card preservation must not allow a stale editor to overwrite changes.")
} catch ReminderLifecycle.Problem.changed {}
var acceptedSnapshot = original
acceptedSnapshot.reminders[0].soundOnlyAfterIndex = 0
acceptedSnapshot.reminders[0].soundOnlyAnchorAccepted = true
let acceptedEdit = try ReminderLifecycle.saving(off, replacing: daily.generation, expecting: daily, in: acceptedSnapshot, now: now)
precondition(current(acceptedEdit.snapshot, daily.id).soundOnlyAnchorAccepted == true)

// Disabling notifications is explicit stop evidence even if permission is denied.
var disabled = daily
disabled.preferences.notifications = false
let notificationsOff = try ReminderLifecycle.saving(disabled, replacing: daily.generation, expecting: daily,
                                                   in: original, now: now)
precondition(oldNag.canRetire(current: [daily.id: current(notificationsOff.snapshot, daily.id)],
                             deletedIDs: [], queuedReplacement: [], now: now))
let removed = ReminderLifecycle.deleting(daily, in: original)!
precondition(oldNag.canRetire(current: [unrelated.id: unrelated], deletedIDs: removed.snapshot.deletedIDs,
                             queuedReplacement: [], now: now))
precondition(!oldNag.canRetire(current: [:], deletedIDs: [], queuedReplacement: [], now: now),
             "An absent record is never enough evidence to cancel a notification.")

// If an edit A -> B cannot queue B, A is deliberately retained. Done on B must
// retire both observed A and current B, rather than leaving A nagging forever.
var failedEditDraft = daily
failedEditDraft.title = "Edited while scheduling failed"
let failedEdit = try ReminderLifecycle.saving(failedEditDraft, replacing: daily.generation, expecting: daily,
                                            in: original, now: now)
let generationB = current(failedEdit.snapshot, daily.id)
let generationANag = PendingNudge(ScheduledAlert(reminder: daily, index: 3, date: now).identifier)!
let generationBNag = PendingNudge(ScheduledAlert(reminder: generationB, index: 3, date: now).identifier)!
precondition(!generationANag.canRetire(current: [daily.id: generationB], deletedIDs: [], queuedReplacement: [], now: now),
             "A failed edit must preserve its old pending fallback until explicit completion.")
let completedAfterFailedEdit = ReminderLifecycle.completing(generationB, in: failedEdit.snapshot, now: now,
    calendar: calendar, observedGenerations: [generationANag.generationIdentifier])!
let generationC = current(completedAfterFailedEdit.snapshot, daily.id)
let generationCNag = PendingNudge(ScheduledAlert(reminder: generationC, index: 3, date: generationC.due).identifier)!
let exactStops = completedAfterFailedEdit.snapshot.stoppedNotificationGenerations ?? []
for pending in [generationANag, generationBNag] {
    precondition(pending.canRetire(current: [daily.id: generationC], deletedIDs: [], queuedReplacement: [],
                                  stoppedGenerations: exactStops, now: now))
}
precondition(!generationCNag.canRetire(current: [daily.id: generationC], deletedIDs: [], queuedReplacement: [],
                                     stoppedGenerations: exactStops, now: now))
precondition(!unrelatedNag.canRetire(current: [unrelated.id: unrelated], deletedIDs: [], queuedReplacement: [],
                                   stoppedGenerations: exactStops, now: now))
precondition(ReminderLifecycle.completing(generationB, in: completedAfterFailedEdit.snapshot, now: now,
    calendar: calendar, observedGenerations: [generationANag.generationIdentifier]) == nil,
    "A concurrent second Done must not advance the new occurrence.")
precondition(ReminderLifecycle.completing(generationB, in: failedEdit.snapshot, now: now,
    calendar: calendar, observedGenerations: [unrelatedNag.generationIdentifier]) == nil)
precondition(ReminderLifecycle.completing(generationB, in: failedEdit.snapshot, now: now,
    calendar: calendar, observedGenerations: ["nudge.*"]) == nil)

// Save the real transitions through the database and reload them, including
// recurrence/history and deletion tombstones. No action may replace unrelated data.
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let suite = "Nudge.LifecycleChecks.\(UUID().uuidString)"
let disk = UserDefaults(suiteName: suite)!
defer {
    try? FileManager.default.removeItem(at: directory)
    disk.removePersistentDomain(forName: suite)
}
let database = ReminderDatabase(url: directory.appendingPathComponent("Reminders.json"), preferences: disk)
let oldSchemaBytes = try JSONEncoder().encode(original)
let oldSchemaJSON = try JSONSerialization.jsonObject(with: oldSchemaBytes) as! [String: Any]
precondition(oldSchemaJSON["stoppedNotificationGenerations"] == nil)
let oldSchema = try JSONDecoder().decode(ReminderSnapshot.self, from: oldSchemaBytes).validated()
precondition(oldSchema == original && oldSchema.stoppedNotificationGenerations == nil)
var invalidStop = original
invalidStop.stoppedNotificationGenerations = ["nudge.*"]
do {
    _ = try invalidStop.validated()
    preconditionFailure("Invalid or wildcard notification stops must be rejected.")
} catch ReminderDatabase.Problem.invalid {}
invalidStop.stoppedNotificationGenerations = ["\(daily.id.uuidString).\(daily.generation.uuidString)"]
do {
    _ = try invalidStop.validated()
    preconditionFailure("A stop token must not target the current active occurrence.")
} catch ReminderDatabase.Problem.invalid {}
var source = try database.commit(original, replacing: .missing)
source = try database.commit(snooze.snapshot, replacing: source)
source = try database.commit(done.snapshot, replacing: source)
source = try database.commit(undo.snapshot, replacing: source)
source = try database.commit(deletion.snapshot, replacing: source)
let reloaded = try database.read()
precondition(reloaded == source)
if case let .file(reloadedSnapshot) = reloaded {
    precondition(snoozedNag.canRetire(current: Dictionary(uniqueKeysWithValues: reloadedSnapshot.reminders.map { ($0.id, $0) }),
                                    deletedIDs: reloadedSnapshot.deletedIDs, queuedReplacement: [],
                                    stoppedGenerations: reloadedSnapshot.stoppedNotificationGenerations ?? [], now: now),
                 "Completion evidence must survive process restart and database reload.")
} else { preconditionFailure("Expected persisted lifecycle state.") }
precondition(current(deletion.snapshot, unrelated.id) == unrelated)

// This is a second independently-created database, with a distinct migration marker.
let failedSuite = "Nudge.FailedEditChecks.\(UUID().uuidString)"
let failedDisk = UserDefaults(suiteName: failedSuite)!
defer { failedDisk.removePersistentDomain(forName: failedSuite) }
let independentDatabase = ReminderDatabase(url: directory.appendingPathComponent("FailedEdit.json"), preferences: failedDisk)
var failedSource = try independentDatabase.commit(original, replacing: .missing)
failedSource = try independentDatabase.commit(failedEdit.snapshot, replacing: failedSource)
failedSource = try independentDatabase.commit(completedAfterFailedEdit.snapshot, replacing: failedSource)
let reloadedFailure = try independentDatabase.read()
precondition(reloadedFailure == failedSource)
if case let .file(afterRestart) = reloadedFailure {
    let currentByID = Dictionary(uniqueKeysWithValues: afterRestart.reminders.map { ($0.id, $0) })
    for pending in [generationANag, generationBNag] {
        precondition(pending.canRetire(current: currentByID, deletedIDs: afterRestart.deletedIDs, queuedReplacement: [],
                                      stoppedGenerations: afterRestart.stoppedNotificationGenerations ?? [], now: now))
    }
    precondition(current(afterRestart, unrelated.id) == unrelated)
} else { preconditionFailure("Expected reloaded completion after a failed edit.") }

print("Lifecycle integration checks passed: edit, Snooze, Done, repeat history, restore, delete, stale actions, card preservation, and persistence.")


// Removing the alerts switch must not lose/remap records or change their times.
var alertsOffSnapshot = original
for index in alertsOffSnapshot.reminders.indices {
    alertsOffSnapshot.reminders[index].preferences.notifications = false
}
var legacyHistory = alertsOffSnapshot.reminders[0]
legacyHistory.id = UUID()
legacyHistory.completedAt = now
alertsOffSnapshot.reminders.append(legacyHistory)
alertsOffSnapshot.deletedIDs.insert(UUID())
let enabledSnapshot = ReminderLifecycle.enablingNotifications(in: alertsOffSnapshot)
precondition(enabledSnapshot.reminders.count == alertsOffSnapshot.reminders.count)
precondition(enabledSnapshot.deletedIDs == alertsOffSnapshot.deletedIDs)
precondition(enabledSnapshot.stoppedNotificationGenerations == alertsOffSnapshot.stoppedNotificationGenerations)
for (before, after) in zip(alertsOffSnapshot.reminders, enabledSnapshot.reminders) {
    if before.completedAt != nil { precondition(before == after) }
    else {
        var expected = before
        expected.preferences.notifications = true
        precondition(after == expected, "Enabling alerts must preserve every other reminder field.")
    }
}
precondition(ReminderLifecycle.enablingNotifications(in: enabledSnapshot) == enabledSnapshot)
_ = try enabledSnapshot.validated()
print("Always-on notification upgrade preserves reminder identities, schedules, history and deletion evidence.")
