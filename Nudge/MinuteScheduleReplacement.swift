import Foundation
import UserNotifications
#if canImport(ObjectiveC)
import ObjectiveC
#endif

// A deliberately narrow alternative to the app-wide private bulk transaction.
// Every unrelated request, including duplicate-ID hourly phases, must remain
// exactly unchanged. Only one reminder's old nonphase generations can retire.
enum MinuteScheduleReplacement {
    struct Plan {
        let original: [UNNotificationRequest]
        let desired: [UNNotificationRequest]
        let replacement: UNNotificationRequest
        let replacementAlreadyAccepted: Bool
        let obsolete: [UNNotificationRequest]
        let preflightRemovals: [String]
    }

    enum Outcome: Equatable { case applied, superseded }

    struct Problem: LocalizedError {
        let message: String
        let details: String
        init(message: String, details: String = "") {
            self.message = message
            self.details = details
        }
        var errorDescription: String? { message }
    }

    // Tests inject an in-memory notification center. The production overload
    // uses the same checked operations against UNUserNotificationCenter.
    @MainActor struct Operations {
        let pending: () async -> [UNNotificationRequest]
        let add: (UNNotificationRequest) async throws -> Void
        let remove: ([String]) -> Void
    }

    static func plan(actual: [UNNotificationRequest], desired: [UNNotificationRequest],
                     reminders: [Reminder], now: Date = .now) -> Plan? {
        guard actual.count <= 64, desired.count <= AlertPlan.capacity else { return nil }
        var unmatched = actual
        var added: [UNNotificationRequest] = []
        for request in desired {
            if let index = unmatched.firstIndex(where: { equal($0, request) }) {
                unmatched.remove(at: index)
            } else {
                added.append(request)
            }
        }
        guard !unmatched.isEmpty, added.count <= 1 else { return nil }
        let replacement: UNNotificationRequest
        let alreadyAccepted = added.isEmpty
        if let addition = added.first {
            replacement = addition
        } else {
            // A prior attempt may have accepted the new generation before its
            // verification or old-request removal failed. Retry only that
            // retirement instead of rebuilding unrelated hourly phase groups.
            guard let targetID = unmatched.first.flatMap({ PendingNudge($0.identifier)?.id }) else { return nil }
            let candidates = desired.filter { PendingNudge($0.identifier)?.id == targetID }
            guard candidates.count == 1, let accepted = candidates.first else { return nil }
            replacement = accepted
        }
        guard
              !HourlyNagSchedule.isPhase(replacement), isMinuteRepeat(replacement.trigger),
              let target = PendingNudge(replacement.identifier), target.index == 0,
              desired.filter({ PendingNudge($0.identifier)?.id == target.id }).count == 1 else { return nil }
        let matchingReminders = reminders.filter { $0.id == target.id }
        guard matchingReminders.count == 1, let reminder = matchingReminders.first,
              validReplacement(replacement, reminder: reminder, now: now) else { return nil }

        // Public add/remove operates on identifiers, not individual records.
        // Never let either operation touch an ID shared with a phase or unknown
        // duplicate; in-place content rewrites are outside this fast path.
        let changedIDs = Set(unmatched.map(\.identifier) + [replacement.identifier])
        let phaseIDs = Set((actual + desired).filter(HourlyNagSchedule.isPhase).map(\.identifier))
        let existingReplacements = actual.filter { $0.identifier == replacement.identifier }
        let existingReplacementIsValid = alreadyAccepted
            ? (existingReplacements.count == 1 && equal(existingReplacements[0], replacement))
            : existingReplacements.isEmpty
        guard changedIDs.isDisjoint(with: phaseIDs), existingReplacementIsValid,
              Set(unmatched.map(\.identifier)).count == unmatched.count,
              unmatched.allSatisfy({ request in
                  guard let old = PendingNudge(request.identifier), !HourlyNagSchedule.isPhase(request) else { return false }
                  return old.id == target.id && old.generation != target.generation
                      && actual.filter { $0.identifier == request.identifier }.count == 1
                      && !desired.contains { $0.identifier == request.identifier }
              }) else { return nil }

        // Rapid edits can leave several accepted old generations while newer
        // revisions supersede callbacks. At the OS ceiling only, make one spare
        // slot by retiring redundant TARGET requests, retaining a confirmed
        // pending backup until the new request has been read back exactly.
        let needed = alreadyAccepted ? 0 : max(0, actual.count + 1 - 64)
        guard needed < unmatched.count else { return nil }
        let ordered = unmatched.sorted { lhs, rhs in
            let leftRepeats = lhs.trigger?.repeats == true
            let rightRepeats = rhs.trigger?.repeats == true
            if leftRepeats != rightRepeats { return leftRepeats }
            let leftDate = lhs.content.userInfo[NagDelivery.scheduledKey] as? Double ?? .greatestFiniteMagnitude
            let rightDate = rhs.content.userInfo[NagDelivery.scheduledKey] as? Double ?? .greatestFiniteMagnitude
            if leftDate != rightDate { return leftDate < rightDate }
            return lhs.identifier < rhs.identifier
        }
        // Keep the first (prefer a repeat, otherwise earliest known alert).
        let preflight = Array(ordered.dropFirst().suffix(needed)).map(\.identifier)
        return Plan(original: actual, desired: desired, replacement: replacement,
                    replacementAlreadyAccepted: alreadyAccepted,
                    obsolete: unmatched, preflightRemovals: preflight)
    }

