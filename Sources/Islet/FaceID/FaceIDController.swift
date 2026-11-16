import AppKit
import AVFoundation
import IsletCore

/// What the lock screen shows while Face ID works.
enum FaceScanPhase: Equatable {
    case scanning
    case matched
    /// It tried and the Mac stayed locked: the password is needed by hand.
    case needsPassword
}

/// Face ID on the Mac: looks for an enrolled face at the lock screen (when the display
/// wakes, right after locking, or when the notch is clicked) and, once the face matches
/// and passes the liveness check, types the saved password. Also runs enrolment and the
/// Settings test, which never unlocks anything.
@MainActor
@Observable
final class FaceIDController {
    private(set) var faces: [EnrolledFace] = FaceIDKeychain.loadFaces()
    private(set) var hasPassword = FaceIDKeychain.exists(account: FaceIDKeychain.passwordAccount)
    /// An attempt didn't unlock; it waits for an unlock by hand before trying again.
    private(set) var failedSinceManualUnlock = false
    private(set) var isScanning = false
    /// The Test button's live readout.
    private(set) var testReport: String?
    /// Enrolment progress: which of the nine head directions have been captured.
    private(set) var enrolledDirections: Set<Int> = []
    private(set) var enrolling = false

    var cameraAllowed: Bool { FaceCamera.authorized }
    var accessibilityAllowed: Bool { AXIsProcessTrusted() }
    var isReady: Bool { hasPassword && faces.contains { $0.enabled } }

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private weak var lockScreen: LockScreenController?
    @ObservationIgnored private var camera: FaceCamera?
    @ObservationIgnored private var engine: FaceEngine?
    @ObservationIgnored private var observers: [Any] = []
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var lastAttempt: Date?
    /// Typing the password and waiting to see it take.
    @ObservationIgnored private var unlocking = false
    @ObservationIgnored private var timing = ScanTiming()
    /// Several fingerprints per head direction, averaged when the face is saved.
    @ObservationIgnored private var enrolSamples: [Int: [[Float]]] = [:]
    @ObservationIgnored private var enrolLastSample: [Int: TimeInterval] = [:]
    @ObservationIgnored private var enrolStart: TimeInterval?
    /// Where the head pointed at the start, so directions are measured from there (a
    /// laptop's camera looks up at you, so "straight ahead" isn't zero).
    @ObservationIgnored private var enrolBaseline: (yaw: Double, pitch: Double)?
    @ObservationIgnored private var enrolDone: ((Bool) -> Void)?

    init(settings: AppSettings, lockScreen: LockScreenController) {
        self.settings = settings
        self.lockScreen = lockScreen
    }

