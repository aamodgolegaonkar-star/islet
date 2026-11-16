import IsletCore
import SwiftUI

/// What the on-screen lyrics show, kept by `ScreenLyricsController`.
@MainActor
@Observable
final class ScreenLyricsModel {
    var stream = WordStream(lines: [])
    var isVisible = false
    /// Font size of the large middle word.
    var wordSize: CGFloat = 180
    /// The widest a word may be drawn; longer words shrink to fit.
    var maxWordWidth: CGFloat = 900
    /// Where the stack's middle sits, in points down from the screen's centre.
    var centerOffset: CGFloat = 0
    /// On the lock screen: the album backdrop and the clock fill the screen behind the words.
    var onLockScreen = false
    /// Height of the clock area at the top of the lock screen.
    var clockInset: CGFloat = 300
}

/// The colors of the on-screen lyrics, after Verci's three color wells.
struct ScreenInk: Equatable {
    /// Words already sung.
    var text: Color
    /// The box behind the word being sung, and the icons.
    var highlight: Color
    /// The word being sung, inside its box.
    var highlightText: Color

    /// The colors picked in Settings, or (Match album colors) Verci's rule for the album: its
    /// vivid color for the box, a pale bright tint of the same hue for sung words, and black
    /// or white in the box, whichever reads.
    @MainActor
    static func current(palette: Palette) -> ScreenInk {
        if let picked = LiveTuning.shared.screenLyricsColors, picked.count == 3 {
            return ScreenInk(text: Color(rgb: picked[0]), highlight: Color(rgb: picked[1]),
                             highlightText: Color(rgb: picked[2]))
        }
        let accent = palette.accent
        let (hue, saturation, _) = accent.hsb
        let text = RGB(hue: hue, saturation: min(saturation, 0.45), brightness: 1)
        let luminance = 0.299 * accent.r + 0.587 * accent.g + 0.114 * accent.b
        return ScreenInk(text: Color(rgb: text), highlight: Color(rgb: accent),
                         highlightText: luminance > 0.55 ? .black : .white)
    }
}

/// Big lyrics on the screen itself, a word at a time, after Verci's Fisheye style.
///
/// A short stack of words sits in the middle of the screen. The word being sung appears
/// small at the bottom, in a highlight box that fills as it's sung. When the next word
/// starts, the stack rolls up: that word grows large in the middle as its box fades, then
/// shrinks into the top row and leaves. Rows tilt a little away from the middle, as if seen
/// through a lens. Between phrases the screen clears.
struct ScreenLyricsView: View {
    let store: PlayerStore
    let settings: AppSettings
    let model: ScreenLyricsModel

