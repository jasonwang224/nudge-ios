import Foundation
import UserNotifications

let now = Date(timeIntervalSinceReferenceDate: 850_000_000)
let due = now.addingTimeInterval(600)
var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(secondsFromGMT: 0)!

// Exercise the actual planner and content factory together for every exposed
// combination. Repeat occurrences are separate from the nag notification queue.
var combinations = 0
for rule in RepeatRule.allCases {
    for minutes in ReminderPreferences.nagIntervals {
        for sound in AlertSound.allCases {
            for notifications in [false, true] {
                var preferences = ReminderPreferences()
                preferences.repeatRule = rule
                preferences.nagMinutes = minutes
                preferences.sound = sound
                preferences.notifications = notifications
                let reminder = Reminder(title: "Combination", notes: "Actual note", due: due,
                                        repeatAnchor: due, preferences: preferences)
                let plan = AlertPlan(reminders: [reminder], now: now, capacity: 3)
                precondition(plan.alerts.count == (notifications ? (minutes == 0 ? 1 : 3) : 0))
                for (index, alert) in plan.alerts.enumerated() {
                    precondition(alert.date == due.addingTimeInterval(Double(index * minutes * 60)))
                    let request = NotificationRequestFactory.make(for: alert, soundOnlyEnabled: NagDelivery.enabled, now: now)
                    precondition(request.content.title == reminder.title && request.content.body == reminder.notes)
                    precondition(request.content.categoryIdentifier == NotificationRequestFactory.category)
                    precondition(request.content.threadIdentifier == reminder.id.uuidString)
                    precondition(request.content.userInfo["generation"] as? String == reminder.generation.uuidString)
                    precondition((request.content.sound == nil) == (sound == .silent))
                    precondition(!NotificationRequestFactory.isSoundOnly(request.content))
                    precondition((request.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval == alert.date.timeIntervalSince(now))
                }
                var snoozed = reminder
                snoozed.snoozedUntil = now.addingTimeInterval(900)
                let paused = AlertPlan(reminders: [snoozed], now: now, capacity: 3)
                precondition(paused.alerts.first?.date == (notifications ? snoozed.snoozedUntil : nil))
                var completed = snoozed
                completed.completedAt = now
                precondition(AlertPlan(reminders: [completed], now: now).alerts.isEmpty)
                precondition(ReminderOccurrence.entries(reminders: [completed], on: nil, now: now).isEmpty)
                combinations += 1
            }
        }
    }
}
precondition(combinations == 420 && !NagDelivery.enabled)

var preferences = ReminderPreferences()
preferences.nagMinutes = 2
let overdue = Reminder(title: "Overdue", notes: "", due: now.addingTimeInterval(-300),
                       repeatAnchor: now.addingTimeInterval(-300), preferences: preferences)
let other = Reminder(title: "Independent", notes: "", due: due, repeatAnchor: due, preferences: preferences)
let oldPrimary = PendingNudge(ScheduledAlert(reminder: overdue, index: 0, date: overdue.due).identifier)!
let oldNag = PendingNudge(ScheduledAlert(reminder: overdue, index: 3, date: now.addingTimeInterval(60)).identifier)!
let otherNag = PendingNudge(ScheduledAlert(reminder: other, index: 1, date: due.addingTimeInterval(120)).identifier)!

var stopped = overdue
stopped.preferences.nagMinutes = 0
stopped.generation = UUID()
let state = [stopped.id: stopped, other.id: other]
precondition(AlertPlan(reminders: [stopped], now: now).alerts.isEmpty)
precondition(oldPrimary.canRetire(current: state, deletedIDs: [], queuedReplacement: [], now: now))
precondition(oldNag.canRetire(current: state, deletedIDs: [], queuedReplacement: [], now: now),
             "Nag Off must stop previous followups even when there is no future primary replacement.")
precondition(!otherNag.canRetire(current: state, deletedIDs: [], queuedReplacement: [], now: now))
stopped.generation = overdue.generation
precondition(oldNag.canRetire(current: [stopped.id: stopped], deletedIDs: [], queuedReplacement: [], now: now),
             "Stopping nags also cancels followups if the actionable original card keeps its generation.")
precondition(!oldPrimary.canRetire(current: [stopped.id: stopped], deletedIDs: [], queuedReplacement: [], now: now))

// Moving a reminder into the future with nags off must retain its previous
// primary until the replacement is accepted, including a Snooze operation.
stopped.generation = UUID()
stopped.snoozedUntil = now.addingTimeInterval(900)
precondition(!oldPrimary.canRetire(current: [stopped.id: stopped], deletedIDs: [], queuedReplacement: [], now: now))
precondition(oldPrimary.canRetire(current: [stopped.id: stopped], deletedIDs: [], queuedReplacement: [stopped.id], now: now))
precondition(!oldNag.canRetire(current: [:], deletedIDs: [], queuedReplacement: [], now: now))

let crowded = (0..<65).map { index in
    Reminder(title: "Reminder \(index)", notes: "", due: due.addingTimeInterval(Double(index * 3600)),
             repeatAnchor: due, preferences: preferences)
}
let capacityPlan = AlertPlan(reminders: crowded, now: now)
precondition(capacityPlan.alerts.count == 60 && capacityPlan.unscheduledFirstAlerts == 5)
precondition(capacityPlan.alerts.allSatisfy { $0.index == 0 }, "Initial alerts must outrank extra nags under capacity pressure.")
precondition(Set(capacityPlan.alerts.map { $0.reminder.id }).count == 60)

// Exercise an editor -> committed series -> time edit -> completion -> agenda
// sequence, not just the editor and lifecycle helpers in isolation.
func localDate(_ month: Int, _ day: Int, _ hour: Int = 8, _ minute: Int = 30) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
}
let scenarioNow = localDate(11, 7, 12, 0)
var monthly = ReminderPreferences()
monthly.repeatRule = .monthly
var schedule = PhoneSchedule(day: localDate(10, 31), hour: 8, minute: 30, calendar: calendar)
schedule.day = calendar.dateComponents([.era, .year, .month, .day], from: localDate(11, 30))
let series = Reminder(title: "Month-end", notes: "", due: localDate(11, 30), repeatAnchor: localDate(10, 31),
                      preferences: monthly, phoneSchedule: schedule)
