import SwiftUI
import UIKit

@MainActor
struct NudgeHome: View {
    @ObservedObject var store: ReminderStore
    @Environment(\.colorScheme) private var scheme
    @AppStorage("Nudge.appearance") private var appearance: NudgeAppearance = .system
    @State private var editor: EditorItem?

    private struct EditorItem: Identifiable {
        var id = UUID()
        var reminder: Reminder?
        var initialDay: Date?
    }

    var body: some View {
        let palette = NudgePalette(scheme: scheme)
        TabView {
            agenda(todayOnly: true, palette: palette)
                .tabItem { Label("Today", systemImage: "sun.max") }
            agenda(todayOnly: false, palette: palette)
                .tabItem { Label("Upcoming", systemImage: "calendar") }
            NudgeSettings(store: store, appearance: $appearance, palette: palette)
                .toolbarBackground(palette.paper, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(palette.accent)
        .preferredColorScheme(appearance.scheme)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let issue = store.storageIssue {
                Label(issue, systemImage: "exclamationmark.triangle")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(palette.coral)
            }
        }
        .sheet(item: $editor) { item in
            ReminderEditor(store: store, reminder: item.reminder, initialDay: item.initialDay)
                .tint(palette.accent)
        }
    }

    private func agenda(todayOnly: Bool, palette: NudgePalette) -> some View {
        NudgeAgenda(store: store, todayOnly: todayOnly, palette: palette,
                    newReminder: { editor = EditorItem(initialDay: $0) },
                    editReminder: { editor = EditorItem(reminder: $0) })
            .toolbarBackground(palette.paper, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
    }
}

@MainActor
private struct NudgeAgenda: View {
    @ObservedObject var store: ReminderStore
    let todayOnly: Bool
    let palette: NudgePalette
    let newReminder: (Date?) -> Void
    let editReminder: (Reminder) -> Void
    @Environment(\.openURL) private var openURL
    @State private var selectedDay: Date?
    @State private var showCompleted = false
    @State private var pendingDelete: Reminder?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            agenda(at: context.date)
        }
        .background(palette.paper.ignoresSafeArea())
        .confirmationDialog(pendingDelete.map { $0.completedAt == nil && $0.preferences.repeatRule != .never } == true ? "Delete repeating reminder?" : "Delete reminder?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { reminder in
            Button("Delete", role: .destructive) { store.delete(reminder) }
        } message: { reminder in
            Text(reminder.title)
        }
    }

