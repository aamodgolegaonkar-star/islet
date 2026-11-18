import IsletCore
import SwiftUI

extension View {
    /// A Liquid Glass tile over the wallpaper that is really behind it. With the Clear
    /// Liquid Glass style it's the island's see-through glass, bending the wallpaper at its
    /// rim; a radius of half the side makes a circle.
    func lockGlass(cornerRadius: CGFloat) -> some View {
        modifier(LockGlass(radius: cornerRadius))
    }
}

private struct LockGlass: ViewModifier {
    let radius: CGFloat
    @Environment(\.isSnapshotRendering) private var snapshot
    @Environment(\.liveBackdrop) private var live

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let tuning = LiveTuning.shared
        let clear = tuning.clearGlass && !snapshot && ClearGlassSupport.isAvailable
        content
            .snapshotSafeGlass(clear ? .identity : .islet, visible: !clear, in: shape)
            .background {
                ZStack {
                    if !live { WallpaperBackdrop().clipShape(shape) }
                    if clear {
                        // Above the wallpaper so it bends it; unclipped, it draws its own rim.
                        ClearGlass(topRadius: radius, bottomRadius: radius, frost: tuning.clearFrost, inWindow: true)
                        shape.fill(.black.opacity(tuning.clearDim))
                    }
                }
            }
            // Clear glass lifts itself with the filter's own soft shadow.
            .shadow(color: .black.opacity(clear ? 0 : 0.2), radius: 10, y: 4)
    }
}

// MARK: - Tiny widgets under the clock

struct LockWidgetsRow: View {
    let store: PlayerStore
    @Bindable var model: LockModel
    let settings: AppSettings

    var body: some View {
        if model.isPresented { widgets }
    }

    private var widgets: some View {
        GlassContainer(spacing: 10) {
            HStack(spacing: LockWidget.spacing) {
                ForEach(settings.lockWidgets) { widget in
                    LockWidgetTile(widget: widget, store: store, model: model, settings: settings)
                }
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.wallpaper, model.widgetsWallpaper)
        .environment(\.liveBackdrop, model.backdropCovered)
        .environment(\.colorScheme, .dark)
        .environment(\.appearsActive, true)
        .animation(IslandMotion.subtle, value: settings.lockWidgets)
    }
}

struct BatteryRing: View {
    let battery: BatteryState

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.22), lineWidth: 5)
            Circle()
                .trim(from: 0, to: battery.level)
                .stroke(ringColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Image(systemName: battery.isCharging ? "bolt.fill" : symbol)
                    .font(.system(size: 10, weight: .bold))
                Text("\(Int((battery.level * 100).rounded()))")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .padding(10)
        .animation(.easeInOut(duration: 0.6), value: battery)
    }

    private var ringColor: Color {
        if battery.isCharging { return .green }
        return battery.level < 0.2 ? .red : .white
    }

    private var symbol: String {
        switch battery.level {
        case ..<0.13: "battery.0percent"
        case ..<0.38: "battery.25percent"
        case ..<0.63: "battery.50percent"
        case ..<0.88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

/// Now: the condition, the temperature, and today's high and low.
struct WeatherTile: View {
    let report: WeatherService.Report

    var body: some View {
        VStack(spacing: 1) {
            Image(systemName: report.symbol)
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 15))
            Text("\(report.temperature)°")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text("\(report.high)° \(report.low)°")
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(8)
    }
}

/// Connected headphones: their glyph inside a ring of the lowest battery level.
struct HeadphoneRing: View {
    let status: HeadphoneStatus

    var body: some View {
        let level = Double(status.level ?? 0) / 100
        ZStack {
            Circle().stroke(.white.opacity(0.22), lineWidth: 5)
            Circle()
                .trim(from: 0, to: level)
                .stroke(level < 0.2 ? Color.red : .white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Image(systemName: status.symbol)
                    .font(.system(size: 13, weight: .semibold))
                Text("\(status.level ?? 0)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .padding(10)
        .help(status.name)
    }
}

struct VolumeRing: View {
    let level: Double

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.22), lineWidth: 5)
            Circle()
                .trim(from: 0, to: level)
                .stroke(.white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: level <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                  variableValue: level)
                .font(.system(size: 17, weight: .semibold))
        }
        .padding(10)
        .animation(IslandMotion.quick, value: level)
    }
}

struct NowPlayingMini: View {
    let store: PlayerStore
    @Bindable var model: LockModel

    var body: some View {
        HStack(spacing: 10) {
            CoverArtView(image: store.artwork)
                .frame(width: 44, height: 44)
                .clipShape(.rect(cornerRadius: 10, style: .continuous))
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.miniArtFrame = $0 }
                .shrinksIntoAlbum(model.isAlbumOpen)
            VStack(alignment: .leading, spacing: 2) {
                MarqueeText(text: store.title).font(.system(size: 13, weight: .semibold))
                MarqueeText(text: store.subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                PlaybackClock(timing: store.timing, steps: 2) { date in
                    let duration = store.duration
                    let fraction = duration > 0 ? store.elapsed(at: date) / duration : 0
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.25))
                            Capsule().fill(.white).frame(width: geo.size.width * min(max(fraction, 0), 1))
                        }
                    }
                    .frame(height: 3)
                }
                .padding(.top, 4)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .contentShape(Rectangle())
        .onTapGesture { model.expandFromMini() }
        .help("Show artwork")
    }
}

