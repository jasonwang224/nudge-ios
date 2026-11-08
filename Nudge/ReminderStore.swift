import Foundation
import SwiftUI
import UIKit
import UserNotifications

@MainActor
final class ReminderStore: ObservableObject {
    static let shared = ReminderStore()
    static let category = "NUDGE_REMINDER"
    static let doneAction = "NUDGE_DONE"
    static let snoozeAction = "NUDGE_SNOOZE"

    @Published private(set) var reminders: [Reminder] = []
    @Published var defaults: ReminderPreferences {
        didSet { persist(defaults, key: Self.defaultsKey) }
    }
    @Published private(set) var status = "Checking notification access…"
    @Published private(set) var needsSettings = false
    @Published private(set) var isScheduling = false
    @Published private(set) var storageIssue: String?
    @Published private(set) var expirationEnabled = ExpirationExperiment.enabled
    @Published private(set) var expirationStatus = "Experimental expiration is awaiting a queue check."
    @Published private(set) var notificationDiagnostics = "Refresh after a test to read the notifications still held by iOS."

    static let storageUnavailable = "Nudge couldn’t open your saved reminders. Your data and queued alerts were left untouched."
    private static let defaultsKey = "Nudge.defaults.v1"
    private let center = UNUserNotificationCenter.current()
    private let database: ReminderDatabase
    private var source: ReminderDatabase.Source?
    private var snapshot = ReminderSnapshot()
    private var verifiedEmpty = false
    private var syncTask: Task<Void, Never>?
    private var syncRevision = 0
    private var permissionRequestedByUser = false

