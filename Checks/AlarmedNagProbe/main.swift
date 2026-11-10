import SwiftUI
import UIKit
import UserNotifications

private let probeTokenKey = "alarmedNagProbeToken"
private let probeCategory = "ALARMED_NAG_PROBE"
private let doneAction = "PROBE_DONE"
private let snoozeAction = "PROBE_SNOOZE"

@MainActor
private final class Probe: ObservableObject {
    static let shared = Probe()
    private let center = UNUserNotificationCenter.current()
    @Published private(set) var busy = false
    @Published private(set) var status = "Start the test, then close the app and lock the phone."
    @Published private(set) var details = ""

    func start() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
            }
            let current = await center.notificationSettings()
            guard current.authorizationStatus == .authorized, current.lockScreenSetting == .enabled else {
                status = "Allow notifications and Lock Screen alerts for Nag Probe in iPhone Settings."
                return
            }
        } catch {
            status = error.localizedDescription
            return
        }
        await cancelTest()
        schedule(firstFire: .now.addingTimeInterval(90))
        await refreshDetails()
    }

    func stop() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        await cancelTest()
        status = "Test stopped."
        await refreshDetails()
    }

    func respond(to action: String, token: String) async {
        guard !busy, UserDefaults.standard.string(forKey: probeTokenKey) == token,
              action == doneAction || action == snoozeAction else { return }
        busy = true
        defer { busy = false }
        await cancelTest()
        if action == snoozeAction {
            schedule(firstFire: .now.addingTimeInterval(15 * 60))
        } else {
            status = "Done. The test was stopped."
        }
        await refreshDetails()
    }

    private func schedule(firstFire: Date) {
        let token = UUID().uuidString
        let notification = UILocalNotification()
        notification.alertTitle = "One-minute nag test"
        notification.alertBody = "Leave this card on the Lock Screen for the next nag."
        notification.soundName = UILocalNotificationDefaultSoundName
        notification.category = probeCategory
        notification.userInfo = [probeTokenKey: token]
        notification.fireDate = firstFire
        notification.repeatInterval = .minute
        UserDefaults.standard.set(token, forKey: probeTokenKey)
        UIApplication.shared.scheduleLocalNotification(notification)
        status = "First alert set for " + firstFire.formatted(date: .omitted, time: .standard)
    }

    private func cancelTest() async {
        UserDefaults.standard.removeObject(forKey: probeTokenKey)
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.filter {
            $0.content.userInfo[probeTokenKey] is String
        }.map(\.identifier))
        // Also cancel any tagged record visible through the original UIKit API.
        for notification in UIApplication.shared.scheduledLocalNotifications ?? []
            where notification.userInfo?[probeTokenKey] is String {
            UIApplication.shared.cancelLocalNotification(notification)
        }
        let delivered = await center.deliveredNotifications()
        center.removeDeliveredNotifications(withIdentifiers: delivered.filter {
            $0.request.content.userInfo[probeTokenKey] is String
        }.map(\.request.identifier))
    }

    func refreshDetails() async {
        let pending = await center.pendingNotificationRequests().filter {
            $0.content.userInfo[probeTokenKey] is String
        }
        let delivered = await center.deliveredNotifications().filter {
            $0.request.content.userInfo[probeTokenKey] is String
        }
        let legacyCount = (UIApplication.shared.scheduledLocalNotifications ?? []).filter {
            $0.userInfo?[probeTokenKey] is String
        }.count
        let lines = pending.map { request in
            let trigger = request.trigger.map { String(describing: type(of: $0)) } ?? "none"
            return "Pending \(trigger), repeats \(request.trigger?.repeats == true)\n\(request.identifier)"
        } + delivered.map { notification in
            "Delivered \(notification.date.formatted(date: .omitted, time: .standard))\n\(notification.request.identifier)"
        }
        details = (["Pending \(pending.count) • UIKit \(legacyCount) • Delivered \(delivered.count)"] + lines)
            .joined(separator: "\n\n")
    }
}

private final class ProbeDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: probeCategory, actions: [
                UNNotificationAction(identifier: doneAction, title: "Done", options: []),
                UNNotificationAction(identifier: snoozeAction, title: "Snooze 15 min", options: [])
            ], intentIdentifiers: [], options: [])
        ])
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                             didReceive response: UNNotificationResponse) async {
        guard let token = response.notification.request.content.userInfo[probeTokenKey] as? String else { return }
        await Probe.shared.respond(to: response.actionIdentifier, token: token)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                             willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

@main
@MainActor
struct AlarmedNagProbeApp: App {
    @UIApplicationDelegateAdaptor(ProbeDelegate.self) private var delegate
    @StateObject private var probe = Probe.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List {
                    Section("Lock Screen test") {
                        Text(probe.status)
                        Button("Start in 90 seconds") { Task { await probe.start() } }
                        Button("Stop test", role: .destructive) { Task { await probe.stop() } }
                    }
                    .disabled(probe.busy)
                    Section("iOS notification records") {
                        Button("Refresh") { Task { await probe.refreshDetails() } }
                        Text(probe.details).font(.footnote.monospaced()).textSelection(.enabled)
                        Text("Compare these records with the cards you actually see on the Lock Screen.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("Nag Probe")
            }
            .task(id: scenePhase) {
                if scenePhase == .active { await probe.refreshDetails() }
            }
        }
    }
}
