import AppKit
import SwiftUI

/// Something going through the portal, for the island to show.
struct PortalArrival: Equatable {
    enum Direction { case received, sent }

    let id = UUID()
    let direction: Direction
    let title: String
    let detail: String
    /// A thumbnail of the photo, or the file's icon.
    let preview: NSImage?
    /// Shown when there's no preview (text, links).
    let symbol: String
    let effect: PortalEffect

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}

/// The island's portal card: the portal tears open, the item spins out of it (or, when
/// sending, gets pulled in), a shockwave rolls out, and the words settle beside it.
struct PortalArrivalContent: View {
    @Environment(\.portalTheme) private var theme
    let arrival: PortalArrival
    var topInset: CGFloat = 0
    /// 0 closed → 1 open portal; 2 the item is through.
    @State private var stage = 0
    @State private var wave = false

    private var received: Bool { arrival.direction == .received }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                PortalWell(effect: arrival.effect, energy: stage == 1 ? 1 : 0.35)
                    .scaleEffect(stage == 0 ? 0.1 : 1)
                    .opacity(stage == 0 ? 0 : 1)
                Circle()
                    .stroke(LinearGradient(colors: [theme.colors[1], theme.colors[0], theme.colors[2]], startPoint: .top, endPoint: .bottom), lineWidth: 2)
                    .scaleEffect(wave ? 2.6 : 0.3)
                    .opacity(wave ? 0 : 0.9)
                    .blur(radius: wave ? 2 : 0)
                // Sparks thrown out as the item comes through.
                ForEach(0..<18, id: \.self) { index in
                    let angle = Double(index) / 18 * .pi * 2 + Double(index % 3) * 0.2
                    let reach = 46.0 + Double(index % 4) * 12
                    Capsule()
                        .fill(theme.colors[index % 3])
                        .frame(width: wave ? 2 : 7, height: 2)
                        .rotationEffect(.radians(angle))
                        .offset(x: wave ? cos(angle) * reach : 0, y: wave ? sin(angle) * reach : 0)
                        .opacity(wave ? 0 : (stage == 2 ? 1 : 0))
                        .blendMode(.plusLighter)
                }
                item
                    .scaleEffect(itemScale)
                    .rotationEffect(.degrees(itemRotation))
                    .blur(radius: itemBlur)
                    .opacity(itemOpacity)
                    .offset(x: itemOffset)
            }
            .frame(width: 76, height: 76)
            .zIndex(1)
            ZStack(alignment: .leading) {
                // While the portal opens, so the card is never an empty black box.
                Text(received ? "Incoming from your phone…" : "Sending to your phone…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .opacity(stage == 1 ? 1 : 0)
                    .offset(x: stage == 0 ? -10 : 0, y: stage == 2 ? -8 : 0)
                    .blur(radius: stage == 1 ? 0 : 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(arrival.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(arrival.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                .opacity(stage == 2 ? 1 : 0)
                .offset(y: stage == 2 ? 0 : 8)
                .blur(radius: stage == 2 ? 0 : 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, topInset)
        // A flash of energy sweeping across the island as it comes through.
        .background(alignment: .leading) {
            Capsule()
                .fill(LinearGradient(colors: [theme.colors[0].opacity(0.7), theme.colors[1].opacity(0.35), .clear],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: wave ? 460 : 70, height: 64)
                .blur(radius: 22)
                .opacity(wave ? 0 : (stage >= 1 ? 0.9 : 0))
                .offset(x: 8, y: topInset / 2)
                .allowsHitTesting(false)
        }
        .task { await play() }
    }

    private var item: some View {
        Group {
            if let preview = arrival.preview {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: arrival.symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(LinearGradient(colors: [theme.colors[0], theme.colors[1]], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .frame(width: 50, height: 50)
        .clipShape(.rect(cornerRadius: 12, style: .continuous))
        .shadow(color: theme.colors[1].opacity(0.6), radius: 8)
    }

    // Received: from nothing in the middle out to full size. Sent: the reverse.
    private var through: Bool { received ? stage == 2 : stage < 2 }
    private var itemScale: CGFloat { through ? 1 : 0.05 }
    private var itemRotation: Double { through ? 0 : (received ? -540 : 540) }
    private var itemBlur: CGFloat { through ? 0 : 6 }
    private var itemOpacity: Double { through ? 1 : 0 }
    private var itemOffset: CGFloat { 0 }

    private func play() async {
        try? await Task.sleep(for: .milliseconds(80))
        withAnimation(IslandMotion.playful) { stage = 1 }
        try? await Task.sleep(for: .milliseconds(420))
        withAnimation(IslandMotion.playful) { stage = 2 }
        withAnimation(.easeOut(duration: 1.1)) { wave = true }
    }
}

/// A small living portal: rings of light turning against each other and sparks spiralling
/// into the dark middle (Vortex), or rings of water spreading out from it (Ripple).
/// `energy` speeds it up and brightens it while something is going through.
struct PortalWell: View {
    @Environment(\.portalTheme) private var theme
    let effect: PortalEffect
    var energy: Double = 0.35

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [theme.colors[0].opacity(0.9), theme.colors[1].opacity(0.35), .clear],
                                         center: .center, startRadius: 2, endRadius: 48))
                    .blur(radius: 8)
                    .scaleEffect(1 + 0.06 * sin(t * 2.4) + 0.25 * energy)
                if effect == .vortex { vortex(t) } else { ripples(t) }
                Circle()
                    .fill(RadialGradient(colors: [.black, .black, Color(red: 0.1, green: 0.02, blue: 0.25)],
                                         center: .center, startRadius: 0, endRadius: 15))
                    .frame(width: 32, height: 32)
                    .shadow(color: theme.colors[0], radius: 8)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: energy)
    }

    private func vortex(_ t: Double) -> some View {
        let speed = 1 + energy * 2.5
        return ZStack {
            ring(width: 68, line: 4, colors: [theme.colors[0], theme.colors[1], theme.colors[2], theme.colors[0]])
                .rotationEffect(.radians(t * 1.1 * speed))
            ring(width: 54, line: 3, colors: [.clear, theme.colors[1], .clear, theme.colors[2], .clear, theme.colors[0], .clear])
                .rotationEffect(.radians(-t * 1.9 * speed))
            Canvas { context, size in
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                for index in 0..<46 {
                    // Each spark falls inward along a spiral and starts again at the rim.
                    let seed = Double(index) * 0.618_034
                    let life = (seed + t * 0.28 * speed).truncatingRemainder(dividingBy: 1)
                    let radius = (1 - life) * 35 + 5
                    let angle = seed * .pi * 2 + t * speed * 1.6 + life * 5
                    let point = CGPoint(x: centre.x + cos(angle) * radius, y: centre.y + sin(angle) * radius)
                    let dot = 0.8 + (1 - life) * 1.4
                    let hue = 0.72 - life * 0.25
                    context.fill(Path(ellipseIn: CGRect(x: point.x - dot, y: point.y - dot, width: dot * 2, height: dot * 2)),
                                 with: .color(Color(hue: hue, saturation: 0.8, brightness: 1).opacity(0.25 + life * 0.75)))
                }
            }
            .blendMode(.plusLighter)
        }
    }

    private func ripples(_ t: Double) -> some View {
        ZStack {
            ForEach(0..<4, id: \.self) { index in
                let phase = (t * (0.45 + energy * 0.6) + Double(index) / 4).truncatingRemainder(dividingBy: 1)
                Circle()
                    .stroke(theme.colors[index % 3], lineWidth: 2 - phase * 1.5)
                    .frame(width: 22 + phase * 56, height: 22 + phase * 56)
                    .opacity(1 - phase)
            }
        }
        .blendMode(.plusLighter)
    }

    private func ring(width: CGFloat, line: CGFloat, colors: [Color]) -> some View {
        Circle()
            .stroke(AngularGradient(colors: colors, center: .center), lineWidth: line)
            .frame(width: width, height: width)
            .blur(radius: 0.6)
            .shadow(color: theme.colors[1].opacity(0.5), radius: 4)
    }
}
