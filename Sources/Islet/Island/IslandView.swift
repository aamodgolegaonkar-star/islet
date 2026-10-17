import IsletCore
import SwiftUI

/// The Dynamic Island: a black (or Liquid Glass) pill that springs open into a live
/// Now Playing card, and briefly shows system events such as charging.
///
/// Every state's content is laid out once at its final size and pinned to the top; only
/// the island's outline animates and reveals it. Nothing re-lays out mid-morph, so the
/// content never drifts or "settles" after the spring.
struct IslandView: View {
    @Bindable var model: IslandModel
    let store: PlayerStore
    let settings: AppSettings
    @Namespace private var namespace
    @State private var bump = false
    @State private var chargingGlow = false

    private var activity: IslandActivity? { model.activity }
    private var isCharging: Bool { if case .charging? = activity { true } else { false } }
    private var isExpanded: Bool { model.presentation == .expanded && store.hasTrack && activity == nil }
    private var isShelf: Bool { model.presentation == .shelf && activity == nil }
    private var isControls: Bool { model.presentation == .controls && activity == nil }
    /// The compact island is showing a running timer.
    private var showsTimer: Bool { model.timerEnd != nil && activity == nil && model.presentation == .compact }
    private var style: IslandStyle { settings.islandStyle }
    private var hovered: Bool { model.isHovered && model.presentation == .compact && activity == nil }

    var body: some View {
        let metrics = model.metrics
        // A running timer gives the compact island something to show even without music.
        let busy = store.hasTrack || model.timerEnd != nil
        let sized = metrics.size(for: model.presentation, hasTrack: busy, activity: activity)
        let card = showsTimer ? CGSize(width: metrics.timerWidth, height: sized.height) : sized
        let radii = metrics.cornerRadii(for: model.presentation, hasTrack: busy, activity: activity)
        // A notch is black hardware, so the compact island stays black over it.
        let glass = style.isGlass && !(metrics.hasNotch && !isExpanded && !isShelf && !isControls && activity?.isCard != true)
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: radii.top, bottomLeadingRadius: radii.bottom,
            bottomTrailingRadius: radii.bottom, topTrailingRadius: radii.top, style: .continuous)
        // The transport controls float in their own capsule below the card. It waits hidden
        // behind the card and springs out a beat after it opens, like a droplet released
        // from the island; it is two separate surfaces, so nothing has to merge first.
        let showsCapsule = metrics.split && store.hasTrack && activity == nil
        let capsuleSize = isExpanded
            ? metrics.controlsSize
            : CGSize(width: card.width * 0.6, height: card.height * 0.8)
        let capsuleY = isExpanded ? card.height + metrics.controlsGap : (card.height - capsuleSize.height) / 2

