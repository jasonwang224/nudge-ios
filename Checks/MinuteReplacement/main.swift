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

func changingContent(_ request: UNNotificationRequest, _ edit: (UNMutableNotificationContent) -> Void) -> UNNotificationRequest {
    let content = request.content.mutableCopy() as! UNMutableNotificationContent
    edit(content)
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
precondition(basic.preflightRemovals.isEmpty && !basic.replacementAlreadyAccepted)
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

// A retry of the SAME saved generation must finish retiring its old requests
// without adding again or falling back to an app-wide schedule replacement.
let acceptedOriginal = original + [replacement]
let retirement = MinuteScheduleReplacement.plan(actual: acceptedOriginal, desired: desired,
                                                reminders: [newReminder], now: testDate)!
precondition(retirement.replacementAlreadyAccepted && retirement.preflightRemovals.isEmpty)
precondition(retirement.obsolete.map(\.identifier) == [old.identifier])

let invalidCurrentEdits: [(UNMutableNotificationContent) -> Void] = [
    { $0.userInfo["id"] = UUID().uuidString },
    { $0.userInfo["generation"] = oldReminder.generation.uuidString },
    { $0.userInfo[NagDelivery.versionKey] = NagDelivery.payloadVersion - 1 },
    { $0.userInfo[NagDelivery.titleKey] = "Wrong title" },
    { $0.userInfo[NagDelivery.soundOnlyKey] = true },
    { $0.userInfo.removeValue(forKey: NagDelivery.scheduledKey) },
    { $0.userInfo[NagDelivery.scheduledKey] = Double.nan },
    { $0.userInfo[NagDelivery.scheduledKey] = Double.infinity },
    { $0.userInfo[NagDelivery.scheduledKey] = newReminder.alertDate.timeIntervalSince1970 - 60 },
    { $0.userInfo[NagDelivery.scheduledKey] = newReminder.alertDate.timeIntervalSince1970 + 1 },
    { $0.userInfo[NagDelivery.scheduledKey] = newReminder.alertDate.timeIntervalSince1970 + 60 },
    { $0.title = "Wrong title" },
    { $0.body = "Wrong notes" },
    { $0.categoryIdentifier = "Wrong category" },
    { $0.threadIdentifier = UUID().uuidString },
    { $0.sound = nil },
    { $0.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: "wrong.caf")) },
    { $0.userInfo[HourlyNagSchedule.phaseKey] = 0 }
]
for edit in invalidCurrentEdits {
    let corrupt = changingContent(replacement, edit)
    precondition(MinuteScheduleReplacement.plan(actual: original + [corrupt],
        desired: phases + [corrupt, other], reminders: [newReminder], now: testDate) == nil)
}
precondition(MinuteScheduleReplacement.plan(actual: acceptedOriginal + [replacement], desired: desired,
                                           reminders: [newReminder], now: testDate) == nil)
precondition(MinuteScheduleReplacement.plan(actual: acceptedOriginal + [old], desired: desired,
                                           reminders: [newReminder], now: testDate) == nil)
let wrongRepeatingTrigger = request(newReminder, interval: 300)
precondition(MinuteScheduleReplacement.plan(actual: original + [wrongRepeatingTrigger],
    desired: phases + [wrongRepeatingTrigger, other], reminders: [newReminder], now: testDate) == nil)
precondition(MinuteScheduleReplacement.plan(actual: acceptedOriginal, desired: phases + [replacement, renamed(other)],
                                           reminders: [newReminder], now: testDate) == nil)
precondition(MinuteScheduleReplacement.plan(actual: acceptedOriginal, desired: Array(desired.dropFirst()),
                                           reminders: [newReminder], now: testDate) == nil)
precondition(MinuteScheduleReplacement.plan(actual: acceptedOriginal, desired: desired + [phase(0)],
                                           reminders: [newReminder], now: testDate) == nil)

