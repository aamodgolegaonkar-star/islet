import IsletCore
import SwiftUI

// Live demos for the tutorial's feature pages. Each is a small, self-running sketch of the
// real feature, drawn in the island's black-and-glass look.

/// "What's New": the update's features as glass chips that pop in one by one.
struct WhatsNewHero: View {
    let pages: [Page]
    @State private var shown = 0

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles")
                .font(.system(size: 54, weight: .light))
                .symbolEffect(.bounce, value: shown)
            FlowChips(titles: pages.map(\.chip), shown: shown)
                .frame(width: 620)
        }
        .task {
            for count in 1...max(pages.count, 1) {
                try? await Task.sleep(for: .milliseconds(160))
                withAnimation(IslandMotion.playful) { shown = count }
            }
        }
    }
}

private struct FlowChips: View {
    let titles: [(String, String)]
    let shown: Int

    var body: some View {
        let rows = stride(from: 0, to: titles.count, by: 3).map { Array($0..<min($0 + 3, titles.count)) }
        VStack(spacing: 10) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(spacing: 10) {
                    ForEach(rows[row], id: \.self) { index in
                        Label(titles[index].0, systemImage: titles[index].1)
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .glassEffect(.regular, in: Capsule())
                            .scaleEffect(index < shown ? 1 : 0.5)
                            .opacity(index < shown ? 1 : 0)
                    }
                }
            }
        }
    }
}

extension Page {
    /// Short name and glyph for the What's New chips.
    var chip: (String, String) {
        switch self {
        case .controls: ("Output picker", "airpods.pro")
        case .sound: ("Equalizer", "slider.vertical.3")
        case .levels: ("Edge slider", "speaker.wave.2.fill")
        case .shelf: ("Clipboard", "doc.on.clipboard.fill")
        case .webPlayers: ("Web players", "globe")
        case .lockWidgets: ("Lock widgets", "cloud.sun.fill")
        case .lockCustomize: ("Your widgets", "square.grid.3x1.below.line.grid.1x2")
        case .island: ("Island", "capsule.fill")
        case .swipeSkip: ("Swipe to skip", "hand.draw.fill")
        case .outOfTheWay: ("Hide when paused", "eye.slash.fill")
        case .motion: ("Smoother motion", "wind")
        case .colors: ("Color themes", "paintpalette.fill")
        case .standby: ("Standby", "clock.fill")
        case .portal: ("Portal", "iphone.radiowaves.left.and.right")
        case .faceID: ("Face ID", "faceid")
        case .feel: ("Haptics", "hand.tap.fill")
        case .player: ("Player", "music.note")
        case .wordLyrics: ("Word-by-word lyrics", "quote.bubble.fill")
        case .screenLyrics: ("Lyrics on screen", "text.bubble.fill")
        case .edgeGlow: ("Edge glow", "light.max")
        case .wallLyrics: ("Wall lyrics", "rectangle.stack.fill")
        case .glowBeat: ("Glow to the beat", "waveform")
        case .activities: ("Live activities", "bolt.fill")
        case .lock: ("Lock screen", "lock.fill")
        case .agents: ("Coding agents", "terminal.fill")
        case .welcome, .whatsNew, .done: (title, "star.fill")
        }
    }
}

/// One line sung on a loop, through the three looks: word by word, Fisheye, and Fisheye
/// with icons. Drawn by the player's own `SungWords`.
struct WordLyricsDemo: View {
    private static let line = "I see fire in the night sky"
    private static let words: [LyricWord] = {
        let lines = LRCParser.parse("[00:00.50]\(line)\n[00:04.00]", duration: 4)
        return (WordSymbols.system?.annotate(lines) ?? lines).first { !$0.isInterlude }?.words ?? []
    }()
    private static let loop: TimeInterval = 4
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(start)
            let round = Int(elapsed / Self.loop) % 3
            let focus = WordTiming.focus(in: Self.words, at: elapsed.truncatingRemainder(dividingBy: Self.loop))
            VStack(alignment: .leading, spacing: 22) {
                SungWords(words: Self.words, focus: focus, fontSize: 34, fisheye: round > 0, icons: round == 2)
                    .frame(width: 560, alignment: .leading)
                Text(["Word by Word", "Fisheye", "Fisheye with icons"][round])
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .contentTransition(.opacity)
            }
            .padding(.top, 30)
        }
    }
}

