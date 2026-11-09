import Foundation

// Pure state transitions shared by the app and lifecycle regression checks.
// Persistence and notification reconciliation happen only after a successful change.
enum ReminderLifecycle {
    struct Change {
        var snapshot: ReminderSnapshot
        var retiring: Reminder?
    }

    enum Problem: String, Error {
        case changed = "This reminder changed. Reopen it to edit the latest version."
        case deleted = "This reminder was deleted."
    }

    static func saving(_ reminder: Reminder, replacing generation: UUID?, expecting original: Reminder? = nil,
                       in snapshot: ReminderSnapshot, now: Date = .now) throws -> Change {
        var saved = reminder
        saved.generation = UUID()
        var changed = snapshot
        var retired: Reminder?
        if let index = snapshot.reminders.firstIndex(where: { $0.id == saved.id }) {
            let previous = snapshot.reminders[index]
            guard previous.generation == generation,
                  original.map({ matchesEditableVersion(previous, $0) }) ?? true else { throw Problem.changed }
            let clockChanged = previous.due != saved.due
                || !sameClock(previous.phoneSchedule, saved.phoneSchedule, referenceDate: previous.due)
            if clockChanged || (previous.adjustedDue != nil && saved.adjustedDue == nil) {
                saved.repeatAnchor = saved.due
                saved.adjustedDue = nil
                saved.snoozedUntil = nil
            }
            // An already-delivered one-off has no future request to replace its
            // card. Retain its action identity while stopping any remaining nags.
            // The expected full edit snapshot still rejects concurrent stale edits.
            let keepDeliveredCard = original != nil && previous.completedAt == nil && saved.completedAt == nil
                && previous.preferences.notifications && saved.preferences.notifications
                && saved.preferences.nagMinutes == 0 && saved.alertDate <= now
                && !clockChanged && saved.alertDate == previous.alertDate
            if keepDeliveredCard {
                saved.generation = previous.generation
                saved.soundOnlyAfterIndex = previous.soundOnlyAfterIndex
                saved.soundOnlyAnchorAccepted = previous.soundOnlyAnchorAccepted
            }
            else { retired = previous }
            changed.reminders[index] = saved
        } else {
            guard generation == nil, original == nil, !snapshot.deletedIDs.contains(saved.id) else { throw Problem.deleted }
            changed.reminders.append(saved)
        }
        return Change(snapshot: changed, retiring: retired)
    }

    static func deleting(_ reminder: Reminder, in snapshot: ReminderSnapshot) -> Change? {
        guard let index = snapshot.reminders.firstIndex(where: {
            $0.id == reminder.id && $0.generation == reminder.generation
        }) else { return nil }
        var changed = snapshot
        let removed = changed.reminders.remove(at: index)
        changed.deletedIDs.insert(removed.id)
        return Change(snapshot: changed, retiring: removed)
    }

    static func completing(_ reminder: Reminder, in snapshot: ReminderSnapshot, now: Date = .now,
                           calendar: Calendar = .autoupdatingCurrent, observedGenerations: Set<String> = []) -> Change? {
        guard let index = currentIndex(reminder, in: snapshot) else { return nil }
        let previous = snapshot.reminders[index]
        let next = previous.nextOccurrence(after: now, calendar: calendar)
        guard previous.preferences.repeatRule == .never || next != nil else { return nil }
        let nextGeneration = UUID()
        guard observedGenerations.allSatisfy({ token in
            guard let request = PendingNudge("nudge.\(token).0") else { return false }
            return request.generationIdentifier == token && request.id == previous.id
                && request.generation != nextGeneration
        }) else { return nil }
        var changed = snapshot
        var stopped = changed.stoppedNotificationGenerations ?? []
        stopped.formUnion(observedGenerations)
        stopped.insert("\(previous.id.uuidString).\(previous.generation.uuidString)")
        changed.stoppedNotificationGenerations = stopped
        changed.reminders[index].generation = nextGeneration
        changed.reminders[index].snoozedUntil = nil
        let completedForDay = calendar.startOfDay(for: previous.alertDate) > calendar.startOfDay(for: now)
            ? ReminderDay(previous.alertDate, calendar: calendar) : nil
        if let next {
            var occurrence = changed.reminders[index]
            occurrence.id = UUID()
            occurrence.completedAt = now
            occurrence.completedForDay = completedForDay
            occurrence.precompletedDays = nil
            changed.reminders[index].due = next
            changed.reminders[index].adjustedDue = nil
            let nextDay = ReminderDay(next, calendar: calendar).date(in: calendar) ?? next
            let remaining = previous.precompletedDays?.filter { ($0.date(in: calendar) ?? .distantPast) >= nextDay }
            changed.reminders[index].precompletedDays = remaining?.isEmpty == false ? remaining : nil
            if let schedule = previous.phoneSchedule,
               var resolved = schedule.resolvingCalendar(relativeTo: previous.due, calendar: calendar),
               let recurrenceCalendar = resolved.resolvedCalendar(relativeTo: previous.due, calendar: calendar) {
                resolved.day = recurrenceCalendar.dateComponents([.era, .year, .month, .day], from: next)
                resolved.prefersSecondOccurrence = nil
                changed.reminders[index].phoneSchedule = resolved
            }
            changed.reminders.append(occurrence)
        } else {
            changed.reminders[index].completedAt = now
            changed.reminders[index].completedForDay = completedForDay
        }
        return Change(snapshot: changed, retiring: previous)
    }

