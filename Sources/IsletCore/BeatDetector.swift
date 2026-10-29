import Foundation

/// Finds beats in the music's low end, for the edge glow's pulse (after Lumn's rim, which
/// "syncs to the beat").
///
/// Fed the audio tap's band levels (0…1, lowest band first) about 30 times a second. A beat
/// is a sudden rise in bass energy well above its recent average, at most every 0.28 s
/// (about 214 bpm), so a sustained loud passage doesn't count as a stream of beats.
public struct BeatDetector: Sendable {
    /// How many of the lowest bands make up "the bass".
    public static let bassBands = 3
    static let minimumGap: TimeInterval = 0.28

    private var average: Float = 0
    private var variance: Float = 0
    private var lastBeat: TimeInterval = -.infinity
    private var primed = 0

    public init() {}

    /// Feeds one frame of levels heard at `time`; true when it's a beat.
    public mutating func feed(_ levels: [Float], at time: TimeInterval) -> Bool {
        guard !levels.isEmpty else { return false }
        let bass = levels.prefix(Self.bassBands)
        let energy = bass.reduce(0, +) / Float(bass.count)
        // About a second of memory at 30 frames a second.
        let deviation = energy - average
        let isBeat = primed >= 10
            && deviation > max(0.06, 1.4 * variance.squareRoot())
            && energy > 0.15
            && time - lastBeat >= Self.minimumGap
        average += 0.06 * deviation
        variance += 0.06 * (deviation * deviation - variance)
        primed += 1
        if isBeat { lastBeat = time }
        return isBeat
    }

    /// Back to no memory, e.g. after a pause or a new song.
    public mutating func reset() {
        self = BeatDetector()
    }
}
