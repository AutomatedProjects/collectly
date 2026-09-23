import Testing
@testable import Collectly

struct SwipeDeciderTests {
    @Test(arguments: [
        (130.0, 130.0, ReviewDecision?.some(.keep)),
        (-130.0, -130.0, ReviewDecision?.some(.delete)),
        (40.0, 400.0, ReviewDecision?.some(.keep)),     // quick flick right
        (-40.0, -400.0, ReviewDecision?.some(.delete)), // quick flick left
        (60.0, 90.0, ReviewDecision?.none),             // small drag snaps back
        (0.0, 0.0, ReviewDecision?.none),
        (-20.0, 400.0, ReviewDecision?.none),           // direction mismatch snaps back
    ])
    func decision(translation: Double, predicted: Double, expected: ReviewDecision?) {
        #expect(SwipeDecider.decision(translation: translation, predictedEndTranslation: predicted) == expected)
    }

    @Test func hintStrengthIsClamped() {
        #expect(SwipeDecider.hintStrength(translation: 0) == 0)
        #expect(SwipeDecider.hintStrength(translation: -SwipeDecider.distanceThreshold / 2) == 0.5)
        #expect(SwipeDecider.hintStrength(translation: 1_000) == 1)
    }
}
