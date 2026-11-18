import Foundation
import Testing
@testable import Collectly

/// Store whose `load()` results are scripted, for load-failure tests.
@MainActor
private final class ScriptedStore: PersistenceStore {
    var loadResults: [Result<PersistedState, PersistenceError>]
    var saved: [PersistedState] = []
    var saveFailureHandler: (@MainActor (Error) -> Void)?

    init(_ loadResults: [Result<PersistedState, PersistenceError>]) {
        self.loadResults = loadResults
    }

    func load() throws -> PersistedState {
        try (loadResults.count > 1 ? loadResults.removeFirst() : loadResults[0]).get()
    }

    func save(_ state: PersistedState) throws { saved.append(state) }

    func flush() {}
}

@MainActor
struct AppModelTests {
    private func makeModel(library: MockPhotoLibraryService = MockPhotoLibraryService(photoCount: 5),
                           store: PersistenceStore = InMemoryPersistenceStore()) async -> AppModel {
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
        #expect(store.state.deleteMarkedAt.keys.sorted() == ["mock-photo-2"])

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
        #expect(store.state.deleteMarkedAt.isEmpty)
    }

    // MARK: Swipe commits (M1)

    @Test func decisionForAPhotoNoLongerOnScreenIsIgnored() async {
        let model = await makeModel()
        model.decide(.keep, for: "mock-photo-1")
        // A second, late decision for photo 1 must not land on photo 2.
        model.decide(.delete, for: "mock-photo-1")
        #expect(model.session.current == "mock-photo-2")
        #expect(model.session.decisions == ["mock-photo-1": .keep])
    }

    @Test func swipeCommitBlocksOtherDecisionsAndUndo() async throws {
        let model = await makeModel()
        let album = try model.createAlbum(named: "Favorites")
        model.keepCurrent() // photo 1, so there is something to undo
        #expect(!model.beginSwipe(on: "mock-photo-3"))
        #expect(model.beginSwipe(on: "mock-photo-2"))
        #expect(model.isCommittingSwipe)
        #expect(!model.beginSwipe(on: "mock-photo-2"))

        // Buttons, undo, and album filing tapped mid-animation do nothing.
        model.keepCurrent()
        model.decide(.delete, for: "mock-photo-2")
        model.keep("mock-photo-2", inAlbum: album.id)
        model.undo()
        #expect(model.session.current == "mock-photo-2")
        #expect(model.session.decisions == ["mock-photo-1": .keep])

        model.finishSwipe(.delete, on: "mock-photo-2")
        #expect(!model.isCommittingSwipe)
        #expect(model.session.decisions["mock-photo-2"] == .delete)
        #expect(model.session.current == "mock-photo-3")
        #expect(model.albumCollection.album(id: album.id)?.photoIDs == [])
    }

    @Test func swipeFinishingAfterThePhotoVanishedDoesNotHitTheNextPhoto() async {
        let library = MockPhotoLibraryService(photoCount: 3)
        let model = await makeModel(library: library)
        #expect(model.beginSwipe(on: "mock-photo-1"))
        library.photoIDs.removeFirst()
        await model.refresh()
        #expect(model.session.current == "mock-photo-2")

        model.finishSwipe(.delete, on: "mock-photo-1")
        #expect(!model.isCommittingSwipe)
        #expect(model.session.decisions.isEmpty)
        #expect(model.session.current == "mock-photo-2")
    }

    // MARK: Albums (L2) and filing undo

    @Test func keepInAlbumKeepsAndFiles() async throws {
        let model = await makeModel()
        let album = try model.createAlbum(named: "Favorites")
        model.keep("mock-photo-1", inAlbum: album.id)

        #expect(model.session.decisions["mock-photo-1"] == .keep)
        #expect(model.albumCollection.album(id: album.id)?.photoIDs == ["mock-photo-1"])
        #expect(model.session.current == "mock-photo-2")
    }

    @Test func keepInMissingAlbumShowsErrorAndDoesNotAdvance() async {
        let model = await makeModel()
        model.keep("mock-photo-1", inAlbum: UUID())
        #expect(model.alertMessage != nil)
        #expect(model.session.current == "mock-photo-1")
    }

