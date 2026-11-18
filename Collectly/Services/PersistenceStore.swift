import Foundation

/// Saves and loads Collectly's local state.
@MainActor
protocol PersistenceStore: AnyObject {
    func load() throws -> PersistedState
    /// Queues `state` to be saved. Throws right away if saving is disabled;
    /// failures while writing are reported to `saveFailureHandler`.
    func save(_ state: PersistedState) throws
    /// Blocks until every queued save has been written.
    func flush()
    var saveFailureHandler: (@MainActor (Error) -> Void)? { get set }
}

enum PersistenceError: LocalizedError, Equatable {
    /// The saved file couldn't be decoded. It was moved aside to `backupURL`,
    /// so starting fresh can't overwrite it.
    case corruptedData(backupURL: URL)
    /// The saved file couldn't be decoded or repaired, and moving it aside
    /// failed too. Saving stays disabled so the original isn't overwritten.
    case backupFailed
    /// The saved file exists but couldn't be read, e.g. because the device is
    /// locked. Saving stays disabled until a later load succeeds.
    case unreadable
    /// A newer version of Collectly wrote the file. Saving stays disabled so
    /// that data isn't overwritten.
    case unsupportedVersion(Int)
    /// A save was refused because an earlier load failed.
    case savingDisabled

    /// Whether this load failure leaves the on-disk file as the only good
    /// copy, so nothing may be saved over it.
    var blocksSaving: Bool {
        switch self {
        case .corruptedData: false
        case .backupFailed, .unreadable, .unsupportedVersion, .savingDisabled: true
        }
    }

    var errorDescription: String? {
        switch self {
        case .corruptedData:
            "Your saved review progress couldn't be read, so Collectly started fresh. A copy of the old file was kept. No photos were changed."
        case .backupFailed, .unreadable:
            "Your saved review progress couldn't be read. To protect it, Collectly won't save changes until you restart the app. No photos were changed."
        case .unsupportedVersion:
            "Your review progress was saved by a newer version of Collectly. To protect it, this version won't save changes. Please update the app."
        case .savingDisabled:
            "Saving is turned off because your saved progress couldn't be loaded."
        }
    }
}

/// Stores state as JSON in Application Support.
///
/// - The file uses `NSFileProtectionComplete`: it can't be read while the
///   device is locked. Collectly does no background work, so it only needs the
///   file while it's in use.
/// - Encoding and writing happen on a background queue. Saves are coalesced so
///   only the latest state is written, and they stay in order.
/// - If the file can't be decoded, it is moved aside to a uniquely named
///   `state.corrupt-<ms>-<UUID>.json` before Collectly starts fresh. If a load
///   needed repairs, the original is copied to `state.repaired-….json`. Only
///   the newest `maxBackups` of these are kept.
/// - If the file can't be read, or can't be moved aside, saving is refused
///   until a later load succeeds, so the only copy is never overwritten.
@MainActor
final class FilePersistenceStore: PersistenceStore {
    static let maxBackups = 3
    static let writingOptions: Data.WritingOptions = [.atomic, .completeFileProtection]

    let fileURL: URL
    var saveFailureHandler: (@MainActor (Error) -> Void)?
    private(set) var isSavingBlocked = false