// MARK: - Motion background

/// The song's motion artwork filling the lock screen behind the widgets, fading in once
/// the video is ready and darkened at the top and bottom so the clock and controls read.
struct LockMotionBackground: View {
    let store: PlayerStore
    @Bindable var model: LockModel
    let settings: AppSettings

    /// Something opaque is up (motion artwork or the aurora).
    private var covering: Bool {
        guard model.isPresented, !model.isAlbumOpen else { return false }
        let motion = settings.lockMotionBackground && !LiveTuning.shared.batterySaving && (store.motion?.tall ?? store.motion?.square) != nil
        return motion || (settings.lockAurora && store.hasTrack && store.artwork != nil)
    }

    var body: some View {
        ZStack {
            if model.isPresented, settings.lockMotionBackground, !model.isAlbumOpen, !LiveTuning.shared.batterySaving,
               let url = store.motion?.tall ?? store.motion?.square {
                LoopingVideoView(url: url)
                    .overlay {
                        LinearGradient(stops: [.init(color: .black.opacity(0.45), location: 0),
                                               .init(color: .black.opacity(0.1), location: 0.45),
                                               .init(color: .black.opacity(0.5), location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                    }
                    .transition(.opacity)
                    .id(url)
            } else if model.isPresented, settings.lockAurora, !model.isAlbumOpen, store.hasTrack, let art = store.displayArtwork {
                // No motion artwork for this song: its colours as an aurora instead.
                AlbumAurora(artwork: art, song: store.trackChangeCount, animated: !IslandMotion.reduced)
                    .transition(.opacity)
            }
        }
        // This window sits over loginwindow's own clock: draw the same clock in the same
        // place on top, as the on-screen lyrics do.
        .overlay(alignment: .top) {
            if covering {
                GeometryReader { geo in
                    SystemClockView(screenHeight: geo.size.height)
                        .frame(width: geo.size.width, height: model.clockInset)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: store.motion?.tall ?? store.motion?.square)
        .onChange(of: covering, initial: true) { _, now in model.backdropCovered = now }
    }
}

// MARK: - Player

/// The lock-screen Now Playing platter. Clicking the artwork fills the lock screen with it.
struct LockPlayerPlatter: View {
    let store: PlayerStore
    @Bindable var model: LockModel

    var body: some View {
        if model.isPresented { platter }
    }

    private var platter: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                CoverArtView(image: store.artwork, motionURL: store.motion?.square)
                    .frame(width: 58, height: 58)
                    .clipShape(.rect(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.playerArtFrame = $0 }
                    .onTapGesture { model.expandFromPlayer() }
                    .help("Show artwork")
                    .shrinksIntoAlbum(model.isAlbumOpen)
                VStack(alignment: .leading, spacing: 3) {
                    MarqueeText(text: store.title).font(.system(size: 15, weight: .semibold))
                    MarqueeText(text: store.subtitle).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                }
                .lineLimit(1)
                Spacer(minLength: 6)
                EqualizerBars(isPlaying: store.isPlaying, color: Color(rgb: store.palette.accent))
                    .frame(width: 24, height: 18)
            }
            ScrubberRow(store: store)
            TransportRow(store: store, scale: 0.9, look: .highlight)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .frame(width: 410)
        .foregroundStyle(.white)
        .lockGlass(cornerRadius: 34)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.wallpaper, model.playerWallpaper)
        .environment(\.liveBackdrop, model.backdropCovered)
        .environment(\.colorScheme, .dark)
        .environment(\.appearsActive, true)
    }
}

// MARK: - Open album (full screen)

/// The lock screen's open album: the desktop player, laid out below the clock, with the
/// clock drawn in the lock screen's own typeface over the full-screen background.
struct LockAlbumView: View {
    let store: PlayerStore
    @Bindable var lock: LockModel
    @Bindable var player: FullPlayerModel

    var body: some View {
        FullPlayerView(model: player, store: store, topInset: lock.clockInset, showsClock: true)
            .environment(\.colorScheme, .dark)
            .environment(\.appearsActive, true)
    }
}

extension View {
    /// The small cover gives way to the big one growing out of the same spot: it shrinks
    /// into itself as the album opens (outside the frame readers, which still report the
    /// resting frame for the hero), and grows back once it has closed.
    func shrinksIntoAlbum(_ open: Bool) -> some View {
        scaleEffect(open ? 0.55 : 1)
            .opacity(open ? 0 : 1)
            .animation(open ? .easeIn(duration: 0.2) : IslandMotion.playful, value: open)
    }
}
