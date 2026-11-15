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
    @State private var pickingDate = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var timeFocused: Bool

    init(store: ReminderStore, reminder: Reminder?, initialDay: Date? = nil) {
        self.store = store
        original = reminder
        let now = Date.now
        let date = reminder?.occurrenceDue ?? initialDay ?? now
        let calendar = reminder.flatMap {
            $0.phoneSchedule?.resolvedCalendar(relativeTo: $0.due)
        } ?? Calendar.autoupdatingCurrent
        let components = calendar.dateComponents([.hour, .minute], from: reminder?.occurrenceDue ?? now)
        let schedule = reminder?.adjustedDue == nil ? reminder?.phoneSchedule : nil
        let hour = schedule?.hour ?? components.hour ?? 9
        let minute = schedule?.minute ?? components.minute ?? 0
        _title = State(initialValue: reminder?.title ?? "")
        _notes = State(initialValue: reminder?.notes ?? "")
        _day = State(initialValue: date)
        _time = State(initialValue: reminder == nil
                      ? "" : String(format: "%d:%02d", hour % 12 == 0 ? 12 : hour % 12, minute))
        _isPM = State(initialValue: hour >= 12)
        var initialPreferences = reminder?.preferences ?? store.defaults
        initialPreferences.notifications = true
        _preferences = State(initialValue: initialPreferences)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("What would you like to remember?")
                            .font(.caption).foregroundStyle(palette.secondary)
                        TextField("Reminder name", text: $title, axis: .vertical)
                            .font(.title2.weight(.medium)).lineLimit(1...3)
                            .accessibilityLabel("Reminder title")
                        Divider().overlay(palette.line)
                    }
                    scheduleCard
                    PreferenceFields(preferences: $preferences, palette: palette)
                    VStack(spacing: 12) {
                        TextField("Add a note (optional)", text: $notes, axis: .vertical)
                            .font(.subheadline).lineLimit(1...4)
                            .accessibilityLabel("Reminder note")
                        Divider().overlay(palette.line)
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.subheadline).foregroundStyle(palette.accent)
                            .accessibilityIdentifier("reminder-error")
                    }
                }
                .padding(20)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button(action: save) {
                    Text(original == nil ? "Save reminder" : "Save changes")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .foregroundStyle(canSave ? (palette.scheme == .dark ? palette.canvas : .white) : palette.secondary)
                        .background(canSave ? palette.accent : palette.canvas,
                                    in: RoundedRectangle(cornerRadius: 17))
                }
                .buttonStyle(.plain).disabled(!canSave)
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(palette.paper)
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
                ToolbarItemGroup(placement: .keyboard) {
                    if timeFocused {
                        Spacer()
                        Button("Done") {
                            time = ReminderEditorDraft.formattedTime(time) ?? time
                            timeFocused = false
                        }
                    }
                }
            }
            .sheet(isPresented: $pickingDate) {
                NavigationStack {
                    DatePicker("Reminder date", selection: $day, displayedComponents: .date)
                        .datePickerStyle(.graphical).padding()
                        .background(palette.paper)
                        .navigationTitle("Choose date").navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { pickingDate = false }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
                .tint(palette.accent)
            }
        }
    }

    private var canSave: Bool {
        !didSave && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && ReminderEditorDraft.formattedTime(time) != nil
            && (preferences.repeatRule != .custom || !preferences.weekdays.isEmpty)
    }

    private var scheduleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Time").font(.subheadline.weight(.semibold))
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(spacing: 12))
            layout {
                TextField("– – : – –", text: $time)
                    .keyboardType(.numberPad)
                    .focused($timeFocused)
                    .font(.largeTitle.weight(.medium).monospacedDigit())
                    .accessibilityLabel("Reminder time")
                Picker("AM or PM", selection: $isPM) {
                    Text("AM").tag(false)
                    Text("PM").tag(true)
                }
                .pickerStyle(.segmented).frame(width: 116)
            }
            Text("Enter a time, like 300 for 3:00.")
                .font(.caption).foregroundStyle(palette.secondary)
            HStack {
                Text("Date").font(.subheadline.weight(.semibold))
                Spacer()
                Button { timeFocused = false; pickingDate = true } label: {
                    Label(day.formatted(.dateTime.month(.abbreviated).day()), systemImage: "calendar")
                        .font(.subheadline)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain).foregroundStyle(palette.accent)
                .accessibilityLabel("Choose date, " + day.formatted(date: .complete, time: .omitted))
            }
            .padding(.top, 8)
            TimelineView(.periodic(from: .now, by: 15)) { context in
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(spacing: 6))
                    : AnyLayout(HStackLayout(spacing: 6))
                layout {
                    dateShortcut(0, now: context.date)
                    dateShortcut(1, now: context.date)
                    dateShortcut(3, now: context.date)
                }
            }
            if let schedule = parsedSchedule, let date = schedule.dueDate() {
                let local = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: date)
                VStack(alignment: .leading, spacing: 4) {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption.weight(.medium)).foregroundStyle(palette.accent)
                    Text(scheduleSummary).font(.caption).foregroundStyle(palette.secondary)
                    if local.hour != schedule.hour || local.minute != schedule.minute {
                        Text("The clock skips that time on this date. The app will use the next available time.")
                            .font(.footnote).foregroundStyle(palette.secondary)
                    }
                    if schedule.prefersSecondOccurrence == true {
                        Text("Using the later occurrence of this repeated clock time.")
                            .font(.footnote).foregroundStyle(palette.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
        }
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
            let selected = calendar.isDate(day, inSameDayAs: date)
            Button {
                // Resolve from the phone clock at tap time, including midnight.
                if let currentDate = ReminderEditorDraft.shortcutDate(days: days, now: .now) {
                    day = currentDate
                }
            } label: {
                VStack(spacing: 5) {
                    Text(name).font(.caption.weight(.medium))
                    Text(date, format: .dateTime.month(.abbreviated).day()).font(.caption2)
                }
                .foregroundStyle(selected ? palette.paper : palette.ink)
                .frame(maxWidth: .infinity, minHeight: 56)
                .padding(.horizontal, 3)
                .background(selected ? palette.ink : palette.canvas, in: RoundedRectangle(cornerRadius: 13))
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
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
