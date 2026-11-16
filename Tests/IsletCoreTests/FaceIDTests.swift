import Foundation
import Testing
@testable import IsletCore

@Suite("Face ID: matching, alignment, liveness, typing gate")
struct FaceIDTests {
    @Test func similarityIsCosine() {
        #expect(abs(FaceID.similarity([1, 0], [1, 0]) - 1) < 1e-6)
        #expect(abs(FaceID.similarity([1, 0], [0, 1])) < 1e-6)
        #expect(abs(FaceID.similarity([2, 0], [5, 0]) - 1) < 1e-6)
        #expect(FaceID.similarity([1, 0], [1, 0, 0]) == -1)
        #expect(FaceID.similarity([0, 0], [1, 0]) == -1)
    }

    @Test func bestMatchPicksClosestFace() {
        let enrolled: [[Float]] = [[1, 0, 0], [0, 1, 0]]
        #expect(abs(FaceID.bestMatch([0.1, 0.99, 0], against: enrolled) - FaceID.similarity([0.1, 0.99, 0], [0, 1, 0])) < 1e-9)
        #expect(FaceID.bestMatch([1, 0, 0], against: []) == -1)
    }

    @Test func learningKeepsNewLooksOnly() {
        let enrolled: [[Float]] = [[1, 0, 0]]
        // A near-copy of the enrolment teaches nothing.
        #expect(FaceID.learning([0.99, 0.05, 0], enrolled: enrolled, learned: []) == nil)
        // A different look (other light) is kept.
        let look: [Float] = FaceID.normalized([0.7, 0.7, 0])
        #expect(FaceID.learning(look, enrolled: enrolled, learned: []) == [look])
        // Full: the oldest learned look goes, the newest stays.
        let full = (0..<FaceID.learnedLimit).map { FaceID.normalized([0, -1, Float($0) * 0.01]) }
        let next = FaceID.learning([0, 0, 1], enrolled: enrolled, learned: full)
        #expect(next?.count == FaceID.learnedLimit)
        #expect(next?.first == full[1])
        #expect(next?.last == [0, 0, 1])
    }

    @Test func meanIsAUnitAverage() {
        let mean = FaceID.mean([[1, 0], [0, 1], [3, 3, 3]])
        #expect(abs(mean[0] - 0.70710677) < 1e-6 && abs(mean[1] - 0.70710677) < 1e-6)
        #expect(FaceID.mean([]).isEmpty)
    }

    @Test func strictnessRaisesTheBar() {
        #expect(abs(FaceID.threshold(strictness: 0) - 0.363) < 1e-9)
        #expect(FaceID.threshold(strictness: 1) > FaceID.threshold(strictness: 0.5))
        #expect(FaceID.threshold(strictness: 7) == FaceID.threshold(strictness: 1))
    }

    @Test func keyPointsIgnoreWhichSideIsCalledLeft() {
        let pupils = [FaceID.Point(x: 70, y: 50), FaceID.Point(x: 40, y: 50)]
        let nose = [FaceID.Point(x: 55, y: 60), FaceID.Point(x: 56, y: 72), FaceID.Point(x: 57, y: 65)]
        let lips = [FaceID.Point(x: 45, y: 90), FaceID.Point(x: 56, y: 88), FaceID.Point(x: 68, y: 91)]
        let points = FaceID.keyPoints(pupils: pupils, nose: nose, outerLips: lips)
        #expect(points?.map(\.x) == [40, 70, 56, 45, 68])
        // Mirrored input gives the same order.
        let swapped = FaceID.keyPoints(pupils: pupils.reversed(), nose: nose, outerLips: lips.reversed())
        #expect(swapped == points)
        #expect(FaceID.keyPoints(pupils: [pupils[0]], nose: nose, outerLips: lips) == nil)
    }

    @Test func alignmentRecoversRotationScaleAndShift() throws {
        // The template rotated 20°, scaled 3× and moved: the fit must undo it exactly.
        let angle = 20.0 * .pi / 180, scale = 3.0
        let moved = FaceID.template.map {
            FaceID.Point(x: scale * (cos(angle) * $0.x - sin(angle) * $0.y) + 400,
                         y: scale * (sin(angle) * $0.x + cos(angle) * $0.y) + 120)
        }
        let m = try #require(FaceID.similarityTransform(from: moved, to: FaceID.template))
        for (point, expected) in zip(moved, FaceID.template) {
            let back = FaceID.apply(m, to: point)
            #expect(abs(back.x - expected.x) < 1e-6 && abs(back.y - expected.y) < 1e-6)
        }
        #expect(FaceID.similarityTransform(from: [FaceID.Point(x: 1, y: 1)], to: [FaceID.Point(x: 2, y: 2)]) == nil)
    }

    @Test func eyeOpenness() {
        let open = [FaceID.Point(x: 0, y: 0), FaceID.Point(x: 10, y: 0), FaceID.Point(x: 5, y: -1.5), FaceID.Point(x: 5, y: 1.5)]
        #expect(abs((FaceID.eyeOpenness(open) ?? 0) - 0.3) < 1e-9)
        #expect(FaceID.eyeOpenness([FaceID.Point(x: 0, y: 0)]) == nil)
    }

