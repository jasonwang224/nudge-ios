import SwiftUI

@MainActor
struct ReminderEditor: View {
    let store: ReminderStore
    let original: Reminder?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    private var palette: NudgePalette { NudgePalette(scheme: scheme) }
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
        let date = reminder?.due ?? .now
        let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: date)
        let hour = reminder?.phoneSchedule?.hour ?? components.hour ?? 9
        let minute = reminder?.phoneSchedule?.minute ?? components.minute ?? 0
        _title = State(initialValue: reminder?.title ?? "")
        _notes = State(initialValue: reminder?.notes ?? "")
        _day = State(initialValue: date)
        _time = State(initialValue: reminder == nil
                      ? "" : String(format: "%d:%02d", hour % 12 == 0 ? 12 : hour % 12, minute))
        _isPM = State(initialValue: hour >= 12)
        _preferences = State(initialValue: reminder?.preferences ?? store.defaults)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("What’s on your mind?", text: $title)
                            .font(.title2.weight(.semibold))
                            .accessibilityLabel("Reminder title")
                        Divider().overlay(palette.line)
                        TextField("A little note, if you like", text: $notes, axis: .vertical)
                            .font(.subheadline)
                            .lineLimit(1...4)
                            .accessibilityLabel("Reminder note")
                    }
                    .padding(16)
                    .nudgePanel(palette)
                    scheduleCard
                    PreferenceFields(preferences: $preferences, palette: palette)
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.subheadline).foregroundStyle(palette.accent)
                            .accessibilityIdentifier("reminder-error")
                    }
                    Button(action: save) {
                        Label(original == nil ? "Create reminder" : "Save changes", systemImage: "checkmark")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 15))
                    if original == nil {
                        Label("Starting with your saved defaults.", systemImage: "slider.horizontal.3")
                            .font(.footnote).foregroundStyle(palette.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(18)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(palette.paper.ignoresSafeArea())
            .foregroundStyle(palette.ink)
            .navigationTitle(original == nil ? "New reminder" : "Edit reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(palette.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).fontWeight(.semibold) }
            }
        }
    }

    private var scheduleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("WHEN", systemImage: "clock").font(.caption.weight(.semibold)).tracking(1)
                .foregroundStyle(palette.secondary)
            HStack(spacing: 12) {
                TextField("Time", text: $time).keyboardType(.numbersAndPunctuation)
                    .font(.largeTitle.weight(.medium).monospacedDigit())
                    .accessibilityLabel("Reminder time")
                Picker("AM or PM", selection: $isPM) {
                    Text("AM").tag(false)
                    Text("PM").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 116)
            }
            DatePicker("Date", selection: $day, displayedComponents: .date)
                .font(.subheadline)
            HStack(spacing: 6) {
                dateShortcut(0)
                dateShortcut(1)
                dateShortcut(3)
            }
            if let schedule = parsedSchedule, let date = schedule.dueDate() {
                let local = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: date)
                VStack(alignment: .leading, spacing: 4) {
                    Label(date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.accent)
                    Text(scheduleSummary).font(.footnote).foregroundStyle(palette.secondary)
                    if local.hour != schedule.hour || local.minute != schedule.minute {
                        Text("The clock skips that time on this date. Nudge will use the next available time.")
                            .font(.footnote).foregroundStyle(palette.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(palette.canvas, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(16)
        .nudgePanel(palette)
    }

    private var scheduleSummary: String {
        let alerts: String
        if !preferences.notifications { alerts = "Notifications off" }
        else if preferences.nagMinutes == 0 { alerts = "One notification" }
        else { alerts = "Nudges every \(preferences.nagMinutes) min" }
        if preferences.repeatRule == .never { return alerts }
        return alerts + " · " + preferences.repeatRule.rawValue
    }

    @ViewBuilder
    private func dateShortcut(_ days: Int) -> some View {
        let calendar = Calendar.autoupdatingCurrent
        if let date = calendar.date(byAdding: .day, value: days, to: .now) {
            let name = days == 0 ? "Today" : days == 1 ? "Tomorrow" : date.formatted(.dateTime.weekday(.wide))
            Button(name) { day = date }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(calendar.isDate(day, inSameDayAs: date) ? palette.accent : palette.secondary)
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
        guard !time.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "Enter a reminder time."
            return
        }
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
        if let message = store.save(reminder, replacing: original?.generation) {
            error = message
            return
        }
        dismiss()
    }
}
