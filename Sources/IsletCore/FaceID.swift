import Foundation

/// The pure parts of Face ID: matching face fingerprints, lining a face up for the model,
/// telling a live face from a picture, and the gate that decides whether the password may
/// be typed. None of it touches the camera, the Keychain or the keyboard, so all of it is
/// tested.
public enum FaceID {
    /// SFace's fingerprint length.
    public static let embeddingLength = 128
    /// The model's input side, in pixels.
    public static let inputSide = 112.0

    /// Where SFace expects the eyes, nose tip and mouth corners in its 112×112 input
    /// (OpenCV `FaceRecognizerSF::alignCrop`), left to right as seen in the image.
    public static let template: [Point] = [
        Point(x: 38.2946, y: 51.6963), Point(x: 73.5318, y: 51.5014),
        Point(x: 56.0252, y: 71.7366),
        Point(x: 41.5493, y: 92.3655), Point(x: 70.7299, y: 92.2041),
    ]

    public struct Point: Equatable, Sendable, Codable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    // MARK: - Matching

    /// The fingerprint scaled to length 1, so a dot product is the cosine similarity.
    public static func normalized(_ vector: [Float]) -> [Float] {
        let length = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard length > 0 else { return vector }
        return vector.map { $0 / length }
    }

    /// Cosine similarity of two fingerprints (1 is identical).
    public static func similarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for index in a.indices {
            dot += a[index] * b[index]
            na += a[index] * a[index]
            nb += b[index] * b[index]
        }
        guard na > 0, nb > 0 else { return -1 }
        return Double(dot / (na.squareRoot() * nb.squareRoot()))
    }

    /// The best similarity between `probe` and any enrolled fingerprint.
    public static func bestMatch(_ probe: [Float], against enrolled: [[Float]]) -> Double {
        enrolled.map { similarity(probe, $0) }.max() ?? -1
    }

    /// Minivision's crop for its anti-spoofing models (`CropImage._get_new_box`): the face box
    /// (pixels, y down) grown `scale` times around its centre, as far as the frame allows, and
    /// slid back inside it. Returns the crop's origin and size in pixels.
    public static func spoofCrop(x: Double, y: Double, width boxW: Double, height boxH: Double, scale: Double,
                                 frameWidth: Double, frameHeight: Double) -> (x: Double, y: Double, width: Double, height: Double) {
        let scale = min((frameHeight - 1) / boxH, (frameWidth - 1) / boxW, scale)
        let newW = boxW * scale, newH = boxH * scale
        let cx = boxW / 2 + x, cy = boxH / 2 + y
        var left = cx - newW / 2, top = cy - newH / 2, right = cx + newW / 2, bottom = cy + newH / 2
        if left < 0 { right -= left; left = 0 }
        if top < 0 { bottom -= top; top = 0 }
        if right > frameWidth - 1 { left -= right - frameWidth + 1; right = frameWidth - 1 }
        if bottom > frameHeight - 1 { top -= bottom - frameHeight + 1; bottom = frameHeight - 1 }
        let x0 = left.rounded(.towardZero), y0 = top.rounded(.towardZero)
        let x1 = right.rounded(.towardZero), y1 = bottom.rounded(.towardZero)
        // The repo slices [y0 : y1 + 1], so the crop includes its last row and column.
        return (x0, y0, x1 - x0 + 1, y1 - y0 + 1)
    }

    /// A look this close to one already known adds nothing worth learning.
    public static let novelty = 0.88
    /// Learned looks kept per face; the oldest makes room for a new one.
    public static let learnedLimit = 12

    /// Adds a new look of an enrolled face (other light, glasses, a haircut) to what it has
    /// learned, so it matches sooner next time: the updated list, or nil when the look is a
    /// near-copy of one already known. The enrolment itself never changes, so a bad lesson
    /// can't wear away the original.
    public static func learning(_ probe: [Float], enrolled: [[Float]], learned: [[Float]]) -> [[Float]]? {
        guard bestMatch(probe, against: enrolled + learned) < novelty else { return nil }
        return Array((learned + [probe]).suffix(learnedLimit))
    }

    /// Several fingerprints of one pose averaged and scaled to length 1: steadier than any
    /// single frame, whose noise (blur, a half blink) would otherwise be enrolled for good.
    public static func mean(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        var sum = [Float](repeating: 0, count: first.count)
        for vector in vectors where vector.count == sum.count {
            for index in sum.indices { sum[index] += vector[index] }
        }
        return normalized(sum)
    }

    /// The similarity a face must reach. Strictness 0…1 runs from OpenCV's recommended
    /// SFace threshold (0.363) up to well past it: stricter means harder for anyone else
    /// and occasionally slower for you.
    public static func threshold(strictness: Double) -> Double {
        0.363 + 0.237 * min(max(strictness, 0), 1)
    }

    // MARK: - Alignment

    /// The five points SFace wants, in template order, from the landmarks Vision finds:
    /// the two pupils, the nose outline and the outer lips. Sorted by x in the image, so
    /// whichever side a detector calls "left" doesn't matter. `y` grows downward.
    public static func keyPoints(pupils: [Point], nose: [Point], outerLips: [Point]) -> [Point]? {
        guard pupils.count == 2, !nose.isEmpty, outerLips.count >= 2 else { return nil }
        let eyes = pupils.sorted { $0.x < $1.x }
        // The nose tip is the outline's lowest point.
        guard let tip = nose.max(by: { $0.y < $1.y }),
              let mouthLeft = outerLips.min(by: { $0.x < $1.x }),
              let mouthRight = outerLips.max(by: { $0.x < $1.x }) else { return nil }
        return [eyes[0], eyes[1], tip, mouthLeft, mouthRight]
    }

    /// A similarity transform (rotation, uniform scale, shift) taking `source` onto
    /// `target` as closely as possible (Umeyama): `[a, b, tx, c, d, ty]` with
    /// x' = a·x + b·y + tx and y' = c·x + d·y + ty.
    public static func similarityTransform(from source: [Point], to target: [Point]) -> [Double]? {
        guard source.count == target.count, source.count >= 2 else { return nil }
        let n = Double(source.count)
        let sx = source.map(\.x).reduce(0, +) / n, sy = source.map(\.y).reduce(0, +) / n
        let tx = target.map(\.x).reduce(0, +) / n, ty = target.map(\.y).reduce(0, +) / n
        // Fit x' = a·x − b·y + e, y' = b·x + a·y + f on the centred points.
        var num1 = 0.0, num2 = 0.0, den = 0.0
        for (s, t) in zip(source, target) {
            let x = s.x - sx, y = s.y - sy, u = t.x - tx, v = t.y - ty
            num1 += x * u + y * v
            num2 += x * v - y * u
            den += x * x + y * y
        }
        guard den > 1e-9 else { return nil }
        let a = num1 / den, b = num2 / den
        return [a, -b, tx - (a * sx - b * sy), b, a, ty - (b * sx + a * sy)]
    }

    /// Applies a transform from `similarityTransform`.
    public static func apply(_ m: [Double], to p: Point) -> Point {
        Point(x: m[0] * p.x + m[1] * p.y + m[2], y: m[3] * p.x + m[4] * p.y + m[5])
    }

    // MARK: - Liveness

    /// How open an eye is: its outline's height over its width (about 0.25–0.35 open,
    /// under 0.15 shut).
    public static func eyeOpenness(_ outline: [Point]) -> Double? {
        guard outline.count >= 4,
              let minX = outline.map(\.x).min(), let maxX = outline.map(\.x).max(),
              let minY = outline.map(\.y).min(), let maxY = outline.map(\.y).max(),
              maxX - minX > 0 else { return nil }
        return (maxY - minY) / (maxX - minX)
    }
}

