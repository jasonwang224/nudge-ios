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
        .blur(radius: pendingCompletion == nil ? 0 : 3)
        .allowsHitTesting(pendingCompletion == nil)
        .accessibilityHidden(pendingCompletion != nil)
        .overlay {
            if let occurrence = pendingCompletion {
                CompletionConfirmation(palette: palette, message: completionMessage(for: occurrence),
                    cancel: { pendingCompletion = nil },
                    confirm: {
                        pendingCompletion = nil
                        Task { await store.done(occurrence, animation: reminderAnimation) }
                    })
            }
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

    private func completionMessage(for occurrence: ReminderOccurrence) -> String {
        let date = occurrence.date.formatted(date: .abbreviated, time: .shortened)
        let detail = "Complete “\(occurrence.reminder.title)” for \(date)?"
        return occurrence.reminder.preferences.repeatRule == .never
            ? detail : detail + "\nOnly this occurrence will be completed. Future repeats will continue."
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
    @ScaledMetric(relativeTo: .largeTitle) private var heroTimeSize = 38.0
    @ScaledMetric(relativeTo: .headline) private var heroPeriodSize = 18.0
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var now = Date.now
    @State private var selectedDay: Date?
    @State private var showCompleted = false
    @State private var pendingDelete: Reminder?
    @State private var expandedTime: ExpandedTime?
    @State private var adjustmentIssue: String?
    @State private var scrollRequest: ReminderNotificationOpen?
    @State private var searchText = ""
    @State private var searchPresented = false
    @FocusState private var searchFocused: Bool

    private var isSearching: Bool { !ReminderSearch.terms(in: searchText).isEmpty }


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
                searchText = ""
                searchPresented = false
                searchFocused = false
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
                                             selectedDay: selectedDay, now: now, calendar: calendar, searchText: searchText)
        let viewedDay = presentation.viewedDay
        let isToday = presentation.isToday
        let active = presentation.active
        let completed = presentation.completed
        let visible = presentation.visible
        let due = presentation.due
        let snoozed = presentation.snoozed
        let upcoming = presentation.upcoming

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                NudgeHeading(eyebrow: (todayOnly ? viewedDay : now).formatted(.dateTime.weekday(.wide).month(.wide).day()),
                             title: todayOnly ? (isToday ? "Today" : viewedDay.formatted(.dateTime.weekday(.wide))) : "Upcoming",
                             subtitle: "",
                             icon: todayOnly ? "sun.max" : "calendar", palette: palette,
                             iconAction: { searchPresented ? dismissSearch() : revealSearch() },
                             iconLabel: searchPresented ? "Close search" : "Search reminders",
                             iconSelected: searchPresented)
                if searchPresented {
                    searchField
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .task {
                            await Task.yield()
                            guard !Task.isCancelled, searchPresented else { return }
                            searchFocused = true
                        }
                }
                if isSearching {
                    Text("All dates · Names and notes")
                        .font(.caption).foregroundStyle(palette.secondary)
                }
                if todayOnly && !isSearching {
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
                let filterLayout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(spacing: 6))
                    : AnyLayout(HStackLayout(spacing: 8))
                filterLayout {
                    filterButton(todayOnly ? "Reminders" : "Scheduled", count: visible.count, completed: false)
                    filterButton("Completed", count: completed.count, completed: true)
                }
                if isSearching {
                    let results = showCompleted ? completed.map { ReminderOccurrence($0) } : visible
                    if results.isEmpty {
                        searchEmptyState(otherCount: showCompleted ? visible.count : completed.count)
                    } else {
                        reminderSection(showCompleted ? "Completed results" : "Search results",
                                        icon: "magnifyingglass", items: results, now: now)
                    }
                } else if showCompleted {
                    if completed.isEmpty { emptyState(completed: true) }
                    else { reminderSection("Completed", icon: "checkmark.circle", items: completed.map { ReminderOccurrence($0) }, now: now) }
                } else if visible.isEmpty {
                    emptyState(completed: false)
                } else {
                    reminderSection("Needs attention", icon: "bell.badge", items: due, now: now)
                    reminderSection("Snoozed", icon: "clock", items: snoozed, now: now)
                    if let next = upcoming.first {
                        if isExpanded(next, reminder: liveReminder(for: next)) {
                            reminderSection("Up next", icon: "clock", items: [next], now: now)
                        } else {
                            nextCard(next, now: now)
                        }
                    }
                    reminderSection(todayOnly ? (isToday ? "Later today" : "Later that day") : "Coming up", icon: "calendar",
                                    items: Array(upcoming.dropFirst()), now: now)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .animation(reminderAnimation, value: expandedTime?.id)
            .animation(reminderAnimation, value: searchPresented)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                searchFocused = false
                newReminder(todayOnly && !isSearching ? viewedDay : nil)
            } label: {
                Label("New reminder", systemImage: "plus")
                    .font(.headline).lineLimit(1).minimumScaleFactor(0.65)
                    .foregroundStyle(palette.scheme == .dark ? palette.canvas : .white)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(palette.accent, in: RoundedRectangle(cornerRadius: 17))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            .background(palette.paper)
        }
        .foregroundStyle(palette.ink)
    }

    private var searchField: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(palette.secondary)
                    .accessibilityHidden(true)
                TextField("Search reminders", text: Binding(
                    get: { searchText },
                    set: { updateSearch($0) }
                ))
                .font(.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
                .onSubmit { searchFocused = false }
                .accessibilityLabel("Search reminder names and notes")
                .accessibilityHint("Searches all dates. Use Reminders or Completed to choose results.")
                if !searchText.isEmpty {
                    Button { updateSearch(""); searchFocused = true } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(palette.secondary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.leading, 12).padding(.trailing, searchText.isEmpty ? 12 : 0)
            .frame(minHeight: 44)
            .nudgePanel(palette, fill: palette.canvas, radius: 13)
            Button("Cancel", action: dismissSearch)
                .font(.body).frame(minHeight: 44)
                .foregroundStyle(palette.accent)
                .accessibilityLabel("Cancel search")
        }
    }

    private func revealSearch() {
        closeTime()
        pendingDelete = nil
        searchPresented = true
    }

    private func dismissSearch() {
        searchFocused = false
        updateSearch("")
        searchPresented = false
    }

    private func updateSearch(_ value: String) {
        searchText = value
        closeTime()
        pendingDelete = nil
    }

    private func searchEmptyState(otherCount: Int) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.largeTitle.weight(.light))
                .foregroundStyle(palette.secondary).accessibilityHidden(true)
            Text("No matching reminders").font(.title3.weight(.semibold))
            Text(otherCount > 0
                 ? "Matches are available in " + (showCompleted ? "Reminders." : "Completed.")
                 : "Try another word from the reminder's name or notes.")
                .font(.subheadline).foregroundStyle(palette.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(22).nudgePanel(palette)
    }

    private func weekStrip(today: Date, viewedDay: Date, active: [Reminder], now: Date, calendar: Calendar) -> some View {
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        let strip = HStack(spacing: 5) {
            ForEach(days, id: \.self) { day in
                let selected = calendar.isDate(day, inSameDayAs: viewedDay)
                let hasReminder = !ReminderOccurrence.entries(reminders: active, on: day, now: now, calendar: calendar).isEmpty
                Button {
                    selectedDay = day
                    showCompleted = false
                    closeTime()
                } label: {
                    VStack(spacing: 5) {
                        Text(day.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.caption2).lineLimit(1).minimumScaleFactor(0.75)
                        Text(day, format: .dateTime.day()).font(.subheadline.weight(.semibold))
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Circle().fill(hasReminder ? (selected ? palette.paper : palette.accent) : .clear)
                            .frame(width: 4, height: 4)
                    }
                    .foregroundStyle(selected ? palette.paper : palette.secondary)
                    .frame(maxWidth: .infinity, minHeight: 62)
                    .frame(width: dynamicTypeSize.isAccessibilitySize ? 140 : nil)
                    .background(selected ? palette.ink : .clear, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                ScrollView(.horizontal, showsIndicators: false) { strip }
            } else { strip }
        }
    }

    private func filterButton(_ label: String, count: Int, completed: Bool) -> some View {
        let selected = showCompleted == completed
        return Button {
            showCompleted = completed
            searchFocused = false
            closeTime()
        } label: {
            HStack(spacing: 5) {
                Text(label).font(.footnote.weight(selected ? .semibold : .regular))
                    .lineLimit(1).minimumScaleFactor(0.8)
                Text(count.formatted()).font(.caption2.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(selected ? palette.coral : palette.canvas, in: Capsule())
            }
            .foregroundStyle(selected ? palette.ink : palette.secondary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: completed ? .trailing : .leading)
            .padding(.horizontal, 4)
            .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func reminderSection(_ title: String, icon: String, items: [ReminderOccurrence], now: Date) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title).font(.footnote.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Text("\(items.count) " + (items.count == 1 ? "reminder" : "reminders")).font(.caption2).foregroundStyle(palette.secondary)
                }
                .padding(.horizontal, 3)
                VStack(spacing: 0) {
                    ForEach(items) { occurrence in
                        VStack(spacing: 0) {
                            if occurrence.id != items.first?.id {
                                Divider().overlay(palette.line.opacity(0.5)).padding(.horizontal, 14)
                            }
                            reminderRow(occurrence, now: now)
                        }
                        .transition(.opacity)
                    }
                }
                .nudgePanel(palette)
            }
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
                    searchFocused = false
                    if completed { store.restore(reminder) }
                    else { confirmCompletion(current) }
                } label: {
                    Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
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
            .padding(.vertical, 7)
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
        let date = Calendar.autoupdatingCurrent.isDate(occurrence.date, inSameDayAs: now)
            ? occurrence.date.formatted(date: .omitted, time: .shortened)
            : occurrence.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
        return reminder.preferences.repeatRule == .never ? date : date + " · " + reminder.preferences.repeatRule.rawValue
    }

    private func nextCard(_ occurrence: ReminderOccurrence, now: Date) -> some View {
        let reminder = liveReminder(for: occurrence)
        let current = occurrence.isProjected ? ReminderOccurrence(reminder, projectedDate: occurrence.date) : ReminderOccurrence(reminder)
        let expanded = isExpanded(occurrence, reminder: reminder)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 7) {
                    Circle().fill(palette.accent).frame(width: 6, height: 6)
                    Text("Up next").font(.caption.weight(.semibold))
                }
                .foregroundStyle(palette.accent)
                Spacer()
                Button { confirmCompletion(current) } label: {
                    Image(systemName: "checkmark.circle").font(.system(size: 24))
                        .frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel("Done, " + reminder.title)
                reminderMenu(current, now: now)
            }
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
            layout {
                Button { toggleTime(occurrence, current: current) } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        heroTime(current.date)
                            .font(.system(size: heroTimeSize, weight: .semibold).monospacedDigit())
                            .lineLimit(1).minimumScaleFactor(0.75)
                        Text(reminder.title).font(.title3.weight(.semibold))
                        if reminder.preferences.repeatRule != .never {
                            Text(reminder.preferences.repeatRule.rawValue)
                                .font(.caption).foregroundStyle(palette.secondary)
                        }
                        if !reminder.notes.isEmpty {
                            Text(reminder.notes).font(.subheadline)
                                .foregroundStyle(palette.secondary).lineLimit(3)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .accessibilityHint(expanded ? "Collapse time adjustments" : "Show time adjustments")
                BellBuddy(date: current.date, palette: palette)
            }
            Divider().overlay(palette.accent.opacity(0.25))
            let cadence = reminder.preferences.nagMinutes
            let alert = cadence == 0 ? "One notification" : "Nag me every \(cadence) min"
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Label(alert, systemImage: "bell")
                    Spacer(minLength: 4)
                    Text("15 min snooze").foregroundStyle(palette.secondary)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Label(alert, systemImage: "bell")
                    Text("15 min snooze").foregroundStyle(palette.secondary)
                }
            }
            .font(.caption).foregroundStyle(palette.accent)
            if !Calendar.autoupdatingCurrent.isDate(current.date, inSameDayAs: now) {
                Text(current.date, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                    .font(.footnote).foregroundStyle(palette.secondary)
            }
            if expanded {
                quickTimeMenu(current, now: now)
                    .transition(quickTimeTransition)
            }
        }
        .padding(14)
        .nudgePanel(palette, fill: palette.coral, radius: 24)
        .id(occurrence.id)
        .transition(.opacity)
    }

    private func heroTime(_ date: Date) -> Text {
        // Keep the phone's locale/12- or 24-hour preference; shrink only its day period.
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        var text = AttributedString(date.formatted(date: .omitted, time: .shortened))
        for symbol in [formatter.amSymbol, formatter.pmSymbol].compactMap({ $0 }) where !symbol.isEmpty {
            if let range = text.range(of: symbol) {
                text[range].font = .system(size: heroPeriodSize, weight: .semibold)
            }
        }
        return Text(text)
    }

    private func liveReminder(for occurrence: ReminderOccurrence) -> Reminder {
        store.reminders.first { $0.id == occurrence.reminder.id } ?? occurrence.reminder
    }

    private func isExpanded(_ occurrence: ReminderOccurrence, reminder: Reminder) -> Bool {
        expandedTime?.id == occurrence.id && expandedTime?.generation == reminder.generation
    }

    private func toggleTime(_ occurrence: ReminderOccurrence, current: ReminderOccurrence) {
        searchFocused = false
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
            if reminder.completedAt == nil && !occurrence.isProjected {
                Text(occurrence.date <= now ? "Later options start from now." : "Tap again to keep adjusting.")
                    .font(.caption2).foregroundStyle(palette.secondary)
                    .frame(maxWidth: .infinity).multilineTextAlignment(.center)
            }
            if let adjustmentIssue {
                Text(adjustmentIssue).font(.footnote).foregroundStyle(palette.accent)
            }
        }
        .padding(13)
        .nudgePanel(palette, fill: palette.canvas, radius: 16)
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
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .nudgePanel(palette, radius: 12)
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
                    searchFocused = false
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
            Image(systemName: "ellipsis").font(.system(size: 20)).frame(width: 44, height: 44)
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


