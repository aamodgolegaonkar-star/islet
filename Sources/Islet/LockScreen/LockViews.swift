import IsletCore
import SwiftUI

extension View {
    /// A Liquid Glass tile over the wallpaper that is really behind it.
    @MainActor
    func lockGlass<S: Shape>(_ shape: S, glass: Glass? = nil) -> some View {
        self
            .snapshotSafeGlass(glass ?? .islet, in: shape)
            .background { WallpaperBackdrop().clipShape(shape) }
            .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
    }
}

// MARK: - Tiny widgets under the clock

struct LockWidgetsRow: View {
    let store: PlayerStore
    @Bindable var model: LockModel

    var body: some View {
        if model.isPresented { widgets }
    }

    private var widgets: some View {
        GlassContainer(spacing: 10) {
            HStack(spacing: 12) {
                if let battery = model.battery {
                    BatteryRing(battery: battery)
                        .frame(width: 66, height: 66)
                        .lockGlass(Circle())
                }
                if store.hasTrack {
                    NowPlayingMini(store: store, model: model)
                        .frame(width: 222, height: 66)
                        .lockGlass(RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
                VolumeRing(level: store.volume)
                    .frame(width: 66, height: 66)
                    .lockGlass(Circle())
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.wallpaper, model.widgetsWallpaper)
        .environment(\.colorScheme, .dark)
        .environment(\.appearsActive, true)
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
        .animation(.easeInOut(duration: 0.3), value: level)
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
            VStack(alignment: .leading, spacing: 2) {
                Text(store.title).font(.system(size: 13, weight: .semibold))
                Text(store.artist).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
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

// MARK: - Player

/// The lock-screen Now Playing platter. Clicking the artwork fills the lock screen with it.
struct LockPlayerPlatter: View {
    let store: PlayerStore
    @Bindable var model: LockModel

    private let shape = RoundedRectangle(cornerRadius: 34, style: .continuous)

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
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.title).font(.system(size: 15, weight: .semibold))
                    Text(store.artist).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
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
        .lockGlass(shape)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.wallpaper, model.playerWallpaper)
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