        ZStack(alignment: .top) {
            if showsCapsule {
                TransportRow(store: store, scale: 0.8, look: .highlight, clickable: isExpanded)
                    .frame(width: metrics.controlsSize.width, height: metrics.controlsSize.height)
                    .scaleEffect(x: capsuleSize.width / metrics.controlsSize.width,
                                 y: capsuleSize.height / metrics.controlsSize.height, anchor: .top)
                    .opacity(isExpanded ? 1 : 0)
                    .frame(width: capsuleSize.width, height: capsuleSize.height, alignment: .top)
                    .modifier(IslandSurface(style: style, glass: style.isGlass, shape: Capsule(), radii: (.infinity, .infinity), expanded: isExpanded,
                                            artwork: store.artwork, palette: store.palette))
                    .opacity(isExpanded ? 1 : 0)
                    .offset(y: capsuleY)
                    .animation(isExpanded ? IslandMotion.open.delay(0.05) : .easeOut(duration: 0.12), value: isExpanded)
            }
            ZStack(alignment: .top) {
                content(metrics)
            }
            .frame(width: card.width, height: card.height, alignment: .top)
            .clipShape(shape)
            .modifier(IslandSurface(style: style, glass: glass, shape: shape, radii: radii, expanded: isExpanded,
                                    artwork: store.artwork, palette: store.palette))
            // Beside the island (outside its shape), so it never covers the content.
            .overlay(alignment: .topTrailing) { privacyDot(metrics) }
        }
        .modifier(RoutedClickSpace(windowWidth: metrics.windowSize.width, topInset: metrics.topInset))
        .shadow(color: .green.opacity(isCharging && chargingGlow ? 0.55 : 0), radius: 16)
        .modifier(Shake(shakes: CGFloat(model.shakes)))
        .animation(.linear(duration: 0.5), value: model.shakes)
        .scaleEffect(bump ? 1.06 : 1, anchor: .top)
        // Under the pointer the resting island lifts slightly, so it reads as touchable.
        .scaleEffect(hovered ? 1.045 : 1, anchor: .top)
        .animation(IslandMotion.subtle, value: hovered)
        .padding(.top, metrics.topInset)
        .opacity(model.isSuppressed || model.isTucked ? 0 : 1)
        // Swiped up: it slips up and away; it drops back the same way.
        .scaleEffect(model.isTucked ? 0.75 : 1, anchor: .top)
        .offset(y: model.isTucked ? -18 : 0)
        .animation(IslandMotion.subtle, value: model.isTucked)
        .frame(width: metrics.windowSize.width, height: metrics.windowSize.height, alignment: .top)
        .environment(\.colorScheme, .dark)
        .environment(\.wallpaper, model.wallpaper)
        .environment(\.appearsActive, true)
        .animation(isExpanded ? IslandMotion.open : IslandMotion.close, value: isExpanded)
        .animation(isShelf ? IslandMotion.open : IslandMotion.close, value: isShelf)
        .animation(isControls ? IslandMotion.open : IslandMotion.close, value: isControls)
        .animation(IslandMotion.activity, value: activity)
        .animation(IslandMotion.open, value: store.hasTrack)
        .animation(.easeInOut(duration: 0.2), value: model.isSuppressed)
        .animation(IslandMotion.subtle, value: style)
        .onChange(of: store.trackChangeCount) { pulse() }
        .onChange(of: store.hasTrack) { _, hasTrack in
            // Music stopped while open: start compact next time, not popped open.
            if !hasTrack, model.presentation == .expanded { model.presentation = .compact }
        }
        .onChange(of: activity) { oldValue, newValue in
            if let newValue, !newValue.sameKind(as: oldValue) { pulse() }
            let charging = if case .charging? = newValue { true } else { false }
            withAnimation(charging ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : .easeOut(duration: 0.2)) {
                chargingGlow = charging
            }
        }
    }

    private func pulse() {
        guard !isExpanded else { return }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.5)) { bump = true }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7).delay(0.16)) { bump = false }
    }

    @ViewBuilder
    private func content(_ metrics: IslandMetrics) -> some View {
        if case let .charging(battery)? = activity {
            ChargingContent(battery: battery)
                .frame(width: metrics.chargingWidth, height: metrics.compactHeight)
                .transition(.materialize(delay: 0.04))
        } else if activity == .unlocked {
            UnlockContent()
                .frame(width: metrics.unlockedWidth, height: metrics.compactHeight)
                .transition(.materialize(delay: 0.04))
        } else if case .level? = activity {
            LevelContent(model: model, notchHeight: metrics.hasNotch ? metrics.notchHeight : nil)
                .frame(width: metrics.chargingWidth,
                       height: metrics.hasNotch ? metrics.compactHeight + 26 : metrics.compactHeight)
                .transition(.materialize(delay: 0.04))
        } else if case let .headphones(card)? = activity {
            HeadphoneContent(card: card)
                .padding(.top, metrics.hasNotch ? metrics.notchHeight : 0)
                .frame(width: metrics.headphoneCardWidth, height: metrics.compactHeight + 76)
                .transition(.materialize(delay: 0.08))
        } else if case let .agent(alert)? = activity {
            AgentContent(alert: alert) { model.onAgentTap(alert) }
                .padding(.top, metrics.hasNotch ? metrics.notchHeight : 0)
                .frame(width: metrics.headphoneCardWidth, height: metrics.compactHeight + 58)
                .transition(.materialize(delay: 0.08))
        } else if case let .lowBattery(percent)? = activity {
            LowBatteryContent(percent: percent, besideNotch: metrics.hasNotch)
                .frame(width: metrics.chargingWidth, height: metrics.compactHeight)
                .transition(.materialize(delay: 0.04))
        } else if activity == .timerDone {
            TimerDoneContent(besideNotch: metrics.hasNotch)
                .frame(width: metrics.chargingWidth, height: metrics.compactHeight)
                .transition(.materialize(delay: 0.04))
        } else if activity == .locked || activity == .lockFailed {
            LockedContent(failed: activity == .lockFailed)
                .frame(width: metrics.lockedWidth, height: metrics.compactHeight)
                .transition(.materialize(delay: 0.04))
        } else if isControls {
            ControlCenterView(model: model, store: store, notchHeight: metrics.hasNotch ? metrics.notchHeight : nil,
                              showMusic: { withAnimation(IslandMotion.open) { model.presentation = .expanded } },
                              showShelf: settings.shelfEnabled ? { withAnimation(IslandMotion.open) { model.presentation = .shelf } } : nil)
                .frame(width: metrics.expandedSize.width, height: metrics.controlsHeight)
                .transition(.materialize(delay: 0.05))
        } else if isShelf {
            ShelfView(shelf: model.shelf, hasTrack: store.hasTrack,
                      showControls: { withAnimation(IslandMotion.open) { model.presentation = .controls } },
                      notchHeight: metrics.hasNotch ? metrics.notchHeight : nil,
                      showMusic: { withAnimation(IslandMotion.open) { model.presentation = .expanded } },
                      dropped: { model.onShelfDrop() },
                      interacting: { on in
                          model.isInteracting = on
                          if !on { model.interactionEnded() }
                      })
                .frame(width: metrics.expandedSize.width, height: metrics.shelfHeight)
                .transition(.materialize(delay: 0.05))
        } else if isExpanded {
            expandedContent(split: metrics.split)
                .frame(width: metrics.expandedSize.width, height: metrics.expandedSize.height)
                .transition(.materialize(delay: 0.05))
        } else if let end = model.timerEnd {
            TimerCompactContent(end: end)
                .frame(width: metrics.timerWidth, height: metrics.compactHeight)
                .transition(.materialize(delay: 0.04))
        } else if store.hasTrack {
            compactContent
                .frame(width: metrics.compactWidth, height: metrics.compactHeight)
                .transition(.materialize(delay: 0.08))
        } else {
            // The resting island: a click opens Control Center.
            Color.clear
                .frame(width: metrics.idleWidth, height: metrics.compactHeight)
                .contentShape(Rectangle())
                .routedClick("island.idle") { withAnimation(IslandMotion.open) { model.presentation = .controls } }
        }
    }

    // MARK: - Compact

    private var compactContent: some View {
        HStack(spacing: 0) {
            artwork(cornerRadius: 7)
                .frame(width: model.metrics.compactHeight - 9, height: model.metrics.compactHeight - 9)
            Spacer(minLength: 0)
            EqualizerBars(isPlaying: barsMoving, color: accent)
                .matchedGeometryEffect(id: "bars", in: namespace)
                .frame(width: 20, height: 13)
                .padding(.trailing, 6)
        }
        .padding(.horizontal, 5)
        .contentShape(Rectangle())
        .onTapGesture { model.requestExpand() }
    }

    // MARK: - Expanded

    private func expandedContent(split: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                artwork(cornerRadius: 13)
                    .frame(width: 54, height: 54)
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                    .onTapGesture { model.openPlayer() }
                    .help("Open Now Playing")
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(store.artist)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.62))
                    if case .synced = store.lyrics, LiveTuning.shared.showIslandLyrics {
                        LiveLyricLine(store: store)
                    }
                }
                .lineLimit(1)
                .contentShape(Rectangle())
                .onTapGesture { model.openPlayer() }
                Spacer(minLength: 6)
                if !model.shelf.items.isEmpty { shelfButton }
                IslandPillButton(label: nil, symbol: "switch.2", help: "Control Center", id: "island.controls") {
                    withAnimation(IslandMotion.open) { model.presentation = .controls }
                }
                EqualizerBars(isPlaying: barsMoving, color: accent)
                    .matchedGeometryEffect(id: "bars", in: namespace)
                    .frame(width: 26, height: 20)
            }
            .padding(.bottom, 10)
            // Times sit inline with the bar, like the iPhone, clear of the rounded corners.
            InlineScrubber(store: store) { editing in
                model.isInteracting = editing
                if !editing { model.interactionEnded() }
            }
            if !split {
                // Inside a glass card, buttons highlight softly instead of stacking more glass.
                TransportRow(store: store, scale: 0.9, look: style.isGlass ? .highlight : .glassOnHover)
                    .padding(.top, 4)
            }
        }
        .padding(.top, model.metrics.hasNotch ? model.metrics.notchHeight + 6 : 0)
        .padding(.horizontal, 24)
    }

    /// Orange while a microphone is in use, green for the camera (green wins), at the edge
    /// of the compact island, like the iPhone's indicator. Beside a notch it sits in the
    /// right wing.
    @ViewBuilder
    private func privacyDot(_ metrics: IslandMetrics) -> some View {
        if (model.micActive || model.cameraActive), activity == nil, model.presentation == .compact {
            Circle()
                .fill(model.cameraActive ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
                .padding(.top, metrics.topInset + (metrics.compactHeight - 6) / 2)
                .offset(x: 12)
                .transition(.scale.combined(with: .opacity))
        }
    }

    /// Switches the open island to the shelf (shown while it holds files).
    private var shelfButton: some View {
        IslandPillButton(label: "\(model.shelf.items.count)", symbol: "tray.full.fill", help: "Shelf", id: "island.shelf") {
            withAnimation(IslandMotion.open) { model.presentation = .shelf }
        }
    }

    private func artwork(cornerRadius: CGFloat) -> some View {
        CoverArtView(image: store.artwork, motionURL: isExpanded ? store.motion?.square : nil)
            .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
            .matchedGeometryEffect(id: "art", in: namespace)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.artFrame = $0 }
    }

    private var accent: Color {
        Color(rgb: store.palette.accent)
    }

    /// The bars rest while the island is hidden under the full-screen player.
    private var barsMoving: Bool {
        store.isPlaying && !model.isSuppressed
    }
}

