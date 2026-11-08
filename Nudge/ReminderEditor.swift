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
    @State private var didSave = false
    @FocusState private var timeFocused: Bool

    init(store: ReminderStore, reminder: Reminder?, initialDay: Date? = nil) {
        self.store = store
        original = reminder
        let now = Date.now
        let date = reminder?.due ?? initialDay ?? now
        let calendar = reminder.flatMap {
            $0.phoneSchedule?.resolvedCalendar(relativeTo: $0.due)
        } ?? Calendar.autoupdatingCurrent
        let components = calendar.dateComponents([.hour, .minute], from: reminder?.due ?? now)
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
                    .disabled(didSave)
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
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).fontWeight(.semibold).disabled(didSave)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    if timeFocused {
                        Spacer()
                        Button("Done") { timeFocused = false }
                    }
                }
            }
        }
    }

    private var scheduleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("WHEN", systemImage: "clock").font(.caption.weight(.semibold)).tracking(1)
                .foregroundStyle(palette.secondary)
            HStack(spacing: 12) {
                TextField("Time", text: $time)
                    .keyboardType(.numberPad)
                    .focused($timeFocused)
                    .font(.largeTitle.weight(.medium).monospacedDigit())
                    .accessibilityLabel("Reminder time")
                Picker("AM or PM", selection: $isPM) {
                    Text("AM").tag(false)
                    Text("PM").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 116)
            }
            Text("Enter 830 for 8:30.")
                .font(.footnote)
                .foregroundStyle(palette.secondary)
            DatePicker("Date", selection: $day, displayedComponents: .date)
                .font(.subheadline)
            TimelineView(.periodic(from: .now, by: 15)) { context in
                HStack(spacing: 6) {
                    dateShortcut(0, now: context.date)
                    dateShortcut(1, now: context.date)
                    dateShortcut(3, now: context.date)
                }
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
                    if schedule.prefersSecondOccurrence == true {
                        Text("Using the later occurrence of this repeated clock time.")
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
    private func dateShortcut(_ days: Int, now: Date) -> some View {
        let calendar = Calendar.autoupdatingCurrent
        if let date = ReminderEditorDraft.shortcutDate(days: days, now: now, calendar: calendar) {
            let name = days == 0 ? "Today" : days == 1 ? "Tomorrow" : date.formatted(.dateTime.weekday(.wide))
            Button(name) {
                // A tap at midnight must use the current day even if the next
                // label refresh has not happened. Never move the draft by itself.
                if let currentDate = ReminderEditorDraft.shortcutDate(days: days, now: .now) {
                    day = currentDate
                }
            }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(calendar.isDate(day, inSameDayAs: date) ? palette.accent : palette.secondary)
        }
    }

    private var parsedSchedule: PhoneSchedule? {
        ReminderEditorDraft.schedule(time: time, day: day, isPM: isPM, original: original)
    }

    private func save() {
        guard !didSave else { return }
        do {
            let reminder = try ReminderEditorDraft.reminder(original: original, title: title, notes: notes,
                                                           day: day, time: time, isPM: isPM, preferences: preferences)
            if let message = store.save(reminder, replacing: original?.generation, expecting: original) {
                error = message
                return
            }
            didSave = true
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
