import Foundation

enum RepeatRule: String, Codable, CaseIterable, Identifiable {
    case never = "Never"
    case daily = "Daily"
    case weekdays = "Weekdays"
    case weekly = "Weekly"
    case monthly = "Monthly"
    case yearly = "Yearly"
    case custom = "Custom"

    var id: String { rawValue }
}

enum AlertSound: String, Codable, CaseIterable, Identifiable {
    case system = "iPhone default"
    case glass = "Glass"
    case droplet = "Droplet"
    case chime = "Chime"
    case digitalChime = "Digital Chime"
    case silent = "Silent"

    var id: String { rawValue }

    var fileName: String? {
        switch self {
        case .glass, .droplet, .chime: return rawValue + ".wav"
        case .digitalChime: return "DigitalChime.wav"
        case .system, .silent: return nil
        }
    }
}

struct ReminderPreferences: Codable, Equatable {
    static let nagIntervals = [0, 2, 5, 10, 15, 20, 30]

    var nagMinutes = 5
    var repeatRule = RepeatRule.never
    var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    var notifications = true
    var sound = AlertSound.chime
}

struct PhoneSchedule: Codable, Equatable {
    var day: DateComponents
    var anchorDay: DateComponents
    var hour: Int
    var minute: Int
    // Freeze chronology, not timezone. A phone calendar preference must never
    // reinterpret a saved year/era in another calendar.
    var storedCalendar: Calendar?
    // Only the current explicitly chosen date can use the second repeated hour.
    // Future recurring dates continue to use the first matching local time.
    var prefersSecondOccurrence: Bool?

    init(day: Date, hour: Int, minute: Int, calendar: Calendar = .autoupdatingCurrent) {
        self.day = calendar.dateComponents([.era, .year, .month, .day], from: day)
        anchorDay = self.day
        self.hour = hour
        self.minute = minute
        storedCalendar = Calendar(identifier: calendar.identifier)
        prefersSecondOccurrence = nil
    }

    func dueDate(referenceDate: Date? = nil, calendar: Calendar = .autoupdatingCurrent) -> Date? {
        let resolved: Calendar?
        if let storedCalendar {
            resolved = Self.withCurrentTimeZone(storedCalendar, from: calendar)
        } else if let referenceDate {
            resolved = resolvedCalendar(relativeTo: referenceDate, calendar: calendar)
        } else {
            resolved = nil
        }
        guard let resolved, let date = resolved.date(from: day) else { return nil }
        return time(on: date, calendar: resolved,
                    repeatedTimePolicy: prefersSecondOccurrence == true ? .last : .first)
    }

    func resolvedCalendar(relativeTo referenceDate: Date,
                          calendar: Calendar = .autoupdatingCurrent) -> Calendar? {
        if let storedCalendar { return Self.withCurrentTimeZone(storedCalendar, from: calendar) }

        // Legacy components have no calendar identity. Infer only a unique
        // chronology compatible with the persisted absolute date; never assume
        // Gregorian or stamp the phone's newly selected calendar onto old data.
        // Limit inference to these verified iPhone calendar identities. Other
        // legacy chronologies stay untouched until an explicit schedule edit;
        // some Foundation identifiers alias Gregorian on particular runtimes.
        // Allow a full timezone change plus one repeated DST hour.
        let identifiers: [Calendar.Identifier] = [.gregorian, .buddhist, .japanese]
        let matches = identifiers.compactMap { identifier -> Calendar? in
            var candidate = Calendar(identifier: identifier)
            candidate.timeZone = calendar.timeZone
            guard let date = candidate.date(from: day),
                  Self.sameDayComponents(day, candidate.dateComponents([.era, .year, .month, .day], from: date)),
                  let first = time(on: date, calendar: candidate, repeatedTimePolicy: .first),
                  let last = time(on: date, calendar: candidate, repeatedTimePolicy: .last),
                  min(abs(first.timeIntervalSince(referenceDate)), abs(last.timeIntervalSince(referenceDate))) <= 27 * 3600
            else { return nil }
            return candidate
        }
        // ISO 8601 and Gregorian have identical era/year/month/day arithmetic;
        // a legacy ISO record is deliberately represented by Gregorian above.
        return matches.count == 1 ? matches[0] : nil
    }

    func resolvingCalendar(relativeTo referenceDate: Date,
                           calendar: Calendar = .autoupdatingCurrent) -> Self? {
        guard let resolved = resolvedCalendar(relativeTo: referenceDate, calendar: calendar) else { return nil }
        var result = self
        if result.storedCalendar == nil { result.storedCalendar = Calendar(identifier: resolved.identifier) }
        return result
    }

    func time(on day: Date, calendar: Calendar) -> Date? {
        time(on: day, calendar: calendar, repeatedTimePolicy: .first)
    }

