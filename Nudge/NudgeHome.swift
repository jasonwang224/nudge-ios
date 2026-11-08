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
        .sheet(item: $editor) { item in
            ReminderEditor(store: store, reminder: item.reminder)
                .tint(palette.accent)
        }
    }

    private func agenda(todayOnly: Bool, palette: NudgePalette) -> some View {
        NudgeAgenda(store: store, todayOnly: todayOnly, palette: palette,
                    newReminder: { editor = EditorItem() },
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
    let newReminder: () -> Void
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
        .confirmationDialog("Delete reminder?", isPresented: Binding(
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
        let viewedDay = max(today, selectedDay ?? today)
        let isToday = calendar.isDate(viewedDay, inSameDayAs: today)
        let active = store.reminders.filter { $0.completedAt == nil }.sorted { $0.alertDate < $1.alertDate }
        let completed = store.reminders.filter { $0.completedAt != nil }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        let visible = active.filter { reminder in
            !todayOnly || calendar.isDate(reminder.alertDate, inSameDayAs: viewedDay)
                || (isToday && (reminder.alertDate <= now || reminder.snoozedUntil != nil))
        }
        let due = visible.filter { $0.alertDate <= now }
        let snoozed = visible.filter { $0.alertDate > now && $0.snoozedUntil != nil }
        let upcoming = visible.filter { $0.alertDate > now && $0.snoozedUntil == nil }

        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                NudgeHeading(eyebrow: now.formatted(.dateTime.weekday(.wide).month(.wide).day()),
                             title: todayOnly ? "Hello, today." : "On the horizon.",
                             subtitle: todayOnly ? "A little more headspace starts here." : "A little planning. A lot of peace of mind.",
                             icon: todayOnly ? "sun.max" : "calendar", palette: palette)
                if todayOnly {
                    weekStrip(today: today, viewedDay: viewedDay, active: active, calendar: calendar)
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
                HStack(spacing: 8) {
                    filterButton(todayOnly ? "Reminders" : "Scheduled", count: visible.count, completed: false)
                    filterButton("Completed", count: completed.count, completed: true)
                }
                if showCompleted {
                    if completed.isEmpty { emptyState(completed: true) }
                    else { reminderSection("LOOK AT YOU GO", icon: "checkmark.circle", items: completed, now: now) }
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
            Button(action: newReminder) {
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

    private func weekStrip(today: Date, viewedDay: Date, active: [Reminder], calendar: Calendar) -> some View {
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        return HStack(spacing: 5) {
            ForEach(days, id: \.self) { day in
                let selected = calendar.isDate(day, inSameDayAs: viewedDay)
                let hasReminder = active.contains { calendar.isDate(day, inSameDayAs: $0.alertDate) }
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
    private func reminderSection(_ title: String, icon: String, items: [Reminder], now: Date) -> some View {
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

    private func reminderRow(_ reminder: Reminder, now: Date) -> some View {
        let completed = reminder.completedAt != nil
        let restoreTitle = reminder.preferences.repeatRule == .never ? "Restore" : "Restore as one-time reminder"
        return HStack(spacing: 6) {
            Button {
                if completed { store.restore(reminder) }
                else { store.done(reminder) }
            } label: {
                Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(completed ? palette.green : palette.accent)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel((completed ? restoreTitle : "Done") + ", " + reminder.title)
            Button {
                if completed { store.restore(reminder) }
                else { editReminder(reminder) }
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(reminder.title).font(.body.weight(.medium)).foregroundStyle(palette.ink)
                    Text(reminderDetail(reminder, now: now))
                        .font(.footnote).foregroundStyle(palette.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Menu {
                if completed {
                    Button(restoreTitle, systemImage: "arrow.uturn.backward") { store.restore(reminder) }
                } else {
                    Button("Edit", systemImage: "pencil") { editReminder(reminder) }
                    Button("Snooze 15 min", systemImage: "clock") { store.snooze(reminder) }
                }
                Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = reminder }
            } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 44)
                    .foregroundStyle(palette.secondary)
            }
            .accessibilityLabel("Options for " + reminder.title)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
    }

    private func reminderDetail(_ reminder: Reminder, now: Date) -> String {
        if let completed = reminder.completedAt {
            return "Completed " + completed.formatted(date: .abbreviated, time: .shortened)
        }
        if let snooze = reminder.snoozedUntil, snooze > now {
            let date: Date.FormatStyle.DateStyle = Calendar.autoupdatingCurrent.isDate(snooze, inSameDayAs: now) ? .omitted : .abbreviated
            return "Snoozed until " + snooze.formatted(date: date, time: .shortened)
        }
        let date = reminder.due.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
        return reminder.preferences.repeatRule == .never ? date : date + " · " + reminder.preferences.repeatRule.rawValue
    }

    private func nextCard(_ reminder: Reminder, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("UP NEXT", systemImage: "circle.fill")
                    .font(.caption.weight(.semibold)).tracking(1).foregroundStyle(palette.accent)
                Spacer()
                Button { store.done(reminder) } label: {
                    Image(systemName: "checkmark.circle").font(.title2)
                        .frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel("Done, " + reminder.title)
            }
            Button { editReminder(reminder) } label: {
                VStack(alignment: .leading, spacing: 7) {
                    Text(reminder.due, style: .time).font(.largeTitle.weight(.medium).monospacedDigit())
                    Text(reminder.title).font(.title3.weight(.semibold))
                    Text(reminder.notes.isEmpty ? "We’ll give you a little nudge." : reminder.notes)
                        .font(.subheadline).foregroundStyle(palette.secondary).lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            Divider().overlay(palette.accent.opacity(0.25))
            let cadence = reminder.preferences.nagMinutes
            let alert = !reminder.preferences.notifications ? "Notifications off" : cadence == 0 ? "One gentle nudge" : "Every \(cadence) min"
            Label(alert, systemImage: "bell").font(.footnote.weight(.medium)).foregroundStyle(palette.accent)
            if !Calendar.autoupdatingCurrent.isDate(reminder.due, inSameDayAs: now) {
                Text(reminder.due, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                    .font(.footnote).foregroundStyle(palette.secondary)
            }
        }
        .padding(16)
        .nudgePanel(palette, fill: palette.coral)
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

