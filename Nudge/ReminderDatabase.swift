import Foundation
import CryptoKit

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
    enum Problem: Error, Equatable {
        case invalid, missing, changed, destructiveChange, unsupported
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
    // The injectable writer exercises failures at each durable boundary in checks.
    var writeFile: (Data, URL, Data.WritingOptions) throws -> Void = { data, url, options in
        try data.write(to: url, options: options)
    }

    var readFile: (URL) throws -> Data = { try Data(contentsOf: $0) }

    var recoveryURL: URL { url.appendingPathExtension("recovery") }
    var damagedURL: URL { url.appendingPathExtension("damaged") }

    private struct Header: Decodable { let version: Int }
    private struct RecoveryRecord: Codable, Equatable {
        let version: Int
        let payload: Data
        let checksum: String
        let replacesPrimaryChecksum: String?
        let integrity: String
    }

    private static func checksum(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func integrity(payload: String, previous: String?) -> String {
        checksum(Data("version=1\nprevious=\(previous ?? "missing")\npayload=\(payload)".utf8))
    }

    private func decodeSnapshot(_ bytes: Data) throws -> ReminderSnapshot {
        do {
            let header = try JSONDecoder().decode(Header.self, from: bytes)
            guard header.version == 1 else { throw Problem.unsupported }
            return try JSONDecoder().decode(ReminderSnapshot.self, from: bytes).validated()
        } catch let error as DecodingError {
            // Valid JSON with an unknown enum/required field can belong to a
            // newer app even if its schema number is unchanged. Never roll it back.
            if (try? JSONSerialization.jsonObject(with: bytes)) != nil { throw Problem.unsupported }
            throw error
        }
    }

    private func readBytes(_ file: URL) throws -> Data? {
        do { return try readFile(file) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        }
    }

    private func readRecovery() throws -> RecoveryRecord? {
        guard let bytes = try readBytes(recoveryURL) else { return nil }
        let header = try JSONDecoder().decode(Header.self, from: bytes)
        guard header.version == 1 else { throw Problem.unsupported }
        let record = try JSONDecoder().decode(RecoveryRecord.self, from: bytes)
        guard Self.checksum(record.payload) == record.checksum,
              Self.integrity(payload: record.checksum, previous: record.replacesPrimaryChecksum) == record.integrity else { throw Problem.invalid }
        _ = try decodeSnapshot(record.payload)
        return record
    }

    private func atomicWrite(_ bytes: Data, to file: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try writeFile(bytes, file, options)
    }

    private func writeRecovery(_ payload: Data, replacing primary: Data?) throws {
        _ = try decodeSnapshot(payload)
        let digest = Self.checksum(payload)
        let previous = primary.map(Self.checksum)
        let record = RecoveryRecord(version: 1, payload: payload, checksum: digest,
                                    replacesPrimaryChecksum: previous,
                                    integrity: Self.integrity(payload: digest, previous: previous))
        try atomicWrite(JSONEncoder().encode(record), to: recoveryURL)
        guard let checked = try readRecovery(), checked == record else { throw Problem.invalid }
    }

    private func preserveDamaged(_ bytes: Data) throws {
        let first = try readBytes(damagedURL)
        let destination = first == nil || first == bytes ? damagedURL
            : url.appendingPathExtension("damaged-\(Self.checksum(bytes))")
        if try readBytes(destination) != bytes { try atomicWrite(bytes, to: destination) }
        guard try readBytes(destination) == bytes else { throw Problem.invalid }
    }

    private func restore(_ record: RecoveryRecord, damaged: Data?,
                         report: (String) -> Void) throws -> Source {
        let snapshot = try decodeSnapshot(record.payload)
        do {
            // Keep the first damaged original for inspection; never replace it
            // with a blank database, and don't create unlimited quarantine files.
            if let damaged { try preserveDamaged(damaged) }
            try atomicWrite(record.payload, to: url)
            report("Recovered your reminders from the automatic backup.")
        } catch {
            // The checksummed recovery copy is already durable. Keep it usable
            // even if a full disk or temporary write failure prevents repair.
            report("Using the automatic backup. The main file will be repaired when storage is available.")
        }
        preferences.set(true, forKey: Self.migratedKey)
        return .file(snapshot)
    }

    func read(report: (String) -> Void = { _ in }) throws -> Source {
        // A protected/unreadable main file is not corruption: propagate IO errors.
        let primary = try readBytes(url)
        let recovery: RecoveryRecord?
        do { recovery = try readRecovery() }
        catch Problem.unsupported { throw Problem.unsupported }
        catch {
            // Permission/protected-data/IO failures do not prove corruption. The
            // backup may hold a newer committed save than the readable primary.
            guard error is DecodingError || (error as? Problem) == .invalid else { throw error }
            // A bad backup may be replaced only from a fully valid primary.
            guard let primary, let snapshot = try? decodeSnapshot(primary) else { throw error }
            do {
                try writeRecovery(primary, replacing: primary)
                report("Automatic backup is ready.")
            } catch {
                report("Your reminders are readable, but the automatic backup could not be refreshed.")
            }
            preferences.set(true, forKey: Self.migratedKey)
            return .file(snapshot)
        }

        if let primary {
            let snapshot: ReminderSnapshot
            do { snapshot = try decodeSnapshot(primary) }
            catch Problem.unsupported { throw Problem.unsupported }
            catch {
                guard let recovery else { throw error }
                return try restore(recovery, damaged: primary, report: report)
            }
            let digest = Self.checksum(primary)
            if let recovery, recovery.checksum != digest,
               recovery.replacesPrimaryChecksum == digest {
                // The backup write is the commit point. A terminated process or
                // failed main-file mirror must not undo that accepted change.
                return try restore(recovery, damaged: nil, report: report)
            }
            if let recovery, recovery.checksum != digest {
                try validateTransition(from: decodeSnapshot(recovery.payload), to: snapshot)
            }
            if recovery?.checksum != digest {
                // Upgrade, lost/broken backup, or a valid write by an older app:
                // preserve the valid primary rather than roll it back.
                do {
                    try writeRecovery(primary, replacing: primary)
                    report("Automatic backup is ready.")
                } catch {
                    report("Your reminders are readable, but the automatic backup could not be refreshed.")
                }
            } else {
                report("Automatic backup is ready.")
            }
            preferences.set(true, forKey: Self.migratedKey)
            return .file(snapshot)
        }

        if let recovery { return try restore(recovery, damaged: nil, report: report) }
        // Never fall back to a stale legacy copy after migration, even when both
        // files have disappeared. A genuine first install may still be empty.
        guard preferences.object(forKey: Self.migratedKey) == nil else { throw Problem.missing }
        guard let legacy = preferences.object(forKey: Self.legacyKey) else {
            report("Automatic backup starts with your first saved reminder.")
            return .missing
        }
        guard let data = legacy as? Data else { throw Problem.invalid }
        let reminders = try JSONDecoder().decode([Reminder].self, from: data)
        return .legacy(try ReminderSnapshot(reminders: reminders).validated())
    }

    private func validateTransition(from previous: ReminderSnapshot, to next: ReminderSnapshot) throws {
        let removed = Set(previous.reminders.map(\.id)).subtracting(next.reminders.map(\.id))
        guard removed.isSubset(of: next.deletedIDs),
              previous.deletedIDs.isSubset(of: next.deletedIDs),
              (previous.stoppedNotificationGenerations ?? []).isSubset(of: next.stoppedNotificationGenerations ?? []) else {
            throw Problem.destructiveChange
        }
    }

    func commit(_ snapshot: ReminderSnapshot, replacing source: Source) throws -> Source {
        guard try read() == source else { throw Problem.changed }
        let checked = try snapshot.validated()
        let previous: ReminderSnapshot
        switch source {
        case .missing: previous = ReminderSnapshot()
        case .legacy(let existing), .file(let existing): previous = existing
        }
        try validateTransition(from: previous, to: checked)
        let bytes = try JSONEncoder().encode(checked)
        let priorBytes = try readBytes(url)
        // Commit durably to the recovery copy first. If this fails, the primary
        // remains untouched and the caller gets an error. Once it succeeds, the
        // save is committed even if mirroring the primary is interrupted.
        try writeRecovery(bytes, replacing: priorBytes)
        preferences.set(true, forKey: Self.migratedKey)
        do {
            if let priorBytes, (try? decodeSnapshot(priorBytes)) == nil { try preserveDamaged(priorBytes) }
            try atomicWrite(bytes, to: url)
        } catch { /* The verified recovery record remains the durable committed copy. */ }
        return .file(checked)
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
