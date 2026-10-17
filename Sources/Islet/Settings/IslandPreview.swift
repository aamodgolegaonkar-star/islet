import AppKit
import SwiftUI

/// A small, live copy of the top of the screen for the Island pane: the real desktop
/// picture with the island drawn at its real proportions, so style, size and transparency
/// changes can be seen while the sliders move.
struct IslandPreview: View {
    let style: IslandStyle
    /// Changes whenever a size or transparency setting moves, so the island re-measures.
    let tuningKey: [Double]

    private static let height: CGFloat = 132
    @State private var wallpaper: WallpaperContext?

    var body: some View {
        GeometryReader { geo in
            let screen = NSScreen.screens.first
            let metrics = IslandMetrics.make(for: screen, style: style)
            // The strip of screen shown: wide enough for the island with room either side.
            let span = max(metrics.compactWidth + 280, 560)
            let scale = geo.size.width / span
            ZStack(alignment: .top) {
                backdrop
                if metrics.hasNotch {
                    // The camera housing, which the island wraps around.
                    UnevenRoundedRectangle(bottomLeadingRadius: 8 * scale, bottomTrailingRadius: 8 * scale)
                        .fill(.black)
                        .frame(width: metrics.idleWidth * scale, height: metrics.notchHeight * scale)
                        .zIndex(1)
                }
                island(metrics, scale: scale)
                    .padding(.top, metrics.hasNotch ? 0 : metrics.topInset * scale)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .clipShape(.rect(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator))
            .task(id: span) { wallpaper = Self.wallpaper(span: span, height: geo.size.height / scale) }
        }
        .frame(height: Self.height)
        .animation(.spring(response: 0.42, dampingFraction: 0.72), value: style)
        .animation(.spring(response: 0.42, dampingFraction: 0.72), value: tuningKey)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var backdrop: some View {
        if let wallpaper {
            Image(decorative: wallpaper.image, scale: wallpaper.scale)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .transition(.opacity)
        } else {
            LinearGradient(colors: [Color(white: 0.32), Color(white: 0.2)], startPoint: .top, endPoint: .bottom)
        }
    }

    private func island(_ metrics: IslandMetrics, scale: CGFloat) -> some View {
        let height = (metrics.hasNotch ? metrics.notchHeight : metrics.compactHeight) * scale
        let width = metrics.compactWidth * scale
        let shape = metrics.hasNotch
            ? AnyShape(UnevenRoundedRectangle(bottomLeadingRadius: height / 2, bottomTrailingRadius: height / 2))
            : AnyShape(Capsule())
        let art = height * 0.62
        return HStack {
            RoundedRectangle(cornerRadius: art * 0.24, style: .continuous)
                .fill(.white.opacity(0.18))
                .overlay(Image(systemName: "music.note").font(.system(size: art * 0.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85)))
                .frame(width: art, height: art)
            Spacer(minLength: 0)
            HStack(spacing: art * 0.12) {
                ForEach([0.45, 0.8, 0.6, 0.95], id: \.self) { level in
                    Capsule().fill(Color.pink).frame(width: art * 0.13, height: art * 0.7 * level)
                }
            }
            .frame(height: art * 0.7)
        }
        .padding(.horizontal, (height - art) / 2 + 2 * scale)
        .frame(width: width, height: height)
        .modifier(PreviewSurface(style: style, shape: shape))
        .shadow(color: .black.opacity(0.25), radius: 6 * scale, y: 2 * scale)
    }

    /// The desktop picture under the top of the screen, cropped to the strip shown.
    @MainActor
    private static func wallpaper(span: CGFloat, height: CGFloat) -> WallpaperContext? {
        guard let screen = NSScreen.screens.first else { return nil }
        let frame = CGRect(x: screen.frame.midX - span / 2, y: screen.frame.maxY - height,
                           width: span, height: height).integral
        return Wallpaper.context(for: screen, windowFrame: frame)
    }
}

private struct PreviewSurface: ViewModifier {
    let style: IslandStyle
    let shape: AnyShape

    func body(content: Content) -> some View {
        if style.isGlass {
            content.glassEffect(.islet(clear: style == .clearGlass), in: shape)
        } else {
            content.background(shape.fill(.black))
        }
    }
}
