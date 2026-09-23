import Foundation

enum AlbumError: LocalizedError, Equatable {
    case emptyName
    case nameTooLong(limit: Int)
    case duplicateName(String)
    case notFound

    var errorDescription: String? {
        switch self {
        case .emptyName: "Album names can't be empty."
        case .nameTooLong(let limit): "Album names can be at most \(limit) characters."
        case .duplicateName(let name): "An album named “\(name)” already exists."
        case .notFound: "That album no longer exists."
        }
    }
}

/// Pure, UI-independent album management with name validation.
struct AlbumCollection: Equatable, Sendable {
    static let maxNameLength = 60

    private(set) var albums: [Album]

    init(albums: [Album] = []) {
        self.albums = albums
    }

    func album(id: UUID) -> Album? {
        albums.first { $0.id == id }
    }

    func albums(containing photoID: String) -> [Album] {
        albums.filter { $0.photoIDs.contains(photoID) }
    }

    /// Trims the name and checks it is non-empty, short enough, and unique
    /// (case-insensitively) among albums other than `excluding`.
    func validatedName(_ rawName: String, excluding albumID: UUID? = nil) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AlbumError.emptyName }
        guard name.count <= Self.maxNameLength else { throw AlbumError.nameTooLong(limit: Self.maxNameLength) }
        let clash = albums.contains {
            $0.id != albumID && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }
        guard !clash else { throw AlbumError.duplicateName(name) }
        return name
    }

    @discardableResult
    mutating func create(named rawName: String, now: Date = Date()) throws -> Album {
        let album = Album(name: try validatedName(rawName), createdAt: now)
        albums.append(album)
        return album
    }

    mutating func rename(_ albumID: UUID, to rawName: String) throws {
        guard let index = albums.firstIndex(where: { $0.id == albumID }) else { throw AlbumError.notFound }
        albums[index].name = try validatedName(rawName, excluding: albumID)
    }

    mutating func delete(_ albumID: UUID) {
        albums.removeAll { $0.id == albumID }
    }

    /// Adds a photo to an album. Returns `false` if it was already there.
    @discardableResult
    mutating func add(_ photoID: String, to albumID: UUID) throws -> Bool {
        guard let index = albums.firstIndex(where: { $0.id == albumID }) else { throw AlbumError.notFound }
        guard !albums[index].photoIDs.contains(photoID) else { return false }
        albums[index].photoIDs.append(photoID)
        return true
    }

    mutating func remove(_ photoID: String, from albumID: UUID) {
        guard let index = albums.firstIndex(where: { $0.id == albumID }) else { return }
        albums[index].photoIDs.removeAll { $0 == photoID }
    }

    /// Drops photos from every album, used after they are deleted from the library.
    mutating func removePhotosEverywhere(_ photoIDs: Set<String>) {
        for index in albums.indices {
            albums[index].photoIDs.removeAll { photoIDs.contains($0) }
        }
    }
}
