import Foundation
import Testing
@testable import Collectly

@MainActor
struct AppModelTests {
    private func makeModel(library: MockPhotoLibraryService = MockPhotoLibraryService(photoCount: 5),
                           store: InMemoryPersistenceStore = InMemoryPersistenceStore()) async -> AppModel {
        let model = AppModel(library: library, persistence: store)
        await model.reloadLibrary()
        return model
    }

    @Test func requestingAccessLoadsLibrary() async {
        let library = MockPhotoLibraryService(status: .notDetermined, statusAfterRequest: .limited, photoCount: 3)
        let model = AppModel(library: library, persistence: InMemoryPersistenceStore())
        #expect(model.authorization == .notDetermined)
        await model.reloadLibrary()
        #expect(model.loadState == .idle)

        await model.requestAccess()
        #expect(library.authorizationRequestCount == 1)
        #expect(model.authorization == .limited)
        #expect(model.loadState == .loaded)
        #expect(model.session.progress.total == 3)
    }

    @Test func deniedAccessDoesNotLoad() async {
        let library = MockPhotoLibraryService(status: .notDetermined, statusAfterRequest: .denied)
        let model = AppModel(library: library, persistence: InMemoryPersistenceStore())
        await model.requestAccess()
        #expect(model.authorization == .denied)
        #expect(model.loadState == .idle)
        #expect(model.session.progress.total == 0)
    }

    @Test func decisionsPersistAcrossLaunches() async {
        let library = MockPhotoLibraryService(photoCount: 5)
        let store = InMemoryPersistenceStore()
        let model = await makeModel(library: library, store: store)
        model.keepCurrent()
        model.deleteCurrent()
        #expect(store.saveCount == 2)

        let relaunched = await makeModel(library: library, store: store)
        #expect(relaunched.session.progress == ReviewProgress(total: 5, kept: 1, markedForDeletion: 1))
        #expect(relaunched.session.current == "mock-photo-3")
    }

    @Test func undoRevertsAndPersists() async {
        let store = InMemoryPersistenceStore()
        let model = await makeModel(store: store)
        model.deleteCurrent()
        model.undo()
        #expect(model.session.current == "mock-photo-1")
        #expect(store.state.decisions.isEmpty)
    }

    @Test func keepInAlbumKeepsAndFiles() async throws {
        let model = await makeModel()
        let album = try model.createAlbum(named: "Favorites")
        model.keepCurrent(inAlbum: album.id)

        #expect(model.session.decisions["mock-photo-1"] == .keep)
        #expect(model.albumCollection.album(id: album.id)?.photoIDs == ["mock-photo-1"])
        #expect(model.session.current == "mock-photo-2")
    }

    @Test func keepInMissingAlbumShowsErrorAndDoesNotAdvance() async {
        let model = await makeModel()
        model.keepCurrent(inAlbum: UUID())
        #expect(model.alertMessage != nil)
        #expect(model.session.current == "mock-photo-1")
    }

    @Test func undoOfKeepInAlbumAlsoRemovesAlbumFiling() async throws {
        let model = await makeModel()
        let album = try model.createAlbum(named: "Favorites")
        model.keepCurrent(inAlbum: album.id)
        model.undo()

        #expect(model.session.current == "mock-photo-1")
        #expect(model.albumCollection.album(id: album.id)?.photoIDs == [])
    }

    @Test func confirmedDeletionRemovesPhotosFromLibraryAndAlbums() async throws {
        let library = MockPhotoLibraryService(photoCount: 3)
        let model = await makeModel(library: library)
        let album = try model.createAlbum(named: "Mixed")
        model.keepCurrent(inAlbum: album.id) // photo 1 filed
        model.deleteCurrent()                // photo 2
        model.resetKeptDecisions()           // photo 1 back in the queue
        model.deleteCurrent()                // photo 1, still in the album

        #expect(model.session.markedForDeletion == ["mock-photo-1", "mock-photo-2"])
        await model.confirmDeletion()

        #expect(library.deletedIDs == ["mock-photo-1", "mock-photo-2"])
        #expect(model.session.markedForDeletion.isEmpty)
        #expect(model.session.progress.total == 1)
        #expect(model.albumCollection.album(id: album.id)?.photoIDs == [])
        #expect(model.alertMessage == nil)
    }

    @Test func cancelledSystemPromptKeepsPhotosMarkedWithoutError() async {
        let library = MockPhotoLibraryService(photoCount: 2)
        library.deleteError = PhotoLibraryError.userCancelled
        let model = await makeModel(library: library)
        model.deleteCurrent()

        await model.confirmDeletion()
        #expect(model.session.markedForDeletion == ["mock-photo-1"])
        #expect(model.alertMessage == nil)
        #expect(!model.isDeleting)
    }

    @Test func failedDeletionKeepsPhotosMarkedAndReportsError() async {
        struct Boom: Error {}
        let library = MockPhotoLibraryService(photoCount: 2)
        library.deleteError = Boom()
        let model = await makeModel(library: library)
        model.deleteCurrent()

        await model.confirmDeletion()
        #expect(model.session.markedForDeletion == ["mock-photo-1"])
        #expect(model.alertMessage != nil)
    }

    @Test func refreshPicksUpNewPhotosAndRevokedAccess() async {
        let library = MockPhotoLibraryService(photoCount: 2)
        let model = await makeModel(library: library)
        library.photoIDs.insert("fresh", at: 0)
        await model.refresh()
        #expect(model.session.current == "fresh")

        library.status = .denied
        await model.refresh()
        #expect(model.authorization == .denied)
    }

    @Test func corruptedPersistenceStartsFreshWithMessage() {
        final class FailingStore: PersistenceStore {
            func load() throws -> PersistedState { throw PersistenceError.corruptedData(backupURL: nil) }
            func save(_ state: PersistedState) throws {}
        }
        let model = AppModel(library: MockPhotoLibraryService(), persistence: FailingStore())
        #expect(model.alertMessage != nil)
        #expect(model.session.decisions.isEmpty)
    }

    @Test func demoModeUsesMockLibrary() {
        let model = AppModel.makeDefault(arguments: ["Collectly", "-CollectlyDemoMode"])
        #expect(model.library is MockPhotoLibraryService)
    }
}
