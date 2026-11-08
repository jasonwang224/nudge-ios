import SwiftUI
import UIKit

@MainActor
struct NudgeSettings: View {
    @ObservedObject var store: ReminderStore
    @Binding var appearance: NudgeAppearance
    let palette: NudgePalette
    @Environment(\.openURL) private var openURL
    @State private var showingPreview = false

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
        .sheet(isPresented: $showingPreview) {
            NudgeNotificationPreview(preferences: store.defaults, palette: palette)
        }
    }

    private var notificationCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("LOCK SCREEN", systemImage: "lock")
                .font(.caption.weight(.semibold)).tracking(0.8)
            Button { showingPreview = true } label: {
                Label("Preview a notification", systemImage: "bell")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }.buttonStyle(.plain).foregroundStyle(palette.accent)
            Divider().overlay(palette.line)
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

@MainActor
private struct NudgeNotificationPreview: View {
    let preferences: ReminderPreferences
    let palette: NudgePalette
    @Environment(\.dismiss) private var dismiss
    @State private var result: String?
    @State private var soundPreview = NudgeSoundPreview()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 3) {
                        Text(Date.now, format: .dateTime.weekday(.wide).month(.wide).day())
                            .font(.headline).foregroundStyle(palette.green)
                        Text(Date.now, style: .time)
                            .font(.system(size: 54, weight: .light)).monospacedDigit()
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        Label("NUDGE", systemImage: "bell.badge")
                            .font(.caption.weight(.semibold)).tracking(1)
                            .foregroundStyle(palette.accent)
                        Text("Take a little breather").font(.headline)
                        Text("A moment to stretch, get some water, or just breathe.")
                            .font(.subheadline).foregroundStyle(palette.secondary)
                        if let result {
                            Text(result).font(.subheadline.weight(.semibold)).foregroundStyle(palette.green)
                            Button("Try again") {
                                self.result = nil
                                soundPreview.play(preferences.sound)
                            }
                            .frame(minHeight: 44)
                        } else {
                            HStack(spacing: 10) {
                                Button("Done") { result = "Sample marked as done." }
                                Button("Snooze 15 min") { result = "Sample snoozed for 15 minutes." }
                            }.buttonStyle(.bordered)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .nudgePanel(palette)
                    Text("Try either action on this sample. Your saved reminders are separate.")
                        .font(.footnote).foregroundStyle(palette.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
            }
            .foregroundStyle(palette.ink)
            .background(palette.sage.ignoresSafeArea())
            .navigationTitle("Notification preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .onAppear { soundPreview.play(preferences.sound) }
    }
}
