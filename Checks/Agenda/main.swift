import Foundation

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!

func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

func reminder(_ title: String, due: Date, rule: RepeatRule, nagMinutes: Int = 2) -> Reminder {
    var preferences = ReminderPreferences()
    preferences.repeatRule = rule
    preferences.nagMinutes = nagMinutes
    var result = Reminder(title: title, notes: "", due: due, repeatAnchor: due, preferences: preferences)
    result.phoneSchedule = PhoneSchedule(day: due, hour: calendar.component(.hour, from: due),
                                         minute: calendar.component(.minute, from: due), calendar: calendar)
    return result
}

let saturday = date(2026, 11, 7)
precondition(calendar.component(.weekday, from: saturday) == 7)
let daily = reminder("Daily", due: date(2026, 11, 7, 8), rule: .daily)
let weekly = reminder("Weekly", due: date(2026, 11, 7, 9), rule: .weekly)
let weekdays = reminder("Weekdays", due: date(2026, 11, 6, 10), rule: .weekdays)
var custom = reminder("Monday and Wednesday", due: date(2026, 11, 4, 11), rule: .custom)
custom.preferences.weekdays = [2, 4]
let original = [daily, weekly, weekdays, custom]

for offset in 1...7 {
    let selected = calendar.date(byAdding: .day, value: offset, to: saturday)!
    let rows = ReminderOccurrence.entries(reminders: original, on: selected, now: saturday, calendar: calendar)
    let weekday = calendar.component(.weekday, from: selected)
    let dailyRows = rows.filter { $0.reminder.id == daily.id }
    precondition(dailyRows.count == 1 && dailyRows[0].isProjected)
    precondition(calendar.isDate(dailyRows[0].date, inSameDayAs: selected))
    precondition(calendar.component(.hour, from: dailyRows[0].date) == 8)
    precondition(rows.filter { $0.reminder.id == weekly.id }.count == (weekday == 7 ? 1 : 0))
    precondition(rows.filter { $0.reminder.id == weekdays.id }.count == ((2...6).contains(weekday) ? 1 : 0))
    precondition(rows.filter { $0.reminder.id == custom.id }.count == ([2, 4].contains(weekday) ? 1 : 0))
    precondition(rows.map(\.date) == rows.map(\.date).sorted())
    precondition(Set(rows.map(\.id)).count == rows.count)
}
precondition(original == [daily, weekly, weekdays, custom], "Agenda projection must not advance or alter the saved series.")

let today = ReminderOccurrence.entries(reminders: original, on: saturday, now: saturday, calendar: calendar)
precondition(today.count == original.count && today.allSatisfy { !$0.isProjected },
             "Today keeps overdue actual reminders without adding hypothetical repeat occurrences.")
let upcoming = ReminderOccurrence.entries(reminders: Array(original.reversed()), on: nil, now: saturday, calendar: calendar)
precondition(upcoming.count == original.count && upcoming.allSatisfy { !$0.isProjected })
precondition(upcoming.map(\.date) == original.map(\.alertDate).sorted(),
             "The unfiltered list preserves actual upcoming/overdue reminders and their order.")

let firstFuture = reminder("Starts Tuesday", due: date(2026, 11, 10, 8), rule: .daily)
precondition(ReminderOccurrence.entries(reminders: [firstFuture], on: date(2026, 11, 8), now: saturday, calendar: calendar).isEmpty)
let firstDay = ReminderOccurrence.entries(reminders: [firstFuture], on: date(2026, 11, 10), now: saturday, calendar: calendar)
precondition(firstDay.count == 1 && !firstDay[0].isProjected && firstDay[0].date == firstFuture.due)
let followingDay = ReminderOccurrence.entries(reminders: [firstFuture], on: date(2026, 11, 11), now: saturday, calendar: calendar)
precondition(followingDay.count == 1 && followingDay[0].isProjected)

