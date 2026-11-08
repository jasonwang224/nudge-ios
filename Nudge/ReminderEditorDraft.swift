import Foundation

// Shared by the editor and source checks, so validation covers the actual save path.
enum ReminderEditorDraft {
    enum Problem: LocalizedError, Equatable {
        case emptyTitle, emptyTime, invalidTime, emptyWeekdays, pastDate, excludedWeekday, excludedCustomDay

        var errorDescription: String? {
            switch self {
            case .emptyTitle: return "Enter a reminder title."
            case .emptyTime: return "Enter a reminder time."
            case .invalidTime: return "Enter a valid time, such as 830 for 8:30."
            case .emptyWeekdays: return "Choose at least one repeat day."
            case .pastDate: return "Choose a future date and time."
            case .excludedWeekday: return "Choose a weekday date for a Weekdays reminder."
            case .excludedCustomDay: return "Choose a date that matches your selected repeat days."
            }
        }
    }

    static func shortcutDate(days: Int, now: Date, calendar: Calendar = .autoupdatingCurrent) -> Date? {
        calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now))
    }

    static func schedule(time: String, day: Date, isPM: Bool,
                         calendar: Calendar = .autoupdatingCurrent) -> PhoneSchedule? {
        let input = time.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.utf8.allSatisfy({ (48...57).contains($0) || $0 == 58 }) else { return nil }
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
        return PhoneSchedule(day: day, hour: hour % 12 + (isPM ? 12 : 0), minute: minute, calendar: calendar)
    }

    static func reminder(original: Reminder?, title: String, notes: String, day: Date,
                         time: String, isPM: Bool, preferences: ReminderPreferences,
                         now: Date = .now, calendar: Calendar = .autoupdatingCurrent) throws -> Reminder {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw Problem.emptyTitle }
        guard !time.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Problem.emptyTime }
        guard var schedule = schedule(time: time, day: day, isPM: isPM, calendar: calendar),
              let date = schedule.dueDate(calendar: calendar) else { throw Problem.invalidTime }
        guard preferences.repeatRule != .custom || !preferences.weekdays.isEmpty else { throw Problem.emptyWeekdays }

        let previous = original?.phoneSchedule
        let sameClock = previous?.day == schedule.day && previous?.hour == schedule.hour && previous?.minute == schedule.minute
        let sameLegacyMinute = previous == nil && original.map {
            calendar.isDate($0.due, equalTo: date, toGranularity: .minute)
        } == true
        guard sameClock || sameLegacyMinute || date > now else { throw Problem.pastDate }

        let patternChanged = original.map {
            $0.preferences.repeatRule != preferences.repeatRule
                || (preferences.repeatRule == .custom && $0.preferences.weekdays != preferences.weekdays)
        } ?? false
        // Existing reminders may predate this validation. Do not block harmless
        // title/note edits to an unchanged schedule, even when it is overdue.
        if original == nil || patternChanged || !(sameClock || sameLegacyMinute) {
            let weekday = calendar.component(.weekday, from: date)
            if preferences.repeatRule == .weekdays && (weekday == 1 || weekday == 7) {
                throw Problem.excludedWeekday
            }
            if preferences.repeatRule == .custom && !preferences.weekdays.contains(weekday) {
                throw Problem.excludedCustomDay
            }
        }
        if !patternChanged, let original, calendar.isDate(original.due, inSameDayAs: date) {
            // Adjusting the time of an advanced Jan31 -> Feb28 occurrence must
            // not turn the whole monthly series into a "28th" reminder.
            schedule.anchorDay = previous?.anchorDay
                ?? calendar.dateComponents([.era, .year, .month, .day], from: original.repeatAnchor)
        }
        var result = original ?? Reminder(title: name, notes: notes, due: date,
                                          repeatAnchor: date, preferences: preferences)
        result.title = name
        result.notes = notes
        result.due = sameLegacyMinute ? (original?.due ?? date) : date
        result.phoneSchedule = sameLegacyMinute ? nil : schedule
        result.preferences = preferences
        if patternChanged { result.repeatAnchor = result.due }
        return result
    }
}
