import AppKit
import IsletCore
import SwiftUI

/// `Islet --glass-gallery <out.png> --art <image>`: renders Liquid Glass treatments side by
/// side over the real player background and captures them (real glass, not stand-ins), so
/// styles can be compared by eye.
@MainActor
enum GlassGallery {
    static func run(output: String, artPath: String?) {
        let data = artPath.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
        let art = data.flatMap(NSImage.init(data:))
        let palette = data.map(ArtworkPixels.palette(from:)) ?? .fallback
        let size = CGSize(width: 1100, height: 760)

        let view = ZStack {
            FluidBackground(palette: palette, artwork: art)
            VStack(alignment: .leading, spacing: 34) {
                row("transport") {
                    transport.padding(.horizontal, 14).padding(.vertical, 6).glassEffect(.regular, in: Capsule())
                    transport.padding(.horizontal, 14).padding(.vertical, 6).glassEffect(.clear, in: Capsule())
                    transport.padding(.horizontal, 14).padding(.vertical, 6).glassEffect(.clear.tint(.black.opacity(0.18)), in: Capsule())
                    GlassEffectContainer(spacing: 10) {
                        HStack(spacing: 6) {
                            ForEach(["backward.fill", "play.fill", "forward.fill"], id: \.self) { symbol in
                                Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(.white)
                                    .frame(width: 50, height: 50).glassEffect(.clear, in: Circle())
                            }
                        }
                    }
                }
                row("buttons") {
                    circle(.regular)
                    circle(.clear)
                    circle(.clear.tint(.black.opacity(0.2)))
                    circle(.clear.tint(.white.opacity(0.1)))
                }
                row("merge") {
                    ForEach([0.0, 8, 16, 28], id: \.self) { gap in
                        GlassEffectContainer(spacing: 30) {
                            VStack(spacing: gap) {
                                RoundedRectangle(cornerRadius: 26).fill(.clear).frame(width: 150, height: 70)
                                    .glassEffect(.regular, in: .rect(cornerRadius: 26))
                                Color.clear.frame(width: 90, height: 34).glassEffect(.regular, in: Capsule())
                            }
                        }
                    }
                }
            }
            .padding(40)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark)

        let panel = IslandPanel(size: size)
        let host = FirstMouseHostingView(rootView: view)
        host.sizingOptions = []
        panel.contentView = host
        panel.setFrameOrigin(CGPoint(x: 30, y: 30))
        panel.orderFrontRegardless()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            WindowCapture.capture(panel, to: URL(fileURLWithPath: output))
            exit(0)
        }
    }

    private static var transport: some View {
        HStack(spacing: 26) {
            ForEach(["backward.fill", "play.fill", "forward.fill"], id: \.self) { symbol in
                Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(.white)
            }
        }
        .frame(height: 44)
    }

    private static func circle(_ glass: Glass) -> some View {
        Image(systemName: "quote.bubble").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 46, height: 46).glassEffect(glass, in: Circle())
    }

    private static func row(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .center, spacing: 30) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                .frame(width: 70, alignment: .leading)
            content()
        }
    }
}