    func start() {
        observers = [
            DistributedObserver("com.apple.screenIsLocked") { [weak self] _ in self?.locked() },
            DistributedObserver("com.apple.screenIsUnlocked") { [weak self] _ in self?.unlocked() },
        ]
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.trigger(.wake) }
        })
        lockScreen?.onIslandClick = { [weak self] in self?.trigger(.click) }
        lockScreen?.islandClickable = settings.faceIDEnabled && settings.faceIDOnClick
    }

    enum Trigger { case wake, lock, click }

    // MARK: - Lock screen

    private func locked() {
        lockScreen?.islandClickable = settings.faceIDEnabled && settings.faceIDOnClick
        // Load the model now, off the main thread, so the first look doesn't wait for it.
        if settings.faceIDEnabled, isReady, engine == nil {
            Task { @MainActor [weak self] in
                let loaded = await Self.loadEngine()
                if let self, self.engine == nil { self.engine = loaded }
            }
        }
        // Wait a couple of seconds, so locking on purpose sticks.
        guard settings.faceIDOnLock else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            self?.trigger(.lock)
        }
    }

    private func unlocked() {
        // Also when unlocked by hand mid-look: otherwise it would stay "scanning" for good.
        finishScan(hide: true)
        // Opened by hand: Face ID may try again next time.
        if unlockedByFace {
            let total = Int(((ProcessInfo.processInfo.systemUptime - timing.start) * 1000).rounded())
            Log.lock.info("Face ID unlocked the Mac \(total) ms after it started looking")
            if let lesson { learn(lesson) }
        } else {
            failedSinceManualUnlock = false
        }
        lesson = nil
    }

    // MARK: - Learning

    /// A match this far above the bar is sure enough to learn from.
    private static let confidentMargin = 0.08
    /// The confident frame of a Strict match under way, learned once the unlock works.
    /// (Nothing is learned from a look after the password is typed by hand: a phone still
    /// held up to the camera would be learned with it.)
    @ObservationIgnored private var lesson: [Float]?

    /// Keeps a new look of whichever enabled face this is closest to.
    private func learn(_ embedding: [Float]) {
        let enabled = faces.indices.filter { faces[$0].enabled }
        guard settings.faceIDLearn,
              let index = enabled.max(by: { FaceID.bestMatch(embedding, against: faces[$0].allEmbeddings)
                  < FaceID.bestMatch(embedding, against: faces[$1].allEmbeddings) }),
              let learned = FaceID.learning(embedding, enrolled: faces[index].embeddings, learned: faces[index].learned ?? [])
        else { return }
        faces[index].learned = learned
        FaceIDKeychain.saveFaces(faces)
        Log.lock.info("Face ID learned a new look (\(learned.count) learned)")
    }

    /// Drops everything learned for a face, back to its enrolment.
    func forgetLearned(_ face: EnrolledFace) {
        guard let index = faces.firstIndex(where: { $0.id == face.id }) else { return }
        faces[index].learned = nil
        FaceIDKeychain.saveFaces(faces)
    }

    /// Whether the unlock that just happened was Face ID's (for the island's animation).
    var unlockedByFace: Bool {
        lastAttempt.map { Date().timeIntervalSince($0) < 6 } ?? false
    }

    func trigger(_ trigger: Trigger) {
        // Not while it types: the keys themselves wake the display and would start another look.
        guard settings.faceIDEnabled, isReady, !isScanning, !unlocking, !failedSinceManualUnlock,
              LockScreenState.sessionLocked, cameraAllowed, accessibilityAllowed else { return }
        switch trigger {
        case .wake: guard settings.faceIDOnWake else { return }
        case .lock: guard settings.faceIDOnLock else { return }
        case .click: guard settings.faceIDOnClick else { return }
        }
        Log.lock.info("Face ID looking (\(String(describing: trigger), privacy: .public))")
        scan()
    }

    /// Frames in a row that must match before it unlocks: one lucky frame isn't enough.
    private static let matchStreak = 3

    private func scan() {
        let enrolled = faces.filter(\.enabled).flatMap(\.allEmbeddings)
        let threshold = FaceID.threshold(strictness: settings.faceIDStrictness)
        let square = settings.faceIDStyle == .square
        lesson = nil
        var liveness = LivenessTracker(level: settings.faceIDLiveness)
        var streak = 0
        isScanning = true
        timing = ScanTiming()
        resetBlinkNudge()
        awaitingFreshMatch = false
        // Bring the password field up now, while the camera starts, rather than after the match.
        LockScreenState.declareActivity()
        lockScreen?.showFaceScan(.scanning, square: square)
        let lightCheck = settings.faceIDLiveness == .strict
        let started = runCamera(lookForFrames: settings.faceIDLiveness != .off) { [weak self] sample in
            guard let self, self.isScanning else { return }
            let score = sample.embedding.map { FaceID.bestMatch($0, against: enrolled) }
            self.timing.note(sample, score: score, threshold: threshold)
            guard let score else { return }
            // Liveness only counts frames of the face that matched; anyone else starts it over.
            guard self.recordMatch(sample, score: score, threshold: threshold) else {
                liveness.reset()
                streak = 0
                self.nudgeSince = nil
                return
            }
            streak += 1
            liveness.add(sample.liveness)
            // Light check passed: this frame is a full match (recordMatch's normal bar) of you.
            if self.awaitingFreshMatch, !self.lightChecking {
                self.awaitingFreshMatch = false
                return self.matched(at: sample.time, square: square)
            }
            self.considerBlinkNudge(at: sample.time, matched: streak >= Self.matchStreak, live: liveness.passed)
            // Woken with a key press: keep looking until the keyboard has been quiet for
            // two seconds, so the match is still fresh when it types.
            guard !self.lightChecking, streak >= Self.matchStreak, liveness.passed,
                  LockScreenState.secondsSinceKeyPress >= 2 else { return }
            Log.lock.info("\(self.timing.summary("matched", at: sample.time), privacy: .public)")
            // Only a Strict unlock (blink and light check) teaches it: on Natural a video of
            // you could unlock, and learning from it would make the next one easier.
            self.lesson = lightCheck && score >= threshold + Self.confidentMargin ? sample.embedding : nil
            guard lightCheck else { return self.matched(at: sample.time, square: square) }
            self.runLightCheck { [weak self] verdict in
                guard let self, self.isScanning else { return }
                if verdict.passed {
                    self.awaitingFreshMatch = true
                } else {
                    // Looks like a picture or a video: stop, and let the password be typed by hand.
                    self.finishScan()
                    self.lockScreen?.showFaceScan(.needsPassword, square: square)
                }
            }
        }
        guard started else { return finishScan(hide: true) }
        scanTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.settings.faceIDDuration ?? 5))
            guard let self, !Task.isCancelled, self.isScanning else { return }
            Log.lock.info("\(self.timing.summary("gave up", at: ProcessInfo.processInfo.systemUptime), privacy: .public)")
            self.finishScan(hide: true)
        }
    }

    private func matched(at time: TimeInterval, square: Bool) {
        finishScan()
        lockScreen?.showFaceScan(.matched, square: square)
        unlock(matchedAt: time)
    }

    // MARK: - Light check (Strict)

    @ObservationIgnored private var flashReadings: [FlashChallenge.Reading] = []
    /// When the light check's first colour went up (nil: no check under way).
    @ObservationIgnored private var flashStart: TimeInterval?
    /// A face that isn't the enrolled one showed up during the check.
    @ObservationIgnored private var flashIntruder = false
    @ObservationIgnored private var lightChecking = false
    /// The light check passed: unlock on the next frame that fully matches.
    @ObservationIgnored private var awaitingFreshMatch = false
    /// The lowest score seen while the colours showed (for the log).
    @ObservationIgnored private var flashLowest = 1.0
    /// Where the matched face was in the last frame (normalized).
    @ObservationIgnored private var lastFaceBox: CGRect?

    /// Whether this frame is the enrolled face, keeping its colour for the light check.
    private func recordMatch(_ sample: FaceSample, score: Double, threshold: Double) -> Bool {
        if flashStart != nil {
            // Coloured light wrecks the match score (your own face fell to 5%), so during the
            // flash the face must instead stay put: swapping in a photo or a phone would jump.
            // A full match after the flash is still needed before it unlocks.
            flashLowest = min(flashLowest, score)
            if let box = sample.faceBox, let last = lastFaceBox, !Self.sameSpot(box, last) {
                flashIntruder = true
                return false
            }
        } else if score < threshold {
            lastFaceBox = nil
            return false
        }
        lastFaceBox = sample.faceBox
        // A blink nudge's white flash would skew the light check's baseline.
        if let reading = sample.flashReading, sample.time >= nudgeQuietUntil {
            flashReadings.append(reading)
            flashReadings.removeAll { sample.time - $0.time > 2 }
        }
        return true
    }

    /// The same face from one frame to the next: it can't move a tenth of the picture, or
    /// change size by a fifth, in a thirtieth of a second.
    private static func sameSpot(_ a: CGRect, _ b: CGRect) -> Bool {
        hypot(a.midX - b.midX, a.midY - b.midY) < 0.1 && min(a.width / b.width, b.width / a.width) > 0.8
    }

    // MARK: - Blink nudge

    /// Matched this long with no blink yet: nudge.
    private static let nudgeDelay: TimeInterval = 0.8
    private static let maxNudges = 2
    /// When the face started waiting for a blink (nil: not matched).
    @ObservationIgnored private var nudgeSince: TimeInterval?
    @ObservationIgnored private var nudges = 0
    /// Frames before this show the nudge's flash.
    @ObservationIgnored private var nudgeQuietUntil: TimeInterval = 0

    private func resetBlinkNudge() {
        nudgeSince = nil
        nudges = 0
        nudgeQuietUntil = 0
    }

    /// Your face matched but liveness still wants a blink: after a moment, a quick white
    /// flash, which makes eyes blink on their own, instead of waiting for a natural one.
    private func considerBlinkNudge(at time: TimeInterval, matched: Bool, live: Bool) {
        guard settings.faceIDBlinkNudge, settings.faceIDLiveness != .off, !lightChecking, matched, !live else {
            if !matched { nudgeSince = nil }
            return
        }
        let since = nudgeSince ?? time
        nudgeSince = since
        guard nudges < Self.maxNudges, time - since >= Self.nudgeDelay else { return }
        nudges += 1
        nudgeSince = time
        // The flash, then camera delay, before frames are clean again.
        nudgeQuietUntil = ProcessInfo.processInfo.systemUptime + 0.12 + 0.25
        lockScreen?.flash(NSColor(white: 1, alpha: 0.9))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !self.lightChecking else { return }
            self.lockScreen?.flash(nil)
        }
    }

    /// Shows two colours in random order, then judges the frames that came in meanwhile.
    private func runLightCheck(done: @escaping @MainActor (FlashChallenge.Verdict) -> Void) {
        let challenge = FlashChallenge.random()
        flashIntruder = false
        flashLowest = 1
        lightChecking = true
        Task { @MainActor [weak self] in
            defer { self?.lightChecking = false; self?.flashStart = nil }
            for (index, tint) in challenge.tints.enumerated() {
                self?.lockScreen?.flash(tint.color)
                if index == 0 { self?.flashStart = ProcessInfo.processInfo.systemUptime }
                try? await Task.sleep(for: .seconds(FlashChallenge.step))
            }
            self?.lockScreen?.flash(nil)
            try? await Task.sleep(for: .seconds(FlashChallenge.delay + 0.05))
            guard let self, let start = self.flashStart else { return }
            var verdict = challenge.verdict(self.flashReadings, start: start)
            if self.flashIntruder {
                verdict.passed = false
                verdict.reason = "another face appeared"
            }
            let shifts = verdict.shifts.map { String(format: "%.3f", $0) }.joined(separator: ", ")
            Log.lock.info("Face ID light check \(challenge.tints.map { "\($0)" }.joined(separator: "→"), privacy: .public): \(verdict.passed ? "passed" : "failed", privacy: .public), \(verdict.reason, privacy: .public) [\(shifts, privacy: .public)], lowest match during it \(Int((self.flashLowest * 100).rounded()))%")
            done(verdict)
        }
    }

    private func finishScan(hide: Bool = false) {
        isScanning = false
        scanTask?.cancel()
        lockScreen?.flash(nil)
        stopCamera()
        if hide { lockScreen?.hideFaceScan() }
    }

    private func unlock(matchedAt: TimeInterval) {
        LockScreenState.declareActivity()
        // The password field needs about 450 ms from the wake at the scan's start; a match
        // that comes sooner waits out the rest.
        let wait = max(0, 0.45 - (matchedAt - timing.start))
        unlocking = true
        Task { @MainActor [weak self] in
            defer { self?.unlocking = false }
            var waited = wait
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            // The display may have gone to sleep at the lock screen; keys typed while it
            // wakes are lost, so wake it first and give the password field a moment.
            if LockScreenState.displayAsleep {
                let began = ProcessInfo.processInfo.systemUptime
                while LockScreenState.displayAsleep, ProcessInfo.processInfo.systemUptime - began < 1.5 {
                    LockScreenState.declareActivity()
                    try? await Task.sleep(for: .milliseconds(50))
                }
                try? await Task.sleep(for: .milliseconds(400))
                waited += ProcessInfo.processInfo.systemUptime - began
            }
            guard let self else { return }
            let gate = FaceUnlockGate(
                sessionLocked: LockScreenState.sessionLocked,
                lockWindowOnScreen: LockScreenState.lockWindowOnScreen,
                secondsSinceKeyPress: LockScreenState.secondsSinceKeyPress,
                secondsSinceMatch: ProcessInfo.processInfo.systemUptime - matchedAt - waited,
                failedSinceManualUnlock: self.failedSinceManualUnlock)
            if let refusal = gate.refusal {
                Log.lock.info("Face ID matched but won't type: \(String(describing: refusal), privacy: .public)")
                self.lockScreen?.hideFaceScan()
                return
            }
            guard let data = FaceIDKeychain.load(account: FaceIDKeychain.passwordAccount),
                  let password = String(data: data, encoding: .utf8) else {
                // Unreadable (saved by a differently signed build): Settings asks for it again.
                Log.lock.error("Face ID can't read the saved password; it needs saving again")
                self.hasPassword = false
                self.lockScreen?.showFaceScan(.needsPassword, square: self.settings.faceIDStyle == .square)
                return
            }
            self.lastAttempt = Date()
            let typed = KeyTyper.type(password, pressReturn: true, requireLocked: true)
            let since = Int(((ProcessInfo.processInfo.systemUptime - self.timing.start) * 1000).rounded())
            Log.lock.info("Face ID typed the password: \(typed) (\(since) ms after it started looking)")
            // Still locked a few seconds later: the password is wrong (changed?). Stop
            // until the Mac is unlocked by hand, rather than piling up failed attempts.
            try? await Task.sleep(for: .seconds(3))
            if LockScreenState.sessionLocked {
                self.failedSinceManualUnlock = true
                self.lastAttempt = nil
                self.lockScreen?.showFaceScan(.needsPassword, square: self.settings.faceIDStyle == .square)
                Log.lock.error("Face ID unlock didn't take; waiting for an unlock by hand")
            }
        }
    }

    // MARK: - Camera

    private func runCamera(lookForFrames: Bool, handle: @escaping @MainActor (FaceSample) -> Void) -> Bool {
        if engine == nil { engine = FaceEngine() }
        guard let engine else {
            Log.lock.error("Face ID model missing from the app")
            return false
        }
        let camera = FaceCamera()
        self.camera = camera
        return camera.start(onFrame: Self.frameHandler(engine: engine, lookForFrames: lookForFrames, handle: handle))
    }

    /// Made outside the main actor: the camera calls it on its own queue.
    nonisolated private static func frameHandler(engine: FaceEngine, lookForFrames: Bool,
                                                 handle: @escaping @MainActor (FaceSample) -> Void)
        -> @Sendable (CVPixelBuffer, TimeInterval) -> Void {
        { buffer, time in
            var sample = engine.analyze(buffer, time: time, lookForFrames: lookForFrames)
            sample.cost = ProcessInfo.processInfo.systemUptime - time
            Task { @MainActor [sample] in handle(sample) }
        }
    }

    private func stopCamera() {
        camera?.stop()
        camera = nil
        // The model and Vision's buffers are megabytes; keep them only while locked, when the
        // next look may come any moment. `locked()` loads them again.
        if !LockScreenState.sessionLocked { engine = nil }
    }

    nonisolated private static func loadEngine() async -> FaceEngine? { FaceEngine() }

    // MARK: - Setup

    func requestCamera() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        Log.lock.info("Face ID camera permission: \(status.rawValue, privacy: .public)")
        switch status {
        case .authorized: return true
        case .notDetermined:
            // A background app's prompt can land behind other windows.
            NSApp.activate()
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            // Denied before: macOS never asks twice, so send them to the switch.
            Self.openPrivacy("Privacy_Camera")
            return false
        }
    }

    func requestAccessibility() {
        // The prompt only ever appears once, so also open the list itself.
        if !AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) {
            Self.openPrivacy("Privacy_Accessibility")
        }
    }

    private static func openPrivacy(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Checks the password against this Mac's account, then keeps it in the Keychain.
    func savePassword(_ password: String) -> Bool {
        guard MacPassword.verify(password) else { return false }
        hasPassword = FaceIDKeychain.save(Data(password.utf8), account: FaceIDKeychain.passwordAccount)
        failedSinceManualUnlock = false
        return hasPassword
    }

    /// The session camera for the setup preview, while enrolling.
    var previewSession: AVCaptureSession? { camera?.session }

    /// Enrolment: look around slowly while it captures the face from nine directions
    /// (straight on, and up, down, left, right and the diagonals).
    /// Fingerprints averaged per direction: a direction counts once it has `enrolMinimum`,
    /// taken at least `enrolSpacing` apart so they aren't near-copies of one frame.
    private static let enrolMinimum = 3, enrolMaximum = 5
    private static let enrolSpacing: TimeInterval = 0.12
    /// The camera's first moments are dark while it settles its exposure.
    private static let enrolWarmUp: TimeInterval = 0.6

    func beginEnrolment() {
        guard !enrolling else { return }
        resetEnrolment()
        enrolling = true
        let started = runCamera(lookForFrames: false) { [weak self] sample in
            guard let self, self.enrolling else { return }
            let start = self.enrolStart ?? sample.time
            self.enrolStart = start
            guard sample.time - start >= Self.enrolWarmUp, let embedding = sample.embedding else { return }
            let baseline = self.enrolBaseline ?? (sample.yaw, sample.pitch)
            self.enrolBaseline = baseline
            let direction = Self.direction(yaw: sample.yaw - baseline.yaw, pitch: sample.pitch - baseline.pitch)
            let taken = self.enrolSamples[direction, default: []]
            guard taken.count < Self.enrolMaximum,
                  sample.time - (self.enrolLastSample[direction] ?? 0) >= Self.enrolSpacing else { return }
            self.enrolSamples[direction] = taken + [embedding]
            self.enrolLastSample[direction] = sample.time
            if taken.count + 1 >= Self.enrolMinimum { self.enrolledDirections.insert(direction) }
        }
        if !started { enrolling = false }
    }

    /// Ends enrolment and keeps the face if enough of it was seen.
    func finishEnrolment(name: String) -> Bool {
        enrolling = false
        stopCamera()
        let directions = enrolSamples.values.filter { $0.count >= Self.enrolMinimum }
        resetEnrolment()
        guard directions.count >= 4 else { return false }
        let label = name.trimmingCharacters(in: .whitespaces)
        faces.append(EnrolledFace(name: label.isEmpty ? "Face \(faces.count + 1)" : label,
                                  embeddings: directions.map(FaceID.mean)))
        FaceIDKeychain.saveFaces(faces)
        return true
    }

    func cancelEnrolment() {
        enrolling = false
        resetEnrolment()
        stopCamera()
    }

    private func resetEnrolment() {
        enrolSamples = [:]
        enrolLastSample = [:]
        enrolStart = nil
        enrolBaseline = nil
        enrolledDirections = []
    }

    /// 0 straight on; 1–8 around it, like a clock face.
    private static func direction(yaw: Double, pitch: Double) -> Int {
        let side = yaw > 9 ? 1 : yaw < -9 ? -1 : 0
        let tilt = pitch > 7 ? 1 : pitch < -7 ? -1 : 0
        switch (side, tilt) {
        case (0, 0): return 0
        case (0, -1): return 1
        case (1, -1): return 2
        case (1, 0): return 3
        case (1, 1): return 4
        case (0, 1): return 5
        case (-1, 1): return 6
        case (-1, 0): return 7
        default: return 8
        }
    }

    func setEnabled(_ face: EnrolledFace, _ on: Bool) {
        guard let index = faces.firstIndex(where: { $0.id == face.id }) else { return }
        faces[index].enabled = on
        FaceIDKeychain.saveFaces(faces)
    }

    func delete(_ face: EnrolledFace) {
        faces.removeAll { $0.id == face.id }
        FaceIDKeychain.saveFaces(faces)
    }

    /// Turn Off and Forget: the faces and the password leave the Keychain.
    func forgetEverything() {
        cancelEnrolment()
        settings.faceIDEnabled = false
        FaceIDKeychain.delete(account: FaceIDKeychain.passwordAccount)
        FaceIDKeychain.delete(account: FaceIDKeychain.facesAccount)
        faces = FaceIDKeychain.loadFaces()
        hasPassword = FaceIDKeychain.exists(account: FaceIDKeychain.passwordAccount)
        failedSinceManualUnlock = false
    }

    /// Looks for a few seconds and reports how closely the face matched, without
    /// unlocking anything.
    func test() {
        guard !isScanning, !enrolling else { return }
        let enrolled = faces.filter(\.enabled).flatMap(\.allEmbeddings)
        let threshold = FaceID.threshold(strictness: settings.faceIDStrictness)
        var liveness = LivenessTracker(level: settings.faceIDLiveness)
        var best = -1.0
        var frames = 0, seen = 0
        var light: FlashChallenge.Verdict?
        var realSum = 0.0, realCount = 0
        isScanning = true
        resetBlinkNudge()
        testReport = "Looking…"
        let started = runCamera(lookForFrames: settings.faceIDLiveness != .off) { [weak self] sample in
            guard let self, self.isScanning else { return }
            frames += 1
            liveness.add(sample.liveness)
            if let realness = sample.realness { realSum += realness; realCount += 1 }
            if let embedding = sample.embedding {
                seen += 1
                let score = FaceID.bestMatch(embedding, against: enrolled)
                best = max(best, score)
                let matched = self.recordMatch(sample, score: score, threshold: threshold)
                self.considerBlinkNudge(at: sample.time, matched: matched, live: liveness.passed)
            }
            self.testReport = Self.report(best: best, threshold: threshold, seen: seen, frames: frames, liveness: liveness)
        }
        guard started else {
            isScanning = false
            testReport = "The camera isn't available."
            return
        }
        Task { @MainActor [weak self] in
            // Strict: halfway through, the light check, judged like the lock screen's.
            try? await Task.sleep(for: .seconds(2))
            if let self, self.isScanning, self.settings.faceIDLiveness == .strict {
                self.runLightCheck { light = $0 }
            }
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            self.isScanning = false
            self.lockScreen?.flash(nil)
            self.stopCamera()
            self.testReport = Self.report(best: best, threshold: threshold, seen: seen, frames: frames, liveness: liveness,
                                          light: light, done: true)
                + (realCount > 0 ? " Looks live: \(Int((realSum / Double(realCount) * 100).rounded()))%." : "")
        }
    }

    private static func report(best: Double, threshold: Double, seen: Int, frames: Int,
                               liveness: LivenessTracker, light: FlashChallenge.Verdict? = nil, done: Bool = false) -> String {
        guard seen > 0 else { return done ? "No face found. Sit in front of the camera, in good light." : "Looking…" }
        let match = best >= threshold
        let score = "Match \(Int((max(best, 0) * 100).rounded()))% (needs \(Int((threshold * 100).rounded()))%)"
        let lightPassed = light?.passed ?? true
        let verdict = !match ? "Not a match."
            : !liveness.passed ? "Matched, but liveness didn't pass — blink" + (liveness.level == .strict ? "." : " or move a little.")
            : !lightPassed ? "Matched, but the light check failed (\(light?.reason ?? ""))."
            : "Would unlock."
        return done ? "\(score). \(verdict)" : "\(score) · liveness: \(liveness.summary)"
    }
}