    @Test func albumFilingIsBoundToThePhotoThePickerWasOpenedFor() async throws {
        let model = await makeModel()
        let album = try model.createAlbum(named: "Favorites")
        // The picker opens for photo 1, then photo 1 is decided another way.
        model.keepCurrent()
        model.keep("mock-photo-1", inAlbum: album.id)

        #expect(model.albumCollection.album(id: album.id)?.photoIDs == [])
        #expect(model.session.current == "mock-photo-2")
        #expect(model.session.decisions["mock-photo-2"] == nil)
        #expect(model.alertMessage != nil)
    }

    @Test func undoOfKeepInAlbumAlsoRemovesAlbumFiling() async throws {
        let model = await makeModel()
        let album = try model.createAlbum(named: "Favorites")
        model.keep("mock-photo-1", inAlbum: album.id)
        model.undo()

        #expect(model.session.current == "mock-photo-1")
        #expect(model.albumCollection.album(id: album.id)?.photoIDs == [])
    }

    @Test func undoAfterResetDoesNotRemoveAnEarlierFiling() async throws {
        let model = await makeModel()
        let album = try model.createAlbum(named: "Favorites")
        model.keep("mock-photo-1", inAlbum: album.id)
        for _ in 1..<5 { model.keepCurrent() }
        model.resetKeptDecisions()
        #expect(model.session.current == "mock-photo-1")

        // Photo 1 is already in the album, so this filing adds nothing and
        // undoing it must leave the earlier filing alone.
        model.keep("mock-photo-1", inAlbum: album.id)
        model.undo()
        #expect(model.session.current == "mock-photo-1")
        #expect(model.albumCollection.album(id: album.id)?.photoIDs == ["mock-photo-1"])
    }

    @Test func undoAfterRestoreDoesNotTouchAlbums() async throws {
        let model = await makeModel()
        let album = try model.createAlbum(named: "Favorites")
        model.keep("mock-photo-1", inAlbum: album.id)
        model.deleteCurrent()              // photo 2
        model.restore("mock-photo-2")      // its delete entry is now stale
        model.undo()                       // skips photo 2, undoes photo 1's filing
        #expect(model.session.current == "mock-photo-1")
        #expect(model.session.decisions["mock-photo-2"] == .keep)
        #expect(model.albumCollection.album(id: album.id)?.photoIDs == [])
    }

    // MARK: Deletion (L1, L8)

    @Test func confirmedDeletionRemovesPhotosFromLibraryAndAlbums() async throws {
        let library = MockPhotoLibraryService(photoCount: 3)
        let model = await makeModel(library: library)
        let album = try model.createAlbum(named: "Mixed")
        model.keep("mock-photo-1", inAlbum: album.id) // photo 1 filed
        model.deleteCurrent()                         // photo 2
        model.resetKeptDecisions()                    // photo 1 back in the queue
        model.deleteCurrent()                         // photo 1, still in the album

        #expect(model.session.markedForDeletion == ["mock-photo-1", "mock-photo-2"])
        await model.confirmDeletion(of: model.session.markedForDeletion)

        #expect(library.deletedIDs == ["mock-photo-1", "mock-photo-2"])
        #expect(model.session.markedForDeletion.isEmpty)
        #expect(model.session.progress.total == 1)
        #expect(model.albumCollection.album(id: album.id)?.photoIDs == [])
        #expect(model.alertMessage == nil)
    }

    @Test func deletionOnlyDeletesConfirmedPhotosThatAreStillMarked() async {
        let library = MockPhotoLibraryService(photoCount: 5)
        let model = await makeModel(library: library)
        model.deleteCurrent() // 1
        model.deleteCurrent() // 2
        let confirmed = model.session.markedForDeletion // dialog opens with 1, 2

        model.restore("mock-photo-2") // changed mind while the dialog was open
        model.deleteCurrent()         // 3, marked after the dialog opened
        await model.confirmDeletion(of: confirmed + ["mock-photo-5"])

        #expect(library.deletedIDs == ["mock-photo-1"])
        #expect(model.session.markedForDeletion == ["mock-photo-3"])
        #expect(model.session.decisions["mock-photo-2"] == .keep)
    }

