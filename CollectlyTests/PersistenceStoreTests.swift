import Foundation
import Testing
@testable import Collectly

@MainActor
struct PersistenceStoreTests {
    private let directory = FileManager.default.temporaryDirectory
        .appending(path: "CollectlyTests-\(UUID().uuidString)")

    private var fileURL: URL { directory.appending(path: "state.json") }

    private func writeRaw(_ text: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: fileURL)
    }

    private func readRaw(_ url: URL? = nil) throws -> String {
        try String(contentsOf: url ?? fileURL, encoding: .utf8)
    }

    private func backupNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { FilePersistenceStore.backupTimestamp(fromFileName: $0) != nil }
            .sorted()
    }

    private func encoded(_ state: PersistedState) throws -> String {
        String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
    }

    /// Loads, expecting a `PersistenceError`.
    private func loadError(_ store: FilePersistenceStore) -> PersistenceError? {
        do {
            _ = try store.load()
            Issue.record("Expected load to throw")
            return nil
        } catch {
            return error as? PersistenceError
        }
    }

    @Test func missingFileLoadsEmptyState() throws {
        let store = FilePersistenceStore(fileURL: fileURL)
        #expect(try store.load() == PersistedState())
    }

    @Test func roundTripsState() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FilePersistenceStore(fileURL: fileURL)
        let state = PersistedState(
            decisions: ["a": .keep, "b": .delete],
            deleteMarkedAt: ["b": Date(timeIntervalSince1970: 100)],
            albums: [Album(name: "Pets", photoIDs: ["a"], createdAt: Date(timeIntervalSince1970: 100))]
        )
        try store.save(state)
        store.flush()
        #expect(try FilePersistenceStore(fileURL: fileURL).load() == state)
    }

    // MARK: Background writer (L9)

    @Test func rapidSavesCoalesceAndTheLastOneWins() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FilePersistenceStore(fileURL: fileURL)
        for index in 0..<50 {
            try store.save(PersistedState(decisions: ["photo-\(index)": .keep]))
        }
        store.flush()
        #expect(try FilePersistenceStore(fileURL: fileURL).load().decisions == ["photo-49": .keep])
    }

    @Test func backgroundWriteFailureIsReported() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        // A plain file where the directory should be makes the write fail.
        try Data().write(to: directory)
        let store = FilePersistenceStore(fileURL: fileURL)
        var reported: Error?
        store.saveFailureHandler = { reported = $0 }
        try store.save(PersistedState())
        store.flush()
        for _ in 0..<100 where reported == nil { await Task.yield() }
        #expect(reported != nil)
    }

    // MARK: File protection (L6)

    @Test func usesCompleteFileProtection() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(FilePersistenceStore.writingOptions.contains(.completeFileProtection))
        #expect(FilePersistenceStore.writingOptions.contains(.atomic))
        let store = FilePersistenceStore(fileURL: fileURL)
        try store.save(PersistedState())
        store.flush()
        // The simulator may not report protection classes; devices do.
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        if let protection = attributes[.protectionKey] as? FileProtectionType {
            #expect(protection == .complete)
        }
    }

    // MARK: Corrupt files and backups (M2, L6)

    @Test func corruptedFileIsBackedUpAndThenSavingIsAllowed() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeRaw("not json")

        let store = FilePersistenceStore(fileURL: fileURL)
        guard case .corruptedData(let backupURL)? = loadError(store) else {
            Issue.record("Expected corruptedData")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(try readRaw(backupURL) == "not json")
        #expect(backupURL.lastPathComponent.hasPrefix("state.corrupt-"))

        // The original is safe in the backup, so starting fresh may save.
        try store.save(PersistedState(decisions: ["a": .keep]))
        store.flush()
        #expect(try readRaw(backupURL) == "not json")
        #expect(try FilePersistenceStore(fileURL: fileURL).load().decisions == ["a": .keep])
    }

    @Test func backupNamesDoNotCollideWithinTheSameMoment() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FilePersistenceStore(fileURL: fileURL)
        var backups: [URL] = []
        for text in ["first", "second"] {
            try writeRaw(text)
            if case .corruptedData(let url)? = loadError(store) { backups.append(url) }
        }
        #expect(backups.count == 2)
        #expect(Set(backups).count == 2)
        #expect(try backups.map { try readRaw($0) } == ["first", "second"])
    }

    @Test func onlyTheNewestBackupsAreKept() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeRaw("")
        // Older-format backups are included in the limit.
        try Data("legacy".utf8).write(to: directory.appending(path: "state.corrupt-1700000000.json"))
        try Data("keep me".utf8).write(to: directory.appending(path: "unrelated.json"))

        let store = FilePersistenceStore(fileURL: fileURL)
        var newest: URL?
        for index in 0..<5 {
            try writeRaw("corrupt \(index)")
            if case .corruptedData(let url)? = loadError(store) { newest = url }
        }
        let names = try backupNames()
        #expect(names.count == FilePersistenceStore.maxBackups)
        #expect(!names.contains("state.corrupt-1700000000.json"))
        let newestURL: URL = try #require(newest)
        #expect(try readRaw(newestURL) == "corrupt 4")
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "unrelated.json").path))
    }

    @Test func parsesBackupTimestamps() {
        #expect(FilePersistenceStore.backupTimestamp(fromFileName: "state.corrupt-1700000000.json") == 1_700_000_000_000)
        #expect(FilePersistenceStore.backupTimestamp(
            fromFileName: "state.corrupt-001700000000123-8F0C6A4E-0000-0000-0000-000000000000.json") == 1_700_000_000_123)
        #expect(FilePersistenceStore.backupTimestamp(fromFileName: "state.repaired-000000000000042-X.json") == 42)
        #expect(FilePersistenceStore.backupTimestamp(fromFileName: "state.json") == nil)
        #expect(FilePersistenceStore.backupTimestamp(fromFileName: "other.corrupt-1.json") == nil)
    }

    // MARK: Loss-safe failures (M2)

    @Test func failedBackupBlocksSavingSoTheOriginalSurvives() throws {
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        try writeRaw("not json")
        // A read-only directory makes moving the file aside fail.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)

        let store = FilePersistenceStore(fileURL: fileURL)
        #expect(loadError(store) == .backupFailed)
        #expect(store.isSavingBlocked)
        #expect(throws: PersistenceError.savingDisabled) { try store.save(PersistedState()) }
        store.flush()
        #expect(try readRaw() == "not json")
    }

    @Test func unreadableFileBlocksSavingUntilALoadSucceeds() throws {
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let original = PersistedState(decisions: ["a": .keep])
        try writeRaw(try encoded(original))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)

        let store = FilePersistenceStore(fileURL: fileURL)
        #expect(loadError(store) == .unreadable)
        #expect(throws: PersistenceError.savingDisabled) { try store.save(PersistedState()) }

        // Once readable again (e.g. the device was unlocked), loading works
        // and saving resumes.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        #expect(try store.load() == original)
        try store.save(PersistedState(decisions: ["b": .keep]))
        store.flush()
        #expect(try FilePersistenceStore(fileURL: fileURL).load().decisions == ["b": .keep])
    }

    @Test func newerVersionIsNeverOverwritten() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let newer = try encoded(PersistedState(version: PersistedState.currentVersion + 1, decisions: ["a": .keep]))
        try writeRaw(newer)

        let store = FilePersistenceStore(fileURL: fileURL)
        #expect(loadError(store) == .unsupportedVersion(PersistedState.currentVersion + 1))
        #expect(throws: PersistenceError.savingDisabled) { try store.save(PersistedState()) }
        #expect(try readRaw() == newer)
        #expect(try backupNames().isEmpty)
    }

    // MARK: Validation on load (L5)

    @Test func impossibleVersionIsTreatedAsCorrupt() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeRaw(try encoded(PersistedState(version: 0)))
        guard case .corruptedData? = loadError(FilePersistenceStore(fileURL: fileURL)) else {
            Issue.record("Expected corruptedData")
            return
        }
    }

    @Test func repairedStateKeepsACopyOfTheOriginal() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let original = try encoded(PersistedState(albums: [
            Album(id: id, name: "Pets", photoIDs: ["a"], createdAt: Date(timeIntervalSince1970: 0)),
            Album(id: id, name: "Pets", photoIDs: ["b"], createdAt: Date(timeIntervalSince1970: 0)),
        ]))
        try writeRaw(original)

        let loaded = try FilePersistenceStore(fileURL: fileURL).load()
        #expect(loaded.albums.map(\.photoIDs) == [["a", "b"]])
        let backups = try backupNames()
        #expect(backups.count == 1)
        #expect(backups.first?.hasPrefix("state.repaired-") == true)
        #expect(try readRaw(directory.appending(path: backups[0])) == original)
    }

    @Test func legacyFileWithoutDeleteDatesLoadsWithoutBackup() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeRaw(#"{"version":1,"decisions":{"a":"delete"},"albums":[]}"#)
        let loaded = try FilePersistenceStore(fileURL: fileURL).load()
        #expect(loaded.decisions == ["a": .delete])
        #expect(loaded.deleteMarkedAt.keys.sorted() == ["a"])
        #expect(try backupNames().isEmpty)
    }
}
