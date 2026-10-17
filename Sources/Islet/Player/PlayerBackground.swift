import CoreImage
import IsletCore
import SwiftUI

/// The full-screen backdrop. During the hero it starts as the sharp artwork, then blurs
/// and dissolves into the fluid palette background (or the motion artwork video).
struct PlayerBackground: View {
    let store: PlayerStore
    let isOpen: Bool

    var body: some View {
        ZStack {
            Color.black
            if let art = store.displayArtwork {
                // Visible mostly during the transition; the fluid layer then covers it.
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: isOpen ? 50 : 0, opaque: true)
                    .opacity(isOpen ? 0 : 1)
                    .animation(.easeIn(duration: 0.55).delay(isOpen ? 0.2 : 0), value: isOpen)
            }
            FluidBackground(palette: store.palette, artwork: store.displayArtwork)
                .opacity(isOpen ? 1 : 0)
            if !LiveTuning.shared.batterySaving, let tall = store.motion?.tall ?? store.motion?.square {
                // Motion artwork: the background itself moves.
                LoopingVideoView(url: tall)
                    .blur(radius: 18, opaque: true)
                    .opacity(isOpen ? 0.9 : 0)
            }
            LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.32)], startPoint: .top, endPoint: .bottom)
                .opacity(isOpen ? 1 : 0)
        }
        .clipped()
    }
}

