import SwiftUI
import UIKit
import UserNotifications
import ObjectiveC

private let expectedBundle = "com.jasonwang224.nudge.cardpreservationprobe"
private let categoryID = "CARD_PRESERVATION_PROBE"
private let doneID = "CARD_DONE"
private let snoozeID = "CARD_SNOOZE"
private let tokenKey = "cardProbeToken"
private let firstKey = "cardProbeFirstFire"
private let prefix = "card-probe."

private enum Bridge {
    typealias LegacyFactory = @convention(c) (
        AnyObject, Selector, NSDate, NSTimeZone?, UInt64, NSCalendar?
    ) -> Unmanaged<AnyObject>?
    typealias Reply = @convention(block) (NSError?) -> Void
    typealias BulkSetter = @convention(c) (AnyObject, Selector, NSArray, Reply) -> Void
    typealias ObjectGetter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
    typealias IntegerGetter = @convention(c) (AnyObject, Selector) -> UInt64

    static let legacySelector = NSSelectorFromString("triggerWithDate:timeZone:repeatInterval:repeatCalendar:")
    static let bulkSelector = NSSelectorFromString("setNotificationRequests:completionHandler:")

    static var isolated: Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        return id == expectedBundle || id.hasPrefix(expectedBundle + ".")
    }

    static func hourly(first: Date) -> UNNotificationTrigger? {
        guard let cls = NSClassFromString("UNLegacyNotificationTrigger"),
              let method = class_getClassMethod(cls, legacySelector),
              method_getNumberOfArguments(method) == 6 else { return nil }
        let factory = unsafeBitCast(method_getImplementation(method), to: LegacyFactory.self)
        let object = factory(cls as AnyObject, legacySelector, first as NSDate,
                             nil, UInt64(NSCalendar.Unit.hour.rawValue), nil)
        guard let trigger = object?.takeUnretainedValue() as? UNNotificationTrigger,
              trigger.repeats else { return nil }
        return trigger
    }

    static func firstDate(_ trigger: UNNotificationTrigger?) -> Date? {
        guard let trigger, let cls = object_getClass(trigger),
              let method = class_getInstanceMethod(cls, NSSelectorFromString("date")),
              method_getNumberOfArguments(method) == 2 else { return nil }
        let getter = unsafeBitCast(method_getImplementation(method), to: ObjectGetter.self)
        return (getter(trigger, NSSelectorFromString("date"))?.takeUnretainedValue() as? NSDate) as Date?
    }

    static func unit(_ trigger: UNNotificationTrigger?) -> UInt64? {
        guard let trigger, let cls = object_getClass(trigger),
              let method = class_getInstanceMethod(cls, NSSelectorFromString("repeatInterval")),
              method_getNumberOfArguments(method) == 2 else { return nil }
        let getter = unsafeBitCast(method_getImplementation(method), to: IntegerGetter.self)
        return getter(trigger, NSSelectorFromString("repeatInterval"))
    }

    static func available(on center: UNUserNotificationCenter) -> Bool {
        guard isolated, let cls = object_getClass(center),
              let method = class_getInstanceMethod(cls, bulkSelector) else { return false }
        return method_getNumberOfArguments(method) == 4
    }

    static func submit(_ requests: [UNNotificationRequest], center: UNUserNotificationCenter,
                       completion: @escaping (String?) -> Void) {
        guard isolated, available(on: center), let cls = object_getClass(center),
              let method = class_getInstanceMethod(cls, bulkSelector) else {
            completion("Bulk scheduling is unavailable, or the app identifier is not isolated.")
            return
        }
        let setter = unsafeBitCast(method_getImplementation(method), to: BulkSetter.self)
        let reply: Reply = { error in completion(error?.localizedDescription) }
        setter(center, bulkSelector, requests as NSArray, reply)
    }
}

