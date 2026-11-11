import SwiftUI
import UIKit
import UserNotifications
import ObjectiveC

private let expectedBundle = "com.jasonwang224.nudge.fiveminuteprobe"
private let categoryID = "FIVE_MINUTE_PROBE"
private let doneID = "FIVE_DONE"
private let snoozeID = "FIVE_SNOOZE"
private let tokenKey = "fiveMinuteProbeToken"
private let firstKey = "fiveMinuteProbeFirstFire"
private let prefix = "five-minute-probe."

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

@MainActor
private final class Submission {
    private var continuation: CheckedContinuation<String?, Never>?
    func wait(requests: [UNNotificationRequest], center: UNUserNotificationCenter) async -> String? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            Bridge.submit(requests, center: center) { message in
                Task { @MainActor in self.finish(message) }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self.finish("Bulk scheduling did not reply within five seconds.")
            }
        }
    }
    private func finish(_ message: String?) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: message)
    }
}

@MainActor
private final class Probe: ObservableObject {
    static let shared = Probe()
    private let center = UNUserNotificationCenter.current()
    @Published private(set) var busy = false
    @Published private(set) var status = "Start the test, then close this app and lock your phone."
    @Published private(set) var details = ""
    @Published private(set) var expectedTimes = ""

    private init() {
        if UserDefaults.standard.string(forKey: tokenKey) != nil {
            status = "Existing test loaded. Opening this app does not restart or clear it."
        }
    }

    private var token: String? { UserDefaults.standard.string(forKey: tokenKey) }
    private var first: Date? {
        let value = UserDefaults.standard.double(forKey: firstKey)
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }

