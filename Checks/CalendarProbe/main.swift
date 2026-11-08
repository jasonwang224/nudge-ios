import Foundation

var gregorian = Calendar(identifier: .gregorian)
gregorian.timeZone = TimeZone(identifier: "America/Los_Angeles")!
func date(_ month: Int, _ day: Int) -> Date {
    gregorian.date(from: DateComponents(year: 2026, month: month, day: day, hour: 8, minute: 30))!
}
let reference = date(11, 30)
var legacy = PhoneSchedule(day: date(10, 31), hour: 8, minute: 30, calendar: gregorian)
legacy.day = gregorian.dateComponents([.era, .year, .month, .day], from: reference)
legacy.storedCalendar = nil
let formatter = ISO8601DateFormatter()
func describe(_ value: Date?) -> String { value.map(formatter.string(from:)) ?? "nil" }
print("PROBE legacy Gregorian November30: \(legacy.day), reference \(describe(reference))")
print("PROBE stored component calendar: \(String(describing: legacy.day.calendar))")
for phoneIdentifier in [Calendar.Identifier.japanese, .buddhist] {
    var phone = Calendar(identifier: phoneIdentifier)
    phone.timeZone = gregorian.timeZone
    print("PROBE inferred while phone \(phoneIdentifier): \(String(describing: legacy.resolvedCalendar(relativeTo: reference, calendar: phone)?.identifier))")
}
let identifiers: [Calendar.Identifier] = [
    .gregorian, .buddhist, .chinese, .coptic, .ethiopicAmeteMihret,
    .ethiopicAmeteAlem, .hebrew, .indian, .islamic, .islamicCivil,
    .japanese, .persian, .republicOfChina, .islamicTabular, .islamicUmmAlQura
]
for identifier in identifiers {
    var candidate = Calendar(identifier: identifier)
    candidate.timeZone = gregorian.timeZone
    guard let day = candidate.date(from: legacy.day) else {
        print("PROBE \(identifier): date(from:) nil")
        continue
    }
    let actual = candidate.dateComponents([.era, .year, .month, .day], from: day)
    let same = legacy.day.era == actual.era && legacy.day.year == actual.year
        && legacy.day.month == actual.month && legacy.day.day == actual.day
        && (legacy.day.isLeapMonth == nil || legacy.day.isLeapMonth == actual.isLeapMonth)
    let first = candidate.date(bySettingHour: 8, minute: 30, second: 0, of: day,
                               matchingPolicy: .nextTime, repeatedTimePolicy: .first)
    let last = candidate.date(bySettingHour: 8, minute: 30, second: 0, of: day,
                              matchingPolicy: .nextTime, repeatedTimePolicy: .last)
    let delta = first.map { abs($0.timeIntervalSince(reference)) / 3600 }
    print("PROBE \(identifier): normalized \(actual), same=\(same), first=\(describe(first)), last=\(describe(last)), firstDeltaHours=\(String(describing: delta)), sameDay=\(first.map { candidate.isDate(day, inSameDayAs: $0) } ?? false)")
}