    static func completingProjected(_ occurrence: ReminderOccurrence, in snapshot: ReminderSnapshot, now: Date = .now,
                                    calendar: Calendar = .autoupdatingCurrent) -> Change? {
        guard occurrence.isProjected, let index = currentIndex(occurrence.reminder, in: snapshot) else { return nil }
        let series = snapshot.reminders[index]
        guard ReminderOccurrence.entries(reminders: [series], on: occurrence.date, now: now, calendar: calendar)
            .contains(where: { $0.isProjected && $0.id == occurrence.id }) else { return nil }

        let completedDay = ReminderDay(occurrence.date, calendar: calendar)
        var changed = snapshot
        var days = series.precompletedDays ?? []
        days.insert(completedDay)
        changed.reminders[index].precompletedDays = days

        var history = series
        history.id = UUID()
        history.generation = UUID()
        history.due = occurrence.date
        history.adjustedDue = nil
        history.snoozedUntil = nil
        history.completedAt = now
        history.completedForDay = completedDay
        history.precompletedDays = nil
        if var schedule = series.phoneSchedule?.resolvingCalendar(relativeTo: series.due, calendar: calendar),
           let recurrenceCalendar = schedule.resolvedCalendar(relativeTo: series.due, calendar: calendar) {
            schedule.day = recurrenceCalendar.dateComponents([.era, .year, .month, .day], from: occurrence.date)
            schedule.prefersSecondOccurrence = nil
            history.phoneSchedule = schedule
        }
        changed.reminders.append(history)
        return Change(snapshot: changed, retiring: nil)
    }

    static func restoring(_ reminder: Reminder, in snapshot: ReminderSnapshot, now: Date = .now) -> Change? {
        guard let previous = snapshot.reminders.first(where: {
            $0.id == reminder.id && $0.generation == reminder.generation && $0.completedAt != nil
        }) else { return nil }
        var restored = previous
        restored.completedAt = nil
        restored.completedForDay = nil
        restored.snoozedUntil = nil
        // Undo restores the occurrence at its original time. An overdue one is
        // visible in Needs attention; its active recurring series stays separate.
        restored.preferences.repeatRule = .never
        return try? saving(restored, replacing: previous.generation, expecting: previous, in: snapshot, now: now)
    }

    static func snoozing(_ reminder: Reminder, in snapshot: ReminderSnapshot, now: Date = .now) -> Change? {
        guard let index = currentIndex(reminder, in: snapshot) else { return nil }
        let previous = snapshot.reminders[index]
        guard previous.occurrenceDue <= now else { return nil }
        var changed = snapshot
        changed.reminders[index].generation = UUID()
        changed.reminders[index].snoozedUntil = now.addingTimeInterval(15 * 60)
        return Change(snapshot: changed, retiring: previous)
    }

    static func adjusting(_ reminder: Reminder, by shift: ReminderTimeShift, direction: ReminderTimeShift.Direction,
                          in snapshot: ReminderSnapshot, now: Date = .now,
                          calendar: Calendar = .autoupdatingCurrent) -> Change? {
        guard let index = currentIndex(reminder, in: snapshot) else { return nil }
        let previous = snapshot.reminders[index]
        guard let due = shift.date(from: previous.alertDate, direction: direction, now: now, calendar: calendar) else {
            return nil
        }
        var changed = snapshot
        changed.reminders[index].generation = UUID()
        changed.reminders[index].adjustedDue = due
        changed.reminders[index].snoozedUntil = nil
        return Change(snapshot: changed, retiring: previous)
    }

    static func matchesEditableVersion(_ current: Reminder, _ expected: Reminder) -> Bool {
        var current = current
        var expected = expected
        // Scheduling can record acceptance while an editor is open. It does not
        // change editable content and must not invalidate the user's draft.
        current.soundOnlyAfterIndex = nil
        current.soundOnlyAnchorAccepted = nil
        expected.soundOnlyAfterIndex = nil
        expected.soundOnlyAnchorAccepted = nil
        return current == expected
    }

    static func refreshingSchedules(in snapshot: ReminderSnapshot,
                                    calendar: Calendar = .autoupdatingCurrent) -> ReminderSnapshot {
        var changed = snapshot
        for index in changed.reminders.indices where changed.reminders[index].completedAt == nil {
            let previous = changed.reminders[index]
            guard let schedule = previous.phoneSchedule,
                  let resolved = schedule.resolvingCalendar(relativeTo: previous.due, calendar: calendar),
                  let due = resolved.dueDate(referenceDate: previous.due, calendar: calendar) else { continue }
            changed.reminders[index].phoneSchedule = resolved
            if due != previous.due {
                changed.reminders[index].due = due
                // Snooze is elapsed time and keeps its own scheduled identity.
                if previous.snoozedUntil == nil { changed.reminders[index].generation = UUID() }
            }
        }
        return changed
    }

    private static func sameClock(_ lhs: PhoneSchedule?, _ rhs: PhoneSchedule?, referenceDate: Date) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (.some(lhs), .some(rhs)):
            return lhs.day == rhs.day && lhs.hour == rhs.hour && lhs.minute == rhs.minute
                && lhs.resolvedCalendar(relativeTo: referenceDate)?.identifier
                    == rhs.resolvedCalendar(relativeTo: referenceDate)?.identifier
                && (lhs.prefersSecondOccurrence == true) == (rhs.prefersSecondOccurrence == true)
        default: return false
        }
    }

    private static func currentIndex(_ reminder: Reminder, in snapshot: ReminderSnapshot) -> Int? {
        snapshot.reminders.firstIndex {
            $0.id == reminder.id && $0.generation == reminder.generation && $0.completedAt == nil
        }
    }
}