var pastDue = newReminder
pastDue.due = testDate.addingTimeInterval(-180)
let pastDueRequest = request(pastDue)
let alignedPast = changingContent(pastDueRequest) {
    $0.userInfo[NagDelivery.scheduledKey] = testDate.addingTimeInterval(-60).timeIntervalSince1970
}
precondition(MinuteScheduleReplacement.plan(actual: original + [alignedPast],
    desired: phases + [alignedPast, other], reminders: [pastDue], now: testDate) != nil)
let distantAligned = changingContent(pastDueRequest) {
    $0.userInfo[NagDelivery.scheduledKey] = testDate.addingTimeInterval(120).timeIntervalSince1970
}
precondition(MinuteScheduleReplacement.plan(actual: original + [distantAligned],
    desired: phases + [distantAligned, other], reminders: [pastDue], now: testDate) == nil)

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
    var onRemove: (() -> Void)?
    var readback: (([UNNotificationRequest], Int) -> [UNNotificationRequest])?
    let targetID: UUID

    init(_ requests: [UNNotificationRequest], targetID: UUID = oldReminder.id) {
        self.requests = requests; self.targetID = targetID; peak = requests.count
    }

    var operations: MinuteScheduleReplacement.Operations {
        MinuteScheduleReplacement.Operations(pending: {
            self.reads += 1
            self.onRead?()
            return self.readback?(self.requests, self.reads) ?? self.requests
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
            self.onRemove?()
        })
    }
}

@discardableResult @MainActor
func expectFailure(_ body: () async throws -> Void) async -> MinuteScheduleReplacement.Problem {
    do { try await body(); preconditionFailure("Expected a verified scheduling failure") }
    catch {
        guard let problem = error as? MinuteScheduleReplacement.Problem else {
            preconditionFailure("Expected a scoped scheduling error, received \(error)")
        }
        return problem
    }
}