    private func time(on day: Date, calendar: Calendar,
                      repeatedTimePolicy: Calendar.RepeatedTimePolicy) -> Date? {
        guard let time = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day,
                                       matchingPolicy: .nextTime, repeatedTimePolicy: repeatedTimePolicy),
              calendar.isDate(day, inSameDayAs: time) else { return nil }
        return time
    }

    private static func withCurrentTimeZone(_ stored: Calendar, from current: Calendar) -> Calendar {
        var result = Calendar(identifier: stored.identifier)
        result.timeZone = current.timeZone
        return result
    }

    private static func sameDayComponents(_ lhs: DateComponents, _ rhs: DateComponents) -> Bool {
        lhs.era == rhs.era && lhs.year == rhs.year && lhs.month == rhs.month && lhs.day == rhs.day
            && (lhs.isLeapMonth == nil || lhs.isLeapMonth == rhs.isLeapMonth)
    }
}

// Use a local civil date so a completed day survives changes to the clock,
// time zone, or the iPhone's display calendar.
struct ReminderDay: Codable, Hashable {
    private let components: DateComponents

    init(_ date: Date, calendar: Calendar) {
        components = Self.localGregorian(calendar).dateComponents([.era, .year, .month, .day], from: date)
    }

    func date(in calendar: Calendar) -> Date? {
        Self.localGregorian(calendar).date(from: components)
    }

    private static func localGregorian(_ calendar: Calendar) -> Calendar {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return gregorian
    }
}

struct Reminder: Codable, Identifiable, Equatable {
    var id = UUID()
    var generation = UUID()
    var title: String
    var notes: String
    var due: Date
    var repeatAnchor: Date
    var preferences: ReminderPreferences
    var phoneSchedule: PhoneSchedule?
    var adjustedDue: Date?
    var snoozedUntil: Date?
    var completedAt: Date?
    var completedForDay: ReminderDay?
    var precompletedDays: Set<ReminderDay>?
    // Optional for backward compatibility. Legacy generations keep visible nags.
    var soundOnlyAfterIndex: Int?
    var soundOnlyAnchorAccepted: Bool?

    var occurrenceDue: Date { adjustedDue ?? due }
    var alertDate: Date { snoozedUntil ?? occurrenceDue }

    var hasValidSchedule: Bool {
        let dates = [due, repeatAnchor, adjustedDue, snoozedUntil, completedAt].compactMap { $0 }
        return dates.allSatisfy { abs($0.timeIntervalSinceReferenceDate) < 100_000_000_000 }
            && ReminderPreferences.nagIntervals.contains(preferences.nagMinutes)
            && preferences.weekdays.allSatisfy { (1...7).contains($0) }
            && (soundOnlyAfterIndex.map { $0 >= 0 } ?? true)
            && (phoneSchedule.map { (0...23).contains($0.hour) && (0...59).contains($0.minute) } ?? true)
    }

    func nextOccurrence(after now: Date, calendar currentCalendar: Calendar = .autoupdatingCurrent) -> Date? {
        let rule = preferences.repeatRule
        guard rule != .never else { return nil }
        let calendar: Calendar
        if let phoneSchedule {
            guard let resolved = phoneSchedule.resolvedCalendar(relativeTo: due, calendar: currentCalendar) else { return nil }
            calendar = resolved
        } else {
            calendar = currentCalendar
        }
        let cutoff = max(now, due)
        let anchor = phoneSchedule.flatMap { calendar.date(from: $0.anchorDay) } ?? repeatAnchor
        let anchorDay = calendar.startOfDay(for: anchor)
        let cutoffDay = calendar.startOfDay(for: cutoff)
        let elapsedDays = calendar.dateComponents([.day], from: anchorDay, to: cutoffDay).day ?? 0
        let clock = calendar.dateComponents([.hour, .minute, .second], from: repeatAnchor)
        let skipped = precompletedDays ?? []
        func shouldSchedule(_ candidate: Date) -> Bool {
            candidate > cutoff && (skipped.isEmpty || !skipped.contains(ReminderDay(candidate, calendar: calendar)))
        }

        if rule == .monthly || rule == .yearly {
            let unit: Calendar.Component = rule == .yearly ? .year : .month
            guard let anchorMonth = calendar.dateInterval(of: .month, for: anchor)?.start,
                  let anchorPeriod = calendar.dateInterval(of: unit, for: anchor)?.start,
                  let cutoffPeriod = calendar.dateInterval(of: unit, for: cutoff)?.start else { return nil }
            let elapsed = calendar.dateComponents([unit], from: anchorPeriod, to: cutoffPeriod).value(for: unit) ?? 0
            let firstOffset = max(0, elapsed)
            let originalDay = calendar.component(.day, from: anchor)
            // Start each search from the original month so a clamped date does
            // not change the anchor when the next period has more days.
            for offset in firstOffset...(firstOffset + 1 + skipped.count) {
                guard let shiftedMonth = calendar.date(byAdding: unit, value: offset, to: anchorMonth),
                      let month = calendar.dateInterval(of: .month, for: shiftedMonth)?.start,
                      let days = calendar.range(of: .day, in: .month, for: month),
                      let day = calendar.date(byAdding: .day, value: min(originalDay, days.count) - 1, to: month),
                      let candidate = atTime(clock, on: day, calendar: calendar) else { continue }
                if shouldSchedule(candidate) { return candidate }
            }
            return nil
        }

        for offset in max(0, elapsedDays)...(max(0, elapsedDays) + 7 * (1 + skipped.count)) {
            if rule == .weekly && offset % 7 != 0 { continue }
            guard let day = calendar.date(byAdding: .day, value: offset, to: anchorDay) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            if rule == .weekdays && (weekday == 1 || weekday == 7) { continue }
            if rule == .custom && !preferences.weekdays.contains(weekday) { continue }
            if let candidate = atTime(clock, on: day, calendar: calendar), shouldSchedule(candidate) {
                return candidate
            }
        }
        return nil
    }

