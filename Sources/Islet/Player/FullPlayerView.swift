import SwiftUI

/// Frames for the full-screen player in its modes. Computed explicitly (instead of
/// stacks) so the hero animation knows exactly where the cover lands. `topInset` reserves
/// space at the top (the lock screen's clock); everything else lays out below it.
///
/// With lyrics on: the lyrics column beside the cover, or, for Fisheye (`stage`), the cover
/// small in the bottom-left corner with the controls beside it and the big word stack
/// filling everything above.
struct PlayerLayout {
    let cover: CGRect
    let controls: CGRect
    let lyrics: CGRect
    let coverCorner: CGFloat

    static let controlsHeight: CGFloat = 264

    init(size: CGSize, showLyrics: Bool, stage: Bool = false, topInset: CGFloat = 0) {
        let w = size.width, y0 = topInset, h = size.height - topInset
        let minTop: CGFloat = topInset > 0 ? 14 : 48
        if showLyrics, stage {
            let margin: CGFloat = 36
            let bottom = y0 + h - margin
            let side = min(h * 0.22, 190)
            cover = CGRect(x: margin, y: bottom - side, width: side, height: side)
            controls = CGRect(x: cover.maxX + 30, y: bottom - Self.controlsHeight + 22,
                              width: min(420, w - cover.maxX - 30 - margin), height: Self.controlsHeight)
            // Above the corner, clear of the close button.
            let top = y0 + max(minTop, 80)
            lyrics = CGRect(x: 0, y: top, width: w, height: max(controls.minY - 12 - top, 120))
        } else if showLyrics {
            let side = min(h * 0.42, w * 0.29, 480, h - Self.controlsHeight - 30 - minTop * 2)
            let centerX = w * 0.27
            let top = y0 + max(minTop, h / 2 - (side + 30 + Self.controlsHeight) / 2)
            cover = CGRect(x: centerX - side / 2, y: top, width: side, height: side)
            let width = max(side + 40, 380)
            controls = CGRect(x: centerX - width / 2, y: cover.maxY + 30, width: width, height: Self.controlsHeight)
            lyrics = CGRect(x: w * 0.5, y: y0, width: w * 0.44, height: h)
        } else {
            let side = min(h * 0.5, w * 0.4, 560, h - Self.controlsHeight - 34 - minTop * 2)
            let block = side + 34 + Self.controlsHeight
            let top = y0 + max(minTop, (h - block) / 2 - (topInset > 0 ? 0 : 8))
            cover = CGRect(x: w / 2 - side / 2, y: top, width: side, height: side)
            let width = max(side + 60, 440)
            controls = CGRect(x: w / 2 - width / 2, y: cover.maxY + 34, width: width, height: Self.controlsHeight)
            lyrics = CGRect(x: w * 0.56, y: y0, width: w * 0.44, height: h)
        }
        coverCorner = max(10, cover.width * 0.035)
    }
}

/// Apple Music-style full-screen Now Playing. Also used on the lock screen, where it
/// leaves `topInset` for the clock and draws the clock in the lock screen's own typeface.
struct FullPlayerView: View {
    @Bindable var model: FullPlayerModel
    let store: PlayerStore
    var topInset: CGFloat = 0
    var showsClock = false

    var body: some View {
        if model.isPresented {
            player
        }
    }

