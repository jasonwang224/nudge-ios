import Foundation

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!

func date(_ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
}

func reminder(_ title: String, due: Date, rule: RepeatRule = .never) -> Reminder {
    var preferences = ReminderPreferences()
    preferences.repeatRule = rule
    return Reminder(title: title, notes: "", due: due, repeatAnchor: due, preferences: preferences)
}

let now = date(7, 19)
let daily = reminder("Daily", due: date(7, 8), rule: .daily)
let later = reminder("Later", due: date(7, 22))
var snoozed = reminder("Snoozed", due: date(7, 18))
snoozed.snoozedUntil = date(7, 19, 10)
var expiredSnooze = reminder("Expired snooze", due: date(6, 20))
expiredSnooze.snoozedUntil = date(7, 18, 55)
var yesterdayComplete = reminder("Yesterday complete", due: date(6, 8))
yesterdayComplete.completedAt = date(6, 9)
var todayComplete = reminder("Today complete", due: date(6, 9))
todayComplete.completedAt = date(7, 10)
let original = [daily, later, snoozed, expiredSnooze, yesterdayComplete, todayComplete]

let today = AgendaPresentation(reminders: original, todayOnly: true, selectedDay: nil, now: now, calendar: calendar)
precondition(today.isToday && today.viewedDay == date(7, 0))
precondition(today.completed.map(\.id) == [todayComplete.id], "Today history must use completion date, not due date or all-time history.")
precondition(Set(today.due.map { $0.reminder.id }) == Set([daily.id, expiredSnooze.id]))
precondition(today.snoozed.map { $0.reminder.id } == [snoozed.id])
precondition(today.upcoming.map { $0.reminder.id } == [later.id])
let sections = today.due + today.snoozed + today.upcoming
precondition(Set(sections.map(\.id)) == Set(today.visible.map(\.id)) && sections.count == today.visible.count,
             "Every actual row must appear in exactly one section.")

let upcoming = AgendaPresentation(reminders: original, todayOnly: false, selectedDay: date(10), now: now, calendar: calendar)
precondition(upcoming.completed.map(\.id) == [todayComplete.id, yesterdayComplete.id], "Upcoming keeps complete all-time history.")
precondition(upcoming.visible.count == 4 && upcoming.visible.allSatisfy { !$0.isProjected })

let tuesday = AgendaPresentation(reminders: original, todayOnly: true, selectedDay: date(10), now: now, calendar: calendar)
precondition(!tuesday.isToday && tuesday.viewedDay == date(10, 0))
precondition(tuesday.completed.isEmpty && tuesday.due.isEmpty && tuesday.snoozed.isEmpty)
precondition(tuesday.upcoming.count == 1 && tuesday.upcoming[0].isProjected && tuesday.upcoming[0].reminder == daily)

precondition(!AgendaPresentation.canSnooze(ReminderOccurrence(later), now: now),
             "Snooze must not move a future reminder earlier than its scheduled due time.")
precondition(!AgendaPresentation.canSnooze(tuesday.upcoming[0], now: now),
             "Projected rows must never snooze the current reminder.")
precondition(AgendaPresentation.canSnooze(ReminderOccurrence(daily), now: now))
precondition(AgendaPresentation.canSnooze(ReminderOccurrence(snoozed), now: now),
             "A reminder that was already due can extend its active snooze.")
precondition(!AgendaPresentation.canSnooze(ReminderOccurrence(todayComplete), now: now))
precondition(AgendaPresentation.canSnooze(ReminderOccurrence(later), now: later.due),
             "Snooze becomes available when the original reminder is due.")

// A screen left open overnight follows Today without dragging a chosen future day forward.
let nextMorning = date(8, 0, 1)
let staleToday = AgendaPresentation(reminders: original, todayOnly: true, selectedDay: date(7, 0), now: nextMorning, calendar: calendar)
precondition(staleToday.isToday && staleToday.viewedDay == date(8, 0) && staleToday.completed.isEmpty)
let stillTuesday = AgendaPresentation(reminders: original, todayOnly: true, selectedDay: date(10, 0), now: nextMorning, calendar: calendar)
precondition(stillTuesday.viewedDay == date(10, 0) && !stillTuesday.isToday)
let nowTuesday = AgendaPresentation(reminders: original, todayOnly: true, selectedDay: date(10, 0), now: date(10, 0, 1), calendar: calendar)
precondition(nowTuesday.isToday && nowTuesday.visible.allSatisfy { !$0.isProjected })

// The instant the snooze ends, it moves to Needs attention without disappearing.
let expired = AgendaPresentation(reminders: [snoozed], todayOnly: true, selectedDay: nil, now: date(7, 19, 10), calendar: calendar)
precondition(expired.snoozed.isEmpty && expired.upcoming.isEmpty && expired.due.count == 1)
precondition(expired.due[0].date == snoozed.snoozedUntil)
precondition(original == [daily, later, snoozed, expiredSnooze, yesterdayComplete, todayComplete], "Agenda rendering must never mutate reminders.")

print("Agenda sections, completed-date filtering, future selection, midnight rollover, and snooze transition checks passed.")
