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
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { shown = count }
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
        case .feel: ("Haptics", "hand.tap.fill")
        case .player: ("Player", "music.note")
        case .wordLyrics: ("Word-by-word lyrics", "quote.bubble.fill")
        case .screenLyrics: ("Lyrics on screen", "text.bubble.fill")
        case .edgeGlow: ("Edge glow", "light.max")
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
                withAnimation(.spring(response: 0.45, dampingFraction: 0.72)) { step = (step + 1) % 4 }
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
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { level = target }
                }
                try? await Task.sleep(for: .milliseconds(500))
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { edge.toggle() }
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
                withAnimation(.snappy) { mode = (mode + 1) % modes.count }
                if mode == 0 { withAnimation(.snappy) { chosen = (chosen + 1) % outputs.count == 0 ? 1 : 2 } }
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
            .animation(.spring(response: 0.5, dampingFraction: 0.75), value: preset)
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
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { clipboard.toggle() }
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
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { index = (index + 1) % services.count }
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
        .onAppear { withAnimation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.3)) { shown = true } }
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
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { tiles.removeAll { $0 == widget } }
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
        withAnimation(.spring(response: 0.5, dampingFraction: 0.78)) {
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
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { done.toggle() }
            }
        }
    }
}