    private var player: some View {
        GeometryReader { geo in
            let size = geo.size
            let stage = LiveTuning.shared.lyricStyle == .fisheye
            let layout = PlayerLayout(size: size, showLyrics: model.showLyrics, stage: stage, topInset: topInset)
            let open = model.isOpen
            let background = open ? CGRect(origin: .zero, size: size) : model.origin
            let cover = open ? layout.cover : model.origin
            let motionURL = store.motion?.square

            ZStack(alignment: .topLeading) {
                // 1. The artwork blooms out of its origin and becomes the background.
                PlayerBackground(store: store, isOpen: open)
                    .frame(width: background.width, height: background.height)
                    .clipShape(.rect(cornerRadius: open ? 0 : model.originCornerRadius, style: .continuous))
                    .offset(x: background.minX, y: background.minY)

                if showsClock {
                    // The lock screen's own date and Liquid Glass clock, where loginwindow puts them.
                    SystemClockView(screenHeight: size.height)
                        .frame(width: size.width, height: topInset)
                        .opacity(open ? 1 : 0)
                        .animation(.easeOut(duration: 0.35).delay(open ? 0.12 : 0), value: open)
                }

                // 2. The sharp cover springs from its origin to its place in the layout.
                CoverArtView(image: store.displayArtwork, motionURL: motionURL)
                    .frame(width: cover.width, height: cover.height)
                    .clipShape(.rect(cornerRadius: open ? layout.coverCorner : model.originCornerRadius,
                                     style: .continuous))
                    .shadow(color: .black.opacity(open ? 0.38 : 0), radius: 34, y: 20)
                    .scaleEffect(store.isPlaying || !open ? 1 : 0.9)
                    .offset(x: cover.minX, y: cover.minY)
                    .animation(IslandMotion.playful, value: store.isPlaying)
                    .onTapGesture { toggleLyrics() }

                // 3. Controls and lyrics fade in once the hero is under way.
                PlayerControls(store: store, model: model)
                    .frame(width: layout.controls.width, height: layout.controls.height, alignment: .top)
                    .offset(x: layout.controls.minX, y: layout.controls.minY + (open ? 0 : 26))
                    .opacity(open ? 1 : 0)
                    .animation(.easeOut(duration: open ? 0.4 : 0.12).delay(open ? 0.14 : 0), value: open)

                if model.showLyrics {
                    Group {
                        if stage {
                            StageLyrics(store: store, size: layout.lyrics.size)
                        } else {
                            LyricsPanel(store: store)
                        }
                    }
                        .frame(width: layout.lyrics.width, height: layout.lyrics.height)
                        .offset(x: layout.lyrics.minX, y: layout.lyrics.minY)
                        .opacity(open ? 1 : 0)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(x: 70)).animation(IslandMotion.panel.delay(0.08)),
                            removal: .opacity.combined(with: .offset(x: 40)).animation(IslandMotion.quick)))
                }

                closeButton
                    .offset(x: 26, y: 26)
                    .opacity(open ? 1 : 0)
                    .animation(IslandMotion.quick.delay(open ? 0.2 : 0), value: open)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .ignoresSafeArea()
    }

    private var closeButton: some View {
        Button { model.close() } label: {
            Image(systemName: "chevron.down").font(.system(size: 17, weight: .semibold))
        }
        .buttonStyle(GlassIconButtonStyle(diameter: 44, look: .glass))
        .help("Close (Esc)")
    }

    private func toggleLyrics() {
        withAnimation(IslandMotion.panel) { model.showLyrics.toggle() }
    }
}

/// Shuffle and repeat, for players Islet can control that way (Music, Spotify).
struct PlaybackOptionsRow: View {
    let store: PlayerStore

    var body: some View {
        Group {
            if let shuffle = store.shuffle, let repeatMode = store.repeatMode {
                HStack {
                    option("shuffle", on: shuffle, id: "shuffle") { store.toggleShuffle() }
                        .help("Shuffle")
                    Spacer()
                    option(repeatMode == .one ? "repeat.1" : "repeat", on: repeatMode != .off, id: "repeat") {
                        store.cycleRepeat()
                    }
                    .help("Repeat")
                }
                .padding(.bottom, 10)
                .transition(.opacity)
            }
        }
        .task(id: store.trackChangeCount) { store.refreshPlaybackOptions() }
    }

    private func option(_ symbol: String, on: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(on ? 1 : 0.45))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(GlassIconButtonStyle(diameter: 34, look: on ? .glass : .glassOnHover))
        .routedClick(id, action: action)
    }
}

/// Title, scrubber, transport, volume and the lyrics toggle under the cover — every
/// control is Liquid Glass floating over the moving artwork background.
struct PlayerControls: View {
    let store: PlayerStore
    @Bindable var model: FullPlayerModel

    var body: some View {
        GlassContainer(spacing: 18) {
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.title)
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(store.subtitle)
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(.white.opacity(0.66))
                    }
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 1)
                    Spacer(minLength: 8)
                    Button {
                        withAnimation(IslandMotion.panel) { model.showLyrics.toggle() }
                    } label: {
                        Image(systemName: model.showLyrics ? "quote.bubble.fill" : "quote.bubble")
                            .font(.system(size: 16, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(GlassIconButtonStyle(diameter: 42, look: .glass))
                    .help("Lyrics (L)")
                }
                .padding(.bottom, 16)

                ScrubberRow(store: store, large: true, thumb: .always, steps: 8)
                    .padding(.bottom, 12)

                GlassControlsCapsule(store: store, scale: 1.15)
                    .padding(.bottom, 16)

                PlaybackOptionsRow(store: store)

                VolumeRow(store: store)
            }
        }
    }
}
