import Foundation

enum ReminderTimeShift: String, CaseIterable {
    case fiveMinutes = "5 min"
    case hour = "1 hour"
    case day = "1 day"

    enum Direction: Equatable {
        case earlier, later
    }

    func date(from due: Date, direction: Direction, now: Date,
              calendar: Calendar = .autoupdatingCurrent) -> Date? {
        let start = max(due, now)
        let sign = direction == .earlier ? -1 : 1
        let candidate: Date?
        switch self {
        case .fiveMinutes: candidate = start.addingTimeInterval(Double(sign) * 300)
        case .hour: candidate = start.addingTimeInterval(Double(sign) * 3600)
        case .day: candidate = calendar.date(byAdding: .day, value: sign, to: start)
        }
        guard let candidate, candidate > now,
              abs(candidate.timeIntervalSinceReferenceDate) < 100_000_000_000 else { return nil }
        return candidate
    }
}

struct ReminderNotificationOpen: Equatable {
    let id: UUID
    let generation: UUID
    let token = UUID()
}

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
            && occurrence.reminder.occurrenceDue <= now
    }

    static func includesToday(_ reminder: Reminder, now: Date = .now,
                              calendar: Calendar = .autoupdatingCurrent) -> Bool {
        !ReminderOccurrence.entries(reminders: [reminder], on: calendar.startOfDay(for: now),
                                    now: now, calendar: calendar).isEmpty
    }

    init(reminders: [Reminder], todayOnly: Bool, selectedDay: Date?, now: Date,
         calendar: Calendar = .autoupdatingCurrent) {
        let today = calendar.startOfDay(for: now)
        let day = max(today, selectedDay.map { calendar.startOfDay(for: $0) } ?? today)
        viewedDay = day
        isToday = calendar.isDate(day, inSameDayAs: today)
        active = reminders.filter { $0.completedAt == nil }
        let viewedCompletionDay = ReminderDay(day, calendar: calendar)
        completed = reminders.filter {
            guard let completedAt = $0.completedAt else { return false }
            if !todayOnly { return true }
            if let completedForDay = $0.completedForDay {
                return completedForDay == viewedCompletionDay
            }
            return calendar.isDate(completedAt, inSameDayAs: day)
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
