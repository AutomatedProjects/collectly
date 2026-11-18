import Foundation
import Observation

/// Observable app state shared by all screens. Coordinates the photo library,
/// the pure `ReviewSession` / `AlbumCollection` logic, and persistence.
@MainActor
@Observable
final class AppModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
    }

    private(set) var authorization: PhotoLibraryAuthorization
    private(set) var loadState: LoadState = .idle
    private(set) var session: ReviewSession
    private(set) var albumCollection: AlbumCollection
    private(set) var isDeleting = false
    /// The photo whose swipe-away animation is running. While set, other
    /// decisions and undo are refused so they can't land on the wrong photo.
    private(set) var committingPhotoID: String?
    /// User-facing error message; the root view shows it as an alert.
    var alertMessage: String?

    @ObservationIgnored let library: PhotoLibraryService
    @ObservationIgnored private let persistence: PersistenceStore
    /// `false` after a load failure that left the saved file as the only good
    /// copy. Changes then stay in memory so the file is never overwritten.
    @ObservationIgnored private(set) var isSavingEnabled = true
    /// The saved file couldn't be read (e.g. the device was locked during a
    /// prewarmed launch). Loading is retried before the next library reload.
    @ObservationIgnored private var needsLoadRetry = false
    @ObservationIgnored private var hasUnsavedChanges = false
    @ObservationIgnored private var reloadGeneration = 0
    @ObservationIgnored private(set) var libraryChangeTask: Task<Void, Never>?
    /// Coalesces bursts of PhotoKit change notifications.
    @ObservationIgnored var libraryChangeDelay: Duration = .milliseconds(300)

    init(library: PhotoLibraryService, persistence: PersistenceStore) {
        self.library = library
        self.persistence = persistence
        self.authorization = library.authorizationStatus()
        session = ReviewSession()
        albumCollection = AlbumCollection()
        loadPersistedState(isRetry: false)
        library.onLibraryChange = { [weak self] in self?.libraryDidChange() }
        persistence.saveFailureHandler = { [weak self] error in
            self?.alertMessage = "Couldn't save your progress. \(error.localizedDescription)"
        }
    }

    static func makeDefault(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppModel {
        #if DEBUG
        if arguments.contains("-CollectlyDemoMode") {
            return AppModel(library: MockPhotoLibraryService(photoCount: 30), persistence: InMemoryPersistenceStore())
        }
        #endif
        return AppModel(library: SystemPhotoLibraryService(), persistence: FilePersistenceStore.makeDefault())
    }

    // MARK: Library access

    func requestAccess() async {
        authorization = await library.requestAuthorization()
        await reloadLibrary()
    }

    /// Re-checks permission and refreshes photos, e.g. when returning from Settings.
    func refresh() async {
        authorization = library.authorizationStatus()
        await reloadLibrary()
    }

    /// Fetches the library and reconciles the session with it. When reloads
    /// overlap, only the most recently started one is applied.
    func reloadLibrary() async {
        if needsLoadRetry { loadPersistedState(isRetry: true) }
        guard authorization.canReadLibrary else { return }
        reloadGeneration += 1
        let generation = reloadGeneration
        if loadState != .loaded { loadState = .loading }
        let ids = await library.fetchPhotoIdentifiers()
        guard generation == reloadGeneration else { return }
        // Access may have been revoked while the fetch was running.
        authorization = library.authorizationStatus()
        guard authorization.canReadLibrary else { return }
        session.reconcile(with: ids)
        if !session.pruneStaleDeleteMarks(libraryIsComplete: authorization == .authorized).isEmpty {
            persist()
        }
        loadState = .loaded
    }

    private func libraryDidChange() {
        libraryChangeTask?.cancel()
        let delay = libraryChangeDelay
        libraryChangeTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.reloadLibrary()
        }
    }

    // MARK: Review

    var isCommittingSwipe: Bool { committingPhotoID != nil }

    func keepCurrent() {
        guard let photoID = session.current else { return }
        decide(.keep, for: photoID)
    }

    func deleteCurrent() {
        guard let photoID = session.current else { return }
        decide(.delete, for: photoID)
    }

    /// Records a decision for `photoID` only if it is still the photo on
    /// screen and no swipe is being committed.
    func decide(_ decision: ReviewDecision, for photoID: String) {
        guard committingPhotoID == nil, session.decide(decision, for: photoID) else { return }
        persist()
    }

    /// Starts committing a swipe on `photoID`. Returns `false` if the photo
    /// isn't on screen any more or another swipe is in flight.
    func beginSwipe(on photoID: String) -> Bool {
        guard committingPhotoID == nil, session.current == photoID else { return false }
        committingPhotoID = photoID
        return true
    }

    /// Finishes a swipe started with `beginSwipe(on:)`.
    func finishSwipe(_ decision: ReviewDecision, on photoID: String) {
        guard committingPhotoID == photoID else { return }
        committingPhotoID = nil
        decide(decision, for: photoID)
    }

    /// Keeps `photoID` and files it into an album in one step, as long as it
    /// is still the photo on screen.
    func keep(_ photoID: String, inAlbum albumID: UUID) {
        guard committingPhotoID == nil else { return }
        guard session.current == photoID else {
            alertMessage = "That photo is no longer up for review, so it wasn't added to the album."
            return
        }
        let added: Bool
        do {
            added = try albumCollection.add(photoID, to: albumID)
        } catch {
            alertMessage = error.localizedDescription
            return
        }
        // Only record a filing this action made, so undo can't remove a
        // photo that was already in the album.
        session.decide(.keep, for: photoID, filedIn: added ? albumID : nil)
        persist()
    }

    func undo() {
        guard committingPhotoID == nil, let entry = session.undo() else { return }
        if let albumID = entry.filedAlbumID {
            albumCollection.remove(entry.photoID, from: albumID)
        }
        persist()
    }

    func resetKeptDecisions() {
        guard committingPhotoID == nil else { return }
        session.resetKept()
        persist()
    }

    // MARK: Deletion

    func restore(_ photoID: String) {
        guard !isDeleting else { return }
        session.restore(photoID)
        persist()
    }

    /// Keeps the photos the user saw when they confirmed "Keep All". Photos
    /// marked after that stay marked.
    func restoreAll(_ photoIDs: [String]) {
        guard !isDeleting else { return }
        session.restoreAll(photoIDs)
        persist()
    }

    /// Deletes the photos the user confirmed, limited to those still marked
    /// for deletion. Call only after the user confirmed in the app; iOS then
    /// shows its own confirmation too.
    func confirmDeletion(of confirmedIDs: [String]) async {
        guard !isDeleting else { return }
        let marked = Set(session.markedForDeletion)
        var seen = Set<String>()
        let ids = confirmedIDs.filter { marked.contains($0) && seen.insert($0).inserted }
        guard !ids.isEmpty else { return }
        isDeleting = true
        defer { isDeleting = false }
        let result: PhotoDeletionResult
        do {
            result = try await library.deletePhotos(withIdentifiers: ids)
        } catch PhotoLibraryError.userCancelled {
            // The user backed out of the system prompt; keep everything marked.
            return
        } catch {
            alertMessage = "Couldn't delete photos. \(error.localizedDescription)"
            return
        }
        if !result.deleted.isEmpty {
            session.removeDeleted(result.deleted)
            albumCollection.removePhotosEverywhere(Set(result.deleted))
            persist()
        }
        if !result.notDeletable.isEmpty {
            let count = result.notDeletable.count
            let deleted = result.deleted.count
            alertMessage = (deleted > 0 ? "Deleted \(deleted) \(deleted == 1 ? "photo" : "photos"). " : "")
                + "\(count) \(count == 1 ? "photo" : "photos") can't be deleted by Collectly, for example because "
                + "\(count == 1 ? "it was" : "they were") synced from a computer. \(count == 1 ? "It stays" : "They stay") in To Delete."
        }
        if !result.missing.isEmpty {
            // Already gone from the library; a reload drops them from view.
            await reloadLibrary()
        }
    }

    // MARK: Albums

    var albums: [Album] { albumCollection.albums }

    /// Photos in the album that are currently visible in the library.
    func visiblePhotoIDs(in album: Album) -> [String] {
        album.photoIDs.filter { session.contains($0) }
    }

    @discardableResult
    func createAlbum(named name: String) throws -> Album {
        let album = try albumCollection.create(named: name)
        persist()
        return album
    }

    func renameAlbum(_ albumID: UUID, to name: String) throws {
        try albumCollection.rename(albumID, to: name)
        persist()
    }

    func deleteAlbum(_ albumID: UUID) {
        albumCollection.delete(albumID)
        persist()
    }

    func removePhoto(_ photoID: String, fromAlbum albumID: UUID) {
        albumCollection.remove(photoID, from: albumID)
        persist()
    }

    // MARK: Persistence

    /// Writes any queued saves, e.g. before the app is suspended.
    func flushPersistence() {
        persistence.flush()
    }

    private func loadPersistedState(isRetry: Bool) {
        // Don't replace changes made in memory while saving was disabled.
        if isRetry && hasUnsavedChanges {
            needsLoadRetry = false
            alertMessage = PersistenceError.unreadable.localizedDescription
            return
        }
        do {
            let state = try persistence.load()
            session = ReviewSession(libraryIDs: session.libraryIDs,
                                    decisions: state.decisions,
                                    deleteMarkedAt: state.deleteMarkedAt)
            albumCollection = AlbumCollection(albums: state.albums)
            isSavingEnabled = true
            needsLoadRetry = false
        } catch {
            let persistenceError = error as? PersistenceError
            isSavingEnabled = !(persistenceError?.blocksSaving ?? true)
            if persistenceError == .unreadable && !isRetry {
                // Likely a prewarmed launch while the device was locked. Retry
                // once the app is in use before telling the user.
                needsLoadRetry = true
            } else {
                needsLoadRetry = false
                alertMessage = error.localizedDescription
            }
        }
    }

    private func persist() {
        guard isSavingEnabled else {
            hasUnsavedChanges = true
            return
        }
        let state = PersistedState(decisions: session.decisions,
                                   deleteMarkedAt: session.deleteMarkedAt,
                                   albums: albumCollection.albums)
        do {
            try persistence.save(state)
        } catch {
            alertMessage = "Couldn't save your progress. \(error.localizedDescription)"
        }
    }
}
