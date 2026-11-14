import Foundation
import UserNotifications

enum NotificationContentEquivalence {
    static func equal(_ lhs: UNNotificationContent, _ rhs: UNNotificationContent) -> Bool {
        if lhs.isEqual(rhs) { return true }
        // iOS can store empty body/subtitle strings as nil in its notification
        // records. Swift reads those absent strings as "", while NSObject's
        // content equality still distinguishes nil from an empty NSString.
        // Normalize only these empty text representations on private copies.
        // Every remaining content property must still pass full native equality.
        let emptyBody = lhs.body.isEmpty && rhs.body.isEmpty
        let emptySubtitle = lhs.subtitle.isEmpty && rhs.subtitle.isEmpty
        guard emptyBody || emptySubtitle,
              let left = lhs.mutableCopy() as? UNMutableNotificationContent,
              let right = rhs.mutableCopy() as? UNMutableNotificationContent,
              left.isEqual(lhs), right.isEqual(rhs) else { return false }
        // If copying itself changes another property, fail closed rather than
        // accidentally accepting that loss along with empty-text normalization.
        if emptyBody {
            left.body = ""
            right.body = ""
        }
        if emptySubtitle {
            left.subtitle = ""
            right.subtitle = ""
        }
        return left.isEqual(right)
    }
}
