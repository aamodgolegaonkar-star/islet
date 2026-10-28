import Foundation

/// Every sung word of a song in order, across line breaks: what the on-screen lyrics walk
/// through one word at a time.
public struct WordStream: Sendable, Equatable {
    public let words: [LyricWord]

    public init(lines: [LyricLine]) {
        // Stable, so duet words that start together keep their order.
        words = lines.filter { !$0.isInterlude }.flatMap(\.words).enumerated()
            .sorted { $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start }
            .map(\.element)
    }

    /// The word being sung, or the last one sung, at `time`; nil before the first.
    public func index(at time: TimeInterval) -> Int? {
        var low = 0, high = words.count - 1, found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if words[mid].start <= time {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    /// Between phrases: the last word ended a while ago and the next isn't about to start,
    /// so the screen can clear instead of holding an old word through an instrumental.
    public func isResting(at time: TimeInterval, after ended: TimeInterval = 1.6, before next: TimeInterval = 0.5) -> Bool {
        guard let index = index(at: time) else { return true }
        let sinceEnd = time - words[index].end
        let untilNext = index + 1 < words.count ? words[index + 1].start - time : .infinity
        return sinceEnd > ended && untilNext > next
    }
}