var completed = daily
completed.completedAt = saturday
let selections: [Date?] = [nil, saturday, date(2026, 11, 8)]
for selected in selections {
    precondition(ReminderOccurrence.entries(reminders: [completed], on: selected, now: saturday, calendar: calendar).isEmpty)
}
var invalid = daily
invalid.preferences.nagMinutes = Int.max
precondition(ReminderOccurrence.entries(reminders: [invalid], on: date(2026, 11, 8), now: saturday, calendar: calendar).isEmpty)
let once = reminder("One time", due: daily.due, rule: .never)
precondition(ReminderOccurrence.entries(reminders: [once], on: date(2026, 11, 8), now: saturday, calendar: calendar).isEmpty,
             "Repeated nags do not create future calendar occurrences.")
for minutes in ReminderPreferences.nagIntervals {
    var withNag = daily
    withNag.preferences.nagMinutes = minutes
    let rows = ReminderOccurrence.entries(reminders: [withNag], on: date(2026, 11, 8), now: saturday, calendar: calendar)
    precondition(rows.count == 1 && rows[0].date == date(2026, 11, 8, 8),
                 "The agenda shows repeat occurrences, not each nag notification.")
}

let january31 = date(2027, 1, 31)
let monthly = reminder("Month end", due: date(2027, 1, 31, 9), rule: .monthly)
let februaryRows = ReminderOccurrence.entries(reminders: [monthly], on: date(2027, 2, 28), now: january31, calendar: calendar)
precondition(februaryRows.count == 1 && februaryRows[0].date == date(2027, 2, 28, 9))
precondition(februaryRows[0].reminder == monthly && februaryRows[0].isProjected)
precondition(ReminderOccurrence.entries(reminders: [monthly], on: date(2027, 2, 27), now: january31, calendar: calendar).isEmpty)
let marchRows = ReminderOccurrence.entries(reminders: [monthly], on: date(2027, 3, 31), now: january31, calendar: calendar)
precondition(marchRows.count == 1 && marchRows[0].date == date(2027, 3, 31, 9),
             "Projecting February must not change a monthly series' January 31 anchor.")

for (dayBefore, changeDay, elapsedHours) in [(date(2027, 3, 13), date(2027, 3, 14), 23),
                                           (date(2027, 11, 6), date(2027, 11, 7), 25)] {
    let due = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: dayBefore)!
    let series = reminder("Eight AM", due: due, rule: .daily)
    let rows = ReminderOccurrence.entries(reminders: [series], on: changeDay, now: dayBefore, calendar: calendar)
    precondition(rows.count == 1 && rows[0].isProjected)
    precondition(calendar.component(.hour, from: rows[0].date) == 8)
    precondition(rows[0].date.timeIntervalSince(due) == Double(elapsedHours * 3600),
                 "Projected local times must follow daylight-saving changes, not add 24 hours.")
}

var acrossMidnight = reminder("Late evening", due: date(2026, 11, 8, 23, 55), rule: .daily)
acrossMidnight.snoozedUntil = date(2026, 11, 9, 0, 10)
let sundayNight = date(2026, 11, 8, 23, 56)
let mondayRows = ReminderOccurrence.entries(reminders: [acrossMidnight], on: date(2026, 11, 9),
                                             now: sundayNight, calendar: calendar)
precondition(mondayRows.map(\.date) == [date(2026, 11, 9, 0, 10), date(2026, 11, 9, 23, 55)])
precondition(mondayRows.map(\.isProjected) == [false, true])
precondition(Set(mondayRows.map(\.id)).count == 2, "An actual snooze and a future repeat need distinct stable row identities.")
precondition(mondayRows.allSatisfy { $0.reminder == acrossMidnight })
let sundayRows = ReminderOccurrence.entries(reminders: [acrossMidnight], on: sundayNight,
                                             now: sundayNight, calendar: calendar)
precondition(sundayRows.count == 1 && !sundayRows[0].isProjected && sundayRows[0].date == acrossMidnight.snoozedUntil,
             "Today retains the existing behavior of showing snoozed reminders even across midnight.")
let standalone = ReminderOccurrence(acrossMidnight)
precondition(standalone.date == acrossMidnight.alertDate && !standalone.isProjected)
precondition(standalone.id == mondayRows[0].id)

print("Agenda projection, recurrence, DST, snooze, identity, and preservation checks passed.")
