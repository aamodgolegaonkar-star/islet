import IsletCore
import SwiftUI

/// A lyric line drawn word by word (Settings → Music & Lyrics → Style).
///
/// On the line being sung, each word fills with light from left to right while it's sung
/// and lifts a little. In Fisheye the word being sung also swells and its neighbours less
/// so, like a lens passing along the line. With word icons on, a picture rises over words
/// like "fire" or "rain" as they're reached. Other lines are drawn still.
///
/// Only the active line runs a timeline, and only while music plays.
struct WordLyricLine: View {
    let line: LyricLine
    let isActive: Bool
    let fontSize: CGFloat
    let store: PlayerStore

    var body: some View {
        if isActive {
            TimelineView(.animation(minimumInterval: LiveTuning.shared.batterySaving ? 1.0 / 20 : 1.0 / 60,
                                    paused: !store.isPlaying)) { context in
                words(focus: WordTiming.focus(in: line.words, at: store.lyricsPosition(at: context.date) + Self.lead))
            }
        } else {
            words(focus: nil)
        }
    }

    /// Words light up a hair early, as lines do, so the light leads the voice.
    private static let lead: TimeInterval = 0.05

    private func words(focus: Double?) -> some View {
        SungWords(words: line.words, focus: focus, fontSize: fontSize,
                  fisheye: LiveTuning.shared.lyricStyle == .fisheye,
                  icons: LiveTuning.shared.lyricWordIcons)
    }
}

/// The words of one line at one moment: `focus` is `WordTiming.focus` (nil: not being sung).
/// Shared by the player, the open island and the tutorial's demo.
struct SungWords: View {
    let words: [LyricWord]
    let focus: Double?
    let fontSize: CGFloat
    let fisheye: Bool
    let icons: Bool
    /// One row that slides along to keep the word being sung in view (the island), with
    /// icons beside their words rather than above them.
    var singleLine = false

    /// Small island text needs a stronger lens to read as one.
    private var amount: CGFloat { singleLine ? 1.7 : 1 }

    var body: some View {
        // In Fisheye, lines wrap a little early to leave room for the swell.
        WordFlow(spacing: fontSize * 0.26, lineSpacing: fontSize * 0.1, reserve: fisheye ? fontSize * 1.3 : 0,
                 singleLine: singleLine, focus: focus) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                let swell = fisheye ? focus.map { Self.swell(of: index, count: words.count, focus: $0) * amount } ?? 0 : 0
                SungWord(word: word,
                         progress: focus.map { WordTiming.progress(of: index, focus: $0) },
                         scale: 1 + swell,
                         fontSize: fontSize,
                         showsSymbol: icons && focus != nil,
                         inlineSymbol: singleLine)
                    .layoutValue(key: WordScale.self, value: 1 + swell)
            }
        }
        .mask {
            // A sliding row fades out at its sides instead of cutting words in half.
            if singleLine {
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.05),
                                       .init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
            } else {
                Rectangle()
            }
        }
    }

    /// How much word `index` grows: most at the point being sung, falling away over about
    /// a word on either side, and easing out once the line is done.
    static func swell(of index: Int, count: Int, focus: Double) -> CGFloat {
        let distance = Double(index) + 0.5 - focus
        let lens = exp(-(distance * distance) / (2 * 0.75 * 0.75))
        let ending = min(max((Double(count) - focus) * 2, 0), 1)
        return CGFloat(0.24 * lens * ending)
    }
}

/// One word. `progress` is how far through it singing is (nil: a line that isn't being sung).
private struct SungWord: View {
    let word: LyricWord
    let progress: Double?
    let scale: CGFloat
    let fontSize: CGFloat
    let showsSymbol: Bool
    let inlineSymbol: Bool

