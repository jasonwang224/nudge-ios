import Foundation
import SwiftUI
import UserNotifications

@MainActor
final class ReminderStore: ObservableObject {
    static let shared = ReminderStore()
    static let category = "NUDGE_REMINDER"
    static let doneAction = "NUDGE_DONE"
    static let snoozeAction = "NUDGE_SNOOZE"

    @Published private(set) var reminders: [Reminder]
    @Published var defaults: ReminderPreferences {
        didSet { persist(defaults, key: Self.defaultsKey) }
    }
    @Published private(set) var status = "Checking notification access…"
    @Published private(set) var needsSettings = false
    @Published private(set) var isScheduling = false

    private static let remindersKey = "Nudge.reminders.v1"
    private static let defaultsKey = "Nudge.defaults.v1"
    private let center = UNUserNotificationCenter.current()
    private var syncTask: Task<Void, Never>?
    private var syncRevision = 0

    private init() {
        let disk = UserDefaults.standard
        let decoder = JSONDecoder()
        reminders = disk.data(forKey: Self.remindersKey)
            .flatMap { try? decoder.decode([Reminder].self, from: $0) } ?? []
        defaults = disk.data(forKey: Self.defaultsKey)
            .flatMap { try? decoder.decode(ReminderPreferences.self, from: $0) } ?? ReminderPreferences()
    }

    func save(_ reminder: Reminder) {
        var saved = reminder
        saved.generation = UUID()
        if let index = reminders.firstIndex(where: { $0.id == saved.id }) {
            let previous = reminders[index]
            if previous.due != saved.due || previous.phoneSchedule != saved.phoneSchedule {
                saved.repeatAnchor = saved.due
                saved.snoozedUntil = nil
            }
            clearNotifications(for: previous)
            reminders[index] = saved
        } else {
            reminders.append(saved)
        }
        saveReminders()
        enqueueSync(askPermission: saved.preferences.notifications)
    }

    func scheduleTest() {
        enqueueSync(askPermission: true)
        let permissionCheck = syncTask
        Task {
            await permissionCheck?.value
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized, settings.lockScreenSetting == .enabled else { return }
            let due = Date().addingTimeInterval(30)
            var preferences = defaults
            preferences.notifications = true
            preferences.nagMinutes = 2
            preferences.repeatRule = .never
            save(Reminder(title: "Lock Screen test", notes: "Hold this notification to try Snooze 15 min or Done.",
                          due: due, repeatAnchor: due, preferences: preferences))
        }
    }

    func delete(_ reminder: Reminder) {
        guard let stored = reminders.first(where: { $0.id == reminder.id }) else { return }
        clearNotifications(for: stored)
        reminders.removeAll { $0.id == reminder.id }
        saveReminders()
        enqueueSync()
    }

    func done(_ reminder: Reminder, now: Date = .now) {
        guard let index = currentIndex(reminder.id, generation: reminder.generation) else { return }
        clearNotifications(for: reminders[index])
        reminders[index].generation = UUID()
        reminders[index].snoozedUntil = nil
        if let next = reminders[index].nextOccurrence(after: now) {
            var occurrence = reminders[index]
            occurrence.id = UUID()
            occurrence.completedAt = now
            reminders[index].due = next
            reminders[index].phoneSchedule?.day = Calendar.autoupdatingCurrent.dateComponents(
                [.era, .year, .month, .day], from: next
            )
            reminders.append(occurrence)
        } else {
            reminders[index].completedAt = now
        }
        saveReminders()
        enqueueSync()
    }

    func restore(_ reminder: Reminder) {
        guard var saved = reminders.first(where: { $0.id == reminder.id && $0.completedAt != nil }) else { return }
        saved.completedAt = nil
        saved.snoozedUntil = nil
        // A completed occurrence is separate from the active recurring series.
        saved.preferences.repeatRule = .never
        save(saved)
    }

    func snooze(_ reminder: Reminder, now: Date = .now) {
        guard let index = currentIndex(reminder.id, generation: reminder.generation) else { return }
        clearNotifications(for: reminders[index])
        reminders[index].generation = UUID()
        reminders[index].snoozedUntil = now.addingTimeInterval(15 * 60)
        saveReminders()
        enqueueSync()
    }

    func handleAction(_ action: String, id: String, generation: String, at time: Date) async {
        guard let id = UUID(uuidString: id), let generation = UUID(uuidString: generation),
              let index = currentIndex(id, generation: generation) else { return }
        switch action {
        case Self.doneAction: done(reminders[index], now: time)
        case Self.snoozeAction: snooze(reminders[index], now: time)
        default: return
        }
        await syncTask?.value
    }

