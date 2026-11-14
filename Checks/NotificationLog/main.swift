import Foundation

let first = Date(timeIntervalSince1970: 0)
var log = NotificationUpdateLog()
precondition(log.lastFailure == nil && log.recent.isEmpty)
log.record(stage: "readback", message: "Could not verify", details: "Missing phase 2", failure: true,
           version: "1.1.12 (24)", date: first)
let originalFailure = log.lastFailure!
for index in 1...20 {
    log.record(stage: "retry", message: "Schedule verified \(index)", version: "1.1.12 (24)",
               date: first.addingTimeInterval(Double(index)))
}
precondition(log.recent.count == 8 && log.recent.first?.message == "Schedule verified 13")
precondition(log.lastFailure == originalFailure, "Success must not erase the failure that prompted a report")
precondition(!log.recent.contains(originalFailure), "The retained failure must survive eviction from recent updates")
let restored = NotificationUpdateLog.decode(try JSONEncoder().encode(log))
precondition(restored.lastFailure == originalFailure && restored.recent == log.recent)
precondition(restored.report.contains("Missing phase 2") && restored.report.contains("Schedule verified 20"))
precondition(restored.report.contains("1970-01-01T00:00:00.000Z"))
log.record(stage: "protect", message: "New failure", failure: true, version: "1.1.12 (24)",
           date: first.addingTimeInterval(21))
precondition(log.lastFailure?.message == "New failure")
log.record(stage: "complete", message: "Recovered", version: "1.1.12 (24)")
precondition(log.lastFailure?.message == "New failure")

// Bound both new records and externally decoded logs, including the separate
// retained failure. Unicode prefixes must not split a grapheme into invalid text.
let longLabel = String(repeating: "é", count: 1_100)
let longDetails = String(repeating: "🙂", count: 65_000)
var bounded = NotificationUpdateLog()
bounded.record(stage: longLabel, message: longLabel, details: longDetails, failure: true, version: longLabel)
let entry = bounded.lastFailure!
precondition(entry.stage.count == 1_000 && entry.message.count == 1_000 && entry.version.count == 1_000)
precondition(entry.details.count == 64_000 && entry.details.last == "🙂")
precondition(bounded.recent == [entry])

let oversizedEntry: [String: Any] = ["date": 0, "version": longLabel, "stage": longLabel,
    "message": longLabel, "details": longDetails, "isFailure": true]
let oversizedLog: [String: Any] = ["lastFailure": oversizedEntry,
    "recent": Array(repeating: oversizedEntry, count: 12)]
let oversizedData = try JSONSerialization.data(withJSONObject: oversizedLog)
let normalized = try JSONDecoder().decode(NotificationUpdateLog.self, from: oversizedData)
precondition(normalized.recent.count == 8)
for item in normalized.recent + [normalized.lastFailure!] {
    precondition(item.stage.count <= 1_000 && item.message.count <= 1_000 && item.version.count <= 1_000)
    precondition(item.details.count <= 64_000)
}

for invalid in [Data([0xff, 0xfe]), Data("not JSON".utf8), Data("{\"recent\":\"invalid\"}".utf8)] {
    let empty = NotificationUpdateLog.decode(invalid)
    precondition(empty.lastFailure == nil && empty.recent.isEmpty)
}
precondition(NotificationUpdateLog.decode(nil).recent.isEmpty)
precondition(NotificationUpdateLog.decode(Data("{}".utf8)).lastFailure == nil)
print("Notification log checks passed: latest failure survives success and JSON roundtrip, recent entries and details are bounded on record/decode, and malformed diagnostics safely become empty.")