private extension Bridge {
    // Public nextTriggerDate is exposed on concrete public trigger classes, not the base class.
    // Legacy hourly estimates use the same local minute/second pattern used by this probe.
    // This is a near-due guard, not proof of the server's delivery timing or DST behavior.
    static func estimatedNext(_ trigger: UNNotificationTrigger?) -> Date? {
        if let calendar = trigger as? UNCalendarNotificationTrigger { return calendar.nextTriggerDate() }
        guard unit(trigger) == UInt64(NSCalendar.Unit.hour.rawValue), let first = firstDate(trigger) else { return nil }
        let now = Date.now
        if first > now { return first }
        return Calendar.current.nextDate(after: now,
            matching: Calendar.current.dateComponents([.minute, .second], from: first),
            matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
    }
    typealias ContentSetter = @convention(c) (AnyObject, Selector, NSString, UNNotificationContent, Reply) -> Void
    static let contentSelector = NSSelectorFromString("replaceContentForRequestWithIdentifier:replacementContent:completionHandler:")
    static var canProtect: Bool {
        guard isolated, let cls = object_getClass(UNUserNotificationCenter.current()),
              let method = class_getInstanceMethod(cls, contentSelector) else { return false }
        return method_getNumberOfArguments(method) == 5
    }
    static func protect(_ card: UNNotification, completion: @escaping (String?) -> Void) {
        let center = UNUserNotificationCenter.current()
        guard canProtect, let cls = object_getClass(center),
              let method = class_getInstanceMethod(cls, contentSelector) else {
            completion("Content-only replacement is unavailable."); return
        }
        let setter = unsafeBitCast(method_getImplementation(method), to: ContentSetter.self)
        let reply: Reply = { completion($0?.localizedDescription) }
        setter(center, contentSelector, card.request.identifier as NSString, card.request.content, reply)
    }
}

// Keep timeout failures explicit. Never follow an uncertain callback with a destructive fallback.
@MainActor private final class ReplyWaiter {
    private var continuation: CheckedContinuation<String?, Never>?
    func wait(_ operation: (@escaping (String?) -> Void) -> Void) async -> String? {
        await withCheckedContinuation { pending in
            continuation = pending
            operation { message in Task { @MainActor in self.finish(message) } }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self.finish("No reply within five seconds. Setup is incomplete; no automatic fallback was attempted.")
            }
        }
    }
    private func finish(_ message: String?) {
        let pending = continuation; continuation = nil; pending?.resume(returning: message)
    }
}

private struct ProbeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct Journal: Codable {
    let original: Data
    let desired: Data
    let created: Date
    let retireIDs: [String]
    static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("card-probe-transaction.json")
    }
    static func archive(_ requests: [UNNotificationRequest]) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: requests, requiringSecureCoding: true)
    }
    func requests() throws -> [UNNotificationRequest] {
        guard let value = try NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSArray.self, UNNotificationRequest.self], from: desired) as? [UNNotificationRequest],
              !value.isEmpty, value.count <= 60,
              value.allSatisfy({ $0.identifier.hasPrefix(prefix) }) else {
            throw ProbeError(message: "The recovery schedule could not be validated.")
        }
        return value
    }
    static func save(original: [UNNotificationRequest], desired: [UNNotificationRequest], retireIDs: [String]) throws {
        let record = Journal(original: try archive(original), desired: try archive(desired), created: .now, retireIDs: retireIDs)
        let data = try JSONEncoder().encode(record)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        // Exercise secure decoding before any pending schedules are paused.
        let restored = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: url)).requests()
        guard schedulesMatch(restored, desired) else { throw ProbeError(message: "Recovery archive did not round-trip.") }
    }
}