    private func frames(_ eyes: [Double?], yaw: [Double]? = nil, framed: Bool = false) -> [LivenessTracker.Frame] {
        eyes.enumerated().map { index, value in
            LivenessTracker.Frame(time: Double(index) * 0.1, eyes: value, yaw: yaw?[index] ?? 0, pitch: 0, roll: 0, framed: framed)
        }
    }

    @Test func aBlinkPasses() {
        var tracker = LivenessTracker(level: .natural)
        for frame in frames([0.3, 0.3, 0.29, 0.1, 0.08, 0.27, 0.3]) { tracker.add(frame) }
        #expect(tracker.passed)
        #expect(tracker.summary == "blinked")
    }

    @Test func aStillPhotoDoesNot() {
        var tracker = LivenessTracker(level: .natural)
        for frame in frames(Array(repeating: 0.3, count: 15)) { tracker.add(frame) }
        #expect(!tracker.passed)
    }

    @Test func headMovementAloneNeverPasses() {
        // A still photo jiggling by a few degrees (camera noise, a hand) is not a live face.
        let eyes = Array(repeating: 0.3 as Double?, count: 6)
        let yaw = [0, 1, 2, 3, 3.5, 3]
        var natural = LivenessTracker(level: .natural)
        var strict = LivenessTracker(level: .strict)
        for frame in frames(eyes, yaw: yaw) {
            natural.add(frame)
            strict.add(frame)
        }
        #expect(!natural.passed)
        #expect(!strict.passed)
    }

    @Test func aFramedFaceIsDeniedEvenWhenItBlinks() {
        var tracker = LivenessTracker(level: .natural)
        for frame in frames([0.3, 0.3, 0.05, 0.3, 0.3], framed: true) { tracker.add(frame) }
        #expect(tracker.denied)
        #expect(!tracker.passed)
        var off = LivenessTracker(level: .off)
        for frame in frames([0.3], framed: true) { off.add(frame) }
        #expect(off.passed)
    }

    @Test func oldFramesFallOutOfTheWindow() {
        var tracker = LivenessTracker(level: .strict)
        // A big head turn long ago, then stillness: not live now.
        tracker.add(.init(time: 0, eyes: 0.3, yaw: -20, pitch: 0, roll: 0, framed: false))
        for t in stride(from: 5.0, to: 7.5, by: 0.1) {
            tracker.add(.init(time: t, eyes: 0.3, yaw: 0, pitch: 0, roll: 0, framed: false))
        }
        #expect(!tracker.passed)
    }

    @Test func aBlinkExpiresWithTheWindow() {
        // Someone blinks, then 3 s of a still photo: the old blink no longer counts.
        var tracker = LivenessTracker(level: .natural)
        for frame in frames([0.3, 0.3, 0.05, 0.3]) { tracker.add(frame) }
        #expect(tracker.passed)
        for t in stride(from: 3.0, to: 6.0, by: 0.1) {
            tracker.add(.init(time: t, eyes: 0.3, yaw: 0, pitch: 0, roll: 0, framed: false))
        }
        #expect(!tracker.passed)
    }

    @Test func resetForgetsAnotherFacesBlink() {
        var tracker = LivenessTracker(level: .natural)
        for frame in frames([0.3, 0.3, 0.05, 0.3]) { tracker.add(frame) }
        tracker.reset()
        for t in stride(from: 0.5, to: 1.5, by: 0.1) {
            tracker.add(.init(time: t, eyes: 0.3, yaw: 0, pitch: 0, roll: 0, framed: false))
        }
        #expect(!tracker.passed)
    }

    @Test func gateTypesOnlyWhenEverythingHolds() {
        let ok = FaceUnlockGate(sessionLocked: true, lockWindowOnScreen: true, secondsSinceKeyPress: 10,
                                secondsSinceMatch: 0.3, failedSinceManualUnlock: false)
        #expect(ok.allowsTyping)
        var gate = ok
        gate.sessionLocked = false
        #expect(gate.refusal == .notLocked)
        gate = ok
        gate.lockWindowOnScreen = false
        #expect(gate.refusal == .noLockScreen)
        gate = ok
        gate.secondsSinceKeyPress = 0.5
        #expect(gate.refusal == .someoneTyping)
        gate = ok
        gate.secondsSinceMatch = nil
        #expect(gate.refusal == .noRecentMatch)
        gate.secondsSinceMatch = 2
        #expect(gate.refusal == .noRecentMatch)
        gate.secondsSinceMatch = -1
        #expect(gate.refusal == .noRecentMatch)
        gate = ok
        gate.failedSinceManualUnlock = true
        #expect(gate.refusal == .failedBefore)
    }