/// The album cover itself, blurred and slowly moving, filling the screen — two copies
/// drift, rotate and breathe in opposite directions, like Apple Music. When the song
/// changes the old cover cross-fades into the new one; without artwork it falls back to
/// the palette colors.
///
/// The cover is blurred once per song and the motion runs as Core Animation in the render
/// server at up to 30 fps, so the app does no per-frame work at all. Also the glow behind
/// the open glass island.
struct FluidBackground: View {
    let palette: Palette
    let artwork: NSImage?
    @Environment(\.isSnapshotRendering) private var snapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if snapshot {
            // ImageRenderer can't draw AppKit views: one still frame.
            ZStack {
                gradient
                if let artwork {
                    Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 240, height: 240).blur(radius: 6, opaque: true).saturation(1.3)
                        .scaleEffect(9)
                }
                Color.black.opacity(0.2)
            }
            .clipped()
        } else {
            FluidLayers(colors: palette.colors.prefix(3).map { NSColor(Color(rgb: $0)).cgColor },
                        artwork: artwork, animated: !reduceMotion, slow: LiveTuning.shared.batterySaving)
        }
    }

    private var gradient: LinearGradient {
        LinearGradient(colors: palette.colors.prefix(3).map { Color(rgb: $0) },
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

private struct FluidLayers: NSViewRepresentable {
    var colors: [CGColor]
    var artwork: NSImage?
    var animated: Bool
    var slow: Bool

    func makeNSView(context: Context) -> FluidBackgroundView { FluidBackgroundView() }

    func updateNSView(_ view: FluidBackgroundView, context: Context) {
        view.update(colors: colors, artwork: artwork, animated: animated, slow: slow)
    }
}

final class FluidBackgroundView: NSView {
    private let gradient = CAGradientLayer()
    private let dim = CALayer()
    /// One scene (two moving copies of a cover) per artwork; old scenes fade out.
    private var scene: CALayer?
    private var artwork: NSImage?
    private var animated = true
    /// Battery Saver: the same motion at a lower frame rate.
    private var slow = false
    private var blurTask: Task<Void, Never>?
    private var occlusionObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        dim.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
        for sublayer in [gradient, dim] {
            sublayer.actions = ["bounds": NSNull(), "position": NSNull()]
            layer?.addSublayer(sublayer)
        }
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(colors: [CGColor], artwork: NSImage?, animated: Bool, slow: Bool) {
        if gradient.colors as? [CGColor] != colors { gradient.colors = colors }
        let motionChanged = animated != self.animated || slow != self.slow
        self.animated = animated
        self.slow = slow
        if artwork !== self.artwork {
            self.artwork = artwork
            loadScene(for: artwork)
        } else if motionChanged, let scene {
            scene.sublayers?.forEach(applyDrift)
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        dim.frame = bounds
        if let scene { layoutScene(scene) }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        guard let window else { return }
        // Nothing to animate while the window is hidden; resume where it would be.
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let scene = self.scene else { return }
                let visible = self.window?.occlusionState.contains(.visible) == true
                scene.speed = visible ? 1 : 0
            }
        }
    }

    // MARK: - Scenes

    private func loadScene(for artwork: NSImage?) {
        blurTask?.cancel()
        guard let artwork, let source = artwork.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            show(nil)
            return
        }
        blurTask = Task { [weak self] in
            let blurred = await Task.detached(priority: .userInitiated) { CoverBlur.make(from: source) }.value
            guard let self, !Task.isCancelled, self.artwork === artwork else { return }
            self.show(blurred)
        }
    }

    /// Cross-fades from the current scene to one built from `image` (nil: just the gradient).
    private func show(_ image: CGImage?) {
        let old = scene
        scene = nil
        if let image {
            let next = CALayer()
            next.actions = ["bounds": NSNull(), "position": NSNull()]
            for (index, opacity) in [(0, Float(1)), (1, Float(0.35))] {
                let copy = CALayer()
                copy.contents = image
                copy.contentsGravity = .resizeAspectFill
                copy.magnificationFilter = .linear
                copy.opacity = opacity
                copy.name = "\(index)"
                copy.actions = ["bounds": NSNull(), "position": NSNull(), "transform": NSNull()]
                next.addSublayer(copy)
            }
            layer?.insertSublayer(next, below: dim)
            layoutScene(next)
            next.sublayers?.forEach(applyDrift)
            fade(next, from: 0, to: 1)
            scene = next
        }
        if let old {
            fade(old, from: old.presentation()?.opacity ?? old.opacity, to: 0) { old.removeFromSuperlayer() }
        }
    }

    private func fade(_ layer: CALayer, from: Float, to: Float, completion: (() -> Void)? = nil) {
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = 1.2
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.opacity = to
        layer.add(animation, forKey: "fade")
        CATransaction.commit()
    }

    /// Each copy is a square large enough that its edges never come on screen while it
    /// turns (its side covers the view's diagonal) and drifts; the second is flipped,
    /// larger, and moves the other way.
    private func layoutScene(_ scene: CALayer) {
        scene.frame = bounds
        let diagonal = hypot(bounds.width, bounds.height)
        for copy in scene.sublayers ?? [] {
            let side = diagonal * (copy.name == "0" ? 1.35 : 1.6)
            copy.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            copy.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        scene.sublayers?.forEach(applyDrift)
    }

    private func applyDrift(_ copy: CALayer) {
        copy.removeAllAnimations()
        let first = copy.name == "0"
        copy.setAffineTransform(first ? .identity : CGAffineTransform(rotationAngle: .pi))
        guard animated, bounds.width > 0 else { return }
        let w = bounds.width, h = bounds.height
        let frameRate = slow ? CAFrameRateRange(minimum: 8, maximum: 12, preferred: 12)
                             : CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        // The copies turn all the way round, in opposite directions, so the colors swirl
        // like Apple Music's background…
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = (first ? 1 : -1) * 2 * CGFloat.pi
        turn.isAdditive = true
        turn.duration = first ? 48 : 64
        turn.repeatCount = .infinity
        turn.preferredFrameRateRange = frameRate
        copy.add(turn, forKey: "turn")
        // …while they drift and breathe: (key path, amplitude, half-period in seconds).
        let motions: [(String, CGFloat, CFTimeInterval)] = first
            ? [("transform.scale", 0.08, 13), ("position.x", w * 0.09, 17), ("position.y", h * 0.09, 21)]
            : [("transform.scale", 0.07, 16), ("position.x", w * 0.1, 19), ("position.y", h * 0.08, 15)]
        for (keyPath, amplitude, halfPeriod) in motions {
            let drift = CABasicAnimation(keyPath: keyPath)
            drift.fromValue = -amplitude
            drift.toValue = amplitude
            drift.isAdditive = true
            drift.duration = halfPeriod
            drift.autoreverses = true
            drift.repeatCount = .infinity
            drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // Start mid-swing so nothing jumps when the scene appears.
            drift.timeOffset = halfPeriod / 2
            drift.preferredFrameRateRange = frameRate
            copy.add(drift, forKey: keyPath)
        }
    }
}

/// Blurs a cover for the background: shrunk to a few hundred pixels (it is scaled up
/// across the whole screen anyway), blurred with clamped edges and a little extra
/// saturation. Runs off the main thread.
enum CoverBlur {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func make(from source: CGImage) -> CGImage? {
        let side: CGFloat = 160
        let input = CIImage(cgImage: source)
        let scale = side / max(input.extent.width, input.extent.height, 1)
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = small.extent
        let output = small.clampedToExtent()
            .applyingGaussianBlur(sigma: 4)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.3])
            .cropped(to: extent)
        return context.createCGImage(output, from: extent)
    }
}
