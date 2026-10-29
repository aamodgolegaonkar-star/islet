import IsletCore
import SwiftUI

/// A soft ring of light around a screen's edges: a wide, faint haze, a brighter band and a
/// thin bright line along the very edge. The colors run around the ring (the album's, or
/// the one or two picked in Settings) and cross-fade when the song changes. With a notch,
/// the ring can run around it like Lumn's rim instead of passing under it.
struct EdgeGlowView: View {
    let store: PlayerStore
    let settings: AppSettings
    /// The display's notch, if it has one (points).
    let notch: CGSize?

    var body: some View {
        let colors = glowColors.map { Color(rgb: $0) }
        let ring = AngularGradient(colors: colors + colors.prefix(1), center: .center)
        let rim = GlowRim(notch: settings.edgeGlowNotch ? notch : nil)
        let width = settings.edgeGlowWidth
        ZStack {
            // Stroked on the edge itself, so only the inner half shows.
            rim.stroke(ring, lineWidth: 112 * width).blur(radius: 44 * width)
            rim.stroke(ring, lineWidth: 32 * width).blur(radius: 12 * width)
            rim.stroke(ring, lineWidth: 8 * width).blur(radius: 3)
        }
        // Drawn once into one layer, so fading it (and the breathing and beat pulses the
        // controller runs on that layer) doesn't redraw the blur.
        .drawingGroup()
        .opacity(settings.edgeGlowStrength)
        .animation(.easeInOut(duration: 1.2), value: glowColors)
        .allowsHitTesting(false)
    }

    private var glowColors: [RGB] {
        switch settings.edgeGlowColors {
        case .album: store.palette.glowColors
        case .one: [settings.edgeGlowColor1]
        case .two: [settings.edgeGlowColor1, settings.edgeGlowColor2]
        }
    }
}

/// The screen's outline: rounded corners like the display's own, and with `notch`, a dip
/// down around the notch at the top centre (flared where it meets the top edge, rounded at
/// its bottom corners, as the hardware is).
struct GlowRim: Shape {
    var notch: CGSize?
    var cornerRadius: CGFloat = 12

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = cornerRadius
        path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        if let notch, notch.width > 0, notch.height > 0 {
            let left = rect.midX - notch.width / 2, right = rect.midX + notch.width / 2
            let flare: CGFloat = 6, bottom = min(10, notch.height / 2)
            path.addLine(to: CGPoint(x: left - flare, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: left, y: rect.minY + flare), control: CGPoint(x: left, y: rect.minY))
            path.addLine(to: CGPoint(x: left, y: rect.minY + notch.height - bottom))
            path.addQuadCurve(to: CGPoint(x: left + bottom, y: rect.minY + notch.height),
                              control: CGPoint(x: left, y: rect.minY + notch.height))
            path.addLine(to: CGPoint(x: right - bottom, y: rect.minY + notch.height))
            path.addQuadCurve(to: CGPoint(x: right, y: rect.minY + notch.height - bottom),
                              control: CGPoint(x: right, y: rect.minY + notch.height))
            path.addLine(to: CGPoint(x: right, y: rect.minY + flare))
            path.addQuadCurve(to: CGPoint(x: right + flare, y: rect.minY), control: CGPoint(x: right, y: rect.minY))
        }
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r,
                    startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r,
                    startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r,
                    startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r,
                    startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}
