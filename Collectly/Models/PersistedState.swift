import Foundation

/// Everything Collectly saves between launches. Stored as JSON on device.
struct PersistedState: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var decisions: [String: ReviewDecision]
    var albums: [Album]

    init(version: Int = PersistedState.currentVersion,
         decisions: [String: ReviewDecision] = [:],
         albums: [Album] = []) {
        self.version = version
        self.decisions = decisions
        self.albums = albums
    }
}
