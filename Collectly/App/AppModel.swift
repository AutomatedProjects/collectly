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
    /// User-facing error message; the root view shows it as an alert.
    var alertMessage: String?

    @ObservationIgnored let library: PhotoLibraryService
    @ObservationIgnored private let persistence: PersistenceStore
    /// Album filings made by "keep in album", so undo can reverse them too.
    @ObservationIgnored private var albumFilings: [String: UUID] = [:]

    init(library: PhotoLibraryService, persistence: PersistenceStore) {
        self.library = library
        self.persistence = persistence
        self.authorization = library.authorizationStatus()

        let state: PersistedState
        do {
            state = try persistence.load()
        } catch {
            state = PersistedState()
            alertMessage = error.localizedDescription
        }
        session = ReviewSession(decisions: state.decisions)
        albumCollection = AlbumCollection(albums: state.albums)
    }

    static func makeDefault(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppModel {
        if arguments.contains("-CollectlyDemoMode") {
            return AppModel(library: MockPhotoLibraryService(photoCount: 30), persistence: InMemoryPersistenceStore())
        }
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

    func reloadLibrary() async {
        guard authorization.canReadLibrary else { return }
        if loadState != .loaded { loadState = .loading }
        let ids = await library.fetchPhotoIdentifiers()
        session.reconcile(with: ids)
        loadState = .loaded
    }

    // MARK: Review

    func keepCurrent() { decide(.keep) }

    func deleteCurrent() { decide(.delete) }

    func decide(_ decision: ReviewDecision) {
        guard let photoID = session.decide(decision) else { return }
        albumFilings[photoID] = nil
        persist()
    }

    /// Keeps the current photo and files it into an album in one step.
    func keepCurrent(inAlbum albumID: UUID) {
        guard let photoID = session.current else { return }
        do {
            if try albumCollection.add(photoID, to: albumID) {
                albumFilings[photoID] = albumID
            }
        } catch {
            alertMessage = error.localizedDescription
            return
        }
        session.decide(.keep)
        persist()
    }

    func undo() {
        guard let entry = session.undo() else { return }
        if let albumID = albumFilings.removeValue(forKey: entry.photoID) {
            albumCollection.remove(entry.photoID, from: albumID)
        }
        persist()
    }

    func resetKeptDecisions() {
        session.resetKept()
        persist()
    }

    // MARK: Deletion

    func restore(_ photoID: String) {
        session.restore(photoID)
        persist()
    }

    func restoreAll() {
        session.restoreAll()
        persist()
    }

    /// Deletes every photo marked for deletion. Call only after the user
    /// confirmed in the app; iOS then shows its own confirmation too.
    func confirmDeletion() async {
        let ids = session.markedForDeletion
        guard !ids.isEmpty, !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await library.deletePhotos(withIdentifiers: ids)
            session.removeDeleted(ids)
            albumCollection.removePhotosEverywhere(Set(ids))
            persist()
        } catch PhotoLibraryError.userCancelled {
            // The user backed out of the system prompt; keep everything marked.
        } catch {
            alertMessage = "Couldn't delete photos. \(error.localizedDescription)"
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

    private func persist() {
        let state = PersistedState(decisions: session.decisions, albums: albumCollection.albums)
        do {
            try persistence.save(state)
        } catch {
            alertMessage = "Couldn't save your progress. \(error.localizedDescription)"
        }
    }
}
