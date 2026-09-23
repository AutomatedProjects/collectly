import CoreGraphics

/// Turns a horizontal drag into a review decision.
enum SwipeDecider {
    /// How far the card must be dragged to count as a decision.
    static let distanceThreshold: CGFloat = 120
    /// How far a quick flick must be projected to travel to count.
    static let flickThreshold: CGFloat = 300

    /// Right = keep, left = delete, `nil` = snap back.
    static func decision(translation: CGFloat, predictedEndTranslation: CGFloat) -> ReviewDecision? {
        if translation >= distanceThreshold || (translation > 0 && predictedEndTranslation >= flickThreshold) {
            return .keep
        }
        if translation <= -distanceThreshold || (translation < 0 && predictedEndTranslation <= -flickThreshold) {
            return .delete
        }
        return nil
    }

    /// 0...1 strength of the on-card KEEP/DELETE hint while dragging.
    static func hintStrength(translation: CGFloat) -> Double {
        min(Double(abs(translation) / distanceThreshold), 1)
    }
}
