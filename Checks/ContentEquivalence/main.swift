import Foundation
import UserNotifications

let testNow = Date(timeIntervalSince1970: 1_900_000_000)

func content(body: String = "", subtitle: String = "") -> UNMutableNotificationContent {
    let result = UNMutableNotificationContent()
    result.title = "Keep the reminder"
    result.body = body
    result.subtitle = subtitle
    result.categoryIdentifier = NotificationRequestFactory.category
    result.threadIdentifier = "test-thread"
    result.sound = .default
    result.userInfo = ["test": "unchanged"]
    return result
}

func copy(_ content: UNNotificationContent) -> UNMutableNotificationContent {
    content.mutableCopy() as! UNMutableNotificationContent
}

// KVC reaches the native object setter without Swift bridging nil into "".
// This reproduces the empty-text representation returned by the user's phone.
let empty = content()
let nilBody = copy(empty)
nilBody.setValue(nil, forKey: "body")
let nilSubtitle = copy(empty)
nilSubtitle.setValue(nil, forKey: "subtitle")
let bothNil = copy(nilBody)
bothNil.setValue(nil, forKey: "subtitle")
precondition(nilBody.value(forKey: "body") == nil)
precondition(nilSubtitle.value(forKey: "subtitle") == nil)
precondition(!empty.isEqual(nilBody), "The fixture must reproduce raw nil-versus-empty inequality")
precondition(!empty.isEqual(nilSubtitle), "The subtitle fixture must also differ before normalization")
precondition(nilBody.body.isEmpty && nilSubtitle.subtitle.isEmpty,
             "Swift getters hide the raw nil-versus-empty difference")

for normalized in [nilBody, nilSubtitle, bothNil] {
    precondition(NotificationContentEquivalence.equal(empty, normalized))
    precondition(NotificationContentEquivalence.equal(normalized, empty), "Comparison must be symmetric")
}
precondition(NotificationContentEquivalence.equal(empty, copy(empty)))
precondition(bothNil.value(forKey: "body") == nil && bothNil.value(forKey: "subtitle") == nil,
             "Comparing must not mutate the OS-returned content")
precondition(empty.value(forKey: "body") as? String == "" && empty.value(forKey: "subtitle") as? String == "",
             "Comparing must not mutate the expected content")
precondition(!empty.isEqual(bothNil), "Original objects must still retain their raw representations")

let nonemptyBody = content(body: "Do not lose these notes")
let lostBody = copy(nonemptyBody); lostBody.setValue(nil, forKey: "body")
precondition(!NotificationContentEquivalence.equal(nonemptyBody, lostBody))
precondition(!NotificationContentEquivalence.equal(lostBody, nonemptyBody))
let nonemptySubtitle = content(subtitle: "Important detail")
let lostSubtitle = copy(nonemptySubtitle); lostSubtitle.setValue(nil, forKey: "subtitle")
precondition(!NotificationContentEquivalence.equal(nonemptySubtitle, lostSubtitle))
precondition(!NotificationContentEquivalence.equal(content(body: " "), nilBody), "Whitespace is real content")
precondition(!NotificationContentEquivalence.equal(content(subtitle: " "), nilSubtitle))

// Enter the normalization branch, then prove full content equality still
// rejects differences outside the two explicitly allowed empty-text fields.
let forbiddenEdits: [(UNMutableNotificationContent) -> Void] = [
    { $0.title = "Different reminder" },
    { $0.body = "Unexpected notes" },
    { $0.subtitle = "Unexpected subtitle" },
    { $0.sound = nil },
    { $0.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: "different.caf")) },
    { $0.userInfo["test"] = "changed" },
    { $0.categoryIdentifier = "wrong-actions" },
    { $0.threadIdentifier = "wrong-reminder" },
    { $0.badge = 7 },
    { $0.interruptionLevel = .passive },
    { $0.relevanceScore = 0.75 },
    { $0.launchImageName = "different-launch-image" },
    { $0.targetContentIdentifier = "different-target" }
]
for edit in forbiddenEdits {
    let changed = copy(bothNil)
    edit(changed)
    precondition(!NotificationContentEquivalence.equal(empty, changed))
    precondition(!NotificationContentEquivalence.equal(changed, empty))
}
let privateDifference = copy(bothNil)
if privateDifference.responds(to: NSSelectorFromString("setShouldHideDate:")) {
    privateDifference.setValue(NSNumber(value: true), forKey: "shouldHideDate")
    precondition(!NotificationContentEquivalence.equal(empty, privateDifference),
                 "Full equality must still catch OS-private content differences")
} else {
    print("This SDK does not expose shouldHideDate; public-property negative controls still ran.")
}

func reminder(minutes: Int) -> Reminder {
    var preferences = ReminderPreferences()
    preferences.nagMinutes = minutes
    let due = testNow.addingTimeInterval(600)
    return Reminder(title: "Reminder \(minutes)", notes: "", due: due,
                    repeatAnchor: due, preferences: preferences)
}

func normalized(_ request: UNNotificationRequest) -> UNNotificationRequest {
    let result = copy(request.content)
    if result.body.isEmpty { result.setValue(nil, forKey: "body") }
    if result.subtitle.isEmpty { result.setValue(nil, forKey: "subtitle") }
    return UNNotificationRequest(identifier: request.identifier, content: result, trigger: request.trigger)
}

