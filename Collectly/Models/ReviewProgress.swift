import Foundation

/// Snapshot of how far the user is through reviewing the visible library.
struct ReviewProgress: Equatable, Sendable {
    var total: Int
    var kept: Int
    var markedForDeletion: Int

    static let empty = ReviewProgress(total: 0, kept: 0, markedForDeletion: 0)

    var reviewed: Int { kept + markedForDeletion }
    var remaining: Int { max(total - reviewed, 0) }
    var fractionComplete: Double { total == 0 ? 0 : Double(reviewed) / Double(total) }
    var isComplete: Bool { total > 0 && remaining == 0 }
}
