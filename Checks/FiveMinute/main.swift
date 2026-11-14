import Foundation
import UserNotifications

let now = Date(timeIntervalSince1970: 1_800_000_000)
func reminder(_ index: Int, minutes: Int = 5) -> Reminder {
    var p = ReminderPreferences(); p.nagMinutes = minutes
    let date = now.addingTimeInterval(Double(60 + index))
    return Reminder(title: "Reminder \(index)", notes: "", due: date, repeatAnchor: date, preferences: p)
}
let five = (0..<6).map { reminder($0) }
let fiveOnly = HourlyNagAllocation(reminders: Array(five.prefix(5)), now: now, capacity: 60, existingIDs: [])
precondition(fiveOnly.repeatingIDs.count == 5 && fiveOnly.fallbackCount == 0)
let six = HourlyNagAllocation(reminders: five, now: now, capacity: 60, existingIDs: [five[5].id])
precondition(six.repeatingIDs.count == 4 && six.fallbackCount == 2)
precondition(six.repeatingIDs.contains(five[5].id), "Prefer the accepted group before spending slots on a new one")
let others = (10..<20).map { reminder($0, minutes: 0) }
let mixed = HourlyNagAllocation(reminders: Array(five.prefix(5)) + others, now: now, capacity: 60, existingIDs: [])
precondition(mixed.repeatingIDs.count == 4)
precondition(mixed.repeatingIDs.count * 12 + (5 - mixed.repeatingIDs.count) + others.count <= 60)
precondition(HourlyNagAllocation(reminders: five, now: now, capacity: 5, existingIDs: []).repeatingIDs.isEmpty)
var completed = five[0]; completed.completedAt = now
var disabled = five[1]; disabled.preferences.notifications = false
precondition(HourlyNagAllocation(reminders: [completed, disabled], now: now, capacity: 60, existingIDs: []).repeatingIDs.isEmpty)
let unsupported = [0, 1].map { reminder($0, minutes: $0) }
precondition(HourlyNagAllocation(reminders: unsupported, now: now, capacity: 60, existingIDs: []).repeatingIDs.isEmpty)

func phase(_ index: Int, id: String = "group", minutes: Int = 5) -> UNNotificationRequest {
    let c = UNMutableNotificationContent(); c.title = "Five minute"
    c.userInfo = [HourlyNagSchedule.phaseKey: index]
    if minutes != 5 { c.userInfo[HourlyNagSchedule.minutesKey] = minutes }
    return UNNotificationRequest(identifier: id, content: c,
        trigger: UNCalendarNotificationTrigger(dateMatching: DateComponents(minute: index * minutes), repeats: true))
}
let phases = (0..<12).map { phase($0) }
precondition(HourlyNagSchedule.matches(Array(phases.reversed()), phases))
var broken = phases; broken[11] = phases[0]
precondition(!HourlyNagSchedule.matches(broken, phases), "Do not confuse identifier equality with phase equality")
precondition(!HourlyNagSchedule.matches(Array(phases.dropLast()), phases))
precondition(!HourlyNagSchedule.matches(phases + [phase(0, id: "other")], phases))
let full = phases + [phase(0, id: "other")]
let archive = try NSKeyedArchiver.archivedData(withRootObject: full, requiringSecureCoding: true)
let decoded = try NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSArray.self, UNNotificationRequest.self], from: archive) as! [UNNotificationRequest]
precondition(HourlyNagSchedule.matches(decoded, full), "Recovery must retain duplicate phases AND unrelated requests")

