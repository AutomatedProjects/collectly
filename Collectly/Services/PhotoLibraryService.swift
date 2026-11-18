import Photos
import UIKit

enum PhotoLibraryAuthorization: Equatable, Sendable {
    case notDetermined
    case authorized
    case limited
    case denied
    case restricted

    init(_ status: PHAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .authorized: self = .authorized
        case .limited: self = .limited
        case .denied: self = .denied
        case .restricted: self = .restricted
        @unknown default: self = .denied
        }
    }

    var canReadLibrary: Bool { self == .authorized || self == .limited }
}

enum PhotoLibraryError: LocalizedError, Equatable {
    /// The user dismissed the system "Allow Collectly to delete?" prompt.
    case userCancelled
    case notAuthorized

    var errorDescription: String? {
        switch self {
        case .userCancelled: "Deletion was cancelled."
        case .notAuthorized: "Collectly doesn't have permission to change your photo library."
        }
    }
}

/// Outcome of a deletion request. Photos can be skipped because PhotoKit
/// won't delete them (for example, photos synced from a computer) or because
/// they are no longer in the library.
struct PhotoDeletionResult: Equatable, Sendable {
    var deleted: [String] = []
    var notDeletable: [String] = []
    var missing: [String] = []
}

/// Everything the app needs from the photo library. The real implementation
/// wraps PhotoKit; `MockPhotoLibraryService` backs previews, tests, and demo mode.
@MainActor
protocol PhotoLibraryService: AnyObject {
    func authorizationStatus() -> PhotoLibraryAuthorization
    func requestAuthorization() async -> PhotoLibraryAuthorization
    /// Identifiers of all visible still photos, newest first.
    func fetchPhotoIdentifiers() async -> [String]
    /// `targetSize` is in pixels. Cancelling the calling task cancels the
    /// underlying request, including any iCloud download.
    func image(for photoID: String, targetSize: CGSize) async -> UIImage?
    func creationDate(for photoID: String) async -> Date?
    /// Moves the deletable photos among `photoIDs` to the Photos app's
    /// Recently Deleted album. iOS shows its own confirmation prompt; throws
    /// `PhotoLibraryError.userCancelled` if the user declines it.
    func deletePhotos(withIdentifiers photoIDs: [String]) async throws -> PhotoDeletionResult
    /// Called on the main actor when the photo library changes, for example
    /// after edits in the Photos app or a change to the limited selection.
    var onLibraryChange: (@MainActor () -> Void)? { get set }
}
