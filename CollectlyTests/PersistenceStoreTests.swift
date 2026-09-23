import Foundation
import Testing
@testable import Collectly

@MainActor
struct PersistenceStoreTests {
    private let directory = FileManager.default.temporaryDirectory
        .appending(path: "CollectlyTests-\(UUID().uuidString)")

    private var fileURL: URL { directory.appending(path: "state.json") }

    @Test func missingFileLoadsEmptyState() throws {
        let store = FilePersistenceStore(fileURL: fileURL)
        #expect(try store.load() == PersistedState())
    }

    @Test func roundTripsState() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FilePersistenceStore(fileURL: fileURL)
        let state = PersistedState(
            decisions: ["a": .keep, "b": .delete],
            albums: [Album(name: "Pets", photoIDs: ["a"], createdAt: Date(timeIntervalSince1970: 100))]
        )
        try store.save(state)
        #expect(try FilePersistenceStore(fileURL: fileURL).load() == state)
    }

    @Test func corruptedFileIsBackedUpNotOverwritten() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)

        let store = FilePersistenceStore(fileURL: fileURL)
        var backupURL: URL?
        do {
            _ = try store.load()
            Issue.record("Expected load to throw")
        } catch PersistenceError.corruptedData(let url) {
            backupURL = url
        }

        let backup = try #require(backupURL)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(try String(contentsOf: backup, encoding: .utf8) == "not json")
    }
}
