import AppKit
import SwiftUI

/// Clear Liquid Glass. The public glass APIs always frost what's behind an overlay window
/// heavily; this builds the same material from Core Animation's own pieces instead (as
/// Canopy does): a window-server backdrop, run through the system `glassBackground`
/// filter, shaped by a signed-distance field. With no blur the glass stays see-through and
/// only bends the screen at its edges.
///
/// These are private classes reached by name, so everything is checked before use; when any
/// piece is missing `ClearGlass.isAvailable` is false and callers keep Apple's stock glass.
@MainActor
enum ClearGlassSupport {
    static let isAvailable: Bool = {
        guard NSClassFromString("CABackdropLayer") is CALayer.Type,
              NSClassFromString("CASDFLayer") is CALayer.Type,
              NSClassFromString("CASDFElementLayer") is CALayer.Type,
              let filter = makeFilter(),
              let keys = filter.value(forKey: "inputKeys") as? [String]
        else { return false }
        return keys.contains("inputInnerRefractionAmount") && keys.contains("inputBlurRadius")
    }()

    static func makeFilter() -> NSObject? {
        guard let cls = NSClassFromString("CAFilter") as? NSObject.Type,
              cls.responds(to: NSSelectorFromString("filterWithType:")),
              let filter = cls.perform(NSSelectorFromString("filterWithType:"), with: "glassBackground")?
                  .takeUnretainedValue() as? NSObject
        else { return nil }
        return filter
    }

    static func layer(_ name: String) -> CALayer? {
        (NSClassFromString(name) as? CALayer.Type)?.init()
    }
}

/// The glass surface for a rounded shape. Corner radii animate along with the frame, so it
/// follows the island's morph; a radius larger than half the height makes a capsule.
struct ClearGlass: View, @preconcurrency Animatable {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    /// Blur of what's behind, in points; 0 is perfectly clear.
    var frost: Double

    nonisolated var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    var body: some View {
        ClearGlassRepresentable(topRadius: topRadius, bottomRadius: bottomRadius, frost: frost)
    }
}

private struct ClearGlassRepresentable: NSViewRepresentable {
    let topRadius: CGFloat
    let bottomRadius: CGFloat
    let frost: Double

    func makeNSView(context: Context) -> ClearGlassView { ClearGlassView() }

    func updateNSView(_ view: ClearGlassView, context: Context) {
        view.topRadius = topRadius
        view.bottomRadius = bottomRadius
        view.frost = frost
        view.refresh()
    }
}

final class ClearGlassView: NSView {
    var topRadius: CGFloat = 0
    var bottomRadius: CGFloat = 0
    var frost: Double = 0

    private let backdrop: CALayer?
    private let sdf: CALayer?
    /// Two overlapping shapes, because an SDF element has one corner radius: the upper one
    /// carries the top corners, the lower one the bottom corners.
    private let upper: CALayer?
    private let lower: CALayer?
    /// The glass's outermost pixel is a noisy, aliased ring (refraction at its extreme);
    /// a smooth mask a hair inside it trims that off, the same two-shape outline.
    private let edgeMask = CALayer()
    private let maskUpper = CALayer()
    private let maskLower = CALayer()
    private static let edgeTrim: CGFloat = 1

