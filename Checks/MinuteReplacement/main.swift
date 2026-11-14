import Foundation
import UserNotifications

let testDate = Date(timeIntervalSince1970: 1_800_000_000)
func minuteReminder() -> Reminder {
    var preferences = ReminderPreferences(); preferences.nagMinutes = 1
    return Reminder(title: "Minute reminder", notes: "Keep other cards", due: testDate,
                    repeatAnchor: testDate, preferences: preferences)
}
func shifted(_ reminder: Reminder) -> Reminder {
    var next = reminder
    next.generation = UUID()
    next.due = reminder.due.addingTimeInterval(300)
    return next
}
func request(_ reminder: Reminder, index: Int = 0, interval: Double = 60) -> UNNotificationRequest {
    let alert = ScheduledAlert(reminder: reminder, index: index, date: reminder.alertDate, repeatsEveryMinute: true)
    return NotificationRequestFactory.make(for: alert, soundOnlyEnabled: false, now: testDate,
        triggerOverride: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: true))
}
func phase(_ index: Int) -> UNNotificationRequest {
    let content = UNMutableNotificationContent(); content.title = "Unrelated hourly group"
    content.userInfo = [HourlyNagSchedule.phaseKey: index, HourlyNagSchedule.minutesKey: 5]
    return UNNotificationRequest(identifier: "unrelated-phase-group", content: content,
        trigger: UNCalendarNotificationTrigger(dateMatching: DateComponents(minute: index * 5), repeats: true))
}
func unrelated(_ index: Int) -> UNNotificationRequest {
    let content = UNMutableNotificationContent(); content.title = "Unrelated \(index)"
    return UNNotificationRequest(identifier: "foreign.\(index)", content: content,
        trigger: UNCalendarNotificationTrigger(dateMatching: DateComponents(year: 2030, month: 1, day: 1, hour: 12 + index / 60, minute: index % 60), repeats: false))
}
func renamed(_ request: UNNotificationRequest) -> UNNotificationRequest {
    let content = request.content.mutableCopy() as! UNMutableNotificationContent
    content.title += " changed"
    return UNNotificationRequest(identifier: request.identifier, content: content, trigger: request.trigger)
}

let oldReminder = minuteReminder()
let newReminder = shifted(oldReminder)
let old = request(oldReminder)
let replacement = request(newReminder)
let phases = (0..<12).map(phase)
let other = unrelated(0)
let original = phases + [old, other]
let desired = phases + [replacement, other]
let basic = MinuteScheduleReplacement.plan(actual: original, desired: desired, reminders: [newReminder])!
precondition(basic.obsolete.map(\.identifier) == [old.identifier])
precondition(basic.preflightRemovals.isEmpty)
precondition(HourlyNagSchedule.matches(basic.original, original))
precondition(MinuteScheduleReplacement.plan(actual: Array(original.reversed()), desired: desired, reminders: [newReminder]) != nil)

// A changed phase, a missing phase, a second target, or unrelated content must
// never be smuggled into this public identifier-based replacement path.
var altered = desired; altered[0] = renamed(altered[0])
precondition(MinuteScheduleReplacement.plan(actual: original, desired: altered, reminders: [newReminder]) == nil)
precondition(MinuteScheduleReplacement.plan(actual: original, desired: Array(desired.dropFirst()), reminders: [newReminder]) == nil)
precondition(MinuteScheduleReplacement.plan(actual: original, desired: desired + [phase(0)], reminders: [newReminder]) == nil)
precondition(MinuteScheduleReplacement.plan(actual: original, desired: phases + [replacement, renamed(other)], reminders: [newReminder]) == nil)
precondition(MinuteScheduleReplacement.plan(actual: original + [old], desired: desired, reminders: [newReminder]) == nil)
precondition(MinuteScheduleReplacement.plan(actual: original, desired: desired, reminders: [newReminder, newReminder]) == nil)
precondition(MinuteScheduleReplacement.plan(actual: original, desired: desired, reminders: []) == nil)
var wrongInterval = newReminder; wrongInterval.preferences.nagMinutes = 5
precondition(MinuteScheduleReplacement.plan(actual: original, desired: desired, reminders: [wrongInterval]) == nil)
precondition(MinuteScheduleReplacement.plan(actual: original, desired: phases + [request(newReminder, interval: 300), other], reminders: [newReminder]) == nil)
precondition(MinuteScheduleReplacement.plan(actual: original, desired: phases + [request(newReminder, index: 1), other], reminders: [newReminder]) == nil)
var completed = newReminder; completed.completedAt = testDate
precondition(MinuteScheduleReplacement.plan(actual: original, desired: desired, reminders: [completed]) == nil)
var disabled = newReminder; disabled.preferences.notifications = false
precondition(MinuteScheduleReplacement.plan(actual: original, desired: desired, reminders: [disabled]) == nil)
var invalid = newReminder; invalid.due = Date(timeIntervalSince1970: .infinity)
precondition(MinuteScheduleReplacement.plan(actual: original, desired: desired, reminders: [invalid]) == nil)

