import Foundation
import SwiftUI
import UIKit
import UserNotifications

@MainActor
final class ReminderStore: ObservableObject {
    static let shared = ReminderStore()
    static let category = NotificationRequestFactory.category
    static let doneAction = "NUDGE_DONE"
    static let snoozeAction = "NUDGE_SNOOZE"

    @Published private(set) var reminders: [Reminder] = []
    @Published var defaults: ReminderPreferences {
        didSet { persist(defaults, key: Self.defaultsKey) }
    }
    @Published private(set) var status = "Checking notification access…"
    @Published private(set) var needsSettings = false
    @Published private(set) var storageIssue: String?
    @Published private(set) var schedulingIssue: String?
    @Published private(set) var soundOnlyEnabled = NagDelivery.enabled
    @Published private(set) var deliveryStatus = "Checking upcoming notification delivery."
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
    func save(_ reminder: Reminder, replacing generation: UUID? = nil, expecting original: Reminder? = nil) -> String? {
        do {
            let change = try ReminderLifecycle.saving(reminder, replacing: generation, expecting: original, in: snapshot)
            return commit(change.snapshot, retiring: change.retiring, askPermission: reminder.preferences.notifications)
        } catch let problem as ReminderLifecycle.Problem {
            return problem.rawValue
        } catch {
            return "Nudge couldn’t prepare this change. Your reminder was kept."
        }
    }

    func delete(_ reminder: Reminder) {
        guard let change = ReminderLifecycle.deleting(reminder, in: snapshot) else { return }
        commit(change.snapshot, retiring: change.retiring)
    }

    func done(_ reminder: Reminder, now: Date = .now) async {
        // An unsuccessful earlier edit can leave an older generation scheduled.
        // Settle in-flight adds, then include every observed generation belonging
        // to this reminder in the same durable completion transaction.
        await waitForCurrentSync()
        guard loadDatabase(), currentIndex(reminder.id, generation: reminder.generation) != nil else { return }
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        guard loadDatabase(), currentIndex(reminder.id, generation: reminder.generation) != nil else { return }
        let owned = (pending + delivered.map(\.request)).compactMap { PendingNudge($0.identifier) }
            .filter { $0.id == reminder.id }
        let observed = Set(owned.map(\.generationIdentifier))
        guard let change = ReminderLifecycle.completing(reminder, in: snapshot, now: now,
                                                       observedGenerations: observed) else {
            let message = "Nudge couldn’t determine the next repeat date. Edit this reminder’s date and repeat settings, then try Done again."
            schedulingIssue = message
            status = message
            return
        }
        guard commit(change.snapshot, retiring: change.retiring) == nil else { return }
        let oldCards = delivered.compactMap { item -> String? in
            guard let request = PendingNudge(item.request.identifier), request.id == reminder.id,
                  observed.contains(request.generationIdentifier) else { return nil }
            return item.request.identifier
        }
        if !oldCards.isEmpty { center.removeDeliveredNotifications(withIdentifiers: oldCards) }
    }

    func restore(_ reminder: Reminder) {
        guard let change = ReminderLifecycle.restoring(reminder, in: snapshot) else { return }
        commit(change.snapshot, retiring: change.retiring,
               askPermission: change.snapshot.reminders.first(where: { $0.id == reminder.id })?.preferences.notifications == true)
    }

    func snooze(_ reminder: Reminder, now: Date = .now) {
        guard let change = ReminderLifecycle.snoozing(reminder, in: snapshot, now: now) else { return }
        commit(change.snapshot, retiring: change.retiring)
    }

