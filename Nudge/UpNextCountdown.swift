import Foundation

/// Presentation only: uses the displayed occurrence, including snoozes and time adjustments.
enum UpNextCountdown {
    static func label(until date: Date, now: Date) -> String {
        let remaining = date.timeIntervalSince(now)
        guard remaining.isFinite else { return "" }
        if remaining > 0 && remaining < 60 { return "In <1 min" }
        if remaining <= 0 && remaining > -60 { return "Due now" }
        let minutes = Int(min(abs(remaining) / 60, 52_560_000).rounded(.up))
        let duration: String
        if minutes < 60 {
            duration = "\(minutes) min"
        } else if minutes < 1_440 {
            let hours = minutes / 60
            let remainder = minutes % 60
            duration = remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
        } else {
            let days = minutes / 1_440
            let hours = (minutes % 1_440) / 60
            let dayText = "\(days) " + (days == 1 ? "day" : "days")
            duration = hours == 0 ? dayText : "\(dayText) \(hours) hr"
        }
        return remaining > 0 ? "In \(duration)" : "\(duration) overdue"
    }
}
