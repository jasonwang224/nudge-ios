import Foundation

func expectFailure(_ label: String, _ body: () throws -> Void) {
    do { try body(); preconditionFailure("Expected failure: \(label)") }
    catch { }
}
func item(_ title: String) -> Reminder {
    let due = Date(timeIntervalSince1970: 2_000_000_000)
    return Reminder(title: title, notes: "", due: due, repeatAnchor: due, preferences: ReminderPreferences())
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let suite = "nudge-data-safety.\(UUID().uuidString)"
let preferences = UserDefaults(suiteName: suite)!
defer {
    preferences.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: root)
}
let database = ReminderDatabase(url: root.appendingPathComponent("Reminders.json"), preferences: preferences)
let a = item("Keep A")
let b = item("Keep B")
var history = item("Completed history")
history.completedAt = Date(timeIntervalSince1970: 1_999_999_999)
let tombstone = UUID()
let stopped = "\(a.id.uuidString).\(UUID().uuidString)"
let original = ReminderSnapshot(reminders: [a, b, history], deletedIDs: [tombstone],
                                stoppedNotificationGenerations: [stopped])
let source = try database.commit(original, replacing: .missing)
let originalBytes = try Data(contentsOf: database.url)

func rejectWithoutChangingDisk(_ label: String, _ candidate: ReminderSnapshot,
                               replacing source: ReminderDatabase.Source) throws {
    let before = try Data(contentsOf: database.url)
    expectFailure(label) { _ = try database.commit(candidate, replacing: source) }
    let after = try Data(contentsOf: database.url)
    precondition(after == before, "\(label) must preserve exact prior bytes")
}
try rejectWithoutChangingDisk("valid-looking empty database", ReminderSnapshot(), replacing: source)
var missingOne = original
missingOne.reminders.removeFirst()
try rejectWithoutChangingDisk("one omitted active reminder", missingOne, replacing: source)
var missingHistory = original
missingHistory.reminders.removeLast()
try rejectWithoutChangingDisk("omitted completed history", missingHistory, replacing: source)
var droppedDeletes = original
droppedDeletes.deletedIDs = []
try rejectWithoutChangingDisk("lost deletion history", droppedDeletes, replacing: source)
var droppedStops = original
droppedStops.stoppedNotificationGenerations = nil
try rejectWithoutChangingDisk("lost notification cancellation history", droppedStops, replacing: source)
var invalidRecord = original
invalidRecord.reminders[0].preferences.nagMinutes = -1
try rejectWithoutChangingDisk("invalid schedule", invalidRecord, replacing: source)

// Real intentional deletion keeps every unrelated record and persists its tombstone.
let deletion = ReminderLifecycle.deleting(a, in: original)!
let deletedSource = try database.commit(deletion.snapshot, replacing: source)
let afterDelete = try database.read()
precondition(afterDelete == deletedSource)
precondition(deletion.snapshot.reminders == [b, history])
try rejectWithoutChangingDisk("stale overwrite after deletion", original, replacing: source)

// A decoder failure must never authorize empty initialization or change the bad bytes.
let damaged = Data("{\"version\":1,\"reminders\":[".utf8)
try damaged.write(to: database.url, options: .atomic)
try damaged.write(to: database.recoveryURL, options: .atomic)
expectFailure("malformed primary") { _ = try database.read() }
try rejectWithoutChangingDisk("cannot erase malformed primary", ReminderSnapshot(), replacing: deletedSource)
let preservedDamage = try Data(contentsOf: database.url)
precondition(preservedDamage == damaged)
try FileManager.default.removeItem(at: database.url)
expectFailure("missing migrated primary") { _ = try database.read() }
expectFailure("cannot recreate missing migrated primary") {
    _ = try database.commit(ReminderSnapshot(), replacing: .missing)
}
precondition(!FileManager.default.fileExists(atPath: database.url.path))

