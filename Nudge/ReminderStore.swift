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
    @Published private(set) var notificationOpen: ReminderNotificationOpen?
    @Published var defaults: ReminderPreferences {
        didSet { persist(defaults, key: Self.defaultsKey) }
    }
    @Published private(set) var status = "Checking notification access…"
    @Published private(set) var needsSettings = false
    @Published private(set) var storageIssue: String?
    @Published private(set) var backupStatus = "Checking automatic backup…"
    @Published private(set) var schedulingIssue: String?
    @Published private(set) var isUpdatingNotifications = false
    @Published private(set) var soundOnlyEnabled = NagDelivery.enabled
    @Published private(set) var deliveryStatus = "Checking upcoming notification delivery."
    @Published private(set) var notificationDiagnostics = "Refresh after a test to read the notifications still held by iOS."

    static let storageUnavailable = "Nudge couldn’t open your saved reminders. Your data and queued alerts were left untouched."
    private static let defaultsKey = "Nudge.defaults.v1"
    private static let updateLogKey = "Nudge.notificationUpdateLog.v1"
    private var updateLog = NotificationUpdateLog()
    private let center = UNUserNotificationCenter.current()
    private let database: ReminderDatabase
    private var source: ReminderDatabase.Source?
    private var snapshot = ReminderSnapshot()
    private var verifiedEmpty = false
    private var syncTask: Task<Void, Never>?
    private var syncRevision = 0
    private var permissionRequestedByUser = false
    private var canQueueMinuteRepeats = NotificationRequestFactory.supportsMinuteRepeats
    private var phaseRetry: Task<Void, Never>?
    private var retryBudget = NotificationRetryBudget()
    private var adjustmentSequence = QuickAdjustmentSequence()
    private var deliveredCleanupPrefixes: Set<String> = []
    private var adjustmentBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    private init() {
        let disk = UserDefaults.standard
        updateLog = NotificationUpdateLog.decode(disk.data(forKey: Self.updateLogKey))
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

    func exportBackup() throws -> Data {
        guard loadDatabase() else { throw ReminderDatabase.Problem.missing }
        return try ReminderBackup.encode(snapshot: snapshot)
    }

    func importBackup(_ backup: ReminderBackup) -> String {
        guard loadDatabase() else { return storageIssue ?? Self.storageUnavailable }
        do {
            let merged = try backup.merging(into: snapshot)
            let added = merged.reminders.count - snapshot.reminders.count
            guard added > 0 else { return "No new reminders to import. Existing and previously deleted reminders were skipped." }
            if let error = commit(merged) { return error }
            return "Imported \(added) reminders. Skipped \(backup.reminders.count - added) existing or previously deleted reminders."
        } catch {
            return "This backup could not be imported. Your reminders were kept."
        }
    }

    func delete(_ reminder: Reminder) {
        guard let change = ReminderLifecycle.deleting(reminder, in: snapshot) else { return }
        commit(change.snapshot, retiring: change.retiring)
    }

    func done(_ reminder: Reminder, now: Date = .now, animation: Animation? = nil) async {
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
        if PreservedNotificationSchedule.inProgress {
            await waitForCurrentSync()
            await done(reminder, now: now, animation: animation)
            return
        }
        guard commit(change.snapshot, retiring: change.retiring, animation: animation) == nil else { return }
        deliveredCleanupPrefixes.formUnion(observed.map { ScheduledAlert.prefix + $0 + "." })
    }

    func done(_ occurrence: ReminderOccurrence, now: Date = .now, animation: Animation? = nil) async {
        if !occurrence.isProjected {
            await done(occurrence.reminder, now: now, animation: animation)
            return
        }
        guard loadDatabase(),
              let change = ReminderLifecycle.completingProjected(occurrence, in: snapshot, now: now) else { return }
        // The future occurrence has no requests of its own. Leave the current
        // occurrence and its queued alerts in place.
        commit(change.snapshot, refreshAlerts: false, animation: animation)
    }

    func restore(_ reminder: Reminder) {
        guard let change = ReminderLifecycle.restoring(reminder, in: snapshot) else { return }
        commit(change.snapshot, retiring: change.retiring,
               askPermission: change.snapshot.reminders.first(where: { $0.id == reminder.id })?.preferences.notifications == true)
    }

    func snooze(_ reminder: Reminder, now: Date = .now) {
        if PreservedNotificationSchedule.inProgress {
            Task { [weak self] in
                await self?.waitForCurrentSync()
                self?.snooze(reminder, now: now)
            }
            return
        }
        guard let change = ReminderLifecycle.snoozing(reminder, in: snapshot, now: now) else { return }
        commit(change.snapshot, retiring: change.retiring)
    }

    func adjustTime(_ reminder: Reminder, by shift: ReminderTimeShift, direction: ReminderTimeShift.Direction,
                    now: Date = .now) -> String? {
        guard loadDatabase() else { return storageIssue ?? Self.storageUnavailable }
        guard let current = adjustmentSequence.currentReminder(for: reminder, in: snapshot) else {
            return ReminderLifecycle.Problem.changed.rawValue
        }
        guard let change = ReminderLifecycle.adjusting(current, by: shift, direction: direction,
                                                      in: snapshot, now: now) else {
            return "Choose a time in the future."
        }
        // Persist every tap immediately. A running OS transaction finishes
        // uncancelled; its successor uses the newest durable reminder state.
        let problem = commit(change.snapshot, retiring: change.retiring,
                             adjustment: true, syncDelay: 0.4)
        if problem == nil, let latest = snapshot.reminders.first(where: { $0.id == current.id }) {
            adjustmentSequence.record(previous: current, next: latest)
            recordUpdate(stage: "adjustment saved", message: "\(direction) \(shift.rawValue); Nag Me \(latest.preferences.nagMinutes) min",
                details: "reminder=\(latest.id); generation=\(latest.generation); oldEpoch=\(current.alertDate.timeIntervalSince1970); newEpoch=\(latest.alertDate.timeIntervalSince1970)")
        }
        return problem
    }

    func handleAction(_ action: String, id: String, generation: String, at time: Date) async {
        guard loadDatabase(), let id = UUID(uuidString: id), let generation = UUID(uuidString: generation),
              let index = currentIndex(id, generation: generation) else { return }
        switch action {
        case UNNotificationDefaultActionIdentifier:
            notificationOpen = ReminderNotificationOpen(id: id, generation: generation)
            return
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
        enqueueSync(resetRetries: true)
    }

    func retryNotifications() { refresh() }

    private func loadDatabase() -> Bool {
        do {
            var loaded = try database.read { backupStatus = $0 }
            if case .legacy(let existing) = loaded {
                do {
                    // Back up old-format installs immediately, without changing
                    // any reminder identity, schedule, or cancellation metadata.
                    loaded = try database.commit(existing, replacing: loaded)
                    backupStatus = "Automatic backup is ready."
                } catch {
                    // Retain readable legacy data and retry on a later refresh.
                    backupStatus = "Your reminders are readable, but automatic backup could not be created yet."
                }
            }
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
            backupStatus = "Automatic recovery is unavailable. Existing saved files were kept."
            return false
        }
    }

    @discardableResult
    private func commit(_ changed: ReminderSnapshot, retiring previous: Reminder? = nil,
                        askPermission: Bool = false, refreshAlerts: Bool = true,
                        animation: Animation? = nil, adjustment: Bool = false,
                        syncDelay: TimeInterval = 0) -> String? {
        guard adjustment || !PreservedNotificationSchedule.inProgress else {
            let message = "Notifications are being updated. Please try this change again in a moment."
            schedulingIssue = message
            status = message
            return message
        }
        guard let source else { return storageIssue ?? "Open Nudge and wait for your reminders to finish loading." }
        let prepared = NagDelivery.prepare(changed, replacing: snapshot, now: .now)
        do {
            self.source = try database.commit(prepared, replacing: source)
        } catch {
            storageIssue = "Nudge couldn’t save this change. Your previous reminders and queued alerts were kept."
            return storageIssue
        }
        snapshot = prepared
        if let animation {
            withAnimation(animation) { reminders = prepared.reminders }
        } else {
            reminders = prepared.reminders
        }
        verifiedEmpty = false
        storageIssue = nil
        if !adjustment { adjustmentSequence.reset() }
        if let previous { clearNotifications(for: previous) }
        if adjustment { beginAdjustmentBackgroundTask() }
        if refreshAlerts { enqueueSync(askPermission: askPermission, delay: syncDelay, resetRetries: true) }
        return nil
    }

    private func currentIndex(_ id: UUID, generation: UUID) -> Int? {
        reminders.firstIndex { $0.id == id && $0.generation == generation && $0.completedAt == nil }
    }

    private func clearNotifications(for reminder: Reminder) {
        let prefix = "\(ScheduledAlert.prefix)\(reminder.id.uuidString).\(reminder.generation.uuidString)."
        // Process this inside the serialized scheduler. An independent callback
        // could remove a card while the protected transaction verifies it.
        deliveredCleanupPrefixes.insert(prefix)
    }

    private func flushDeliveredCleanup(revision: Int, retiringVerified: Bool = false) async -> Bool {
        let prefixes = deliveredCleanupPrefixes
        guard !prefixes.isEmpty else { return true }
        let cards = await center.deliveredNotifications()
        guard revision == syncRevision else { return false }
        let ids = cards.map { $0.request.identifier }.filter { id in prefixes.contains { id.hasPrefix($0) } }
        if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        for _ in 0..<15 {
            let remaining = await center.deliveredNotifications()
            guard revision == syncRevision else { return false }
            if !remaining.contains(where: { card in prefixes.contains { card.request.identifier.hasPrefix($0) } }) {
                // An old repeat may fire during a scheduling wait. Keep its
                // cleanup intent until after replacement and a pending readback.
                if retiringVerified {
                    let pending = await center.pendingNotificationRequests()
                    guard revision == syncRevision else { return false }
                    let retired = prefixes.filter { prefix in
                        !pending.contains { $0.identifier.hasPrefix(prefix) }
                    }
                    deliveredCleanupPrefixes.subtract(retired)
                }
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        schedulingIssue = "Waiting for old reminder cards to clear. Your reminder changes are saved."
        retryPhaseSync()
        return false
    }

    private func beginAdjustmentBackgroundTask() {
        guard adjustmentBackgroundTask == .invalid else { return }
        adjustmentBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save reminder time adjustments") { [weak self] in
            Task { @MainActor in self?.endAdjustmentBackgroundTask() }
        }
    }

    private func endAdjustmentBackgroundTask() {
        guard adjustmentBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(adjustmentBackgroundTask)
        adjustmentBackgroundTask = .invalid
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            status = "Nudge could not save your changes."
        }
    }

    private func enqueueSync(askPermission: Bool = false, delay: TimeInterval = 0, resetRetries: Bool = false) {
        permissionRequestedByUser = permissionRequestedByUser || askPermission
        if resetRetries {
            phaseRetry?.cancel()
            retryBudget.reset()
        }
        let prior = syncTask
        syncRevision += 1
        let revision = syncRevision
        let notBefore = Date.now.addingTimeInterval(delay)
        isUpdatingNotifications = true
        syncTask = Task { [weak self] in
            await prior?.value
            guard let self, revision == self.syncRevision else { return }
            let remaining = notBefore.timeIntervalSinceNow
            if remaining > 0 { try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
            guard revision == self.syncRevision else { return }
            await self.reconcile(revision: revision)
            guard revision == self.syncRevision else { return }
            _ = await self.flushDeliveredCleanup(revision: revision, retiringVerified: true)
            guard revision == self.syncRevision else { return }
            self.isUpdatingNotifications = false
            self.adjustmentSequence.reset()
            self.endAdjustmentBackgroundTask()
        }
    }

    private func reconcile(revision: Int) async {
        var settings = await center.notificationSettings()
        guard revision == syncRevision else { return }
        var requests = await center.pendingNotificationRequests()
        guard revision == syncRevision else { return }
        guard await flushDeliveredCleanup(revision: revision) else { return }
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
        let explicitStops = requests.filter { request in
            PendingNudge(request.identifier)?.canRetire(
                current: currentBeforeScheduling, deletedIDs: snapshot.deletedIDs, queuedReplacement: [],
                stoppedGenerations: snapshot.stoppedNotificationGenerations ?? [],
                isRepeating: request.trigger?.repeats == true
            ) == true
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

        requests = await center.pendingNotificationRequests()
        guard revision == syncRevision else { return }
        let scheduleTask = UIApplication.shared.beginBackgroundTask(withName: "Update reminder schedule")
        let handledHourly = await reconcileHourlyNagSchedule(requests: requests, revision: revision)
        if scheduleTask != .invalid { UIApplication.shared.endBackgroundTask(scheduleTask) }
        if handledHourly { return }

        // Upgrade accepted requests in place before capacity pruning. No cancel
        // happens first, and legacy expiry is never put on a new request.
        let rewritesSucceeded = await configureDelivery(revision: revision)
        guard revision == syncRevision, loadDatabase() else { return }
        requests = await center.pendingNotificationRequests()
        guard revision == syncRevision else { return }

        let current = Dictionary(uniqueKeysWithValues: reminders.map { ($0.id, $0) })
        var repeatingRequests = Set(requests.filter { $0.trigger?.repeats == true }.map(\.identifier))
        var pending = requests.compactMap { PendingNudge($0.identifier) }
        let minuteReminders = reminders.filter {
            $0.preferences.nagMinutes == 1 && $0.preferences.notifications && $0.hasValidSchedule && $0.completedAt == nil
        }
        let repeatingMinuteIDs = Set(minuteReminders.filter { reminder in
            canQueueMinuteRepeats || repeatingRequests.contains(
                ScheduledAlert(reminder: reminder, index: 0, date: reminder.alertDate).identifier
            )
        }.map(\.id))
        let plan = AlertPlan(reminders: reminders, now: .now, repeatingMinuteIDs: repeatingMinuteIDs)
        let desired = Set(plan.alerts.map(\.identifier))
        let otherCount = requests.count - pending.count
        var retained = Set(pending.map(\.identifier))
        var replacements = Set(plan.alerts.lazy.filter { retained.contains($0.identifier) }.map(\.reminder.id))

        func retireSuperseded() {
            let removed = Set(pending.filter { request in
                if request.canRetire(current: current, deletedIDs: snapshot.deletedIDs, queuedReplacement: replacements,
                                     stoppedGenerations: snapshot.stoppedNotificationGenerations ?? [],
                                     isRepeating: repeatingRequests.contains(request.identifier)) { return true }
                // Retire fallback one-shots only after this generation's repeat is accepted.
                return request.index > 0 && repeatingMinuteIDs.contains(request.id)
                    && current[request.id]?.generation == request.generation
                    && repeatingRequests.contains("\(ScheduledAlert.prefix)\(request.generationIdentifier).0")
            }.map(\.identifier))
            guard !removed.isEmpty else { return }
            center.removePendingNotificationRequests(withIdentifiers: Array(removed))
            pending.removeAll { removed.contains($0.identifier) }
            retained.subtract(removed)
            repeatingRequests.subtract(removed)
        }
        retireSuperseded()

        var failure = !rewritesSucceeded
        for alert in plan.alerts {
            guard revision == syncRevision else { return }
            let replacing = retained.contains(alert.identifier)
            guard !replacing || (alert.repeatsEveryMinute && !repeatingRequests.contains(alert.identifier)) else { continue }
            let trigger = alert.repeatsEveryMinute ? NotificationRequestFactory.minuteRepeatTrigger(firstFire: alert.date) : nil
            if alert.repeatsEveryMinute && trigger == nil {
                canQueueMinuteRepeats = false
                enqueueSync()
                return
            }
            // A one-slot swap gives iOS the replacement before retiring the old
            // generation. When adding a new reminder, only shed a redundant nag.
            let count = pending.count + otherCount
            let canSwap = count == AlertPlan.capacity && pending.contains {
                $0.id == alert.reminder.id && $0.generation != alert.reminder.generation
            }
            if !replacing && count >= AlertPlan.capacity && !canSwap {
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
                let queued = request(for: alert, triggerOverride: trigger)
                try await center.add(queued)
                guard revision == syncRevision else { return }
                if alert.repeatsEveryMinute {
                    let confirmed = await center.pendingNotificationRequests().contains {
                        $0.identifier == alert.identifier && $0.trigger?.repeats == true
                    }
                    guard revision == syncRevision else { return }
                    guard confirmed else {
                        canQueueMinuteRepeats = false
                        enqueueSync()
                        return
                    }
                    repeatingRequests.insert(alert.identifier)
                }
                if !NotificationRequestFactory.isSoundOnly(queued.content),
                   !recordAcceptedAnchor(queued.identifier) { failure = true; break }
            } catch {
                guard revision == syncRevision else { return }
                if alert.repeatsEveryMinute {
                    canQueueMinuteRepeats = false
                    enqueueSync()
                    return
                }
                failure = true
                break
            }
            guard revision == syncRevision, source != nil else { return }
            if !replacing, let added = PendingNudge(alert.identifier) { pending.append(added) }
            retained.insert(alert.identifier)
            replacements.insert(alert.reminder.id)
            retireSuperseded()
        }
        guard revision == syncRevision else { return }
        await updateDeliveryStatus(revision: revision, failed: failure)
        guard revision == syncRevision else { return }
        if failure || plan.unscheduledFirstAlerts > 0 {
            schedulingIssue = "Some alerts could not be queued. Check your reminders before closing Nudge."
        } else if repeatingMinuteIDs.count < minuteReminders.count {
            schedulingIssue = "iOS couldn’t queue a repeating one-minute alert. Individual alerts are scheduled instead."
        } else {
            schedulingIssue = nil
            phaseRetry?.cancel()
            retryBudget.reset()
        }
        recordUpdate(stage: failure ? "standard schedule failed" : "standard schedule checked",
            message: schedulingIssue ?? "Standard notification scheduling completed.", failure: failure || plan.unscheduledFirstAlerts > 0)
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

    private func retryPhaseSync(after delay: Double = 3) {
        guard retryBudget.consume() else {
            schedulingIssue = "Automatic retries stopped. Your reminder changes are saved. Tap Retry alerts to try again."
                + (PreservedNotificationSchedule.hasJournal ? " Some alerts may be paused until recovery completes." : "")
            status = schedulingIssue!
            recordUpdate(stage: "automatic retries exhausted", message: schedulingIssue!)
            return
        }
        phaseRetry?.cancel()
        phaseRetry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.enqueueSync()
        }
    }

    private func reconcileHourlyNagSchedule(requests: [UNNotificationRequest], revision: Int, waits: Int = 0) async -> Bool {
        let wantsHourly = reminders.contains { $0.completedAt == nil && $0.preferences.notifications && HourlyNagCadence(minutes: $0.preferences.nagMinutes) != nil && $0.hasValidSchedule }
        guard (wantsHourly && PreservedNotificationSchedule.available)
                || requests.contains(where: HourlyNagSchedule.isPhase) || PreservedNotificationSchedule.hasJournal else { return false }
        var selectedRoute = "schedule planning"
        do {
            guard PreservedNotificationSchedule.available else {
                throw PreservedNotificationSchedule.Problem(message: "iOS cannot update the continuous nag schedule. Existing notifications were kept.")
            }
            guard loadDatabase() else { return true }
            let now = Date.now
            let current = Dictionary(uniqueKeysWithValues: reminders.map { ($0.id, $0) })
            // Recovery never replays stale generations blindly. Rebuild from the
            // readable database, using saved records only to retain accepted timing.
            let saved = try PreservedNotificationSchedule.recoveryRequests().filter { request in
                if request.trigger?.repeats == true { return true }
                if let stamp = request.content.userInfo[NagDelivery.scheduledKey] as? Double { return stamp > now.timeIntervalSince1970 }
                return true
            }
            var keys = Set<String>()
            let pool = (requests + saved).filter { request in
                let phase = request.content.userInfo[HourlyNagSchedule.phaseKey].map { String(describing: $0) } ?? "single"
                return keys.insert(request.identifier + ":" + phase).inserted
            }
            let grouped = Dictionary(grouping: pool.filter(HourlyNagSchedule.isPhase), by: \.identifier)
            let existingIDs = Set(grouped.keys.compactMap { PendingNudge($0)?.id })
            let preserved = pool.filter { request in
                guard let parsed = PendingNudge(request.identifier) else { return true }
                if parsed.canRetire(current: current, deletedIDs: snapshot.deletedIDs, queuedReplacement: [],
                                    stoppedGenerations: snapshot.stoppedNotificationGenerations ?? [],
                                    isRepeating: request.trigger?.repeats == true, now: now) { return false }
                // Missing database rows are not permission to delete notifications.
                return current[parsed.id] == nil || current[parsed.id]?.hasValidSchedule == false
            }
            guard preserved.count <= AlertPlan.capacity else { throw PreservedNotificationSchedule.Problem(message: "Existing notifications fill the available schedule. They were kept.") }
            let allocation = HourlyNagAllocation(reminders: reminders, now: now,
                capacity: AlertPlan.capacity - preserved.count, existingIDs: existingIDs)
            let minuteIDs = Set(reminders.filter { $0.preferences.nagMinutes == 1 }.map(\.id))
            let remaining = reminders.filter { !allocation.repeatingIDs.contains($0.id) }
            let plan = AlertPlan(reminders: remaining, now: now,
                capacity: max(0, AlertPlan.capacity - preserved.count - allocation.phaseSlots),
                repeatingMinuteIDs: minuteIDs)
            var desired = try preserved.map(PreservedNotificationSchedule.absolute)
            for alert in plan.alerts {
                if alert.repeatsEveryMinute {
                    if let existing = pool.first(where: { $0.identifier == alert.identifier && $0.trigger?.repeats == true && !HourlyNagSchedule.isPhase($0) }) {
                        desired.append(existing)
                    } else {
                        guard let trigger = NotificationRequestFactory.minuteRepeatTrigger(firstFire: alert.date) else { throw PreservedNotificationSchedule.Problem(message: "A one-minute repeating alert could not be prepared. Existing alerts were kept.") }
                        desired.append(request(for: alert, triggerOverride: trigger))
                    }
                } else {
                    desired.append(try PreservedNotificationSchedule.absolute(request(for: alert)))
                }
            }
            for reminder in reminders where allocation.repeatingIDs.contains(reminder.id) {
                guard let cadence = HourlyNagCadence(minutes: reminder.preferences.nagMinutes) else { continue }
                let id = ScheduledAlert(reminder: reminder, index: 0, date: reminder.alertDate).identifier
                let existing = grouped[id] ?? []
                if validHourlyNagGroup(existing, reminder: reminder) {
                    desired += existing
                    continue
                }
                guard let first = AlertPlan(reminders: [reminder], now: now, capacity: 1).alerts.first?.date else { continue }
                for (phase, date) in cadence.phaseDates(first: first).enumerated() {
                    guard let trigger = NotificationRequestFactory.hourlyRepeatTrigger(firstFire: date),
                          let retainedDate = PreservedNotificationSchedule.firstDate(trigger), abs(retainedDate.timeIntervalSince(date)) < 0.1,
                          PreservedNotificationSchedule.repeatUnit(trigger) == UInt64(NSCalendar.Unit.hour.rawValue) else {
                        throw PreservedNotificationSchedule.Problem(message: "A repeating phase could not be prepared. Existing alerts were kept.")
                    }
                    let alert = ScheduledAlert(reminder: reminder, index: 0, date: date)
                    let base = request(for: alert, triggerOverride: trigger)
                    let content = base.content.mutableCopy() as! UNMutableNotificationContent
                    content.userInfo[HourlyNagSchedule.phaseKey] = phase
                    content.userInfo[HourlyNagSchedule.minutesKey] = cadence.minutes
                    content.userInfo[HourlyNagSchedule.anchorKey] = first.timeIntervalSince1970
                    desired.append(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
                }
            }
            // Preserve a superseded generation if its replacement has not fit.
            // Refuse the entire update instead of silently dropping that last alert.
            let replacementIDs = Set(desired.compactMap { PendingNudge($0.identifier)?.id })
            let unrepresented = pool.filter { request in
                guard let parsed = PendingNudge(request.identifier), let reminder = current[parsed.id],
                      reminder.generation != parsed.generation || !replacementIDs.contains(parsed.id) else { return false }
                if request.trigger?.repeats != true,
                   let stamp = request.content.userInfo[NagDelivery.scheduledKey] as? Double, stamp <= now.timeIntervalSince1970 { return false }
                return !parsed.canRetire(current: current, deletedIDs: snapshot.deletedIDs, queuedReplacement: replacementIDs,
                    stoppedGenerations: snapshot.stoppedNotificationGenerations ?? [], isRepeating: request.trigger?.repeats == true, now: now)
            }
            guard unrepresented.isEmpty else { throw PreservedNotificationSchedule.Problem(message: "There is not enough room for a replacement alert. The existing schedule was kept.") }
            guard revision == syncRevision, loadDatabase() else { return true }
            // Compare interval requests by their persisted absolute due time, not
            // nextTriggerDate(), which would restart their countdown.
            let comparable = try requests.map(PreservedNotificationSchedule.absolute)
            if !HourlyNagSchedule.matches(comparable, desired) || PreservedNotificationSchedule.hasJournal {
                // Reuse raw OS objects for unchanged requests. The bulk path
                // needs absolute dates, but re-adding those unrelated requests
                // is unnecessary when just one minute-repeat changes.
                var unused = Array(requests.indices)
                let narrowDesired = desired.map { candidate -> UNNotificationRequest in
                    guard let match = unused.firstIndex(where: {
                        HourlyNagSchedule.matches([comparable[$0]], [candidate])
                    }) else { return candidate }
                    return requests[unused.remove(at: match)]
                }
                let narrowPlan = !PreservedNotificationSchedule.hasJournal
                    && !PreservedNotificationSchedule.inProgress && Date.now >= PreservedNotificationSchedule.retryAfter
                    ? MinuteScheduleReplacement.plan(actual: requests, desired: narrowDesired, reminders: reminders) : nil
                if let narrowPlan {
                    recordUpdate(stage: narrowPlan.replacementAlreadyAccepted ? "minute retirement retry" : "minute replacement", message: "Updating one reminder; pending=\(requests.count); desired=\(narrowDesired.count)")
                    // Once started, never fall through to a global rebuild on
                    // failure or supersession. The serial retry reads afresh.
                    selectedRoute = narrowPlan.replacementAlreadyAccepted ? "minute retirement retry" : "minute replacement"
                    let outcome = try await MinuteScheduleReplacement.apply(narrowPlan, center: center,
                        isCurrent: { self.syncRevision == revision })
                    guard outcome == .applied else { return true }
                } else {
                    let reason = PreservedNotificationSchedule.hasJournal ? "saved recovery transaction"
                        : PreservedNotificationSchedule.inProgress ? "update in progress"
                        : Date.now < PreservedNotificationSchedule.retryAfter ? "callback cooldown"
                        : "change does not qualify for a scoped minute replacement"
                    recordUpdate(stage: "protected schedule route", message: reason,
                        details: HourlyNagSchedule.mismatchDescription(actual: requests, expected: narrowDesired) ?? "Pending schedule already matches; recovery still needs finalization.")
                    // A newly-created reminder due in the next few seconds must not
                    // miss its first alert while the preservation transaction waits.
                    // Install that first alert normally, then arm the repeat phases
                    // after delivery. Both use the same action/card identifier.
                    let imminent = desired.filter { candidate in
                        (candidate.content.userInfo[HourlyNagSchedule.phaseKey] as? Int == 0 || candidate.trigger?.repeats == false)
                            && !requests.contains(where: { old in old.identifier == candidate.identifier })
                    }
                    for first in imminent {
                        let planned = (first.content.userInfo[NagDelivery.scheduledKey] as? Double).map(Date.init(timeIntervalSince1970:))
                        guard let date = PreservedNotificationSchedule.firstDate(first.trigger) ?? planned,
                              date > .now, date.timeIntervalSinceNow < 8 else { continue }
                        let content = first.content.mutableCopy() as! UNMutableNotificationContent
                        content.userInfo.removeValue(forKey: HourlyNagSchedule.phaseKey)
                        content.userInfo.removeValue(forKey: HourlyNagSchedule.anchorKey)
                        content.userInfo.removeValue(forKey: HourlyNagSchedule.minutesKey)
                        let parts = Calendar.autoupdatingCurrent.dateComponents([.era, .year, .month, .day, .hour, .minute, .second], from: date)
                        try await center.add(UNNotificationRequest(identifier: first.identifier, content: content,
                            trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
                        schedulingIssue = "The first alert is queued. Keep the app open briefly while continuous nags are prepared."
                        status = schedulingIssue!
                        try await Task.sleep(nanoseconds: 3_000_000_000)
                        guard revision == syncRevision else { return true }
                        return await reconcileHourlyNagSchedule(requests: await center.pendingNotificationRequests(), revision: revision, waits: waits + 1)
                    }
                    if PreservedNotificationSchedule.nearDelivery(requests) || Date.now < PreservedNotificationSchedule.retryAfter {
                        schedulingIssue = "An alert is arriving or iOS is finishing an update. Keep the app open while the schedule is updated."
                        status = schedulingIssue!
                        if waits < 5 {
                            try await Task.sleep(nanoseconds: 3_000_000_000)
                            guard revision == syncRevision else { return true }
                            return await reconcileHourlyNagSchedule(requests: await center.pendingNotificationRequests(), revision: revision, waits: waits + 1)
                        }
                        retryPhaseSync()
                        return true
                    }
                    selectedRoute = "protected schedule"
                    try await PreservedNotificationSchedule.apply(desired, original: requests)
                }
            }
            guard revision == syncRevision else { return true }
            // Migration may leave finite-queue cards for this SAME occurrence
            // under old numeric indices. Retire those only after the new group
            // is confirmed. Never remove another reminder's cards here.
            let delivered = await center.deliveredNotifications()
            guard revision == syncRevision else { return true }
            let obsoleteCards = delivered.compactMap { card -> String? in
                guard let parsed = PendingNudge(card.request.identifier),
                      allocation.repeatingIDs.contains(parsed.id), current[parsed.id]?.generation == parsed.generation,
                      parsed.index != 0 else { return nil }
                return parsed.identifier
            }
            if !obsoleteCards.isEmpty { center.removeDeliveredNotifications(withIdentifiers: obsoleteCards) }
            recordUpdate(stage: "schedule verified", message: "Pending schedule and delivered-card checks completed. Saved recovery: \(PreservedNotificationSchedule.hasJournal)")
            phaseRetry?.cancel(); retryBudget.reset()
            let continuous = allocation.repeatingIDs.count
            deliveryStatus = "\(continuous) continuous 2/5/10/15/20/30-minute reminders. \(desired.count) scheduled entries."
            if allocation.fallbackCount > 0 || plan.unscheduledFirstAlerts > 0 {
                schedulingIssue = "Notification space is limited. \(allocation.fallbackCount) reminders use a limited alert queue instead of continuous nags. \(plan.unscheduledFirstAlerts) first alerts could not fit."
            } else { schedulingIssue = nil }
            status = schedulingIssue ?? "Alerts queued. 2/5/10/15/20/30-minute nags reuse one notification per reminder."
            return true
        } catch {
            let narrowDetails = (error as? MinuteScheduleReplacement.Problem)?.details
            let stage = selectedRoute == "protected schedule" ? PreservedNotificationSchedule.lastAttemptStage : selectedRoute
            recordUpdate(stage: stage, message: error.localizedDescription,
                details: "revision=\(revision); currentRevision=\(syncRevision); recoveryPending=\(PreservedNotificationSchedule.hasJournal)\n"
                    + (narrowDetails ?? (selectedRoute == "protected schedule" ? PreservedNotificationSchedule.latestVerificationDetails : nil) ?? "No pending-array mismatch was recorded for this stage."), failure: true)
            guard revision == syncRevision else { return true }
            schedulingIssue = error.localizedDescription
            if PreservedNotificationSchedule.hasJournal { schedulingIssue! += " Some alerts may be paused until recovery completes." }
            status = schedulingIssue!
            retryPhaseSync(after: max(3, PreservedNotificationSchedule.retryAfter.timeIntervalSinceNow + 1))
            return true
        }
    }

    private func validHourlyNagGroup(_ group: [UNNotificationRequest], reminder: Reminder) -> Bool {
        guard let cadence = HourlyNagCadence(minutes: reminder.preferences.nagMinutes),
              group.count == cadence.phaseCount, let anchor = group.first?.content.userInfo[HourlyNagSchedule.anchorKey] as? Double,
              anchor.isFinite else { return false }
        var phases = Set<Int>()
        return group.allSatisfy { request in
            guard let phase = request.content.userInfo[HourlyNagSchedule.phaseKey] as? Int,
                  (0..<cadence.phaseCount).contains(phase), phases.insert(phase).inserted,
                  HourlyNagSchedule.recordedMinutes(request.content) == cadence.minutes,
                  request.content.userInfo[HourlyNagSchedule.anchorKey] as? Double == anchor,
                  request.content.title == reminder.title, request.content.body == reminder.notes,
                  request.trigger?.repeats == true,
                  PreservedNotificationSchedule.repeatUnit(request.trigger) == UInt64(NSCalendar.Unit.hour.rawValue),
                  let actual = PreservedNotificationSchedule.firstDate(request.trigger) else { return false }
            return abs(actual.timeIntervalSince1970 - (anchor + Double(phase * cadence.minutes * 60))) < 0.1
        }
    }

    private func request(for alert: ScheduledAlert, triggerOverride: UNNotificationTrigger? = nil) -> UNNotificationRequest {
        // The first accepted alert can establish its anchor while this plan's
        // remaining alerts still contain older copies of the reminder.
        var latest = alert
        if let reminder = reminders.first(where: { $0.id == alert.reminder.id && $0.generation == alert.reminder.generation }) {
            latest.reminder = reminder
        }
        return NotificationRequestFactory.make(for: latest, soundOnlyEnabled: soundOnlyEnabled,
                                               triggerOverride: triggerOverride)
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
        let byID = Dictionary(requests.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        // An accepted repeat stays anchored to the date already held by iOS.
        let oneShots = requests.filter { $0.trigger?.repeats != true }
        let alerts = NagDelivery.rewritableAlerts(pending: oneShots.compactMap { PendingNudge($0.identifier) },
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

    private func recordUpdate(stage: String, message: String, details: String = "", failure: Bool = false) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        updateLog.record(stage: stage, message: message, details: details, failure: failure,
                         version: "\(version) (\(build))")
        // Diagnostic storage is separate from reminders and never changes the
        // scheduling result. Keep the in-memory report if persistence fails.
        if let data = try? JSONEncoder().encode(updateLog) {
            UserDefaults.standard.set(data, forKey: Self.updateLogKey)
        }
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
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        var lines = ["App \(version) (\(build)) · iOS \(UIDevice.current.systemVersion)",
                     "Captured: \(time(.now))", "Sound-only nags: \(soundOnlyEnabled ? "ON" : "OFF")",
                     "Pending API records: \(pending.count) · Delivered API records: \(delivered.count)",
                     "API records are not a count of visible Lock Screen cards. Check the screen directly.",
                     "Read-only snapshot; no notification removal requested."]
        lines.append("Repeating phase records: \(pending.filter(HourlyNagSchedule.isPhase).count). Recovery pending: \(PreservedNotificationSchedule.hasJournal). \(schedulingIssue ?? "")")
        lines.append("Automatic retries used: \(retryBudget.attempts)/\(retryBudget.maximum). Update running: \(isUpdatingNotifications).")
        lines.append("SAVED UPDATE HISTORY\n" + updateLog.report)
        lines.append("CURRENT PENDING SNAPSHOT\n" + PreservedNotificationSchedule.requestDetails(pending))
        if let details = PreservedNotificationSchedule.latestVerificationDetails {
            lines.append("Last unverified schedule:\n\(details)")
        }
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
