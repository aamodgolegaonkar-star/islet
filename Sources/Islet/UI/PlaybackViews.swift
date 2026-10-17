import AVFoundation
import IsletCore
import SwiftUI

/// Redraws its content on the playback clock only: `steps` times per played second,
/// aligned to whole seconds so time labels tick evenly, and not at all while paused. A bar
/// a few hundred points wide moves well under a pixel per step, so this looks continuous.
///
/// A sleeping task rather than a TimelineView: on macOS 27 any TimelineView keeps a
/// display-rate update loop running (measured: ~60 layouts a second for 4 visible changes),
/// while this wakes exactly once per tick.
struct PlaybackClock<Content: View>: View {
    var timing: PlaybackTiming?
    var steps: Int
    @ViewBuilder var content: (Date) -> Content
    @State private var now = Date()

    private struct Key: Equatable {
        var timing: PlaybackTiming?
        var steps: Int
    }

    var body: some View {
        // Battery saver: whole seconds only.
        let steps = LiveTuning.shared.batterySaving ? 1 : self.steps
        content(now)
            .task(id: Key(timing: timing, steps: steps)) {
                now = Date()
                guard let timing else { return }
                while let next = timing.nextTick(after: now, steps: steps) {
                    try? await Task.sleep(until: .now + .seconds(next.timeIntervalSinceNow),
                                          tolerance: .milliseconds(12))
                    guard !Task.isCancelled else { return }
                    // Never earlier than the tick, so whole seconds show on time.
                    now = max(Date(), next)
                }
            }
    }
}

/// Glass scrubber with elapsed / remaining labels, driven by the store's interpolated clock.
struct ScrubberRow: View {
    let store: PlayerStore
    var large = false
    var groove = false
    var thumb: GlassSlider.Thumb = .onHover
    /// Redraws per played second (see `PlaybackClock`).
    var steps = 4
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var preview: Double?

    var body: some View {
        PlaybackClock(timing: store.timing, steps: steps) { date in
            let duration = store.duration
            let elapsed = store.elapsed(at: date)
            let shown = preview.map { $0 * duration } ?? elapsed
            VStack(spacing: large ? 6 : 2) {
                GlassSlider(
                    value: duration > 0 ? elapsed / duration : 0,
                    restHeight: large ? 7 : 5,
                    activeHeight: large ? 14 : 10,
                    groove: groove,
                    thumb: thumb,
                    onEditingChanged: onEditingChanged,
                    onPreview: { preview = $0 },
                    onCommit: { store.seek(to: $0 * duration) })
                HStack {
                    Text(TimeText.string(shown))
                    Spacer()
                    Text(TimeText.remaining(shown, duration: duration))
                }
                .font(.system(size: large ? 12 : 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(preview == nil ? 0.5 : 0.85))
            }
        }
    }
}

/// Scrubber with elapsed and remaining time inline on either side of the bar, as in the
/// iPhone's Now Playing activity.
struct InlineScrubber: View {
    let store: PlayerStore
    var thumb: GlassSlider.Thumb = .onHover
    var fontSize: CGFloat = 11
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var preview: Double?

    var body: some View {
        PlaybackClock(timing: store.timing, steps: 4) { date in
            let duration = store.duration
            let elapsed = store.elapsed(at: date)
            let shown = preview.map { $0 * duration } ?? elapsed
            HStack(spacing: 9) {
                Text(TimeText.string(shown))
                    .frame(width: fontSize * 3.4, alignment: .trailing)
                GlassSlider(
                    value: duration > 0 ? elapsed / duration : 0,
                    restHeight: 5, activeHeight: 10, thumb: thumb,
                    onEditingChanged: onEditingChanged,
                    onPreview: { preview = $0 },
                    onCommit: { store.seek(to: $0 * duration) })
                Text(TimeText.remaining(shown, duration: duration))
                    .frame(width: fontSize * 3.8, alignment: .leading)
            }
            .font(.system(size: fontSize, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(preview == nil ? 0.55 : 0.9))
        }
    }
}

/// Previous / play-pause / next with glass press feedback.
struct TransportRow: View {
    let store: PlayerStore
    var scale: CGFloat = 1
    /// Use `.highlight` when the row already sits inside a glass surface.
    var look: GlassButtonLook = .glassOnHover
    /// False while the row is hidden (the island's capsule tucked behind the pill).
    var clickable = true
    @Environment(\.clickRouter) private var router

