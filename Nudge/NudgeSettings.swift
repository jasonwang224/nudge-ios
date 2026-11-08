import SwiftUI
import UIKit

@MainActor
struct NudgeSettings: View {
    @ObservedObject var store: ReminderStore
    @Binding var appearance: NudgeAppearance
    let palette: NudgePalette
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                NudgeHeading(eyebrow: "Make it yours", title: "Settings",
                             subtitle: "A good default makes all the difference.",
                             icon: "slider.horizontal.3", palette: palette)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your usual, every time.").font(.headline)
                    Text("These defaults apply to new reminders. You can adjust them for each reminder.")
                        .font(.subheadline).foregroundStyle(palette.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(15)
                .nudgePanel(palette, fill: palette.sage)
                PreferenceFields(preferences: $store.defaults, palette: palette)
                VStack(alignment: .leading, spacing: 12) {
                    Label("APPEARANCE", systemImage: "moon")
                        .font(.caption.weight(.semibold)).tracking(0.8)
                    Picker("Appearance", selection: $appearance) {
                        ForEach(NudgeAppearance.allCases) { style in Text(style.rawValue).tag(style) }
                    }.pickerStyle(.segmented)
                }
                .padding(15).nudgePanel(palette)
                notificationCard
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .foregroundStyle(palette.ink)
        .background(palette.paper.ignoresSafeArea())
    }

    private var notificationCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("LOCK SCREEN", systemImage: "lock")
                .font(.caption.weight(.semibold)).tracking(0.8)
            if store.isScheduling {
                HStack {
                    ProgressView()
                    Text("Scheduling with iOS…").font(.footnote)
                }
            } else {
                Text(store.status).font(.footnote).foregroundStyle(palette.secondary)
            }
            if store.needsSettings {
                Button("Open iPhone notification settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
                .frame(minHeight: 44, alignment: .leading)
            } else {
                Button("Send a test alert in 30 seconds") { store.scheduleTest() }
                    .disabled(store.isScheduling)
                    .frame(minHeight: 44, alignment: .leading)
                Text("The test adds a reminder that nudges every 2 minutes. Wait for the queue confirmation before locking your iPhone.")
                    .font(.footnote).foregroundStyle(palette.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .nudgePanel(palette)
    }
}
