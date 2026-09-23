import Foundation

/// What the user decided for a single photo during review.
enum ReviewDecision: String, Codable, Sendable {
    /// Swiped right: the photo stays in the library.
    case keep
    /// Swiped left: the photo is queued for deletion. Nothing is removed from
    /// the library until the user confirms from the "To Delete" screen.
    case delete
}
