import AppKit
import MetalKit
import SwiftUI

/// The album cover as a living lock-screen backdrop, the way Canopy draws it: five copies
/// of the cover, each turned, mirrored and drifting on its own, blended through soft
/// windows into one flowing image, gently swirled, colour-graded towards night blue and
/// crossfading to the next cover when the song changes. A Metal fragment shader (rebuilt
/// from Canopy's `artFragment`) draws it at 30 fps from the high-resolution cover; it holds
/// still with Reduce Motion and draws nothing while the display sleeps.
struct AlbumAurora: NSViewRepresentable {
    let artwork: NSImage
    /// Changes with the song, so a sharper copy of the same cover swaps in without a crossfade.
    var song: Int = 0
    var animated: Bool

    func makeNSView(context: Context) -> NSView {
        AuroraRenderer.makeView() ?? NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? AuroraRenderer.View)?.renderer.update(artwork: artwork, song: song, animated: animated)
    }
}

@MainActor
final class AuroraRenderer: NSObject, MTKViewDelegate {
    /// Frames come from the screen's display link rather than MTKView's loop or the view's
    /// link, which both stop when AppKit thinks the window is hidden (the lock screen's
    /// private space reads as hidden). It stops while the display sleeps.
    final class View: MTKView {
        var renderer: AuroraRenderer!
        private var link: CADisplayLink?
        private var occlusion: NSObjectProtocol?
        var animating = true {
            didSet { refreshLink() }
        }

        /// Runs only while animating and its window is on screen. A hidden lock-screen window
        /// keeps its SwiftUI content until it's shown again, so without this the shader would
        /// go on drawing behind the desktop after an unlock.
        private func refreshLink() {
            link?.isPaused = !(animating && window?.isVisible == true)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            link?.invalidate()
            link = nil
            occlusion.map(NotificationCenter.default.removeObserver)
            occlusion = window.map {
                NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: $0,
                                                       queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshLink() }
                }
            }
            guard let screen = window?.screen ?? NSScreen.main else { return }
            let link = screen.displayLink(target: self, selector: #selector(tick))
            // Full quality whenever it runs: only while the lock screen is lit.
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
            link.add(to: .main, forMode: .common)
            self.link = link
            refreshLink()
        }

        @objc private func tick() {
            guard window?.isVisible == true else { return refreshLink() }
            draw()
        }