    private init() {
        let disk = UserDefaults.standard
        database = ReminderDatabase(url: URL.applicationSupportDirectory.appending(path: "Nudge/Reminders-v1.json"),
                                    preferences: disk)
        defaults = disk.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(ReminderPreferences.self, from: $0) }
            .flatMap { ReminderPreferences.nagIntervals.contains($0.nagMinutes) ? $0 : nil } ?? ReminderPreferences()
        _ = loadDatabase()
    }

    @discardableResult
    func save(_ reminder: Reminder, replacing generation: UUID? = nil) -> String? {
        var saved = reminder
        saved.generation = UUID()
        var changed = snapshot
        var retired: Reminder?
        if let index = reminders.firstIndex(where: { $0.id == saved.id }) {
            let previous = reminders[index]
            guard previous.generation == generation else { return "This reminder changed. Reopen it to edit the latest version." }
            if previous.due != saved.due || previous.phoneSchedule != saved.phoneSchedule {
                saved.repeatAnchor = saved.due
                saved.snoozedUntil = nil
            }
            retired = previous
            changed.reminders[index] = saved
        } else {
            guard generation == nil, !changed.deletedIDs.contains(saved.id) else { return "This reminder was deleted." }
            changed.reminders.append(saved)
        }
        return commit(changed, retiring: retired, askPermission: saved.preferences.notifications)
    }

    func setExpirationExperiment(_ enabled: Bool) {
        expirationEnabled = enabled
        ExpirationExperiment.enabled = enabled
        enqueueSync()
    }

    func scheduleTest(nagMinutes: Int = 2) {
        guard [2, 5].contains(nagMinutes) else { return }
        enqueueSync(askPermission: true)
        Task {
            await waitForCurrentSync()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized, settings.lockScreenSetting == .enabled else { return }
            let due = Date().addingTimeInterval(30)
            var preferences = defaults
            preferences.notifications = true
            preferences.nagMinutes = nagMinutes
            preferences.repeatRule = .never
            let title = self.expirationEnabled ? "Expiration test · \(nagMinutes) min" : "Control test · \(nagMinutes) min"
            save(Reminder(title: title, notes: "Hold this notification to try Snooze 15 min or Done.",
                          due: due, repeatAnchor: due, preferences: preferences))
        }
    }

    func delete(_ reminder: Reminder) {
        guard let index = reminders.firstIndex(where: {
            $0.id == reminder.id && $0.generation == reminder.generation
        }) else { return }
        var changed = snapshot
        let stored = changed.reminders.remove(at: index)
        changed.deletedIDs.insert(stored.id)
        commit(changed, retiring: stored)
    }

    func done(_ reminder: Reminder, now: Date = .now) {
        guard let index = currentIndex(reminder.id, generation: reminder.generation) else { return }
        let previous = reminders[index]
        var changed = snapshot
        changed.reminders[index].generation = UUID()
        changed.reminders[index].snoozedUntil = nil
        if let next = previous.nextOccurrence(after: now) {
            var occurrence = changed.reminders[index]
            occurrence.id = UUID()
            occurrence.completedAt = now
            changed.reminders[index].due = next
            changed.reminders[index].phoneSchedule?.day = Calendar.autoupdatingCurrent.dateComponents(
                [.era, .year, .month, .day], from: next
            )
            changed.reminders.append(occurrence)
        } else {
            changed.reminders[index].completedAt = now
        }
        commit(changed, retiring: previous)
    }

    func restore(_ reminder: Reminder) {
        guard var saved = reminders.first(where: {
            $0.id == reminder.id && $0.generation == reminder.generation && $0.completedAt != nil
        }) else { return }
        saved.completedAt = nil
        saved.snoozedUntil = nil
        // A completed occurrence is separate from the active recurring series.
        saved.preferences.repeatRule = .never
        save(saved, replacing: saved.generation)
    }

    func snooze(_ reminder: Reminder, now: Date = .now) {
        guard let index = currentIndex(reminder.id, generation: reminder.generation) else { return }
        let previous = reminders[index]
        var changed = snapshot
        changed.reminders[index].generation = UUID()
        changed.reminders[index].snoozedUntil = now.addingTimeInterval(15 * 60)
        commit(changed, retiring: previous)
    }

    func handleAction(_ action: String, id: String, generation: String, at time: Date) async {
        guard loadDatabase(), let id = UUID(uuidString: id), let generation = UUID(uuidString: generation),
              let index = currentIndex(id, generation: generation) else { return }
        switch action {
        case Self.doneAction: done(reminders[index], now: time)
        case Self.snoozeAction: snooze(reminders[index], now: time)
        default: return
        }
        // Keep the delegate alive if an app refresh supersedes this reconciliation.
        await waitForCurrentSync()
    }

    private func waitForCurrentSync() async {
        while let task = syncTask {
            let revision = syncRevision
            await task.value
            if revision == syncRevision { break }
        }
    }

    func refresh() {
        if loadDatabase() {
            let calendar = Calendar.autoupdatingCurrent
            var adjusted = snapshot
            for index in adjusted.reminders.indices where adjusted.reminders[index].completedAt == nil {
                guard let due = adjusted.reminders[index].phoneSchedule?.dueDate(calendar: calendar),
                      adjusted.reminders[index].due != due else { continue }
                if adjusted.reminders[index].snoozedUntil == nil {
                    adjusted.reminders[index].generation = UUID()
                }
                adjusted.reminders[index].due = due
            }
            if adjusted != snapshot {
                commit(adjusted)
                return
            }
        }
        enqueueSync()
    }

    private func loadDatabase() -> Bool {
        do {
            let loaded = try database.read()
            switch loaded {
            case .missing:
                if let source, source != .missing { throw ReminderDatabase.Problem.missing }
                guard verifiedEmpty else { return false }
            case .legacy(let existing), .file(let existing):
                verifiedEmpty = false
                if existing != snapshot {
                    snapshot = existing
                    reminders = existing.reminders
                }
            }
            source = loaded
            storageIssue = nil
            return true
        } catch {
            source = nil
            verifiedEmpty = false
            storageIssue = Self.storageUnavailable
            return false
        }
    }

    @discardableResult
    private func commit(_ changed: ReminderSnapshot, retiring previous: Reminder? = nil,
                        askPermission: Bool = false) -> String? {
        guard let source else { return storageIssue ?? "Open Nudge and wait for your reminders to finish loading." }
        do {
            self.source = try database.commit(changed, replacing: source)
        } catch {
            storageIssue = "Nudge couldn’t save this change. Your previous reminders and queued alerts were kept."
            return storageIssue
        }
        snapshot = changed
        reminders = changed.reminders
        verifiedEmpty = false
        storageIssue = nil
        if let previous { clearNotifications(for: previous) }
        enqueueSync(askPermission: askPermission)
        return nil
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

    private func persist<T: Encodable>(_ value: T, key: String) {
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            status = "Nudge could not save your changes."
        }
    }

    private func enqueueSync(askPermission: Bool = false) {
        permissionRequestedByUser = permissionRequestedByUser || askPermission
        let prior = syncTask
        syncRevision += 1
        let revision = syncRevision
        isScheduling = true
        syncTask = Task { [weak self] in
            await prior?.value
            guard let self else { return }
            await self.reconcile(revision: revision)
            if revision == self.syncRevision { self.isScheduling = false }
        }
    }

    private func reconcile(revision: Int) async {
        var settings = await center.notificationSettings()
        guard revision == syncRevision else { return }
        let requests = await center.pendingNotificationRequests()
        guard revision == syncRevision else { return }
        if !loadDatabase() {
            guard storageIssue == nil, UIApplication.shared.applicationState == .active,
                  UIApplication.shared.isProtectedDataAvailable else { return }
            let delivered = await center.deliveredNotifications()
            guard revision == syncRevision else { return }
            guard !(requests.map(\.identifier) + delivered.map(\.request.identifier))
                .contains(where: { $0.hasPrefix(ScheduledAlert.prefix) }) else {
                storageIssue = Self.storageUnavailable
                return
            }
            verifiedEmpty = true
            guard loadDatabase() else { return }
        }
        let askPermission = permissionRequestedByUser
        permissionRequestedByUser = false
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
        guard authorized else {
            status = "Allow notifications to receive reminders on the Lock Screen."
            return
        }
        // Re-read after any permission prompt. Cancellation only uses readable, committed data.
        guard loadDatabase() else { return }

        let plan = AlertPlan(reminders: reminders, now: .now)
        let desired = Set(plan.alerts.map(\.identifier))
        let current = Dictionary(uniqueKeysWithValues: reminders.map { ($0.id, $0) })
        var pending = requests.compactMap { PendingNudge($0.identifier) }
        let otherCount = requests.count - pending.count
        var retained = Set(pending.map(\.identifier))
        var replacements = Set(plan.alerts.lazy.filter { retained.contains($0.identifier) }.map(\.reminder.id))

        func retireSuperseded() {
            let removed = Set(pending.filter {
                $0.canRetire(current: current, deletedIDs: snapshot.deletedIDs, queuedReplacement: replacements)
            }.map(\.identifier))
            guard !removed.isEmpty else { return }
            center.removePendingNotificationRequests(withIdentifiers: Array(removed))
            pending.removeAll { removed.contains($0.identifier) }
            retained.subtract(removed)
        }
        retireSuperseded()

        var failure = false
        for alert in plan.alerts {
            guard revision == syncRevision else { return }
            guard !retained.contains(alert.identifier) else { continue }
            // A one-slot swap gives iOS the replacement before retiring the old
            // generation. When adding a new reminder, only shed a redundant nag.
            let count = pending.count + otherCount
            let canSwap = count == AlertPlan.capacity && pending.contains {
                $0.id == alert.reminder.id && $0.generation != alert.reminder.generation
            }
            if count >= AlertPlan.capacity && !canSwap {
                guard let extra = PendingNudge.expendable(in: pending, current: current, desired: desired) else {
                    failure = true
                    break
                }
                // A predecessor must not expire if its successor is being evicted.
                guard await releaseExpirationDependency(on: extra.identifier, revision: revision), revision == syncRevision else {
                    failure = true
                    break
                }
                center.removePendingNotificationRequests(withIdentifiers: [extra.identifier])
                pending.removeAll { $0.identifier == extra.identifier }
                retained.remove(extra.identifier)
            }
            do {
                try await center.add(request(for: alert))
            } catch {
                failure = true
                break
            }
            guard revision == syncRevision, source != nil else { return }
            if let added = PendingNudge(alert.identifier) { pending.append(added) }
            retained.insert(alert.identifier)
            replacements.insert(alert.reminder.id)
            retireSuperseded()
        }
        guard revision == syncRevision else { return }
        await configureExpiration(revision: revision)
        guard revision == syncRevision else { return }
        if !lockScreenEnabled {
            status = "Turn on Lock Screen alerts for Nudge in iPhone Settings."
        } else if failure || plan.unscheduledFirstAlerts > 0 {
            status = "Some alerts could not be queued. Check your reminders before closing Nudge."
        } else if settings.scheduledDeliverySetting == .enabled {
            status = "Alerts are queued. Choose immediate delivery in iPhone Settings for on-time tests."
        } else {
            status = "\(retained.count) alerts queued with iOS."
        }
    }

    private func request(for alert: ScheduledAlert) -> UNNotificationRequest {
        let reminder = alert.reminder
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.notes.isEmpty ? "Hold for Done or Snooze 15 min." : reminder.notes
        content.categoryIdentifier = Self.category
        content.threadIdentifier = reminder.id.uuidString
        content.userInfo = ["id": reminder.id.uuidString, "generation": reminder.generation.uuidString,
                            ExpirationExperiment.scheduledKey: alert.date.timeIntervalSince1970]
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

    private func configureExpiration(revision: Int) async {
        let enabled = expirationEnabled
        guard NudgeExpirationAvailable() else {
            expirationStatus = "Expiration is unavailable on this iPhone. Alerts still use normal delivery."
            return
        }
        let requests = await center.pendingNotificationRequests()
        guard revision == syncRevision, loadDatabase() else { return }
        let byID = Dictionary(uniqueKeysWithValues: requests.map { ($0.identifier, $0) })
        let candidates = ExpirationCandidate.make(pending: requests.compactMap { PendingNudge($0.identifier) },
                                                  reminders: reminders, now: .now)
        var failed = false
        for candidate in candidates {
            guard revision == syncRevision else { return }
            let alert = candidate.alert
            guard alert.date.timeIntervalSinceNow > 5, let previous = byID[alert.identifier] else { continue }
            let successor = enabled ? candidate.successor : nil
            let desiredDate = successor?.date
            let recordedDate = (previous.content.userInfo[ExpirationExperiment.requestedKey] as? Double).map(Date.init(timeIntervalSince1970:))
            if NudgeExpirationMatches(previous.content, desiredDate) && recordedDate == desiredDate { continue }

            let base = request(for: alert)
            let content = base.content.mutableCopy() as! UNMutableNotificationContent
            guard NudgeSetExpiration(content, desiredDate) else { failed = true; continue }
            if let successor {
                content.userInfo[ExpirationExperiment.requestedKey] = successor.date.timeIntervalSince1970
                content.userInfo[ExpirationExperiment.successorKey] = successor.identifier
            }
            // Recreate from the original absolute date, never from a fetched
            // time-interval trigger whose delay could restart at this moment.
            guard alert.date.timeIntervalSinceNow > 5 else { continue }
            do {
                try await center.add(UNNotificationRequest(identifier: alert.identifier, content: content, trigger: base.trigger))
            } catch { failed = true }
        }
        guard revision == syncRevision else { return }
        let verified = await center.pendingNotificationRequests()
        guard revision == syncRevision else { return }
        let requested = verified.filter { $0.content.userInfo[ExpirationExperiment.requestedKey] != nil }
        let retained = requested.filter {
            guard let expected = $0.content.userInfo[ExpirationExperiment.requestedKey] as? Double,
                  let actual = NudgeReadExpiration($0.content) else { return false }
            return abs(actual.timeIntervalSince1970 - expected) < 0.5
        }.count
        if enabled {
            expirationStatus = "iOS readback: \(retained) of \(requested.count) requested expiry dates retained. This does not prove Lock Screen removal."
        } else {
            expirationStatus = "Expiration off for upcoming alerts. Already-delivered cards may still expire."
        }
        if failed { expirationStatus += " Some changes failed; check diagnostics." }
    }

    private func releaseExpirationDependency(on successorID: String, revision: Int) async -> Bool {
        let pending = await center.pendingNotificationRequests()
        guard revision == syncRevision else { return false }
        let delivered = await center.deliveredNotifications()
        guard revision == syncRevision else { return false }
        let depends: (UNNotificationRequest) -> Bool = {
            PendingNudge($0.identifier) != nil && $0.content.userInfo[ExpirationExperiment.successorKey] as? String == successorID
        }
        // A delivered card cannot safely be rewritten without presenting again.
        guard !delivered.contains(where: { depends($0.request) }) else { return false }
        for predecessor in pending where depends(predecessor) {
            guard revision == syncRevision else { return false }
            guard let timestamp = predecessor.content.userInfo[ExpirationExperiment.scheduledKey] as? Double,
                  timestamp.isFinite else { return false }
            let date = Date(timeIntervalSince1970: timestamp)
            guard date.timeIntervalSinceNow > 10 else { return false }
            let content = predecessor.content.mutableCopy() as! UNMutableNotificationContent
            guard NudgeSetExpiration(content, nil) else { return false }
            content.userInfo.removeValue(forKey: ExpirationExperiment.requestedKey)
            content.userInfo.removeValue(forKey: ExpirationExperiment.successorKey)
            let trigger: UNNotificationTrigger
            if let calendar = predecessor.trigger as? UNCalendarNotificationTrigger {
                trigger = calendar
            } else { trigger = intervalTrigger(for: date) }
            do {
                try await center.add(UNNotificationRequest(identifier: predecessor.identifier, content: content, trigger: trigger))
            } catch { return false }
            let readback = await center.pendingNotificationRequests()
            guard revision == syncRevision, date.timeIntervalSinceNow > 5,
                  let verified = readback.first(where: { $0.identifier == predecessor.identifier }),
                  NudgeExpirationMatches(verified.content, nil),
                  verified.content.userInfo[ExpirationExperiment.successorKey] == nil else { return false }
        }
        return true
    }

    func refreshNotificationDiagnostics() async {
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        func time(_ date: Date?) -> String { date.map(formatter.string(from:)) ?? "none" }
        var lines = ["Nudge 1.0.5 (7) · iOS \(UIDevice.current.systemVersion)",
                     "Captured: \(time(.now))", "Experiment: \(expirationEnabled ? "ON" : "OFF")",
                     "Private setter present: \(NudgeExpirationAvailable())",
                     "Pending: \(pending.count) · Delivered cards: \(delivered.count)",
                     "Read-only snapshot; no cards cleared."]
        for item in delivered.sorted(by: { $0.date < $1.date }) {
            lines.append("VISIBLE · \(item.request.content.title) · delivered \(time(item.date)) · expiry \(time(NudgeReadExpiration(item.request.content))) · \(item.request.identifier)")
        }
        for item in pending.sorted(by: { $0.identifier < $1.identifier }) {
            let planned = (item.content.userInfo[ExpirationExperiment.scheduledKey] as? Double).map(Date.init(timeIntervalSince1970:))
            let requested = (item.content.userInfo[ExpirationExperiment.requestedKey] as? Double).map(Date.init(timeIntervalSince1970:))
            lines.append("PENDING · \(item.content.title) · at \(time(planned)) · requested expiry \(time(requested)) · iOS expiry \(time(NudgeReadExpiration(item.content))) · \(item.identifier)")
        }
        notificationDiagnostics = lines.joined(separator: "\n")
    }
}
