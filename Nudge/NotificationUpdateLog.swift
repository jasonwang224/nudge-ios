import Foundation

// Diagnostics only: this data is independent of reminder storage and recovery.
struct NotificationUpdateLog: Codable {
    static let recentLimit = 8
    static let detailLimit = 64_000
    static let labelLimit = 1_000

    struct Entry: Codable, Equatable {
        let date: Date
        let version: String
        let stage: String
        let message: String
        let details: String
        let isFailure: Bool

        fileprivate var bounded: Entry {
            Entry(date: date, version: String(version.prefix(NotificationUpdateLog.labelLimit)),
                  stage: String(stage.prefix(NotificationUpdateLog.labelLimit)),
                  message: String(message.prefix(NotificationUpdateLog.labelLimit)),
                  details: String(details.prefix(NotificationUpdateLog.detailLimit)), isFailure: isFailure)
        }
    }

    private(set) var lastFailure: Entry?
    private(set) var recent: [Entry] = []

    init() {}

    private enum CodingKeys: String, CodingKey { case lastFailure, recent }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recent = Array((try container.decodeIfPresent([Entry].self, forKey: .recent) ?? []).suffix(Self.recentLimit))
            .map(\.bounded)
        let savedFailure = try container.decodeIfPresent(Entry.self, forKey: .lastFailure)?.bounded
        lastFailure = savedFailure?.isFailure == true ? savedFailure : recent.last(where: \.isFailure)
    }

    static func decode(_ data: Data?) -> Self {
        guard let data else { return Self() }
        return (try? JSONDecoder().decode(Self.self, from: data)) ?? Self()
    }

    mutating func record(stage: String, message: String, details: String = "", failure: Bool = false,
                         version: String, date: Date = .now) {
        let entry = Entry(date: date, version: version, stage: stage, message: message,
                          details: details, isFailure: failure).bounded
        if failure { lastFailure = entry }
        recent.append(entry)
        if recent.count > Self.recentLimit { recent.removeFirst(recent.count - Self.recentLimit) }
    }

    var report: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        func describe(_ entry: Entry) -> String {
            var text = "\(formatter.string(from: entry.date)) · \(entry.version) · \(entry.stage) · \(entry.isFailure ? "FAILURE" : "UPDATE")\n\(entry.message)"
            if !entry.details.isEmpty { text += "\n" + entry.details }
            return text
        }
        let failure = lastFailure.map(describe) ?? "No saved failure."
        let updates = recent.isEmpty ? "No saved updates." : recent.reversed().map(describe).joined(separator: "\n\n")
        return "LATEST SAVED FAILURE\n\(failure)\n\nRECENT UPDATES (newest first)\n\(updates)"
    }
}