    var body: some View {
        HStack(spacing: 22 * scale) {
            Button { tap("previous") { store.previous() } } label: {
                Image(systemName: "backward.fill").font(.system(size: 19 * scale))
            }
            .buttonStyle(GlassIconButtonStyle(diameter: 42 * scale, look: look))
            .probeFrame("previous")
            .routedClick("previous", enabled: clickable) { store.previous() }

            Button { tap("playPause") { store.togglePlayPause() } } label: {
                Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 27 * scale))
                    .contentTransition(.symbolEffect(.replace.downUp))
            }
            .buttonStyle(GlassIconButtonStyle(diameter: 52 * scale, look: look))
            .probeFrame("playPause")
            .routedClick("playPause", enabled: clickable) { store.togglePlayPause() }

            Button { tap("next") { store.next() } } label: {
                Image(systemName: "forward.fill").font(.system(size: 19 * scale))
            }
            .buttonStyle(GlassIconButtonStyle(diameter: 42 * scale, look: look))
            .probeFrame("next")
            .routedClick("next", enabled: clickable) { store.next() }
        }
        .labelStyle(.iconOnly)
    }

    private func tap(_ id: String, _ action: () -> Void) {
        if let router { router.run(id, action) } else { action() }
    }
}

/// Transport buttons in one capsule of stock Liquid Glass.
struct GlassControlsCapsule: View {
    let store: PlayerStore
    var scale: CGFloat = 1

    var body: some View {
        TransportRow(store: store, scale: scale, look: .highlight)
            .padding(.horizontal, 12 * scale)
            .padding(.vertical, 4 * scale)
            .snapshotSafeGlass(.islet, in: Capsule())
    }
}

/// System volume on a glass slider between speaker glyphs.
struct VolumeRow: View {
    let store: PlayerStore
    var groove = false
    var thumb: GlassSlider.Thumb = .always

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
            GlassSlider(value: store.volume, restHeight: 6, activeHeight: 12, groove: groove, thumb: thumb,
                        onChange: { store.setVolume($0) },
                        onCommit: { store.setVolume($0) })
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white.opacity(0.6))
    }
}

/// Four bouncing bars in the artwork's accent color, as in the iPhone Now Playing activity.
struct EqualizerBars: View {
    var isPlaying: Bool
    var color: Color
    @Environment(\.isSnapshotRendering) private var snapshot