let snapshot = ReminderSnapshot(reminders: [series, other])
let edited = try ReminderEditorDraft.reminder(original: series, title: series.title, notes: "Edited",
                                              day: series.due, time: "930", isPM: false, preferences: monthly,
                                              now: scenarioNow, calendar: calendar)
let saved = try ReminderLifecycle.saving(edited, replacing: series.generation, expecting: series,
                                         in: snapshot, now: scenarioNow)
let currentSeries = saved.snapshot.reminders.first { $0.id == series.id }!
precondition(currentSeries.due == localDate(11, 30, 9, 30))
precondition(currentSeries.nextOccurrence(after: localDate(11, 30, 10), calendar: calendar) == localDate(12, 31, 9, 30),
             "The actual store save path must preserve the editor's month-end anchor.")
let finished = ReminderLifecycle.completing(currentSeries, in: saved.snapshot,
                                            now: localDate(11, 30, 10), calendar: calendar)!
let december = AgendaPresentation(reminders: finished.snapshot.reminders, todayOnly: true,
                                  selectedDay: localDate(12, 31), now: localDate(11, 30, 10), calendar: calendar)
precondition(december.upcoming.filter { $0.reminder.id == series.id }.count == 1)
precondition(december.upcoming.first { $0.reminder.id == series.id }?.date == localDate(12, 31, 9, 30))
precondition(december.upcoming.first { $0.reminder.id == series.id }?.isProjected == false)
precondition(finished.snapshot.reminders.first { $0.id == other.id } == other)

// A queued calendar trigger can change interpretation after a system calendar
// switch even if its payload and reminder generation are unchanged.
var calendarReminder = other
calendarReminder.phoneSchedule = PhoneSchedule(day: due, hour: calendar.component(.hour, from: due),
                                               minute: calendar.component(.minute, from: due), calendar: calendar)
let calendarAlert = ScheduledAlert(reminder: calendarReminder, index: 0, date: due)
let expectedRequest = NotificationRequestFactory.make(for: calendarAlert, soundOnlyEnabled: false, now: now)
precondition(!NotificationRequestFactory.needsRewrite(expectedRequest, for: calendarAlert, enabled: false))
let wrongDate = DateComponents(year: 2500, month: 11, day: 8, hour: 8, minute: 30)
let reinterpreted = UNNotificationRequest(identifier: expectedRequest.identifier, content: expectedRequest.content,
                                          trigger: UNCalendarNotificationTrigger(dateMatching: wrongDate, repeats: false))
precondition(NotificationRequestFactory.needsRewrite(reinterpreted, for: calendarAlert, enabled: false),
             "Reopening must repair a reinterpreted calendar trigger without discarding the reminder.")

print("All 420 repeat/nag/sound/notification combinations, snooze/completion integration, Nag Off isolation, capacity, and editor-to-agenda checks passed.")
