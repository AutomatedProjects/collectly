import Foundation

/// Pure, UI-independent review state: which photos exist, what was decided for
/// each, what is left to review, and an undo history.
///
/// Decisions for photos that are not currently visible (for example, photos
/// deselected under limited library access) are retained so they come back if
/// the photo becomes visible again, but they are excluded from progress.
struct ReviewSession: Sendable {
    static let undoLimit = 100

    struct UndoEntry: Equatable, Sendable {
        let photoID: String
        let decision: ReviewDecision
    }

    /// Photos visible in the library, in review order (newest first).
    private(set) var libraryIDs: [String] = []
    private(set) var decisions: [String: ReviewDecision]
    /// Unreviewed photos; the first element is the photo currently on screen.
    private(set) var queue: [String] = []
    private(set) var undoStack: [UndoEntry] = []
    private(set) var progress: ReviewProgress = .empty
    /// Visible photos marked for deletion, in library order.
    private(set) var markedForDeletion: [String] = []

    private var librarySet: Set<String> = []

    init(libraryIDs: [String] = [], decisions: [String: ReviewDecision] = [:]) {
        self.decisions = decisions
        reconcile(with: libraryIDs)
    }

    var current: String? { queue.first }
    var upNext: String? { queue.dropFirst().first }
    var canUndo: Bool { !undoStack.isEmpty }

    func contains(_ photoID: String) -> Bool { librarySet.contains(photoID) }

    /// Replaces the set of visible photos, e.g. after the library changed.
    mutating func reconcile(with ids: [String]) {
        var seen = Set<String>()
        libraryIDs = ids.filter { seen.insert($0).inserted }
        librarySet = seen
        queue = libraryIDs.filter { decisions[$0] == nil }
        undoStack.removeAll { !seen.contains($0.photoID) }
        recount()
    }

    /// Records a decision for the current photo and advances the queue.
    /// Returns the photo that was decided, or `nil` if nothing is left.
    @discardableResult
    mutating func decide(_ decision: ReviewDecision) -> String? {
        guard let id = queue.first else { return nil }
        queue.removeFirst()
        decisions[id] = decision
        undoStack.append(UndoEntry(photoID: id, decision: decision))
        if undoStack.count > Self.undoLimit {
            undoStack.removeFirst(undoStack.count - Self.undoLimit)
        }
        recount()
        return id
    }

    /// Reverts the most recent decision and puts that photo back on screen.
    /// Entries made stale by later changes (restore, reset) are skipped.
    @discardableResult
    mutating func undo() -> UndoEntry? {
        while let entry = undoStack.popLast() {
            guard decisions[entry.photoID] == entry.decision, librarySet.contains(entry.photoID) else { continue }
            decisions[entry.photoID] = nil
            queue.insert(entry.photoID, at: 0)
            recount()
            return entry
        }
        return nil
    }

    /// Moves a photo out of the deletion queue and marks it as kept.
    mutating func restore(_ photoID: String) {
        guard decisions[photoID] == .delete else { return }
        decisions[photoID] = .keep
        recount()
    }

    mutating func restoreAll() {
        for id in markedForDeletion {
            decisions[id] = .keep
        }
        recount()
    }

    /// Forgets photos that were permanently removed from the library.
    mutating func removeDeleted(_ ids: [String]) {
        let removed = Set(ids)
        for id in removed {
            decisions[id] = nil
        }
        reconcile(with: libraryIDs.filter { !removed.contains($0) })
    }

    /// Sends every kept photo back to the review queue. Photos marked for
    /// deletion stay marked.
    mutating func resetKept() {
        decisions = decisions.filter { $0.value != .keep }
        undoStack.removeAll { $0.decision == .keep }
        queue = libraryIDs.filter { decisions[$0] == nil }
        recount()
    }

    private mutating func recount() {
        var kept = 0
        var marked: [String] = []
        for id in libraryIDs {
            switch decisions[id] {
            case .keep: kept += 1
            case .delete: marked.append(id)
            case nil: break
            }
        }
        markedForDeletion = marked
        progress = ReviewProgress(total: libraryIDs.count, kept: kept, markedForDeletion: marked.count)
    }
}
