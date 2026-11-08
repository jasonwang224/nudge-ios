import Foundation

enum NagDelivery {
    static let soundOnlyKey = "nudgeSoundOnly"
    static let scheduledKey = "nudgeScheduledAt"
    static let titleKey = "nudgeReminderTitle"
    static let versionKey = "nudgePayloadVersion"
    static let payloadVersion = 2

    // The device experiment failed. Ignore its previously saved ON preference;
    // reconciliation restores full-content nags before the app closes.
    static let enabled = false

    static func isSoundOnly(_ alert: ScheduledAlert, enabled: Bool) -> Bool {
        guard enabled, alert.reminder.preferences.sound != .silent,
              alert.reminder.soundOnlyAnchorAccepted == true,
              let anchor = alert.reminder.soundOnlyAfterIndex else { return false }
        return alert.index > anchor
    }

    // Older database records have no anchor. Keep their visible nags until a
    // deliberate save/Snooze creates a generation with a new visible alert.
    static func prepare(_ changed: ReminderSnapshot, replacing previous: ReminderSnapshot,
                        now: Date) -> ReminderSnapshot {
        let generations = Dictionary(uniqueKeysWithValues: previous.reminders.map { ($0.id, $0.generation) })
        var result = changed
        for index in result.reminders.indices {
            let reminder = result.reminders[index]
            guard reminder.completedAt == nil, generations[reminder.id] != reminder.generation else { continue }
            result.reminders[index].soundOnlyAfterIndex = AlertPlan(reminders: [reminder], now: now, capacity: 1)
                .alerts.first?.index
            result.reminders[index].soundOnlyAnchorAccepted = false
        }
        return result
    }

    // Only called after iOS accepts a visible request, or reads it back. If the
    // proposed first alert was missed before permission/queuing, the first actual
    // accepted alert becomes the anchor. Its successors may then be sound-only.
    static func acceptingVisibleAnchor(identifier: String, in snapshot: ReminderSnapshot) -> ReminderSnapshot? {
        guard let request = PendingNudge(identifier),
              let index = snapshot.reminders.firstIndex(where: {
                  $0.id == request.id && $0.generation == request.generation
                      && $0.completedAt == nil && $0.soundOnlyAnchorAccepted == false
              }) else { return nil }
        var result = snapshot
        result.reminders[index].soundOnlyAfterIndex = request.index
        result.reminders[index].soundOnlyAnchorAccepted = true
        return result
    }

    // Rebuild only owned, active, current-generation requests from their original
    // absolute time. Reusing a fetched interval trigger would restart its delay.
    static func rewritableAlerts(pending: [PendingNudge], reminders: [Reminder], now: Date) -> [ScheduledAlert] {
        let current = Dictionary(uniqueKeysWithValues: reminders.map { ($0.id, $0) })
        return pending.compactMap { request -> ScheduledAlert? in
            guard let reminder = current[request.id], reminder.generation == request.generation,
                  reminder.completedAt == nil, reminder.preferences.notifications, reminder.hasValidSchedule,
                  request.index == 0 || reminder.preferences.nagMinutes > 0 else { return nil }
            let date = reminder.alertDate.addingTimeInterval(Double(request.index) * Double(reminder.preferences.nagMinutes) * 60)
            guard date.timeIntervalSince(now) > 5, abs(date.timeIntervalSinceReferenceDate) < 100_000_000_000 else { return nil }
            return ScheduledAlert(reminder: reminder, index: request.index, date: date)
        }.sorted { $0.date < $1.date }
    }
}