/// How hard Face ID works to tell you from a picture of you.
public enum FaceLiveness: String, CaseIterable, Sendable, Codable {
    /// Fastest. A good photo of you could fool it.
    case off
    /// A natural blink. (Head movement used to count too, but the camera's own jitter on a
    /// still photo was enough to pass it.) Stops photos; a video of you blinking gets past.
    case natural
    /// A clear blink (a tilted photo can fake head movement, not a blink), no phone or photo
    /// edge around the face, then the screen's light check (`FlashChallenge`).
    case strict
}

/// Watches a couple of seconds of frames for signs of a live face: a blink (the eyes close
/// and open again) or the head moving. A frame where the face sits inside a rectangle (a
/// phone screen or a printed photo) counts against it in every level but off.
public struct LivenessTracker: Sendable {
    public struct Frame: Sendable {
        public var time: TimeInterval
        /// Average openness of both eyes (`FaceID.eyeOpenness`).
        public var eyes: Double?
        /// Head pose in degrees.
        public var yaw: Double
        public var pitch: Double
        public var roll: Double
        /// A rectangle (screen or photo edge) was found around the face.
        public var framed: Bool
        /// The anti-spoofing models' chance this is a live face, 0…1 (nil: they didn't run).
        public var realness: Double?

        public init(time: TimeInterval, eyes: Double?, yaw: Double, pitch: Double, roll: Double, framed: Bool,
                    realness: Double? = nil) {
            self.time = time
            self.eyes = eyes
            self.yaw = yaw
            self.pitch = pitch
            self.roll = roll
            self.framed = framed
            self.realness = realness
        }
    }