let wrongContent = replacement.content.mutableCopy() as! UNMutableNotificationContent
wrongContent.userInfo["generation"] = oldReminder.generation.uuidString
let forged = UNNotificationRequest(identifier: replacement.identifier, content: wrongContent, trigger: replacement.trigger)
precondition(MinuteScheduleReplacement.plan(actual: original, desired: phases + [forged, other], reminders: [newReminder]) == nil)
let sharedPhaseContent = old.content.mutableCopy() as! UNMutableNotificationContent
sharedPhaseContent.userInfo[HourlyNagSchedule.phaseKey] = 0
let sharedPhase = UNNotificationRequest(identifier: old.identifier, content: sharedPhaseContent, trigger: old.trigger)
precondition(MinuteScheduleReplacement.plan(actual: original + [sharedPhase], desired: desired + [sharedPhase], reminders: [newReminder]) == nil)
precondition(MinuteScheduleReplacement.plan(actual: phases + [old], desired: phases + [old], reminders: [oldReminder]) == nil)

let crowdedOthers = phases + (0..<47).map(unrelated)
precondition(crowdedOthers.count == 59)
let sixty = crowdedOthers + [old]
let sixtyDesired = crowdedOthers + [replacement]
precondition(MinuteScheduleReplacement.plan(actual: sixty, desired: sixtyDesired, reminders: [newReminder])!.preflightRemovals.isEmpty)
let tooManyOther = crowdedOthers + [unrelated(100)]
precondition(MinuteScheduleReplacement.plan(actual: tooManyOther + [old], desired: tooManyOther + [replacement], reminders: [newReminder]) == nil)

@MainActor final class MockCenter {
    var requests: [UNNotificationRequest]
    var events: [String] = []
    var peak: Int
    var adds = 0
    var reads = 0
    var removals: [[String]] = []
    var failAdd = false
    var dropAdd = false
    var corruptAdd = false
    var losePhaseOnAdd = false
    var ignoreRemove = false
    var onAdd: (() -> Void)?
    var onRead: (() -> Void)?
    let targetID: UUID

    init(_ requests: [UNNotificationRequest], targetID: UUID = oldReminder.id) {
        self.requests = requests; self.targetID = targetID; peak = requests.count
    }

    var operations: MinuteScheduleReplacement.Operations {
        MinuteScheduleReplacement.Operations(pending: {
            self.reads += 1
            self.onRead?()
            return self.requests
        }, add: { request in
            self.events.append("add"); self.adds += 1
            if self.failAdd { throw MinuteScheduleReplacement.Problem(message: "Mock add failure") }
            if !self.dropAdd {
                self.requests.removeAll { $0.identifier == request.identifier }
                self.requests.append(self.corruptAdd ? renamed(request) : request)
                self.peak = max(self.peak, self.requests.count)
            }
            if self.losePhaseOnAdd { self.requests.removeAll { HourlyNagSchedule.isPhase($0) } }
            self.onAdd?()
        }, remove: { ids in
            self.events.append("remove"); self.removals.append(ids)
            // Every attempted cancellation must be narrowly owned by the target.
            precondition(ids.allSatisfy { PendingNudge($0)?.id == self.targetID })
            precondition(!ids.contains("unrelated-phase-group"))
            if !self.ignoreRemove { self.requests.removeAll { ids.contains($0.identifier) } }
            precondition(self.requests.contains { PendingNudge($0.identifier)?.id == self.targetID },
                         "Never remove the final confirmed target request")
        })
    }
}