    @MainActor static func apply(_ plan: Plan, center: UNUserNotificationCenter = .current(),
                                 isCurrent: () -> Bool) async throws -> Outcome {
        let operations = Operations(pending: { await center.pendingNotificationRequests() },
                                    add: { try await center.add($0) },
                                    remove: { center.removePendingNotificationRequests(withIdentifiers: $0) })
        return try await apply(plan, operations: operations, isCurrent: isCurrent)
    }

    @MainActor static func apply(_ plan: Plan, operations: Operations,
                                 isCurrent: () -> Bool) async throws -> Outcome {
        guard isCurrent() else { return .superseded }
        let before = await operations.pending()
        guard isCurrent() else { return .superseded }
        guard matches(before, plan.original) else {
            throw changedQueue(stage: "before replacement", actual: before, expected: plan.original)
        }

        var retained = plan.original
        if !plan.preflightRemovals.isEmpty {
            operations.remove(plan.preflightRemovals)
            let removed = Set(plan.preflightRemovals)
            retained.removeAll { removed.contains($0.identifier) }
            guard try await confirm(retained, stage: "after spare-slot cleanup", operations: operations,
                                    isCurrent: isCurrent) else { return .superseded }
        }
        guard isCurrent() else { return .superseded }
        if !plan.replacementAlreadyAccepted {
            guard retained.count + 1 <= 64 else {
                throw Problem(message: "There is no spare notification slot for this reminder's time update.",
                              details: "Stage: before replacement add.")
            }
            do { try await operations.add(plan.replacement) }
            catch {
                let failure = error as NSError
                throw Problem(message: error.localizedDescription,
                              details: "Stage: replacement add. Error: \(failure.domain) (\(failure.code)).")
            }
            guard isCurrent() else { return .superseded }
            // A callback alone does not establish acceptance. Confirm the entire
            // intermediate queue, including all untouched duplicate hourly phases.
            guard try await confirm(retained + [plan.replacement], stage: "after replacement add",
                                    operations: operations, isCurrent: isCurrent) else { return .superseded }
        }
        guard isCurrent() else { return .superseded }
        let alreadyRemoved = Set(plan.preflightRemovals)
        let retire = plan.obsolete.map(\.identifier).filter { !alreadyRemoved.contains($0) }
        if !retire.isEmpty { operations.remove(retire) }
        guard try await confirm(plan.desired, stage: "after old-generation retirement", operations: operations,
                                isCurrent: isCurrent) else { return .superseded }
        return .applied
    }

    @MainActor private static func confirm(_ expected: [UNNotificationRequest], stage: String, operations: Operations,
                                           isCurrent: () -> Bool) async throws -> Bool {
        var lastReadback: [UNNotificationRequest] = []
        for attempt in 0..<6 {
            guard isCurrent() else { return false }
            let actual = await operations.pending()
            guard isCurrent() else { return false }
            lastReadback = actual
            if matches(actual, expected) { return true }
            if attempt < 5 {
                try await Task.sleep(nanoseconds: 50_000_000)
                guard isCurrent() else { return false }
            }
        }
        throw changedQueue(stage: stage, actual: lastReadback, expected: expected)
    }

    private static func changedQueue(stage: String, actual: [UNNotificationRequest], expected: [UNNotificationRequest]) -> Problem {
        let details = HourlyNagSchedule.mismatchDescription(actual: actual, expected: expected) ?? "No mismatch remains."
        return Problem(message: "iPhone could not confirm this reminder's time update. Keep the app open to retry; other reminders were not deliberately changed.",
                       details: "Stage: \(stage).\n\(details)")
    }