func phases(for reminder: Reminder) -> [UNNotificationRequest] {
    let cadence = HourlyNagCadence(minutes: reminder.preferences.nagMinutes)!
    return cadence.phaseDates(first: reminder.alertDate).enumerated().map { phase, date in
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: DateComponents(minute: phase * cadence.minutes, second: 7), repeats: true)
        let alert = ScheduledAlert(reminder: reminder, index: 0, date: date)
        let result = NotificationRequestFactory.make(for: alert, soundOnlyEnabled: false,
                                                     now: testNow, triggerOverride: trigger)
        let text = copy(result.content)
        text.subtitle = ""
        text.userInfo[HourlyNagSchedule.phaseKey] = phase
        text.userInfo[HourlyNagSchedule.minutesKey] = cadence.minutes
        text.userInfo[HourlyNagSchedule.anchorKey] = reminder.alertDate.timeIntervalSince1970
        return UNNotificationRequest(identifier: result.identifier, content: text, trigger: trigger)
    }
}

// All phase cadences retain every trigger and duplicate identifier occurrence.
// Empty text must not disguise missing records, duplicated phases or timing loss.
for minutes in [2, 5, 10, 15, 20, 30] {
    let expected = phases(for: reminder(minutes: minutes))
    let actual = expected.map(normalized)
    precondition(actual.count == 60 / minutes)
    precondition(HourlyNagSchedule.matches(Array(actual.reversed()), expected))
    precondition(HourlyNagSchedule.mismatch(actual, expected) == nil)
    precondition(!HourlyNagSchedule.matches(Array(actual.dropLast()), expected))
    precondition(!HourlyNagSchedule.matches(actual + [actual[0]], expected))
    var duplicated = actual; duplicated[duplicated.count - 1] = actual[0]
    precondition(!HourlyNagSchedule.matches(duplicated, expected))
    let missing = HourlyNagSchedule.mismatch(duplicated, expected)!
    precondition(missing.missing.count == 1 && missing.extra.count == 1 && missing.changed.isEmpty)
    var retimed = actual
    retimed[0] = UNNotificationRequest(identifier: actual[0].identifier, content: actual[0].content,
        trigger: UNCalendarNotificationTrigger(dateMatching: DateComponents(minute: 59, second: 8), repeats: true))
    precondition(!HourlyNagSchedule.matches(retimed, expected))
    let timingMismatch = HourlyNagSchedule.mismatch(retimed, expected)!
    precondition(timingMismatch.changed.count == 1 && timingMismatch.changed[0].triggerChanged)
    precondition(timingMismatch.changed[0].contentFields.isEmpty)
    let renamed = UNNotificationRequest(identifier: "different.identifier", content: actual[0].content,
                                         trigger: actual[0].trigger)
    precondition(!HourlyNagSchedule.matches([renamed], [expected[0]]))
}

func minuteRequest(_ reminder: Reminder) -> UNNotificationRequest {
    NotificationRequestFactory.make(
        for: ScheduledAlert(reminder: reminder, index: 0, date: reminder.alertDate, repeatsEveryMinute: true),
        soundOnlyEnabled: false, now: testNow,
        triggerOverride: UNTimeIntervalNotificationTrigger(timeInterval: 60, repeats: true))
}

@MainActor func checkMinuteUpdate() async throws {
    let oldReminder = reminder(minutes: 1)
    var currentReminder = oldReminder
    currentReminder.generation = UUID()
    currentReminder.adjustedDue = oldReminder.alertDate.addingTimeInterval(300)
    let old = normalized(minuteRequest(oldReminder))
    let expected = minuteRequest(currentReminder)
    let preservedPhases = phases(for: reminder(minutes: 5)).map(normalized)
    var pending = preservedPhases + [old]
    let desired = preservedPhases + [expected]
    var adds = 0
    var reads = 0
    var cancellations: [[String]] = []
    let operations = MinuteScheduleReplacement.Operations(pending: {
        reads += 1
        return pending
    }, add: { request in
        adds += 1
        pending.removeAll { $0.identifier == request.identifier }
        pending.append(normalized(request))
    }, remove: { identifiers in
        precondition(identifiers == [old.identifier], "Only the edited reminder's old generation may retire")
        cancellations.append(identifiers)
        pending.removeAll { identifiers.contains($0.identifier) }
    })
    let plan = MinuteScheduleReplacement.plan(actual: pending, desired: desired,
                                              reminders: [currentReminder], now: testNow)!
    precondition(!plan.replacementAlreadyAccepted)
    let outcome = try await MinuteScheduleReplacement.apply(plan, operations: operations, isCurrent: { true })
    precondition(outcome == .applied && adds == 1 && reads == 3 && cancellations == [[old.identifier]],
                 "An accepted nil-body request must verify on the first pass, without a retry")
    precondition(HourlyNagSchedule.matches(pending, desired))
    let actualPhases = pending.filter(HourlyNagSchedule.isPhase)
    precondition(actualPhases.count == preservedPhases.count)
    for (actual, before) in zip(actualPhases, preservedPhases) {
        precondition(actual.identifier == before.identifier && actual.content.isEqual(before.content)
                     && actual.trigger?.isEqual(before.trigger) == true,
                     "Unrelated phases must retain their original content and triggers")
    }

    // The already-accepted generation may use the native nil representation
    // while the desired request is freshly constructed with empty strings.
    pending = preservedPhases + [old, normalized(expected)]
    adds = 0; reads = 0; cancellations = []
    let retirement = MinuteScheduleReplacement.plan(actual: pending, desired: desired,
                                                    reminders: [currentReminder], now: testNow)!
    precondition(retirement.replacementAlreadyAccepted)
    let retired = try await MinuteScheduleReplacement.apply(retirement, operations: operations, isCurrent: { true })
    precondition(retired == .applied && adds == 0 && reads == 2 && cancellations == [[old.identifier]])
    precondition(HourlyNagSchedule.matches(pending, desired))
}

try await checkMinuteUpdate()
print("Content equivalence checks passed: raw nil/empty reproduction, immutable comparison, strict negative controls, every phase cadence, and first-pass minute replacement plus retirement.")
