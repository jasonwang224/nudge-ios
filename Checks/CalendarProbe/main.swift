import Foundation

// Diagnostic only: this does not change saved reminders or scheduling behavior.
let zone = TimeZone(identifier: "America/Los_Angeles")!
var gregorian = Calendar(identifier: .gregorian)
gregorian.timeZone = zone
let original = gregorian.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 8, minute: 30))!
let schedule = PhoneSchedule(day: original, hour: 8, minute: 30, calendar: gregorian)
precondition(schedule.dueDate(calendar: gregorian) == original)

let formatter = ISO8601DateFormatter()
formatter.timeZone = zone
func describe(_ date: Date?) -> String {
    date.map(formatter.string(from:)) ?? "nil"
}

print("Gregorian-created schedule: \(describe(original))")
print("Stored components: \(schedule.day)")
print("Stored calendar: \(String(describing: schedule.day.calendar?.identifier))")
for identifier in [Calendar.Identifier.buddhist, .japanese] {
    var changed = Calendar(identifier: identifier)
    changed.timeZone = zone
    let actual = schedule.dueDate(calendar: changed)
    print("Read with \(identifier): \(describe(actual)); original instant preserved: \(actual == original)")
    print("Original instant in \(identifier): \(changed.dateComponents([.era, .year, .month, .day], from: original))")
}

// Verify a safe future schema option without adopting it in production here.
// Calendar is Codable, and its identifier survives JSON encoding/decoding.
let calendarBytes = try JSONEncoder().encode(gregorian)
let decodedCalendar = try JSONDecoder().decode(Calendar.self, from: calendarBytes)
precondition(decodedCalendar.identifier == gregorian.identifier)
print("Calendar Codable identifier round trip: \(decodedCalendar.identifier)")

// DST-fold probe: a future local time must remain representable after the clock
// has repeated 1 AM. The current resolver always selects the first 1:30 AM.
let foldDay = gregorian.date(from: DateComponents(year: 2027, month: 11, day: 7, hour: 12))!
let fold = PhoneSchedule(day: foldDay, hour: 1, minute: 30, calendar: gregorian)
let first = gregorian.date(bySettingHour: 1, minute: 30, second: 0, of: foldDay,
                           matchingPolicy: .nextTime, repeatedTimePolicy: .first)!
let last = gregorian.date(bySettingHour: 1, minute: 30, second: 0, of: foldDay,
                          matchingPolicy: .nextTime, repeatedTimePolicy: .last)!
let nowInSecondHour = last.addingTimeInterval(-20 * 60)
precondition(first < nowInSecondHour && last > nowInSecondHour)
print("DST-fold now: \(describe(nowInSecondHour)); resolved: \(describe(fold.dueDate(calendar: gregorian))); future alternative: \(describe(last))")
print("DST-fold chosen instant is already past: \(fold.dueDate(calendar: gregorian)! < nowInSecondHour)")
