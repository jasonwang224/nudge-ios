import Foundation

func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fatalError(message) }
}

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!

func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
}

let now = date(2026, 11, 7, 12)
let tomorrow = date(2026, 11, 8)

func draft(original: Reminder? = nil, title: String = "Reminder", notes: String = "",
           day: Date = tomorrow, time: String = "830", isPM: Bool = false,
           preferences: ReminderPreferences = ReminderPreferences()) throws -> Reminder {
    try ReminderEditorDraft.reminder(original: original, title: title, notes: notes, day: day,
                                     time: time, isPM: isPM, preferences: preferences, now: now, calendar: calendar)
}

func expectProblem(_ problem: ReminderEditorDraft.Problem, _ message: String, _ operation: () throws -> Reminder) {
    do {
        _ = try operation()
        fatalError("Expected validation failure: \(message)")
    } catch let actual as ReminderEditorDraft.Problem {
        expect(actual == problem, "Wrong validation error for \(message): \(actual)")
    } catch {
        fatalError("Unexpected error for \(message): \(error)")
    }
}

for (input, hour, minute) in [("8", 8, 0), ("08", 8, 0), ("830", 8, 30), ("0830", 8, 30),
                               ("8:30", 8, 30), ("12", 0, 0), ("1200", 0, 0), ("1234", 0, 34), (" 8:05 ", 8, 5)] {
    let schedule = ReminderEditorDraft.schedule(time: input, day: tomorrow, isPM: false, calendar: calendar)
    expect(schedule?.hour == hour && schedule?.minute == minute, "Numeric time parsing failed: \(input)")
    let pm = ReminderEditorDraft.schedule(time: input, day: tomorrow, isPM: true, calendar: calendar)
    expect(pm?.hour == hour + 12 && pm?.minute == minute, "PM parsing failed: \(input)")
}
for input in ["", " ", "0", "00", "13", "1360", "860", "8:60", "8:", ":30", "8::30", "12345", "+8", "-8", "8:+2", "8:3a", "8 30", "8.30"] {
    expect(ReminderEditorDraft.schedule(time: input, day: tomorrow, isPM: false, calendar: calendar) == nil,
           "Malformed time was accepted: \(input)")
}
expectProblem(.emptyTitle, "blank title") { try draft(title: " \n ") }
for (input, formatted) in [("300", "3:00"), ("905", "9:05"), ("1200", "12:00"), ("3:00", "3:00")] {
    expect(ReminderEditorDraft.formattedTime(input) == formatted, "Keypad Done did not format \(input)")
}
expect(ReminderEditorDraft.formattedTime("") == nil, "Keypad Done should leave blank input alone")
expect(ReminderEditorDraft.formattedTime("360") == nil, "Keypad Done should leave invalid input alone")
expectProblem(.emptyTime, "blank time") { try draft(time: " ") }
expectProblem(.invalidTime, "invalid minute") { try draft(time: "1260") }
expectProblem(.pastDate, "new past date") { try draft(day: date(2026, 11, 7)) }
let trimmed = try draft(title: "  Feed cat\n", notes: "Keep this note exactly.\n")
expect(trimmed.title == "Feed cat" && trimmed.notes == "Keep this note exactly.\n", "Title/note normalization changed user text")
expect(trimmed.due == date(2026, 11, 8, 8, 30), "Chosen calendar date did not reach saved reminder")
expect(trimmed.preferences.sound == .chime, "New default sound must remain Chime")

var custom = ReminderPreferences()
custom.repeatRule = .custom
custom.weekdays = []
expectProblem(.emptyWeekdays, "empty custom repeat") { try draft(preferences: custom) }
custom.weekdays = [3, 5] // Tuesday, Thursday
expectProblem(.excludedCustomDay, "custom repeat first day is Sunday") { try draft(preferences: custom) }
let customTuesday = try draft(day: date(2026, 11, 10), preferences: custom)
expect(customTuesday.due == date(2026, 11, 10, 8, 30), "Allowed custom first date was moved")
var weekdays = ReminderPreferences()
weekdays.repeatRule = .weekdays
expectProblem(.excludedWeekday, "weekday repeat first day is Sunday") { try draft(preferences: weekdays) }
_ = try draft(day: date(2026, 11, 9), preferences: weekdays)