// Multiset comparison deliberately preserves duplicate request identifiers (one per phase).
private func schedulesMatch(_ actual: [UNNotificationRequest], _ expected: [UNNotificationRequest]) -> Bool {
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

@MainActor private final class Probe: ObservableObject {
    static let shared = Probe()
    private let center = UNUserNotificationCenter.current()
    private let seedKey = "cardProbeSeeded"
    private let logKey = "cardProbeLog"
    @Published private(set) var busy = false
    @Published private(set) var status = "First create the sample cards, then install five-minute nags."
    @Published private(set) var details = ""
    @Published private(set) var times = ""
    @Published private(set) var seeded = false
    @Published private(set) var activeNag = false
    @Published private(set) var needsRecovery = false
    private var log: String { UserDefaults.standard.string(forKey: logKey) ?? "" }
    private var nagID: String? { UserDefaults.standard.string(forKey: tokenKey) }
    private init() { }

    private func note(_ message: String) {
        let entry = Date.now.formatted(date: .omitted, time: .standard) + " " + message
        UserDefaults.standard.set(String((log + "\n" + entry).suffix(24000)), forKey: logKey)
    }
    private func fail(_ message: String) { status = message; note("FAILED: " + message) }
    private func ready() throws {
        guard Bridge.isolated else { throw ProbeError(message: "Wrong bundle identifier. All notification operations are disabled.") }
        guard Bridge.available(on: center), Bridge.canProtect else {
            throw ProbeError(message: "The required private scheduling or content-update method is unavailable.")
        }
    }
    private func content(_ title: String, body: String, role: String) -> UNMutableNotificationContent {
        let value = UNMutableNotificationContent()
        value.title = title; value.body = body; value.sound = .default
        // Distinct threads make A, B, C and the nag easier to inspect in expanded notifications.
        value.threadIdentifier = prefix + role
        value.userInfo = ["role": role]
        return value
    }
    private func calendar(_ date: Date) -> UNCalendarNotificationTrigger {
        UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date), repeats: false)
    }
    func seed() async {
        guard !busy, Bridge.isolated else { return }
        busy = true; defer { busy = false }
        do {
            try ready()
            guard !FileManager.default.fileExists(atPath: Journal.url.path) else { throw ProbeError(message: "Finish or reset the interrupted test first.") }
            let pending = await center.pendingNotificationRequests()
            let delivered = await center.deliveredNotifications()
            guard pending.isEmpty, delivered.isEmpty else { throw ProbeError(message: "Sample records already exist. Use Reset only when you want a fresh test.") }
            if await center.notificationSettings().authorizationStatus == .notDetermined {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
            }
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized, settings.lockScreenSetting == .enabled, settings.soundSetting == .enabled else {
                throw ProbeError(message: "Enable notifications, Lock Screen and Sounds for Card Guard Probe in iPhone Settings.")
            }
            let base = Date(timeIntervalSince1970: ceil(Date.now.timeIntervalSince1970))
            guard let hourly = Bridge.hourly(first: base.addingTimeInterval(60)) else { throw ProbeError(message: "Hourly trigger unavailable.") }
            let samples = [
                UNNotificationRequest(identifier: prefix + "A", content: content("Keep A - one-time reminder", body: "This original card should survive setup. Leave it here.", role: "A"), trigger: calendar(base.addingTimeInterval(45))),
                UNNotificationRequest(identifier: prefix + "B", content: content("Keep B - hourly reminder", body: "This card AND its hourly schedule should survive.", role: "B"), trigger: hourly),
                UNNotificationRequest(identifier: prefix + "C", content: content("Dismiss C - optional check", body: "Swipe away ONLY this card before step 2. It should not return.", role: "C"), trigger: calendar(base.addingTimeInterval(75))),
                UNNotificationRequest(identifier: prefix + "D", content: content("Future D - schedule preserved", body: "This was scheduled before five-minute nags were installed.", role: "D"), trigger: calendar(base.addingTimeInterval(15 * 60)))
            ]
            for sample in samples { try await center.add(sample) }
            guard schedulesMatch(await center.pendingNotificationRequests(), samples) else { throw ProbeError(message: "Sample schedule readback did not match. Reset before continuing.") }
            UserDefaults.standard.set(true, forKey: seedKey)
            status = "Lock your phone for 90 seconds. Keep A and B. Optionally dismiss C. Then reopen this app for step 2."
            note("Samples scheduled: A +45s, B +60s (hourly), C +75s, D +15min. Start: \(base.formatted()).")
        } catch { fail(error.localizedDescription) }
        await refresh()
    }

    private func nagRequests(first: Date, id: String) throws -> [UNNotificationRequest] {
        try (0..<12).map { phase in
            let date = first.addingTimeInterval(Double(phase) * 300)
            guard let trigger = Bridge.hourly(first: date),
                  let actual = Bridge.firstDate(trigger), abs(actual.timeIntervalSince(date)) < 0.1,
                  Bridge.unit(trigger) == UInt64(NSCalendar.Unit.hour.rawValue) else { throw ProbeError(message: "Hourly phase validation failed.") }
            let value = content("Five-minute nag", body: "Only this card should refresh. Keep A and B should stay.", role: "nag")
            value.categoryIdentifier = categoryID
            value.userInfo = ["role": "nag", "phase": phase, "first": first.timeIntervalSince1970]
            return UNNotificationRequest(identifier: id, content: value, trigger: trigger)
        }
    }
    func install(recheck: Bool = false) async {
        guard !busy, Bridge.isolated else { return }
        busy = true; defer { busy = false }
        do {
            try ready()
            guard !FileManager.default.fileExists(atPath: Journal.url.path) else { throw ProbeError(message: "An incomplete setup needs recovery or reset first.") }
            let delivered = await center.deliveredNotifications()
            let ids = Set(delivered.map { $0.request.identifier })
            guard ids.contains(prefix + "A"), ids.contains(prefix + "B") else {
                throw ProbeError(message: "A and B must both be delivered before this test. Wait 90 seconds after step 1 and leave those cards in place.")
            }
            let pending = await center.pendingNotificationRequests()
            let desired: [UNNotificationRequest]
            if recheck {
                guard pending.filter({ $0.content.userInfo["role"] as? String == "nag" }).count == 12 else { throw ProbeError(message: "No complete five-minute group to recheck.") }
                desired = pending
            } else {
                guard !pending.contains(where: { $0.content.userInfo["role"] as? String == "nag" }) else { throw ProbeError(message: "Nags already run. Use Repeat preservation check.") }
                let first = Date(timeIntervalSince1970: ceil(Date.now.timeIntervalSince1970 + 90))
                desired = pending + (try nagRequests(first: first, id: prefix + UUID().uuidString))
            }
            try await transact(original: pending, desired: desired)
        } catch { fail(error.localizedDescription) }
        await refresh()
    }

    private func verifyCards(_ before: [UNNotification], _ after: [UNNotification], requireNil: Bool) throws {
        guard before.count == after.count else { throw ProbeError(message: "Delivered card count changed. Aborting; this is not a preservation pass.") }
        for old in before {
            guard let new = after.first(where: { $0.request.identifier == old.request.identifier }),
                  abs(new.date.timeIntervalSince(old.date)) < 0.1,
                  new.request.content.isEqual(old.request.content),
                  !requireNil || new.request.trigger == nil else {
                throw ProbeError(message: "Card \(old.request.content.title) did not retain its content/date with an empty trigger. Bulk setup was not approved by readback.")
            }
        }
    }

    private func transact(original: [UNNotificationRequest], desired: [UNNotificationRequest], recovering: Bool = false, retireIDs: [String] = []) async throws {
        try ready()
        guard !desired.isEmpty, desired.count <= 60,
              (original + desired).allSatisfy({ $0.identifier.hasPrefix(prefix) }),
              retireIDs.allSatisfy({ $0.hasPrefix(prefix) && !desired.map(\.identifier).contains($0) }) else { throw ProbeError(message: "Unexpected notification or capacity. No bulk operation allowed.") }
        // Absolute calendar and legacy dates only. No interval trigger is silently re-anchored.
        for request in original + desired {
            guard let trigger = request.trigger,
                  trigger is UNCalendarNotificationTrigger || Bridge.firstDate(trigger) != nil else {
                throw ProbeError(message: "Unsupported trigger in schedule.")
            }
            if let next = Bridge.estimatedNext(trigger), next.timeIntervalSinceNow < 30 {
                throw ProbeError(message: "An alert is due within 30 seconds. Let it arrive, then try again.")
            }
            if !trigger.repeats && Bridge.estimatedNext(trigger) == nil {
                throw ProbeError(message: "A saved one-time alert is overdue. Reset this isolated test; do not silently replay it.")
            }
        }
        if !recovering { try Journal.save(original: original, desired: desired, retireIDs: retireIDs) }
        // An interruption may leave test alerts paused. The journal is never auto-applied on launch.
        let task = UIApplication.shared.beginBackgroundTask(withName: "Protect probe cards")
        defer { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
        note("Transaction begins. Saved \(original.count) original / \(desired.count) desired records.")
        let baseline = await center.deliveredNotifications()
        guard baseline.allSatisfy({ $0.request.identifier.hasPrefix(prefix) }) else { throw ProbeError(message: "Unexpected delivered notification. Aborted.") }
        center.removePendingNotificationRequests(withIdentifiers: Array(Set(original.map(\.identifier))))
        var empty = false
        for _ in 0..<10 {
            if await center.pendingNotificationRequests().isEmpty { empty = true; break }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        guard empty else { throw ProbeError(message: "Pending queue did not pause. No bulk setup performed.") }
        let before = await center.deliveredNotifications()
        try verifyCards(baseline, before, requireNil: false)
        note("Paused pending queue; protecting \(before.count) delivered cards.")
        for card in before where card.request.trigger != nil {
            if let error = await ReplyWaiter().wait({ Bridge.protect(card, completion: $0) }) { throw ProbeError(message: error) }
        }
        let protected = await center.deliveredNotifications()
        try verifyCards(before, protected, requireNil: true)
        guard await center.pendingNotificationRequests().isEmpty else { throw ProbeError(message: "A content update unexpectedly scheduled a request. No bulk setup performed.") }
        note("All \(protected.count) cards report empty triggers and unchanged content/dates. Submitting merged schedule.")
        if let error = await ReplyWaiter().wait({ Bridge.submit(desired, center: center, completion: $0) }) { throw ProbeError(message: error) }
        var matched = false
        for _ in 0..<6 {
            if schedulesMatch(await center.pendingNotificationRequests(), desired) { matched = true; break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        guard matched else { throw ProbeError(message: "Merged schedule readback failed. Recovery journal kept; no automatic reset.") }
        try verifyCards(before, await center.deliveredNotifications(), requireNil: true)
        if let nag = desired.first(where: { $0.content.userInfo["role"] as? String == "nag" }) {
            UserDefaults.standard.set(nag.identifier, forKey: tokenKey)
        }
        // Only a snoozed nag is retired, after preservation and schedule readback succeed.
        if !retireIDs.isEmpty { center.removeDeliveredNotifications(withIdentifiers: retireIDs) }
        try FileManager.default.removeItem(at: Journal.url)
        status = "API checks passed. Now check the Lock Screen: A and B should still be there, without a new sound or timestamp. This is NOT yet a visual pass."
        note("READBACK PASS: all pending phases and all \(before.count) delivered cards preserved. User must check visible cards.")
    }

    func recover() async {
        guard !busy, Bridge.isolated else { return }
        busy = true; defer { busy = false }
        do {
            let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: Journal.url))
            guard Date.now.timeIntervalSince(journal.created) > 10 else { throw ProbeError(message: "Wait ten seconds after an interrupted operation before retrying.") }
            try await transact(original: await center.pendingNotificationRequests(), desired: journal.requests(), recovering: true, retireIDs: journal.retireIDs)
        } catch { fail(error.localizedDescription) }
        await refresh()
    }

    func respond(action: String, id: String) async {
        guard Bridge.isolated, action == doneID || action == snoozeID else { return }
        while busy { try? await Task.sleep(nanoseconds: 100_000_000) }
        guard nagID == id else { return }
        busy = true; defer { busy = false }
        do {
            guard !FileManager.default.fileExists(atPath: Journal.url.path) else { throw ProbeError(message: "Setup is incomplete. Reopen the probe to recover or reset before using actions.") }
            if action == doneID {
                let others = await center.deliveredNotifications().filter { $0.request.identifier != id }
                center.removePendingNotificationRequests(withIdentifiers: [id])
                center.removeDeliveredNotifications(withIdentifiers: [id])
                try await Task.sleep(nanoseconds: 300_000_000)
                guard !(await center.pendingNotificationRequests()).contains(where: { $0.identifier == id }) else {
                    throw ProbeError(message: "Done cancellation has not been confirmed. Retry Done.")
                }
                try verifyCards(others, await center.deliveredNotifications().filter { $0.request.identifier != id }, requireNil: false)
                UserDefaults.standard.removeObject(forKey: tokenKey)
                status = "Done requested for the nag only. A, B and D are unchanged."
                note(status)
            } else {
                let original = await center.pendingNotificationRequests()
                let first = Date(timeIntervalSince1970: ceil(Date.now.timeIntervalSince1970 + 900))
                let next = try nagRequests(first: first, id: prefix + UUID().uuidString)
                // Preserve every visible card during the transaction, including the old nag.
                // Remove only the old nag card after its replacement schedule is verified.
                try await transact(original: original, desired: original.filter { $0.identifier != id } + next, retireIDs: [id])
                status = "Snoozed for 15 minutes. Check that A and B stayed visible."
                note(status)
            }
        } catch { fail(error.localizedDescription) }
        await refresh()
    }

    func reset() async {
        guard !busy, Bridge.isolated else { return }
        busy = true; defer { busy = false }
        // Explicitly user-confirmed reset, scoped to this separate bundle and prefix.
        for _ in 0..<3 {
            let pending = await center.pendingNotificationRequests()
            let delivered = await center.deliveredNotifications()
            let ids = Set((pending + delivered.map(\.request)).map(\.identifier).filter { $0.hasPrefix(prefix) })
            center.removePendingNotificationRequests(withIdentifiers: Array(ids))
            center.removeDeliveredNotifications(withIdentifiers: Array(ids))
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        try? FileManager.default.removeItem(at: Journal.url)
        UserDefaults.standard.removeObject(forKey: tokenKey)
        UserDefaults.standard.removeObject(forKey: seedKey)
        status = "This probe was reset. The main app was not accessed."
        note(status)
        await refresh()
    }

    func refresh() async {
        guard Bridge.isolated else { details = "Unexpected bundle. Notification access disabled."; return }
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        let settings = await center.notificationSettings()
        seeded = UserDefaults.standard.bool(forKey: seedKey)
        activeNag = pending.contains { $0.content.userInfo["role"] as? String == "nag" }
        needsRecovery = FileManager.default.fileExists(atPath: Journal.url.path)
        if needsRecovery && !busy { status = "Previous setup is incomplete. Test alerts may be paused. Retry setup or reset this probe. Opening the app does not modify notifications." }
        let nag = pending.first { $0.content.userInfo["role"] as? String == "nag" }
        if let first = nag?.content.userInfo["first"] as? Double {
            times = [0, 5, 10, 60, 65].map { "+\($0) min: \(Date(timeIntervalSince1970: first + Double($0) * 60).formatted(date: .omitted, time: .standard))" }.joined(separator: "\n")
        } else { times = "" }
        var lines = ["Card Guard Probe 1.0 (1) / iOS \(UIDevice.current.systemVersion)",
                     "Bundle: \(Bundle.main.bundleIdentifier ?? "?")", "Captured: \(Date.now.formatted())",
                     "Status: \(status)", "Recovery journal: \(needsRecovery)",
                     "Pending: \(pending.count) records / \(Set(pending.map(\.identifier)).count) identifiers; delivered API records: \(delivered.count)",
                     "API counts are NOT visible card counts. Refresh/opening never removes or reschedules alerts.",
                     "Auth \(settings.authorizationStatus.rawValue); lock \(settings.lockScreenSetting.rawValue); sound \(settings.soundSetting.rawValue)"]
        for card in delivered.sorted(by: { $0.date < $1.date }) {
            lines.append("DELIVERED \(card.request.content.title) | \(card.date.formatted()) | trigger \(card.request.trigger.map { String(describing: type(of: $0)) } ?? "EMPTY (protected)") | \(card.request.identifier)")
        }
        for request in pending.sorted(by: { $0.identifier < $1.identifier }) {
            lines.append("PENDING \(request.content.title) | phase \(request.content.userInfo["phase"] ?? "-") | estimated next \(Bridge.estimatedNext(request.trigger)?.formatted() ?? "none") | first \(Bridge.firstDate(request.trigger)?.formatted() ?? "n/a") | repeats \(request.trigger?.repeats == true) | \(request.identifier)")
        }
        details = (lines + ["TRANSACTION LOG", log]).joined(separator: "\n\n")
    }
}

private final class ProbeDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        guard Bridge.isolated else { return true }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(identifier: categoryID, actions: [
            UNNotificationAction(identifier: snoozeID, title: "Snooze 15 min", options: []),
            UNNotificationAction(identifier: doneID, title: "Done", options: [])
        ], intentIdentifiers: [], options: [])])
        return true
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await Probe.shared.respond(action: response.actionIdentifier, id: response.notification.request.identifier)
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