/// The on-screen lyrics' stack of words rolling through a line, drawn by the real `WordStack`.
struct ScreenLyricsDemo: View {
    private static let words: [LyricWord] = {
        let line = "Now when you see me I'm stunning"
        let lines = LRCParser.parse("[00:00.20]\(line)\n[00:03.80]", duration: 4)
        return (WordSymbols.system?.annotate(lines) ?? lines).first { !$0.isInterlude }?.words ?? []
    }()
    private static let stream = WordStream(lines: [LyricLine(id: 0, start: 0, end: 4, text: "", words: words)])
    private static let ink = ScreenInk(text: Color(rgb: AppSettings.defaultScreenLyricsColors.text),
                                       highlight: Color(rgb: AppSettings.defaultScreenLyricsColors.highlight),
                                       highlightText: .white)
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let time = context.date.timeIntervalSince(start).truncatingRemainder(dividingBy: 4.6)
            let current = Self.stream.isResting(at: time) ? nil : Self.stream.index(at: time)
            let progress = current.map { index -> Double in
                let word = Self.words[index]
                return min(max((time - word.start) / max(word.end - word.start, 0.05), 0), 1)
            } ?? 0
            WordStack(words: Self.words, current: current, progress: progress, size: 64,
                      font: .sfPro, ink: Self.ink, icons: true, lensed: LyricLens.isAvailable)
                .frame(width: 560, height: 294)
                .lyricLens(size: CGSize(width: 560, height: 294))
        }
    }
}

/// A small screen whose edges glow in one album's colors, then the next.
struct EdgeGlowDemo: View {
    private static let albums: [Palette] = [
        Palette(colors: [RGB(0.5, 0.1, 0.4), RGB(0.1, 0.2, 0.6)], accent: RGB(0.98, 0.36, 0.6)),
        Palette(colors: [RGB(0.6, 0.3, 0.05), RGB(0.5, 0.05, 0.05)], accent: RGB(1, 0.62, 0.2)),
        Palette(colors: [RGB(0.05, 0.4, 0.4), RGB(0.1, 0.15, 0.5)], accent: RGB(0.3, 0.95, 0.8)),
    ]
    @State private var index = 0
    @State private var bright = false

    var body: some View {
        let colors = Self.albums[index].glowColors.map { Color(rgb: $0) }
        let ring = AngularGradient(colors: colors + colors.prefix(1), center: .center)
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        ZStack {
            shape.fill(.black.opacity(0.55))
            ZStack {
                shape.strokeBorder(ring, lineWidth: 18).blur(radius: 14).opacity(0.85)
                shape.strokeBorder(ring, lineWidth: 2.5).blur(radius: 2)
            }
            .clipShape(shape)
            .opacity(bright ? 1 : 0.65)
            Image(systemName: "music.note")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
        }
        .frame(width: 360, height: 210)
        .animation(.easeInOut(duration: 1.2), value: index)
        .task {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { bright = true }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.4))
                index = (index + 1) % Self.albums.count
            }
        }
    }
}

/// Four lines on the Wall, sung on a loop, drawn by the real `WallLyrics`.
struct WallLyricsDemo: View {
    private static let lines: [LyricLine] = {
        let lrc = "[00:00.30]The night is young\n[00:01.80]Turn the music up\n[00:03.30]Hearts on fire\n[00:04.80]Dancing till the sun\n[00:06.60]"
        let parsed = LRCParser.parse(lrc, duration: 7)
        return WordSymbols.system?.annotate(parsed) ?? parsed
    }()
    private static let ink = ScreenInk(text: Color(rgb: AppSettings.defaultScreenLyricsColors.text),
                                       highlight: Color(rgb: AppSettings.defaultScreenLyricsColors.highlight),
                                       highlightText: .white)
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let time = context.date.timeIntervalSince(start).truncatingRemainder(dividingBy: 7.5)
            WallLyrics(lines: Self.lines, time: time, size: 30, font: .sfPro, ink: Self.ink,
                       icons: true, maxWidth: 480)
                .frame(width: 560, height: 230)
                .padding(.bottom, 30)
        }
    }
}