// Editing an advanced series must preserve its original month-end anchor.
var monthly = ReminderPreferences()
monthly.repeatRule = .monthly
let january = date(2026, 1, 31, 8, 30)
var monthlySchedule = PhoneSchedule(day: january, hour: 8, minute: 30, calendar: calendar)
monthlySchedule.day = calendar.dateComponents([.era, .year, .month, .day], from: date(2026, 2, 28))
var original = Reminder(title: "Original", notes: "", due: date(2026, 2, 28, 8, 30),
                        repeatAnchor: january, preferences: monthly, phoneSchedule: monthlySchedule)
original.snoozedUntil = now.addingTimeInterval(15 * 60)
let edited = try draft(original: original, title: "Edited", notes: "New note", day: original.due, preferences: monthly)
expect(edited.id == original.id && edited.generation == original.generation, "Editor replaced reminder identity")
expect(edited.phoneSchedule == original.phoneSchedule && edited.repeatAnchor == january, "Text-only edit reset monthly anchor")
expect(edited.snoozedUntil == original.snoozedUntil, "Text-only edit cleared snooze")
expect(edited.nextOccurrence(after: date(2026, 2, 28, 9), calendar: calendar) == date(2026, 3, 31, 8, 30),
       "Text-only edit changed a Jan31 series to the 28th")

let october = date(2026, 10, 31, 8, 30)
var novemberSchedule = PhoneSchedule(day: october, hour: 8, minute: 30, calendar: calendar)
novemberSchedule.day = calendar.dateComponents([.era, .year, .month, .day], from: date(2026, 11, 30))
let november = Reminder(title: "Monthly", notes: "", due: date(2026, 11, 30, 8, 30),
                        repeatAnchor: october, preferences: monthly, phoneSchedule: novemberSchedule)
let laterTime = try draft(original: november, day: november.due, time: "930", preferences: monthly)
expect(laterTime.phoneSchedule?.anchorDay == novemberSchedule.anchorDay, "Time-only edit reset month-end day")
expect(laterTime.nextOccurrence(after: date(2026, 11, 30, 10), calendar: calendar) == date(2026, 12, 31, 9, 30),
       "Time-only edit should keep the 31st and use the new clock")
var legacyMonthly = november
legacyMonthly.phoneSchedule = nil
let legacyTime = try draft(original: legacyMonthly, day: legacyMonthly.due, time: "930", preferences: monthly)
expect(legacyTime.nextOccurrence(after: date(2026, 11, 30, 10), calendar: calendar) == date(2026, 12, 31, 9, 30),
       "Legacy monthly time edit lost its original repeat day")

// Changing Daily to Monthly uses the date currently displayed in the editor.
var daily = ReminderPreferences()
daily.repeatRule = .daily
let first = date(2026, 11, 1, 8, 30)
var dailySchedule = PhoneSchedule(day: first, hour: 8, minute: 30, calendar: calendar)
dailySchedule.day = calendar.dateComponents([.era, .year, .month, .day], from: now)
let advanced = Reminder(title: "Daily", notes: "", due: date(2026, 11, 7, 8, 30),
                        repeatAnchor: first, preferences: daily, phoneSchedule: dailySchedule)
let switched = try draft(original: advanced, day: advanced.due, preferences: monthly)
expect(switched.repeatAnchor == advanced.due, "Changed repeat rule retained obsolete absolute anchor")
expect(switched.phoneSchedule?.anchorDay == dailySchedule.day, "Changed repeat rule retained obsolete calendar anchor")
expect(switched.nextOccurrence(after: now, calendar: calendar) == date(2026, 12, 7, 8, 30),
       "Daily-to-monthly switch must repeat on the displayed day, not old series start")

