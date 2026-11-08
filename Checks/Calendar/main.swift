import Foundation

var gregorian = Calendar(identifier: .gregorian)
gregorian.timeZone = TimeZone(identifier: "America/Los_Angeles")!
func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 8, _ minute: Int = 30) -> Date {
    gregorian.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}
func calendar(_ identifier: Calendar.Identifier) -> Calendar {
    var result = Calendar(identifier: identifier)
    result.timeZone = gregorian.timeZone
    return result
}
func reminder(_ schedule: PhoneSchedule, due: Date, rule: RepeatRule = .daily) -> Reminder {
    var preferences = ReminderPreferences()
    preferences.repeatRule = rule
    return Reminder(title: "Calendar check", notes: "", due: due, repeatAnchor: due,
                    preferences: preferences, phoneSchedule: schedule)
}

let original = date(2026, 11, 8)
let schedule = PhoneSchedule(day: original, hour: 8, minute: 30, calendar: gregorian)
var oldSchema = try JSONSerialization.jsonObject(with: JSONEncoder().encode(schedule)) as! [String: Any]
oldSchema.removeValue(forKey: "storedCalendar")
oldSchema.removeValue(forKey: "prefersSecondOccurrence")
let oldBytes = try JSONSerialization.data(withJSONObject: oldSchema)
let oldDecoded = try JSONDecoder().decode(PhoneSchedule.self, from: oldBytes)
precondition(oldDecoded.storedCalendar == nil && oldDecoded.prefersSecondOccurrence == nil)
precondition(oldDecoded.dueDate(referenceDate: original, calendar: calendar(.buddhist)) == original,
             "Records lacking both new optional fields must remain safely readable")
let calendars: [Calendar.Identifier] = [
    .gregorian, .buddhist, .chinese, .coptic, .ethiopicAmeteMihret,
    .ethiopicAmeteAlem, .hebrew, .iso8601, .indian, .islamic,
    .islamicCivil, .japanese, .persian, .republicOfChina,
    .islamicTabular, .islamicUmmAlQura
]
for identifier in calendars {
    let displayCalendar = calendar(identifier)
    precondition(schedule.dueDate(calendar: displayCalendar) == original,
                 "Changing display calendar reinterpreted a saved Gregorian schedule")
    let created = PhoneSchedule(day: original, hour: 8, minute: 30, calendar: displayCalendar)
    precondition(created.dueDate(calendar: gregorian) == original,
                 "A newly created non-Gregorian schedule lost its chronology")
    let encoded = try JSONEncoder().encode(created)
    let reloaded = try JSONDecoder().decode(PhoneSchedule.self, from: encoded)
    precondition(reloaded.storedCalendar?.identifier == identifier)
    precondition(reloaded.dueDate(calendar: gregorian) == original)
    let series = reminder(created, due: original, rule: .monthly)
    precondition(series.nextOccurrence(after: original, calendar: gregorian)
                    == series.nextOccurrence(after: original, calendar: displayCalendar),
                 "Recurring month arithmetic changed with display calendar")
}

// Legacy records did not encode Calendar. Infer only an unambiguous chronology.
for identifier in [Calendar.Identifier.gregorian, .buddhist, .japanese, .iso8601] {
    var legacy = PhoneSchedule(day: original, hour: 8, minute: 30, calendar: calendar(identifier))
    legacy.storedCalendar = nil
    let inferred = legacy.resolvingCalendar(relativeTo: original, calendar: calendar(.buddhist))!
    let expected: Calendar.Identifier = identifier == .iso8601 ? .gregorian : identifier
    precondition(inferred.storedCalendar?.identifier == expected,
                 "Legacy migration guessed the currently selected calendar")
    precondition(inferred.dueDate(calendar: calendar(.japanese)) == original)
    precondition(legacy.dueDate(referenceDate: original, calendar: calendar(.japanese)) == original)
    let before = ReminderSnapshot(reminders: [reminder(legacy, due: original)])
    let refreshed = ReminderLifecycle.refreshingSchedules(in: before, calendar: calendar(.japanese))
    precondition(refreshed.reminders[0].due == original)
    precondition(refreshed.reminders[0].phoneSchedule?.storedCalendar?.identifier == expected)
}