/// A small screen with a notch whose edge glow flares on a steady beat.
struct GlowBeatDemo: View {
    private static let palette = Palette(colors: [RGB(0.5, 0.1, 0.4), RGB(0.1, 0.2, 0.6)], accent: RGB(0.98, 0.36, 0.6))
    @State private var start = Date()

    var body: some View {
        let colors = Self.palette.glowColors.map { Color(rgb: $0) }
        let ring = AngularGradient(colors: colors + colors.prefix(1), center: .center)
        let rim = GlowRim(notch: CGSize(width: 70, height: 14), cornerRadius: 14)
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let beat = context.date.timeIntervalSince(start).truncatingRemainder(dividingBy: 0.5)
            let flare = exp(-beat / 0.12)
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.55))
                ZStack {
                    rim.stroke(ring, lineWidth: 36).blur(radius: 14)
                    rim.stroke(ring, lineWidth: 5).blur(radius: 2)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .opacity(0.55 + 0.45 * flare)
                Image(systemName: "waveform")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .scaleEffect(1 + 0.12 * flare)
            }
            .frame(width: 360, height: 210)
        }
    }
}

/// A cycle of the island's live activities.
struct ActivitiesDemo: View {
    @State private var step = 0

    var body: some View {
        ZStack {
            switch step {
            case 0: pill(width: 300) {
                Image(systemName: "bolt.fill").foregroundStyle(.green)
                Text("Charging").fontWeight(.semibold)
                Spacer()
                Text("82%").foregroundStyle(.green).fontWeight(.semibold)
            }
            case 1: pill(width: 360, height: 92) {
                Image(systemName: "airpods.pro").font(.system(size: 40))
                VStack(alignment: .leading) {
                    Text("AirPods Pro").fontWeight(.semibold)
                    Text("Connected").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                Text("L 90  R 88").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.green)
            }
            case 2: pill(width: 260) {
                Image(systemName: "timer").foregroundStyle(.orange)
                Spacer()
                Text("24:59").font(.system(size: 15, weight: .semibold).monospacedDigit()).foregroundStyle(.orange)
            }
            default: pill(width: 220) {
                Image(systemName: "music.note")
                Spacer()
                Circle().fill(.orange).frame(width: 7, height: 7)
            }
            }
        }
        .id(step)
        .transition(.scale(scale: 0.7).combined(with: .opacity))
        .scaleEffect(1.3)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(IslandMotion.playful) { step = (step + 1) % 4 }
            }
        }
    }

    private func pill(width: CGFloat, height: CGFloat = 40, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 10) { content() }
            .font(.system(size: 14))
            .padding(.horizontal, 16)
            .frame(width: width, height: height)
            .background(RoundedRectangle(cornerRadius: height / 2.2, style: .continuous).fill(.black))
    }
}

/// The level in the island, then on the screen's edge.
struct LevelsDemo: View {
    @State private var edge = false
    @State private var level = 0.4

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.25), lineWidth: 1.5)
                .frame(width: 440, height: 220)
            // The island's version.
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill")
                Capsule().fill(.white.opacity(0.2)).frame(width: 110, height: 5)
                    .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: 110 * level, height: 5) }
                Text("\(Int(level * 100))").font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(.black))
            .offset(y: -88)
            .opacity(edge ? 0 : 1)
            // The edge slider.
            VStack(spacing: 8) {
                Capsule().fill(.white.opacity(0.2)).frame(width: 7, height: 110)
                    .overlay(alignment: .bottom) { Capsule().fill(.white).frame(width: 7, height: 110 * level) }
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 11))
            }
            .padding(.vertical, 12)
            .frame(width: 34)
            .glassEffect(.regular, in: Capsule())
            .offset(x: 190)
            .opacity(edge ? 1 : 0)
            .scaleEffect(edge ? 1 : 0.8)
        }
        .task {
            while !Task.isCancelled {
                for target in [0.7, 0.55, 0.85] {
                    try? await Task.sleep(for: .milliseconds(500))
                    withAnimation(IslandMotion.quick) { level = target }
                }
                try? await Task.sleep(for: .milliseconds(500))
                withAnimation(IslandMotion.subtle) { edge.toggle() }
            }
        }
    }
}