    private let fileManager = FileManager.default
    private let writer: StateFileWriter

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.writer = StateFileWriter(fileURL: fileURL, options: Self.writingOptions)
        writer.onError = { [weak self] error in
            Task { @MainActor in self?.saveFailureHandler?(error) }
        }
    }

    static func makeDefault() -> FilePersistenceStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return FilePersistenceStore(fileURL: base.appending(path: "Collectly/state.json"))
    }

    func load() throws -> PersistedState {
        writer.flush()
        guard fileManager.fileExists(atPath: fileURL.path) else {
            isSavingBlocked = false
            return PersistedState()
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            isSavingBlocked = true
            throw PersistenceError.unreadable
        }

        let outcome: PersistedStateValidator.Outcome
        do {
            let decoded = try JSONDecoder().decode(PersistedState.self, from: data)
            outcome = try PersistedStateValidator.validate(decoded)
        } catch StateValidationError.newerVersion(let version) {
            isSavingBlocked = true
            throw PersistenceError.unsupportedVersion(version)
        } catch {
            guard let backupURL = makeBackup(kind: "corrupt", move: true) else {
                isSavingBlocked = true
                throw PersistenceError.backupFailed
            }
            isSavingBlocked = false
            throw PersistenceError.corruptedData(backupURL: backupURL)
        }

        // Keep the unrepaired original before the next save replaces it.
        if outcome.repaired, makeBackup(kind: "repaired", move: false) == nil {
            isSavingBlocked = true
            throw PersistenceError.backupFailed
        }
        isSavingBlocked = false
        return outcome.state
    }

    func save(_ state: PersistedState) throws {
        guard !isSavingBlocked else { throw PersistenceError.savingDisabled }
        writer.enqueue(state)
    }

    func flush() {
        writer.flush()
    }

    // MARK: Backups

    /// Moves or copies the state file to a new, uniquely named backup and
    /// prunes old backups. Returns `nil` if the backup couldn't be made.
    private func makeBackup(kind: String, move: Bool) -> URL? {
        let milliseconds = Int64(Date().timeIntervalSince1970 * 1000)
        let stamp = String(format: "%015lld", milliseconds)
        let name = "\(Self.backupPrefix)\(kind)-\(stamp)-\(UUID().uuidString).json"
        let backupURL = fileURL.deletingLastPathComponent().appending(path: name)
        do {
            if move {
                try fileManager.moveItem(at: fileURL, to: backupURL)
            } else {
                try fileManager.copyItem(at: fileURL, to: backupURL)
            }
        } catch {
            return nil
        }
        try? fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: backupURL.path)
        pruneBackups(keeping: backupURL)
        return backupURL
    }

    private static let backupPrefix = "state."

    /// Deletes all but the newest `maxBackups` backups. Ordering comes from
    /// the timestamp in the file name, so no file metadata is read.
    private func pruneBackups(keeping newest: URL) {
        let directory = fileURL.deletingLastPathComponent()
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        let backups = names.compactMap { name -> (name: String, stamp: Int64)? in
            guard let stamp = Self.backupTimestamp(fromFileName: name) else { return nil }
            return (name, stamp)
        }
        .sorted { ($0.stamp, $0.name) > ($1.stamp, $1.name) }
        for backup in backups.dropFirst(Self.maxBackups) where backup.name != newest.lastPathComponent {
            try? fileManager.removeItem(at: directory.appending(path: backup.name))
        }
    }

    /// Milliseconds since 1970 from `state.corrupt-<ms>-<UUID>.json`,
    /// `state.repaired-<ms>-<UUID>.json`, or the older
    /// `state.corrupt-<seconds>.json` format. `nil` for any other file.
    static func backupTimestamp(fromFileName name: String) -> Int64? {
        guard name.hasPrefix(backupPrefix), name.hasSuffix(".json") else { return nil }
        let body = name.dropFirst(backupPrefix.count).dropLast(".json".count)
        let rest: Substring
        if body.hasPrefix("corrupt-") {
            rest = body.dropFirst("corrupt-".count)
        } else if body.hasPrefix("repaired-") {
            rest = body.dropFirst("repaired-".count)
        } else {
            return nil
        }
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, let value = Int64(digits) else { return nil }
        // The original format used whole seconds.
        return digits.count <= 11 && rest.count == digits.count ? value * 1000 : value
    }
}

/// Encodes and writes state on a serial background queue. Only the most
/// recent pending state is written, so rapid saves coalesce.
final class StateFileWriter: @unchecked Sendable {
    /// Set once, before the first `enqueue`.
    var onError: (@Sendable (Error) -> Void)?

    private let fileURL: URL
    private let options: Data.WritingOptions
    private let queue = DispatchQueue(label: "com.collectly.persistence", qos: .utility)
    private let lock = NSLock()
    private var pending: PersistedState?

    init(fileURL: URL, options: Data.WritingOptions) {
        self.fileURL = fileURL
        self.options = options
    }

    func enqueue(_ state: PersistedState) {
        let needsDrain = lock.withLock {
            defer { pending = state }
            return pending == nil
        }
        if needsDrain {
            queue.async { self.drain() }
        }
    }

    func flush() {
        queue.sync {}
    }

    private func drain() {
        let state: PersistedState? = lock.withLock {
            defer { pending = nil }
            return pending
        }
        guard let state else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL, options: options)
        } catch {
            onError?(error)
        }
    }
}

/// Non-persistent store for previews, tests, and demo mode.
@MainActor
final class InMemoryPersistenceStore: PersistenceStore {
    var state: PersistedState
    var saveCount = 0
    var saveFailureHandler: (@MainActor (Error) -> Void)?

    init(state: PersistedState = PersistedState()) {
        self.state = state
    }

    func load() throws -> PersistedState { state }

    func save(_ state: PersistedState) throws {
        self.state = state
        saveCount += 1
    }

    func flush() {}
}
