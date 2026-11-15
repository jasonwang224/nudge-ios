import Foundation

enum Injected: Error { case write }
func fail(_ name: String, _ operation: () throws -> Void) {
    do { try operation(); preconditionFailure("Expected rejection: \(name)") } catch {}
}
func reminder(_ name: String) -> Reminder {
    let date = Date(timeIntervalSince1970: 2_000_000_000)
    return Reminder(title: name, notes: "Preserve these notes", due: date, repeatAnchor: date,
                    preferences: ReminderPreferences())
}
func withDatabase(_ body: (ReminderDatabase) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "recovery-checks.\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suite)!
    let db = ReminderDatabase(url: root.appendingPathComponent("Reminders.json"), preferences: preferences)
    defer {
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    try body(db)
}
let a = reminder("Active")
var done = reminder("Completed")
done.completedAt = a.due
var snoozed = reminder("Snoozed")
snoozed.snoozedUntil = snoozed.due.addingTimeInterval(900)
let removed = UUID()
let stop = "\(a.id.uuidString).\(UUID().uuidString)"
let original = ReminderSnapshot(reminders: [a, done, snoozed], deletedIDs: [removed],
                                stoppedNotificationGenerations: [stop])
let corrupt = Data("{\"version\":1,\"reminders\":[".utf8)

try withDatabase { db in
    let source = try db.commit(original, replacing: .missing)
    let primary = try Data(contentsOf: db.url)
    let backup = try Data(contentsOf: db.recoveryURL)
    try corrupt.write(to: db.url, options: .atomic)
    var notice = ""
    let recovered = try db.read { notice = $0 }
    precondition(recovered == source && notice.contains("Recovered"))
    let repaired = try Data(contentsOf: db.url)
    let preserved = try Data(contentsOf: db.damagedURL)
    let retainedBackup = try Data(contentsOf: db.recoveryURL)
    precondition(repaired == primary && preserved == corrupt && retainedBackup == backup)
    // All metadata is restored, so completed/deleted alerts cannot resurrect.
    precondition(recovered == .file(original))
    try FileManager.default.removeItem(at: db.url)
    let restoredMissing = try db.read()
    precondition(restoredMissing == source)
}

try withDatabase { db in
    let source = try db.commit(original, replacing: .missing)
    let bytes = try Data(contentsOf: db.url)
    let backup = try Data(contentsOf: db.recoveryURL)
    var faulty = db
    faulty.writeFile = { data, url, options in
        if url == db.recoveryURL { throw Injected.write }
        try data.write(to: url, options: options)
    }
    var next = original
    next.reminders[0].title = "Must not be partially saved"
    fail("backup write failure") { _ = try faulty.commit(next, replacing: source) }
    let afterPrimary = try Data(contentsOf: db.url)
    let afterBackup = try Data(contentsOf: db.recoveryURL)
    precondition(afterPrimary == bytes && afterBackup == backup)
}

try withDatabase { db in
    var faulty = db
    faulty.writeFile = { _, _, _ in throw Injected.write }
    fail("failed first save") { _ = try faulty.commit(original, replacing: .missing) }
    precondition(db.preferences.object(forKey: ReminderDatabase.migratedKey) == nil)
    let empty = try db.read()
    precondition(empty == .missing)
}

try withDatabase { db in
    let source = try db.commit(original, replacing: .missing)
    let oldPrimary = try Data(contentsOf: db.url)
    var faulty = db
    faulty.writeFile = { data, url, options in
        if url == db.url { throw Injected.write }
        try data.write(to: url, options: options)
    }
    let deletion = ReminderLifecycle.deleting(a, in: original)!.snapshot
    let committed = try faulty.commit(deletion, replacing: source)
    precondition(committed == .file(deletion))
    let unchangedPrimary = try Data(contentsOf: db.url)
    precondition(unchangedPrimary == oldPrimary)
    // A successful save remains readable even if primary repair repeatedly fails.
    let retry1 = try faulty.read()
    let retry2 = try faulty.read()
    precondition(retry1 == committed && retry2 == committed)
    var another = deletion
    another.reminders[0].notes = "Saved while using recovery"
    let committedAgain = try faulty.commit(another, replacing: committed)
    let stillReadable = try faulty.read()
    precondition(stillReadable == committedAgain)
    fail("stale source after backup-only commit") { _ = try faulty.commit(original, replacing: source) }
    // Simulated restart finishes mirroring the latest durable state, not the old file.
    let restart = try db.read()
    precondition(restart == .file(another))
    let decoded = try JSONDecoder().decode(ReminderSnapshot.self, from: Data(contentsOf: db.url))
    precondition(decoded == another && decoded.deletedIDs.contains(a.id))
}

try withDatabase { db in
    var faulty = db
    faulty.writeFile = { data, url, options in
        if url == db.url { throw Injected.write }
        try data.write(to: url, options: options)
    }
    let committed = try faulty.commit(original, replacing: .missing)
    // Crash before preferences flush during first migration: recovery still wins.
    db.preferences.removeObject(forKey: ReminderDatabase.migratedKey)
    db.preferences.set(try JSONEncoder().encode([reminder("Obsolete legacy")]), forKey: ReminderDatabase.legacyKey)
    let restarted = try db.read()
    precondition(restarted == committed)
}

try withDatabase { db in
    let source = try db.commit(original, replacing: .missing)
    let oldPrimary = try Data(contentsOf: db.url)
    let oldBackup = try Data(contentsOf: db.recoveryURL)
    var faulty = db
    faulty.writeFile = { data, url, options in
        if url == db.recoveryURL { return } // Stale valid readback must not pass verification.
        try data.write(to: url, options: options)
    }
    var next = original
    next.reminders[0].notes = "Not actually persisted"
    fail("stale backup readback") { _ = try faulty.commit(next, replacing: source) }
    let after = try Data(contentsOf: db.url)
    let backupAfter = try Data(contentsOf: db.recoveryURL)
    precondition(after == oldPrimary && backupAfter == oldBackup)
}

try withDatabase { db in
    let source = try db.commit(original, replacing: .missing)
    try corrupt.write(to: db.url, options: .atomic)
    var faulty = db
    faulty.writeFile = { data, url, options in
        if url == db.damagedURL { throw Injected.write }
        try data.write(to: url, options: options)
    }
    let usableBackup = try faulty.read()
    let preserved = try Data(contentsOf: db.url)
    precondition(usableBackup == source && preserved == corrupt)
    var next = original
    next.reminders[0].title = "Still safely saved in recovery"
    let nextSource = try faulty.commit(next, replacing: source)
    let readable = try faulty.read()
    let untouched = try Data(contentsOf: db.url)
    precondition(readable == nextSource && untouched == corrupt)
    let repaired = try db.read()
    precondition(repaired == .file(next))
}

try withDatabase { db in
    _ = try db.commit(original, replacing: .missing)
    let backup = try Data(contentsOf: db.recoveryURL)
    try JSONEncoder().encode(ReminderSnapshot()).write(to: db.url, options: .atomic)
    let truncated = try Data(contentsOf: db.url)
    fail("valid-looking truncated primary cannot erase recovery") { _ = try db.read() }
    let afterBackup = try Data(contentsOf: db.recoveryURL)
    let afterPrimary = try Data(contentsOf: db.url)
    precondition(afterBackup == backup && afterPrimary == truncated)
}

try withDatabase { db in
    _ = try db.commit(original, replacing: .missing)
    let primary = try Data(contentsOf: db.url)
    var record = try JSONSerialization.jsonObject(with: Data(contentsOf: db.recoveryURL)) as! [String: Any]
    record["replacesPrimaryChecksum"] = String(repeating: "0", count: 64)
    try JSONSerialization.data(withJSONObject: record).write(to: db.recoveryURL, options: .atomic)
    let repairedBackup = try db.read()
    precondition(repairedBackup == .file(original))
    let retained = try Data(contentsOf: db.url)
    precondition(retained == primary)
    // A damaged payload may be newer than the primary: preserve both rather than guess.
    record = try JSONSerialization.jsonObject(with: Data(contentsOf: db.recoveryURL)) as! [String: Any]
    record["payload"] = Data("tampered".utf8).base64EncodedString()
    try JSONSerialization.data(withJSONObject: record).write(to: db.recoveryURL, options: .atomic)
    let damagedBackup = try Data(contentsOf: db.recoveryURL)
    fail("unknown damaged recovery payload") { _ = try db.read() }
    let keptPrimary = try Data(contentsOf: db.url)
    let keptRecovery = try Data(contentsOf: db.recoveryURL)
    precondition(keptPrimary == primary && keptRecovery == damagedBackup)
}

try withDatabase { db in
    _ = try db.commit(original, replacing: .missing)
    try corrupt.write(to: db.url, options: .atomic)
    try corrupt.write(to: db.recoveryURL, options: .atomic)
    fail("both copies corrupt") { _ = try db.read() }
    fail("no blank overwrite when both corrupt") { _ = try db.commit(ReminderSnapshot(), replacing: .missing) }
    let primary = try Data(contentsOf: db.url)
    let backup = try Data(contentsOf: db.recoveryURL)
    precondition(primary == corrupt && backup == corrupt)
    try FileManager.default.removeItem(at: db.url)
    try FileManager.default.removeItem(at: db.recoveryURL)
    fail("both copies missing after migration") { _ = try db.read() }
}

try withDatabase { db in
    _ = try db.commit(original, replacing: .missing)
    let primary = try Data(contentsOf: db.url)
    let backup = try Data(contentsOf: db.recoveryURL)
    var unreadable = db
    unreadable.readFile = { url in
        if url == db.recoveryURL { throw CocoaError(.fileReadNoPermission) }
        return try Data(contentsOf: url)
    }
    fail("existing unreadable recovery is not missing") { _ = try unreadable.read() }
    unreadable.readFile = { url in
        if url == db.url { throw CocoaError(.fileReadNoPermission) }
        return try Data(contentsOf: url)
    }
    fail("protected primary is not corrupt") { _ = try unreadable.read() }
    let after = try Data(contentsOf: db.url)
    let afterBackup = try Data(contentsOf: db.recoveryURL)
    precondition(after == primary && afterBackup == backup)
}

try withDatabase { db in
    // An existing app database gains a backup without requiring an edit.
    try FileManager.default.createDirectory(at: db.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(original).write(to: db.url, options: .atomic)
    var faulty = db
    faulty.writeFile = { data, url, options in
        if url == db.recoveryURL { throw Injected.write }
        try data.write(to: url, options: options)
    }
    let readable = try faulty.read()
    precondition(readable == .file(original))
    let upgraded = try db.read()
    precondition(upgraded == readable && FileManager.default.fileExists(atPath: db.recoveryURL.path))
}

for futureFormat in ["version", "enum", "numeric"] {
    try withDatabase { db in
        _ = try db.commit(original, replacing: .missing)
        let backup = try Data(contentsOf: db.recoveryURL)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: db.url)) as! [String: Any]
        if futureFormat != "version" {
            var records = json["reminders"] as! [[String: Any]]
            var preferences = records[0]["preferences"] as! [String: Any]
            if futureFormat == "enum" { preferences["repeatRule"] = "Future repeat rule" }
            else { preferences["nagMinutes"] = 7 }
            records[0]["preferences"] = preferences
            json["reminders"] = records
        } else { json["version"] = 99 }
        let future = try JSONSerialization.data(withJSONObject: json)
        try future.write(to: db.url, options: .atomic)
        fail("future primary schema/enum/numeric value") { _ = try db.read() }
        let kept = try Data(contentsOf: db.url)
        let keptBackup = try Data(contentsOf: db.recoveryURL)
        precondition(kept == future && keptBackup == backup)
    }
}
try withDatabase { db in
    _ = try db.commit(original, replacing: .missing)
    let primary = try Data(contentsOf: db.url)
    var json = try JSONSerialization.jsonObject(with: Data(contentsOf: db.recoveryURL)) as! [String: Any]
    json["version"] = 99
    let future = try JSONSerialization.data(withJSONObject: json)
    try future.write(to: db.recoveryURL, options: .atomic)
    fail("future recovery format") { _ = try db.read() }
    let kept = try Data(contentsOf: db.url)
    let keptBackup = try Data(contentsOf: db.recoveryURL)
    precondition(kept == primary && keptBackup == future)
}