    @Test func confirmingNothingStillMarkedDoesNotCallPhotoKit() async {
        let library = MockPhotoLibraryService(photoCount: 2)
        library.deleteError = PhotoLibraryError.notAuthorized // would surface if called
        let model = await makeModel(library: library)
        await model.confirmDeletion(of: ["mock-photo-1"])
        #expect(model.alertMessage == nil)
    }

    @Test func undeletablePhotosStayMarkedAndAreReported() async {
        let library = MockPhotoLibraryService(photoCount: 3)
        library.undeletableIDs = ["mock-photo-2"]
        let model = await makeModel(library: library)
        model.deleteCurrent()
        model.deleteCurrent()

        await model.confirmDeletion(of: model.session.markedForDeletion)
        #expect(library.deletedIDs == ["mock-photo-1"])
        #expect(model.session.markedForDeletion == ["mock-photo-2"])
        #expect(model.alertMessage?.contains("Deleted 1 photo.") == true)
        #expect(model.alertMessage?.contains("1 photo can't be deleted") == true)
    }

    @Test func photosAlreadyGoneAreDroppedByReloadWithoutError() async {
        let library = MockPhotoLibraryService(status: .limited, photoCount: 3)
        let model = await makeModel(library: library)
        model.deleteCurrent()
        library.photoIDs.removeAll { $0 == "mock-photo-1" } // deleted in Photos meanwhile

        await model.confirmDeletion(of: ["mock-photo-1"])
        #expect(library.deletedIDs.isEmpty)
        #expect(model.session.markedForDeletion.isEmpty)
        #expect(model.alertMessage == nil)
    }

    @Test func cancelledSystemPromptKeepsPhotosMarkedWithoutError() async {
        let library = MockPhotoLibraryService(photoCount: 2)
        library.deleteError = PhotoLibraryError.userCancelled
        let model = await makeModel(library: library)
        model.deleteCurrent()

        await model.confirmDeletion(of: model.session.markedForDeletion)
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

        await model.confirmDeletion(of: model.session.markedForDeletion)
        #expect(model.session.markedForDeletion == ["mock-photo-1"])
        #expect(model.alertMessage != nil)
    }

    // MARK: Keep All (L7)

    @Test func keepAllOnlyKeepsThePhotosShownInTheDialog() async {
        let model = await makeModel()
        model.deleteCurrent() // 1
        let confirmed = model.session.markedForDeletion
        model.deleteCurrent() // 2, marked after the dialog opened
        model.restoreAll(confirmed)
        #expect(model.session.decisions["mock-photo-1"] == .keep)
        #expect(model.session.markedForDeletion == ["mock-photo-2"])
    }

    // MARK: Reloads and library changes (L3, L4)

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

    @Test func staleOverlappingReloadDoesNotWin() async {
        let library = MockPhotoLibraryService(photoCount: 0)
        let model = AppModel(library: library, persistence: InMemoryPersistenceStore())
        library.photoIDs = ["old"]
        library.suspendNextFetch = true
        let slowReload = Task { await model.reloadLibrary() }
        while !library.hasSuspendedFetch { await Task.yield() }

        library.photoIDs = ["new"]
        await model.reloadLibrary()
        library.resumeSuspendedFetch()
        await slowReload.value

        #expect(model.session.libraryIDs == ["new"])
    }

    @Test func accessRevokedDuringFetchIsNotOverwritten() async {
        let library = MockPhotoLibraryService(photoCount: 2)
        let model = AppModel(library: library, persistence: InMemoryPersistenceStore())
        library.suspendNextFetch = true
        let reload = Task { await model.reloadLibrary() }
        while !library.hasSuspendedFetch { await Task.yield() }
        library.status = .denied
        library.resumeSuspendedFetch()
        await reload.value

        #expect(model.authorization == .denied)
        #expect(model.session.libraryIDs.isEmpty)
    }

