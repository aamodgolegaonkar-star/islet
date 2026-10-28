import Foundation
import Testing
@testable import IsletCore

@Suite("Word timing")
struct WordTimingTests {
    @Test func estimateSpreadsWordsAcrossTheLine() {
        let words = WordTiming.estimate("Look at the stars", start: 10, end: 13)
        #expect(words.map(\.text) == ["Look", "at", "the", "stars"])
        #expect(words.first?.start == 10)
        // Each word follows the last without gaps, and longer words take longer.
        for (a, b) in zip(words, words.dropFirst()) { #expect(abs(a.end - b.start) < 1e-9) }
        #expect(words[3].end - words[3].start > words[1].end - words[1].start)
        #expect((words.last?.end ?? 99) <= 13)
    }

    @Test func estimateKeepsANaturalPaceOnLongLines() {
        // A short phrase held before a 12 s gap shouldn't crawl across all of it.
        let words = WordTiming.estimate("Hey you", start: 0, end: 12)
        #expect((words.last?.end ?? 0) < 2)
    }

    @Test func estimateFitsShortLines() {
        let words = WordTiming.estimate("One two three four", start: 5, end: 5.6)
        #expect((words.last?.end ?? 99) <= 5.6)
    }

    @Test func piecesTouchingWithoutSpaceFormOneWord() {
        let words = WordTiming.words(from: [
            TimedPiece(start: 1, end: 1.2, text: "beau"),
            TimedPiece(start: 1.2, end: 1.4, text: "ti"),
            TimedPiece(start: 1.4, end: 1.9, text: "ful"),
            TimedPiece(start: 2, end: 2.5, text: " day"),
        ], lineEnd: 3)
        #expect(words.map(\.text) == ["beautiful", "day"])
        #expect(words[0].start == 1 && words[0].end == 1.9)
        #expect(words[1].start == 2 && words[1].end == 2.5)
    }

    @Test func focusCountsWordsSung() {
        let words = [LyricWord(text: "a", start: 1, end: 2), LyricWord(text: "b", start: 3, end: 4)]
        #expect(WordTiming.focus(in: words, at: 0.5) == -1)
        #expect(WordTiming.focus(in: words, at: 1.5) == 0.5)
        // Between words, focus waits at the start of the next one.
        #expect(WordTiming.focus(in: words, at: 2.5) == 1)
        #expect(WordTiming.focus(in: words, at: 3.25) == 1.25)
        #expect(WordTiming.focus(in: words, at: 9) == 2)
        #expect(WordTiming.progress(of: 0, focus: 1.25) == 1)
        #expect(WordTiming.progress(of: 1, focus: 1.25) == 0.25)
        #expect(WordTiming.progress(of: 2, focus: 1.25) == 0)
    }
}

@Suite("LRC word timing")
struct LRCWordTests {
    @Test func enhancedLRCKeepsTheSourcesWordTimes() throws {
        let lines = LRCParser.parse("[00:02.00]<00:02.00>Look <00:02.40>at <00:02.70>the<00:03.10>\n[00:05.00]Next")
        let line = try #require(lines.first)
        #expect(line.text == "Look at the")
        #expect(line.hasExactWordTiming)
        #expect(line.words.map(\.text) == ["Look", "at", "the"])
        #expect(line.words.map(\.start) == [2, 2.4, 2.7])
        #expect(line.words.last?.end == 3.1)
    }

    @Test func plainLRCGetsEstimatedWords() throws {
        let lines = LRCParser.parse("[00:01.00]Look at the stars\n[00:04.00]Next")
        let line = try #require(lines.first)
        #expect(!line.hasExactWordTiming)
        #expect(line.words.map(\.text) == ["Look", "at", "the", "stars"])
    }

    @Test func repeatedChorusShiftsWordTimes() {
        let lines = LRCParser.parse("[00:01.00][00:11.00]<00:01.00>La <00:01.50>la")
        let chorus = lines.filter { !$0.isInterlude }
        #expect(chorus.map { $0.words.map(\.start) } == [[1, 1.5], [11, 11.5]])
    }