try withDatabase { db in
    let empty = ReminderSnapshot()
    let source = try db.commit(empty, replacing: .missing)
    let oldEmptyPrimary = try Data(contentsOf: db.url)
    var interrupted = db
    interrupted.writeFile = { data, url, options in
        if url == db.url { throw Injected.write }
        try data.write(to: url, options: options)
    }
    _ = try interrupted.commit(original, replacing: source)
    var record = try JSONSerialization.jsonObject(with: Data(contentsOf: db.recoveryURL)) as! [String: Any]
    record["integrity"] = "damaged integrity metadata"
    let latestDamagedCopy = try JSONSerialization.data(withJSONObject: record)
    try latestDamagedCopy.write(to: db.recoveryURL, options: .atomic)
    fail("never replace newer recovery payload with old empty primary") { _ = try db.read() }
    let keptRecovery = try Data(contentsOf: db.recoveryURL)
    let keptPrimary = try Data(contentsOf: db.url)
    precondition(keptRecovery == latestDamagedCopy && keptPrimary == oldEmptyPrimary)
}

try withDatabase { db in
    _ = try db.commit(original, replacing: .missing)
    let backup = try Data(contentsOf: db.recoveryURL)
    var divergent = original
    divergent.reminders[0].title = "Unexplained external change"
    let divergentBytes = try JSONEncoder().encode(divergent)
    try divergentBytes.write(to: db.url, options: .atomic)
    fail("valid-looking divergent primary must not replace backup") { _ = try db.read() }
    let retainedPrimary = try Data(contentsOf: db.url)
    let retainedBackup = try Data(contentsOf: db.recoveryURL)
    precondition(retainedPrimary == divergentBytes && retainedBackup == backup)
}

print("Automatic recovery checks passed: upgrade, corruption/missing file, full metadata, interrupted/repeated mirror writes, backup failures, exact readback, quarantine failures, divergent truncation, checksums, both-copy failures and future formats.")