    func handleAction(_ action: String, id: String, generation: String, at time: Date) async {
        guard loadDatabase(), let id = UUID(uuidString: id), let generation = UUID(uuidString: generation),
              let index = currentIndex(id, generation: generation) else { return }
        switch action {
        case Self.doneAction: await done(reminders[index], now: time)
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
            let adjusted = ReminderLifecycle.refreshingSchedules(in: snapshot)
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
        let prepared = NagDelivery.prepare(changed, replacing: snapshot, now: .now)
        do {
            self.source = try database.commit(prepared, replacing: source)
        } catch {
            storageIssue = "Nudge couldn’t save this change. Your previous reminders and queued alerts were kept."
            return storageIssue
        }
        snapshot = prepared
        reminders = prepared.reminders
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
        schedulingIssue = nil
        syncTask = Task { [weak self] in
            await prior?.value
            guard let self else { return }
            await self.reconcile(revision: revision)
        }
    }

    private func reconcile(revision: Int) async {
        var settings = await center.notificationSettings()
        guard revision == syncRevision else { return }
        var requests = await center.pendingNotificationRequests()
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
        var permissionFailed = false
        if askPermission && settings.authorizationStatus == .notDetermined {
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
                settings = await center.notificationSettings()
            } catch {
                status = "iPhone could not request notification access."
                schedulingIssue = status
                permissionFailed = true
            }
        }
        guard revision == syncRevision else { return }

        let authorized = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional || settings.authorizationStatus == .ephemeral
        let lockScreenEnabled = settings.lockScreenSetting == .enabled
        needsSettings = settings.authorizationStatus == .denied || (authorized && !lockScreenEnabled)
        // Revoking permission must not prevent an explicit Done/Delete/Off from
        // removing its obsolete requests. Otherwise they can fire when permission
        // is enabled again outside the app. Never infer a stop from missing data.
        guard loadDatabase() else { return }
        let currentBeforeScheduling = Dictionary(uniqueKeysWithValues: reminders.map { ($0.id, $0) })
        let explicitStops = requests.compactMap { PendingNudge($0.identifier) }.filter {
            $0.canRetire(current: currentBeforeScheduling, deletedIDs: snapshot.deletedIDs, queuedReplacement: [],
                         stoppedGenerations: snapshot.stoppedNotificationGenerations ?? [])
        }.map(\.identifier)
        if !explicitStops.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: explicitStops)
        }
        guard authorized else {
            if !permissionFailed { status = "Allow notifications to receive reminders on the Lock Screen." }
            return
        }
        // Re-read after any permission prompt. Cancellation only uses readable, committed data.
        guard loadDatabase() else { return }

        // Upgrade accepted requests in place before capacity pruning. No cancel
        // happens first, and legacy expiry is never put on a new request.
        let rewritesSucceeded = await configureDelivery(revision: revision)
        guard revision == syncRevision, loadDatabase() else { return }
        requests = await center.pendingNotificationRequests()
        guard revision == syncRevision else { return }

        let plan = AlertPlan(reminders: reminders, now: .now)
        let desired = Set(plan.alerts.map(\.identifier))
        let current = Dictionary(uniqueKeysWithValues: reminders.map { ($0.id, $0) })
        var pending = requests.compactMap { PendingNudge($0.identifier) }
        let otherCount = requests.count - pending.count
        var retained = Set(pending.map(\.identifier))
        var replacements = Set(plan.alerts.lazy.filter { retained.contains($0.identifier) }.map(\.reminder.id))

        func retireSuperseded() {
            let removed = Set(pending.filter {
                $0.canRetire(current: current, deletedIDs: snapshot.deletedIDs, queuedReplacement: replacements,
                             stoppedGenerations: snapshot.stoppedNotificationGenerations ?? [])
            }.map(\.identifier))
            guard !removed.isEmpty else { return }
            center.removePendingNotificationRequests(withIdentifiers: Array(removed))
            pending.removeAll { removed.contains($0.identifier) }
            retained.subtract(removed)
        }
        retireSuperseded()

        var failure = !rewritesSucceeded
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
                // Do not strand a delivered/near-due alert from the old expiry
                // experiment by removing its promised successor.
                guard await canEvictLegacySuccessor(extra.identifier, revision: revision), revision == syncRevision else {
                    failure = true
                    break
                }
                center.removePendingNotificationRequests(withIdentifiers: [extra.identifier])
                pending.removeAll { $0.identifier == extra.identifier }
                retained.remove(extra.identifier)
            }
            do {
                let queued = request(for: alert)
                try await center.add(queued)
                guard revision == syncRevision else { return }
                if !NotificationRequestFactory.isSoundOnly(queued.content),
                   !recordAcceptedAnchor(queued.identifier) { failure = true; break }
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
        await updateDeliveryStatus(revision: revision, failed: failure)
        guard revision == syncRevision else { return }
        if failure || plan.unscheduledFirstAlerts > 0 {
            schedulingIssue = "Some alerts could not be queued. Check your reminders before closing Nudge."
        }
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
        // The first accepted alert can establish its anchor while this plan's
        // remaining alerts still contain older copies of the reminder.
        var latest = alert
        if let reminder = reminders.first(where: { $0.id == alert.reminder.id && $0.generation == alert.reminder.generation }) {
            latest.reminder = reminder
        }
        return NotificationRequestFactory.make(for: latest, soundOnlyEnabled: soundOnlyEnabled)
    }

    private func recordAcceptedAnchor(_ identifier: String) -> Bool {
        guard let changed = NagDelivery.acceptingVisibleAnchor(identifier: identifier, in: snapshot) else { return true }
        guard let source else { return false }
        do {
            self.source = try database.commit(changed, replacing: source)
            snapshot = changed
            reminders = changed.reminders
            return true
        } catch {
            storageIssue = "Nudge couldn't save the first alert confirmation. Existing reminders and alerts were kept."
            return false
        }
    }

    private func configureDelivery(revision: Int) async -> Bool {
        let requests = await center.pendingNotificationRequests()
        guard revision == syncRevision, loadDatabase() else { return false }
        // Recover after a crash between iOS accepting the first card and the
        // confirmation being saved. Never infer this from a legacy expiry card.
        if reminders.contains(where: { $0.completedAt == nil && $0.soundOnlyAnchorAccepted == false }) {
            let delivered = await center.deliveredNotifications()
            guard revision == syncRevision else { return false }
            let accepted = (requests + delivered.map(\.request)).filter {
                $0.content.userInfo[NagDelivery.versionKey] as? Int == NagDelivery.payloadVersion
                    && NotificationRequestFactory.visibleNudge(identifier: $0.identifier, content: $0.content, date: .now) != nil
            }.sorted { (PendingNudge($0.identifier)?.index ?? Int.max) < (PendingNudge($1.identifier)?.index ?? Int.max) }
            for request in accepted {
                guard recordAcceptedAnchor(request.identifier) else { return false }
            }
        }
        let byID = Dictionary(uniqueKeysWithValues: requests.map { ($0.identifier, $0) })
        let alerts = NagDelivery.rewritableAlerts(pending: requests.compactMap { PendingNudge($0.identifier) },
                                                 reminders: reminders, now: .now)
        var succeeded = true
        for alert in alerts {
            guard revision == syncRevision else { return false }
            var latest = alert
            guard let reminder = reminders.first(where: { $0.id == alert.reminder.id && $0.generation == alert.reminder.generation }) else { continue }
            latest.reminder = reminder
            guard latest.date.timeIntervalSinceNow > 5, let previous = byID[latest.identifier],
                  NotificationRequestFactory.needsRewrite(previous, for: latest, enabled: soundOnlyEnabled) else { continue }
            // A fresh content object clears the previous private expiry property.
            // On failure, the accepted old request is not deliberately removed.
            do {
                let queued = request(for: latest)
                try await center.add(queued)
                guard revision == syncRevision else { return false }
                if !NotificationRequestFactory.isSoundOnly(queued.content),
                   !recordAcceptedAnchor(queued.identifier) { return false }
            }
            catch { succeeded = false }
        }
        return revision == syncRevision && succeeded
    }

    private func canEvictLegacySuccessor(_ identifier: String, revision: Int) async -> Bool {
        let pending = await center.pendingNotificationRequests()
        guard revision == syncRevision else { return false }
        let delivered = await center.deliveredNotifications()
        guard revision == syncRevision else { return false }
        return !(pending + delivered.map(\.request)).contains {
            PendingNudge($0.identifier) != nil
                && $0.content.userInfo["nudgeExpirySuccessor"] as? String == identifier
        }
    }

    private func updateDeliveryStatus(revision: Int, failed: Bool) async {
        let requests = await center.pendingNotificationRequests()
        guard revision == syncRevision else { return }
        let owned = requests.filter { PendingNudge($0.identifier) != nil }
        let soundOnly = owned.filter { NotificationRequestFactory.isSoundOnly($0.content) }.count
        deliveryStatus = "Upcoming: \(owned.count - soundOnly) alert requests, \(soundOnly) sound-only nags."
        if failed { deliveryStatus += " Some updates failed; keep Nudge open and check your reminders." }
    }

    func refreshNotificationDiagnostics() async {
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        func time(_ date: Date?) -> String { date.map(formatter.string(from:)) ?? "none" }
        func title(_ content: UNNotificationContent) -> String {
            content.userInfo[NagDelivery.titleKey] as? String ?? content.title
        }
        func mode(_ content: UNNotificationContent) -> String {
            NotificationRequestFactory.isSoundOnly(content) ? "sound-only" : "alert"
        }
        var lines = ["Nudge 1.0.8 (10) · iOS \(UIDevice.current.systemVersion)",
                     "Captured: \(time(.now))", "Sound-only nags: \(soundOnlyEnabled ? "ON" : "OFF")",
                     "Pending API records: \(pending.count) · Delivered API records: \(delivered.count)",
                     "API records are not a count of visible Lock Screen cards. Check the screen directly.",
                     "Read-only snapshot; no notification removal requested."]
        for item in delivered.sorted(by: { $0.date < $1.date }) {
            lines.append("REPORTED · \(title(item.request.content)) · \(mode(item.request.content)) · delivered \(time(item.date)) · \(item.request.identifier)")
        }
        for item in pending.sorted(by: { $0.identifier < $1.identifier }) {
            let planned = (item.content.userInfo[NagDelivery.scheduledKey] as? Double).map(Date.init(timeIntervalSince1970:))
            let legacy = item.content.userInfo[NagDelivery.versionKey] as? Int != NagDelivery.payloadVersion
            lines.append("PENDING · \(title(item.content)) · \(mode(item.content)) · at \(time(planned)) · legacy payload \(legacy) · \(item.identifier)")
        }
        notificationDiagnostics = lines.joined(separator: "\n")
    }
}
