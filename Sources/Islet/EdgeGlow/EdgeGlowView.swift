import IsletCore
import SwiftUI

/// A soft ring of light around the screen's edges in the album's colors: a wide, faint
/// haze with a brighter thin line along the very edge. The colors run around the ring, and
/// cross-fade when the song changes.
struct EdgeGlowView: View {
    let store: PlayerStore
    let settings: AppSettings

    /// Roughly the display's own rounded corners.
    private static let cornerRadius: CGFloat = 12

    var body: some View {
        let colors = store.palette.glowColors.map { Color(rgb: $0) }
        let ring = AngularGradient(colors: colors + colors.prefix(1), center: .center)
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        ZStack {
            shape.strokeBorder(ring, lineWidth: 56).blur(radius: 44)
            shape.strokeBorder(ring, lineWidth: 16).blur(radius: 12)
            shape.strokeBorder(ring, lineWidth: 4).blur(radius: 3)
        }
        // Drawn once into one layer, so fading it (and the breathing the controller runs
        // on that layer) doesn't redraw the blur.
        .drawingGroup()
        .opacity(settings.edgeGlowStrength)
        .animation(.easeInOut(duration: 1.2), value: store.palette)
        .allowsHitTesting(false)
    }
}