    var body: some View {
        let lit = progress ?? 1
        Group {
            if inlineSymbol, showsSymbol, let symbol = word.symbol {
                // Always there, dim until the word is reached, so nothing shifts when it lights.
                HStack(spacing: fontSize * 0.22) {
                    Image(systemName: symbol)
                        .font(.system(size: fontSize * 0.95, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white.opacity(lit > 0 ? 1 : 0.38))
                        .scaleEffect(lit > 0 ? 1 : 0.75)
                        .animation(IslandMotion.respecting(.spring(response: 0.38, dampingFraction: 0.62)), value: lit > 0)
                    lettering(lit)
                }
            } else {
                lettering(lit)
            }
        }
            .overlay(alignment: .top) {
                if showsSymbol, !inlineSymbol, let symbol = word.symbol {
                    let shown = lit > 0
                    Image(systemName: symbol)
                        .font(.system(size: fontSize * 0.6, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white)
                        .offset(y: -fontSize * 0.72)
                        .scaleEffect(shown ? 1 : 0.4, anchor: .bottom)
                        .opacity(shown ? 1 : 0)
                        .animation(IslandMotion.respecting(.spring(response: 0.38, dampingFraction: 0.62)), value: shown)
                }
            }
            .offset(y: -fontSize * 0.035 * lit * (progress == nil ? 0 : 1))
            .scaleEffect(scale, anchor: .bottom)
    }

    /// The word, dim, with its sung part lit by a wipe.
    private func lettering(_ lit: Double) -> some View {
        text
            .foregroundStyle(.white.opacity(progress == nil ? 1 : 0.38))
            .overlay {
                if lit > 0 {
                    text.foregroundStyle(.white).mask(wipe(lit))
                }
            }
    }

    private var text: some View {
        Text(word.text).font(.system(size: fontSize, weight: .bold))
    }

    /// A soft-edged reveal from the left.
    private func wipe(_ progress: Double) -> LinearGradient {
        let edge = 0.2
        let front = min(max(progress * (1 + edge), 0), 1 + edge)
        return LinearGradient(stops: [
            .init(color: .black, location: min(max(front - edge, 0), 1)),
            .init(color: .clear, location: min(front, 1)),
        ], startPoint: .leading, endPoint: .trailing)
    }
}

/// How much a word is drawn larger than its size (Fisheye), so `WordFlow` makes room.
private struct WordScale: LayoutValueKey {
    static let defaultValue: CGFloat = 1
}

/// Words left to right, wrapping like text. Lines break by the words' normal sizes, so a
/// swelling word never moves another to the next line or changes the row's height; within
/// a line, swollen words push their neighbours aside.
struct WordFlow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat
    /// Width kept free at the end of each line for words drawn larger than their size.
    var reserve: CGFloat = 0
    /// Never wrap; slide the row left to keep `focus` (the point being sung) in view.
    var singleLine = false
    var focus: Double?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        if singleLine {
            let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
            let width = sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(sizes.count - 1, 0))
            return CGSize(width: proposal.width ?? width, height: sizes.map(\.height).max() ?? 0)
        }
        let rows = rows(in: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { row in
            row.reduce(0) { $0 + subviews[$1].sizeThatFits(.unspecified).width } + spacing * CGFloat(max(row.count - 1, 0))
        }.max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height(of: rows, subviews: subviews))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        if singleLine {
            placeRow(in: bounds, subviews: subviews)
            return
        }
        var y = bounds.minY
        for row in rows(in: bounds.width, subviews: subviews) {
            let rowHeight = row.map { subviews[$0].sizeThatFits(.unspecified).height }.max() ?? 0
            var x = bounds.minX
            for index in row {
                let size = subviews[index].sizeThatFits(.unspecified)
                let scale = subviews[index][WordScale.self]
                // Scaling grows the word evenly both ways; shift it so it starts at x.
                subviews[index].place(at: CGPoint(x: x + size.width * (scale - 1) / 2, y: y + rowHeight - size.height),
                                      proposal: ProposedViewSize(size))
                x += size.width * scale + spacing
            }
            y += rowHeight + lineSpacing
        }
    }

    private func placeRow(in bounds: CGRect, subviews: Subviews) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let scales = subviews.map { $0[WordScale.self] }
        let widths = zip(sizes, scales).map { $0.width * $1 }
        let total = widths.reduce(0, +) + spacing * CGFloat(max(widths.count - 1, 0))
        // Where singing is, in points from the row's start; kept a little left of centre.
        var shift: CGFloat = 0
        if total > bounds.width, let focus, focus >= 0, !widths.isEmpty {
            let index = min(Int(focus), widths.count - 1)
            let before = widths[..<index].reduce(0, +) + spacing * CGFloat(index)
            let point = before + widths[index] * CGFloat(min(focus - Double(index), 1))
            shift = min(max(point - bounds.width * 0.55, 0), total - bounds.width)
        }
        let height = sizes.map(\.height).max() ?? 0
        var x = bounds.minX - shift
        for index in subviews.indices {
            let size = sizes[index]
            subviews[index].place(at: CGPoint(x: x + size.width * (scales[index] - 1) / 2,
                                              y: bounds.minY + height - size.height),
                                  proposal: ProposedViewSize(size))
            x += widths[index] + spacing
        }
    }

    private func rows(in width: CGFloat, subviews: Subviews) -> [[Int]] {
        var rows: [[Int]] = []
        var current: [Int] = []
        var x: CGFloat = 0
        for index in subviews.indices {
            let w = subviews[index].sizeThatFits(.unspecified).width
            if !current.isEmpty, x + spacing + w > width - reserve {
                rows.append(current)
                current = []
                x = 0
            }
            x += (current.isEmpty ? 0 : spacing) + w
            current.append(index)
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    private func height(of rows: [[Int]], subviews: Subviews) -> CGFloat {
        let heights = rows.map { row in row.map { subviews[$0].sizeThatFits(.unspecified).height }.max() ?? 0 }
        return heights.reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
    }
}