/// The output picker with AirPods noise control.
struct OutputDemo: View {
    @State private var chosen = 1
    @State private var mode = 0
    private let outputs = [("MacBook Pro Speakers", "laptopcomputer"), ("AirPods Pro", "airpods.pro"),
                           ("Living Room HomePod", "homepod.fill")]
    private let modes = [("Noise Cancellation", "person.crop.circle.badge.minus"), ("Transparency", "person.wave.2.fill"),
                         ("Adaptive", "sparkles")]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header("Sound Output")
            ForEach(outputs.indices, id: \.self) { index in
                row(outputs[index].0, symbol: outputs[index].1, on: index == chosen)
            }
            Divider().overlay(.white.opacity(0.2)).padding(.vertical, 3)
            header("Noise Control")
            ForEach(modes.indices, id: \.self) { index in
                row(modes[index].0, symbol: modes[index].1, on: index == mode)
            }
        }
        .padding(12)
        .frame(width: 280)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.4))
                withAnimation(IslandMotion.quick) { mode = (mode + 1) % modes.count }
                if mode == 0 { withAnimation(IslandMotion.quick) { chosen = (chosen + 1) % outputs.count == 0 ? 1 : 2 } }
            }
        }
    }

    private func header(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5)).padding(.leading, 6)
    }

    private func row(_ title: String, symbol: String, on: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).opacity(on ? 1 : 0)
            Image(systemName: symbol).frame(width: 20)
            Text(title)
            Spacer()
        }
        .font(.system(size: 13))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor.opacity(0.35) : .clear))
    }
}

/// An equalizer moving between presets, beside bars that follow the beat.
struct SoundDemo: View {
    @State private var preset = 0
    @State private var beat = [0.4, 0.7, 0.5, 0.3]
    private let presets: [[Double]] = [EqualizerPreset.bassBoost.bands, EqualizerPreset.vocal.bands,
                                       EqualizerPreset.trebleBoost.bands, EqualizerPreset.flat.bands]

    var body: some View {
        HStack(spacing: 44) {
            HStack(alignment: .center, spacing: 10) {
                ForEach(0..<10, id: \.self) { band in
                    let gain = presets[preset][band]
                    ZStack {
                        Capsule().fill(.white.opacity(0.15)).frame(width: 4, height: 150)
                        Circle().fill(.white).frame(width: 14, height: 14).offset(y: -gain / 12 * 68)
                    }
                }
            }
            .animation(IslandMotion.panel, value: preset)
            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { bar in
                    Capsule().fill(Color.orange.gradient).frame(width: 9, height: 12 + 60 * beat[bar])
                }
            }
            .frame(height: 80)
            .animation(.linear(duration: 0.12), value: beat)
        }
        .task {
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(130))
                beat = beat.map { _ in Double.random(in: 0.1...1) }
                tick += 1
                if tick % 12 == 0 { preset = (preset + 1) % presets.count }
            }
        }
    }
}

/// Files on the shelf, then the Clipboard tab.
struct ShelfDemo: View {
    @State private var clipboard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                tab("Files", "tray.full.fill", on: !clipboard)
                tab("Clipboard", "doc.on.clipboard.fill", on: clipboard)
            }
            HStack(spacing: 10) {
                if clipboard {
                    card { Text("Meeting notes for Friday…").font(.system(size: 11)) }
                    card {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("apple.com").font(.system(size: 11, weight: .semibold))
                            Text("https://apple.com/macos").font(.system(size: 10)).foregroundStyle(.blue)
                        }
                    }
                    card { Image(systemName: "photo.fill").font(.system(size: 26)).foregroundStyle(.white.opacity(0.7)) }
                } else {
                    ForEach(["doc.richtext.fill", "photo.fill", "film.fill"], id: \.self) { symbol in
                        VStack(spacing: 4) {
                            Image(systemName: symbol).font(.system(size: 30))
                            Text("File").font(.system(size: 10)).foregroundStyle(.white.opacity(0.7))
                        }
                        .frame(width: 92, height: 70)
                    }
                }
            }
            .transition(.opacity)
        }
        .padding(18)
        .frame(width: 400, height: 150, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 34, style: .continuous).fill(.black))
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                withAnimation(IslandMotion.subtle) { clipboard.toggle() }
            }
        }
    }

    private func tab(_ title: String, _ symbol: String, on: Bool) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(on ? 1 : 0.5))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(.white.opacity(on ? 0.16 : 0)))
    }

    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(8)
            .frame(width: 112, height: 70, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.1)))
    }
}