@main @MainActor struct CardPreservationProbeApp: App {
    @UIApplicationDelegateAdaptor(ProbeDelegate.self) private var delegate
    @StateObject private var probe = Probe.shared
    @Environment(\.scenePhase) private var phase
    @State private var confirmReset = false
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List {
                    Section("Separate test - 1.0 (1)") {
                        Text("This probe has its own notifications and data. It cannot access your main app or the original 5 Min Probe.")
                        Text(probe.status).fontWeight(.medium)
                    }
                    Section("1. Put sample cards on the Lock Screen") {
                        Button("Create sample cards") { Task { await probe.seed() } }.disabled(probe.busy || probe.seeded || probe.needsRecovery)
                        Text("Lock your phone for 90 seconds. Keep A and Keep B should arrive. Leave both cards there. Optionally swipe away Dismiss C to check it stays gone.")
                        Text("Future D is due 15 minutes after this step. Keep B repeats hourly. Nothing is cleared when you reopen the probe.").font(.footnote)
                    }
                    Section("2. Protect cards and install nags") {
                        Button("Install 5-minute nags") { Task { await probe.install() } }.disabled(probe.busy || !probe.seeded || probe.activeNag || probe.needsRecovery)
                        Text("Reopen the probe and tap above. Then lock your phone again. A and B should remain with their original times and without sounding again. The new nag starts in 90 seconds.")
                        Text("Expand the notification stack to inspect all cards. The nag should sound every five minutes and reuse one card. A and B must stay; dismissed C must stay gone; Future D should still arrive.")
                        if !probe.times.isEmpty { Text(probe.times).font(.callout.monospacedDigit()) }
                    }
                    Section("3. Check another update") {
                        Button("Repeat preservation check") { Task { await probe.install(recheck: true) } }.disabled(probe.busy || !probe.activeNag || probe.needsRecovery)
                        Text("After two nags, use this to repeat the same protection and scheduling process. All existing cards should remain, including the nag. Then test Snooze and Done on the nag card; A and B should stay.")
                    }
                    if probe.needsRecovery {
                        Section("Incomplete setup") {
                            Text("Only this probe's test alerts may be paused. Retry to finish the saved setup. If it fails again, share diagnostics before resetting.")
                            Button("Retry interrupted setup") { Task { await probe.recover() } }.disabled(probe.busy)
                        }
                    }
                    Section("Diagnostics") {
                        Button("Refresh (read only)") { Task { await probe.refresh() } }.disabled(probe.busy)
                        ShareLink("Share diagnostics", item: probe.details)
                        Text(probe.details).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Section {
                        Button("Reset this probe", role: .destructive) { confirmReset = true }.disabled(probe.busy)
                        Text("Reset removes this probe's sample cards and schedules only. Use it when you finish testing.").font(.footnote)
                    }
                }.navigationTitle("Card Guard Probe")
                    .confirmationDialog("Remove this probe's test cards and schedules?", isPresented: $confirmReset, titleVisibility: .visible) {
                        Button("Reset probe", role: .destructive) { Task { await probe.reset() } }
                        Button("Cancel", role: .cancel) { }
                    }
            }.task(id: phase) { if phase == .active { await probe.refresh() } }
        }
    }
}