    @Test func libraryChangeNotificationReloads() async {
        let library = MockPhotoLibraryService(photoCount: 2)
        let model = await makeModel(library: library)
        model.libraryChangeDelay = .zero
        library.photoIDs.insert("fresh", at: 0)
        library.simulateLibraryChange()
        await model.libraryChangeTask?.value
        #expect(model.session.current == "fresh")
    }

    @Test func fullAccessDropsDeleteMarksForPhotosThatAreGone() async {
        let library = MockPhotoLibraryService(photoCount: 3)
        let store = InMemoryPersistenceStore()
        let model = await makeModel(library: library, store: store)
        model.deleteCurrent() // 1
        model.keepCurrent()   // 2
        library.photoIDs.removeAll { $0 != "mock-photo-3" } // removed outside Collectly

        await model.refresh()
        #expect(model.session.decisions == ["mock-photo-2": .keep])
        #expect(store.state.decisions == ["mock-photo-2": .keep])
    }

    @Test func limitedAccessKeepsRecentHiddenDeleteMarks() async {
        let library = MockPhotoLibraryService(status: .limited, photoCount: 3)
        let model = await makeModel(library: library)
        model.deleteCurrent() // 1
        library.photoIDs.removeFirst() // deselected in the limited picker

        await model.refresh()
        #expect(model.session.decisions["mock-photo-1"] == .delete)
        #expect(model.session.markedForDeletion.isEmpty)
    }

    // MARK: Persistence failures (M2)

    @Test func corruptedPersistenceStartsFreshWithMessageAndKeepsSaving() async {
        let store = ScriptedStore([.failure(.corruptedData(backupURL: URL(filePath: "/tmp/backup.json")))])
        let model = await makeModel(store: store)
        #expect(model.alertMessage != nil)
        #expect(model.session.decisions.isEmpty)
        model.keepCurrent()
        #expect(store.saved.count == 1)
    }

    @Test(arguments: [PersistenceError.backupFailed, .unsupportedVersion(99)])
    func blockingLoadFailureNeverSaves(error: PersistenceError) async {
        let store = ScriptedStore([.failure(error)])
        let model = await makeModel(store: store)
        #expect(model.alertMessage == error.localizedDescription)
        #expect(!model.isSavingEnabled)

        model.keepCurrent()
        _ = try? model.createAlbum(named: "New")
        #expect(store.saved.isEmpty)
    }

    @Test func unreadableFileIsRetriedBeforeTellingTheUser() async {
        let saved = PersistedState(decisions: ["mock-photo-1": .keep])
        let store = ScriptedStore([.failure(.unreadable), .success(saved)])
        let model = AppModel(library: MockPhotoLibraryService(photoCount: 3), persistence: store)
        #expect(model.alertMessage == nil)
        #expect(!model.isSavingEnabled)

        await model.reloadLibrary() // e.g. the device was unlocked
        #expect(model.alertMessage == nil)
        #expect(model.isSavingEnabled)
        #expect(model.session.current == "mock-photo-2")
        model.keepCurrent()
        #expect(store.saved.last?.decisions.count == 2)
    }

    @Test func unreadableFileThatStaysUnreadableDisablesSaving() async {
        let store = ScriptedStore([.failure(.unreadable)])
        let model = await makeModel(store: store)
        #expect(model.alertMessage == PersistenceError.unreadable.localizedDescription)
        model.keepCurrent()
        #expect(store.saved.isEmpty)
    }

    @Test func backgroundSaveFailureIsShown() async {
        struct DiskFull: Error {}
        let store = InMemoryPersistenceStore()
        let model = await makeModel(store: store)
        store.saveFailureHandler?(DiskFull())
        #expect(model.alertMessage?.hasPrefix("Couldn't save your progress.") == true)
    }

    // MARK: Demo mode

    #if DEBUG
    @Test func demoModeUsesMockLibraryInDebugBuilds() {
        let model = AppModel.makeDefault(arguments: ["Collectly", "-CollectlyDemoMode"])
        #expect(model.library is MockPhotoLibraryService)
    }
    #endif
}