    private func atTime(_ clock: DateComponents, on day: Date, calendar: Calendar) -> Date? {
        if let phoneSchedule { return phoneSchedule.time(on: day, calendar: calendar) }
        return calendar.date(bySettingHour: clock.hour ?? 0, minute: clock.minute ?? 0,
                             second: clock.second ?? 0, of: day)
    }
}

struct ScheduledAlert: Equatable {
    static let prefix = "nudge."
    var reminder: Reminder
    var index: Int
    var date: Date

    var identifier: String {
        "\(Self.prefix)\(reminder.id.uuidString).\(reminder.generation.uuidString).\(index)"
    }
}

// Cancellation requires positive evidence: an explicit stop, or an accepted
// replacement for this reminder. An absent record alone is never evidence.
struct PendingNudge {
    let identifier: String
    let id: UUID
    let generation: UUID
    let index: Int

    init?(_ identifier: String) {
        let parts = identifier.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "nudge",
              let id = UUID(uuidString: String(parts[1])),
              let generation = UUID(uuidString: String(parts[2])),
              let index = Int(parts[3]), index >= 0 else { return nil }
        self.identifier = identifier
        self.id = id
        self.generation = generation
        self.index = index
    }

    var generationIdentifier: String { "\(id.uuidString).\(generation.uuidString)" }

    func canRetire(current: [UUID: Reminder], deletedIDs: Set<UUID>, queuedReplacement: Set<UUID>,
                   stoppedGenerations: Set<String> = [], now: Date = .now) -> Bool {
        if stoppedGenerations.contains(generationIdentifier) { return true }
        if deletedIDs.contains(id) { return true }
        guard let reminder = current[id] else { return false }
        // Turning Nag Me off is explicit evidence to stop followups, even if
        // an overdue one-shot reminder has no future replacement to accept.
        // A future primary still needs an accepted replacement before removal.
        let nagsStopped = reminder.hasValidSchedule && reminder.preferences.nagMinutes == 0
            && (index > 0 || (generation != reminder.generation && reminder.alertDate <= now))
        return reminder.completedAt != nil || !reminder.preferences.notifications || nagsStopped
            || (generation != reminder.generation && queuedReplacement.contains(id))
    }

    static func expendable(in pending: [Self], current: [UUID: Reminder], desired: Set<String>) -> Self? {
        // Never evict a primary, an accepted visible anchor (which may be a
        // later index after a delayed first schedule), or a reminder's last alert.
        let counts = Dictionary(grouping: pending, by: \.id).mapValues(\.count)
        return pending.filter {
            current[$0.id] != nil && !desired.contains($0.identifier)
                && $0.index > 0 && (counts[$0.id] ?? 0) > 1
                && !(current[$0.id]?.generation == $0.generation
                     && current[$0.id]?.soundOnlyAnchorAccepted == true
                     && current[$0.id]?.soundOnlyAfterIndex == $0.index)
        }.max { $0.index < $1.index }
    }
}

struct DeliveredNudge {
    private let request: PendingNudge
    private let date: Date

    init?(identifier: String, date: Date) {
        guard let request = PendingNudge(identifier) else { return nil }
        self.request = request
        self.date = date
    }

    static func supersededIdentifiers(in delivered: [Self], by incoming: Self? = nil) -> [String] {
        if let incoming {
            // The foreground alert may not be in Notification Center yet.
            return delivered.compactMap { $0.identifierIfSuperseded(by: incoming) }
        }

        return Dictionary(grouping: delivered, by: \.request.id).values.flatMap { group -> [String] in
            guard let newest = group.max(by: { $0.isOlder(than: $1) }) else { return [] }
            return group.compactMap { $0.identifierIfSuperseded(by: newest) }
        }
    }