/// The island's shake on a wrong attempt, like the iPhone's Face ID padlock: three quick
/// swings that die away. Each increment of `shakes` plays one shake.
private struct Shake: GeometryEffect {
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let progress = shakes - shakes.rounded(.down)
        let swing = 11 * (1 - progress) * sin(progress * .pi * 6)
        return ProjectionTransform(CGAffineTransform(translationX: swing, y: 0))
    }
}

/// The lock-screen island: a closed padlock at the leading edge, as on the iPhone, or a
/// red fingerprint there after a wrong attempt.
struct LockedContent: View {
    let failed: Bool

    var body: some View {
        HStack {
            glyph.frame(width: 24)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: failed)
    }

    private var glyph: some View {
        ZStack {
            Image(systemName: "lock.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .opacity(failed ? 0 : 1)
                .scaleEffect(failed ? 0.6 : 1)
            Image(systemName: "touchid")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.red)
                .opacity(failed ? 1 : 0)
                .scaleEffect(failed ? 1 : 0.6)
        }
    }
}

/// The unlock moment: the fingerprint is read (red), recognised (green), then turns into
/// an open padlock as "Unlocked" fades in.
struct UnlockContent: View {
    private enum Phase { case scanning, recognised, open }
    @State private var phase = Phase.scanning
    @State private var bounce = 0

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Image(systemName: "touchid")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(phase == .scanning ? Color.red : .green)
                    .symbolEffect(.bounce, value: bounce)
                    .scaleEffect(phase == .open ? 0.5 : 1)
                    .opacity(phase == .open ? 0 : 1)
                Image(systemName: "lock.open.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.bounce, value: phase == .open)
                    .scaleEffect(phase == .open ? 1 : 0.5)
                    .opacity(phase == .open ? 1 : 0)
            }
            .frame(width: 24)
            Spacer(minLength: 6)
            Text("Unlocked")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .opacity(phase == .open ? 1 : 0)
                .offset(x: phase == .open ? 0 : 6)
        }
        .padding(.horizontal, 12)
        .task {
            try? await Task.sleep(for: .milliseconds(180))
            withAnimation(.easeOut(duration: 0.3)) { phase = .recognised }
            bounce += 1
            try? await Task.sleep(for: .milliseconds(520))
            withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) { phase = .open }
        }
    }
}

