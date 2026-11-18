import Photos
import UIKit

/// PhotoKit-backed implementation of `PhotoLibraryService`.
///
/// Fetches run in detached tasks so they stay off the main thread. Image
/// requests allow network access so photos stored only in iCloud Photos can be
/// shown; iOS downloads them. Collectly itself never contacts a server.
@MainActor
final class SystemPhotoLibraryService: PhotoLibraryService {
    var onLibraryChange: (@MainActor () -> Void)?
    private var changeObserver: LibraryChangeObserver?

    func authorizationStatus() -> PhotoLibraryAuthorization {
        PhotoLibraryAuthorization(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAuthorization() async -> PhotoLibraryAuthorization {
        PhotoLibraryAuthorization(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    func fetchPhotoIdentifiers() async -> [String] {
        startObservingChangesIfNeeded()
        return await Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let result = PHAsset.fetchAssets(with: .image, options: options)
            var ids: [String] = []
            ids.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in
                ids.append(asset.localIdentifier)
            }
            return ids
        }.value
    }

    func image(for photoID: String, targetSize: CGSize) async -> UIImage? {
        let request = PhotoImageRequest { PHImageManager.default().cancelImageRequest($0) }
        return await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                guard !request.isCancelled,
                      let asset = PHAsset.fetchAssets(withLocalIdentifiers: [photoID], options: nil).firstObject else {
                    return nil
                }
                let options = PHImageRequestOptions()
                // High quality delivers exactly one callback; `PhotoImageRequest`
                // also guards against a second resume.
                options.deliveryMode = .highQualityFormat
                options.resizeMode = .fast
                options.isNetworkAccessAllowed = true
                return await withCheckedContinuation { continuation in
                    request.start(continuation) {
                        PHImageManager.default().requestImage(for: asset, targetSize: targetSize,
                                                              contentMode: .aspectFit, options: options) { @Sendable image, _ in
                            request.finish(image)
                        }
                    }
                }
            }.value
        } onCancel: {
            request.cancel()
        }
    }

    func creationDate(for photoID: String) async -> Date? {
        await Task.detached(priority: .utility) {
            PHAsset.fetchAssets(withLocalIdentifiers: [photoID], options: nil).firstObject?.creationDate
        }.value
    }

    func deletePhotos(withIdentifiers photoIDs: [String]) async throws -> PhotoDeletionResult {
        guard authorizationStatus().canReadLibrary else { throw PhotoLibraryError.notAuthorized }
        var result = await Task.detached(priority: .userInitiated) {
            var canDelete: [String: Bool] = [:]
            PHAsset.fetchAssets(withLocalIdentifiers: photoIDs, options: nil).enumerateObjects { asset, _, _ in
                canDelete[asset.localIdentifier] = asset.canPerform(.delete)
            }
            var plan = PhotoDeletionResult()
            for id in photoIDs {
                switch canDelete[id] {
                case true?: plan.deleted.append(id)
                case false?: plan.notDeletable.append(id)
                case nil: plan.missing.append(id)
                }
            }
            return plan
        }.value

        let deletable = result.deleted
        guard !deletable.isEmpty else { return result }
        do {
            try await PHPhotoLibrary.shared().performChanges { @Sendable in
                let assets = PHAsset.fetchAssets(withLocalIdentifiers: deletable, options: nil)
                PHAssetChangeRequest.deleteAssets(assets)
            }
        } catch let error as PHPhotosError where error.code == .userCancelled {
            throw PhotoLibraryError.userCancelled
        } catch {
            result.deleted = []
            throw error
        }
        return result
    }

    /// Registers for library changes once access is granted. Registering
    /// earlier is pointless because nothing is visible yet.
    private func startObservingChangesIfNeeded() {
        guard changeObserver == nil, authorizationStatus().canReadLibrary else { return }
        let observer = LibraryChangeObserver { [weak self] in
            Task { @MainActor in self?.onLibraryChange?() }
        }
        PHPhotoLibrary.shared().register(observer)
        changeObserver = observer
    }
}

/// Forwards PhotoKit change notifications, which arrive on a background queue.
private final class LibraryChangeObserver: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    private let handler: @Sendable () -> Void

    init(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        handler()
    }
}

/// Bridges one PhotoKit image request to a continuation, making sure it is
/// resumed exactly once and that task cancellation cancels the request even
/// if it races with the request starting or finishing.
final class PhotoImageRequest: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelRequest: @Sendable (PHImageRequestID) -> Void
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var requestID: PHImageRequestID?
    private var cancelled = false

    init(cancelRequest: @escaping @Sendable (PHImageRequestID) -> Void) {
        self.cancelRequest = cancelRequest
    }

    var isCancelled: Bool { lock.withLock { cancelled } }

    /// Stores the continuation and starts the request with `begin`, unless
    /// the request was already cancelled.
    func start(_ continuation: CheckedContinuation<UIImage?, Never>, begin: () -> PHImageRequestID) {
        let alreadyCancelled = lock.withLock {
            if !cancelled { self.continuation = continuation }
            return cancelled
        }
        guard !alreadyCancelled else {
            continuation.resume(returning: nil)
            return
        }
        let id = begin()
        let cancelNow = lock.withLock {
            requestID = id
            return cancelled
        }
        if cancelNow { cancelRequest(id) }
    }

    func finish(_ image: UIImage?) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: image)
    }

    func cancel() {
        let (id, continuation) = lock.withLock {
            cancelled = true
            defer { self.continuation = nil }
            return (requestID, self.continuation)
        }
        if let id { cancelRequest(id) }
        continuation?.resume(returning: nil)
    }
}