/// The open island naming the service a browser tab plays.
struct WebPlayerDemo: View {
    @State private var index = 0
    private let services = ["YouTube Music", "Deezer", "Qobuz", "SoundCloud", "Tidal", "Bandcamp"]

    var body: some View {
        HStack(spacing: 13) {
            RoundedRectangle(cornerRadius: 13)
                .fill(LinearGradient(colors: [.red, .pink], startPoint: .top, endPoint: .bottom))
                .frame(width: 54, height: 54)
                .overlay(Image(systemName: "globe").font(.system(size: 22)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Your Song").font(.system(size: 15, weight: .semibold))
                HStack(spacing: 0) {
                    Text("Your Artist · ").foregroundStyle(.white.opacity(0.62))
                    Text(services[index])
                        .foregroundStyle(.white)
                        .id(index)
                        .transition(.push(from: .bottom).combined(with: .opacity))
                }
                .font(.system(size: 13))
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(width: 400, height: 110)
        .background(RoundedRectangle(cornerRadius: 36, style: .continuous).fill(.black))
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.3))
                withAnimation(IslandMotion.subtle) { index = (index + 1) % services.count }
            }
        }
    }
}

/// The lock screen's widget row.
struct LockWidgetsDemo: View {
    @State private var shown = false

    var body: some View {
        VStack(spacing: 10) {
            Text("9:41").font(.system(size: 64, weight: .semibold, design: .rounded))
            HStack(spacing: 12) {
                circle {
                    VStack(spacing: 0) {
                        Image(systemName: "cloud.sun.fill").symbolRenderingMode(.multicolor)
                        Text("18°").font(.system(size: 15, weight: .semibold))
                    }
                }
                circle(ring: 0.8) { Text("80").font(.system(size: 15, weight: .semibold)) }
                circle(ring: 0.6) { Image(systemName: "speaker.wave.2.fill") }
                circle(ring: 0.9) {
                    VStack(spacing: 0) {
                        Image(systemName: "airpods.pro").font(.system(size: 12))
                        Text("90").font(.system(size: 13, weight: .semibold))
                    }
                }
            }
            .scaleEffect(shown ? 1 : 0.6)
            .opacity(shown ? 1 : 0)
        }
        .onAppear { withAnimation(IslandMotion.playful.delay(0.3)) { shown = true } }
    }

    private func circle(ring: Double? = nil, @ViewBuilder _ content: () -> some View) -> some View {
        ZStack {
            if let ring {
                Circle().stroke(.white.opacity(0.22), lineWidth: 4)
                Circle().trim(from: 0, to: ring).stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            content()
        }
        .padding(8)
        .frame(width: 62, height: 62)
        .glassEffect(.regular, in: Circle())
    }
}

/// The lock-screen row rearranging itself: a Date tile joins, then two tiles swap.
/// Clicking a tile removes it; it comes back on the next round.
struct LockCustomizeDemo: View {
    @State private var tiles: [LockWidget] = [.battery, .volume, .headphones]
    @State private var round = 0

    var body: some View {
        VStack(spacing: 10) {
            Text("9:41").font(.system(size: 64, weight: .semibold, design: .rounded))
            HStack(spacing: 12) {
                ForEach(tiles) { widget in
                    tile(widget)
                        .onTapGesture {
                            withAnimation(IslandMotion.subtle) { tiles.removeAll { $0 == widget } }
                        }
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(height: 62)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.4))
                step()
            }
        }
    }

    private func step() {
        withAnimation(IslandMotion.panel) {
            switch round % 4 {
            case 0: tiles.insert(.date, at: 0)
            case 1: if tiles.count > 2 { tiles.swapAt(1, 2) }
            case 2: tiles.append(.worldClock)
            default: tiles = [.battery, .volume, .headphones]
            }
        }
        round += 1
    }

