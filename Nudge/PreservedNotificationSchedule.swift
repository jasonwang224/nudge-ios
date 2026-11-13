import Foundation
import UserNotifications
import UIKit
import ObjectiveC

// The tested nil-trigger protection path. It never removes delivered cards and
// never reposts missing ones. Only the caller's own notification center is used.
@MainActor enum PreservedNotificationSchedule {
    struct Problem: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    struct Journal: Codable {
        let original: Data
        let desired: Data
        let date: Date
        static func decode(_ data: Data) throws -> [UNNotificationRequest] {
            guard let requests = try NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSArray.self, UNNotificationRequest.self], from: data) as? [UNNotificationRequest], requests.count <= 64 else {
                throw Problem(message: "The saved notification recovery schedule could not be read. Your reminders have not been changed.")
            }
            return requests
        }
    }
    static var journalURL: URL { URL.applicationSupportDirectory.appending(path: "Nudge/NotificationTransaction-v1.json") }
    static var hasJournal: Bool { FileManager.default.fileExists(atPath: journalURL.path) }
    static var retryAfter = Date.distantPast
    static var inProgress = false
    private typealias Reply = @convention(block) (NSError?) -> Void
    private typealias Bulk = @convention(c) (AnyObject, Selector, NSArray, Reply) -> Void
    private typealias Protect = @convention(c) (AnyObject, Selector, NSString, UNNotificationContent, Reply) -> Void
    private typealias ObjectGetter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
    private typealias IntegerGetter = @convention(c) (AnyObject, Selector) -> UInt64
    private static let bulk = NSSelectorFromString("setNotificationRequests:completionHandler:")
    private static let protect = NSSelectorFromString("replaceContentForRequestWithIdentifier:replacementContent:completionHandler:")
    static var available: Bool {
        guard NotificationRequestFactory.supportsMinuteRepeats,
              let cls = object_getClass(UNUserNotificationCenter.current()),
              let b = class_getInstanceMethod(cls, bulk), method_getNumberOfArguments(b) == 4,
              let p = class_getInstanceMethod(cls, protect), method_getNumberOfArguments(p) == 5 else { return false }
        return true
    }
    static func firstDate(_ trigger: UNNotificationTrigger?) -> Date? {
        guard let trigger, let cls = object_getClass(trigger),
              let method = class_getInstanceMethod(cls, NSSelectorFromString("date")), method_getNumberOfArguments(method) == 2 else { return nil }
        let getter = unsafeBitCast(method_getImplementation(method), to: ObjectGetter.self)
        return (getter(trigger, NSSelectorFromString("date"))?.takeUnretainedValue() as? NSDate) as Date?
    }
    static func repeatUnit(_ trigger: UNNotificationTrigger?) -> UInt64? {
        guard let trigger, let cls = object_getClass(trigger),
              let method = class_getInstanceMethod(cls, NSSelectorFromString("repeatInterval")), method_getNumberOfArguments(method) == 2 else { return nil }
        return unsafeBitCast(method_getImplementation(method), to: IntegerGetter.self)(trigger, NSSelectorFromString("repeatInterval"))
    }
    static func recoveryRequests() throws -> [UNNotificationRequest] {
        guard hasJournal else { return [] }
        let j = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
        // The store revalidates every saved request against the current database.
        return try Journal.decode(j.desired) + Journal.decode(j.original)
    }
    static func absolute(_ request: UNNotificationRequest) throws -> UNNotificationRequest {
        guard request.trigger is UNTimeIntervalNotificationTrigger else { return request }
        guard request.trigger?.repeats != true,
              let stamp = request.content.userInfo[NagDelivery.scheduledKey] as? Double, stamp.isFinite else {
            throw Problem(message: "An existing notification has timing that cannot safely be preserved. Existing alerts were left in place.")
        }
        let date = Date(timeIntervalSince1970: stamp)
        let parts = Calendar.autoupdatingCurrent.dateComponents([.era, .year, .month, .day, .hour, .minute, .second], from: date)
        return UNNotificationRequest(identifier: request.identifier, content: request.content,
                                     trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
    }
    static func nearDelivery(_ requests: [UNNotificationRequest], now: Date = .now) -> Bool {
        requests.contains { request in
            if let date = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() { return date.timeIntervalSince(now) < 8 }
            if let date = firstDate(request.trigger) {
                if date > now { return date.timeIntervalSince(now) < 8 }
                let unit = repeatUnit(request.trigger)
                let period = unit == UInt64(NSCalendar.Unit.minute.rawValue) ? 60.0 : 3600.0
                let age = now.timeIntervalSince(date).truncatingRemainder(dividingBy: period)
                return age < 3 || period - age < 8
            }
            if let stamp = request.content.userInfo[NagDelivery.scheduledKey] as? Double,
               request.trigger?.repeats != true { return stamp - now.timeIntervalSince1970 < 8 }
            return false
        }
    }
    private static func verify(_ before: [UNNotification], _ after: [UNNotification]) throws {
        // A concurrent dismissal aborts this attempt. Never recreate a missing
        // card, and never misreport an OS-removed card as a preservation success.
        guard before.count == after.count else {
            throw Problem(message: "The visible notification records changed during the update. Keep the app open to retry safely.")
        }
        for card in after {
            guard let old = before.first(where: { $0.request.identifier == card.request.identifier }),
                  card.request.trigger == nil, abs(card.date.timeIntervalSince(old.date)) < 0.1,
                  card.request.content.isEqual(old.request.content) else {
                throw Problem(message: "Could not protect an existing notification card. The schedule update was stopped; keep the app open to retry.")
            }
        }
    }
    static func apply(_ desired: [UNNotificationRequest], original: [UNNotificationRequest]) async throws {
        guard available, !inProgress, Date.now >= retryAfter, desired.count <= AlertPlan.capacity else {
            throw Problem(message: "Notification scheduling is not ready. Keep the app open and try again.")
        }
        inProgress = true
        let task = UIApplication.shared.beginBackgroundTask(withName: "Preserve reminder notifications")
        defer { inProgress = false; if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
        let center = UNUserNotificationCenter.current()
        let j = Journal(original: try NSKeyedArchiver.archivedData(withRootObject: original, requiringSecureCoding: true),
                        desired: try NSKeyedArchiver.archivedData(withRootObject: desired, requiringSecureCoding: true), date: .now)
        guard HourlyNagSchedule.matches(try Journal.decode(j.desired), desired) else { throw Problem(message: "Notification recovery verification failed. Existing alerts were kept.") }
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(j).write(to: journalURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        // Check callbacks/readback, not a nil bulk callback alone. No global
        // delivered-notification removal is used, including on error paths.
        center.removePendingNotificationRequests(withIdentifiers: Array(Set(original.map(\.identifier))))
        for _ in 0..<10 {
            if await center.pendingNotificationRequests().isEmpty { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard await center.pendingNotificationRequests().isEmpty else { throw Problem(message: "The notification queue did not pause. Recovery is saved; keep the app open.") }
        let before = await center.deliveredNotifications()
        for card in before where card.request.trigger != nil {
            if let error = await ScheduleReply().wait({ completion in
                guard let cls = object_getClass(center), let method = class_getInstanceMethod(cls, protect) else { completion("Protection unavailable."); return }
                let reply: Reply = { completion($0?.localizedDescription) }
                unsafeBitCast(method_getImplementation(method), to: Protect.self)(center, protect, card.request.identifier as NSString, card.request.content, reply)
            }) { retryAfter = .now.addingTimeInterval(15); throw Problem(message: error) }
        }
        try verify(before, await center.deliveredNotifications())
        guard await center.pendingNotificationRequests().isEmpty else { throw Problem(message: "Protection unexpectedly changed the queue. Recovery is saved; keep the app open.") }
        if !desired.isEmpty {
            if let error = await ScheduleReply().wait({ completion in
                guard let cls = object_getClass(center), let method = class_getInstanceMethod(cls, bulk) else { completion("Bulk scheduling unavailable."); return }
                let reply: Reply = { completion($0?.localizedDescription) }
                unsafeBitCast(method_getImplementation(method), to: Bulk.self)(center, bulk, desired as NSArray, reply)
            }) { retryAfter = .now.addingTimeInterval(15); throw Problem(message: error) }
        }
        var matched = false
        for _ in 0..<6 {
            if HourlyNagSchedule.matches(await center.pendingNotificationRequests(), desired) { matched = true; break }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        guard matched else { throw Problem(message: "iOS did not retain the full schedule. Recovery is saved; keep the app open to retry.") }
        try verify(before, await center.deliveredNotifications())
        try FileManager.default.removeItem(at: journalURL)
    }
}

@MainActor private final class ScheduleReply {
    private var continuation: CheckedContinuation<String?, Never>?
    func wait(_ call: (@escaping (String?) -> Void) -> Void) async -> String? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            call { message in Task { @MainActor in self.finish(message) } }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self.finish("iOS did not confirm the notification update. Recovery is saved; keep the app open.")
            }
        }
    }
    private func finish(_ message: String?) {
        let saved = continuation; continuation = nil; saved?.resume(returning: message)
    }
}
