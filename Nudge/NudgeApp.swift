import SwiftUI
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let done = UNNotificationAction(identifier: ReminderStore.doneAction, title: "Done", options: [])
        let snooze = UNNotificationAction(identifier: ReminderStore.snoozeAction, title: "Snooze 15 min", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: ReminderStore.category,
                                   actions: [done, snooze], intentIdentifiers: [], options: [])
        ])
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                             didReceive response: UNNotificationResponse) async {
        let time = Date()
        let payload = response.notification.request.content.userInfo
        guard let id = payload["id"] as? String, let generation = payload["generation"] as? String else { return }
        let action = response.actionIdentifier
        await ReminderStore.shared.handleAction(action, id: id, generation: generation, at: time)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                             willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        if !ExpirationExperiment.enabled,
           let incoming = DeliveredNudge(identifier: notification.request.identifier, date: notification.date) {
            await Self.trimDeliveredNags(in: center, incoming: incoming)
        }
        return [.banner, .list, .sound]
    }

    nonisolated static func trimDeliveredNags(in center: UNUserNotificationCenter, incoming: DeliveredNudge? = nil) async {
        let delivered = await center.deliveredNotifications()
        guard !Task.isCancelled else { return }
        let nudges = delivered.compactMap {
            DeliveredNudge(identifier: $0.request.identifier, date: $0.date)
        }
        let obsolete = DeliveredNudge.supersededIdentifiers(in: nudges, by: incoming)
        if !obsolete.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: obsolete)
        }
    }
}

@main
@MainActor
struct NudgeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = ReminderStore.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            NudgeHome(store: store)
                .tint(Color(red: 0.77, green: 0.30, blue: 0.23))
                .task { store.refresh() }
                .task(id: scenePhase) {
                    guard scenePhase == .active, !ExpirationExperiment.enabled else { return }
                    await AppDelegate.trimDeliveredNags(in: .current())
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { store.refresh() }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                    store.refresh()
                }
        }
    }
}
