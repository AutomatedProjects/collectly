import Foundation
import Testing
@testable import Collectly

struct PersistedStateValidatorTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    @Test func cleanStateIsUnchanged() throws {
        let state = PersistedState(decisions: ["a": .keep, "b": .delete],
                                   deleteMarkedAt: ["b": Date(timeIntervalSince1970: 50)],
                                   albums: [Album(name: "Pets", photoIDs: ["a"], createdAt: now)])
        let outcome = try PersistedStateValidator.validate(state, now: now)
        #expect(outcome == .init(state: state, repaired: false))
    }

    @Test func rejectsImpossibleAndNewerVersions() {
        #expect(throws: StateValidationError.invalidVersion(0)) {
            try PersistedStateValidator.validate(PersistedState(version: 0))
        }
        #expect(throws: StateValidationError.newerVersion(PersistedState.currentVersion + 1)) {
            try PersistedStateValidator.validate(PersistedState(version: PersistedState.currentVersion + 1))
        }
    }

    @Test func mergesDuplicateAlbumIDsAndDedupesPhotos() throws {
        let id = UUID()
        let state = PersistedState(albums: [
            Album(id: id, name: "Pets", photoIDs: ["a", "a", ""], createdAt: now),
            Album(id: id, name: "Pets copy", photoIDs: ["b", "a"], createdAt: now),
        ])
        let outcome = try PersistedStateValidator.validate(state, now: now)
        #expect(outcome.repaired)
        #expect(outcome.state.albums == [Album(id: id, name: "Pets", photoIDs: ["a", "b"], createdAt: now)])
    }

    @Test func repairsInvalidAndClashingAlbumNames() throws {
        let long = String(repeating: "x", count: AlbumCollection.maxNameLength + 5)
        let state = PersistedState(albums: [
            Album(name: "Family", createdAt: now),
            Album(name: " family ", createdAt: now),
            Album(name: "FAMILY", createdAt: now),
            Album(name: "   ", createdAt: now),
            Album(name: long, createdAt: now),
            Album(name: long, createdAt: now),
        ])
        let names = try PersistedStateValidator.validate(state, now: now).state.albums.map(\.name)
        let truncated = String(repeating: "x", count: AlbumCollection.maxNameLength)
        #expect(names == ["Family", "family 2", "FAMILY 3", "Untitled Album",
                          truncated, String(truncated.dropLast(2)) + " 2"])
        #expect(names.allSatisfy { $0.count <= AlbumCollection.maxNameLength })
        // Every repaired name passes the same rules as user-entered names.
        var collection = AlbumCollection()
        for name in names { try collection.create(named: name) }
    }

    @Test func dropsEmptyPhotoIDsFromDecisions() throws {
        let outcome = try PersistedStateValidator.validate(PersistedState(decisions: ["": .delete, "a": .keep]), now: now)
        #expect(outcome.repaired)
        #expect(outcome.state.decisions == ["a": .keep])
    }

    @Test func normalizesDeleteMarkDatesWithoutCountingAsRepair() throws {
        let state = PersistedState(decisions: ["a": .delete, "b": .delete, "c": .keep],
                                   deleteMarkedAt: ["b": now.addingTimeInterval(86_400), "c": now, "gone": now])
        let outcome = try PersistedStateValidator.validate(state, now: now)
        #expect(!outcome.repaired)
        // Missing date: now. Future date: clamped. Dates for non-delete or unknown photos: dropped.
        #expect(outcome.state.deleteMarkedAt == ["a": now, "b": now])
    }
}