@MainActor func expectFailure(_ body: () async throws -> Void) async {
    do { try await body(); preconditionFailure("Expected a verified scheduling failure") }
    catch { }
}

@MainActor func runChecks() async throws {
    let normal = MockCenter(original)
    let normalOutcome = try await MinuteScheduleReplacement.apply(basic, operations: normal.operations, isCurrent: { true })
    precondition(normalOutcome == .applied && normal.events == ["add", "remove"])
    precondition(HourlyNagSchedule.matches(normal.requests, desired))
    precondition(HourlyNagSchedule.matches(normal.requests.filter(HourlyNagSchedule.isPhase), phases))

    let atBudget = MockCenter(sixty)
    let atBudgetPlan = MinuteScheduleReplacement.plan(actual: sixty, desired: sixtyDesired, reminders: [newReminder])!
    _ = try await MinuteScheduleReplacement.apply(atBudgetPlan, operations: atBudget.operations, isCurrent: { true })
    precondition(atBudget.peak == 61 && atBudget.requests.count == 60)

    let failedAdd = MockCenter(original); failedAdd.failAdd = true
    await expectFailure { _ = try await MinuteScheduleReplacement.apply(basic, operations: failedAdd.operations, isCurrent: { true }) }
    precondition(HourlyNagSchedule.matches(failedAdd.requests, original) && failedAdd.removals.isEmpty)

    let lostAdd = MockCenter(original); lostAdd.dropAdd = true
    await expectFailure { _ = try await MinuteScheduleReplacement.apply(basic, operations: lostAdd.operations, isCurrent: { true }) }
    precondition(lostAdd.removals.isEmpty && HourlyNagSchedule.matches(lostAdd.requests, original))

    let changedAdd = MockCenter(original); changedAdd.corruptAdd = true
    await expectFailure { _ = try await MinuteScheduleReplacement.apply(basic, operations: changedAdd.operations, isCurrent: { true }) }
    precondition(changedAdd.removals.isEmpty && changedAdd.requests.contains { $0.identifier == old.identifier })

    let droppedPhase = MockCenter(original); droppedPhase.losePhaseOnAdd = true
    await expectFailure { _ = try await MinuteScheduleReplacement.apply(basic, operations: droppedPhase.operations, isCurrent: { true }) }
    precondition(droppedPhase.removals.isEmpty, "Do not retire backups after unrelated schedule loss")

    let staleSnapshot = MockCenter(Array(original.dropLast()))
    await expectFailure { _ = try await MinuteScheduleReplacement.apply(basic, operations: staleSnapshot.operations, isCurrent: { true }) }
    precondition(staleSnapshot.events.isEmpty, "An unrelated alert firing must force a fresh plan, not bulk mutation")

    let noRevision = MockCenter(original)
    let skipped = try await MinuteScheduleReplacement.apply(basic, operations: noRevision.operations, isCurrent: { false })
    precondition(skipped == .superseded && noRevision.reads == 0 && noRevision.events.isEmpty)

    var current = true
    let changedDuringRead = MockCenter(original)
    changedDuringRead.onRead = { current = false }
    let stoppedAtRead = try await MinuteScheduleReplacement.apply(basic, operations: changedDuringRead.operations, isCurrent: { current })
    precondition(stoppedAtRead == .superseded && changedDuringRead.events.isEmpty)

    current = true
    let changedDuringAdd = MockCenter(original)
    changedDuringAdd.onAdd = { current = false }
    let stoppedAtAdd = try await MinuteScheduleReplacement.apply(basic, operations: changedDuringAdd.operations, isCurrent: { current })
    precondition(stoppedAtAdd == .superseded && changedDuringAdd.removals.isEmpty)
    precondition(changedDuringAdd.requests.contains { $0.identifier == old.identifier })

    current = true
    let changedDuringConfirmation = MockCenter(original)
    changedDuringConfirmation.onRead = { if changedDuringConfirmation.reads == 2 { current = false } }
    let stoppedAtConfirmation = try await MinuteScheduleReplacement.apply(basic, operations: changedDuringConfirmation.operations, isCurrent: { current })
    precondition(stoppedAtConfirmation == .superseded && changedDuringConfirmation.removals.isEmpty)

    let ignoredRemoval = MockCenter(original); ignoredRemoval.ignoreRemove = true
    await expectFailure { _ = try await MinuteScheduleReplacement.apply(basic, operations: ignoredRemoval.operations, isCurrent: { true }) }
    precondition(ignoredRemoval.adds == 1 && ignoredRemoval.removals.count == 1)

    // Ten edits can each supersede a successful add callback. Verify bounded
    // redundant-generation pruning, no global cancellation, and eventual latest
    // generation convergence while all twelve shared-ID phases remain intact.
    let rapid = MockCenter(sixty)
    var latest = oldReminder
    for _ in 0..<10 {
        latest = shifted(latest)
        let target = request(latest)
        let final = crowdedOthers + [target]
        let nextPlan = MinuteScheduleReplacement.plan(actual: rapid.requests, desired: final, reminders: [latest])!
        current = true
        rapid.onAdd = { current = false }
        let result = try await MinuteScheduleReplacement.apply(nextPlan, operations: rapid.operations, isCurrent: { current })
        precondition(result == .superseded && rapid.peak <= 64)
        precondition(HourlyNagSchedule.matches(rapid.requests.filter(HourlyNagSchedule.isPhase), phases))
    }
    latest = shifted(latest)
    let final = crowdedOthers + [request(latest)]
    let lastPlan = MinuteScheduleReplacement.plan(actual: rapid.requests, desired: final, reminders: [latest])!
    precondition(rapid.requests.count == 64 && lastPlan.preflightRemovals.count == 1)
    current = true; rapid.onAdd = nil
    let settled = try await MinuteScheduleReplacement.apply(lastPlan, operations: rapid.operations, isCurrent: { current })
    precondition(settled == .applied && rapid.requests.count == 60 && rapid.peak == 64)
    precondition(HourlyNagSchedule.matches(rapid.requests, final))

    // Even when freeing headroom is necessary, a failed replacement preserves
    // at least one confirmed backup and every unrelated request.
    let oldGenerations = (0..<5).map { _ in request(shifted(oldReminder)) }
    let fullQueue = crowdedOthers + oldGenerations
    let fullPlan = MinuteScheduleReplacement.plan(actual: fullQueue, desired: sixtyDesired, reminders: [newReminder])!
    let fullFailure = MockCenter(fullQueue); fullFailure.failAdd = true
    await expectFailure { _ = try await MinuteScheduleReplacement.apply(fullPlan, operations: fullFailure.operations, isCurrent: { true }) }
    precondition(fullFailure.requests.count == 63 && fullFailure.adds == 1)
    precondition(fullFailure.requests.filter { PendingNudge($0.identifier)?.id == oldReminder.id }.count == 4)
    precondition(HourlyNagSchedule.matches(fullFailure.requests.filter { PendingNudge($0.identifier)?.id != oldReminder.id }, crowdedOthers))
    precondition(MinuteScheduleReplacement.plan(actual: fullQueue + [unrelated(200)], desired: sixtyDesired, reminders: [newReminder]) == nil)
}

try await runChecks()
print("Minute replacement checks passed: scoped add/confirm/retire, phase preservation, failures, capacity, and rapid revision races.")