// Legacy invalid starting weekdays stay editable until their schedule changes.
var legacyWeekday = advanced
legacyWeekday.preferences = weekdays
let harmless = try draft(original: legacyWeekday, title: "Rename", day: legacyWeekday.due, preferences: weekdays)
expect(harmless.due == legacyWeekday.due, "Legacy title edit silently moved date")
expectProblem(.excludedWeekday, "changed future date excluded by weekday rule") {
    try draft(original: legacyWeekday, day: tomorrow, preferences: weekdays)
}
expectProblem(.excludedWeekday, "changing daily Saturday reminder to weekdays") {
    try draft(original: advanced, day: advanced.due, preferences: weekdays)
}

let exact = date(2026, 11, 7, 8, 30, 17)
let old = Reminder(title: "Legacy", notes: "", due: exact, repeatAnchor: exact, preferences: daily)
let oldEdited = try draft(original: old, title: "Rename", day: exact, preferences: daily)
expect(oldEdited.due == exact && oldEdited.phoneSchedule == nil, "Legacy edit rounded seconds or changed scheduling mode")

let defaults = custom
var quickMoved = advanced
quickMoved.adjustedDue = date(2026, 11, 8, 10, 5, 24)
let quickRename = try draft(original: quickMoved, title: "Keep the moved time", day: tomorrow,
                            time: "1005", preferences: daily)
expect(quickRename.alertDate == quickMoved.alertDate && quickRename.phoneSchedule == quickMoved.phoneSchedule,
       "Editing the title must preserve the adjusted occurrence and the repeat schedule")
let quickEdit = try draft(original: quickMoved, day: tomorrow, time: "1115", preferences: daily)
expect(quickEdit.adjustedDue == nil && quickEdit.alertDate == date(2026, 11, 8, 11, 15),
       "Explicit date or time edits must replace the quick adjustment")
var individual = try draft(day: date(2026, 11, 10), preferences: defaults)
individual.preferences.sound = .silent
individual.preferences.weekdays.remove(3)
expect(defaults.sound == .chime && defaults.weekdays == [3, 5], "Per-reminder edits mutated saved defaults")

let gap = ReminderEditorDraft.schedule(time: "230", day: date(2027, 3, 14), isPM: false, calendar: calendar)!
expect(gap.hour == 2 && gap.minute == 30, "DST adjustment changed intended recurring clock")
let gapDate = gap.dueDate(calendar: calendar)!
expect(calendar.isDate(gapDate, inSameDayAs: date(2027, 3, 14)), "DST gap moved reminder to a different day")
expect(calendar.component(.hour, from: gapDate) == 3, "DST gap did not use next available time")

let beforeMidnight = date(2026, 11, 7, 23, 59, 59)
let afterMidnight = date(2026, 11, 8, 0, 0, 1)
expect(ReminderEditorDraft.shortcutDate(days: 0, now: beforeMidnight, calendar: calendar) == date(2026, 11, 7),
       "Today shortcut before midnight has the wrong date")
expect(ReminderEditorDraft.shortcutDate(days: 0, now: afterMidnight, calendar: calendar) == date(2026, 11, 8),
       "Today shortcut did not roll forward at midnight")
expect(ReminderEditorDraft.shortcutDate(days: 1, now: afterMidnight, calendar: calendar) == date(2026, 11, 9),
       "Tomorrow shortcut did not roll forward at midnight")
expect(ReminderEditorDraft.shortcutDate(days: 3, now: beforeMidnight, calendar: calendar) == date(2026, 11, 10),
       "Named weekday shortcut before midnight is incorrect")
expect(ReminderEditorDraft.shortcutDate(days: 3, now: afterMidnight, calendar: calendar) == date(2026, 11, 11),
       "Named weekday shortcut did not roll forward at midnight")
expect(ReminderEditorDraft.shortcutDate(days: 1, now: date(2026, 12, 31, 23, 59), calendar: calendar) == date(2027, 1, 1),
       "Tomorrow shortcut failed at year/month rollover")
expect(ReminderEditorDraft.shortcutDate(days: 3, now: date(2027, 1, 30, 12), calendar: calendar) == date(2027, 2, 2),
       "Named weekday shortcut failed at month rollover")