@MainActor func runChecks() async throws {
    let normal = MockCenter(original)
    let normalOutcome = try await MinuteScheduleReplacement.apply(basic, operations: normal.operations, isCurrent: { true })
    precondition(normalOutcome == .applied && normal.events == ["add", "remove"])
    precondition(HourlyNagSchedule.matches(normal.requests, desired))
    precondition(HourlyNagSchedule.matches(normal.requests.filter(HourlyNagSchedule.isPhase), phases))

    let retireOnly = MockCenter(acceptedOriginal)
    let retired = try await MinuteScheduleReplacement.apply(retirement, operations: retireOnly.operations, isCurrent: { true })
    precondition(retired == .applied && retireOnly.adds == 0 && retireOnly.events == ["remove"])
    precondition(HourlyNagSchedule.matches(retireOnly.requests, desired))

    // A successful add can be temporarily absent from readback. Its retry must
    // recognize that SAME generation once visible, then retire only the backup.
    let delayedReadback = MockCenter(original)
    delayedReadback.readback = { records, read in
        read >= 2 ? records.filter { $0.identifier != replacement.identifier } : records
    }
    let addVerificationFailure = await expectFailure {
        _ = try await MinuteScheduleReplacement.apply(basic, operations: delayedReadback.operations, isCurrent: { true })
    }
    precondition(addVerificationFailure.details.contains("Stage: after replacement add."))
    precondition(addVerificationFailure.details.contains("MISSING") && addVerificationFailure.details.contains(replacement.identifier))
    precondition(!addVerificationFailure.message.contains("Stage:") && addVerificationFailure.errorDescription == addVerificationFailure.message)
    precondition(delayedReadback.adds == 1 && delayedReadback.removals.isEmpty)
    delayedReadback.readback = nil
    let retryAccepted = MinuteScheduleReplacement.plan(actual: delayedReadback.requests, desired: desired,
                                                       reminders: [newReminder], now: testDate)!
    precondition(retryAccepted.replacementAlreadyAccepted)
    _ = try await MinuteScheduleReplacement.apply(retryAccepted, operations: delayedReadback.operations, isCurrent: { true })
    precondition(delayedReadback.adds == 1 && delayedReadback.events == ["add", "remove"])
    precondition(HourlyNagSchedule.matches(delayedReadback.requests, desired))

    // The fresh state check also protects retire-only retries. A fired unrelated
    // one-shot requires replanning; it is not permission to cancel other records.
    let staleRetirement = MockCenter(acceptedOriginal.filter { $0.identifier != other.identifier })
    let staleProblem = await expectFailure {
        _ = try await MinuteScheduleReplacement.apply(retirement, operations: staleRetirement.operations, isCurrent: { true })
    }
    precondition(staleRetirement.events.isEmpty && staleProblem.details.contains("Stage: before replacement."))
    precondition(staleProblem.details.contains(other.identifier))
    var retirementCurrent = true
    let supersededRetirement = MockCenter(acceptedOriginal)
    supersededRetirement.onRead = { retirementCurrent = false }
    let skippedRetirement = try await MinuteScheduleReplacement.apply(retirement, operations: supersededRetirement.operations,
                                                                     isCurrent: { retirementCurrent })
    precondition(skippedRetirement == .superseded && supersededRetirement.events.isEmpty)
    retirementCurrent = true
    let changedAfterRetirement = MockCenter(acceptedOriginal)
    changedAfterRetirement.onRemove = { retirementCurrent = false }
    let retiredThenSuperseded = try await MinuteScheduleReplacement.apply(retirement, operations: changedAfterRetirement.operations,
                                                                          isCurrent: { retirementCurrent })
    precondition(retiredThenSuperseded == .superseded && changedAfterRetirement.adds == 0)
    precondition(HourlyNagSchedule.matches(changedAfterRetirement.requests, desired))

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
    let removalProblem = await expectFailure {
        _ = try await MinuteScheduleReplacement.apply(basic, operations: ignoredRemoval.operations, isCurrent: { true })
    }
    precondition(removalProblem.details.contains("Stage: after old-generation retirement."))
    precondition(removalProblem.details.contains("EXTRA") && removalProblem.details.contains(old.identifier))
    precondition(ignoredRemoval.adds == 1 && ignoredRemoval.removals.count == 1)
    ignoredRemoval.ignoreRemove = false
    let retryRetirement = MinuteScheduleReplacement.plan(actual: ignoredRemoval.requests, desired: desired,
                                                         reminders: [newReminder], now: testDate)!
    precondition(retryRetirement.replacementAlreadyAccepted)
    _ = try await MinuteScheduleReplacement.apply(retryRetirement, operations: ignoredRemoval.operations, isCurrent: { true })
    precondition(ignoredRemoval.adds == 1 && ignoredRemoval.removals.count == 2)
    precondition(HourlyNagSchedule.matches(ignoredRemoval.requests, desired))

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
    let fullAccepted = crowdedOthers + Array(oldGenerations.prefix(4)) + [replacement]
    let fullRetirement = MinuteScheduleReplacement.plan(actual: fullAccepted, desired: sixtyDesired,
                                                        reminders: [newReminder], now: testDate)!
    precondition(fullRetirement.replacementAlreadyAccepted && fullRetirement.preflightRemovals.isEmpty)
    let fullRetry = MockCenter(fullAccepted)
    _ = try await MinuteScheduleReplacement.apply(fullRetirement, operations: fullRetry.operations, isCurrent: { true })
    precondition(fullRetry.adds == 0 && fullRetry.peak == 64 && fullRetry.requests.count == 60)
    precondition(HourlyNagSchedule.matches(fullRetry.requests, sixtyDesired))
}

try await runChecks()
print("Minute replacement checks passed: scoped add/confirm/retire, validated retire-only retries, diagnostics, phase preservation, failures, capacity, and rapid revision races.")
