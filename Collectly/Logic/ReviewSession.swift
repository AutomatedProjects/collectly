import Foundation

/// Pure, UI-independent review state: which photos exist, what was decided for
/// each, what is left to review, and an undo history.
///
/// Decisions for photos that are not currently visible (for example, photos
/// deselected under limited library access) are retained so they come back if
/// the photo becomes visible again, but they are excluded from progress.
/// Delete marks are the exception: see `pruneStaleDeleteMarks`.
struct ReviewSession: Sendable {
    static let undoLimit = 100
    /// How long a delete mark survives while its photo is hidden (limited
    /// access). Expiring a mark only returns the photo to review; it never
    /// deletes anything.
    static let hiddenDeleteMarkLifetime: TimeInterval = 30 * 24 * 60 * 60

    struct UndoEntry: Equatable, Sendable {
        let photoID: String
        let decision: ReviewDecision
        /// The album this decision filed the photo into, if it was a
        /// "keep in album". Undo removes the photo from that album again.
        let filedAlbumID: UUID?

        init(photoID: String, decision: ReviewDecision, filedAlbumID: UUID? = nil) {
            self.photoID = photoID
            self.decision = decision
            self.filedAlbumID = filedAlbumID
        }
    }

    /// Photos visible in the library, in review order (newest first).
    private(set) var libraryIDs: [String] = []
    private(set) var decisions: [String: ReviewDecision]
    /// When each photo was marked for deletion.
    private(set) var deleteMarkedAt: [String: Date]
    /// Unreviewed photos; the first element is the photo currently on screen.
    private(set) var queue: [String] = []
    private(set) var undoStack: [UndoEntry] = []
    private(set) var progress: ReviewProgress = .empty
    /// Visible photos marked for deletion, in library order.
    private(set) var markedForDeletion: [String] = []

    private var librarySet: Set<String> = []

    init(libraryIDs: [String] = [],
         decisions: [String: ReviewDecision] = [:],
         deleteMarkedAt: [String: Date] = [:],
         now: Date = Date()) {
        self.decisions = decisions
        var markedAt: [String: Date] = [:]
        for (id, decision) in decisions where decision == .delete {
            markedAt[id] = deleteMarkedAt[id] ?? now
        }
        self.deleteMarkedAt = markedAt
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

    /// Drops delete marks for photos that are not visible, so a forgotten mark
    /// can't resurface later and be deleted in a batch. With full library
    /// access a missing photo is gone (or hidden in Photos), so its mark is
    /// dropped right away. With limited access the photo may just be
    /// deselected, so its mark is kept for `hiddenDeleteMarkLifetime`.
    /// Dropping a mark sends the photo back to review; it never deletes.
    /// Returns the photos whose marks were dropped.
    @discardableResult
    mutating func pruneStaleDeleteMarks(libraryIsComplete: Bool, now: Date = Date()) -> [String] {
        let stale = deleteMarkedAt.compactMap { id, markedAt -> String? in
            guard !librarySet.contains(id) else { return nil }
            return libraryIsComplete || now.timeIntervalSince(markedAt) > Self.hiddenDeleteMarkLifetime ? id : nil
        }
        for id in stale {
            decisions[id] = nil
            deleteMarkedAt[id] = nil
        }
        recount()
        return stale.sorted()
    }

    /// Records a decision for the current photo and advances the queue.
    /// Returns the photo that was decided, or `nil` if nothing is left.
    @discardableResult
    mutating func decide(_ decision: ReviewDecision, now: Date = Date()) -> String? {
        guard let id = queue.first else { return nil }
        return decide(decision, for: id, now: now) ? id : nil
    }

    /// Records a decision for `photoID`, but only if it is still the photo on
    /// screen. Guards against a decision landing on a different photo than
    /// the one the user acted on (for example after a delayed swipe).
    @discardableResult
    mutating func decide(_ decision: ReviewDecision,
                         for photoID: String,
                         filedIn albumID: UUID? = nil,
                         now: Date = Date()) -> Bool {
        guard queue.first == photoID else { return false }
        queue.removeFirst()
        decisions[photoID] = decision
        deleteMarkedAt[photoID] = decision == .delete ? now : nil
        undoStack.append(UndoEntry(photoID: photoID, decision: decision, filedAlbumID: albumID))
        if undoStack.count > Self.undoLimit {
            undoStack.removeFirst(undoStack.count - Self.undoLimit)
        }
        recount()
        return true
    }

    /// Reverts the most recent decision and puts that photo back on screen.
    /// Entries made stale by later changes (restore, reset) are skipped.
    @discardableResult
    mutating func undo() -> UndoEntry? {
        while let entry = undoStack.popLast() {
            guard decisions[entry.photoID] == entry.decision, librarySet.contains(entry.photoID) else { continue }
            decisions[entry.photoID] = nil
            deleteMarkedAt[entry.photoID] = nil
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
        deleteMarkedAt[photoID] = nil
        recount()
    }

    /// Keeps every photo in `photoIDs` that is still marked for deletion.
    /// Photos marked after the caller captured `photoIDs` stay marked.
    mutating func restoreAll(_ photoIDs: [String]) {
        let marked = Set(markedForDeletion)
        for id in photoIDs where marked.contains(id) {
            decisions[id] = .keep
            deleteMarkedAt[id] = nil
        }
        recount()
    }

    /// Forgets photos that were permanently removed from the library.
    mutating func removeDeleted(_ ids: [String]) {
        let removed = Set(ids)
        for id in removed {
            decisions[id] = nil
            deleteMarkedAt[id] = nil
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