let springNext = ReminderEditorDraft.shortcutDate(days: 1, now: date(2027, 3, 14, 12), calendar: calendar)!
expect(springNext == date(2027, 3, 15) && springNext.timeIntervalSince(date(2027, 3, 14)) == 23 * 60 * 60,
       "Shortcut used 24 elapsed hours instead of a calendar day during spring DST")
let fallNext = ReminderEditorDraft.shortcutDate(days: 1, now: date(2026, 11, 1, 12), calendar: calendar)!
expect(fallNext == date(2026, 11, 2) && fallNext.timeIntervalSince(date(2026, 11, 1)) == 25 * 60 * 60,
       "Shortcut used 24 elapsed hours instead of a calendar day during fall DST")

// Repeated clock times: choose the remaining future occurrence, and preserve it
// when editing the same reminder later instead of silently jumping backwards.
let iso = ISO8601DateFormatter()
let firstFold = iso.date(from: "2026-11-01T08:30:00Z")!
let secondFold = iso.date(from: "2026-11-01T09:30:00Z")!
let betweenFolds = iso.date(from: "2026-11-01T08:45:00Z")!
let foldDay = date(2026, 11, 1)
let secondDraft = try ReminderEditorDraft.reminder(original: nil, title: "Fall reminder", notes: "", day: foldDay,
                                                  time: "130", isPM: false, preferences: daily,
                                                  now: betweenFolds, calendar: calendar)
expect(secondDraft.due == secondFold && secondDraft.phoneSchedule?.prefersSecondOccurrence == true,
       "Editor rejected or selected the past first occurrence while the second was still future")
let secondPreview = ReminderEditorDraft.schedule(time: "130", day: foldDay, isPM: false,
                                                 now: betweenFolds, calendar: calendar)
expect(secondPreview?.dueDate(calendar: calendar) == secondFold, "Editor preview and saved fold time disagree")
let secondRenamed = try ReminderEditorDraft.reminder(original: secondDraft, title: "Renamed", notes: "", day: foldDay,
                                                    time: "130", isPM: false, preferences: daily,
                                                    now: iso.date(from: "2026-11-01T10:00:00Z")!, calendar: calendar)
expect(secondRenamed.due == secondFold && secondRenamed.phoneSchedule == secondDraft.phoneSchedule,
       "Metadata edit changed the chosen repeated-time occurrence")
let firstDraft = try ReminderEditorDraft.reminder(original: nil, title: "First fall reminder", notes: "", day: foldDay,
                                                 time: "130", isPM: false, preferences: daily,
                                                 now: iso.date(from: "2026-11-01T08:00:00Z")!, calendar: calendar)
expect(firstDraft.due == firstFold && firstDraft.phoneSchedule?.prefersSecondOccurrence != true,
       "Editor should choose the first occurrence when both are still future")
let firstRenamed = try ReminderEditorDraft.reminder(original: firstDraft, title: "Rename overdue first", notes: "", day: foldDay,
                                                   time: "130", isPM: false, preferences: daily,
                                                   now: betweenFolds, calendar: calendar)
expect(firstRenamed.due == firstFold, "Renaming an existing first-fold reminder moved it to the second fold")

// Changing the iPhone calendar must not reinterpret existing persisted year/era
// components or overwrite their month-end anchor during an editor save.
let otherIdentifiers: [Calendar.Identifier] = [.japanese, .buddhist]
for identifier in otherIdentifiers {
    var otherCalendar = Calendar(identifier: identifier)
    otherCalendar.timeZone = calendar.timeZone
    let underOtherCalendar = try ReminderEditorDraft.reminder(original: november, title: "Calendar switched", notes: "",
                                                              day: november.due, time: "830", isPM: false,
                                                              preferences: monthly, now: now, calendar: otherCalendar)
    expect(underOtherCalendar.due == november.due, "Editor reinterpreted stored calendar components after a phone calendar switch")
    expect(underOtherCalendar.phoneSchedule?.anchorDay == november.phoneSchedule?.anchorDay,
           "Calendar switch changed the stored monthly anchor")
    expect(underOtherCalendar.phoneSchedule?.storedCalendar?.identifier == .gregorian,
           "Editor overwrote an existing reminder's calendar identity")
    var inferredLegacy = november
    inferredLegacy.phoneSchedule?.storedCalendar = nil
    let inferredEdit = try ReminderEditorDraft.reminder(original: inferredLegacy, title: "Legacy calendar switched", notes: "",
                                                        day: inferredLegacy.due, time: "830", isPM: false,
                                                        preferences: monthly, now: now, calendar: otherCalendar)
    expect(inferredEdit.due == inferredLegacy.due && inferredEdit.phoneSchedule?.storedCalendar?.identifier == .gregorian,
           "Editor did not safely infer and retain a legacy calendar after phone calendar changed")
}