// A count alone cannot distinguish loss from normalization. Diagnose each
// unmatched record without collapsing duplicate identifiers or phase copies.
precondition(HourlyNagSchedule.mismatch(Array(phases.reversed()), phases) == nil)
let missingPhase = HourlyNagSchedule.mismatch(Array(phases.dropLast()), phases)!
precondition(missingPhase.exactMatchCount == 11 && missingPhase.missing.count == 1)
precondition(missingPhase.missing[0].contains("phase 11") && missingPhase.extra.isEmpty && missingPhase.changed.isEmpty)
let wrongMultiplicity = HourlyNagSchedule.mismatch(broken, phases)!
precondition(wrongMultiplicity.expectedCount == 12 && wrongMultiplicity.actualCount == 12)
precondition(wrongMultiplicity.exactMatchCount == 11 && wrongMultiplicity.missing.count == 1 && wrongMultiplicity.extra.count == 1)
precondition(wrongMultiplicity.missing[0].contains("phase 11") && wrongMultiplicity.extra[0].contains("phase 0"))
precondition(wrongMultiplicity.changed.isEmpty, "An extra phase zero is not a changed phase eleven")
let extraCopy = HourlyNagSchedule.mismatch(phases + [phases[0]], phases)!
precondition(extraCopy.exactMatchCount == 12 && extraCopy.extra.count == 1 && extraCopy.missing.isEmpty && extraCopy.changed.isEmpty)
let extraReminder = HourlyNagSchedule.mismatch(phases + [phase(0, id: "unrelated")], phases)!
precondition(extraReminder.extra == ["unrelated · phase 0"])

let changedTitle = phases[0].content.mutableCopy() as! UNMutableNotificationContent
changedTitle.title = "Different title"
let titleRequest = UNNotificationRequest(identifier: phases[0].identifier, content: changedTitle, trigger: phases[0].trigger)
let titleMismatch = HourlyNagSchedule.mismatch([titleRequest], [phases[0]])!
precondition(titleMismatch.missing.isEmpty && titleMismatch.extra.isEmpty && titleMismatch.changed.count == 1)
precondition(titleMismatch.changed[0].contentFields == ["title"] && !titleMismatch.changed[0].triggerChanged)
precondition(!HourlyNagSchedule.matches([titleRequest], [phases[0]]), "Diagnostics must not relax acceptance")
let changedTrigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(minute: 1), repeats: true)
let triggerRequest = UNNotificationRequest(identifier: phases[0].identifier, content: phases[0].content, trigger: changedTrigger)
let triggerMismatch = HourlyNagSchedule.mismatch([triggerRequest], [phases[0]])!
precondition(triggerMismatch.changed.count == 1 && triggerMismatch.changed[0].triggerChanged)
precondition(triggerMismatch.changed[0].contentFields.isEmpty && triggerMismatch.missing.isEmpty && triggerMismatch.extra.isEmpty)
let bothRequest = UNNotificationRequest(identifier: phases[0].identifier, content: changedTitle, trigger: changedTrigger)
let bothMismatch = HourlyNagSchedule.mismatch([bothRequest], [phases[0]])!
precondition(bothMismatch.changed[0].contentFields == ["title"] && bothMismatch.changed[0].triggerChanged)

// Exact matches must be consumed before pairing changes even when the same
// identifier and phase appear twice with distinct content in a saved schedule.
let exactFirst = HourlyNagSchedule.mismatch([titleRequest], [phases[0], titleRequest])!
precondition(exactFirst.exactMatchCount == 1 && exactFirst.missing.count == 1 && exactFirst.changed.isEmpty)
let changedSound = phases[0].content.mutableCopy() as! UNMutableNotificationContent
changedSound.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: "Chime.caf"))
let soundRequest = UNNotificationRequest(identifier: phases[0].identifier, content: changedSound, trigger: phases[0].trigger)
let soundMismatch = HourlyNagSchedule.mismatch([soundRequest], [phases[0]])!
// A sound difference can be stored in framework properties not exposed by
// public getters. Accept the named field or explicit other-properties fallback;
// the changed content must still be rejected and its trigger remain unchanged.
precondition(soundMismatch.changed.count == 1 && soundMismatch.missing.isEmpty && soundMismatch.extra.isEmpty,
             soundMismatch.description)
precondition((soundMismatch.changed[0].contentFields.contains("sound") || soundMismatch.changed[0].contentFields == ["other properties"]) && !soundMismatch.changed[0].triggerChanged,
             soundMismatch.description)