    public let level: FaceLiveness
    /// Seconds of frames considered.
    public static let window: TimeInterval = 2.5
    private var frames: [Frame] = []
    /// Worked out from the frames still in the window, so an old blink doesn't count.
    private var blinked = false

    public init(level: FaceLiveness) { self.level = level }

    /// Feed only frames of the face that matched; otherwise someone else's blink could
    /// vouch for a photo of you.
    public mutating func add(_ frame: Frame) {
        frames.append(frame)
        frames.removeAll { frame.time - $0.time > Self.window }
        blinked = Self.sawBlink(in: frames, strict: level == .strict)
    }

    /// A different face came into view: start over.
    public mutating func reset() {
        frames.removeAll()
        blinked = false
    }

    /// The face is live enough for this level.
    public var passed: Bool {
        switch level {
        case .off: return true
        case .natural, .strict: return !denied && blinked && realEnough
        }
    }

    /// The anti-spoofing models' average must reach this over the window.
    public static let realBar = 0.6

    /// The anti-spoofing models, over at least three frames, think it's a live face. With
    /// no scores at all (the models aren't installed) they have no say.
    private var realEnough: Bool {
        let scores = frames.compactMap(\.realness)
        if scores.isEmpty { return true }
        return scores.count >= 3 && scores.reduce(0, +) / Double(scores.count) >= Self.realBar
    }

    /// The models have seen enough to say it's a picture or a screen.
    private var looksFake: Bool {
        let scores = frames.compactMap(\.realness)
        return scores.count >= 3 && !realEnough
    }

    /// A screen or photo edge was seen around the face recently.
    public var denied: Bool {
        guard level != .off else { return false }
        let framed = frames.filter(\.framed).count
        return framed >= 2 && Double(framed) >= Double(frames.count) * 0.3
    }

    /// What the Test button reports.
    public var summary: String {
        if level == .off { return "off" }
        if denied || looksFake { return "looks like a photo or screen" }
        return blinked ? "blinked" : "waiting for a blink"
    }

    /// Open, then clearly shut, then open again, within the window.
    private static func sawBlink(in frames: [Frame], strict: Bool) -> Bool {
        let values = frames.compactMap(\.eyes)
        guard values.count >= 3, let open = values.max(), open > 0.12 else { return false }
        let shut = open * (strict ? 0.5 : 0.65)
        var phase = 0
        for value in values {
            switch phase {
            case 0 where value >= open * 0.85: phase = 1
            case 1 where value <= shut: phase = 2
            case 2 where value >= open * 0.8: return true
            default: break
            }
        }
        return false
    }
}

/// Strict liveness's light check. The screen shows colours in an order picked at random,
/// and a real face in front of it takes on each one. A face on a phone or tablet gives off
/// its own light and barely changes; a recorded video can't know the order. Colours are
/// compared as shares of brightness, the face's against the whole frame's, so the camera
/// drifting its exposure and white balance mostly cancels out.
public struct FlashChallenge: Sendable {
    public enum Tint: Int, CaseIterable, Sendable { case red, green, blue }

    public struct Reading: Sendable {
        public var time: TimeInterval
        /// Mean red, green and blue (0–255) of the middle of the face, and of the frame.
        public var face: [Double]
        public var scene: [Double]

        public init(time: TimeInterval, face: [Double], scene: [Double]) {
            self.time = time
            self.face = face
            self.scene = scene
        }
    }

    public struct Verdict: Sendable {
        public var passed: Bool
        /// How far the face's share of each flashed colour rose.
        public var shifts: [Double]
        public var reason: String
    }

    /// How long each colour shows: three of them stay within the three flashes a second
    /// that photosensitivity guidelines allow.
    public static let step: TimeInterval = 0.3
    /// From a colour going up to camera frames showing it (display, exposure, delivery).
    public static let delay: TimeInterval = 0.1
    /// How much the face's share of the flashed colour must rise (shares run 0…1). A real
    /// face measured 0.06–0.09 at arm's length; a face on a screen stays near 0.
    public static let minimumShift = 0.03

