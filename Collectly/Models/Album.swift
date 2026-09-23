import Foundation

/// A Collectly album. Albums are stored locally by Collectly and reference
/// photos by their `PHAsset.localIdentifier`; they are not Photos-app albums.
struct Album: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var photoIDs: [String]
    let createdAt: Date

    init(id: UUID = UUID(), name: String, photoIDs: [String] = [], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.photoIDs = photoIDs
        self.createdAt = createdAt
    }
}