// Identity follows its original chronology while its clock follows the phone.
var newYork = calendar(.japanese)
newYork.timeZone = TimeZone(identifier: "America/New_York")!
var gregorianNewYork = Calendar(identifier: .gregorian)
gregorianNewYork.timeZone = newYork.timeZone
let newYorkDue = gregorianNewYork.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 8, minute: 30))!
precondition(schedule.dueDate(calendar: newYork) == newYorkDue,
             "Persisted calendar identity must not freeze the old timezone")
var travelingLegacy = schedule
travelingLegacy.storedCalendar = nil
precondition(travelingLegacy.dueDate(referenceDate: original, calendar: newYork) == newYorkDue)

// A time-only monthly edit may have replaced repeatAnchor with February while
// retaining January 31 in anchorDay; migration must preserve the latter exactly.
let january31 = date(2027, 1, 31)
let february28 = date(2027, 2, 28, 9, 30)
var monthEnd = PhoneSchedule(day: january31, hour: 9, minute: 30, calendar: gregorian)
monthEnd.day = gregorian.dateComponents([.era, .year, .month, .day], from: february28)
monthEnd.storedCalendar = nil
let monthly = reminder(monthEnd, due: february28, rule: .monthly)
precondition(monthly.nextOccurrence(after: february28, calendar: calendar(.buddhist)) == date(2027, 3, 31, 9, 30))

// Legacy chronologies outside the verified migration set require confirmation.
// Keep absolute data intact and do not silently terminate a series.
var ambiguous = PhoneSchedule(day: original, hour: 8, minute: 30, calendar: calendar(.islamicCivil))
ambiguous.storedCalendar = nil
precondition(ambiguous.resolvedCalendar(relativeTo: original, calendar: gregorian) == nil)
let uncertain = reminder(ambiguous, due: original)
let uncertainSnapshot = ReminderSnapshot(reminders: [uncertain])
precondition(ReminderLifecycle.refreshingSchedules(in: uncertainSnapshot, calendar: gregorian) == uncertainSnapshot)
precondition(ReminderLifecycle.completing(uncertain, in: uncertainSnapshot, now: original, calendar: gregorian) == nil)

// Current second-fold selection survives persistence; subsequent recurrence uses
// the regular first-occurrence policy and history retains its original instant.
let foldDay = date(2027, 11, 7, 12, 0)
let first = gregorian.date(bySettingHour: 1, minute: 30, second: 0, of: foldDay,
                           matchingPolicy: .nextTime, repeatedTimePolicy: .first)!
let last = gregorian.date(bySettingHour: 1, minute: 30, second: 0, of: foldDay,
                          matchingPolicy: .nextTime, repeatedTimePolicy: .last)!
precondition(last.timeIntervalSince(first) == 3600)
var secondFold = PhoneSchedule(day: foldDay, hour: 1, minute: 30, calendar: gregorian)
secondFold.prefersSecondOccurrence = true
precondition(secondFold.dueDate(calendar: calendar(.buddhist)) == last)
precondition(secondFold.time(on: foldDay, calendar: gregorian) == first)
let decodedFold = try JSONDecoder().decode(PhoneSchedule.self, from: JSONEncoder().encode(secondFold))
precondition(decodedFold.dueDate(calendar: gregorian) == last)
let foldReminder = reminder(secondFold, due: last)
let foldSnapshot = ReminderSnapshot(reminders: [foldReminder])
let completed = ReminderLifecycle.completing(foldReminder, in: foldSnapshot, now: last, calendar: calendar(.buddhist))!
let next = completed.snapshot.reminders.first { $0.completedAt == nil }!
let history = completed.snapshot.reminders.first { $0.completedAt != nil }!
precondition(next.due == date(2027, 11, 8, 1, 30))
precondition(next.phoneSchedule?.prefersSecondOccurrence != true)
precondition(history.phoneSchedule?.dueDate(calendar: gregorian) == last)

print("Calendar identity, safe legacy migration, timezone following, month-end preservation, ambiguous-data safety, and repeated-hour checks passed.")
