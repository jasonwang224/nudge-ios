import Foundation

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(secondsFromGMT: 0)!
let now = Date(timeIntervalSince1970: 1_800_000_000)
let initialDue = now.addingTimeInterval(10 * 24 * 3600)
func reminder(_ title: String, repeating: Bool = false) -> Reminder {
    var preferences = ReminderPreferences()
    preferences.nagMinutes = 1
    preferences.repeatRule = repeating ? .daily : .never
    return Reminder(title: title, notes: "", due: initialDue, repeatAnchor: initialDue, preferences: preferences)
}
let unrelated = reminder("Unrelated reminder")

// All six menu buttons must accumulate taps from a preceding SwiftUI render.
// The second and third taps intentionally submit the original generation.
for shift in ReminderTimeShift.allCases {
    let seconds: TimeInterval
    switch shift {
    case .fiveMinutes: seconds = 300
    case .hour: seconds = 3600
    case .day: seconds = 86400 // Fixed UTC calendar keeps this fixture outside DST.
    }
    for direction in [ReminderTimeShift.Direction.earlier, .later] {
        let original = reminder("Burst adjustment", repeating: true)
        var snapshot = ReminderSnapshot(reminders: [original, unrelated])
        var sequence = QuickAdjustmentSequence()
        var generations: Set<UUID> = [original.generation]
        let sign: Double = direction == .earlier ? -1 : 1
        for tap in 1...3 {
            let current = sequence.currentReminder(for: original, in: snapshot)!
            precondition(current == snapshot.reminders.first { $0.id == original.id }!)
            let change = ReminderLifecycle.adjusting(current, by: shift, direction: direction,
                in: snapshot, now: now, calendar: calendar)!
            let next = change.snapshot.reminders.first { $0.id == original.id }!
            precondition(change.retiring == current)
            precondition(next.alertDate == initialDue.addingTimeInterval(sign * seconds * Double(tap)),
                         "Every quick tap must adjust the latest time exactly once")
            precondition(next.due == original.due && next.repeatAnchor == original.repeatAnchor)
            precondition(next.preferences.repeatRule == .daily && next.snoozedUntil == nil)
            precondition(!generations.contains(next.generation))
            generations.insert(next.generation)
            sequence.record(previous: current, next: next)
            snapshot = change.snapshot
            precondition(snapshot.reminders.contains(unrelated), "Other reminders must remain untouched")
        }
        precondition(generations.count == 4)
        let latest = snapshot.reminders.first { $0.id == original.id }!
        let persisted = try JSONEncoder().encode(snapshot.validated())
        let restored = try JSONDecoder().decode(ReminderSnapshot.self, from: persisted).validated()
        precondition(restored == snapshot, "The final rapid-tap state must survive persistence")
        precondition(restored.reminders.first { $0.id == original.id } == latest)
        precondition(restored.reminders.contains(unrelated))
        precondition(sequence.currentReminder(for: original, in: snapshot) == latest)
        sequence.reset()
        precondition(sequence.currentReminder(for: original, in: snapshot) == nil,
                     "A reset must invalidate preceding render generations")
        precondition(sequence.currentReminder(for: latest, in: snapshot) == latest)
    }
}

// An unrelated edit ends an adjustment chain. The old closure must not shift
// newly edited content just because the reminder's persistent ID still matches.
let original = reminder("Edited reminder", repeating: true)
var snapshot = ReminderSnapshot(reminders: [original, unrelated])
var sequence = QuickAdjustmentSequence()
let adjustment = ReminderLifecycle.adjusting(original, by: .fiveMinutes, direction: .later,
    in: snapshot, now: now, calendar: calendar)!
let adjusted = adjustment.snapshot.reminders.first { $0.id == original.id }!
sequence.record(previous: original, next: adjusted)
snapshot = adjustment.snapshot
var draft = adjusted
draft.title = "Edited elsewhere"
let editedSnapshot = try ReminderLifecycle.saving(draft, replacing: adjusted.generation, expecting: adjusted,
    in: snapshot, now: now).snapshot
let edited = editedSnapshot.reminders.first { $0.id == original.id }!
precondition(edited.generation != adjusted.generation)
precondition(sequence.currentReminder(for: original, in: editedSnapshot) == nil)
precondition(sequence.currentReminder(for: adjusted, in: editedSnapshot) == nil)
precondition(sequence.currentReminder(for: edited, in: editedSnapshot) == edited)
precondition(editedSnapshot.reminders.contains(unrelated))

// Done advances a daily series under the same reminder ID. Neither the original
// nor the preceding adjusted closure may accidentally adjust that next instance.
let completedSnapshot = ReminderLifecycle.completing(adjusted, in: snapshot,
    now: adjusted.alertDate.addingTimeInterval(1), calendar: calendar)!.snapshot
let nextOccurrence = completedSnapshot.reminders.first { $0.id == original.id }!
precondition(nextOccurrence.completedAt == nil && nextOccurrence.due > adjusted.due)
precondition(nextOccurrence.generation != adjusted.generation)
precondition(sequence.currentReminder(for: original, in: completedSnapshot) == nil)
precondition(sequence.currentReminder(for: adjusted, in: completedSnapshot) == nil)
precondition(sequence.currentReminder(for: nextOccurrence, in: completedSnapshot) == nextOccurrence)
precondition(completedSnapshot.reminders.contains(unrelated))
let deletedSnapshot = ReminderLifecycle.deleting(adjusted, in: snapshot)!.snapshot
precondition(sequence.currentReminder(for: original, in: deletedSnapshot) == nil)
let oneOff = reminder("One-off")
let doneOneOff = ReminderLifecycle.completing(oneOff, in: ReminderSnapshot(reminders: [oneOff]), now: now)!.snapshot
precondition(sequence.currentReminder(for: oneOff, in: doneOneOff) == nil)

// A new edit or a successful reconciliation can reset the retry allowance.
// Exhaustion itself must never grant extra attempts on repeated consume calls.
var budget = NotificationRetryBudget()
precondition(budget.maximum == 6 && budget.attempts == 0 && !budget.exhausted)
for attempt in 1...6 {
    precondition(budget.consume())
    precondition(budget.attempts == attempt)
}
precondition(budget.exhausted)
for _ in 0..<3 { precondition(!budget.consume() && budget.attempts == 6) }
budget.reset()
precondition(budget.attempts == 0 && !budget.exhausted)
precondition(budget.consume() && budget.attempts == 1)
budget.reset()
for _ in 0..<6 { precondition(budget.consume()) }
precondition(!budget.consume() && budget.exhausted)
for maximum in [-1, 0] {
    var disabled = NotificationRetryBudget(maximum: maximum)
    precondition(disabled.maximum == 0 && disabled.exhausted && !disabled.consume())
    disabled.reset()
    precondition(disabled.attempts == 0 && disabled.exhausted)
}

print("Quick adjustment checks passed: all six buttons accumulate and persist stale-render taps with one-minute nags, unrelated edits and completed/deleted occurrences reject stale closures, and retry budgets exhaust/reset correctly.")