    private func tile(_ widget: LockWidget) -> some View {
        Group {
            switch widget {
            case .date: DateTile()
            case .worldClock: WorldClockTile(zone: TimeZone(identifier: "Asia/Tokyo") ?? .current)
            case .battery: BatteryRing(battery: BatteryState(level: 0.8, isCharging: false, isPluggedIn: false))
            case .volume: VolumeRing(level: 0.6)
            default:
                HeadphoneRing(status: HeadphoneStatus(name: "AirPods", symbol: "airpods.pro",
                                                      battery: HeadphoneBattery(left: 90, right: 90)))
            }
        }
        .frame(width: 62, height: 62)
        .glassEffect(.regular, in: Circle())
    }
}

/// A coding agent asking for attention.
struct AgentDemo: View {
    @State private var done = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: done ? "checkmark.circle.fill" : "exclamationmark.bubble.fill")
                .font(.system(size: 34))
                .foregroundStyle(done ? .green : .orange)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Code").font(.system(size: 15, weight: .semibold))
                Text(done ? "Finished: all tests pass" : "Needs permission to run a command")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.65))
                    .contentTransition(.opacity)
            }
            Spacer()
        }
        .padding(.horizontal, 22)
        .frame(width: 400, height: 90)
        .background(RoundedRectangle(cornerRadius: 34, style: .continuous).fill(.black))
        .scaleEffect(1.2)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.8))
                withAnimation(IslandMotion.subtle) { done.toggle() }
            }
        }
    }
}

/// Two fingers slide over the island and the next song slides in.
struct SwipeSkipDemo: View {
    private static let songs: [(String, [Color])] = [
        ("Your Song", [.pink, .orange]), ("Next Song", [.blue, .purple]), ("Another One", [.green, .teal]),
    ]
    @State private var index = 0
    @State private var swiping = false

    var body: some View {
        VStack(spacing: 18) {
            // The songs slide inside the pill, never past its edges.
            ZStack {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(LinearGradient(colors: Self.songs[index].1, startPoint: .top, endPoint: .bottom))
                        .frame(width: 26, height: 26)
                    Text(Self.songs[index].0).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    Spacer(minLength: 0)
                    Image(systemName: "waveform").foregroundStyle(Self.songs[index].1[0])
                }
                .padding(.horizontal, 10)
                .id(index)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
            }
            .frame(width: 300, height: 42)
            .background(.black)
            .clipShape(.rect(cornerRadius: 19, style: .continuous))
            Image(systemName: "hand.point.up.left.fill")
                .font(.system(size: 30))
                .foregroundStyle(.white.opacity(0.8))
                .offset(x: swiping ? -70 : 70)
                .opacity(swiping ? 0 : 1)
        }
        .scaleEffect(1.3)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(.easeInOut(duration: 0.55)) { swiping = true }
                try? await Task.sleep(for: .milliseconds(300))
                withAnimation(IslandMotion.subtle) { index = (index + 1) % Self.songs.count }
                try? await Task.sleep(for: .milliseconds(500))
                swiping = false
            }
        }
    }
}

/// A paused song tucks away to the resting island; then the island ducks out of a
/// screen recording.
struct OutOfTheWayDemo: View {
    @State private var step = 0

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(step == 2 ? Color.red.opacity(0.8) : .white.opacity(0.15),
                                  style: StrokeStyle(lineWidth: 1.5, dash: step == 2 ? [6, 4] : []))
                    .frame(width: 340, height: 120)
                pill
                    .opacity(step == 2 ? 0 : 1)
                    .frame(maxHeight: 120, alignment: .top)
                    .padding(.top, 10)
            }
            .frame(height: 120)
            Label(caption.0, systemImage: caption.1)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .contentTransition(.opacity)
        }
        .scaleEffect(1.2)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.8))
                withAnimation(IslandMotion.subtle) { step = (step + 1) % 3 }
            }
        }
    }

    private var pill: some View {
        HStack(spacing: 10) {
            if step == 0 {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(LinearGradient(colors: [.pink, .orange], startPoint: .top, endPoint: .bottom))
                    .frame(width: 22, height: 22)
                    .transition(.scale.combined(with: .opacity))
                Spacer(minLength: 0)
                Image(systemName: "pause.fill").font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 9)
        .frame(width: step == 0 ? 210 : 110, height: 34)
        .background(Capsule().fill(.black))
    }

    private var caption: (String, String) {
        switch step {
        case 0: ("Paused", "pause.circle")
        case 1: ("The paused song tucks away", "eye.slash")
        default: ("Hidden from screen sharing", "rectangle.dashed.badge.record")
        }
    }
}

