import Foundation

// A SwiftUI button can still hold the preceding render's generation when a
// second tap arrives. Accept only generations produced by this adjustment
// sequence, never an unrelated edit or a completed recurring occurrence.
struct QuickAdjustmentSequence {
    private struct Chain {
        var current: UUID
        var accepted: Set<UUID>
    }
    private var chains: [UUID: Chain] = [:]

    func currentReminder(for submitted: Reminder, in snapshot: ReminderSnapshot) -> Reminder? {
        guard let current = snapshot.reminders.first(where: {
            $0.id == submitted.id && $0.completedAt == nil
        }) else { return nil }
        if current.generation == submitted.generation { return current }
        guard let chain = chains[submitted.id], chain.current == current.generation,
              chain.accepted.contains(submitted.generation) else { return nil }
        return current
    }

    mutating func record(previous: Reminder, next: Reminder) {
        guard previous.id == next.id else { return }
        var chain = chains[previous.id].flatMap { $0.current == previous.generation ? $0 : nil }
            ?? Chain(current: previous.generation, accepted: [previous.generation])
        chain.accepted.insert(next.generation)
        chain.current = next.generation
        chains[previous.id] = chain
    }

    mutating func reset() { chains.removeAll() }
}

struct NotificationRetryBudget {
    private(set) var attempts = 0
    let maximum: Int
    init(maximum: Int = 6) { self.maximum = max(0, maximum) }
    var exhausted: Bool { attempts >= maximum }
    mutating func reset() { attempts = 0 }
    mutating func consume() -> Bool {
        guard !exhausted else { return false }
        attempts += 1
        return true
    }
}
