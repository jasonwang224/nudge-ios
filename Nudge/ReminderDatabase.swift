import Foundation

struct ReminderSnapshot: Codable, Equatable {
    var version = 1
    var reminders: [Reminder] = []
    var deletedIDs: Set<UUID> = []
    // Additive/optional so existing version-1 databases remain readable.
    // A completed occurrence must stop even if permission prevents its next
    // occurrence from being queued. Each token names one exact id + generation.
    var stoppedNotificationGenerations: Set<String>?

    func validated() throws -> Self {
        let activeGenerations = Set(reminders.filter { $0.completedAt == nil }.map {
            "\($0.id.uuidString).\($0.generation.uuidString)"
        })
        guard version == 1,
              Set(reminders.map(\.id)).count == reminders.count,
              reminders.allSatisfy({ !deletedIDs.contains($0.id) && $0.hasValidSchedule }),
              (stoppedNotificationGenerations ?? []).allSatisfy({ token in
                  guard let request = PendingNudge("nudge.\(token).0") else { return false }
                  return request.generationIdentifier == token && !activeGenerations.contains(token)
              }) else {
            throw ReminderDatabase.Problem.invalid
        }
        return self
    }
}

struct ReminderDatabase {
    enum Problem: Error {
        case invalid, missing, changed, destructiveChange
    }

    enum Source: Equatable {
        case missing
        case legacy(ReminderSnapshot)
        case file(ReminderSnapshot)
    }

    static let legacyKey = "Nudge.reminders.v1"
    static let migratedKey = "Nudge.reminders.file.v1"
    let url: URL
    let preferences: UserDefaults

    func read() throws -> Source {
        let bytes: Data
        do {
            bytes = try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            // Never fall back to the stale legacy copy after a successful migration.
            guard preferences.object(forKey: Self.migratedKey) == nil else { throw Problem.missing }
            guard let legacy = preferences.object(forKey: Self.legacyKey) else { return .missing }
            guard let data = legacy as? Data else { throw Problem.invalid }
            let reminders = try JSONDecoder().decode([Reminder].self, from: data)
            return .legacy(try ReminderSnapshot(reminders: reminders).validated())
        }
        let snapshot = try JSONDecoder().decode(ReminderSnapshot.self, from: bytes).validated()
        if preferences.object(forKey: Self.migratedKey) == nil {
            preferences.set(true, forKey: Self.migratedKey)
        }
        return .file(snapshot)
    }

    func commit(_ snapshot: ReminderSnapshot, replacing source: Source) throws -> Source {
        // A vanished, unreadable, or changed file must never be replaced by in-memory data.
        guard try read() == source else { throw Problem.changed }
        let checked = try snapshot.validated()
        let previous: ReminderSnapshot
        switch source {
        case .missing: previous = ReminderSnapshot()
        case .legacy(let existing), .file(let existing): previous = existing
        }
        // A syntactically valid snapshot can still accidentally omit every record.
        // Only explicit deletion tombstones authorize disappearance; retain all
        // cancellation bookkeeping so a later import cannot resurrect deleted data.
        let removed = Set(previous.reminders.map(\.id)).subtracting(checked.reminders.map(\.id))
        guard removed.isSubset(of: checked.deletedIDs),
              previous.deletedIDs.isSubset(of: checked.deletedIDs),
              (previous.stoppedNotificationGenerations ?? []).isSubset(of: checked.stoppedNotificationGenerations ?? []) else {
            throw Problem.destructiveChange
        }
        let bytes = try JSONEncoder().encode(checked)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try bytes.write(to: url, options: options)
        preferences.set(true, forKey: Self.migratedKey)
        return .file(snapshot)
    }
}


// Portable backup contains reminders only, never deletion/cancellation bookkeeping.
struct ReminderBackup: Codable {
    let format: String
    let version: Int
    let reminders: [Reminder]

    init(snapshot: ReminderSnapshot) {
        format = "reminder-backup"
        version = 1
        reminders = snapshot.reminders
    }

    static func encode(snapshot: ReminderSnapshot) throws -> Data {
        // History and successive imports can exceed the size of any single import.
        // Never truncate or refuse a valid database merely because it has grown.
        let backup = Self(snapshot: try snapshot.validated())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(backup)
    }

    static func decode(_ data: Data) throws -> Self {
        let backup = try JSONDecoder().decode(Self.self, from: data)
        try backup.validateForImport()
        return backup
    }

    private func validateForImport() throws {
        guard format == "reminder-backup", version == 1 else {
            throw ReminderDatabase.Problem.invalid
        }
        _ = try ReminderSnapshot(reminders: reminders).validated()
    }

    func merging(into current: ReminderSnapshot) throws -> ReminderSnapshot {
        try validateForImport()
        var merged = current
        let known = Set(current.reminders.map(\.id)).union(current.deletedIDs)
        merged.reminders += reminders.filter { !known.contains($0.id) }.map {
            var copy = $0
            copy.generation = UUID()
            return copy
        }
        return try merged.validated()
    }
}