    var body: some View {
        if snapshot {
            // ImageRenderer can't draw AppKit views: the bars at rest.
            GeometryReader { geo in
                HStack(spacing: geo.size.width * 0.13) {
                    ForEach(0..<4, id: \.self) { i in
                        Capsule().fill(color.gradient)
                            .frame(height: max(geo.size.width * 0.16, geo.size.height * EqualizerView.rest[i]))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        } else {
            EqualizerLayers(isPlaying: isPlaying, color: NSColor(color))
        }
    }
}

private struct EqualizerLayers: NSViewRepresentable {
    var isPlaying: Bool
    var color: NSColor

    func makeNSView(context: Context) -> EqualizerView { EqualizerView() }

    func updateNSView(_ view: EqualizerView, context: Context) {
        view.update(isPlaying: isPlaying, color: color,
                    reduceMotion: context.environment.accessibilityReduceMotion,
                    saving: LiveTuning.shared.batterySaving)
    }
}

/// The equalizer as Core Animation layers: the bounce loops in the render server, so it
/// costs the app no CPU while music plays, and it stops whenever the window can't be seen.
final class EqualizerView: NSView {
    static let rest: [CGFloat] = [0.3, 0.5, 0.38, 0.26]
    /// Loop length per bar; unequal lengths keep the four from ever falling into step.
    private static let periods: [CFTimeInterval] = [1.19, 0.89, 1.43, 1.01]
    private static let phases: [Double] = [0, 1.9, 3.3, 4.6]
    /// Fixed levels shown instead of the bounce when Reduce Motion is on.
    private static let still: [CGFloat] = [0.55, 0.85, 0.65, 0.45]

    private let bars: [CAGradientLayer] = (0..<4).map { _ in CAGradientLayer() }
    private var isPlaying = false
    private var reduceMotion = false
    private var saving = false
    private var color: NSColor?
    private var laidOutSize: CGSize = .zero
    /// Whether the loops are running (playing, motion allowed, window on screen).
    private var moving = false
    /// Layer time at which the loops began, so a relayout continues them in phase.
    private var loopStart: CFTimeInterval = 0
    private var occlusionObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for bar in bars {
            // Geometry is set explicitly; only colour changes fade.
            bar.actions = ["bounds": NSNull(), "position": NSNull(), "cornerRadius": NSNull()]
            bar.startPoint = CGPoint(x: 0.5, y: 1)
            bar.endPoint = CGPoint(x: 0.5, y: 0)
            layer?.addSublayer(bar)
        }
    }

    required init?(coder: NSCoder) { nil }

    // Taps belong to the SwiftUI views around the bars.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(isPlaying: Bool, color: NSColor, reduceMotion: Bool, saving: Bool) {
        if color != self.color {
            self.color = color
            let top = color.blended(withFraction: 0.14, of: .white) ?? color
            let bottom = color.blended(withFraction: 0.14, of: .black) ?? color
            for bar in bars { bar.colors = [top.cgColor, bottom.cgColor] }
        }
        // With Reduce Motion the resting levels themselves depend on playing.
        let restChanged = (reduceMotion || self.reduceMotion) && isPlaying != self.isPlaying
        let rateChanged = saving != self.saving && moving
        self.isPlaying = isPlaying
        self.reduceMotion = reduceMotion
        self.saving = saving
        refreshMotion(force: restChanged || rateChanged)
    }

    /// Starts or stops the bounce when whether it should run has changed.
    private func refreshMotion(force: Bool = false) {
        let shouldMove = isPlaying && !reduceMotion && window?.occlusionState.contains(.visible) == true
        guard shouldMove != moving || force else { return }
        moving = shouldMove
        applyMotion(transition: true)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        guard let window else { return }
        // Hidden island (screen locked, display asleep): stop, and pick up again on return.
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMotion() }
        }
        refreshMotion()
    }

    override func layout() {
        super.layout()
        guard bounds.size != laidOutSize, bounds.width > 0, bounds.height > 0 else { return }
        laidOutSize = bounds.size
        let spacing = bounds.width * 0.13
        let width = (bounds.width - spacing * 3) / 4
        for (i, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: width, height: height(level: restLevel(i)))
            bar.position = CGPoint(x: CGFloat(i) * (width + spacing) + width / 2, y: bounds.midY)
            bar.cornerRadius = width / 2
        }
        applyMotion(transition: false)
    }

    private func height(level: CGFloat) -> CGFloat {
        max(bounds.width * 0.16, bounds.height * min(max(level, 0.16), 1))
    }

    private func restLevel(_ i: Int) -> CGFloat {
        isPlaying && reduceMotion ? Self.still[i] : Self.rest[i]
    }

    /// One loop of bar `i`: two harmonics of its own period, so it repeats seamlessly.
    private func loopHeights(_ i: Int) -> [CGFloat] {
        (0...24).map { step in
            let x = 2 * Double.pi * Double(step) / 24 + Self.phases[i]
            return height(level: CGFloat(0.52 + 0.27 * sin(x) + 0.16 * sin(2 * x)))
        }
    }

    /// Starts, resumes or stops the bounce. `transition` eases between rest and motion;
    /// otherwise running loops are re-added in phase (after a relayout).
    private func applyMotion(transition: Bool) {
        guard bounds.width > 0, bounds.height > 0, let layer else { return }
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        let blendTime: CFTimeInterval = 0.22
        if moving, transition || loopStart == 0 { loopStart = now + (transition ? blendTime : 0) }
        for (i, bar) in bars.enumerated() {
            let shown = bar.presentation()?.bounds.height ?? bar.bounds.height
            bar.removeAllAnimations()
            bar.bounds.size.height = height(level: restLevel(i))
            guard moving else {
                if transition { bar.add(spring(from: shown, to: bar.bounds.height), forKey: "settle") }
                continue
            }
            let loop = CAKeyframeAnimation(keyPath: "bounds.size.height")
            loop.values = loopHeights(i)
            loop.duration = Self.periods[i]
            loop.calculationMode = .cubic
            loop.repeatCount = .infinity
            loop.beginTime = loopStart
            loop.preferredFrameRateRange = saving
                ? CAFrameRateRange(minimum: 8, maximum: 12, preferred: 10)
                : CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
            if transition {
                // Ease from wherever the bar is into the loop's first frame, then hand over.
                let blend = CABasicAnimation(keyPath: "bounds.size.height")
                blend.fromValue = shown
                blend.toValue = loopHeights(i)[0]
                blend.duration = blendTime
                blend.timingFunction = CAMediaTimingFunction(name: .easeOut)
                bar.add(blend, forKey: "blend")
            }
            bar.add(loop, forKey: "loop")
        }
    }

    private func spring(from: CGFloat, to: CGFloat) -> CASpringAnimation {
        let spring = CASpringAnimation(keyPath: "bounds.size.height")
        spring.fromValue = from
        spring.toValue = to
        spring.stiffness = 260
        spring.damping = 22
        spring.duration = spring.settlingDuration
        return spring
    }
}

