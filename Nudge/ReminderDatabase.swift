import Foundation

struct ReminderSnapshot: Codable, Equatable {
    var version = 1
    var reminders: [Reminder] = []
    var deletedIDs: Set<UUID> = []

    func validated() throws -> Self {
        guard version == 1,
              Set(reminders.map(\.id)).count == reminders.count,
              reminders.allSatisfy({ !deletedIDs.contains($0.id) && $0.hasValidSchedule }) else {
            throw ReminderDatabase.Problem.invalid
        }
        return self
    }
}

struct ReminderDatabase {
    enum Problem: Error {
        case invalid, missing, changed
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
        let bytes = try JSONEncoder().encode(snapshot.validated())
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
