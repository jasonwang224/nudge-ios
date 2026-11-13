import Foundation
import UserNotifications

let now = Date(timeIntervalSince1970: 1_800_000_000)
func reminder(_ index: Int, minutes: Int = 5) -> Reminder {
    var p = ReminderPreferences(); p.nagMinutes = minutes
    let date = now.addingTimeInterval(Double(60 + index))
    return Reminder(title: "Reminder \(index)", notes: "", due: date, repeatAnchor: date, preferences: p)
}
let five = (0..<6).map { reminder($0) }
let fiveOnly = FiveMinuteAllocation(reminders: Array(five.prefix(5)), now: now, capacity: 60, existingIDs: [])
precondition(fiveOnly.repeatingIDs.count == 5 && fiveOnly.fallbackCount == 0)
let six = FiveMinuteAllocation(reminders: five, now: now, capacity: 60, existingIDs: [five[5].id])
precondition(six.repeatingIDs.count == 4 && six.fallbackCount == 2)
precondition(six.repeatingIDs.contains(five[5].id), "Prefer the accepted group before spending slots on a new one")
let others = (10..<20).map { reminder($0, minutes: 0) }
let mixed = FiveMinuteAllocation(reminders: Array(five.prefix(5)) + others, now: now, capacity: 60, existingIDs: [])
precondition(mixed.repeatingIDs.count == 4)
precondition(mixed.repeatingIDs.count * 12 + (5 - mixed.repeatingIDs.count) + others.count <= 60)
precondition(FiveMinuteAllocation(reminders: five, now: now, capacity: 5, existingIDs: []).repeatingIDs.isEmpty)
var completed = five[0]; completed.completedAt = now
var disabled = five[1]; disabled.preferences.notifications = false
precondition(FiveMinuteAllocation(reminders: [completed, disabled], now: now, capacity: 60, existingIDs: []).repeatingIDs.isEmpty)
let unsupported = [1, 2, 10, 15, 20, 30].map { reminder($0, minutes: $0) }
precondition(FiveMinuteAllocation(reminders: unsupported, now: now, capacity: 60, existingIDs: []).repeatingIDs.isEmpty)

func phase(_ index: Int, id: String = "group") -> UNNotificationRequest {
    let c = UNMutableNotificationContent(); c.title = "Five minute"
    c.userInfo = [FiveMinuteSchedule.phaseKey: index]
    return UNNotificationRequest(identifier: id, content: c,
        trigger: UNCalendarNotificationTrigger(dateMatching: DateComponents(minute: index * 5), repeats: true))
}
let phases = (0..<12).map { phase($0) }
precondition(FiveMinuteSchedule.matches(Array(phases.reversed()), phases))
var broken = phases; broken[11] = phases[0]
precondition(!FiveMinuteSchedule.matches(broken, phases), "Do not confuse identifier equality with phase equality")
precondition(!FiveMinuteSchedule.matches(Array(phases.dropLast()), phases))
precondition(!FiveMinuteSchedule.matches(phases + [phase(0, id: "other")], phases))
let full = phases + [phase(0, id: "other")]
let archive = try NSKeyedArchiver.archivedData(withRootObject: full, requiringSecureCoding: true)
let decoded = try NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSArray.self, UNNotificationRequest.self], from: archive) as! [UNNotificationRequest]
precondition(FiveMinuteSchedule.matches(decoded, full), "Recovery must retain duplicate phases AND unrelated requests")

// Snooze creates a new action generation and first fire; Done stops only that
// generation while daily recurrence survives. Allocation must use the new state.
var daily = five[0]; daily.preferences.repeatRule = .daily
let snapshot = ReminderSnapshot(reminders: [daily, five[1]])
let actionTime = daily.due.addingTimeInterval(1)
precondition(ReminderLifecycle.snoozing(daily, in: snapshot, now: now) == nil, "A future reminder cannot be snoozed before it fires")
let snoozed = ReminderLifecycle.snoozing(daily, in: snapshot, now: actionTime)!.snapshot
let paused = snoozed.reminders.first { $0.id == daily.id }!
precondition(paused.generation != daily.generation && paused.alertDate == actionTime.addingTimeInterval(900))
let done = ReminderLifecycle.completing(daily, in: snapshot, now: daily.due.addingTimeInterval(1))!.snapshot
precondition(done.reminders.contains { $0.id == daily.id && $0.generation != daily.generation && $0.due > daily.due })
precondition(done.reminders.contains { $0 == five[1] })
print("Five-minute allocation, phase multiset, recovery archive, Snooze and daily Done checks passed.")