    @Test func spoofCropMatchesMinivision() {
        // Room all round: grown around the centre.
        let mid = FaceID.spoofCrop(x: 270, y: 190, width: 100, height: 100, scale: 2.7, frameWidth: 640, frameHeight: 480)
        #expect(mid.x == 185 && mid.y == 105 && mid.width == 271 && mid.height == 271)
        // In the corner: slid back inside the frame.
        let corner = FaceID.spoofCrop(x: 0, y: 0, width: 100, height: 100, scale: 4, frameWidth: 640, frameHeight: 480)
        #expect(corner.x == 0 && corner.y == 0 && corner.width == 401 && corner.height == 401)
        // Too big to grow 4×: only as far as the frame's height allows.
        let close = FaceID.spoofCrop(x: 170, y: 90, width: 300, height: 300, scale: 4, frameWidth: 640, frameHeight: 480)
        #expect(close.y == 0 && close.height == 480 && close.x == 80 && close.width == 480)
    }

    @Test func antiSpoofingHasTheLastWord() {
        func tracker(_ realness: Double?) -> LivenessTracker {
            var tracker = LivenessTracker(level: .natural)
            for (index, eyes) in [0.3, 0.3, 0.05, 0.3, 0.3].enumerated() {
                tracker.add(.init(time: Double(index) * 0.1, eyes: eyes, yaw: 0, pitch: 0, roll: 0, framed: false, realness: realness))
            }
            return tracker
        }
        #expect(tracker(0.9).passed)
        // A video of you blinking on a phone: it blinks, but the models see a screen.
        #expect(!tracker(0.2).passed)
        #expect(tracker(0.2).summary == "looks like a photo or screen")
        // Models not installed: blink-only, as before.
        #expect(tracker(nil).passed)
    }

    @Test func strictWantsABlinkNotJustMovement() {
        var strict = LivenessTracker(level: .strict)
        for frame in frames(Array(repeating: 0.3, count: 8), yaw: [0, 4, 8, 12, 8, 4, 0, -4]) { strict.add(frame) }
        #expect(!strict.passed)
        for frame in frames([0.3, 0.3, 0.05, 0.3]) { strict.add(.init(time: frame.time + 1, eyes: frame.eyes, yaw: 0, pitch: 0, roll: 0, framed: false)) }
        #expect(strict.passed)
    }

    /// 30 frames a second around a light check. `lit` says, for the tint the camera sees
    /// at that moment, how much the face and the whole frame brighten in that colour.
    private func flashReadings(_ challenge: FlashChallenge, start: Double, showing order: [FlashChallenge.Tint],
                               face lift: Double, scene sceneLift: Double) -> [FlashChallenge.Reading] {
        stride(from: start - 0.6, to: start + challenge.duration + 0.1, by: 1.0 / 30).map { t in
            var face = [90.0, 80.0, 70.0], scene = [60.0, 60.0, 60.0]
            let slot = Int(((t - start - FlashChallenge.delay) / FlashChallenge.step).rounded(.down))
            if t - start >= FlashChallenge.delay, order.indices.contains(slot) {
                face[order[slot].rawValue] += lift
                scene[order[slot].rawValue] += sceneLift
            }
            return .init(time: t, face: face, scene: scene)
        }
    }

    @Test func aRealFaceTakesOnTheColours() {
        let challenge = FlashChallenge(tints: [.blue, .red])
        let verdict = challenge.verdict(flashReadings(challenge, start: 10, showing: [.blue, .red], face: 30, scene: 5), start: 10)
        #expect(verdict.passed)
        #expect(verdict.shifts.count == 2 && verdict.shifts.allSatisfy { $0 > FlashChallenge.minimumShift })
    }

    @Test func aScreenOrAReplayDoesNot() {
        let challenge = FlashChallenge(tints: [.blue, .red])
        // A face on a phone gives off its own light: only the room around it changes.
        #expect(!challenge.verdict(flashReadings(challenge, start: 10, showing: [.blue, .red], face: 0, scene: 5), start: 10).passed)
        // A video recorded during another check shows the wrong order.
        #expect(!challenge.verdict(flashReadings(challenge, start: 10, showing: [.red, .blue], face: 30, scene: 5), start: 10).passed)
        // No frames of the face at all.
        #expect(challenge.verdict([], start: 10).reason == "no face just before the flash")
    }

    @Test func randomChallengesAreThreeRedOrGreenFlashes() {
        var seen = Set<[Int]>()
        for _ in 0..<200 {
            let tints = FlashChallenge.random().tints
            #expect(tints.count == 3 && !tints.contains(.blue))
            seen.insert(tints.map(\.rawValue))
        }
        #expect(seen.count == 8)
        // The same colour twice in a row is judged per flash, like any other order.
        let twice = FlashChallenge(tints: [.red, .red, .green])
        #expect(twice.verdict(flashReadings(twice, start: 10, showing: [.red, .red, .green], face: 30, scene: 5), start: 10).passed)
        #expect(!twice.verdict(flashReadings(twice, start: 10, showing: [.red, .green, .green], face: 30, scene: 5), start: 10).passed)
    }
}
