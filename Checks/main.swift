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

func expectFailure(_ label: String, _ operation: () throws -> Void) {
    do {
        try operation()
        preconditionFailure("Expected failure: \(label)")
    } catch { }
}

func checkDatabaseSafety() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "nudge-checks.\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suite)!
    defer {
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    let database = ReminderDatabase(url: root.appendingPathComponent("Reminders.json"), preferences: preferences)
    let empty = try database.read()
    precondition(empty == .missing)

    preferences.set("incorrect type", forKey: ReminderDatabase.legacyKey)
    expectFailure("a legacy value of the wrong type is not an empty store") { _ = try database.read() }
    var invalid = test
    invalid.preferences.nagMinutes = Int.max
    preferences.set(try JSONEncoder().encode([test, invalid]), forKey: ReminderDatabase.legacyKey)
    expectFailure("a bad record cannot erase a good one") { _ = try database.read() }
    precondition(AlertPlan(reminders: [invalid], now: start).alerts.isEmpty)

    let legacyBytes = try JSONEncoder().encode([test, later])
    preferences.set(legacyBytes, forKey: ReminderDatabase.legacyKey)
    let original = ReminderSnapshot(reminders: [test, later])
    let loaded = try database.read()
    precondition(loaded == .legacy(original))
    let migrated = try database.commit(original, replacing: loaded)
    precondition(migrated == .file(original))
    precondition(preferences.data(forKey: ReminderDatabase.legacyKey) == legacyBytes)
    let beforeSnooze = try Data(contentsOf: database.url)

    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
    expectFailure("failed atomic Snooze write") {
        _ = try database.commit(ReminderSnapshot(reminders: [snoozed, later]), replacing: migrated)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    let afterFailedWrite = try Data(contentsOf: database.url)
    precondition(afterFailedWrite == beforeSnooze)

    let changed = ReminderSnapshot(reminders: [snoozed], deletedIDs: [later.id])
    let saved = try database.commit(changed, replacing: migrated)
    precondition(saved == .file(changed))
    expectFailure("stale snapshot cannot undo Snooze or delete") {
        _ = try database.commit(original, replacing: migrated)
    }

    let corrupt = Data("{\"version\":1,\"reminders\":[".utf8)
    try corrupt.write(to: database.url, options: .atomic)
    expectFailure("corrupted primary is not an empty store") { _ = try database.read() }
    expectFailure("cannot overwrite corrupt bytes with a blank database") {
        _ = try database.commit(ReminderSnapshot(), replacing: saved)
    }
    let afterAttemptedOverwrite = try Data(contentsOf: database.url)
    precondition(afterAttemptedOverwrite == corrupt)
    try FileManager.default.removeItem(at: database.url)
    expectFailure("a missing primary cannot resurrect an obsolete legacy copy") { _ = try database.read() }
}

try checkDatabaseSafety()

let oldPrimary = PendingNudge(initial.alerts.first { $0.reminder.id == test.id && $0.index == 0 }!.identifier)!
let oldNag = PendingNudge(initial.alerts.first { $0.reminder.id == test.id && $0.index == 1 }!.identifier)!
let otherPrimary = PendingNudge(initial.alerts.first { $0.reminder.id == later.id }!.identifier)!
let current = [test.id: snoozed, later.id: later]
precondition(!oldPrimary.canRetire(current: current, deletedIDs: [], queuedReplacement: []),
             "An interrupted or rejected replacement must leave the original queued.")
precondition(oldPrimary.canRetire(current: current, deletedIDs: [], queuedReplacement: [test.id]))
precondition(!otherPrimary.canRetire(current: current, deletedIDs: [], queuedReplacement: [test.id]))
precondition(!otherPrimary.canRetire(current: [:], deletedIDs: [], queuedReplacement: []),
             "A missing record does not authorize cancellation.")
precondition(otherPrimary.canRetire(current: [:], deletedIDs: [later.id], queuedReplacement: []))
precondition(PendingNudge.expendable(in: [oldPrimary, oldNag, otherPrimary], current: current, desired: [])?
    .identifier == oldNag.identifier)
precondition(PendingNudge.expendable(in: [oldNag, otherPrimary], current: current, desired: []) == nil,
             "Do not drop the last queued nag even when the new alert has no free slot.")
print("Database and notification preservation checks passed.")

let firstDelivered = DeliveredNudge(identifier: oldPrimary.identifier, date: start)!
let latestDelivered = DeliveredNudge(identifier: oldNag.identifier, date: start.addingTimeInterval(120))!
let otherDelivered = DeliveredNudge(identifier: otherPrimary.identifier, date: start)!
let secondNag = ScheduledAlert(reminder: test, index: 2, date: start.addingTimeInterval(240))
let incoming = DeliveredNudge(identifier: secondNag.identifier, date: secondNag.date)!
let delivered = [latestDelivered, otherDelivered, firstDelivered]
precondition(Set(DeliveredNudge.supersededIdentifiers(in: delivered, by: incoming))
    == [oldPrimary.identifier, oldNag.identifier], "A foreground nag clears only older alerts for that reminder.")
precondition(DeliveredNudge.supersededIdentifiers(in: delivered, by: firstDelivered).isEmpty,
             "A delayed callback must leave the newer alert visible.")
precondition(DeliveredNudge.supersededIdentifiers(in: delivered) == [oldPrimary.identifier],
             "Returning to Nudge keeps the latest delivered alert per reminder.")
precondition(DeliveredNudge(identifier: "unrelated-notification", date: start) == nil)
print("Delivered nag cleanup checks passed.")
