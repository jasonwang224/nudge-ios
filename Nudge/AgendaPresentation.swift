import Foundation

// A read-only snapshot shared by the date strip, filters, and agenda sections.
struct AgendaPresentation {
    let viewedDay: Date
    let isToday: Bool
    let active: [Reminder]
    let completed: [Reminder]
    let visible: [ReminderOccurrence]
    let due: [ReminderOccurrence]
    let snoozed: [ReminderOccurrence]
    let upcoming: [ReminderOccurrence]

    static func canSnooze(_ occurrence: ReminderOccurrence, now: Date) -> Bool {
        !occurrence.isProjected && occurrence.reminder.completedAt == nil
            && occurrence.reminder.due <= now
    }

    init(reminders: [Reminder], todayOnly: Bool, selectedDay: Date?, now: Date,
         calendar: Calendar = .autoupdatingCurrent) {
        let today = calendar.startOfDay(for: now)
        let day = max(today, selectedDay.map { calendar.startOfDay(for: $0) } ?? today)
        viewedDay = day
        isToday = calendar.isDate(day, inSameDayAs: today)
        active = reminders.filter { $0.completedAt == nil }
        completed = reminders.filter {
            guard let completedAt = $0.completedAt else { return false }
            return !todayOnly || calendar.isDate(completedAt, inSameDayAs: day)
        }.sorted {
            if $0.completedAt == $1.completedAt { return $0.id.uuidString < $1.id.uuidString }
            return ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast)
        }
        visible = ReminderOccurrence.entries(reminders: active, on: todayOnly ? day : nil,
                                             now: now, calendar: calendar)
        due = visible.filter { !$0.isProjected && $0.date <= now }
        snoozed = visible.filter { !$0.isProjected && $0.date > now && $0.reminder.snoozedUntil != nil }
        upcoming = visible.filter { $0.date > now && ($0.isProjected || $0.reminder.snoozedUntil == nil) }
    }
}