    public let tints: [Tint]

    public init(tints: [Tint]) { self.tints = tints }

    /// Three flashes, each red or green at random: eight orders, so a replay guesses right
    /// one time in eight. No blue: a camera barely sees a blue screen on a face (0.009
    /// against 0.06–0.09 for red and green).
    public static func random() -> FlashChallenge {
        FlashChallenge(tints: (0..<3).map { _ in Bool.random() ? .red : .green })
    }

    /// From the first colour going up to the last frame that can still show a colour.
    public var duration: TimeInterval { Double(tints.count) * Self.step + Self.delay }

    /// `start`: when the first colour went up. The frames just before it are the baseline.
    /// Feed only frames of the face that matched.
    public func verdict(_ readings: [Reading], start: TimeInterval) -> Verdict {
        func share(_ reading: Reading) -> [Double]? {
            let face = reading.face.reduce(0, +), scene = reading.scene.reduce(0, +)
            guard reading.face.count == 3, reading.scene.count == 3, face > 1, scene > 1 else { return nil }
            return (0..<3).map { reading.face[$0] / face - reading.scene[$0] / scene }
        }
        func mean(from: TimeInterval, to: TimeInterval) -> [Double]? {
            let values = readings.filter { $0.time >= from && $0.time < to }.compactMap(share)
            guard !values.isEmpty else { return nil }
            return (0..<3).map { channel in values.map { $0[channel] }.reduce(0, +) / Double(values.count) }
        }
        guard let base = mean(from: start - 0.6, to: start + Self.delay * 0.5) else {
            return Verdict(passed: false, shifts: [], reason: "no face just before the flash")
        }
        var shifts: [Double] = []
        for (index, tint) in tints.enumerated() {
            // Trim the edges, where the camera may still show the previous colour.
            let from = start + Double(index) * Self.step + Self.delay + 0.03
            let to = start + Double(index + 1) * Self.step + Self.delay - 0.03
            guard let seen = mean(from: from, to: to) else {
                return Verdict(passed: false, shifts: shifts, reason: "lost the face during the flash")
            }
            let shift = (0..<3).map { seen[$0] - base[$0] }
            let channel = tint.rawValue
            shifts.append(shift[channel])
            let strongest = shift.indices.allSatisfy { $0 == channel || shift[$0] < shift[channel] }
            guard shift[channel] >= Self.minimumShift, strongest else {
                return Verdict(passed: false, shifts: shifts, reason: "the face didn't turn \(tint)")
            }
        }
        return Verdict(passed: true, shifts: shifts, reason: "the face took on each colour")
    }
}

/// Whether Face ID may type the password right now. Every condition must hold; the
/// worst mistake is typing the password into an app after the screen has already
/// unlocked, so the lock is checked here and again just before the first key.
public struct FaceUnlockGate: Sendable {
    public var sessionLocked: Bool
    public var lockWindowOnScreen: Bool
    /// Seconds since anyone last pressed a key.
    public var secondsSinceKeyPress: Double
    /// Seconds since the face matched and passed liveness (nil: it hasn't).
    public var secondsSinceMatch: Double?
    /// An attempt failed (wrong or changed password) since the last unlock by hand.
    public var failedSinceManualUnlock: Bool

    public init(sessionLocked: Bool, lockWindowOnScreen: Bool, secondsSinceKeyPress: Double,
                secondsSinceMatch: Double?, failedSinceManualUnlock: Bool) {
        self.sessionLocked = sessionLocked
        self.lockWindowOnScreen = lockWindowOnScreen
        self.secondsSinceKeyPress = secondsSinceKeyPress
        self.secondsSinceMatch = secondsSinceMatch
        self.failedSinceManualUnlock = failedSinceManualUnlock
    }

    public enum Refusal: Equatable, Sendable {
        case notLocked, noLockScreen, someoneTyping, noRecentMatch, failedBefore
    }

    /// Nil when it's safe to type, otherwise why not.
    public var refusal: Refusal? {
        if !sessionLocked { return .notLocked }
        if !lockWindowOnScreen { return .noLockScreen }
        if secondsSinceKeyPress < 2 { return .someoneTyping }
        guard let secondsSinceMatch, secondsSinceMatch >= 0, secondsSinceMatch <= 1 else { return .noRecentMatch }
        if failedSinceManualUnlock { return .failedBefore }
        return nil
    }

    public var allowsTyping: Bool { refusal == nil }
}