    func refresh() {
        let calendar = Calendar.autoupdatingCurrent
        var adjusted = reminders
        for index in adjusted.indices where adjusted[index].completedAt == nil {
            guard let due = adjusted[index].phoneSchedule?.dueDate(calendar: calendar),
                  adjusted[index].due != due else { continue }
            if adjusted[index].snoozedUntil == nil {
                clearNotifications(for: adjusted[index])
                adjusted[index].generation = UUID()
            }
            adjusted[index].due = due
        }
        if adjusted != reminders {
            reminders = adjusted
            saveReminders()
        }
        enqueueSync()
    }

    private func currentIndex(_ id: UUID, generation: UUID) -> Int? {
        reminders.firstIndex { $0.id == id && $0.generation == generation && $0.completedAt == nil }
    }

    private func clearNotifications(for reminder: Reminder) {
        let prefix = "\(ScheduledAlert.prefix)\(reminder.id.uuidString).\(reminder.generation.uuidString)."
        // Reconciliation removes the obsolete pending requests. Clear the visible stack too.
        center.getDeliveredNotifications { [center] delivered in
            let ids = delivered.map { $0.request.identifier }.filter { $0.hasPrefix(prefix) }
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    private func saveReminders() {
        persist(reminders, key: Self.remindersKey)
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            status = "Nudge could not save your changes."
        }
    }

    private func enqueueSync(askPermission: Bool = false) {
        let prior = syncTask
        syncRevision += 1
        let revision = syncRevision
        isScheduling = true
        syncTask = Task { [weak self] in
            await prior?.value
            guard let self else { return }
            await self.reconcile(askPermission: askPermission, revision: revision)
            if revision == self.syncRevision { self.isScheduling = false }
        }
    }

    private func reconcile(askPermission: Bool, revision: Int) async {
        var settings = await center.notificationSettings()
        if askPermission && settings.authorizationStatus == .notDetermined {
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
                settings = await center.notificationSettings()
            } catch {
                status = "iPhone could not request notification access."
                return
            }
        }
        guard revision == syncRevision else { return }

        let authorized = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional || settings.authorizationStatus == .ephemeral
        let lockScreenEnabled = settings.lockScreenSetting == .enabled
        needsSettings = settings.authorizationStatus == .denied || (authorized && !lockScreenEnabled)
        let pending = await center.pendingNotificationRequests()
        guard revision == syncRevision else { return }
        let owned = pending.map(\.identifier).filter { $0.hasPrefix(ScheduledAlert.prefix) }
        guard authorized else {
            center.removePendingNotificationRequests(withIdentifiers: owned)
            status = "Allow notifications to receive reminders on the Lock Screen."
            return
        }

        let plan = AlertPlan(reminders: reminders, now: .now)
        let desired = Set(plan.alerts.map(\.identifier))
        center.removePendingNotificationRequests(withIdentifiers: owned.filter { !desired.contains($0) })
        let retained = Set(owned).intersection(desired)
        var failures = 0
        for alert in plan.alerts where !retained.contains(alert.identifier) {
            guard revision == syncRevision else { return }
            do {
                try await center.add(request(for: alert))
            } catch {
                failures += 1
            }
        }
        guard revision == syncRevision else { return }
        if !lockScreenEnabled {
            status = "Turn on Lock Screen alerts for Nudge in iPhone Settings."
        } else if failures > 0 || plan.unscheduledFirstAlerts > 0 {
            status = "Some alerts could not be queued. Check your reminders before closing Nudge."
        } else if settings.scheduledDeliverySetting == .enabled {
            status = "Alerts are queued. Choose immediate delivery in iPhone Settings for on-time tests."
        } else {
            status = "\(plan.alerts.count) alerts queued with iOS."
        }
    }

    private func request(for alert: ScheduledAlert) -> UNNotificationRequest {
        let reminder = alert.reminder
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.notes.isEmpty ? "Hold for Done or Snooze 15 min." : reminder.notes
        content.categoryIdentifier = Self.category
        content.threadIdentifier = reminder.id.uuidString
        content.userInfo = ["id": reminder.id.uuidString, "generation": reminder.generation.uuidString]
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
                trigger = intervalTrigger(for: alert.date)
            }
        } else {
            trigger = intervalTrigger(for: alert.date)
        }
        return UNNotificationRequest(identifier: alert.identifier, content: content, trigger: trigger)
    }

    private func intervalTrigger(for date: Date) -> UNTimeIntervalNotificationTrigger {
        UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
    }
}
