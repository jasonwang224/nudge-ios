import Foundation
import UserNotifications

// File name and persisted phase keys are retained for compatibility with 1.1.10.
struct HourlyNagCadence: Equatable {
    let minutes: Int
    init?(minutes: Int) {
        guard [2, 5, 10, 15, 20, 30].contains(minutes) else { return nil }
        self.minutes = minutes
    }
    var phaseCount: Int { 60 / minutes }
    func phaseDates(first: Date) -> [Date] {
        (0..<phaseCount).map { first.addingTimeInterval(Double($0 * minutes * 60)) }
    }
}

// Reserve a first alert for every active reminder, then allocate whole groups.
// Different intervals require different numbers of real pending records.
struct HourlyNagAllocation {
    var repeatingIDs: Set<UUID> = []
    var phaseSlots = 0
    var fallbackCount = 0
    init(reminders: [Reminder], now: Date, capacity: Int, existingIDs: Set<UUID>) {
        let primary = reminders.compactMap { AlertPlan(reminders: [$0], now: now, capacity: 1).alerts.first }
        let candidates = primary.filter { HourlyNagCadence(minutes: $0.reminder.preferences.nagMinutes) != nil }.sorted {
            if existingIDs.contains($0.reminder.id) != existingIDs.contains($1.reminder.id) { return existingIDs.contains($0.reminder.id) }
            return $0.date == $1.date ? $0.identifier < $1.identifier : $0.date < $1.date
        }
        var extra = max(0, capacity - primary.count)
        for alert in candidates {
            guard let cadence = HourlyNagCadence(minutes: alert.reminder.preferences.nagMinutes) else { continue }
            let needed = cadence.phaseCount - 1
            if extra >= needed {
                repeatingIDs.insert(alert.reminder.id)
                extra -= needed
                phaseSlots += cadence.phaseCount
            }
            else { fallbackCount += 1 }
        }
    }
}

enum HourlyNagSchedule {
    // Do not rename these keys: accepted five-minute groups and recovery files
    // from 1.1.10 must be recognized without rebuilding or resetting their timing.
    static let phaseKey = "nudgeFiveMinutePhase"
    static let anchorKey = "nudgeFiveMinuteAnchor"
    static let minutesKey = "nudgeHourlyNagMinutes"
    static func recordedMinutes(_ content: UNNotificationContent) -> Int? {
        if let raw = content.userInfo[minutesKey] { return raw as? Int }
        return isPhaseContent(content) ? 5 : nil
    }
    private static func isPhaseContent(_ content: UNNotificationContent) -> Bool { content.userInfo[phaseKey] != nil }
    static func matches(_ actual: [UNNotificationRequest], _ expected: [UNNotificationRequest]) -> Bool {
        guard actual.count == expected.count else { return false }
        var remaining = actual
        for request in expected {
            guard let index = remaining.firstIndex(where: {
                $0.identifier == request.identifier && NotificationContentEquivalence.equal($0.content, request.content) &&
                    (($0.trigger == nil && request.trigger == nil) || $0.trigger?.isEqual(request.trigger) == true)
            }) else { return false }
            remaining.remove(at: index)
        }
        return remaining.isEmpty
    }

    struct ChangedRecord {
        let record: String
        let contentFields: [String]
        let triggerChanged: Bool
    }

    struct Mismatch {
        let expectedCount: Int
        let actualCount: Int
        let exactMatchCount: Int
        let missing: [String]
        let extra: [String]
        let changed: [ChangedRecord]

        var description: String {
            var lines = ["Expected \(expectedCount) pending records; read back \(actualCount). Verified matches: \(exactMatchCount).",
                         "Missing: \(missing.count). Extra: \(extra.count). Changed: \(changed.count)."]
            lines += missing.map { "MISSING · \($0)" }
            lines += extra.map { "EXTRA · \($0)" }
            lines += changed.map { item in
                var fields = item.contentFields.map { "content.\($0)" }
                if item.triggerChanged { fields.append("trigger") }
                return "CHANGED · \(item.record) · \(fields.joined(separator: ", "))"
            }
            return lines.joined(separator: "\n")
        }
    }