    func start() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        guard Bridge.isolated else {
            status = "Wrong app identifier. Scheduling and cancellation are disabled."
            return
        }
        do {
            if await center.notificationSettings().authorizationStatus == .notDetermined {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
            }
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized,
                  settings.lockScreenSetting == .enabled,
                  settings.soundSetting == .enabled else {
                status = "Enable notifications, Lock Screen, and Sounds for 5 Min Probe in iPhone Settings."
                await refresh()
                return
            }
            await schedule(after: 90)
        } catch {
            status = "Notification permission failed: " + error.localizedDescription
        }
    }

    private func schedule(after seconds: TimeInterval) async {
        guard Bridge.isolated, Bridge.available(on: center) else {
            status = "This iOS version does not expose the required bulk scheduling method."
            return
        }
        let run = UUID().uuidString
        let firstFire = Date(timeIntervalSince1970: ceil(Date.now.timeIntervalSince1970 + seconds))
        var requests: [UNNotificationRequest] = []
        for phase in 0..<12 {
            let date = firstFire.addingTimeInterval(Double(phase) * 300)
            guard let trigger = Bridge.hourly(first: date),
                  let retainedDate = Bridge.firstDate(trigger),
                  abs(retainedDate.timeIntervalSince(date)) < 0.01,
                  Bridge.unit(trigger) == UInt64(NSCalendar.Unit.hour.rawValue) else {
                status = "The hourly trigger is unavailable or did not retain its first date. Nothing was scheduled."
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Five-minute nag test"
            content.body = "Leave this card here and compare it with the next alert."
            content.sound = .default
            content.categoryIdentifier = categoryID
            content.threadIdentifier = run
            content.userInfo = [tokenKey: run, "phase": phase, "firstFire": date.timeIntervalSince1970]
            requests.append(UNNotificationRequest(identifier: prefix + run, content: content, trigger: trigger))
        }
        // This is an isolated bundle: bulk set can clear only this probe's delivered cards.
        // Do not use this API in the main app's populated notification queue.
        UserDefaults.standard.set(run, forKey: tokenKey)
        UserDefaults.standard.set(firstFire.timeIntervalSince1970, forKey: firstKey)
        status = "Submitting 12 hourly phases with one shared identifier..."
        let reply = await Submission().wait(requests: requests, center: center)
        var validation = "No readback yet."
        for _ in 0..<6 {
            let pending = await center.pendingNotificationRequests()
            validation = validate(pending, run: run, firstFire: firstFire)
            if validation.isEmpty { break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        if reply == nil && validation.isEmpty {
            status = "iOS retained all 12 phases. First alert: \(time(firstFire)). Then every 5 minutes. Lock Screen behavior still needs your test."
        } else {
            let reason = [reply, validation.isEmpty ? nil : validation].compactMap { $0 }.joined(separator: " ")
            await cancelOwned()
            status = "Test could not be armed; cancellation requested for probe alerts. " + reason
        }
        await refresh()
    }

    private func validate(_ records: [UNNotificationRequest], run: String, firstFire: Date) -> String {
        guard records.count == 12 else { return "Expected 12 pending records; iOS returned \(records.count)." }
        var phases = Set<Int>()
        for record in records {
            guard record.identifier == prefix + run,
                  record.content.userInfo[tokenKey] as? String == run,
                  let phase = record.content.userInfo["phase"] as? Int,
                  (0..<12).contains(phase), phases.insert(phase).inserted,
                  record.trigger?.repeats == true,
                  String(describing: type(of: record.trigger!)) == "UNLegacyNotificationTrigger",
                  Bridge.unit(record.trigger) == UInt64(NSCalendar.Unit.hour.rawValue),
                  let actual = Bridge.firstDate(record.trigger),
                  abs(actual.timeIntervalSince(firstFire.addingTimeInterval(Double(phase) * 300))) < 0.1
            else { return "iOS changed, deduplicated, or lost a phase. This batch is not safe to test." }
        }
        return ""
    }

    func stop() async {
        guard !busy, Bridge.isolated else { return }
        busy = true
        defer { busy = false }
        await cancelOwned()
        status = "Stopped. Cancellation requested for this probe only."
        await refresh()
    }

    private func cancelOwned() async {
        guard Bridge.isolated else { return }
        let savedID = token.map { prefix + $0 }
        UserDefaults.standard.removeObject(forKey: tokenKey)
        UserDefaults.standard.removeObject(forKey: firstKey)
        for _ in 0..<3 {
            let pending = await center.pendingNotificationRequests()
            let delivered = await center.deliveredNotifications()
            var ids = Set((pending + delivered.map(\.request)).map(\.identifier).filter { $0.hasPrefix(prefix) })
            if let savedID { ids.insert(savedID) }
            center.removePendingNotificationRequests(withIdentifiers: Array(ids))
            center.removeDeliveredNotifications(withIdentifiers: Array(ids))
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    func respond(action: String, run: String) async {
        guard action == doneID || action == snoozeID else { return }
        while busy { try? await Task.sleep(nanoseconds: 50_000_000) }
        guard Bridge.isolated, token == run else { return }
        busy = true
        defer { busy = false }
        await cancelOwned()
        if action == snoozeID { await schedule(after: 15 * 60) }
        else {
            status = "Done. The five-minute test was stopped."
            await refresh()
        }
    }

    func refresh() async {
        guard Bridge.isolated else {
            details = "Unexpected bundle identifier. Notification access is disabled."
            return
        }
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        let settings = await center.notificationSettings()
        let run = token
        let firstFire = first
        var lines = [
            "5 Min Probe 1.0 (1) · iOS \(UIDevice.current.systemVersion)",
            "Captured: \(Date.now.formatted())",
            "Bundle: \(Bundle.main.bundleIdentifier ?? "unknown")",
            "Pending API records: \(pending.count) · distinct identifiers: \(Set(pending.map(\.identifier)).count)",
            "Delivered API records: \(delivered.count)",
            "API record counts are not visible Lock Screen card counts.",
            "Read-only snapshot. Refresh does not remove or reschedule alerts.",
            "Authorization: \(settings.authorizationStatus.rawValue) · Lock Screen: \(settings.lockScreenSetting.rawValue) · Sound: \(settings.soundSetting.rawValue)"
        ]
        if let run, let firstFire {
            let result = validate(pending, run: run, firstFire: firstFire)
            lines.append(result.isEmpty ? "Readback: 12 matching hourly phases, one identifier." : "Readback: " + result)
            let offsets = [0, 5, 10, 15, 55, 60, 65]
            expectedTimes = offsets.map { "+\($0) min  \(time(firstFire.addingTimeInterval(Double($0) * 60)))" }.joined(separator: "\n")
        } else {
            expectedTimes = ""
            lines.append("No active test token.")
        }
        for record in pending.sorted(by: { (Bridge.firstDate($0.trigger) ?? .distantPast) < (Bridge.firstDate($1.trigger) ?? .distantPast) }) {
            let date = Bridge.firstDate(record.trigger).map(time) ?? "none"
            let phase = (record.content.userInfo["phase"] as? Int).map(String.init) ?? "?"
            let kind = record.trigger.map { String(describing: type(of: $0)) } ?? "none"
            lines.append("PENDING phase \(phase) · first \(date) · \(kind) · repeats \(record.trigger?.repeats == true) · unit \(Bridge.unit(record.trigger).map(String.init) ?? "none")\n\(record.identifier)")
        }
        for notification in delivered.sorted(by: { $0.date < $1.date }) {
            lines.append("DELIVERED \(time(notification.date)) · phase \(notification.request.content.userInfo["phase"] ?? "?")\n\(notification.request.identifier)")
        }
        details = lines.joined(separator: "\n\n")
    }

    private func time(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .standard) }
}

private final class ProbeDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        guard Bridge.isolated else { return true }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: categoryID, actions: [
                UNNotificationAction(identifier: snoozeID, title: "Snooze 15 min", options: []),
                UNNotificationAction(identifier: doneID, title: "Done", options: [])
            ], intentIdentifiers: [], options: [])
        ])
        return true
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let run = response.notification.request.content.userInfo[tokenKey] as? String else { return }
        await Probe.shared.respond(action: response.actionIdentifier, run: run)
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

@main @MainActor
struct FiveMinuteProbeApp: App {
    @UIApplicationDelegateAdaptor(ProbeDelegate.self) private var delegate
    @StateObject private var probe = Probe.shared
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List {
                    Section("Separate test app") {
                        Text("This app has its own notification queue. Your reminders and notifications in the main app are separate.")
                        Text(probe.status)
                        Button("Start in 90 seconds") { Task { await probe.start() } }
                        Button("Stop test", role: .destructive) { Task { await probe.stop() } }
                        Text("Starting again replaces only this probe's test. Stop when finished; repeats otherwise continue.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.disabled(probe.busy)
                    Section("What to check") {
                        Text("After the test is armed, close this app and lock your iPhone. Leave its card in place through at least two more nags. Check whether it stays one card and sounds every five minutes.")
                        Text("For the hourly repeat check, leave it running through +60 and +65 minutes.")
                        if !probe.expectedTimes.isEmpty { Text(probe.expectedTimes).font(.callout.monospacedDigit()) }
                    }
                    Section("Diagnostics") {
                        Button("Refresh read-only snapshot") { Task { await probe.refresh() } }.disabled(probe.busy)
                        ShareLink("Share diagnostics", item: probe.details)
                        Text(probe.details).font(.footnote.monospaced()).textSelection(.enabled)
                    }
                }
                .navigationTitle("5 Min Probe")
            }
            .task(id: scenePhase) {
                if scenePhase == .active { await probe.refresh() }
            }
        }
    }
}