/// Album artwork that plays the motion (video) version on top when one is available.
struct CoverArtView: View {
    let image: NSImage?
    var motionURL: URL?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [.gray.opacity(0.5), .gray.opacity(0.25)], startPoint: .top, endPoint: .bottom)
                    .overlay(Image(systemName: "music.note").font(.system(size: 22)).foregroundStyle(.white.opacity(0.6)))
            }
            if let motionURL, !LiveTuning.shared.batterySaving {
                LoopingVideoView(url: motionURL)
            }
        }
        .clipped()
    }
}

/// Muted, looping HLS video layer for motion artwork. Players are shared per URL so the
/// cover and the background stay in sync without decoding the stream twice.
struct LoopingVideoView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> VideoLayerView {
        let view = VideoLayerView()
        view.attach(VideoLooperPool.shared.player(for: url))
        return view
    }

    func updateNSView(_ view: VideoLayerView, context: Context) {
        view.attach(VideoLooperPool.shared.player(for: url))
    }

    final class VideoLayerView: NSView {
        private let playerLayer = AVPlayerLayer()
        private var readyObservation: NSKeyValueObservation?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspectFill
            playerLayer.opacity = 0
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { nil }

        func attach(_ player: AVPlayer) {
            guard playerLayer.player !== player else { return }
            playerLayer.player = player
            playerLayer.opacity = 0
            // Fade in only once a frame is ready, so slow networks show the still cover.
            readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
                guard layer.isReadyForDisplay else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.fadeIn() }
                }
            }
        }

        private func fadeIn() {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.6)
            playerLayer.opacity = 1
            CATransaction.commit()
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }
}

@MainActor
final class VideoLooperPool {
    static let shared = VideoLooperPool()
    private var players: [URL: (player: AVQueuePlayer, looper: AVPlayerLooper)] = [:]

    func player(for url: URL) -> AVQueuePlayer {
        if let existing = players[url] { return existing.player }
        // Keep only the current track's video alive.
        for (_, entry) in players { entry.player.pause() }
        players.removeAll()

        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        let item = AVPlayerItem(url: url)
        item.preferredMaximumResolution = CGSize(width: 1600, height: 1600)
        let looper = AVPlayerLooper(player: player, templateItem: item)
        players[url] = (player, looper)
        player.play()
        return player
    }
}