    override init(frame: CGRect) {
        let backdrop = ClearGlassSupport.layer("CABackdropLayer")
        let sdf = ClearGlassSupport.layer("CASDFLayer")
        let upper = ClearGlassSupport.layer("CASDFElementLayer")
        let lower = ClearGlassSupport.layer("CASDFElementLayer")
        self.backdrop = backdrop
        self.sdf = sdf
        self.upper = upper
        self.lower = lower
        super.init(frame: frame)
        wantsLayer = true
        guard let backdrop, let sdf, let upper, let lower,
              let filter = ClearGlassSupport.makeFilter() else { return }

        backdrop.setValue(true, forKey: "windowServerAware")
        backdrop.setValue(true, forKey: "tracksLuma")
        backdrop.setValue(true, forKey: "allowsFilteredLuma")
        backdrop.setValue(1.0, forKey: "scale")
        sdf.name = "isletGlassShape"
        sdf.setValue(true, forKey: "mergeElements")
        if let effect = (NSClassFromString("CASDFOutputEffect") as? NSObject.Type)?.init() {
            effect.setValue(-1000.0, forKey: "minimum")
            effect.setValue(0.0, forKey: "maximum")
            sdf.setValue(effect, forKey: "effect")
        }
        for element in [upper, lower] {
            element.cornerCurve = .continuous
            sdf.addSublayer(element)
        }
        backdrop.addSublayer(sdf)

        filter.setValue("glass", forKey: "name")
        filter.setValue(sdf.name, forKey: "inputSourceSublayerName")
        // Canopy's look: refraction only near the rim, untinted face, a soft key-light
        // highlight and a faint lift instead of a drop shadow.
        let fixed: [String: Double] = [
            "inputOuterRefractionAmount": 0, "inputOuterRefractionHeight": 0,
            "inputRefractionDistance0": -1, "inputRefractionDistance1": -0.5, "inputRefractionOpacity": 1,
            "inputFaceOpacity": 1, "inputFaceColorMatrixWhite": 1, "inputFaceColorMatrixBlack": 0,
            "inputFaceColorMatrixSaturation": 1,
            "inputShadowAmount": 43.5, "inputShadowOpacity": -0.1, "inputShadowRadius": 8,
            "inputShadowColorMatrixWhite": 1,
            "inputKeyFillHighlightHeight": 0.5, "inputKeyFillHighlightAngle": .pi / 2,
            "inputKeyFillHighlightSpread": 1.309, "inputKeyFillHighlightAmount": -0.4,
            "inputKeyFillHighlightEffectOffset": -0.5, "inputKeyFillHighlightColorBias": -0.25,
            "inputMaxHeadroom": 9999,
        ]
        for (key, value) in fixed { filter.setValue(value, forKey: key) }
        backdrop.filters = [filter]
        for part in [maskUpper, maskLower] {
            part.backgroundColor = CGColor(gray: 0, alpha: 1)
            part.cornerCurve = .continuous
            edgeMask.addSublayer(part)
        }
        backdrop.mask = edgeMask
        layer?.addSublayer(backdrop)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    /// Purely visual: clicks belong to the island's controls.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        refresh()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refresh()
    }

    func refresh() {
        guard let backdrop, let sdf, let upper, let lower else { return }
        let size = bounds.size
        guard size.width > 1, size.height > 1 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let rect = CGRect(origin: .zero, size: size)
        backdrop.frame = rect
        sdf.frame = rect

        let top = min(max(topRadius, 0), size.height / 2, size.width / 2)
        let bottom = min(max(bottomRadius, 0), size.height / 2, size.width / 2)
        let outline = Self.outline(in: rect, top: top, bottom: bottom)
        upper.frame = outline.upper.frame
        upper.cornerRadius = outline.upper.radius
        lower.frame = outline.lower.frame
        lower.cornerRadius = outline.lower.radius

        let trim = Self.edgeTrim
        edgeMask.frame = rect
        let inner = Self.outline(in: rect.insetBy(dx: trim, dy: trim),
                                 top: max(top - trim, 0), bottom: max(bottom - trim, 0))
        maskUpper.frame = inner.upper.frame
        maskUpper.cornerRadius = inner.upper.radius
        maskLower.frame = inner.lower.frame
        maskLower.cornerRadius = inner.lower.radius
        for part in [edgeMask, maskUpper, maskLower] { part.contentsScale = window?.backingScaleFactor ?? 2 }

        // The lens is as deep as the shape is tall, as in the system glass.
        let height = Double(size.height)
        backdrop.setValue(-1.2 * height, forKeyPath: "filters.glass.inputInnerRefractionAmount")
        backdrop.setValue(0.095 * height, forKeyPath: "filters.glass.inputInnerRefractionHeight")
        backdrop.setValue(max(frost, 0), forKeyPath: "filters.glass.inputBlurRadius")
        if let scale = window?.backingScaleFactor { backdrop.contentsScale = scale }
        CATransaction.commit()
    }

    /// A rounded rectangle with different top and bottom radii as two overlapping single-
    /// radius shapes: the upper one stops above the bottom corners and the lower one starts
    /// below the top corners, so each one's other corners fall inside its partner.
    private static func outline(in rect: CGRect, top: CGFloat, bottom: CGFloat)
        -> (upper: (frame: CGRect, radius: CGFloat), lower: (frame: CGRect, radius: CGFloat)) {
        if abs(top - bottom) < 0.5 || rect.height < 2 * (top + bottom) {
            // Equal corners (or too short to split): one shape.
            let radius = (top + bottom) / 2
            return ((rect, radius), (rect, radius))
        }
        let upper = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - bottom)
        let lower = CGRect(x: rect.minX, y: rect.minY + top, width: rect.width, height: rect.height - top)
        return ((upper, top), (lower, bottom))
    }
}