precondition(!HourlyNagSchedule.matches([soundRequest], [phases[0]]))
precondition(soundMismatch.description.contains("content.sound") || soundMismatch.description.contains("content.other properties"), soundMismatch.description)
let invalidPhase = phases[0].content.mutableCopy() as! UNMutableNotificationContent
invalidPhase.userInfo[HourlyNagSchedule.phaseKey] = "invalid"
let invalidRequest = UNNotificationRequest(identifier: phases[0].identifier, content: invalidPhase, trigger: phases[0].trigger)
let invalidMismatch = HourlyNagSchedule.mismatch([invalidRequest], [phases[0]])!
precondition(invalidMismatch.missing.count == 1 && invalidMismatch.extra.count == 1 && invalidMismatch.changed.isEmpty)
precondition(invalidMismatch.extra[0].contains("invalid phase metadata"))

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
// Mixed intervals reserve their actual phase costs, not twelve slots per group.
let intervals = [2, 5, 10, 15, 20, 30]
let expectedCosts = [30, 12, 6, 4, 3, 2]
let mixedIntervals = [5, 10, 15, 30].enumerated().map { reminder($0.offset + 100, minutes: $0.element) }
let oneOff = reminder(200, minutes: 0)
let allFit = HourlyNagAllocation(reminders: mixedIntervals + [oneOff], now: now, capacity: 25, existingIDs: [])
precondition(allFit.repeatingIDs.count == 4 && allFit.phaseSlots == 24 && allFit.fallbackCount == 0)
let tight = HourlyNagAllocation(reminders: mixedIntervals + [oneOff], now: now, capacity: 24, existingIDs: [])
precondition(tight.repeatingIDs.count == 3 && tight.phaseSlots == 22 && tight.fallbackCount == 1)
for capacity in 5...64 {
    let allocation = HourlyNagAllocation(reminders: mixedIntervals + [oneOff], now: now, capacity: capacity, existingIDs: [mixedIntervals[3].id])
    let actualCost = mixedIntervals.filter { allocation.repeatingIDs.contains($0.id) }
        .map { HourlyNagCadence(minutes: $0.preferences.nagMinutes)!.phaseCount }.reduce(0, +)
    precondition(actualCost == allocation.phaseSlots)
    precondition(actualCost + (4 - allocation.repeatingIDs.count) + 1 <= capacity)
}
// Two-minute groups consume thirty slots; reserve other reminders' first alerts.
let twoA = reminder(401, minutes: 2)
let twoB = reminder(402, minutes: 2)
let pair = HourlyNagAllocation(reminders: [twoA, twoB], now: now, capacity: 60, existingIDs: [])
precondition(pair.phaseSlots == 60 && pair.repeatingIDs.count == 2)
let crowdedPair = HourlyNagAllocation(reminders: [twoA, twoB, oneOff], now: now, capacity: 60, existingIDs: [])
precondition(crowdedPair.phaseSlots == 30 && crowdedPair.fallbackCount == 1)
let pairAt63 = HourlyNagAllocation(reminders: [twoA, twoB] + Array(others.prefix(3)), now: now, capacity: 63, existingIDs: [])
precondition(pairAt63.phaseSlots == 60 && pairAt63.repeatingIDs.count == 2)
let crowdedAt63 = HourlyNagAllocation(reminders: [twoA, twoB] + Array(others.prefix(4)), now: now, capacity: 63, existingIDs: [twoB.id])
precondition(crowdedAt63.phaseSlots == 30 && crowdedAt63.repeatingIDs == [twoB.id])
let allIntervals = intervals.enumerated().map { reminder(500 + $0.offset, minutes: $0.element) }
let completeMix = HourlyNagAllocation(reminders: allIntervals + [oneOff], now: now, capacity: 58, existingIDs: [])
precondition(completeMix.repeatingIDs.count == 6 && completeMix.phaseSlots == 57)
for capacity in 7...64 {
    let allocated = HourlyNagAllocation(reminders: allIntervals + [oneOff], now: now, capacity: capacity, existingIDs: [allIntervals[4].id])
    let used = allIntervals.filter { allocated.repeatingIDs.contains($0.id) }
        .map { HourlyNagCadence(minutes: $0.preferences.nagMinutes)!.phaseCount }.reduce(0, +)
    precondition(used == allocated.phaseSlots)
    precondition(used + (6 - allocated.repeatingIDs.count) + 1 <= capacity)
}
let twoPhases = (0..<30).map { phase($0, id: "two", minutes: 2) }
let twentyPhases = (0..<3).map { phase($0, id: "twenty", minutes: 20) }
let newGroups = twoPhases + twentyPhases
let newArchive = try NSKeyedArchiver.archivedData(withRootObject: newGroups, requiringSecureCoding: true)
let restoredGroups = try NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSArray.self, UNNotificationRequest.self], from: newArchive) as! [UNNotificationRequest]
precondition(HourlyNagSchedule.matches(restoredGroups, newGroups))
precondition(restoredGroups.filter { HourlyNagSchedule.recordedMinutes($0.content) == 2 }.count == 30)
precondition(restoredGroups.filter { HourlyNagSchedule.recordedMinutes($0.content) == 20 }.count == 3)
precondition(!HourlyNagSchedule.matches(Array(twoPhases.dropLast()) + twentyPhases, newGroups))
for (minutes, cost) in zip(intervals, expectedCosts) {
    let cadence = HourlyNagCadence(minutes: minutes)!
    precondition(cadence.phaseCount == cost)
    // Model every minute-of-hour starting offset through seven days, including
    // the hour rollover. This proves the date arithmetic, not device/DST behavior.
    for offset in 0..<60 {
        let first = now.addingTimeInterval(Double(offset * 60 + 17))
        let phaseDates = cadence.phaseDates(first: first)
        precondition(phaseDates.count == cost && phaseDates.first == first)
        let duration = 7 * 24 * 3600
        let actual = phaseDates.flatMap { phaseDate in
            (0..<(7 * 24)).map { phaseDate.addingTimeInterval(Double($0 * 3600)) }
        }.sorted()
        let expected = stride(from: 0, to: duration, by: minutes * 60).map { first.addingTimeInterval(Double($0)) }
        precondition(actual == expected, "Hourly phases must yield the chosen cadence without gaps or duplicate deliveries")
    }
    var series = reminder(minutes + 300, minutes: minutes); series.preferences.repeatRule = .daily
    let state = ReminderSnapshot(reminders: [series, oneOff])
    let actionDate = series.due.addingTimeInterval(5)
    let snoozeState = ReminderLifecycle.snoozing(series, in: state, now: actionDate)!.snapshot
    let snoozeSeries = snoozeState.reminders.first { $0.id == series.id }!
    let resumed = cadence.phaseDates(first: snoozeSeries.alertDate)
    precondition(resumed[0] == actionDate.addingTimeInterval(900))
    precondition(resumed[1].timeIntervalSince(resumed[0]) == Double(minutes * 60))
    precondition(snoozeState.reminders.contains(oneOff))
    let doneState = ReminderLifecycle.completing(series, in: state, now: actionDate)!.snapshot
    precondition(doneState.reminders.contains { $0.id == series.id && $0.generation != series.generation && $0.due > series.due })
    precondition(doneState.reminders.contains(oneOff))
    var edited = series; edited.preferences.nagMinutes = minutes == 30 ? 5 : 30
    let editedState = try ReminderLifecycle.saving(edited, replacing: series.generation, expecting: series, in: state)
    precondition(editedState.snapshot.reminders.first { $0.id == series.id }!.generation != series.generation)
    precondition(editedState.snapshot.reminders.contains(oneOff))
}
// The original five-minute metadata must remain valid after upgrading.
precondition(HourlyNagSchedule.recordedMinutes(phases[0].content) == 5)
let newContent = phases[0].content.mutableCopy() as! UNMutableNotificationContent
newContent.userInfo[HourlyNagSchedule.minutesKey] = 15
precondition(HourlyNagSchedule.recordedMinutes(newContent) == 15)
newContent.userInfo[HourlyNagSchedule.minutesKey] = "bad"
precondition(HourlyNagSchedule.recordedMinutes(newContent) == nil)
for invalid in [-1, 0, 1, 3, 7, 60, Int.max] { precondition(HourlyNagCadence(minutes: invalid) == nil) }
print("Hourly nag checks passed: 2/5/10/15/20/30-minute cadence, seven-day arithmetic, mixed capacity, legacy metadata, phase multiset, mismatch diagnostics, archive, Snooze, Done and interval edits.")
