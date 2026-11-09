import Foundation

// Shared by the editor and source checks, so validation covers the actual save path.
enum ReminderEditorDraft {
    enum Problem: LocalizedError, Equatable {
        case emptyTitle, emptyTime, invalidTime, emptyWeekdays, pastDate, excludedWeekday, excludedCustomDay, unconfirmedCalendar

        var errorDescription: String? {
            switch self {
            case .emptyTitle: return "Enter a reminder title."
            case .emptyTime: return "Enter a reminder time."
            case .invalidTime: return "Enter a valid time, such as 830 for 8:30."
            case .emptyWeekdays: return "Choose at least one repeat day."
            case .pastDate: return "Choose a future date and time."
            case .excludedWeekday: return "Choose a weekday date for a Weekdays reminder."
            case .excludedCustomDay: return "Choose a date that matches your selected repeat days."
            case .unconfirmedCalendar: return "Choose a new date or time to confirm this reminder’s schedule."
            }
        }
    }

    static func shortcutDate(days: Int, now: Date, calendar: Calendar = .autoupdatingCurrent) -> Date? {
        calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now))
    }

    static func formattedTime(_ time: String) -> String? {
        guard let clock = clock(time: time, isPM: false) else { return nil }
        let hour = clock.hour == 0 ? 12 : clock.hour
        return String(format: "%d:%02d", hour, clock.minute)
    }

    static func schedule(time: String, day: Date, isPM: Bool, original: Reminder? = nil, now: Date = .now,
                         calendar: Calendar = .autoupdatingCurrent) -> PhoneSchedule? {
        try? preparedSchedule(time: time, day: day, isPM: isPM, original: original, now: now, calendar: calendar).schedule
    }

    private struct PreparedSchedule {
        var schedule: PhoneSchedule
        let calendar: Calendar
        let repairedCalendar: Bool
    }

    private static func preparedSchedule(time: String, day: Date, isPM: Bool, original: Reminder?, now: Date,
                                         calendar: Calendar) throws -> PreparedSchedule {
        guard let clock = clock(time: time, isPM: isPM) else { throw Problem.invalidTime }
        var effectiveCalendar = calendar
        var repairedCalendar = false
        if let original, let previous = original.phoneSchedule {
            if let resolved = previous.resolvedCalendar(relativeTo: original.due, calendar: calendar) {
                effectiveCalendar = resolved
            } else {
                // A deliberate date/time change confirms a replacement schedule.
                // Never reinterpret unknown legacy components during a rename.
                let changed = !calendar.isDate(day, inSameDayAs: original.due)
                    || previous.hour != clock.hour || previous.minute != clock.minute
                guard changed else { throw Problem.unconfirmedCalendar }
                repairedCalendar = true
            }
        }
        var result = PhoneSchedule(day: day, hour: clock.hour, minute: clock.minute, calendar: effectiveCalendar)
        let originalClock = original.map { effectiveCalendar.dateComponents([.hour, .minute], from: $0.due) }
        let sameOriginalClock = !repairedCalendar && original.map {
            effectiveCalendar.isDate(day, inSameDayAs: $0.due)
                && (original?.phoneSchedule?.hour ?? originalClock?.hour) == clock.hour
                && (original?.phoneSchedule?.minute ?? originalClock?.minute) == clock.minute
        } == true
        if sameOriginalClock, let original {
            if let previous = original.phoneSchedule {
                result.prefersSecondOccurrence = previous.prefersSecondOccurrence
            } else if let last = effectiveCalendar.date(bySettingHour: clock.hour, minute: clock.minute, second: 0, of: day,
                                                        matchingPolicy: .nextTime, repeatedTimePolicy: .last),
                      let first = result.dueDate(calendar: effectiveCalendar), last > first,
                      effectiveCalendar.isDate(original.due, equalTo: last, toGranularity: .minute) {
                result.prefersSecondOccurrence = true
            }
        } else if let first = result.dueDate(calendar: effectiveCalendar), first <= now,
                  let last = effectiveCalendar.date(bySettingHour: clock.hour, minute: clock.minute, second: 0, of: day,
                                                    matchingPolicy: .nextTime, repeatedTimePolicy: .last),
                  effectiveCalendar.isDate(last, inSameDayAs: day), last > now {
            result.prefersSecondOccurrence = true
        }
        return PreparedSchedule(schedule: result, calendar: effectiveCalendar, repairedCalendar: repairedCalendar)
    }

    private static func clock(time: String, isPM: Bool) -> (hour: Int, minute: Int)? {
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
        return (hour % 12 + (isPM ? 12 : 0), minute)
    }

    static func reminder(original: Reminder?, title: String, notes: String, day: Date,
                         time: String, isPM: Bool, preferences: ReminderPreferences,
                         now: Date = .now, calendar: Calendar = .autoupdatingCurrent) throws -> Reminder {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw Problem.emptyTitle }
        guard !time.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Problem.emptyTime }
        let patternChanged = original.map {
            $0.preferences.repeatRule != preferences.repeatRule
                || (preferences.repeatRule == .custom && $0.preferences.weekdays != preferences.weekdays)
        } ?? false
        if !patternChanged, var existing = original, let adjusted = existing.adjustedDue,
           let input = clock(time: time, isPM: isPM),
           calendar.isDate(day, inSameDayAs: adjusted),
           calendar.component(.hour, from: adjusted) == input.hour,
           calendar.component(.minute, from: adjusted) == input.minute {
            guard preferences.repeatRule != .custom || !preferences.weekdays.isEmpty else { throw Problem.emptyWeekdays }
            existing.title = name
            existing.notes = notes
            existing.preferences = preferences
            return existing
        }
        let prepared = try preparedSchedule(time: time, day: day, isPM: isPM, original: original, now: now, calendar: calendar)
        var schedule = prepared.schedule
        let effectiveCalendar = prepared.calendar
        guard let date = schedule.dueDate(calendar: calendar) else { throw Problem.invalidTime }
        guard preferences.repeatRule != .custom || !preferences.weekdays.isEmpty else { throw Problem.emptyWeekdays }

        let previous = prepared.repairedCalendar ? nil : original?.phoneSchedule
        let sameClock = previous?.day == schedule.day && previous?.hour == schedule.hour && previous?.minute == schedule.minute
        let sameLegacyMinute = original?.phoneSchedule == nil && original.map {
            effectiveCalendar.isDate($0.due, equalTo: date, toGranularity: .minute)
        } == true
        let unchangedSchedule = original?.adjustedDue == nil && (sameClock || sameLegacyMinute)
        guard unchangedSchedule || date > now else { throw Problem.pastDate }

        // Existing reminders may predate this validation. Do not block harmless
        // title/note edits to an unchanged schedule, even when it is overdue.
        if original == nil || patternChanged || !unchangedSchedule {
            let weekday = effectiveCalendar.component(.weekday, from: date)
            if preferences.repeatRule == .weekdays && (weekday == 1 || weekday == 7) {
                throw Problem.excludedWeekday
            }
            if preferences.repeatRule == .custom && !preferences.weekdays.contains(weekday) {
                throw Problem.excludedCustomDay
            }
        }
        if !patternChanged, !prepared.repairedCalendar, let original, effectiveCalendar.isDate(original.due, inSameDayAs: date) {
            // Adjusting the time of an advanced Jan31 -> Feb28 occurrence must
            // not turn the whole monthly series into a "28th" reminder.
            schedule.anchorDay = previous?.anchorDay
                ?? effectiveCalendar.dateComponents([.era, .year, .month, .day], from: original.repeatAnchor)
        }
        var result = original ?? Reminder(title: name, notes: notes, due: date,
                                          repeatAnchor: date, preferences: preferences)
        result.title = name
        result.notes = notes
        result.due = sameLegacyMinute ? (original?.due ?? date) : date
        result.adjustedDue = nil
        result.phoneSchedule = sameLegacyMinute ? nil : schedule
        result.preferences = preferences
        if patternChanged || prepared.repairedCalendar { result.repeatAnchor = result.due }
        return result
    }
}
