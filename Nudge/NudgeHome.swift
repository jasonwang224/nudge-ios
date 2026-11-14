import Combine
import SwiftUI
import UIKit

@MainActor
struct NudgeHome: View {
    @ObservedObject var store: ReminderStore
    @Environment(\.colorScheme) private var scheme
    @AppStorage("Nudge.appearance") private var appearance: NudgeAppearance = .system
    @State private var editor: EditorItem?
    @State private var pendingCompletion: ReminderOccurrence?
    @State private var tab: Tab = .today
    @State private var notificationRequest: ReminderNotificationOpen?
    @State private var notificationDestination: Tab?

    private let reminderAnimation = Animation.easeInOut(duration: 0.36)

    private enum Tab: Hashable {
        case today, upcoming, settings
    }

    private struct EditorItem: Identifiable {
        var id = UUID()
        var reminder: Reminder?
        var initialDay: Date?
    }

    var body: some View {
        let palette = NudgePalette(scheme: scheme)
        TabView(selection: $tab) {
            agenda(todayOnly: true, palette: palette)
                .tabItem { Label("Today", systemImage: "sun.max") }
                .tag(Tab.today)
            agenda(todayOnly: false, palette: palette)
                .tabItem { Label("Upcoming", systemImage: "calendar") }
                .tag(Tab.upcoming)
            NudgeSettings(store: store, appearance: $appearance, palette: palette)
                .toolbarBackground(palette.paper, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
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
        .alert("Mark as done?", isPresented: Binding(
            get: { pendingCompletion != nil },
            set: { if !$0 { pendingCompletion = nil } }
        ), presenting: pendingCompletion) { occurrence in
            Button("Cancel", role: .cancel) {}
            Button("Done") { Task { await store.done(occurrence, animation: reminderAnimation) } }
        } message: { occurrence in
            Text("\(occurrence.reminder.title)\n\(occurrence.date.formatted(date: .abbreviated, time: .shortened))")
        }
        .onChange(of: store.notificationOpen, initial: true) { _, request in
            guard let request, let reminder = store.reminders.first(where: {
                $0.id == request.id && $0.generation == request.generation && $0.completedAt == nil
            }) else { return }
            let destination: Tab = AgendaPresentation.includesToday(reminder) ? .today : .upcoming
            editor = nil
            pendingCompletion = nil
            notificationDestination = destination
            notificationRequest = request
            tab = destination
        }
    }

    private func agenda(todayOnly: Bool, palette: NudgePalette) -> some View {
        let destination: Tab = todayOnly ? .today : .upcoming
        return NudgeAgenda(store: store, todayOnly: todayOnly, palette: palette,
                    reminderAnimation: reminderAnimation,
                    notificationRequest: tab == destination && notificationDestination == destination ? notificationRequest : nil,
                    didOpenNotification: { request in
                        if notificationRequest == request { notificationRequest = nil }
                    },
                    newReminder: { editor = EditorItem(initialDay: $0) },
                    editReminder: { editor = EditorItem(reminder: $0) },
                    confirmCompletion: { pendingCompletion = $0 })
            .toolbarBackground(palette.paper, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
    }
}

@MainActor
private struct NudgeAgenda: View {
    @ObservedObject var store: ReminderStore
    let todayOnly: Bool
    let palette: NudgePalette
    let reminderAnimation: Animation
    let notificationRequest: ReminderNotificationOpen?
    let didOpenNotification: (ReminderNotificationOpen) -> Void
    let newReminder: (Date?) -> Void
    let editReminder: (Reminder) -> Void
    let confirmCompletion: (ReminderOccurrence) -> Void
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var now = Date.now
    @State private var selectedDay: Date?
    @State private var showCompleted = false
    @State private var pendingDelete: Reminder?
    @State private var expandedTime: ExpandedTime?
    @State private var adjustmentIssue: String?
    @State private var scrollRequest: ReminderNotificationOpen?

    private struct ExpandedTime {
        let id: ReminderOccurrence.ID
        let placement: Reminder?
        var generation: UUID
    }

    private static let clock = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private var quickTimeTransition: AnyTransition {
        .offset(y: -8).combined(with: .opacity)
    }

    var body: some View {
        ScrollViewReader { proxy in
            agenda(at: now)
                .onChange(of: scrollRequest, initial: true) { _, request in
                    guard let request, let id = expandedTime?.id else { return }
                    Task { @MainActor in
                        await Task.yield()
                        guard scrollRequest == request, expandedTime?.id == id else { return }
                        withAnimation(reduceMotion ? nil : reminderAnimation) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
        }
        .onReceive(Self.clock) { now = $0 }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { now = .now }
        }
        .onChange(of: notificationRequest, initial: true) { _, request in
            guard let request else { return }
            if let reminder = store.reminders.first(where: {
                $0.id == request.id && $0.generation == request.generation && $0.completedAt == nil
            }) {
                selectedDay = nil
                showCompleted = false
                pendingDelete = nil
                openTime(ReminderOccurrence(reminder))
                scrollRequest = request
            }
            didOpenNotification(request)
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
        let placed = store.reminders.map { reminder in
            if let expandedTime, let placement = expandedTime.placement,
               reminder.id == placement.id && reminder.generation == expandedTime.generation {
                return placement
            }
            return reminder
        }
        let presentation = AgendaPresentation(reminders: placed, todayOnly: todayOnly,
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
                    VStack(alignment: .leading, spacing: 8) {
                        Label(issue, systemImage: "exclamationmark.triangle")
                        Button(store.isUpdatingNotifications ? "Updating alerts…" : "Retry alerts") {
                            store.retryNotifications()
                        }
                        .disabled(store.isUpdatingNotifications)
                    }
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(palette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .nudgePanel(palette, fill: palette.coral)
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
            .animation(reminderAnimation, value: expandedTime?.id)
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
                    closeTime()
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
            closeTime()
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
                    VStack(spacing: 0) {
                        Divider().overlay(palette.line)
                        reminderRow(reminder, now: now)
                    }
                    .transition(.opacity)
                }
            }
            .nudgePanel(palette)
            .transition(.opacity)
        }
    }

    private func reminderRow(_ occurrence: ReminderOccurrence, now: Date) -> some View {
        let reminder = liveReminder(for: occurrence)
        let current = occurrence.isProjected ? ReminderOccurrence(reminder, projectedDate: occurrence.date) : ReminderOccurrence(reminder)
        let completed = reminder.completedAt != nil
        let restoreTitle = reminder.preferences.repeatRule == .never ? "Restore" : "Restore as one-time reminder"
        let expanded = isExpanded(occurrence, reminder: reminder)
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    if completed { store.restore(reminder) }
                    else { confirmCompletion(current) }
                } label: {
                    Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(completed ? palette.green : palette.accent)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel((completed ? restoreTitle : "Done") + ", " + reminder.title)
                Button {
                    toggleTime(occurrence, current: current)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(reminder.title).font(.body.weight(.medium)).foregroundStyle(palette.ink)
                        Text(reminderDetail(current, now: now))
                            .font(.footnote).foregroundStyle(palette.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .accessibilityHint(expanded ? "Collapse time adjustments" : "Show time adjustments")
                reminderMenu(current, now: now)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            if expanded {
                quickTimeMenu(current, now: now)
                    .padding(.horizontal, 10).padding(.bottom, 10)
                    .transition(quickTimeTransition)
            }
        }
        .id(occurrence.id)
    }

    private func reminderDetail(_ occurrence: ReminderOccurrence, now: Date) -> String {
        let reminder = occurrence.reminder
        if let completed = reminder.completedAt {
            if let day = reminder.completedForDay?.date(in: .autoupdatingCurrent) {
                return "Completed for " + day.formatted(date: .abbreviated, time: .omitted)
            }
            return "Completed " + completed.formatted(date: .abbreviated, time: .shortened)
        }
        if !occurrence.isProjected, let snooze = reminder.snoozedUntil {
            let date: Date.FormatStyle.DateStyle = Calendar.autoupdatingCurrent.isDate(snooze, inSameDayAs: now) ? .omitted : .abbreviated
            return (snooze > now ? "Snoozed until " : "Snooze ended ") + snooze.formatted(date: date, time: .shortened)
        }
        let date = occurrence.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
        return reminder.preferences.repeatRule == .never ? date : date + " · " + reminder.preferences.repeatRule.rawValue
    }

    private func nextCard(_ occurrence: ReminderOccurrence, now: Date) -> some View {
        let reminder = liveReminder(for: occurrence)
        let current = occurrence.isProjected ? ReminderOccurrence(reminder, projectedDate: occurrence.date) : ReminderOccurrence(reminder)
        let expanded = isExpanded(occurrence, reminder: reminder)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("UP NEXT", systemImage: "circle.fill")
                    .font(.caption.weight(.semibold)).tracking(1).foregroundStyle(palette.accent)
                Spacer()
                Button { confirmCompletion(current) } label: {
                    Image(systemName: "checkmark.circle").font(.title2)
                        .frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel("Done, " + reminder.title)
                reminderMenu(current, now: now)
            }
            Button { toggleTime(occurrence, current: current) } label: {
                VStack(alignment: .leading, spacing: 7) {
                    Text(current.date, style: .time).font(.largeTitle.weight(.medium).monospacedDigit())
                    Text(reminder.title).font(.title3.weight(.semibold))
                    Text(reminder.notes.isEmpty ? (reminder.preferences.notifications ? "We’ll give you a little nudge." : "Saved here with notifications off.") : reminder.notes)
                        .font(.subheadline).foregroundStyle(palette.secondary).lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint(expanded ? "Collapse time adjustments" : "Show time adjustments")
            Divider().overlay(palette.accent.opacity(0.25))
            let cadence = reminder.preferences.nagMinutes
            let alert = !reminder.preferences.notifications ? "Notifications off" : cadence == 0 ? "One gentle nudge" : "Every \(cadence) min"
            Label(alert, systemImage: "bell").font(.footnote.weight(.medium)).foregroundStyle(palette.accent)
            if !Calendar.autoupdatingCurrent.isDate(current.date, inSameDayAs: now) {
                Text(current.date, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                    .font(.footnote).foregroundStyle(palette.secondary)
            }
            if expanded {
                quickTimeMenu(current, now: now)
                    .transition(quickTimeTransition)
            }
        }
        .padding(16)
        .nudgePanel(palette, fill: palette.coral)
        .id(occurrence.id)
        .transition(.opacity)
    }

    private func liveReminder(for occurrence: ReminderOccurrence) -> Reminder {
        store.reminders.first { $0.id == occurrence.reminder.id } ?? occurrence.reminder
    }

    private func isExpanded(_ occurrence: ReminderOccurrence, reminder: Reminder) -> Bool {
        expandedTime?.id == occurrence.id && expandedTime?.generation == reminder.generation
    }

    private func toggleTime(_ occurrence: ReminderOccurrence, current: ReminderOccurrence) {
        if isExpanded(occurrence, reminder: current.reminder) { closeTime() }
        else { openTime(current) }
    }

    private func openTime(_ occurrence: ReminderOccurrence) {
        let reminder = occurrence.reminder
        let placement = occurrence.isProjected || reminder.completedAt != nil ? nil : reminder
        expandedTime = ExpandedTime(id: occurrence.id, placement: placement, generation: reminder.generation)
        adjustmentIssue = nil
    }

    private func closeTime() {
        expandedTime = nil
        adjustmentIssue = nil
    }

    private func quickTimeMenu(_ occurrence: ReminderOccurrence, now: Date) -> some View {
        let reminder = occurrence.reminder
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Adjust time", systemImage: "clock").font(.subheadline.weight(.semibold))
                Spacer()
                Text(occurrence.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(palette.accent)
            }
            if reminder.completedAt != nil {
                Text("Restore this reminder to adjust its time.").font(.footnote).foregroundStyle(palette.secondary)
            } else if occurrence.isProjected {
                Text("Adjust the current reminder from Today or Upcoming.")
                    .font(.footnote).foregroundStyle(palette.secondary)
            } else {
                Text(occurrence.date <= now ? "Later options start from now." : "Each tap updates the scheduled time.")
                    .font(.footnote).foregroundStyle(palette.secondary)
                Grid(alignment: .leading, horizontalSpacing: 7, verticalSpacing: 7) {
                    GridRow {
                        Text("Earlier")
                        Text("Later")
                    }
                    .font(.caption).foregroundStyle(palette.secondary)
                    ForEach(ReminderTimeShift.allCases, id: \.self) { shift in
                        GridRow {
                            shiftButton(shift, direction: .earlier, reminder: reminder, now: now)
                            shiftButton(shift, direction: .later, reminder: reminder, now: now)
                        }
                    }
                }
            }
            if let adjustmentIssue {
                Text(adjustmentIssue).font(.footnote).foregroundStyle(palette.accent)
            }
        }
        .padding(11)
        .nudgePanel(palette, fill: palette.canvas)
    }

    private func shiftButton(_ shift: ReminderTimeShift, direction: ReminderTimeShift.Direction,
                             reminder: Reminder, now: Date) -> some View {
        let candidate = shift.date(from: reminder.alertDate, direction: direction, now: now)
        let earlier = direction == .earlier
        return Button {
            adjustmentIssue = store.adjustTime(reminder, by: shift, direction: direction)
            if adjustmentIssue == nil,
               let latest = store.reminders.first(where: { $0.id == reminder.id && $0.completedAt == nil }) {
                expandedTime?.generation = latest.generation
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text((earlier ? "−" : "+") + shift.rawValue).font(.subheadline.weight(.semibold))
                if let candidate {
                    Text(candidate, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.caption2).foregroundStyle(palette.secondary)
                } else {
                    Text("Past time").font(.caption2).foregroundStyle(palette.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .nudgePanel(palette)
        }
        .buttonStyle(.plain)
        .disabled(candidate == nil)
        .opacity(candidate == nil ? 0.55 : 1)
        .accessibilityLabel("Move " + shift.rawValue + (earlier ? " earlier" : " later"))
    }

    private func reminderMenu(_ occurrence: ReminderOccurrence, now: Date) -> some View {
        let reminder = occurrence.reminder
        let completed = reminder.completedAt != nil
        return Menu {
            if completed {
                Button(reminder.preferences.repeatRule == .never ? "Restore" : "Restore as one-time reminder",
                       systemImage: "arrow.uturn.backward") { store.restore(reminder) }
            } else {
                Button(occurrence.isProjected ? "Edit repeating reminder" : "Edit", systemImage: "pencil") {
                    closeTime()
                    editReminder(reminder)
                }
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