/// A photo leaves a little iPhone through its portal and bursts out of the island's.
struct PortalDemo: View {
    @State private var step = 0

    var body: some View {
        HStack(alignment: .center, spacing: 70) {
            // The phone, with its portal.
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.black)
                .frame(width: 112, height: 210)
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.25), lineWidth: 1.5))
                .overlay { PortalWell(effect: .vortex, energy: step == 1 ? 1 : 0.3).scaleEffect(1.1) }
                .overlay(alignment: .bottom) {
                    photo
                        .scaleEffect(step == 0 ? 1 : 0.05)
                        .rotationEffect(.degrees(step == 0 ? 0 : 540))
                        .offset(y: step == 0 ? -26 : -105)
                        .opacity(step == 0 ? 1 : 0)
                }
            // The island, with its portal.
            VStack(spacing: 0) {
                Rectangle().fill(.white.opacity(0.12)).frame(width: 300, height: 5)
                HStack(spacing: 12) {
                    ZStack {
                        PortalWell(effect: .vortex, energy: step == 2 ? 1 : 0.3)
                            .opacity(step == 0 ? 0 : 1)
                            .scaleEffect(step == 0 ? 0.2 : 1)
                        photo
                            .scaleEffect(step == 2 ? 1 : 0.05)
                            .rotationEffect(.degrees(step == 2 ? 0 : -540))
                            .opacity(step == 2 ? 1 : 0)
                    }
                    .frame(width: 76, height: 76)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Photo").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        Text("From iPhone").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                    }
                    .opacity(step == 2 ? 1 : 0)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(width: 260, height: 96)
                .background(UnevenRoundedRectangle(bottomLeadingRadius: 34, bottomTrailingRadius: 34, style: .continuous).fill(.black))
            }
            .offset(y: -40)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.1))
                withAnimation(.easeIn(duration: 0.7)) { step = 1 }
                try? await Task.sleep(for: .seconds(0.8))
                withAnimation(IslandMotion.playful) { step = 2 }
                try? await Task.sleep(for: .seconds(2.2))
                withAnimation(IslandMotion.quick) { step = 0 }
            }
        }
    }

    private var photo: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(LinearGradient(colors: [.pink, .orange, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 44, height: 44)
            .overlay(alignment: .topTrailing) { Circle().fill(.white.opacity(0.85)).frame(width: 9).padding(7) }
            .shadow(color: .cyan.opacity(0.6), radius: 8)
    }
}

/// Two unlocks, one after the other: Face ID, then Touch ID, each with its own animation.
struct FaceIDDemo: View {
    @State private var face = true
    @State private var phase = FaceScanPhase.scanning
    @State private var cycle = 0

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                if face {
                    FaceIDMark(phase: phase, size: 70)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                } else {
                    Image(systemName: "touchid")
                        .font(.system(size: 64, weight: .light))
                        .foregroundStyle(phase == .matched ? Color.green : .red)
                        .symbolEffect(.bounce, value: phase)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
            }
            .frame(width: 130, height: 130)
            Group {
                if face { FaceUnlockContent() } else { UnlockContent() }
            }
            .id(cycle)
            .frame(width: 230, height: 36)
            .background(Capsule().fill(.black))
            Text(face ? "Face ID" : "Touch ID")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
        .task {
            while !Task.isCancelled {
                withAnimation(IslandMotion.playful) { phase = .scanning }
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(IslandMotion.playful) { phase = .matched }
                try? await Task.sleep(for: .seconds(1.8))
                withAnimation(IslandMotion.subtle) {
                    face.toggle()
                    cycle += 1
                }
            }
        }
    }
}

