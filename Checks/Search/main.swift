import Foundation

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
func date(_ day: Int, _ hour: Int = 12) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
}
let now = date(19)
func make(_ title: String, _ notes: String = "", day: Int = 19, rule: RepeatRule = .never) -> Reminder {
    var prefs = ReminderPreferences(); prefs.repeatRule = rule
    return Reminder(title: title, notes: notes, due: date(day, 15), repeatAnchor: date(day, 15), preferences: prefs)
}
let daily = make("Feed CAT", "Use the blue bowl", day: 18, rule: .daily)
let future = make("Visit Café", "Bring the BLUE notebook", day: 25)
let noteOnly = make("Shopping", "Buy oat milk", day: 21)
var oldDone = make("Feed cat", "Old occurrence", day: 17, rule: .daily)
oldDone.completedAt = date(17, 16)
var snoozed = make("Cat medicine", "After food", day: 18)
snoozed.snoozedUntil = now.addingTimeInterval(900)
let literal = make("Plan [A].*", "")
let original = [daily, future, noteOnly, oldDone, snoozed, literal]
func presentation(_ query: String, today: Bool = true, day: Int = 20, records: [Reminder] = original) -> AgendaPresentation {
    AgendaPresentation(reminders: records, todayOnly: today, selectedDay: date(day), now: now,
                       calendar: calendar, searchText: query)
}
func ids(_ p: AgendaPresentation) -> Set<UUID> { Set(p.visible.map { $0.reminder.id }) }
precondition(ids(presentation("cat")) == Set([daily.id, snoozed.id]))
precondition(presentation("cat").completed.map(\.id) == [oldDone.id], "History must search across dates")
precondition(ids(presentation(" CAFE ")) == [future.id], "Accent/case insensitive and beyond date strip")
precondition(ids(presentation("blue cafe")) == [future.id], "Terms may span title and notes, in either order")
precondition(ids(presentation("milk")) == [noteOnly.id], "Notes-only match")
precondition(ids(presentation("milk", today: false)) == [noteOnly.id])
precondition(ids(presentation("ＣＡＴ")) == [daily.id, snoozed.id], "Full-width text matches")
precondition(ids(presentation("[A].*")) == [literal.id], "Search text is literal, not a regex")
precondition(presentation("cat milk").visible.isEmpty, "Every word must match the same reminder")
precondition(presentation("unmatched").visible.isEmpty && presentation("unmatched").completed.isEmpty)
precondition(presentation("cat").visible.allSatisfy { !$0.isProjected }, "Search returns actual occurrences, not fake future duplicates")
precondition(presentation("cat").snoozed.map { $0.reminder.id } == [snoozed.id])
precondition(presentation("cat").due.map { $0.reminder.id } == [daily.id])
let cleared = presentation(" \n\t ")
let baseline = presentation("")
precondition(cleared.visible.map(\.id) == baseline.visible.map(\.id))
precondition(cleared.completed == baseline.completed)
precondition(baseline.visible.count == 1 && baseline.visible[0].isProjected)
precondition(presentation("cat").visible.map(\.id) == presentation("cat", records: Array(original.reversed())).visible.map(\.id))

// Search results must retain real identities/generations for existing actions.
var snapshot = ReminderSnapshot(); snapshot.reminders = original
let found = presentation("milk").visible[0].reminder
let adjusted = ReminderLifecycle.adjusting(found, by: .fiveMinutes, direction: .later, in: snapshot, now: now, calendar: calendar)!
precondition(adjusted.snapshot.reminders.first { $0.id == found.id }!.alertDate == found.alertDate.addingTimeInterval(300))
precondition(adjusted.snapshot.reminders.filter { $0.id != found.id } == original.filter { $0.id != found.id })
let completed = ReminderLifecycle.completing(daily, in: snapshot, now: now, calendar: calendar)!.snapshot
precondition(completed.reminders.contains { $0.id == daily.id && $0.completedAt == nil && $0.due > now }, "Done keeps recurring series")
precondition(presentation("cat", records: completed.reminders).completed.count == 2)
let snooze = ReminderLifecycle.snoozing(snoozed, in: snapshot, now: now)!.snapshot
precondition(presentation("medicine", records: snooze.reminders).snoozed.count == 1)
precondition(snapshot.reminders == original, "Searching must not change saved data")
precondition(presentation("anything", records: []).visible.isEmpty)
print("Search checks passed: names/notes, all dates, history, case/accents, multiple/literal words, clear/no matches, stable identities, and scoped adjustment/Done/Snooze.")
