import Foundation
import UserNotifications

// File name and persisted phase keys are retained for compatibility with 1.1.10.
struct HourlyNagCadence: Equatable {
    let minutes: Int
    init?(minutes: Int) {
        guard [5, 10, 15, 30].contains(minutes) else { return nil }
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
                $0.identifier == request.identifier && $0.content.isEqual(request.content) &&
                    (($0.trigger == nil && request.trigger == nil) || $0.trigger?.isEqual(request.trigger) == true)
            }) else { return false }
            remaining.remove(at: index)
        }
        return remaining.isEmpty
    }
    static func isPhase(_ request: UNNotificationRequest) -> Bool { request.content.userInfo[phaseKey] != nil }
}