        /// Held still: one frame whenever the size settles.
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            if !animating, newSize.width > 0 { draw() }
        }
    }

    /// Matches the shader's `Uniforms`, eight floats.
    private struct Uniforms {
        var time: Float = 0
        var width: Float = 1
        var height: Float = 1
        var fadeIn: Float = 0
        var songChange: Float = -100
        var crossfade: Float = 1
        var expand: Float = -100
        var phase: Float = 0
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let loader: MTKTextureLoader
    private var current: MTLTexture?
    private var previous: MTLTexture?
    private weak var shownArtwork: NSImage?
    private var uniforms = Uniforms()
    private let start = CACurrentMediaTime()
    private var appeared: CFTimeInterval?
    private var changed: CFTimeInterval?
    private weak var view: View?

    static func makeView() -> View? {
        guard let device = MTLCreateSystemDefaultDevice(), let renderer = AuroraRenderer(device: device) else {
            Log.lock.error("Aurora: Metal unavailable")
            return nil
        }
        let view = View(frame: .zero, device: device)
        view.renderer = renderer
        view.delegate = renderer
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 30
        view.framebufferOnly = true
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        renderer.view = view
        return view
    }

    private init?(device: MTLDevice) {
        let library: MTLLibrary
        do { library = try device.makeLibrary(source: Self.source, options: nil) } catch {
            Log.lock.error("Aurora shader: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let queue = device.makeCommandQueue(),
              let vertex = library.makeFunction(name: "auroraVertex"),
              let fragment = library.makeFunction(name: "auroraFragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.maxAnisotropy = 4
        samplerDescriptor.sAddressMode = .mirrorRepeat
        samplerDescriptor.tAddressMode = .mirrorRepeat
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.sampler = sampler
        loader = MTKTextureLoader(device: device)
    }

    private var song: Int?

    func update(artwork: NSImage, song: Int, animated: Bool) {
        view?.animating = animated
        guard artwork !== shownArtwork,
              let cg = artwork.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let texture = try? loader.newTexture(cgImage: cg, options: [
                  .SRGB: false, .generateMipmaps: true, .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                  .textureStorageMode: MTLStorageMode.private.rawValue]) else { return }
        let newSong = self.song != nil && self.song != song
        self.song = song
        shownArtwork = artwork
        previous = newSong ? current : texture
        current = texture
        if newSong { changed = CACurrentMediaTime() }
        if !animated { view?.draw() }
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { render(in: view) }
    }

    private func render(in view: MTKView) {
        guard let current, let previous, let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        let now = CACurrentMediaTime()
        let appeared = self.appeared ?? now
        self.appeared = appeared
        uniforms.time = Float(now - start)
        uniforms.width = Float(max(view.drawableSize.width, 1))
        uniforms.height = Float(max(view.drawableSize.height, 1))
        // Held still, the one frame drawn is the settled one.
        let still = (view as? View)?.animating == false
        uniforms.fadeIn = still ? 1 : Float(min(max((now - appeared) / 1.2, 0), 1))
        if let changed, !still {
            uniforms.songChange = Float(changed - start)
            let progress = min(max((now - changed) / 1.4, 0), 1)
            uniforms.crossfade = Float(progress * progress * (3 - 2 * progress))
        } else {
            uniforms.crossfade = 1
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(current, index: 0)
        encoder.setFragmentTexture(previous, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()

    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms { float time, width, height, fadeIn, songChange, crossfade, expand, phase; };
    struct Out { float4 position [[position]]; float2 uv; };

    vertex Out auroraVertex(uint id [[vertex_id]]) {
        const float2 corners[3] = { float2(-1, 1), float2(3, 1), float2(-1, -3) };
        const float2 uvs[3] = { float2(0, 0), float2(2, 0), float2(0, 2) };
        Out out;
        out.position = float4(corners[id], 0, 1);
        out.uv = uvs[id];
        return out;
    }

    static float2 turn(float2 p, float a) {
        float c = cos(a), s = sin(a);
        return float2(c * p.x - s * p.y, s * p.x + c * p.y);
    }

    fragment float4 auroraFragment(Out in [[stage_in]],
                                   texture2d<float> art [[texture(0)]],
                                   texture2d<float> previousArt [[texture(1)]],
                                   sampler s [[sampler(0)]],
                                   constant Uniforms &u [[buffer(0)]]) {
        const float aspect = u.width / u.height;
        const float t = u.time;

        // Three slow wells pull the picture around.
        float2 centres[3] = {
            float2(0.28 + 0.16 * sin(t * 0.071), 0.32 + 0.13 * cos(t * 0.053)),
            float2(0.72 + 0.14 * cos(t * 0.059), 0.28 + 0.11 * sin(t * 0.083)),
            float2(0.5 + 0.19 * sin(t * 0.041), 0.72 + 0.15 * cos(t * 0.067)) };
        float2 pull = 0;
        for (int i = 0; i < 3; i++) {
            float2 d = in.uv - centres[i];
            float2 da = float2(d.x * aspect, d.y);
            pull += 0.18 * exp(-7.0 * dot(da, da)) * d;
        }
        const float2 uv = in.uv + pull;
        const float2 q = uv - 0.5;
        const float drift = t * 0.72;

        // Opening the big art (expand) and a new song (songChange) push it for a moment.
        const float sinceExpand = clamp(t - u.expand, 0.0, 30.0);
        const float expand = exp(-3.0 * sinceExpand);
        const float x = clamp(t - u.songChange, 0.0, 4.0) * 2.2;
        const float song = x * exp(1.0 - x);
        const float squash = max(max(1.0 + 0.4 * exp(-1.5 * sinceExpand) * cos(sinceExpand * 2.2), 0.35), 0.35);

        const float r = length(float2(q.x * aspect, q.y));
        const float swirl = 0.007 * sin(r * 2.8 + t * 0.13) + exp(-r * r) * (0.032 + 0.02 * expand + 0.006 * song);
        const float flowScale = 1.1 + 0.28 * expand + 0.05 * song;
        const float zoom = 0.52 + 0.26 * expand;
        const float push = 0.032 * expand + 0.009 * song;

        const float a1 = uv.x * 1.1 + uv.y * 1.7 + u.phase;
        const float a2 = uv.x * 0.7 - uv.y * 1.3 + u.phase * 0.6;
        const float a3 = uv.x * 1.8 + uv.y * 0.5 + u.phase * 0.4;
        const float b1 = uv.x * 0.9 + uv.y * 1.5 + u.phase * 0.8;
        const float b2 = uv.x * 1.5 - uv.y * 0.8 + u.phase * 1.1;
        const float b3 = uv.x * 0.6 + uv.y * 2.0 + u.phase * 1.2;

        const float swirlSign[5] = { 1, -1, -1, 1, -1 };
        const float swirlGain[5] = { 1, 0.68, 1.32, 0.85, 1.15 };
        const float spin[5] = { 0.17, -0.11, 0.22, -0.07, 0.13 };
        const float spinStart[5] = { 0, 2.3, 4.1, 5.7, 1.2 };
        const float flowTurn[5] = { 0.6, 2.9, 4.4, 1.7, 3.8 };
        const float flowGain[5] = { 1, 1.6, 0.65, 1.35, 0.85 };
        const float scale[5] = { 1, 0.78, 1.28, 0.9, 1.12 };
        const float spinOffset[5] = { 0.3, 2.1, 3.6, 5.2, 1.4 };
        const float2 wobbleRate[5] = { float2(0.27, 0.21), float2(0.19, 0.31), float2(0.33, 0.17), float2(0.23, 0.29), float2(0.29, 0.24) };
        const float2 wobbleStart[5] = { float2(0, 1.7), float2(2.4, 0.6), float2(4.2, 3.1), float2(5.5, 2.2), float2(3, 4.8) };
        const float timeOffset[5] = { 0, 41, 97, 160, 223 };
        const float2 anchor[5] = { float2(0.25, 0.28), float2(0.75, 0.24), float2(0.26, 0.74), float2(0.74, 0.76), float2(0.5, 0.5) };
        const float2 mirror[5] = { float2(1, 1), float2(-1, 1), float2(1, -1), float2(-1, -1), float2(1, -1) };
        const float2 shift[5] = { float2(-0.18, -0.18), float2(0.18, -0.18), float2(-0.18, 0.18), float2(0.18, 0.18), float2(0, 0) };

        float3 colour = 0;
        float weights = 0;
        for (int i = 0; i < 5; i++) {
            const float p = timeOffset[i] + drift;
            const float2 twisted = turn(q, swirlSign[i] * swirl * swirlGain[i]);
            float2 flow = float2(0.16 * sin(a1 + p * 0.29) + 0.12 * sin(a2 + p * 0.19) + 0.08 * cos(a3 - p * 0.38),
                                 0.16 * cos(b1 + p * 0.22) + 0.12 * cos(b2 + p * 0.31) - 0.08 * sin(b3 - p * 0.16));
            flow = turn(flow, flowTurn[i]) * flowGain[i];
            flow.x /= aspect;
            flow *= flowScale;
            float2 d = twisted + 0.5 - anchor[i] + flow;
            d.x *= aspect;

            // A soft window around this copy's anchor, stretched by the expand spring.
            const float angle = u.phase + float(i) * 0.785398;
            const float c = cos(angle), sn = sin(angle);
            const float along = (d.x * c + d.y * sn) / squash;
            const float across = (d.y * c - d.x * sn) * squash;
            const float2 e = float2(along * c - across * sn, along * sn + across * c);
            const float weight = exp(-8.0 * dot(e, e));

            // Where this copy reads the cover: turned, mirrored, wobbling.
            float2 look = turn(d, spinStart[i] + u.phase + spin[i] * drift + spinOffset[i]) * mirror[i];
            look.x /= aspect;
            const float around = float(i) * 1.5708 + u.phase;
            const float2 sample = float2(cos(around), sin(around)) * push + 0.5
                + float2(sin(wobbleRate[i].x * drift + wobbleStart[i].x), sin(wobbleRate[i].y * drift + wobbleStart[i].y)) * 0.05
                + shift[i] + look * (scale[i] * zoom);
            float3 cover = art.sample(s, sample).rgb;
            // The old cover is only read while the crossfade runs: half the reads otherwise.
            if (u.crossfade < 0.999) cover = mix(previousArt.sample(s, sample).rgb, cover, u.crossfade);
            colour += cover * weight;
            weights += weight;
        }
        colour /= max(weights, 0.001);

        // Grade: dither, lift the shadows a touch, deepen, push dull colours, sink towards night blue.
        const float3 luma = float3(0.2126, 0.7152, 0.0722);
        colour += fract(sin(dot(uv, float2(12.9898, 78.233))) * 43758.5453) / 170.0;
        colour += max(0.0, 0.1 - dot(colour, luma)) * 0.88 * float3(0.78, 0.82, 1.0);
        colour = pow(saturate(colour), float3(1.18));
        const float grey = dot(colour, luma);
        const float hi = max(colour.r, max(colour.g, colour.b));
        const float lo = min(colour.r, min(colour.g, colour.b));
        const float chroma = clamp((hi - 0.12 - lo) * 3.0303, 0.0, 1.0);
        colour = mix(float3(grey), colour, mix(1.5, 1.1, chroma * chroma * (3.0 - 2.0 * chroma)));
        colour = mix(colour, float3(0.06, 0.07, 0.12), 0.44);

        const float edge = clamp((length(q) - 0.62) * 3.33333, 0.0, 1.0);
        const float vignette = 1.0 - 0.1 * edge * edge * (3.0 - 2.0 * edge);
        const float breathe = 0.97 + 0.03 * sin(t * 0.27);
        const float fade = u.fadeIn * u.fadeIn * (3.0 - 2.0 * u.fadeIn);
        colour = breathe * colour * vignette * fade;
        colour = mix(colour, float3(0.8, 0.82, 0.86), expand * 0.55 * (1.0 - fade));
        return float4(saturate(colour), 1);
    }
    """
}