    /// Words appear a hair early, so the box leads the voice rather than trailing it.
    private static let lead: TimeInterval = 0.08

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                if model.onLockScreen {
                    // The full-screen player's backdrop: motion artwork, or the blurred,
                    // slowly drifting cover, with the lock screen's own clock over it.
                    PlayerBackground(store: store, isOpen: true)
                    // A little darker than the player, so pale words read on a light cover.
                    Color.black.opacity(0.28)
                    SystemClockView(screenHeight: geo.size.height)
                        .frame(width: geo.size.width, height: model.clockInset)
                }
                words(in: geo.size)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// The stack in a band across the screen, about five words tall (Verci's proportions),
    /// seen through the lens.
    private func words(in screen: CGSize) -> some View {
        let band = CGSize(width: screen.width, height: min(model.wordSize * 4.6, screen.height))
        return TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !model.isVisible || !store.isPlaying)) { context in
            let time = store.lyricsPosition(at: context.date) + Self.lead
            let ink = ScreenInk.current(palette: store.palette)
            Group {
                if settings.screenLyricsStyle == .wall, case .synced(let lines) = store.lyrics {
                    WallLyrics(lines: lines, time: time, size: (model.wordSize * 0.36).rounded(),
                               font: settings.screenLyricsFont, ink: ink, icons: settings.lyricWordIcons,
                               maxWidth: screen.width * 0.7)
                        .frame(width: band.width, height: band.height)
                } else {
                    let stream = model.stream
                    let current = stream.isResting(at: time) ? nil : stream.index(at: time)
                    WordStack(words: stream.words, current: current,
                              progress: current.map { WordStack.progress(of: stream.words[$0], at: time) } ?? 0,
                              size: model.wordSize, font: settings.screenLyricsFont, ink: ink,
                              icons: settings.lyricWordIcons, maxWidth: model.maxWordWidth, lensed: LyricLens.isAvailable)
                        .frame(width: band.width, height: band.height)
                        .lyricLens(size: band)
                }
            }
            .offset(y: model.centerOffset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The words around the one being sung, each in its row. Rows are keyed by the word's place
/// in the song, so when `current` moves on every word springs to its next row.
/// Shared with the tutorial's demo.
struct WordStack: View {
    let words: [LyricWord]
    let current: Int?
    let progress: Double
    let size: CGFloat
    let font: ScreenLyricsFont
    let ink: ScreenInk
    let icons: Bool
    var maxWidth: CGFloat?
    /// Drawn through `LyricLens`, which bends the outer rows itself.
    var lensed = false

    /// How far through `word` singing is at `time`, 0 to 1.
    static func progress(of word: LyricWord, at time: TimeInterval) -> Double {
        min(max((time - word.start) / max(word.end - word.start, 0.05), 0), 1)
    }

    var body: some View {
        ZStack {
            if let current {
                ForEach(max(0, current - 3)...min(words.count - 1, current + 1), id: \.self) { index in
                    StackWord(word: words[index], row: Row(slot: index - current, lensed: lensed), seed: index,
                              progress: index == current ? progress : 1,
                              size: size, font: font, ink: ink, icons: icons, maxWidth: maxWidth ?? size * 9)
                        .transition(.opacity)
                }
            }
        }
        // Verci's spring: quick, with a little overshoot.
        .animation(IslandMotion.respecting(.spring(response: 0.3, dampingFraction: 0.72)), value: current)
    }
}

/// Where a word sits for its distance from the word being sung (0), in units of the large
/// word's size. Below the stack (+1) and above it (−3) words are invisible, so they rise in
/// and drift out rather than popping.
private struct Row {
    var y: CGFloat
    var scale: CGFloat
    var opacity: Double
    /// Degrees of tilt about the horizontal axis: the lens bending the top and bottom rows.
    var tilt: Double
    /// How much of the highlight box shows.
    var box: Double

    /// Through the lens, outer rows are Verci's 0.68 of the middle one and the lens does the
    /// bending; without it, they're smaller and tilted to fake the curve.
    init(slot: Int, lensed: Bool) {
        if lensed {
            switch slot {
            case ...(-3): (y, scale, opacity, tilt, box) = (-1.45, 0.4, 0, 0, 0)
            case -2: (y, scale, opacity, tilt, box) = (-0.86, 0.68, 0.92, 0, 0)
            case -1: (y, scale, opacity, tilt, box) = (0, 1, 1, 0, 0)
            case 0: (y, scale, opacity, tilt, box) = (0.86, 0.68, 1, 0, 1)
            default: (y, scale, opacity, tilt, box) = (1.45, 0.4, 0, 0, 1)
            }
            return
        }
        switch slot {
        case ...(-3): (y, scale, opacity, tilt, box) = (-1.3, 0.3, 0, 22, 0)
        case -2: (y, scale, opacity, tilt, box) = (-0.82, 0.5, 0.92, 14, 0)
        case -1: (y, scale, opacity, tilt, box) = (0, 1, 1, 0, 0)
        case 0: (y, scale, opacity, tilt, box) = (0.8, 0.5, 1, -12, 1)
        default: (y, scale, opacity, tilt, box) = (1.3, 0.3, 0, -20, 1)
        }
    }
}

private struct StackWord: View {
    let word: LyricWord
    let row: Row
    /// The word's place in the song: gives it its own small, steady tilt and sideways nudge,
    /// so the stack looks hand-placed rather than ruled (±2.5°, as Verci, and a fifth of a word).
    let seed: Int
    let progress: Double
    let size: CGFloat
    let font: ScreenLyricsFont
    let ink: ScreenInk
    let icons: Bool
    let maxWidth: CGFloat

    var body: some View {
        HStack(spacing: size * 0.14) {
            Text(word.text)
                .font(typeface)
                .tracking(-size * 0.02)
                .lineLimit(1)
                .minimumScaleFactor(0.3)
                .foregroundStyle(row.box > 0 ? ink.highlightText : ink.text)
                .padding(.horizontal, size * 0.07)
                .background { box }
            if icons, let symbol = word.symbol {
                SymbolPop(symbol: symbol, size: size, color: ink.highlight)
            }
        }
        .frame(maxWidth: maxWidth)
        .rotationEffect(.degrees(jitter(1) * 2.5))
        .offset(x: jitter(2) * size * 0.22)
        .fixedSize(horizontal: false, vertical: true)
        .shadow(color: .black.opacity(0.45), radius: size * 0.1)
        .scaleEffect(row.scale)
        .rotation3DEffect(.degrees(row.tilt), axis: (x: 1, y: 0, z: 0), perspective: 0.55)
        .offset(y: row.y * size)
        .opacity(row.opacity)
    }

    /// A steady value in −1…1 for this word.
    private func jitter(_ salt: UInt64) -> Double {
        var x = UInt64(truncatingIfNeeded: seed) &* 0x9E3779B97F4A7C15 &+ salt &* 0xBF58476D1CE4E5B9
        x ^= x >> 31
        x = x &* 0x94D049BB133111EB
        x ^= x >> 29
        return Double(x % 2001) / 1000 - 1
    }

    private var typeface: Font { ScreenLyricsTypeface.font(font, size: size) }

    /// A slightly crooked sticker of highlight color that fills from the left as the word is sung.
    private var box: some View {
        Rectangle()
            .fill(ink.highlight)
            .mask(alignment: .leading) {
                GeometryReader { geo in
                    Rectangle().frame(width: geo.size.width * progress)
                }
            }
            .padding(.vertical, size * 0.06)
            .rotationEffect(.degrees(-1.2))
            .opacity(row.box)
    }
}

/// A word's icon: pops in with a bouncy turn the first time it's drawn, as Verci's do.
private struct SymbolPop: View {
    let symbol: String
    let size: CGFloat
    let color: Color
    @State private var shown = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.62, weight: .bold))
            .foregroundStyle(color)
            .scaleEffect(shown ? 1 : 0.3)
            .rotationEffect(.degrees(shown ? 0 : -14))
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(IslandMotion.respecting(.spring(response: 0.3, dampingFraction: 0.45))) { shown = true }
            }
    }
}

