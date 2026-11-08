import Foundation

let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
var nag = ReminderPreferences()
nag.nagMinutes = 2
var once = nag
once.nagMinutes = 0
let test = Reminder(title: "Test", notes: "", due: start, repeatAnchor: start, preferences: nag)
let later = Reminder(title: "Later", notes: "", due: start.addingTimeInterval(3_600),
                     repeatAnchor: start.addingTimeInterval(3_600), preferences: once)

let initial = AlertPlan(reminders: [test, later], now: start.addingTimeInterval(-10), capacity: 4)
precondition(initial.alerts.filter { $0.reminder.id == test.id }.map(\.date) ==
    [start, start.addingTimeInterval(120), start.addingTimeInterval(240)])
precondition(initial.alerts.contains { $0.reminder.id == later.id }, "A nag must not crowd out another reminder's first alert.")

var snoozed = test
snoozed.generation = UUID()
snoozed.snoozedUntil = start.addingTimeInterval(900)
let paused = AlertPlan(reminders: [snoozed], now: start.addingTimeInterval(10), capacity: 2)
precondition(paused.alerts.map(\.date) == [start.addingTimeInterval(900), start.addingTimeInterval(1020)])
precondition(Set(paused.alerts.map(\.identifier)).isDisjoint(with: initial.alerts.map(\.identifier)))

var completed = test
completed.completedAt = start
precondition(AlertPlan(reminders: [completed], now: start, capacity: 4).alerts.isEmpty)
precondition(AlertPlan(reminders: [later], now: start.addingTimeInterval(3_601)).alerts.isEmpty)

let reopened = AlertPlan(reminders: [test], now: start.addingTimeInterval(125), capacity: 2)
precondition(reopened.alerts.map(\.date) == [start.addingTimeInterval(240), start.addingTimeInterval(360)])

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(secondsFromGMT: 0)!
let jan31 = calendar.date(from: DateComponents(year: 2027, month: 1, day: 31, hour: 9))!
var monthly = Reminder(title: "Month end", notes: "", due: jan31, repeatAnchor: jan31, preferences: once)
monthly.preferences.repeatRule = .monthly
let feb28 = calendar.date(from: DateComponents(year: 2027, month: 2, day: 28, hour: 9))!
precondition(monthly.nextOccurrence(after: jan31, calendar: calendar) == feb28)
monthly.due = feb28
let march31 = calendar.date(from: DateComponents(year: 2027, month: 3, day: 31, hour: 9))!
precondition(monthly.nextOccurrence(after: feb28, calendar: calendar) == march31)

calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
let beforeSpring = calendar.date(from: DateComponents(year: 2027, month: 3, day: 13, hour: 8))!
var daily = Reminder(title: "Morning", notes: "", due: beforeSpring, repeatAnchor: beforeSpring, preferences: once)
daily.preferences.repeatRule = .daily
daily.phoneSchedule = PhoneSchedule(day: beforeSpring, hour: 8, minute: 0, calendar: calendar)
let springMorning = daily.nextOccurrence(after: beforeSpring, calendar: calendar)!
precondition(calendar.component(.hour, from: springMorning) == 8)
precondition(springMorning.timeIntervalSince(beforeSpring) == 23 * 3600)

let beforeFall = calendar.date(from: DateComponents(year: 2027, month: 11, day: 6, hour: 8))!
daily.due = beforeFall
daily.phoneSchedule = PhoneSchedule(day: beforeFall, hour: 8, minute: 0, calendar: calendar)
let fallMorning = daily.nextOccurrence(after: beforeFall, calendar: calendar)!
precondition(calendar.component(.hour, from: fallMorning) == 8)
precondition(fallMorning.timeIntervalSince(beforeFall) == 25 * 3600)

let springGap = PhoneSchedule(day: springMorning, hour: 2, minute: 30, calendar: calendar)
let adjusted = springGap.dueDate(calendar: calendar)!
precondition(calendar.component(.hour, from: adjusted) == 3)
precondition(calendar.component(.minute, from: adjusted) == 0)
let justBeforeSpring = calendar.date(from: DateComponents(year: 2027, month: 3, day: 14, hour: 1, minute: 55))!
let afterSnooze = justBeforeSpring.addingTimeInterval(15 * 60)
precondition(calendar.component(.hour, from: afterSnooze) == 3)
precondition(calendar.component(.minute, from: afterSnooze) == 10)
print("Reminder scheduling checks passed.")
