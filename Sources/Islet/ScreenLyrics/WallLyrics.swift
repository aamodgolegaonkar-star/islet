import IsletCore
import SwiftUI

/// The on-screen lyrics' Wall style, after Verci's "Ship": the last five lines stacked on
/// the left, the line being sung in the highlight color with each word popping in as it's
/// sung, older lines fading back. The whole wall drifts slowly in 3D (turning about 16° side
/// to side and 7° up and down, breathing a little) as if hung in space.
///
/// The sung line sits at the bottom of the space it's given; when long lines don't all fit,
/// the oldest fade out at the top rather than spilling past it.
struct WallLyrics: View {
    let lines: [LyricLine]
    let time: TimeInterval
    /// Font size of the line being sung.
    let size: CGFloat
    let font: ScreenLyricsFont
    let ink: ScreenInk
    let icons: Bool
    let maxWidth: CGFloat

    /// How many lines the wall holds, the sung one included.
    static let depth = 5

    var body: some View {
        let current = LRCParser.activeIndex(in: lines, at: time)
        let shown = Self.shownLines(lines, current: current)
        let t = time
        VStack(alignment: .leading, spacing: size * 0.12) {
            ForEach(shown, id: \.id) { line in
                let age = (current ?? line.id) - line.id
                WallLine(line: line, isCurrent: line.id == current, age: age, time: time,
                         size: age == 0 ? size : size * 0.8, font: font, ink: ink, icons: icons)
                    .transition(.scale(scale: 0.2, anchor: .leading).combined(with: .opacity))
            }
        }
        .frame(maxWidth: maxWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.22)],
                           startPoint: .top, endPoint: .bottom)
        }
        .clipped()
        .animation(IslandMotion.respecting(.spring(response: 0.25, dampingFraction: 0.7)), value: current)
        .rotation3DEffect(.degrees(sin(0.35 * t) * 16), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
        .rotation3DEffect(.degrees(sin(0.22 * t) * 7), axis: (x: 1, y: 0, z: 0), perspective: 0.45)
        .scaleEffect(1 + sin(0.17 * t) * 0.035)
    }

    /// The sung line and up to four before it, skipping instrumental breaks.
    static func shownLines(_ lines: [LyricLine], current: Int?) -> [LyricLine] {
        guard let current else { return [] }
        return Array(lines[...current].filter { !$0.isInterlude }.suffix(depth))
    }
}

private struct WallLine: View {
    let line: LyricLine
    let isCurrent: Bool
    /// Lines since this one was sung (0 for the line being sung).
    let age: Int
    let time: TimeInterval
    let size: CGFloat
    let font: ScreenLyricsFont
    let ink: ScreenInk
    let icons: Bool

    var body: some View {
        WordFlow(spacing: size * 0.24, lineSpacing: size * 0.04) {
            ForEach(Array(line.words.enumerated()), id: \.offset) { index, word in
                // On the line being sung, a word appears when it's reached.
                if !isCurrent || word.start <= time {
                    HStack(spacing: size * 0.18) {
                        Text(word.text)
                            .font(ScreenLyricsTypeface.font(font, size: size))
                            .foregroundStyle(isCurrent ? ink.highlight : ink.text)
                        if icons, let symbol = word.symbol {
                            Image(systemName: symbol)
                                .font(.system(size: size * 0.62, weight: .bold))
                                .foregroundStyle(ink.highlight)
                        }
                    }
                    .rotationEffect(.degrees(tilt(index) * 4.5))
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
                }
            }
        }
        .animation(IslandMotion.respecting(.spring(response: 0.25, dampingFraction: 0.7)), value: line.words.filter { $0.start <= time }.count)
        .opacity(isCurrent ? 1 : max(0.2, 0.7 - Double(age - 1) * 0.15))
        .shadow(color: .black.opacity(0.45), radius: size * 0.1)
    }

    /// A steady value in −1…1 for each word of this line.
    private func tilt(_ index: Int) -> Double {
        var x = UInt64(truncatingIfNeeded: line.id &* 131 &+ index) &* 0x9E3779B97F4A7C15
        x ^= x >> 31
        x = x &* 0xBF58476D1CE4E5B9
        x ^= x >> 29
        return Double(x % 2001) / 1000 - 1
    }
}