/// "Charging" with a bolt, the percentage and a battery that fills up — the island's
/// response to plugging in, as on the iPhone.
struct ChargingContent: View {
    let battery: BatteryState
    @State private var fill: Double = 0
    @State private var bolt = 0

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: bolt)
            Text("Charging")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Spacer(minLength: 6)
            Text("\(Int((battery.level * 100).rounded()))%")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(.green)
            BatteryGlyph(level: fill)
        }
        .padding(.horizontal, 14)
        .onAppear {
            bolt += 1
            withAnimation(.easeOut(duration: 0.9).delay(0.15)) { fill = battery.level }
        }
    }
}

struct BatteryGlyph: View {
    var level: Double

    var body: some View {
        HStack(spacing: 1.5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .stroke(.white.opacity(0.45), lineWidth: 1.2)
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(Color.green.gradient)
                    .frame(width: max(2, 24 * min(max(level, 0), 1)), height: 9)
                    .padding(.leading, 2.5)
            }
            .frame(width: 29, height: 14)
            Capsule().fill(.white.opacity(0.45)).frame(width: 2, height: 5)
        }
    }
}

/// Black (iPhone) or Liquid Glass surface for the island's shapes. Glass samples whatever is
/// really behind the panel (menu bar, desktop, windows) live, plus a glow of the album colors
/// while open.
private struct IslandSurface<S: Shape>: ViewModifier {
    let style: IslandStyle
    let glass: Bool
    let shape: S
    /// The shape's top and bottom corner radii (infinite for a capsule), for clear glass.
    let radii: (top: CGFloat, bottom: CGFloat)
    let expanded: Bool
    let artwork: NSImage?
    let palette: Palette
    @Environment(\.isSnapshotRendering) private var snapshot
    /// Set only on the lock screen, where overlay windows can't sample the system's own
    /// lock screen and the desktop picture has to be painted in.
    @Environment(\.wallpaper) private var wallpaper