    private func identifierIfSuperseded(by newer: Self) -> String? {
        guard request.id == newer.request.id, request.identifier != newer.request.identifier,
              isOlder(than: newer) else { return nil }
        return request.identifier
    }

    private func isOlder(than other: Self) -> Bool {
        if date != other.date { return date < other.date }
        if request.generation == other.request.generation { return request.index < other.request.index }
        return request.identifier < other.request.identifier
    }
}

struct AlertPlan {
    // Reserve a margin under the historically documented 64-request capacity.
    static let capacity = 60
    var alerts: [ScheduledAlert]
    var unscheduledFirstAlerts: Int

    init(reminders: [Reminder], now: Date, capacity: Int = AlertPlan.capacity) {
        let first = reminders.compactMap { reminder -> ScheduledAlert? in
            guard reminder.hasValidSchedule, reminder.completedAt == nil, reminder.preferences.notifications else { return nil }
            let start = reminder.alertDate
            let interval = TimeInterval(reminder.preferences.nagMinutes * 60)
            if start > now { return ScheduledAlert(reminder: reminder, index: 0, date: start) }
            guard interval > 0 else { return nil }
            guard let elapsed = Int(exactly: (now.timeIntervalSince(start) / interval).rounded(.down)),
                  elapsed < Int.max - AlertPlan.capacity else { return nil }
            let index = elapsed + 1
            return ScheduledAlert(reminder: reminder, index: index, date: start.addingTimeInterval(Double(index) * interval))
        }.sorted { $0.date == $1.date ? $0.identifier < $1.identifier : $0.date < $1.date }

        alerts = Array(first.prefix(capacity))
        unscheduledFirstAlerts = max(0, first.count - capacity)
        var next = alerts.compactMap(Self.followingAlert)
        while alerts.count < capacity && !next.isEmpty {
            guard let index = next.indices.min(by: { next[$0].date < next[$1].date }) else { break }
            let alert = next[index]
            alerts.append(alert)
            if let following = Self.followingAlert(after: alert) {
                next[index] = following
            } else {
                next.remove(at: index)
            }
        }
    }

    private static func followingAlert(after alert: ScheduledAlert) -> ScheduledAlert? {
        let minutes = alert.reminder.preferences.nagMinutes
        guard minutes > 0 else { return nil }
        return ScheduledAlert(reminder: alert.reminder, index: alert.index + 1,
                              date: alert.date.addingTimeInterval(TimeInterval(minutes * 60)))
    }
}

// An agenda row is a view of a series, not another saved reminder or queued alert.
// Projected rows keep the original reminder so editing still edits the series.
struct ReminderOccurrence: Identifiable {
    struct ID: Hashable {
        let reminderID: UUID
        let date: Date
    }

    let reminder: Reminder
    let date: Date
    let isProjected: Bool

    var id: ID { ID(reminderID: reminder.id, date: date) }

    init(_ reminder: Reminder) {
        self.reminder = reminder
        date = reminder.alertDate
        isProjected = false
    }

    init(_ reminder: Reminder, projectedDate: Date) {
        self.reminder = reminder
        date = projectedDate
        isProjected = true
    }

    static func entries(reminders: [Reminder], on day: Date?, now: Date,
                        calendar: Calendar = .autoupdatingCurrent) -> [Self] {
        let active = reminders.filter { $0.completedAt == nil }
        guard let day else { return sorted(active.map(Self.init)) }
        let dayStart = calendar.startOfDay(for: day)
        let isToday = calendar.isDate(day, inSameDayAs: now)
        let isFuture = dayStart > calendar.startOfDay(for: now)
        var result: [Self] = []

        for reminder in active {
            if calendar.isDate(reminder.alertDate, inSameDayAs: day)
                || (isToday && (reminder.alertDate <= now || reminder.snoozedUntil != nil)) {
                result.append(Self(reminder))
            }
            guard isFuture, reminder.hasValidSchedule, reminder.preferences.repeatRule != .never else { continue }
            let cutoff = max(dayStart.addingTimeInterval(-1), reminder.alertDate)
            guard let next = reminder.nextOccurrence(after: cutoff, calendar: calendar),
                  calendar.isDate(next, inSameDayAs: day), next != reminder.alertDate else { continue }
            result.append(Self(reminder, projectedDate: next))
        }
        return sorted(result)
    }

    private static func sorted(_ entries: [Self]) -> [Self] {
        entries.sorted {
            $0.date == $1.date ? $0.reminder.id.uuidString < $1.reminder.id.uuidString : $0.date < $1.date
        }
    }
}
