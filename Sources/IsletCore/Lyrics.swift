import Foundation

/// One displayable lyric row. Interludes are synthetic rows for instrumental gaps.
public struct LyricLine: Sendable, Equatable, Identifiable {
    public var id: Int
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var isInterlude: Bool
    /// The line's words with their own timing; empty for interludes.
    public var words: [LyricWord]
    /// The words were timed by the lyrics source (Apple Music, Enhanced LRC), rather than
    /// estimated by spreading the line's time across them.
    public var hasExactWordTiming: Bool

    public init(id: Int, start: TimeInterval, end: TimeInterval, text: String, isInterlude: Bool = false,
                words: [LyricWord] = [], hasExactWordTiming: Bool = false) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.isInterlude = isInterlude
        self.words = words
        self.hasExactWordTiming = hasExactWordTiming
    }
}

/// One line before rows are numbered and interludes are added: a time, the sung text and,
/// when the source times words, its pieces. A nil `end` runs to the next line.
struct TimedEntry {
    var time: TimeInterval
    var end: TimeInterval?
    var text: String
    var pieces: [TimedPiece] = []
}

/// Parser for LRC (and the line part of Enhanced LRC) as served by LRCLIB.
public enum LRCParser {
    /// Gaps at least this long become an interlude row with animated dots.
    public static let interludeThreshold: TimeInterval = 4.5

    // Regex isn't Sendable, so these are built per use rather than shared statics.
    private static var timeTag: Regex<(Substring, Substring, Substring, Substring?)> {
        /\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]/
    }
    private static var wordTag: Regex<(Substring, Substring, Substring, Substring?)> {
        /<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>/
    }
    private static var offsetTag: Regex<(Substring, Substring)> { /(?i)\[offset:\s*([+-]?\d+)\s*\]/ }

    public static func parse(_ lrc: String, duration: TimeInterval? = nil) -> [LyricLine] {
        var offset: TimeInterval = 0
        if let match = lrc.firstMatch(of: offsetTag), let ms = Double(match.1) {
            // A positive offset makes lyrics appear sooner.
            offset = ms / 1000
        }

        var entries: [TimedEntry] = []
        for rawLine in lrc.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var rest = Substring(rawLine)
            var times: [TimeInterval] = []
            while let match = rest.prefixMatch(of: timeTag) {
                times.append(seconds(match.1, match.2, match.3) - offset)
                rest = rest[match.range.upperBound...]
            }
            guard let first = times.first else { continue }
            let text = rest.replacing(wordTag, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let pieces = text.isEmpty ? [] : wordPieces(rest, offset: offset)
            for time in times {
                // Word tags hold the first occurrence's times; a repeated chorus shifts them.
                let shift = time - first
                let moved = pieces.map { TimedPiece(start: max(0, $0.start + shift), text: $0.text) }
                entries.append(TimedEntry(time: max(0, time), text: text, pieces: moved))
            }
        }
        // Stable sort keeps duet lines with equal timestamps in file order.
        let ordered = entries.enumerated()
            .sorted { $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time }
            .map(\.element)
        return buildLines(ordered, duration: duration)
    }

    /// Enhanced LRC word tags: `<00:12.00>Look <00:12.40>at <00:12.70>the<00:13.10>`. Each tag
    /// times the text after it; a trailing tag marks when the last word ends.
    private static func wordPieces(_ body: Substring, offset: TimeInterval) -> [TimedPiece] {
        let matches = body.matches(of: wordTag)
        guard !matches.isEmpty else { return [] }
        var pieces: [TimedPiece] = []
        for (index, match) in matches.enumerated() {
            let upper = index + 1 < matches.count ? matches[index + 1].range.lowerBound : body.endIndex
            var text = String(body[match.range.upperBound..<upper])
            // Text before the first tag belongs to the first word.
            if index == 0 { text = String(body[..<match.range.lowerBound]) + text }
            pieces.append(TimedPiece(start: seconds(match.1, match.2, match.3) - offset, text: text))
        }
        return pieces
    }

    /// Index of the row that should be highlighted at `time`, or nil before the first row.
    public static func activeIndex(in lines: [LyricLine], at time: TimeInterval, lead: TimeInterval = 0.15) -> Int? {
        let target = time + lead
        var low = 0, high = lines.count - 1, found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].start <= target {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    private static func seconds(_ minutes: Substring, _ secs: Substring, _ fraction: Substring?) -> TimeInterval {
        var value = (Double(minutes) ?? 0) * 60 + (Double(secs) ?? 0)
        if let fraction, !fraction.isEmpty {
            // "4" -> 0.4, "43" -> 0.43, "430" -> 0.430
            value += (Double(fraction) ?? 0) / pow(10, Double(fraction.count))
        }
        return value
    }

    /// Numbers the sung lines, gives each its words (timed by the source, or estimated) and
    /// adds interlude rows for long gaps. Shared with `TTMLParser`.
    static func buildLines(_ entries: [TimedEntry], duration: TimeInterval?) -> [LyricLine] {
        var sung: [(start: TimeInterval, end: TimeInterval, text: String, pieces: [TimedPiece])] = []
        for (index, entry) in entries.enumerated() where !entry.text.isEmpty {
            let next = entries[(index + 1)...].first { $0.time > entry.time }?.time
            let end = entry.end ?? next ?? max(duration ?? 0, entry.time + 5)
            sung.append((entry.time, end, entry.text, entry.pieces))
        }

        var lines: [LyricLine] = []
        func add(_ start: TimeInterval, _ end: TimeInterval, _ text: String, pieces: [TimedPiece] = [], interlude: Bool) {
            var line = LyricLine(id: lines.count, start: start, end: end, text: text, isInterlude: interlude)
            if !interlude {
                let timed = WordTiming.words(from: pieces, lineEnd: end)
                line.words = timed.isEmpty ? WordTiming.estimate(text, start: start, end: end) : timed
                line.hasExactWordTiming = !timed.isEmpty
            }
            lines.append(line)
        }
        if let first = sung.first, first.start >= interludeThreshold {
            add(0, first.start, "", interlude: true)
        }
        for (index, line) in sung.enumerated() {
            add(line.start, line.end, line.text, pieces: line.pieces, interlude: false)
            if index + 1 < sung.count {
                let nextStart = sung[index + 1].start
                if nextStart - line.end >= interludeThreshold {
                    add(line.end, nextStart, "", interlude: true)
                }
            }
        }
        return lines
    }
}
