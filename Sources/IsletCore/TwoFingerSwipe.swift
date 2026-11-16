/// Turns one two-finger trackpad gesture over the island into at most one action: up tucks
/// the island away, sideways ("Swipe to skip") changes the song. Movement is given in the
/// direction the fingers travel, whatever the scrolling setting.
public struct TwoFingerSwipe: Sendable {
    public enum Action: Equatable, Sendable { case tuck, next, previous }

    /// Points of upward travel that tuck the island away.
    static let tuckDistance = 28.0
    /// Points of sideways travel that skip, and how much more sideways than vertical it must be.
    static let skipDistance = 40.0
    static let skipDominance = 1.5

    private var up = 0.0
    private var sideways = 0.0
    private var finished = false

    public init() {}

    /// The fingers touched down: a new gesture.
    public mutating func begin() {
        up = 0
        sideways = 0
        finished = false
    }

    /// Adds movement and returns the action it completes, once per gesture. `canSkip` is
    /// false while skipping isn't possible (nothing playing, coasting after the fingers lift,
    /// or the setting is off); sideways travel is then ignored.
    public mutating func move(up dy: Double, right dx: Double, canSkip: Bool) -> Action? {
        guard !finished else { return nil }
        up += dy
        if canSkip { sideways += dx }
        if canSkip, abs(sideways) > Self.skipDistance, abs(sideways) > abs(up) * Self.skipDominance {
            finished = true
            // Like paging: fingers left bring the next song in, right go back.
            return sideways < 0 ? .next : .previous
        }
        if up > Self.tuckDistance, up > abs(sideways) {
            finished = true
            return .tuck
        }
        return nil
    }
}
