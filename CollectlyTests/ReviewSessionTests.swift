import Testing
@testable import Collectly

struct ReviewSessionTests {
    private let ids = ["a", "b", "c", "d"]

    @Test func startsWithEveryPhotoQueuedInLibraryOrder() {
        let session = ReviewSession(libraryIDs: ids)
        #expect(session.queue == ids)
        #expect(session.current == "a")
        #expect(session.upNext == "b")
        #expect(session.progress == ReviewProgress(total: 4, kept: 0, markedForDeletion: 0))
        #expect(!session.canUndo)
    }

    @Test func decidingAdvancesQueueAndUpdatesProgress() {
        var session = ReviewSession(libraryIDs: ids)
        #expect(session.decide(.keep) == "a")
        #expect(session.decide(.delete) == "b")

        #expect(session.current == "c")
        #expect(session.decisions == ["a": .keep, "b": .delete])
        #expect(session.markedForDeletion == ["b"])
        #expect(session.progress.reviewed == 2)
        #expect(session.progress.remaining == 2)
        #expect(session.progress.fractionComplete == 0.5)
        #expect(!session.progress.isComplete)
    }

    @Test func decidingWhenQueueIsEmptyDoesNothing() {
        var session = ReviewSession(libraryIDs: ["a"])
        session.decide(.keep)
        #expect(session.decide(.delete) == nil)
        #expect(session.decisions == ["a": .keep])
        #expect(session.progress.isComplete)
    }

    @Test func emptyLibraryIsNotComplete() {
        let session = ReviewSession(libraryIDs: [])
        #expect(session.current == nil)
        #expect(!session.progress.isComplete)
        #expect(session.progress.fractionComplete == 0)
    }

    @Test func undoPutsLastPhotoBackOnScreen() {
        var session = ReviewSession(libraryIDs: ids)
        session.decide(.keep)
        session.decide(.delete)

        let entry = session.undo()
        #expect(entry == .init(photoID: "b", decision: .delete))
        #expect(session.current == "b")
        #expect(session.decisions["b"] == nil)
        #expect(session.markedForDeletion.isEmpty)

        session.undo()
        #expect(session.current == "a")
        #expect(session.queue == ids)
        #expect(session.undo() == nil)
    }

    @Test func undoHistoryIsCapped() {
        let many = (0..<(ReviewSession.undoLimit + 10)).map { "p\($0)" }
        var session = ReviewSession(libraryIDs: many)
        for _ in many { session.decide(.keep) }
        #expect(session.undoStack.count == ReviewSession.undoLimit)
        #expect(session.undoStack.first?.photoID == "p10")
    }

    @Test func undoSkipsEntriesChangedByRestore() {
        var session = ReviewSession(libraryIDs: ids)
        session.decide(.keep)      // a
        session.decide(.delete)    // b
        session.restore("b")       // b is now kept, so its delete entry is stale

        let entry = session.undo()
        #expect(entry?.photoID == "a")
        #expect(session.decisions["b"] == .keep)
    }

    @Test func restoreMovesPhotoFromDeleteToKeep() {
        var session = ReviewSession(libraryIDs: ids)
        session.decide(.delete)
        session.decide(.delete)
        session.restore("a")
        #expect(session.markedForDeletion == ["b"])
        #expect(session.decisions["a"] == .keep)

        session.restore("c") // unreviewed: no-op
        #expect(session.decisions["c"] == nil)

        session.restoreAll()
        #expect(session.markedForDeletion.isEmpty)
        #expect(session.progress.kept == 2)
    }

    @Test func reconcileAddsNewPhotosAndKeepsHiddenDecisionsOutOfProgress() {
        var session = ReviewSession(libraryIDs: ids)
        session.decide(.keep)   // a
        session.decide(.delete) // b

        session.reconcile(with: ["new", "b", "c", "c"])
        #expect(session.libraryIDs == ["new", "b", "c"])
        #expect(session.queue == ["new", "c"])
        #expect(session.progress == ReviewProgress(total: 3, kept: 0, markedForDeletion: 1))
        // "a" is hidden but its decision is remembered.
        #expect(session.decisions["a"] == .keep)

        session.reconcile(with: ids)
        #expect(session.progress.kept == 1)
    }

    @Test func removeDeletedForgetsPhotosEverywhere() {
        var session = ReviewSession(libraryIDs: ids)
        session.decide(.delete) // a
        session.decide(.keep)   // b
        session.removeDeleted(["a"])

        #expect(session.libraryIDs == ["b", "c", "d"])
        #expect(session.decisions["a"] == nil)
        #expect(!session.contains("a"))
        #expect(session.markedForDeletion.isEmpty)
        #expect(session.undoStack.map(\.photoID) == ["b"])
    }

    @Test func resetKeptRequeuesKeptPhotosOnly() {
        var session = ReviewSession(libraryIDs: ids)
        session.decide(.keep)   // a
        session.decide(.delete) // b
        session.decide(.keep)   // c
        session.resetKept()

        #expect(session.queue == ["a", "c", "d"])
        #expect(session.markedForDeletion == ["b"])
        #expect(session.undoStack.map(\.photoID) == ["b"])
    }
}
