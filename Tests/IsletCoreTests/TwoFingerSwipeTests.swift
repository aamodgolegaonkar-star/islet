import Testing
@testable import IsletCore

@Suite("Two-finger swipes over the island")
struct TwoFingerSwipeTests {
    private func run(_ moves: [(up: Double, right: Double)], canSkip: Bool = true) -> [TwoFingerSwipe.Action] {
        var swipe = TwoFingerSwipe()
        swipe.begin()
        return moves.compactMap { swipe.move(up: $0.up, right: $0.right, canSkip: canSkip) }
    }

    @Test func leftIsNextRightIsPrevious() {
        #expect(run(Array(repeating: (0, -10), count: 6)) == [.next])
        #expect(run(Array(repeating: (0, 10), count: 6)) == [.previous])
    }

    @Test func upTucks() {
        #expect(run(Array(repeating: (10, 0), count: 4)) == [.tuck])
    }

    @Test func oneActionPerGesture() {
        #expect(run(Array(repeating: (0, -30), count: 10)) == [.next])
    }

    @Test func diagonalNeitherSkipsNorTucksEarly() {
        // Mostly up with some drift: tucks, never skips.
        #expect(run(Array(repeating: (10, 5), count: 6)) == [.tuck])
    }

    @Test func sidewaysIgnoredWhenSkippingIsOff() {
        #expect(run(Array(repeating: (0, -30), count: 5), canSkip: false) == [])
        #expect(run(Array(repeating: (10, -30), count: 4), canSkip: false) == [.tuck])
    }

    @Test func beginStartsAFreshGesture() {
        var swipe = TwoFingerSwipe()
        swipe.begin()
        _ = swipe.move(up: 0, right: -50, canSkip: true)
        swipe.begin()
        #expect(swipe.move(up: 0, right: 50, canSkip: true) == .previous)
    }
}
