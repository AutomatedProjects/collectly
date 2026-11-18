import Foundation

enum StateValidationError: Error, Equatable {
    /// The version number is impossible (zero or negative): treat as corrupt.
    case invalidVersion(Int)
    /// A newer Collectly wrote this file. It must not be overwritten.
    case newerVersion(Int)
}

/// Checks and repairs state decoded from disk before the app trusts it.
///
/// Repairs never drop user organization when they can avoid it: duplicate
/// albums are merged rather than discarded, and clashing or invalid names are
/// renamed rather than removed.
enum PersistedStateValidator {
    static let untitledAlbumName = "Untitled Album"

    struct Outcome: Equatable {
        var state: PersistedState
        /// `true` if decisions or albums had to be changed. Filling in missing
        /// delete-mark dates is a routine migration and doesn't count.
        var repaired: Bool
    }

    static func validate(_ input: PersistedState, now: Date = Date()) throws -> Outcome {
        guard input.version >= 1 else { throw StateValidationError.invalidVersion(input.version) }
        guard input.version <= PersistedState.currentVersion else {
            throw StateValidationError.newerVersion(input.version)
        }

        let decisions = input.decisions.filter { !$0.key.isEmpty }
        var deleteMarkedAt: [String: Date] = [:]
        for (id, decision) in decisions where decision == .delete {
            // A date in the future (clock change) would keep a mark alive too long.
            deleteMarkedAt[id] = min(input.deleteMarkedAt[id] ?? now, now)
        }

        let albums = sanitizedAlbums(input.albums)
        let state = PersistedState(version: PersistedState.currentVersion,
                                   decisions: decisions,
                                   deleteMarkedAt: deleteMarkedAt,
                                   albums: albums)
        return Outcome(state: state, repaired: decisions != input.decisions || albums != input.albums)
    }

    private static func sanitizedAlbums(_ input: [Album]) -> [Album] {
        var albums: [Album] = []
        var indexByID: [UUID: Int] = [:]
        for album in input {
            let photoIDs = album.photoIDs.filter { !$0.isEmpty }
            if let index = indexByID[album.id] {
                albums[index].photoIDs += photoIDs
            } else {
                indexByID[album.id] = albums.count
                albums.append(Album(id: album.id, name: album.name, photoIDs: photoIDs, createdAt: album.createdAt))
            }
        }

        var takenNames = Set<String>()
        for index in albums.indices {
            var seen = Set<String>()
            albums[index].photoIDs = albums[index].photoIDs.filter { seen.insert($0).inserted }
            let name = uniqueName(for: albums[index].name, taken: takenNames)
            albums[index].name = name
            takenNames.insert(name.lowercased())
        }
        return albums
    }

    /// Trims and length-limits the name, then appends " 2", " 3", … until it
    /// doesn't clash (case-insensitively) with an earlier album.
    private static func uniqueName(for rawName: String, taken: Set<String>) -> String {
        var base = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = untitledAlbumName }
        base = String(base.prefix(AlbumCollection.maxNameLength))
        guard taken.contains(base.lowercased()) else { return base }
        var number = 2
        while true {
            let suffix = " \(number)"
            let candidate = String(base.prefix(AlbumCollection.maxNameLength - suffix.count))
                .trimmingCharacters(in: .whitespaces) + suffix
            if !taken.contains(candidate.lowercased()) { return candidate }
            number += 1
        }
    }
}