var islamicCivil = Calendar(identifier: .islamicCivil)
islamicCivil.timeZone = calendar.timeZone
let ambiguousDue = date(2026, 11, 8, 8, 30)
var ambiguousSchedule = PhoneSchedule(day: ambiguousDue, hour: 8, minute: 30, calendar: islamicCivil)
ambiguousSchedule.storedCalendar = nil
let ambiguous = Reminder(title: "Legacy ambiguous calendar", notes: "Keep", due: ambiguousDue,
                          repeatAnchor: ambiguousDue, preferences: monthly, phoneSchedule: ambiguousSchedule)
expect(ambiguousSchedule.resolvedCalendar(relativeTo: ambiguousDue, calendar: calendar) == nil,
       "Expected genuinely ambiguous Civil/Tabular legacy calendar fixture")
let originalAmbiguous = ambiguous
expectProblem(.unconfirmedCalendar, "ambiguous legacy metadata edit") {
    try draft(original: ambiguous, title: "Rename", day: ambiguous.due, preferences: monthly)
}
expect(ambiguous == originalAmbiguous, "Refused edit modified the ambiguous original reminder")
let repairedDay = try draft(original: ambiguous, title: "Confirmed date", day: date(2026, 11, 9), preferences: monthly)
expect(repairedDay.due == date(2026, 11, 9, 8, 30) && repairedDay.phoneSchedule?.storedCalendar?.identifier == .gregorian,
       "Explicit date change did not confirm a new schedule in the phone's current calendar")
expect(repairedDay.repeatAnchor == repairedDay.due && repairedDay.phoneSchedule?.anchorDay == repairedDay.phoneSchedule?.day,
       "Calendar repair retained ambiguous repeat anchors")
let repairedClock = try draft(original: ambiguous, title: "Confirmed time", day: ambiguous.due, time: "930", preferences: monthly)
expect(repairedClock.due == date(2026, 11, 8, 9, 30) && repairedClock.phoneSchedule?.storedCalendar?.identifier == .gregorian,
       "Explicit clock change did not repair the ambiguous schedule")

print("Editor time/AM-PM, validation, defaults isolation, repeat anchors, snooze preservation, legacy editing, date shortcuts, calendar identity, and DST checks passed.")


// Old saved defaults and edited alerts-off records cannot recreate a hidden off mode.
var oldAlertsOffDefaults = ReminderPreferences()
oldAlertsOffDefaults.notifications = false
let alwaysOnDraft = try draft(preferences: oldAlertsOffDefaults)
expect(alwaysOnDraft.preferences.notifications, "New reminders must always request notifications.")
var oldAlertsOffReminder = alwaysOnDraft
oldAlertsOffReminder.preferences.notifications = false
let enabledEdit = try draft(original: oldAlertsOffReminder, title: oldAlertsOffReminder.title,
                            day: tomorrow, time: "830", preferences: oldAlertsOffDefaults)
expect(enabledEdit.preferences.notifications, "Editing an older alerts-off reminder must enable notifications.")
expect(enabledEdit.id == oldAlertsOffReminder.id && enabledEdit.due == oldAlertsOffReminder.due,
       "Enabling an edited reminder must preserve its identity and due time.")
print("Editor always-on notification policy checks passed.")