/// Two desktops slide past under a swipe; the island rides off on the first and drops
/// onto the second with a little bounce.
struct MotionDemo: View {
    @State private var onSecond = false
    @State private var arrivals = 0

    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 18) {
                desktop(tint: Color(red: 0.25, green: 0.3, blue: 0.55), label: "Desktop 1", island: !onSecond)
                desktop(tint: Color(red: 0.5, green: 0.3, blue: 0.45), label: "Desktop 2", island: onSecond)
            }
            .offset(x: onSecond ? -169 : 169)
        }
        .frame(width: 340, height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.15)))
        .overlay(alignment: .bottom) {
            Image(systemName: "hand.draw.fill")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.75))
                .offset(x: onSecond ? -60 : 60, y: -14)
        }
        .scaleEffect(1.25)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.8))
                withAnimation(IslandMotion.panel) { onSecond.toggle() }
                try? await Task.sleep(for: .milliseconds(420))
                arrivals += 1
            }
        }
    }

    private func desktop(tint: Color, label: String, island: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(LinearGradient(colors: [tint, tint.opacity(0.5)], startPoint: .top, endPoint: .bottom))
            .frame(width: 320, height: 190)
            .overlay(alignment: .top) {
                Capsule().fill(.black)
                    .frame(width: 96, height: 24)
                    .padding(.top, 6)
                    .opacity(island ? 1 : 0)
                    .islandArrival(arrivals)
            }
            .overlay(alignment: .bottomLeading) {
                Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6)).padding(10)
            }
    }
}

/// The theme picker, live: click a color and the switch, slider, Portal and clock follow.
struct ColorsDemo: View {
    @State private var theme = AccentTheme.aurora
    @State private var on = true
    @State private var auto = true

    var body: some View {
        VStack(spacing: 22) {
            HStack(spacing: 26) {
                Text("9:41")
                    .font(.system(size: 54, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.gradient)
                PortalWell(effect: .vortex, energy: 0.6)
                    .frame(width: 80, height: 80)
                    .environment(\.portalTheme, theme)
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("", isOn: $on).toggleStyle(.switch).labelsHidden()
                    Capsule().fill(.white.opacity(0.15)).frame(width: 110, height: 5)
                        .overlay(alignment: .leading) { Capsule().fill(theme.tint).frame(width: 70, height: 5) }
                }
            }
            ThemePicker(selection: Binding(get: { theme }, set: { theme = $0; auto = false }))
        }
        .tint(theme.tint)
        .animation(IslandMotion.panel, value: theme)
        .scaleEffect(1.15)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.6))
                guard auto else { continue }
                let all = AccentTheme.allCases
                withAnimation(IslandMotion.playful) { theme = all[(all.firstIndex(of: theme)! + 1) % all.count] }
            }
        }
    }
}

/// A Mac on its charger fades from the desktop into Standby, then wakes again.
struct StandbyDemo: View {
    @State private var standby = false

    var body: some View {
        let theme = AccentTheme.aurora
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.25, green: 0.3, blue: 0.5), Color(red: 0.4, green: 0.3, blue: 0.45)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay {
                    RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.18)).frame(width: 150, height: 90).offset(x: -40, y: 6)
                }
            ZStack {
                Color.black
                RadialGradient(colors: [theme.colors[0].opacity(0.35), .clear], center: .topLeading, startRadius: 0, endRadius: 220)
                RadialGradient(colors: [theme.colors[2].opacity(0.25), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 220)
                HStack(spacing: 22) {
                    Text("10:09")
                        .font(.system(size: 64, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.gradient)
                        .offset(y: standby ? 0 : 14)
                        .blur(radius: standby ? 0 : 6)
                    VStack(spacing: 10) {
                        tile { Image(systemName: "music.note").foregroundStyle(theme.colors[2]) }
                            .offset(y: standby ? 0 : 18)
                        tile { Image(systemName: "bolt.fill").foregroundStyle(theme.colors[1]) }
                            .offset(y: standby ? 0 : 24)
                    }
                }
            }
            .opacity(standby ? 1 : 0)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .frame(width: 340, height: 210)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.18)))
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "powerplug.fill").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).padding(10)
        }
        .scaleEffect(1.2)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(standby ? IslandMotion.exit : IslandMotion.playful) { standby.toggle() }
                try? await Task.sleep(for: .seconds(standby ? 1.6 : 0))
            }
        }
    }

    private func tile<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.system(size: 18, weight: .semibold))
            .frame(width: 54, height: 44)
            .background(.white.opacity(0.08), in: .rect(cornerRadius: 12, style: .continuous))
    }
}
