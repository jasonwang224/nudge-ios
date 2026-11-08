import Foundation

enum ExpirationExperiment {
    static let preferenceKey = "Nudge.expirationExperiment.v1"
    static let requestedKey = "nudgeExpiryRequestedAt"
    static let successorKey = "nudgeExpirySuccessor"
    static let scheduledKey = "nudgeScheduledAt"

    static var enabled: Bool {
        get { (UserDefaults.standard.object(forKey: preferenceKey) as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: preferenceKey) }
    }
}

struct ExpirationCandidate {
    let alert: ScheduledAlert
    let successor: ScheduledAlert?

    // Only actually accepted requests are input. No expiry on the final alert,
    // on a gap, on another reminder, or across an edited/snoozed generation.
    static func make(pending: [PendingNudge], reminders: [Reminder], now: Date) -> [Self] {
        let current = Dictionary(uniqueKeysWithValues: reminders.map { ($0.id, $0) })
        let alerts = pending.compactMap { request -> ScheduledAlert? in
            guard let reminder = current[request.id], reminder.generation == request.generation,
                  reminder.completedAt == nil, reminder.preferences.notifications,
                  reminder.hasValidSchedule,
                  request.index == 0 || reminder.preferences.nagMinutes > 0 else { return nil }
            let date = reminder.alertDate.addingTimeInterval(Double(request.index) * Double(reminder.preferences.nagMinutes) * 60)
            guard date.timeIntervalSince(now) > 5, abs(date.timeIntervalSinceReferenceDate) < 100_000_000_000 else { return nil }
            return ScheduledAlert(reminder: reminder, index: request.index, date: date)
        }
        let byID = Dictionary(uniqueKeysWithValues: alerts.map { ($0.identifier, $0) })
        return alerts.sorted { $0.date < $1.date }.map { alert in
            let nextID = alert.index < Int.max
                ? ScheduledAlert(reminder: alert.reminder, index: alert.index + 1, date: alert.date).identifier : ""
            let next = byID[nextID].flatMap { $0.date > alert.date ? $0 : nil }
            return Self(alert: alert, successor: next)
        }
    }
}
