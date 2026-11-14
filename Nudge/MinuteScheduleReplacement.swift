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
        let obsolete: [UNNotificationRequest]
        let preflightRemovals: [String]
    }

    enum Outcome: Equatable { case applied, superseded }

    struct Problem: LocalizedError {
        let message: String
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
                     reminders: [Reminder]) -> Plan? {
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
        guard added.count == 1, let replacement = added.first,
              !HourlyNagSchedule.isPhase(replacement), isMinuteRepeat(replacement.trigger),
              let target = PendingNudge(replacement.identifier), target.index == 0,
              !unmatched.isEmpty else { return nil }
        let matchingReminders = reminders.filter { $0.id == target.id }
        guard matchingReminders.count == 1, let reminder = matchingReminders.first,
              reminder.generation == target.generation, reminder.completedAt == nil,
              reminder.preferences.notifications, reminder.preferences.nagMinutes == 1,
              reminder.hasValidSchedule,
              replacement.content.userInfo["id"] as? String == target.id.uuidString,
              replacement.content.userInfo["generation"] as? String == target.generation.uuidString,
              replacement.content.title == reminder.title,
              replacement.content.body == reminder.notes else { return nil }

        // Public add/remove operates on identifiers, not individual records.
        // Never let either operation touch an ID shared with a phase or unknown
        // duplicate; in-place content rewrites are outside this fast path.
        let changedIDs = Set(unmatched.map(\.identifier) + [replacement.identifier])
        let phaseIDs = Set((actual + desired).filter(HourlyNagSchedule.isPhase).map(\.identifier))
        guard changedIDs.isDisjoint(with: phaseIDs),
              !actual.contains(where: { $0.identifier == replacement.identifier }),
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
        let needed = max(0, actual.count + 1 - 64)
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
        guard matches(before, plan.original) else { throw changedQueue() }

        var retained = plan.original
        if !plan.preflightRemovals.isEmpty {
            operations.remove(plan.preflightRemovals)
            let removed = Set(plan.preflightRemovals)
            retained.removeAll { removed.contains($0.identifier) }
            guard try await confirm(retained, operations: operations, isCurrent: isCurrent) else { return .superseded }
        }
        guard isCurrent() else { return .superseded }
        guard retained.count + 1 <= 64 else { throw changedQueue() }
        try await operations.add(plan.replacement)
        guard isCurrent() else { return .superseded }
        // A callback alone does not establish acceptance. Confirm the entire
        // intermediate queue, including all untouched duplicate hourly phases.
        guard try await confirm(retained + [plan.replacement], operations: operations, isCurrent: isCurrent) else { return .superseded }
        guard isCurrent() else { return .superseded }
        let alreadyRemoved = Set(plan.preflightRemovals)
        let retire = plan.obsolete.map(\.identifier).filter { !alreadyRemoved.contains($0) }
        if !retire.isEmpty { operations.remove(retire) }
        guard try await confirm(plan.desired, operations: operations, isCurrent: isCurrent) else { return .superseded }
        return .applied
    }

    @MainActor private static func confirm(_ expected: [UNNotificationRequest], operations: Operations,
                                           isCurrent: () -> Bool) async throws -> Bool {
        for attempt in 0..<6 {
            guard isCurrent() else { return false }
            let actual = await operations.pending()
            guard isCurrent() else { return false }
            if matches(actual, expected) { return true }
            if attempt < 5 {
                try await Task.sleep(nanoseconds: 50_000_000)
                guard isCurrent() else { return false }
            }
        }
        throw changedQueue()
    }

    private static func changedQueue() -> Problem {
        Problem(message: "iPhone could not confirm this reminder's time update. Keep the app open to retry; other reminders were not deliberately changed.")
    }

    private static func equal(_ lhs: UNNotificationRequest, _ rhs: UNNotificationRequest) -> Bool {
        lhs.identifier == rhs.identifier && lhs.content.isEqual(rhs.content)
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