@MainActor
private struct CompletionConfirmation: View {
    let palette: NudgePalette
    let message: String
    let cancel: () -> Void
    let confirm: () -> Void
    @AccessibilityFocusState private var headingFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.25).ignoresSafeArea()
                VStack(spacing: 0) {
                    ViewThatFits(in: .vertical) {
                        messageContent
                        ScrollView { messageContent }
                    }
                    Divider().overlay(palette.line)
                    actions
                }
                .frame(maxWidth: 297)
                .background(palette.paper, in: RoundedRectangle(cornerRadius: 23))
                .clipShape(RoundedRectangle(cornerRadius: 23))
                .padding(20)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, cancel)
        .onAppear { headingFocused = true }
    }

    private var messageContent: some View {
        VStack(spacing: 15) {
            Image(systemName: "checkmark")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(palette.accent)
                .frame(width: 43, height: 43)
                .background(palette.coral, in: Circle())
                .accessibilityHidden(true)
            Text("Mark as done?")
                .font(.title3.weight(.bold))
                .foregroundStyle(palette.ink)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($headingFocused)
            Text(message).font(.caption).foregroundStyle(palette.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(25)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var actions: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 0))
            : AnyLayout(HStackLayout(spacing: 0))
        return layout {
            Button(role: .cancel, action: cancel) {
                Text("Cancel").font(.subheadline).foregroundStyle(palette.secondary)
                    .frame(maxWidth: .infinity, minHeight: 51)
                    .contentShape(Rectangle())
            }
            if dynamicTypeSize.isAccessibilitySize {
                Rectangle().fill(palette.line).frame(height: 1)
            } else {
                Rectangle().fill(palette.line).frame(width: 1, height: 51)
            }
            Button(action: confirm) {
                Text("Done").font(.subheadline.weight(.semibold)).foregroundStyle(palette.accent)
                    .frame(maxWidth: .infinity, minHeight: 51)
                    .contentShape(Rectangle())
            }
        }.buttonStyle(.plain)
    }
}