    // Diagnostics use the same strict comparison and empty-text normalization as acceptance.
    // Consume verified matches first, including repeated identifiers, before pairing
    // changed records by identifier + phase. A missing phase is never hidden by
    // an extra copy of a different phase with the same request identifier.
    static func mismatch(_ actual: [UNNotificationRequest], _ expected: [UNNotificationRequest]) -> Mismatch? {
        var remaining = actual
        var unmatched: [UNNotificationRequest] = []
        for request in expected {
            if let index = remaining.firstIndex(where: {
                $0.identifier == request.identifier && NotificationContentEquivalence.equal($0.content, request.content) &&
                    triggersEqual($0.trigger, request.trigger)
            }) {
                remaining.remove(at: index)
            } else { unmatched.append(request) }
        }
        guard !unmatched.isEmpty || !remaining.isEmpty else { return nil }
        let exactMatchCount = expected.count - unmatched.count
        var missing: [String] = []
        var changed: [ChangedRecord] = []
        for request in unmatched {
            let candidates = remaining.indices.filter { sameDiagnosticIdentity(remaining[$0], request) }
            let index = candidates.first(where: { NotificationContentEquivalence.equal(remaining[$0].content, request.content) })
                ?? candidates.first(where: { triggersEqual(remaining[$0].trigger, request.trigger) })
                ?? candidates.first
            guard let index else { missing.append(recordLabel(request)); continue }
            let received = remaining.remove(at: index)
            changed.append(ChangedRecord(record: recordLabel(request),
                                         contentFields: changedContentFields(received.content, request.content),
                                         triggerChanged: !triggersEqual(received.trigger, request.trigger)))
        }
        return Mismatch(expectedCount: expected.count, actualCount: actual.count, exactMatchCount: exactMatchCount,
                        missing: missing, extra: remaining.map(recordLabel), changed: changed)
    }

    static func mismatchDescription(actual: [UNNotificationRequest], expected: [UNNotificationRequest]) -> String? {
        mismatch(actual, expected)?.description
    }

    private static func triggersEqual(_ lhs: UNNotificationTrigger?, _ rhs: UNNotificationTrigger?) -> Bool {
        (lhs == nil && rhs == nil) || lhs?.isEqual(rhs) == true
    }

    private static func sameDiagnosticIdentity(_ lhs: UNNotificationRequest, _ rhs: UNNotificationRequest) -> Bool {
        guard lhs.identifier == rhs.identifier else { return false }
        let a = lhs.content.userInfo[phaseKey], b = rhs.content.userInfo[phaseKey]
        if a == nil && b == nil { return true }
        guard let a = a as? Int, let b = b as? Int else { return false }
        return a == b
    }

    private static func recordLabel(_ request: UNNotificationRequest) -> String {
        if let phase = request.content.userInfo[phaseKey] as? Int {
            return "\(request.identifier) · phase \(phase)"
        }
        return request.identifier + (isPhase(request) ? " · invalid phase metadata" : " · single request")
    }

    private static func changedContentFields(_ actual: UNNotificationContent, _ expected: UNNotificationContent) -> [String] {
        guard !NotificationContentEquivalence.equal(actual, expected) else { return [] }
        var fields: [String] = []
        if actual.title != expected.title { fields.append("title") }
        if actual.subtitle != expected.subtitle { fields.append("subtitle") }
        if actual.body != expected.body { fields.append("body") }
        if actual.categoryIdentifier != expected.categoryIdentifier { fields.append("categoryIdentifier") }
        if actual.threadIdentifier != expected.threadIdentifier { fields.append("threadIdentifier") }
        if actual.badge != expected.badge { fields.append("badge") }
        if !((actual.sound == nil && expected.sound == nil) || actual.sound?.isEqual(expected.sound) == true) { fields.append("sound") }
        if !NSDictionary(dictionary: actual.userInfo).isEqual(to: expected.userInfo) { fields.append("userInfo") }
        if actual.interruptionLevel != expected.interruptionLevel { fields.append("interruptionLevel") }
        if actual.relevanceScore != expected.relevanceScore { fields.append("relevanceScore") }
        // OS-private/default properties also participate in isEqual. Report an
        // unexplained content difference instead of silently accepting it.
        return fields.isEmpty ? ["other properties"] : fields
    }
    static func isPhase(_ request: UNNotificationRequest) -> Bool { request.content.userInfo[phaseKey] != nil }
}
