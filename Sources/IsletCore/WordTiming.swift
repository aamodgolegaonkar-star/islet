import Foundation

/// One sung word and when it's sung. `symbol` names an SF Symbol that pictures the word
/// ("fire" → `flame.fill`), set by `WordSymbols` for the words that have one.
public struct LyricWord: Sendable, Equatable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var symbol: String?

    public init(text: String, start: TimeInterval, end: TimeInterval, symbol: String? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.symbol = symbol
    }
}

/// A timed piece of a line as a source delivers it: a word, a syllable ("beau", "ti", "ful")
/// or, with no text, the moment singing stops. Whitespace in `text` separates words; pieces
/// that touch without whitespace are parts of one word.
public struct TimedPiece: Sendable, Equatable {
    public var start: TimeInterval
    /// Nil: the piece lasts until the next one starts.
    public var end: TimeInterval?
    public var text: String

    public init(start: TimeInterval, end: TimeInterval? = nil, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Word-level timing: from a source's timed pieces, or estimated for lyrics timed by line.
public enum WordTiming {
    /// Joins timed pieces into words. Empty when there are no pieces.
    public static func words(from pieces: [TimedPiece], lineEnd: TimeInterval) -> [LyricWord] {
        var words: [LyricWord] = []
        // The previous piece stopped mid-word, so the next one continues it.
        var continues = false
        for (index, piece) in pieces.enumerated() {
            let next = index + 1 < pieces.count ? pieces[index + 1].start : lineEnd
            let end = max(piece.start, piece.end ?? next)
            let tokens = piece.text.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !tokens.isEmpty else {
                continues = false
                continue
            }
            let joinsPrevious = continues && !(piece.text.first?.isWhitespace ?? true)
            for (index, (token, slice)) in zip(tokens, slices(of: tokens, from: piece.start, to: end)).enumerated() {
                if index == 0, joinsPrevious, let last = words.indices.last {
                    words[last].text += token
                    words[last].end = slice.end
                } else {
                    words.append(LyricWord(text: token, start: slice.start, end: slice.end))
                }
            }
            continues = !(piece.text.last?.isWhitespace ?? true)
        }
        return words
    }

    /// Spreads a line's time across its words, longer words taking longer. Singing rarely
    /// fills the whole gap to the next line, so the words move at a natural pace and finish
    /// a little before the line ends.
    public static func estimate(_ text: String, start: TimeInterval, end: TimeInterval) -> [LyricWord] {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }
        let length = max(end - start, 0)
        let pace = weights(of: tokens).reduce(0, +) * secondsPerWeight
        let span = min(length * 0.9, max(minimumSpan, pace))
        return zip(tokens, slices(of: tokens, from: start, to: start + span))
            .map { LyricWord(text: $0, start: $1.start, end: $1.end) }
    }

    /// Where singing is within a line, counted in words: 2.5 is halfway through the third
    /// word. −1 before the first word starts; `words.count` once the last has ended.
    public static func focus(in words: [LyricWord], at time: TimeInterval) -> Double {
        guard let first = words.first, time >= first.start else { return -1 }
        for (index, word) in words.enumerated() where time < word.end {
            guard time > word.start else { return Double(index) }
            return Double(index) + (time - word.start) / max(word.end - word.start, 0.001)
        }
        return Double(words.count)
    }

    /// How far through word `index` singing is (0 to 1), given `focus(in:at:)`.
    public static func progress(of index: Int, focus: Double) -> Double {
        min(max(focus - Double(index), 0), 1)
    }

    // MARK: - Weights

    /// About one sung syllable per three letters, at a pop tempo.
    static let secondsPerWeight = 0.12
    /// Even a short line takes a moment to sing.
    static let minimumSpan: TimeInterval = 1.2

    /// Letters plus one, so short words ("a", "I") still take a beat.
    private static func weights(of tokens: [String]) -> [Double] {
        tokens.map { token in Double(token.unicodeScalars.filter(CharacterSet.alphanumerics.contains).count) + 1 }
    }

    private static func slices(of tokens: [String], from start: TimeInterval, to end: TimeInterval) -> [(start: TimeInterval, end: TimeInterval)] {
        let weights = weights(of: tokens)
        let total = weights.reduce(0, +)
        let length = max(end - start, 0)
        var cursor = start
        return weights.map { weight in
            let next = cursor + length * weight / total
            defer { cursor = next }
            return (cursor, next)
        }
    }
}