    private static func validReplacement(_ request: UNNotificationRequest, reminder: Reminder, now: Date) -> Bool {
        guard let target = PendingNudge(request.identifier), target.id == reminder.id, target.index == 0,
              reminder.generation == target.generation, reminder.completedAt == nil,
              reminder.preferences.notifications, reminder.preferences.nagMinutes == 1,
              reminder.hasValidSchedule, now.timeIntervalSince1970.isFinite,
              request.content.userInfo["id"] as? String == target.id.uuidString,
              request.content.userInfo["generation"] as? String == target.generation.uuidString,
              request.content.userInfo[NagDelivery.versionKey] as? Int == NagDelivery.payloadVersion,
              request.content.userInfo[NagDelivery.soundOnlyKey] as? Bool == false,
              request.content.userInfo[NagDelivery.titleKey] as? String == reminder.title,
              request.content.title == reminder.title, request.content.body == reminder.notes,
              request.content.categoryIdentifier == NotificationRequestFactory.category,
              request.content.threadIdentifier == reminder.id.uuidString,
              let stamp = request.content.userInfo[NagDelivery.scheduledKey] as? Double, stamp.isFinite else { return false }
        let due = reminder.alertDate.timeIntervalSince1970
        let offset = stamp - due
        // A past-due reminder can start at a later minute on its original grid.
        // An accepted request must not silently postpone a future reminder, or
        // claim an arbitrary distant point on that grid as its initial alert.
        guard offset >= -0.001,
              abs(offset - (offset / 60).rounded() * 60) < 0.001,
              stamp <= max(due, now.timeIntervalSince1970 + 60) + 0.001 else { return false }
        let alert = ScheduledAlert(reminder: reminder, index: 0, date: Date(timeIntervalSince1970: stamp), repeatsEveryMinute: true)
        let expectedContent = NotificationRequestFactory.make(for: alert, soundOnlyEnabled: false,
                                                              triggerOverride: request.trigger).content
        guard (request.content.sound == nil && expectedContent.sound == nil)
                || request.content.sound?.isEqual(expectedContent.sound) == true else { return false }
        #if os(iOS)
        guard let trigger = request.trigger, isMinuteRepeat(trigger),
              let date = legacyDate(trigger), abs(date.timeIntervalSince1970 - stamp) < 0.001,
              let expectedTrigger = NotificationRequestFactory.minuteRepeatTrigger(firstFire: date),
              trigger.isEqual(expectedTrigger) else { return false }
        #else
        // macOS tests use a public minute interval as a fixture. It has no
        // absolute first-date property, so its payload supplies that anchor.
        guard let trigger = request.trigger as? UNTimeIntervalNotificationTrigger,
              trigger.repeats, trigger.timeInterval == 60 else { return false }
        #endif
        return true
    }

    #if os(iOS)
    private static func legacyDate(_ trigger: UNNotificationTrigger) -> Date? {
        guard let type = NSClassFromString("UNLegacyNotificationTrigger"), trigger.isKind(of: type),
              let cls = object_getClass(trigger),
              let method = class_getInstanceMethod(cls, NSSelectorFromString("date")),
              method_getNumberOfArguments(method) == 2 else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        let getter = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        return (getter(trigger, NSSelectorFromString("date"))?.takeUnretainedValue() as? NSDate) as Date?
    }
    #endif

    private static func equal(_ lhs: UNNotificationRequest, _ rhs: UNNotificationRequest) -> Bool {
        lhs.identifier == rhs.identifier && NotificationContentEquivalence.equal(lhs.content, rhs.content)
            && ((lhs.trigger == nil && rhs.trigger == nil) || lhs.trigger?.isEqual(rhs.trigger) == true)
    }

    private static func matches(_ actual: [UNNotificationRequest], _ desired: [UNNotificationRequest]) -> Bool {
        HourlyNagSchedule.matches(actual, desired)
    }

    private static func isMinuteRepeat(_ trigger: UNNotificationTrigger?) -> Bool {
        guard let trigger, trigger.repeats else { return false }
        // Also permits the ordinary sixty-second repeat used by macOS checks.
        if let interval = trigger as? UNTimeIntervalNotificationTrigger { return interval.timeInterval == 60 }
        #if canImport(ObjectiveC)
        guard let type = NSClassFromString("UNLegacyNotificationTrigger"), trigger.isKind(of: type),
              let cls = object_getClass(trigger),
              let method = class_getInstanceMethod(cls, NSSelectorFromString("repeatInterval")),
              method_getNumberOfArguments(method) == 2 else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> UInt64
        let getter = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        return getter(trigger, NSSelectorFromString("repeatInterval")) == UInt64(NSCalendar.Unit.minute.rawValue)
        #else
        return false
        #endif
    }
}
