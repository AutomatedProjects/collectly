import Foundation

/// Everything Collectly saves between launches. Stored as JSON on device.
struct PersistedState: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var decisions: [String: ReviewDecision]
    /// When each delete mark was made. Added after version 1 shipped, so it
    /// is optional in the file; missing dates are filled in on load.
    var deleteMarkedAt: [String: Date]
    var albums: [Album]

    init(version: Int = PersistedState.currentVersion,
         decisions: [String: ReviewDecision] = [:],
         deleteMarkedAt: [String: Date] = [:],
         albums: [Album] = []) {
        self.version = version
        self.decisions = decisions
        self.deleteMarkedAt = deleteMarkedAt
        self.albums = albums
    }

    private enum CodingKeys: String, CodingKey {
        case version, decisions, deleteMarkedAt, albums
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        decisions = try container.decode([String: ReviewDecision].self, forKey: .decisions)
        deleteMarkedAt = try container.decodeIfPresent([String: Date].self, forKey: .deleteMarkedAt) ?? [:]
        albums = try container.decode([Album].self, forKey: .albums)
    }
}