/// The lens over the on-screen lyrics (`Resources/Shaders/LyricLens.metal`): full size in the
/// middle, curving and shrinking toward the top and bottom like a glass dome, with Verci's
/// strength (0.45) and falloff (2.2). If the app was built without the shader, the words
/// are drawn flat and `Row` fakes the curve.
enum LyricLens {
    static let library: ShaderLibrary? = Bundle.main.url(forResource: "LyricLens", withExtension: "metallib")
        .map { ShaderLibrary(url: $0) }

    static var isAvailable: Bool { library != nil }
}

extension View {
    @ViewBuilder
    func lyricLens(size: CGSize) -> some View {
        if let library = LyricLens.library {
            distortionEffect(library.lyricLens(.float2(size), .float(0.45), .float(2.2)),
                             maxSampleOffset: CGSize(width: size.width * 0.45, height: size.height * 0.45))
        } else {
            self
        }
    }
}

/// The Fisheye lyrics as the full-screen player's main stage: the same lensed word stack as
/// on the lock screen, as big as the space allows. Lyrics that aren't synced fall back to the
/// player's usual panel (plain text, "Instrumental", or not found).
struct StageLyrics: View {
    let store: PlayerStore
    let size: CGSize

    var body: some View {
        if case .synced = store.lyrics, !store.wordStream.words.isEmpty {
            let wordSize = min(size.height / 3.2, size.width * 0.15).rounded()
            let band = CGSize(width: size.width, height: min(wordSize * 4.6, size.height))
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !store.isPlaying)) { context in
                let time = store.lyricsPosition(at: context.date) + 0.08
                let live = LiveTuning.shared
                let ink = ScreenInk.current(palette: store.palette)
                Group {
                    if live.screenLyricsStyle == .wall, case .synced(let lines) = store.lyrics {
                        WallLyrics(lines: lines, time: time, size: (wordSize * 0.34).rounded(), font: live.screenLyricsFont,
                                   ink: ink, icons: live.lyricWordIcons, maxWidth: size.width * 0.8)
                    } else {
                        let stream = store.wordStream
                        let current = stream.isResting(at: time) ? nil : stream.index(at: time)
                        WordStack(words: stream.words, current: current,
                                  progress: current.map { WordStack.progress(of: stream.words[$0], at: time) } ?? 0,
                                  size: wordSize, font: live.screenLyricsFont, ink: ink, icons: live.lyricWordIcons,
                                  maxWidth: size.width * 0.8, lensed: LyricLens.isAvailable)
                            .frame(width: band.width, height: band.height)
                            .lyricLens(size: band)
                    }
                }
                .frame(width: size.width, height: size.height)
            }
            .allowsHitTesting(false)
        } else {
            LyricsPanel(store: store)
        }
    }
}

/// The on-screen lyrics' typefaces at a size: Verci's weights, semibold for the system faces
/// and bold for the rest.
enum ScreenLyricsTypeface {
    static func font(_ font: ScreenLyricsFont, size: CGFloat) -> Font {
        switch font {
        case .sfPro: .system(size: size, weight: .semibold)
        case .sfRounded: .system(size: size, weight: .semibold, design: .rounded)
        case .newYork: .system(size: size, weight: .semibold, design: .serif)
        case .helveticaNeue: .custom("HelveticaNeue-Bold", size: size)
        case .avenirNext: .custom("AvenirNext-Bold", size: size)
        case .futura: .custom("Futura-Bold", size: size)
        case .didot: .custom("Didot-Bold", size: size)
        }
    }
}