    /// One structure for both looks, so switching between black and glass (beside a notch
    /// the island is black while closed and glass while open) cross-fades the surface
    /// instead of swapping views, which briefly drew the content twice.
    func body(content: Content) -> some View {
        let clear = usesClearGlass
        content
            .snapshotSafeGlass(glass && !clear ? glassMaterial : .identity, visible: glass && !clear, in: shape)
            .background {
                ZStack {
                    ZStack {
                        // Nearly invisible, but non-transparent pixels keep the island clickable
                        // in the otherwise clear panel. No painted wallpaper: the glass refracts
                        // what is actually on screen behind the window.
                        shape.fill(.black.opacity(0.012))
                        if wallpaper != nil { WallpaperBackdrop() }
                        // Only while open: the swirl keeps animating while it exists.
                        if glass, expanded {
                            glow.opacity(style == .clearGlass ? 0.42 : 0.6)
                                .transition(.opacity)
                        }
                    }
                    .clipShape(shape)
                    if clear {
                        // Above the glow, so the glass bends it along with the screen. Not
                        // clipped: the glass draws its own smooth edge, and a clip would cut
                        // through its rim.
                        ClearGlass(topRadius: radii.top, bottomRadius: radii.bottom, frost: clearFrost)
                            .transition(.opacity)
                        shape.fill(.black.opacity(clearDim))
                    }
                    shape.fill(.black).opacity(glass ? 0 : 1)
                }
            }
            .overlay(shape.stroke(.white.opacity(glass ? 0 : (expanded ? 0.09 : 0.04)), lineWidth: 1))
            // Clear glass lifts itself (the filter's own soft shadow); a dark halo would muddy it.
            .shadow(color: .black.opacity(clear ? 0 : glass ? (expanded ? 0.32 : 0.14) : (expanded ? 0.5 : 0.22)),
                    radius: expanded ? (glass ? 22 : 26) : (glass ? 5 : 6),
                    y: expanded ? (glass ? 10 : 12) : 2)
    }

    /// The cover, blurred and slowly swirling, like the full-screen player's background.
    private var glow: some View {
        Color.clear.overlay {
            if artwork != nil {
                FluidBackground(palette: palette, artwork: artwork)
                    .saturation(1.4)
            }
        }
    }

    /// Clear Liquid Glass gets the see-through Core Animation glass wherever it can sample
    /// the screen (not on the lock screen, nor in offscreen snapshots).
    private var usesClearGlass: Bool {
        glass && style == .clearGlass && wallpaper == nil && !snapshot && ClearGlassSupport.isAvailable
    }

    /// The Transparency slider: fully transparent is crystal clear; lower values frost and
    /// darken the glass a little, so white text stays readable over bright windows.
    private var clearFrost: Double { (1 - LiveTuning.shared.glassTransparency) * 16 }
    private var clearDim: Double { (1 - LiveTuning.shared.glassTransparency) * 0.3 }

    private var glassMaterial: Glass {
        switch style {
        case .clearGlass: .islet(clear: true)
        default: .islet
        }
    }
}

extension Color {
    init(rgb: RGB, opacity: Double = 1) {
        self.init(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: opacity)
    }
}
