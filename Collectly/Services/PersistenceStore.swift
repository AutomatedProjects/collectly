import Foundation

/// Saves and loads Collectly's local state.
@MainActor
protocol PersistenceStore: AnyObject {
    func load() throws -> PersistedState
    func save(_ state: PersistedState) throws
}

enum PersistenceError: LocalizedError, Equatable {
    /// The saved file couldn't be read. It was moved aside to `backupURL`
    /// so it isn't overwritten.
    case corruptedData(backupURL: URL?)

    var errorDescription: String? {
        switch self {
        case .corruptedData:
            "Your saved review progress couldn't be read, so Collectly started fresh. No photos were changed."
        }
    }
}

/// Stores state as JSON in Application Support.
@MainActor
final class FilePersistenceStore: PersistenceStore {
    let fileURL: URL
    private let fileManager = FileManager.default

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static func makeDefault() -> FilePersistenceStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return FilePersistenceStore(fileURL: base.appending(path: "Collectly/state.json"))
    }

    func load() throws -> PersistedState {
        guard fileManager.fileExists(atPath: fileURL.path) else { return PersistedState() }
        let data = try Data(contentsOf: fileURL)
        do {
            return try JSONDecoder().decode(PersistedState.self, from: data)
        } catch {
            let backupURL = fileURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            let moved = (try? fileManager.moveItem(at: fileURL, to: backupURL)) != nil
            throw PersistenceError.corruptedData(backupURL: moved ? backupURL : nil)
        }
    }

    func save(_ state: PersistedState) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Non-persistent store for previews, tests, and demo mode.
@MainActor
final class InMemoryPersistenceStore: PersistenceStore {
    var state: PersistedState
    var saveCount = 0

    init(state: PersistedState = PersistedState()) {
        self.state = state
    }

    func load() throws -> PersistedState { state }

    func save(_ state: PersistedState) throws {
        self.state = state
        saveCount += 1
    }
}
