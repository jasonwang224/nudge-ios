import SwiftUI
import UIKit

@MainActor
struct NudgeSettings: View {
    @ObservedObject var store: ReminderStore
    @Binding var appearance: NudgeAppearance
    let palette: NudgePalette
    @Environment(\.openURL) private var openURL
    @State private var showingPreview = false
    @State private var showingDiagnostics = false

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
                soundOnlyCard
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .foregroundStyle(palette.ink)
        .background(palette.paper.ignoresSafeArea())
        .sheet(isPresented: $showingPreview) {
            NudgeNotificationPreview(preferences: store.defaults, palette: palette)
        }
        .sheet(isPresented: $showingDiagnostics) {
            NavigationStack {
                ScrollView {
                    Text(store.notificationDiagnostics).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
                }
                .navigationTitle("Notification diagnostics")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { showingDiagnostics = false } }
                    ToolbarItem(placement: .primaryAction) { ShareLink(item: store.notificationDiagnostics) }
                }
                .task { await store.refreshNotificationDiagnostics() }
            }
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

    private var soundOnlyCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("SOUND-ONLY NAG TEST", systemImage: "speaker.wave.2")
                .font(.caption.weight(.semibold)).tracking(0.8)
            Toggle("Sound-only nags", isOn: Binding(
                get: { store.soundOnlyEnabled }, set: { store.setSoundOnlyNags($0) }
            )).disabled(store.isScheduling)
            Text("Keep the first reminder with Done and Snooze. Later nags play your chosen sound without requesting another card. The original timestamp stays the same.")
                .font(.footnote).foregroundStyle(palette.secondary)
            Text("For existing reminders, edit and save or Snooze to apply this mode. Reminders set to Silent still show normal nag cards. Sound and vibration follow your iPhone settings.")
                .font(.footnote).foregroundStyle(palette.secondary)
            Text(store.deliveryStatus).font(.footnote).foregroundStyle(palette.secondary)
            Divider().overlay(palette.line)
            Button("Start a 2-minute test") { store.scheduleTest(nagMinutes: 2) }
                .disabled(store.isScheduling || store.needsSettings).frame(minHeight: 44)
            Button("Start a 5-minute test") { store.scheduleTest(nagMinutes: 5) }
                .disabled(store.isScheduling || store.needsSettings).frame(minHeight: 44)
            Text("Finish the previous test first. These tests use Chime and start in 30 seconds. Wait for scheduling, close Nudge, and lock your iPhone. After three sounds, check for one original card, then try Snooze and Done.")
                .font(.footnote).foregroundStyle(palette.secondary)
            Text("If you swipe away the original card, later sounds won't bring it back. Open Nudge to snooze or complete the reminder.")
                .font(.footnote).foregroundStyle(palette.secondary)
            Button("Read notification diagnostics") { showingDiagnostics = true }
                .frame(minHeight: 44)
            Text("Diagnostics show iOS records, not a count of cards visible on your Lock Screen.")
                .font(.caption).foregroundStyle(palette.secondary)
            Text("Nudge 1.0.6 · Build 8").font(.caption).foregroundStyle(palette.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15).nudgePanel(palette)
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