    @Test func interludesHaveNoWords() {
        let lines = LRCParser.parse("[00:10.00]Late start")
        #expect(lines.first?.isInterlude == true)
        #expect(lines.first?.words.isEmpty == true)
    }
}

@Suite("Apple Music TTML")
struct TTMLTests {
    static let wordTimed = """
    <tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" \
    xmlns:ttm="http://www.w3.org/ns/ttml#metadata" itunes:timing="Word" xml:lang="en">
    <head><metadata><ttm:agent type="person" xml:id="v1"/></metadata></head>
    <body dur="3:00.000">
    <div begin="1.000" end="9.000">
    <p begin="1.000" end="3.500" itunes:key="L1" ttm:agent="v1"><span begin="1.000" end="1.400">What</span> <span begin="1.400" end="1.700">a</span> <span begin="1.800" end="2.100">beau</span><span begin="2.100" end="2.300">ti</span><span begin="2.300" end="2.800">ful</span> <span begin="2.900" end="3.400">day</span><span ttm:role="x-bg" begin="3.000" end="3.400"><span begin="3.000" end="3.400">(oh)</span></span></p>
    <p begin="9.000" end="11.000" itunes:key="L2" ttm:agent="v1"><span begin="9.000" end="10.000">Again</span></p>
    </div>
    </body>
    </tt>
    """

    @Test func wordTimedLyrics() throws {
        let lines = TTMLParser.parse(Self.wordTimed)
        let sung = lines.filter { !$0.isInterlude }
        #expect(sung.map(\.text) == ["What a beautiful day", "Again"])
        let first = try #require(sung.first)
        #expect(first.hasExactWordTiming)
        #expect(first.words.map(\.text) == ["What", "a", "beautiful", "day"])
        #expect(first.words[2].start == 1.8 && first.words[2].end == 2.8)
        #expect(first.end == 3.5)
        // The 5.5 s gap after the first line becomes an interlude.
        #expect(lines.map(\.isInterlude) == [false, true, false])
    }

