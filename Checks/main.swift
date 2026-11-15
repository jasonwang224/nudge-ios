import Foundation
import UserNotifications

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
    try corrupt.write(to: database.recoveryURL, options: .atomic)
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

func checkSoundOnlyRequests() {
    let now = start.addingTimeInterval(-30)
    for minutes in [2, 5, 10, 15, 20, 30] {
        var reminder = test
        reminder.preferences.nagMinutes = minutes
        reminder.preferences.sound = .chime
        reminder.notes = "Keep this card for Done or Snooze."
        let staged = NagDelivery.prepare(ReminderSnapshot(reminders: [reminder]),
                                         replacing: ReminderSnapshot(), now: now)
        precondition(staged.reminders[0].soundOnlyAnchorAccepted == false)
        let firstCandidate = AlertPlan(reminders: staged.reminders, now: now, capacity: 1).alerts[0]
        let accepted = NagDelivery.acceptingVisibleAnchor(identifier: firstCandidate.identifier, in: staged)!
        reminder = accepted.reminders[0]
        precondition(reminder.soundOnlyAfterIndex == 0)
        precondition(reminder.soundOnlyAnchorAccepted == true)
        let plan = AlertPlan(reminders: [reminder], now: now, capacity: 3)
        let requests = plan.alerts.map { NotificationRequestFactory.make(for: $0, soundOnlyEnabled: true, now: now) }
        let first = requests[0].content
        precondition(first.title == reminder.title && first.body == reminder.notes)
        precondition(first.categoryIdentifier == NotificationRequestFactory.category)
        precondition(first.threadIdentifier == reminder.id.uuidString && first.sound != nil)
        precondition(!NotificationRequestFactory.isSoundOnly(first), "The first alert must keep Done and Snooze accessible.")
        for index in 1..<requests.count {
            let request = requests[index]
            let content = request.content
            precondition(content.title.isEmpty && content.body.isEmpty && content.subtitle.isEmpty)
            precondition(content.categoryIdentifier.isEmpty && content.threadIdentifier.isEmpty)
            precondition(content.attachments.isEmpty && content.badge == nil && content.sound != nil)
            precondition(NotificationRequestFactory.isSoundOnly(content))
            precondition(content.userInfo["id"] as? String == reminder.id.uuidString)
            precondition(content.userInfo["generation"] as? String == reminder.generation.uuidString)
            precondition(content.userInfo[NagDelivery.titleKey] as? String == reminder.title)
            let expectedDate = start.addingTimeInterval(Double(index * minutes * 60))
            precondition(content.userInfo[NagDelivery.scheduledKey] as? Double == expectedDate.timeIntervalSince1970)
            precondition((request.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval == expectedDate.timeIntervalSince(now))
            precondition(content.userInfo["nudgeExpiryRequestedAt"] == nil, "The failed expiration experiment must not affect these requests.")
        }
        let fullRequests = plan.alerts.map { NotificationRequestFactory.make(for: $0, soundOnlyEnabled: false, now: now) }
        precondition(fullRequests.allSatisfy {
            $0.content.title == reminder.title && $0.content.categoryIdentifier == NotificationRequestFactory.category
                && !NotificationRequestFactory.isSoundOnly($0.content)
        }, "Turning the experiment off restores full alerts at every interval.")
        precondition(!NotificationRequestFactory.needsRewrite(requests[1], for: plan.alerts[1], enabled: true))
        precondition(NotificationRequestFactory.needsRewrite(requests[1], for: plan.alerts[1], enabled: false))
        precondition(NotificationRequestFactory.needsRewrite(fullRequests[1], for: plan.alerts[1], enabled: true))

        reminder.preferences.sound = .silent
        let silentPlan = AlertPlan(reminders: [reminder], now: now, capacity: 3)
        let silentRequests = silentPlan.alerts.map { NotificationRequestFactory.make(for: $0, soundOnlyEnabled: true, now: now) }
        precondition(silentRequests.allSatisfy {
            !$0.content.title.isEmpty && $0.content.sound == nil && !NotificationRequestFactory.isSoundOnly($0.content)
        }, "A Silent selection must retain visible nags, not produce empty silent reminders.")
    }

    let legacyPlan = AlertPlan(reminders: [test], now: now, capacity: 3)
    precondition(test.soundOnlyAfterIndex == nil)
    precondition(legacyPlan.alerts.allSatisfy {
        let request = NotificationRequestFactory.make(for: $0, soundOnlyEnabled: true, now: now)
        return request.content.title == test.title && !NotificationRequestFactory.isSoundOnly(request.content)
    }, "An existing generation cannot become sound-only without a new visible anchor.")
    let oldContent = UNMutableNotificationContent()
    oldContent.title = test.title
    oldContent.userInfo = ["id": test.id.uuidString, "generation": test.generation.uuidString,
                           "nudgeExpiryRequestedAt": start.addingTimeInterval(120).timeIntervalSince1970]
    let oldRequest = UNNotificationRequest(identifier: legacyPlan.alerts[0].identifier, content: oldContent,
                                           trigger: UNTimeIntervalNotificationTrigger(timeInterval: 30, repeats: false))
    precondition(NotificationRequestFactory.needsRewrite(oldRequest, for: legacyPlan.alerts[0], enabled: true))
    let replacement = NotificationRequestFactory.make(for: legacyPlan.alerts[0], soundOnlyEnabled: true, now: now)
    precondition(!NotificationRequestFactory.needsRewrite(replacement, for: legacyPlan.alerts[0], enabled: true))
    precondition(replacement.content.userInfo["nudgeExpiryRequestedAt"] == nil)
    precondition(replacement.content.body.isEmpty && replacement.content.categoryIdentifier == NotificationRequestFactory.category,
                 "Reminders without notes should show the title and keep their actions.")
    let instructionalContent = replacement.content.mutableCopy() as! UNMutableNotificationContent
    instructionalContent.body = "Hold for Done or Snooze 15 min."
    let instructionalRequest = UNNotificationRequest(identifier: replacement.identifier, content: instructionalContent,
                                                     trigger: replacement.trigger)
    precondition(NotificationRequestFactory.needsRewrite(instructionalRequest, for: legacyPlan.alerts[0], enabled: true),
                 "A queued alert with the old instructions should be rewritten in place.")
    print("Sound-only request content, intervals, Silent fallback, and mode rewrite checks passed.")
}

func checkSoundOnlyAnchorsAndIsolation() {
    let beforeDue = start.addingTimeInterval(-30)
    let prepared = NagDelivery.prepare(ReminderSnapshot(reminders: [test, later]),
                                       replacing: ReminderSnapshot(), now: beforeDue)
    let anchored = prepared.reminders.first { $0.id == test.id }!
    precondition(anchored.soundOnlyAfterIndex == 0 && anchored.soundOnlyAnchorAccepted == false)
    let firstCandidate = AlertPlan(reminders: [anchored], now: beforeDue, capacity: 1).alerts[0]
    let accepted = NagDelivery.acceptingVisibleAnchor(identifier: firstCandidate.identifier, in: prepared)!
    let refreshed = NagDelivery.prepare(accepted, replacing: accepted, now: start.addingTimeInterval(125))
    precondition(refreshed == accepted && refreshed.reminders.first { $0.id == test.id }?.soundOnlyAnchorAccepted == true,
                 "Reopening must preserve the accepted visible anchor.")
    precondition(NagDelivery.acceptingVisibleAnchor(identifier: firstCandidate.identifier, in: accepted) == nil,
                 "Accepting the same visible anchor twice must not rewrite the database.")

    // A permission prompt or interrupted launch can outlast the originally planned first alert.
    let delayedPlan = AlertPlan(reminders: [anchored], now: start.addingTimeInterval(125), capacity: 2)
    precondition(delayedPlan.alerts[0].index == 2)
    precondition(delayedPlan.alerts.allSatisfy { !NagDelivery.isSoundOnly($0, enabled: true) },
                 "Before any visible request is accepted, future requests must stay visible.")
    let delayedFirst = NotificationRequestFactory.make(for: delayedPlan.alerts[0], soundOnlyEnabled: true,
                                                       now: start.addingTimeInterval(125))
    precondition(delayedFirst.content.title == test.title && delayedFirst.content.categoryIdentifier == NotificationRequestFactory.category)
    let delayedAccepted = NagDelivery.acceptingVisibleAnchor(identifier: delayedFirst.identifier, in: prepared)!
    let delayedReminder = delayedAccepted.reminders.first { $0.id == test.id }!
    precondition(delayedReminder.soundOnlyAfterIndex == 2 && delayedReminder.soundOnlyAnchorAccepted == true)
    let delayedPending = delayedPlan.alerts.compactMap { PendingNudge($0.identifier) }
    precondition(PendingNudge.expendable(in: delayedPending, current: [test.id: delayedReminder], desired: [])?.index == 3,
                 "Capacity pruning must preserve a visible anchor with a nonzero index.")
    precondition(PendingNudge.expendable(in: delayedPending, current: [test.id: delayedReminder],
                                       desired: [delayedPending[1].identifier]) == nil,
                 "A delayed visible anchor cannot be treated as an expendable nag.")
    let acceptedPlan = AlertPlan(reminders: [delayedReminder], now: start.addingTimeInterval(125), capacity: 2)
    precondition(!NagDelivery.isSoundOnly(acceptedPlan.alerts[0], enabled: true)
                 && NagDelivery.isSoundOnly(acceptedPlan.alerts[1], enabled: true),
                 "The actual accepted request becomes the anchor; only its successors can be audio-only.")
    precondition(delayedAccepted.reminders.first { $0.id == later.id } == prepared.reminders.first { $0.id == later.id })
    precondition(NagDelivery.acceptingVisibleAnchor(identifier: "not-a-nudge", in: prepared) == nil)
    precondition(NagDelivery.acceptingVisibleAnchor(identifier: oldPrimary.identifier,
                                                    in: ReminderSnapshot(reminders: [test])) == nil,
                 "An older generation that never opted in must not be converted by accepting a request.")

    var edited = test
    edited.generation = UUID()
    let overdue = NagDelivery.prepare(ReminderSnapshot(reminders: [edited, later]),
                                      replacing: ReminderSnapshot(reminders: [test, later]),
                                      now: start.addingTimeInterval(125))
    let overdueReminder = overdue.reminders.first { $0.id == test.id }!
    precondition(overdueReminder.soundOnlyAfterIndex == 2 && overdueReminder.soundOnlyAnchorAccepted == false)
    let overduePlan = AlertPlan(reminders: [overdueReminder], now: start.addingTimeInterval(125), capacity: 2)
    precondition(overduePlan.alerts.map(\.date) == [start.addingTimeInterval(240), start.addingTimeInterval(360)])
    let overdueAccepted = NagDelivery.acceptingVisibleAnchor(identifier: overduePlan.alerts[0].identifier, in: overdue)!
    let readyOverdue = overdueAccepted.reminders.first { $0.id == test.id }!
    let readyOverduePlan = AlertPlan(reminders: [readyOverdue], now: start.addingTimeInterval(125), capacity: 2)
    precondition(!NagDelivery.isSoundOnly(readyOverduePlan.alerts[0], enabled: true)
                 && NagDelivery.isSoundOnly(readyOverduePlan.alerts[1], enabled: true),
                 "Saving an overdue reminder must leave one future actionable card before audio nags.")
    precondition(overdue.reminders.first { $0.id == later.id } == later,
                 "An unrelated save must not opt legacy reminders into sound-only delivery.")

    let snoozeSnapshot = NagDelivery.prepare(ReminderSnapshot(reminders: [snoozed, later]),
                                             replacing: ReminderSnapshot(reminders: [test, later]), now: start)
    let resumed = snoozeSnapshot.reminders.first { $0.id == test.id }!
    precondition(resumed.soundOnlyAfterIndex == 0 && resumed.soundOnlyAnchorAccepted == false)
    let snoozePlan = AlertPlan(reminders: [resumed], now: start, capacity: 2)
    precondition(snoozePlan.alerts.map(\.date) == [start.addingTimeInterval(900), start.addingTimeInterval(1020)])
    let acceptedSnooze = NagDelivery.acceptingVisibleAnchor(identifier: snoozePlan.alerts[0].identifier, in: snoozeSnapshot)!
    let acceptedSnoozePlan = AlertPlan(reminders: [acceptedSnooze.reminders.first { $0.id == test.id }!], now: start, capacity: 2)
    precondition(!NagDelivery.isSoundOnly(acceptedSnoozePlan.alerts[0], enabled: true)
                 && NagDelivery.isSoundOnly(acceptedSnoozePlan.alerts[1], enabled: true))
    precondition(NagDelivery.acceptingVisibleAnchor(identifier: oldPrimary.identifier, in: snoozeSnapshot) == nil,
                 "A stale-generation success callback must not authorize sound-only nags after Snooze.")
    let stopped = NagDelivery.prepare(ReminderSnapshot(reminders: [completed]), replacing: ReminderSnapshot(), now: start)
    precondition(stopped.reminders[0].soundOnlyAfterIndex == nil)
    precondition(AlertPlan(reminders: stopped.reminders, now: start).alerts.isEmpty)

    let pending = initial.alerts.compactMap { PendingNudge($0.identifier) }
    let currentOnly = NagDelivery.rewritableAlerts(pending: pending, reminders: [resumed, later], now: beforeDue)
    precondition(currentOnly.allSatisfy { $0.reminder.id == later.id }, "Never rewrite stale generations after Snooze.")
    let nearDue = NagDelivery.rewritableAlerts(pending: pending, reminders: [test, later], now: start.addingTimeInterval(-4))
    precondition(!nearDue.contains { $0.reminder.id == test.id && $0.index == 0 })
    precondition(nearDue.contains { $0.reminder.id == later.id }, "Skipping an imminent request must not affect other reminders.")
    let rewritten = nearDue.first { $0.reminder.id == test.id && $0.index == 1 }!
    let afterReopen = start.addingTimeInterval(30)
    let rewrittenRequest = NotificationRequestFactory.make(for: rewritten, soundOnlyEnabled: true, now: afterReopen)
    precondition(rewritten.date == start.addingTimeInterval(120))
    precondition((rewrittenRequest.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval == 90,
                 "Rewriting must preserve the absolute due time, not restart the original delay.")
    var notificationsOff = test
    notificationsOff.preferences.notifications = false
    precondition(NagDelivery.rewritableAlerts(pending: pending, reminders: [notificationsOff], now: beforeDue).isEmpty)
    precondition(NagDelivery.rewritableAlerts(pending: pending, reminders: [completed], now: beforeDue).isEmpty)
    print("Visible anchor, overdue save, Snooze, generation isolation, and original-time checks passed.")
}

func checkSoundOnlyCleanup() {
    let now = start.addingTimeInterval(-30)
    let prepared = NagDelivery.prepare(ReminderSnapshot(reminders: [test]), replacing: ReminderSnapshot(), now: now)
    let firstCandidate = AlertPlan(reminders: prepared.reminders, now: now, capacity: 1).alerts[0]
    let accepted = NagDelivery.acceptingVisibleAnchor(identifier: firstCandidate.identifier, in: prepared)!
    let plan = AlertPlan(reminders: accepted.reminders, now: now, capacity: 3)
    let requests = plan.alerts.map { NotificationRequestFactory.make(for: $0, soundOnlyEnabled: true, now: now) }
    let otherAlert = ScheduledAlert(reminder: later, index: 0, date: later.due)
    let otherRequest = NotificationRequestFactory.make(for: otherAlert, soundOnlyEnabled: true, now: now)
    let entries = zip(plan.alerts, requests).compactMap { alert, request in
        NotificationRequestFactory.visibleNudge(identifier: request.identifier, content: request.content, date: alert.date)
    } + [NotificationRequestFactory.visibleNudge(identifier: otherRequest.identifier, content: otherRequest.content,
                                                 date: otherAlert.date)!]
    precondition(entries.count == 2)
    precondition(DeliveredNudge.supersededIdentifiers(in: entries).isEmpty,
                 "Audio-only records must not retire the original card during reopen cleanup.")
    precondition(NotificationRequestFactory.visibleNudge(identifier: requests[2].identifier, content: requests[2].content,
                                                          date: plan.alerts[2].date) == nil,
                 "Foreground audio-only arrivals must not trigger visible-card cleanup.")
    let fullNag = NotificationRequestFactory.make(for: plan.alerts[2], soundOnlyEnabled: false, now: now)
    let visibleIncoming = NotificationRequestFactory.visibleNudge(identifier: fullNag.identifier, content: fullNag.content,
                                                                  date: plan.alerts[2].date)!
    precondition(DeliveredNudge.supersededIdentifiers(in: entries, by: visibleIncoming) == [requests[0].identifier])
    let blankLegacyContent = UNMutableNotificationContent()
    precondition(NotificationRequestFactory.visibleNudge(identifier: requests[0].identifier, content: blankLegacyContent,
                                                          date: start) == nil)
    print("Sound-only cleanup isolation checks passed.")
}

func checkSoundOnlyDatabaseCompatibility() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "nudge-sound-checks.\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suite)!
    defer {
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    // Build an old-schema fixture by explicitly stripping the new optional fields.
    let original = ReminderSnapshot(reminders: [test, later], deletedIDs: [UUID()])
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
    var records = json["reminders"] as! [[String: Any]]
    for index in records.indices {
        records[index].removeValue(forKey: "soundOnlyAfterIndex")
        records[index].removeValue(forKey: "soundOnlyAnchorAccepted")
    }
    json["reminders"] = records
    let legacyBytes = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    let decoded = try JSONDecoder().decode(ReminderSnapshot.self, from: legacyBytes)
    precondition(decoded == original && decoded.reminders.allSatisfy {
        $0.soundOnlyAfterIndex == nil && $0.soundOnlyAnchorAccepted == nil
    })
    let database = ReminderDatabase(url: root.appendingPathComponent("Reminders.json"), preferences: preferences)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try legacyBytes.write(to: database.url, options: .atomic)
    let source = try database.read()
    precondition(source == .file(original))
    let afterRead = try Data(contentsOf: database.url)
    precondition(afterRead == legacyBytes, "Reading an old database must leave its bytes intact.")
    var edited = decoded
    edited.reminders[0].generation = UUID()
    edited.reminders[0].title = "Edited reminder"
    let prepared = NagDelivery.prepare(edited, replacing: decoded, now: start.addingTimeInterval(-30))
    precondition(prepared.reminders[0].soundOnlyAfterIndex == 0 && prepared.reminders[0].soundOnlyAnchorAccepted == false)
    precondition(prepared.reminders[1] == later && prepared.deletedIDs == original.deletedIDs)
    let committed = try database.commit(prepared, replacing: source)
    precondition(committed == .file(prepared))
    let readback = try database.read()
    precondition(readback == .file(prepared), "Persisting the anchor must preserve other reminders and deletion history.")
    let anchor = AlertPlan(reminders: [prepared.reminders[0]], now: start.addingTimeInterval(-30), capacity: 1).alerts[0]
    let accepted = NagDelivery.acceptingVisibleAnchor(identifier: anchor.identifier, in: prepared)!
    let acceptedSource = try database.commit(accepted, replacing: readback)
    precondition(acceptedSource == .file(accepted) && accepted.reminders[0].soundOnlyAnchorAccepted == true)
    precondition(accepted.reminders[1] == later && accepted.deletedIDs == original.deletedIDs)
    print("Optional-anchor database compatibility and preservation checks passed.")
}

checkSoundOnlyRequests()
checkSoundOnlyAnchorsAndIsolation()
checkSoundOnlyCleanup()
try checkSoundOnlyDatabaseCompatibility()


// Backup round trips and imports must not overwrite live records or tombstones.
do {
    let date = Date(timeIntervalSince1970: 2_000_000_000)
    let item = Reminder(title: "Backup check", notes: "Preserve notes", due: date,
                        repeatAnchor: date, preferences: ReminderPreferences())
    let original = ReminderSnapshot(reminders: [item])
    let bytes = try JSONEncoder().encode(ReminderBackup(snapshot: original))
    let backup = try ReminderBackup.decode(bytes)
    let emptyImport = try backup.merging(into: ReminderSnapshot())
    precondition(emptyImport.reminders.count == 1)
    precondition(emptyImport.reminders[0].id == item.id)
    precondition(emptyImport.reminders[0].generation != item.generation)
    let secondImport = try backup.merging(into: emptyImport)
    precondition(secondImport == emptyImport)
    var edited = item
    edited.title = "Keep current edit"
    let live = ReminderSnapshot(reminders: [edited])
    let preserved = try backup.merging(into: live)
    precondition(preserved == live)
    let deleted = ReminderSnapshot(deletedIDs: [item.id])
    let skipped = try backup.merging(into: deleted)
    precondition(skipped == deleted)
    let duplicate = ReminderBackup(snapshot: ReminderSnapshot(reminders: [item, item]))
    do {
        _ = try ReminderBackup.decode(JSONEncoder().encode(duplicate))
        fatalError("Duplicate backup IDs must fail validation")
    } catch {}
    do {
        _ = try ReminderBackup.decode(Data("{}".utf8))
        fatalError("Invalid backup must be rejected")
    } catch {}
    print("Backup round-trip, merge, duplicate and invalid-file checks passed.")
} catch { fatalError("Backup checks failed: \(error)") }
