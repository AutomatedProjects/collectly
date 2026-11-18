import UIKit

/// In-memory photo library with generated placeholder images. Used by SwiftUI
/// previews, unit tests, and the `-CollectlyDemoMode` launch argument.
@MainActor
final class MockPhotoLibraryService: PhotoLibraryService {
    var status: PhotoLibraryAuthorization
    var statusAfterRequest: PhotoLibraryAuthorization
    var photoIDs: [String]
    var deleteError: Error?
    /// Photos that `deletePhotos` reports as not deletable.
    var undeletableIDs: Set<String> = []
    /// When set, the next fetch snapshots `photoIDs` and then waits until
    /// `resumeSuspendedFetch()` is called. Used to test overlapping reloads.
    var suspendNextFetch = false
    var onLibraryChange: (@MainActor () -> Void)?
    private(set) var deletedIDs: [String] = []
    private(set) var authorizationRequestCount = 0
    private var suspendedFetch: CheckedContinuation<Void, Never>?

    init(status: PhotoLibraryAuthorization = .authorized,
         statusAfterRequest: PhotoLibraryAuthorization = .authorized,
         photoCount: Int = 24) {
        self.status = status
        self.statusAfterRequest = statusAfterRequest
        self.photoIDs = photoCount > 0 ? (1...photoCount).map { "mock-photo-\($0)" } : []
    }

    var hasSuspendedFetch: Bool { suspendedFetch != nil }

    func resumeSuspendedFetch() {
        suspendedFetch?.resume()
        suspendedFetch = nil
    }

    /// Simulates a PhotoKit change notification.
    func simulateLibraryChange() {
        onLibraryChange?()
    }

    func authorizationStatus() -> PhotoLibraryAuthorization { status }

    func requestAuthorization() async -> PhotoLibraryAuthorization {
        authorizationRequestCount += 1
        if status == .notDetermined { status = statusAfterRequest }
        return status
    }

    func fetchPhotoIdentifiers() async -> [String] {
        let snapshot = status.canReadLibrary ? photoIDs : []
        if suspendNextFetch {
            suspendNextFetch = false
            await withCheckedContinuation { suspendedFetch = $0 }
        }
        return snapshot
    }

    func image(for photoID: String, targetSize: CGSize) async -> UIImage? {
        guard photoIDs.contains(photoID) else { return nil }
        let size = CGSize(width: 600, height: 800)
        let seed = photoID.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) }
        let hue = CGFloat(abs(seed % 360)) / 360
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let label = photoID.replacingOccurrences(of: "mock-photo-", with: "#") as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 96, weight: .bold),
                .foregroundColor: UIColor.white,
            ]
            let textSize = label.size(withAttributes: attributes)
            label.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2),
                       withAttributes: attributes)
        }
    }

    func creationDate(for photoID: String) async -> Date? {
        guard let index = photoIDs.firstIndex(of: photoID) else { return nil }
        return Date(timeIntervalSince1970: 1_750_000_000 - Double(index) * 86_400)
    }

    func deletePhotos(withIdentifiers ids: [String]) async throws -> PhotoDeletionResult {
        if let deleteError { throw deleteError }
        var result = PhotoDeletionResult()
        for id in ids {
            if !photoIDs.contains(id) {
                result.missing.append(id)
            } else if undeletableIDs.contains(id) {
                result.notDeletable.append(id)
            } else {
                result.deleted.append(id)
            }
        }
        let removed = Set(result.deleted)
        photoIDs.removeAll { removed.contains($0) }
        deletedIDs.append(contentsOf: result.deleted)
        return result
    }
}