    @Test func lineTimedLyricsGetEstimatedWords() throws {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml"><body><div>
        <p begin="00:01.000" end="00:04.000">Look at the stars</p>
        </div></body></tt>
        """
        let line = try #require(TTMLParser.parse(ttml).first)
        #expect(line.text == "Look at the stars")
        #expect(!line.hasExactWordTiming)
        #expect(line.words.count == 4)
    }

    @Test func unsyncedLyricsGiveNothing() {
        let ttml = #"<tt xmlns="http://www.w3.org/ns/ttml"><body><div><p>Just words</p></div></body></tt>"#
        #expect(TTMLParser.parse(ttml).isEmpty)
    }

    @Test func timeFormats() {
        #expect(TTMLParser.seconds("13.4") == 13.4)
        #expect(TTMLParser.seconds("1:02.5") == 62.5)
        #expect(TTMLParser.seconds("01:02:03.25") == 3723.25)
        #expect(TTMLParser.seconds("4.5s") == 4.5)
        #expect(TTMLParser.seconds("") == nil)
    }

    @Test func catalogMatchingChecksTitleArtistAndLength() throws {
        let json = """
        [{"id":"1","attributes":{"name":"Yellow (Live)","artistName":"Coldplay","durationInMillis":400000}},
         {"id":"2","attributes":{"name":"Yellow","artistName":"Coldplay","durationInMillis":266000}},
         {"id":"3","attributes":{"name":"Yellow","artistName":"Someone Else","durationInMillis":266000}}]
        """
        let songs = try JSONDecoder().decode([AppleMusicLyricsClient.Song].self, from: Data(json.utf8))
        #expect(AppleMusicLyricsClient.bestMatch(songs, title: "Yellow", artist: "Coldplay", duration: 267) == "2")
        #expect(AppleMusicLyricsClient.bestMatch(songs, title: "Clocks", artist: "Coldplay", duration: 267) == nil)
    }
}

@Suite("Word symbols")
struct WordSymbolsTests {
    let symbols = WordSymbols(
        names: ["heart", "heart.fill", "flame", "car", "bold", "list.dash", "tree", "moon.stars"],
        keywords: ["tree": ["forest"], "list.dash": ["list"]],
        categories: ["heart": ["health"], "flame": ["nature"], "car": ["transportation"],
                     "bold": ["textformatting"], "list.dash": ["textformatting"], "tree": ["nature"]])

    @Test func commonWordsPreferFilledSymbols() {
        #expect(symbols.symbol(for: "Love", isNoun: false) == "heart.fill")
        #expect(symbols.symbol(for: "burning", lemma: "burn", isNoun: false) == "flame")
        #expect(symbols.symbol(for: "night", isNoun: true) == "moon.stars")
    }

    @Test func otherWordsMustBeEverydayNouns() {
        #expect(symbols.symbol(for: "forest", isNoun: true) == "tree")
        #expect(symbols.symbol(for: "forest", isNoun: false) == nil)
        #expect(symbols.symbol(for: "bold", isNoun: true) == nil)
        #expect(symbols.symbol(for: "list", isNoun: true) == nil)
    }

    @Test func shortWordsAndPunctuation() {
        #expect(WordSymbols.clean("Fire!") == "fire")
        #expect(WordSymbols.clean("heart's") == "heart")
        #expect(symbols.symbol(for: "a", isNoun: true) == nil)
    }

    @Test func systemDataAnnotatesLyrics() throws {
        let system = try #require(WordSymbols.system)
        let lines = LRCParser.parse("[00:01.00]I see fire in the night sky\n[00:05.00]End")
        let words = try #require(system.annotate(lines).first?.words)
        let found = Dictionary(uniqueKeysWithValues: words.compactMap { w in w.symbol.map { (w.text, $0) } })
        #expect(found["fire"]?.hasPrefix("flame") == true)
        #expect(found["night"]?.hasPrefix("moon") == true)
        #expect(found["I"] == nil && found["the"] == nil)
    }

    @Test func playerButtonsAreNotPictures() throws {
        let system = try #require(WordSymbols.system)
        let lines = LRCParser.parse("[00:01.00]He keeps on playin' games with the play\n[00:05.00]End")
        let words = try #require(system.annotate(lines).first?.words)
        #expect(words.first { $0.text == "play" }?.symbol == nil)
        #expect(words.first { $0.text == "playin'" }?.symbol == nil)
        #expect(words.first { $0.text == "games" }?.symbol?.hasPrefix("gamecontroller") == true)
    }
}

@Suite("Word stream")
struct WordStreamTests {
    let stream = WordStream(lines: LRCParser.parse("[00:01.00]<00:01.00>Now <00:01.50>when<00:02.00>\n[00:02.20]<00:02.20>you <00:02.60>see<00:03.00>\n[00:09.00]<00:09.00>Again<00:10.00>"))

    @Test func wordsRunAcrossLines() {
        #expect(stream.words.map(\.text) == ["Now", "when", "you", "see", "Again"])
        #expect(stream.index(at: 0.5) == nil)
        #expect(stream.index(at: 1.7) == 1)
        // Between lines the last word holds until the next begins.
        #expect(stream.index(at: 2.1) == 1)
        #expect(stream.index(at: 2.3) == 2)
    }

    @Test func clearsDuringLongGaps() {
        #expect(!stream.isResting(at: 2.1))
        #expect(stream.isResting(at: 6))
        #expect(!stream.isResting(at: 8.7))
        #expect(stream.isResting(at: 0.5))
    }

    @Test func hexColors() {
        #expect(RGB(hex: "#FF4258FF") == RGB(1, 0x42 / 255.0, 0x58 / 255.0))
        #expect(RGB(hex: "zz") == nil)
        #expect(RGB(1, 0.5, 0).hex == "#FF8000")
    }
}

@Suite("Edge glow colors")
struct GlowColorTests {
    @Test func glowIsBrightAndStartsWithTheAccent() throws {
        let palette = Palette(colors: [RGB(0.3, 0.05, 0.05), RGB(0.31, 0.05, 0.05), RGB(0.05, 0.1, 0.3)],
                              accent: RGB(0.9, 0.3, 0.5))
        let glow = palette.glowColors
        let first = try #require(glow.first)
        #expect(first.hsb.b == 1)
        #expect(abs(first.hsb.h - RGB(0.9, 0.3, 0.5).hsb.h) < 0.01)
        // The two near-identical reds become one.
        #expect(glow.count == 3)
        #expect(glow.allSatisfy { $0.hsb.b > 0.99 })
    }

    @Test func graysAreLeftOutOfColorfulCovers() {
        let glow = Palette(colors: [RGB(0.2, 0.2, 0.2), RGB(0.1, 0.1, 0.12)], accent: RGB(0.95, 0.3, 0.5)).glowColors
        #expect(glow.count == 1)
        #expect(glow.allSatisfy { $0.hsb.s >= 0.5 })
    }

    @Test func graysStayGray() {
        let glow = Palette(colors: [RGB(0.2, 0.2, 0.2)], accent: RGB(0.2, 0.2, 0.21)).glowColors
        #expect(glow.allSatisfy { $0.hsb.s < 0.12 })
    }
}