/// When each step of one look happened, for a single log line per attempt, so a slow
/// unlock shows where the time went (camera start, finding the face, liveness).
struct ScanTiming {
    let start = ProcessInfo.processInfo.systemUptime
    private var firstFrame: TimeInterval?
    private var firstFace: TimeInterval?
    private var firstMatch: TimeInterval?
    private var frames = 0
    private var cost = 0.0
    private(set) var best = -1.0
    private var realSum = 0.0, realCount = 0

    mutating func note(_ sample: FaceSample, score: Double?, threshold: Double) {
        frames += 1
        cost += sample.cost
        if let realness = sample.realness { realSum += realness; realCount += 1 }
        if firstFrame == nil { firstFrame = sample.time }
        guard let score else { return }
        if firstFace == nil { firstFace = sample.time }
        if score >= threshold, firstMatch == nil { firstMatch = sample.time }
        best = max(best, score)
    }

    func summary(_ outcome: String, at time: TimeInterval) -> String {
        func ms(_ t: TimeInterval?) -> String { t.map { "\(Int((($0 - start) * 1000).rounded())) ms" } ?? "never" }
        let perFrame = frames > 0 ? Int((cost / Double(frames) * 1000).rounded()) : 0
        return "Face ID \(outcome) after \(ms(time)): first frame \(ms(firstFrame)), face \(ms(firstFace)), "
            + "match \(ms(firstMatch)), best \(Int((best * 100).rounded()))%, \(frames) frames at \(perFrame) ms each"
            + (realCount > 0 ? ", looks live \(Int((realSum / Double(realCount) * 100).rounded()))%" : "")
    }
}

extension FlashChallenge.Tint {
    /// Pure, full-strength colours: the biggest change in the light on the face.
    var color: NSColor {
        switch self {
        case .red: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        case .green: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
        case .blue: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        }
    }
}
