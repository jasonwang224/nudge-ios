import SwiftUI
import UIKit

@MainActor
struct NudgeHome: View {
    @ObservedObject var store: ReminderStore
    @Environment(\.openURL) private var openURL
    @State private var editor: EditorItem?

    private struct EditorItem: Identifiable {
        var id = UUID()
        var reminder: Reminder?
    }

    var body: some View {
        TabView {
            remindersTab(todayOnly: true)
                .tabItem { Label("Today", systemImage: "sun.max") }
            remindersTab(todayOnly: false)
                .tabItem { Label("Upcoming", systemImage: "calendar") }
            settings
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .sheet(item: $editor) { item in
            ReminderEditor(store: store, reminder: item.reminder)
        }
    }

    private func remindersTab(todayOnly: Bool) -> some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                let now = context.date
                let active = store.reminders.filter { $0.completedAt == nil }.sorted { $0.alertDate < $1.alertDate }
                let snoozed = active.filter { $0.snoozedUntil != nil && $0.alertDate > now }
                let due = active.filter { $0.alertDate <= now }
                let scheduled = active.filter { reminder in
                    guard reminder.alertDate > now else { return false }
                    if !todayOnly { return true }
                    return reminder.snoozedUntil == nil && Calendar.autoupdatingCurrent.isDate(reminder.due, inSameDayAs: now)
                }
                List {
                    if todayOnly {
                        testSection
                        reminderSection("Needs attention", items: due, now: now)
                        reminderSection("Snoozed", items: snoozed, now: now)
                    }
                    reminderSection(todayOnly ? "Today" : "Scheduled", items: scheduled, now: now)
                    if scheduled.isEmpty && (!todayOnly || (due.isEmpty && snoozed.isEmpty)) {
                        ContentUnavailableView("You're all caught up", systemImage: "checkmark.circle",
                                               description: Text("Tap + to add a reminder."))
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .navigationTitle(todayOnly ? "Today" : "Upcoming")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editor = EditorItem() } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New reminder")
                }
            }
        }
    }

    private var testSection: some View {
        Section {
            Button { store.scheduleTest() } label: {
                Label("Test in 30 seconds", systemImage: "bell.badge")
                    .font(.headline)
            }
            .disabled(store.isScheduling)
            notificationStatus
        } header: {
            Text("Lock Screen test")
        } footer: {
            Text("The test nudges every 2 minutes. Wait for the queue confirmation, then close Nudge and lock your iPhone.")
        }
    }

    @ViewBuilder
    private var notificationStatus: some View {
        if store.isScheduling {
            HStack {
                ProgressView()
                Text("Scheduling with iOS…")
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(store.status).font(.footnote).foregroundStyle(.secondary)
        }
        if store.needsSettings {
            Button("Open iPhone notification settings") {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
            }
        }
    }

    @ViewBuilder
    private func reminderSection(_ title: String, items: [Reminder], now: Date) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { reminder in
                    HStack(spacing: 14) {
                        Button { store.done(reminder) } label: {
                            Image(systemName: "circle").font(.title3)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Done, \(reminder.title)")
                        Button {
                            editor = EditorItem(reminder: reminder)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(reminder.title).font(.headline).foregroundStyle(.primary)
                                if let snoozed = reminder.snoozedUntil, snoozed > now {
                                    Text("Snoozed until \(snoozed.formatted(date: .omitted, time: .shortened))")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                } else {
                                    Text(reminder.due, format: .dateTime.weekday(.abbreviated).hour().minute())
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Delete", role: .destructive) { store.delete(reminder) }
                        Button("Snooze") { store.snooze(reminder) }.tint(.indigo)
                    }
                }
            }
        }
    }

    private var settings: some View {
        NavigationStack {
            Form {
                Section("iPhone notifications") {
                    notificationStatus
                    Button("Enable notifications") { store.enableNotifications() }
                        .disabled(store.isScheduling)
                    LabeledContent("Vibration", value: "iPhone settings")
                    LabeledContent("Snooze", value: "15 minutes")
                }
                PreferenceFields(preferences: $store.defaults)
                Section("Test build") {
                    Text("iOS queues up to \(AlertPlan.capacity) alerts for this build. Nudge tops up the queue when it opens or handles a notification action.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

private struct PreferenceFields: View {
    @Binding var preferences: ReminderPreferences

    var body: some View {
        Section("Alert options") {
            Toggle("Notifications", isOn: $preferences.notifications)
            Picker("Nag me", selection: $preferences.nagMinutes) {
                ForEach(ReminderPreferences.nagIntervals, id: \.self) { minutes in
                    Text(minutes == 0 ? "Off" : "Every \(minutes) min").tag(minutes)
                }
            }
            Picker("Sound", selection: $preferences.sound) {
                ForEach(AlertSound.allCases) { sound in Text(sound.rawValue).tag(sound) }
            }
        }
        Section("Repeat") {
            Picker("Repeat", selection: $preferences.repeatRule) {
                ForEach(RepeatRule.allCases) { rule in Text(rule.rawValue).tag(rule) }
            }
            if preferences.repeatRule == .custom {
                ForEach(1...7, id: \.self) { day in
                    Toggle(Calendar.autoupdatingCurrent.weekdaySymbols[day - 1], isOn: Binding(
                        get: { preferences.weekdays.contains(day) },
                        set: { on in
                            if on { preferences.weekdays.insert(day) }
                            else { preferences.weekdays.remove(day) }
                        }
                    ))
                }
            }
        }
    }
}

@MainActor
private struct ReminderEditor: View {
    let store: ReminderStore
    let original: Reminder?
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var notes: String
    @State private var day: Date
    @State private var time: String
    @State private var isPM: Bool
    @State private var preferences: ReminderPreferences
    @State private var error: String?

    init(store: ReminderStore, reminder: Reminder?) {
        self.store = store
        original = reminder
        let date = reminder?.due ?? Date().addingTimeInterval(5 * 60)
        let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: date)
        let hour = reminder?.phoneSchedule?.hour ?? components.hour ?? 9
        let minute = reminder?.phoneSchedule?.minute ?? components.minute ?? 0
        _title = State(initialValue: reminder?.title ?? "")
        _notes = State(initialValue: reminder?.notes ?? "")
        _day = State(initialValue: date)
        _time = State(initialValue: String(format: "%d:%02d", hour % 12 == 0 ? 12 : hour % 12, minute))
        _isPM = State(initialValue: hour >= 12)
        _preferences = State(initialValue: reminder?.preferences ?? store.defaults)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Reminder") {
                    TextField("Title", text: $title)
                    TextField("Note", text: $notes)
                }
                Section("When") {
                    DatePicker("Date", selection: $day, displayedComponents: .date)
                    HStack {
                        dateShortcut(0)
                        dateShortcut(1)
                        dateShortcut(3)
                    }
                    HStack {
                        TextField("8:30", text: $time).keyboardType(.numbersAndPunctuation)
                            .accessibilityLabel("Reminder time")
                        Picker("AM or PM", selection: $isPM) {
                            Text("AM").tag(false)
                            Text("PM").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 120)
                    }
                    if let schedule = parsedSchedule, let date = schedule.dueDate() {
                        LabeledContent("Scheduled", value: date.formatted(date: .abbreviated, time: .shortened))
                        let local = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: date)
                        if local.hour != schedule.hour || local.minute != schedule.minute {
                            Text("The clock skips that time on this date. Nudge will use the next available time.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                PreferenceFields(preferences: $preferences)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(original == nil ? "New reminder" : "Edit reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).fontWeight(.semibold) }
            }
        }
    }

    @ViewBuilder
    private func dateShortcut(_ days: Int) -> some View {
        let calendar = Calendar.autoupdatingCurrent
        if let date = calendar.date(byAdding: .day, value: days, to: .now) {
            let name = days == 0 ? "Today" : days == 1 ? "Tomorrow" : date.formatted(.dateTime.weekday(.wide))
            Button(name) { day = date }
                .buttonStyle(.bordered)
                .tint(calendar.isDate(day, inSameDayAs: date) ? .accentColor : .secondary)
        }
    }

    private var parsedSchedule: PhoneSchedule? {
        let input = time.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = input.split(separator: ":", omittingEmptySubsequences: false)
        let hour: Int?
        let minute: Int?
        if parts.count == 2, parts.allSatisfy({ (1...2).contains($0.count) }) {
            hour = Int(parts[0])
            minute = Int(parts[1])
        } else if parts.count == 1 && (3...4).contains(input.count) {
            hour = Int(input.dropLast(2))
            minute = Int(input.suffix(2))
        } else if parts.count == 1 && (1...2).contains(input.count) {
            hour = Int(input)
            minute = 0
        } else {
            return nil
        }
        guard let hour, let minute, (1...12).contains(hour), (0...59).contains(minute) else { return nil }
        return PhoneSchedule(day: day, hour: hour % 12 + (isPM ? 12 : 0), minute: minute)
    }

    private func save() {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { error = "Enter a reminder title."; return }
        guard var schedule = parsedSchedule, let date = schedule.dueDate() else {
            error = "Enter a valid time, such as 8:30 or 830."
            return
        }
        guard preferences.repeatRule != .custom || !preferences.weekdays.isEmpty else {
            error = "Choose at least one repeat day."
            return
        }
        let previous = original?.phoneSchedule
        let sameClock = previous?.day == schedule.day && previous?.hour == schedule.hour && previous?.minute == schedule.minute
        let sameTestMinute = previous == nil && original.map {
            Calendar.autoupdatingCurrent.isDate($0.due, equalTo: date, toGranularity: .minute)
        } == true
        guard sameClock || sameTestMinute || date > .now else { error = "Choose a future date and time."; return }
        if sameClock, let previous { schedule.anchorDay = previous.anchorDay }
        var reminder = original ?? Reminder(title: name, notes: notes, due: date,
                                             repeatAnchor: date, preferences: preferences)
        reminder.title = name
        reminder.notes = notes
        reminder.due = sameTestMinute ? (original?.due ?? date) : date
        reminder.phoneSchedule = sameTestMinute ? nil : schedule
        reminder.preferences = preferences
        store.save(reminder)
        dismiss()
    }
}
