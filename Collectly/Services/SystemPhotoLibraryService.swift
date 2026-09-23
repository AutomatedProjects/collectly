import Photos
import UIKit

/// PhotoKit-backed implementation of `PhotoLibraryService`.
@MainActor
final class SystemPhotoLibraryService: PhotoLibraryService {
    private let imageManager = PHCachingImageManager()

    func authorizationStatus() -> PhotoLibraryAuthorization {
        PhotoLibraryAuthorization(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAuthorization() async -> PhotoLibraryAuthorization {
        PhotoLibraryAuthorization(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    func fetchPhotoIdentifiers() async -> [String] {
        await Task.detached(priority: .userInitiated) {
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
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [photoID], options: nil).firstObject else {
            return nil
        }
        let options = PHImageRequestOptions()
        // High quality delivers exactly one callback, which keeps the
        // continuation below single-resume.
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            imageManager.requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFit, options: options) { @Sendable image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    func creationDate(for photoID: String) -> Date? {
        PHAsset.fetchAssets(withLocalIdentifiers: [photoID], options: nil).firstObject?.creationDate
    }

    func deletePhotos(withIdentifiers photoIDs: [String]) async throws {
        guard authorizationStatus().canReadLibrary else { throw PhotoLibraryError.notAuthorized }
        do {
            try await PHPhotoLibrary.shared().performChanges { @Sendable in
                let assets = PHAsset.fetchAssets(withLocalIdentifiers: photoIDs, options: nil)
                PHAssetChangeRequest.deleteAssets(assets)
            }
        } catch let error as PHPhotosError where error.code == .userCancelled {
            throw PhotoLibraryError.userCancelled
        }
    }
}