// Set up a separate explicit legacy-file fixture after testing both-copy failure.
try FileManager.default.removeItem(at: database.recoveryURL)
// Legacy custom repeats stay readable and portable, even in a mixed backup.
var legacyCustom = item("Legacy custom")
legacyCustom.preferences.repeatRule = .custom
legacyCustom.preferences.weekdays = []
let legacySnapshot = ReminderSnapshot(reminders: [a, b, history, legacyCustom])
try JSONEncoder().encode(legacySnapshot).write(to: database.url, options: .atomic)
let legacyLoaded = try database.read()
precondition(legacyLoaded == .file(legacySnapshot))
let legacyBytes = try Data(contentsOf: database.url)
let legacyBackup = try ReminderBackup.decode(ReminderBackup.encode(snapshot: legacySnapshot))
precondition(legacyBackup.reminders == legacySnapshot.reminders)
var importedLegacy = try legacyBackup.merging(into: ReminderSnapshot())
importedLegacy.deletedIDs = [tombstone]
importedLegacy.stoppedNotificationGenerations = [stopped]
precondition(importedLegacy.reminders.count == legacySnapshot.reminders.count)
let restoredCustom = importedLegacy.reminders.first { $0.id == legacyCustom.id }!
let completionTime = restoredCustom.due.addingTimeInterval(60)
let completion = ReminderLifecycle.completing(restoredCustom, in: importedLegacy, now: completionTime)!
precondition(completion.snapshot.reminders.count == importedLegacy.reminders.count)
let completedCustom = completion.snapshot.reminders.first { $0.id == restoredCustom.id }!
precondition(completedCustom.completedAt == completionTime)
precondition(completedCustom.title == restoredCustom.title && completedCustom.notes == restoredCustom.notes)
precondition(completedCustom.preferences == restoredCustom.preferences)
precondition(completion.snapshot.deletedIDs == importedLegacy.deletedIDs)
precondition(completion.snapshot.stoppedNotificationGenerations?.contains(stopped) == true)
precondition(completion.snapshot.stoppedNotificationGenerations?.contains("\(restoredCustom.id.uuidString).\(restoredCustom.generation.uuidString)") == true)
precondition(completion.snapshot.reminders.filter { $0.id != restoredCustom.id }
    == importedLegacy.reminders.filter { $0.id != restoredCustom.id })
let afterLegacyRoundTrip = try Data(contentsOf: database.url)
precondition(afterLegacyRoundTrip == legacyBytes)
precondition(!originalBytes.isEmpty)

// Two valid individual imports can exceed the old record cap; every record must round-trip.
let first = (0..<6_000).map { item("First \($0)") }
let second = (0..<6_000).map { item("Second \($0)") }
let firstBackup = try ReminderBackup.decode(ReminderBackup.encode(snapshot: ReminderSnapshot(reminders: first)))
let secondBackup = try ReminderBackup.decode(ReminderBackup.encode(snapshot: ReminderSnapshot(reminders: second)))
let mergedOnce = try firstBackup.merging(into: ReminderSnapshot())
let mergedTwice = try secondBackup.merging(into: mergedOnce)
precondition(mergedTwice.reminders.count == 12_000)
let fullBackup = try ReminderBackup.decode(ReminderBackup.encode(snapshot: mergedTwice))
precondition(fullBackup.reminders == mergedTwice.reminders)
let recovered = try fullBackup.merging(into: ReminderSnapshot())
precondition(Set(recovered.reminders.map(\.id)) == Set(mergedTwice.reminders.map(\.id)))

// Large notes/history must not disable Export or create a backup Import cannot read.
var large = item("Large notes")
large.notes = String(repeating: "x", count: 10_000_001)
let largeData = try ReminderBackup.encode(snapshot: ReminderSnapshot(reminders: [large]))
precondition(largeData.count > 10_000_000)
let largeBackup = try ReminderBackup.decode(largeData)
precondition(largeBackup.reminders == [large])
let largeRestore = try largeBackup.merging(into: ReminderSnapshot())
precondition(largeRestore.reminders[0].notes == large.notes)

// Duplicate IDs, unknown format versions and malformed records are still rejected.
expectFailure("duplicate backup IDs") {
    _ = try ReminderBackup.decode(JSONEncoder().encode(ReminderBackup(snapshot: ReminderSnapshot(reminders: [a, a]))))
}
var json = try JSONSerialization.jsonObject(with: ReminderBackup.encode(snapshot: original)) as! [String: Any]
json["version"] = 99
expectFailure("unknown backup version") {
    _ = try ReminderBackup.decode(JSONSerialization.data(withJSONObject: json))
}
print("Database safety checks passed: omitted records/history, tombstones, cancellation history, stale/corrupt/missing files, legacy readability, large backup round-trips and invalid imports.")
