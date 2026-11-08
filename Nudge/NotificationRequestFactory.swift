import Foundation
import UserNotifications

enum NotificationRequestFactory {
    static let category = "NUDGE_REMINDER"

    static func make(for alert: ScheduledAlert, soundOnlyEnabled: Bool, now: Date = .now) -> UNNotificationRequest {
        let reminder = alert.reminder
        let soundOnly = NagDelivery.isSoundOnly(alert, enabled: soundOnlyEnabled)
        let content = UNMutableNotificationContent()
        if !soundOnly {
            content.title = reminder.title
            content.body = reminder.notes.isEmpty ? "Hold for Done or Snooze 15 min." : reminder.notes
            content.categoryIdentifier = category
            content.threadIdentifier = reminder.id.uuidString
        }
        content.userInfo = ["id": reminder.id.uuidString, "generation": reminder.generation.uuidString,
                            NagDelivery.scheduledKey: alert.date.timeIntervalSince1970,
                            NagDelivery.soundOnlyKey: soundOnly, NagDelivery.titleKey: reminder.title,
                            NagDelivery.versionKey: NagDelivery.payloadVersion]
        if reminder.preferences.sound == .system {
            content.sound = .default
        } else if let name = reminder.preferences.sound.fileName {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: name))
        }
        let trigger: UNNotificationTrigger
        if alert.index == 0 && reminder.phoneSchedule != nil && reminder.snoozedUntil == nil {
            let parts = Calendar.autoupdatingCurrent.dateComponents(
                [.era, .year, .month, .day, .hour, .minute, .second], from: alert.date
            )
            let calendarTrigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            if let next = calendarTrigger.nextTriggerDate(), abs(next.timeIntervalSince(alert.date)) < 1 {
                trigger = calendarTrigger
            } else {
                trigger = intervalTrigger(for: alert.date, now: now)
            }
        } else {
            trigger = intervalTrigger(for: alert.date, now: now)
        }
        return UNNotificationRequest(identifier: alert.identifier, content: content, trigger: trigger)
    }

    static func isSoundOnly(_ content: UNNotificationContent) -> Bool {
        content.userInfo[NagDelivery.soundOnlyKey] as? Bool == true
    }

    static func visibleNudge(_ notification: UNNotification) -> DeliveredNudge? {
        visibleNudge(identifier: notification.request.identifier, content: notification.request.content, date: notification.date)
    }

    static func visibleNudge(identifier: String, content: UNNotificationContent, date: Date) -> DeliveredNudge? {
        guard !isSoundOnly(content), !content.title.isEmpty || !content.body.isEmpty || !content.subtitle.isEmpty else { return nil }
        return DeliveredNudge(identifier: identifier, date: date)
    }

    static func needsRewrite(_ request: UNNotificationRequest, for alert: ScheduledAlert, enabled: Bool) -> Bool {
        // A system calendar change can reinterpret an existing calendar trigger
        // while the saved reminder's absolute date and identifier stay the same.
        // Reconcile that request in place when Nudge next refreshes. Interval
        // triggers are excluded: querying their next date can restart the delay.
        if let calendarTrigger = request.trigger as? UNCalendarNotificationTrigger {
            guard let next = calendarTrigger.nextTriggerDate(),
                  abs(next.timeIntervalSince(alert.date)) < 1 else { return true }
        }
        return request.content.userInfo[NagDelivery.versionKey] as? Int != NagDelivery.payloadVersion
            || isSoundOnly(request.content) != NagDelivery.isSoundOnly(alert, enabled: enabled)
    }

    private static func intervalTrigger(for date: Date, now: Date) -> UNTimeIntervalNotificationTrigger {
        UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSince(now)), repeats: false)
    }
}
