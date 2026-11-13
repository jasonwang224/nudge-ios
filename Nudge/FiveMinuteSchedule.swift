import Foundation
import UserNotifications

// Pure allocation: reserve a first alert for every active reminder before spending
// eleven additional slots on a continuous five-minute group. Never emit partial groups.
struct FiveMinuteAllocation {
    var repeatingIDs: Set<UUID> = []
    var fallbackCount = 0
    init(reminders: [Reminder], now: Date, capacity: Int, existingIDs: Set<UUID>) {
        let primary = reminders.compactMap { AlertPlan(reminders: [$0], now: now, capacity: 1).alerts.first }
        let candidates = primary.filter { $0.reminder.preferences.nagMinutes == 5 }.sorted {
            if existingIDs.contains($0.reminder.id) != existingIDs.contains($1.reminder.id) { return existingIDs.contains($0.reminder.id) }
            return $0.date == $1.date ? $0.identifier < $1.identifier : $0.date < $1.date
        }
        var extra = max(0, capacity - primary.count)
        for alert in candidates {
            if extra >= 11 { repeatingIDs.insert(alert.reminder.id); extra -= 11 }
            else { fallbackCount += 1 }
        }
    }
}

enum FiveMinuteSchedule {
    static let phaseKey = "nudgeFiveMinutePhase"
    static let anchorKey = "nudgeFiveMinuteAnchor"
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