    private func agenda(at now: Date) -> some View {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: now)
        let presentation = AgendaPresentation(reminders: store.reminders, todayOnly: todayOnly,
                                             selectedDay: selectedDay, now: now, calendar: calendar)
        let viewedDay = presentation.viewedDay
        let isToday = presentation.isToday
        let active = presentation.active
        let completed = presentation.completed
        let visible = presentation.visible
        let due = presentation.due
        let snoozed = presentation.snoozed
        let upcoming = presentation.upcoming

        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                NudgeHeading(eyebrow: (todayOnly ? viewedDay : now).formatted(.dateTime.weekday(.wide).month(.wide).day()),
                             title: todayOnly ? (isToday ? "Hello, today." : viewedDay.formatted(.dateTime.weekday(.wide)) + ".") : "On the horizon.",
                             subtitle: todayOnly ? "A little more headspace starts here." : "A little planning. A lot of peace of mind.",
                             icon: todayOnly ? "sun.max" : "calendar", palette: palette)
                if todayOnly {
                    weekStrip(today: today, viewedDay: viewedDay, active: active, now: now, calendar: calendar)
                    if !isToday && visible.contains(where: \.isProjected) {
                        Text("Planned repeats appear here. Complete or snooze the current reminder from Today.")
                            .font(.footnote).foregroundStyle(palette.secondary)
                    }
                }
                if store.needsSettings {
                    Button {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                    } label: {
                        Label(store.status, systemImage: "bell.slash")
                            .font(.footnote.weight(.medium)).padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .nudgePanel(palette, fill: palette.coral)
                    }
                    .buttonStyle(.plain).foregroundStyle(palette.accent)
                }
                if let issue = store.schedulingIssue, store.storageIssue == nil, !store.needsSettings {
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(palette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .nudgePanel(palette, fill: palette.coral)
                        .accessibilityElement(children: .combine)
                }
                HStack(spacing: 8) {
                    filterButton(todayOnly ? "Reminders" : "Scheduled", count: visible.count, completed: false)
                    filterButton("Completed", count: completed.count, completed: true)
                }
                if showCompleted {
                    if completed.isEmpty { emptyState(completed: true) }
                    else { reminderSection("LOOK AT YOU GO", icon: "checkmark.circle", items: completed.map { ReminderOccurrence($0) }, now: now) }
                } else if visible.isEmpty {
                    emptyState(completed: false)
                } else {
                    reminderSection("Needs attention", icon: "bell.badge", items: due, now: now)
                    reminderSection("Snoozed", icon: "clock", items: snoozed, now: now)
                    if let next = upcoming.first {
                        nextCard(next, now: now)
                    }
                    reminderSection(todayOnly ? "A LITTLE LATER" : "COMING UP", icon: "calendar",
                                    items: Array(upcoming.dropFirst()), now: now)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button { newReminder(todayOnly ? viewedDay : nil) } label: {
                Label("New reminder", systemImage: "plus")
                    .font(.headline)
                    .foregroundStyle(palette.scheme == .dark ? palette.canvas : .white)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(palette.accent, in: RoundedRectangle(cornerRadius: 15))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(palette.paper)
        }
        .foregroundStyle(palette.ink)
    }

    private func weekStrip(today: Date, viewedDay: Date, active: [Reminder], now: Date, calendar: Calendar) -> some View {
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        return HStack(spacing: 5) {
            ForEach(days, id: \.self) { day in
                let selected = calendar.isDate(day, inSameDayAs: viewedDay)
                let hasReminder = !ReminderOccurrence.entries(reminders: active, on: day, now: now, calendar: calendar).isEmpty
                Button {
                    selectedDay = day
                    showCompleted = false
                } label: {
                    VStack(spacing: 5) {
                        Text(String(day.formatted(.dateTime.weekday(.abbreviated)).prefix(1)))
                            .font(.caption)
                        Text(day, format: .dateTime.day()).font(.subheadline.weight(.semibold))
                        Circle().fill(hasReminder ? (selected ? palette.paper : palette.accent) : .clear)
                            .frame(width: 4, height: 4)
                    }
                    .foregroundStyle(selected ? palette.paper : palette.secondary)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(selected ? palette.ink : palette.canvas, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private func filterButton(_ label: String, count: Int, completed: Bool) -> some View {
        let selected = showCompleted == completed
        return Button {
            showCompleted = completed
        } label: {
            HStack(spacing: 5) {
                Text(label).font(.subheadline.weight(selected ? .semibold : .regular))
                Text(count.formatted()).font(.caption.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(selected ? palette.coral : palette.canvas, in: Capsule())
            }
            .foregroundStyle(selected ? palette.ink : palette.secondary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(selected ? palette.surface : palette.paper, in: RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func reminderSection(_ title: String, icon: String, items: [ReminderOccurrence], now: Date) -> some View {
        if !items.isEmpty {
            VStack(spacing: 0) {
                HStack {
                    Label(title, systemImage: icon).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(items.count.formatted()).font(.caption).foregroundStyle(palette.secondary)
                }.padding(13)
                ForEach(items) { reminder in
                    Divider().overlay(palette.line)
                    reminderRow(reminder, now: now)
                }
            }
            .nudgePanel(palette)
        }
    }

    private func reminderRow(_ occurrence: ReminderOccurrence, now: Date) -> some View {
        let reminder = occurrence.reminder
        let completed = reminder.completedAt != nil
        let restoreTitle = reminder.preferences.repeatRule == .never ? "Restore" : "Restore as one-time reminder"
        return HStack(spacing: 6) {
            if occurrence.isProjected {
                Image(systemName: "repeat")
                    .font(.body).foregroundStyle(palette.secondary)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("Planned repeat")
            } else {
                Button {
                    if completed { store.restore(reminder) }
                    else { Task { await store.done(reminder) } }
                } label: {
                    Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(completed ? palette.green : palette.accent)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel((completed ? restoreTitle : "Done") + ", " + reminder.title)
            }
            Button {
                if completed { store.restore(reminder) }
                else { editReminder(reminder) }
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(reminder.title).font(.body.weight(.medium)).foregroundStyle(palette.ink)
                    Text(reminderDetail(occurrence, now: now))
                        .font(.footnote).foregroundStyle(palette.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            reminderMenu(occurrence, now: now)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
    }

    private func reminderDetail(_ occurrence: ReminderOccurrence, now: Date) -> String {
        let reminder = occurrence.reminder
        if occurrence.isProjected {
            return occurrence.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                + " · " + reminder.preferences.repeatRule.rawValue + " repeat"
        }
        if let completed = reminder.completedAt {
            return "Completed " + completed.formatted(date: .abbreviated, time: .shortened)
        }
        if let snooze = reminder.snoozedUntil {
            let date: Date.FormatStyle.DateStyle = Calendar.autoupdatingCurrent.isDate(snooze, inSameDayAs: now) ? .omitted : .abbreviated
            return (snooze > now ? "Snoozed until " : "Snooze ended ") + snooze.formatted(date: date, time: .shortened)
        }
        let date = reminder.due.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
        return reminder.preferences.repeatRule == .never ? date : date + " · " + reminder.preferences.repeatRule.rawValue
    }

    private func nextCard(_ occurrence: ReminderOccurrence, now: Date) -> some View {
        let reminder = occurrence.reminder
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(occurrence.isProjected ? "PLANNED REPEAT" : "UP NEXT", systemImage: occurrence.isProjected ? "repeat" : "circle.fill")
                    .font(.caption.weight(.semibold)).tracking(1).foregroundStyle(palette.accent)
                Spacer()
                if !occurrence.isProjected {
                    Button { Task { await store.done(reminder) } } label: {
                        Image(systemName: "checkmark.circle").font(.title2)
                            .frame(width: 44, height: 44)
                    }.buttonStyle(.plain).accessibilityLabel("Done, " + reminder.title)
                }
                reminderMenu(occurrence, now: now)
            }
            Button { editReminder(reminder) } label: {
                VStack(alignment: .leading, spacing: 7) {
                    Text(occurrence.date, style: .time).font(.largeTitle.weight(.medium).monospacedDigit())
                    Text(reminder.title).font(.title3.weight(.semibold))
                    Text(reminder.notes.isEmpty ? (reminder.preferences.notifications ? "We’ll give you a little nudge." : "Saved here with notifications off.") : reminder.notes)
                        .font(.subheadline).foregroundStyle(palette.secondary).lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            Divider().overlay(palette.accent.opacity(0.25))
            let cadence = reminder.preferences.nagMinutes
            let alert = !reminder.preferences.notifications ? "Notifications off" : cadence == 0 ? "One gentle nudge" : "Every \(cadence) min"
            Label(alert, systemImage: "bell").font(.footnote.weight(.medium)).foregroundStyle(palette.accent)
            if !Calendar.autoupdatingCurrent.isDate(occurrence.date, inSameDayAs: now) {
                Text(occurrence.date, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                    .font(.footnote).foregroundStyle(palette.secondary)
            }
        }
        .padding(16)
        .nudgePanel(palette, fill: palette.coral)
    }

    private func reminderMenu(_ occurrence: ReminderOccurrence, now: Date) -> some View {
        let reminder = occurrence.reminder
        let completed = reminder.completedAt != nil
        return Menu {
            if completed {
                Button(reminder.preferences.repeatRule == .never ? "Restore" : "Restore as one-time reminder",
                       systemImage: "arrow.uturn.backward") { store.restore(reminder) }
            } else {
                Button(occurrence.isProjected ? "Edit repeating reminder" : "Edit", systemImage: "pencil") { editReminder(reminder) }
                if AgendaPresentation.canSnooze(occurrence, now: now) {
                    Button("Snooze 15 min", systemImage: "clock") { store.snooze(reminder) }
                }
            }
            Button(!completed && reminder.preferences.repeatRule != .never ? "Delete repeating reminder" : "Delete",
                   systemImage: "trash", role: .destructive) { pendingDelete = reminder }
        } label: {
            Image(systemName: "ellipsis").frame(width: 44, height: 44)
                .foregroundStyle(palette.secondary)
        }
        .accessibilityLabel("Options for " + reminder.title)
    }

    private func emptyState(completed: Bool) -> some View {
        VStack(spacing: 10) {
            Image(systemName: completed ? "checkmark.circle" : "leaf")
                .font(.largeTitle.weight(.light)).foregroundStyle(palette.green)
                .accessibilityHidden(true)
            Text(completed ? "Small wins go here." : "A little breathing room.")
                .font(.title3.weight(.semibold))
            Text(completed ? "Reminders you complete will appear here." : "Nothing scheduled. Add a little nudge whenever you need one.")
                .font(.subheadline).foregroundStyle(palette.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .nudgePanel(palette)
    }
}

