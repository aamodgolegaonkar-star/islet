import Foundation
import Testing
@testable import IsletCore

@Suite("LRC parsing")
struct LRCParserTests {
    @Test func parsesBasicLinesAndEnds() {
        let lines = LRCParser.parse("""
        [ar:Coldplay]
        [00:01.50]Look at the stars
        [00:04.25]Look how they shine for you
        """, duration: 10)
        #expect(lines.map(\.text) == ["Look at the stars", "Look how they shine for you"])
        #expect(lines[0].start == 1.5)
        #expect(lines[0].end == 4.25)
        #expect(lines[1].end == 10)
    }

    @Test func fractionDigitsAreScaled() {
        let lines = LRCParser.parse("[00:01.5]a\n[00:02.43]b\n[00:03.123]c")
        #expect(lines.map(\.start) == [1.5, 2.43, 3.123])
    }

    @Test func multipleTimestampsRepeatTheLine() {
        let lines = LRCParser.parse("[00:01.00][00:03.00]Chorus\n[00:02.00]Verse")
        #expect(lines.map(\.text) == ["Chorus", "Verse", "Chorus"])
    }

    @Test func offsetMovesLyricsEarlier() {
        let lines = LRCParser.parse("[offset:+500]\n[00:02.00]a\n[00:03.00]b")
        #expect(lines.map(\.start) == [1.5, 2.5])
    }

    @Test func wordTagsAreStripped() {
        let lines = LRCParser.parse("[00:12.00]<00:12.00>Look <00:12.40>at <00:12.70>the")
        // A 12 s intro also yields a leading interlude row.
        #expect(lines.map(\.isInterlude) == [true, false])
        #expect(lines.last?.text == "Look at the")
    }

    @Test func gapsBecomeInterludes() {
        // Intro of 8 s, and an empty marker that opens a 10 s instrumental break.
        let lines = LRCParser.parse("""
        [00:08.00]First
        [00:10.00]Second
        [00:12.00]
        [00:22.00]Third
        """, duration: 30)
        #expect(lines.map(\.isInterlude) == [true, false, false, true, false])
        #expect(lines[0].start == 0 && lines[0].end == 8)
        #expect(lines[3].start == 12 && lines[3].end == 22)
        #expect(lines.map(\.id) == [0, 1, 2, 3, 4])
    }

    @Test func activeIndexUsesSmallLead() {
        let lines = LRCParser.parse("[00:01.00]a\n[00:05.00]b\n[00:09.00]c")
        #expect(LRCParser.activeIndex(in: lines, at: 0.5) == nil)
        #expect(LRCParser.activeIndex(in: lines, at: 4.9) == 1)
        #expect(LRCParser.activeIndex(in: lines, at: 100) == 2)
    }
}

@Suite("Catalog text matching")
struct MusicTextTests {
    @Test func normalizeDropsEditionNoise() {
        #expect(MusicText.normalize("Not Like Us - Single") == "not like us")
        #expect(MusicText.normalize("Parachutes (Deluxe Edition)") == "parachutes")
        #expect(MusicText.normalize("Beyoncé") == "beyonce")
        #expect(MusicText.normalize("Song feat. Someone") == "song")
    }

    @Test func artworkURLResizes() {
        let url = MusicText.resizedArtworkURL("https://is1-ssl.mzstatic.com/image/thumb/Music/x/100x100bb.jpg", size: 1400)
        #expect(url?.absoluteString == "https://is1-ssl.mzstatic.com/image/thumb/Music/x/1400x1400bb.jpg")
    }

    @Test func albumSuffixCleanup() {
        #expect(LRCLIBClient.cleanAlbum("Not Like Us - Single") == "Not Like Us")
        #expect(LRCLIBClient.cleanAlbum("Parachutes") == "Parachutes")
    }
}

@Suite("Motion artwork parsing")
struct MotionArtworkTests {
    @Test func readsEditorialVideoVariants() {
        let json = #"{"data":[{"id":"1","attributes":{"name":"A","editorialVideo":{"motionDetailSquare":{"video":"https://example.com/sq.m3u8"},"motionDetailTall":{"video":"https://example.com/tall.m3u8"}}}}]}"#
        let art = MotionArtwork.parse(albumResponse: Data(json.utf8))
        #expect(art?.square?.absoluteString == "https://example.com/sq.m3u8")
        #expect(art?.tall?.absoluteString == "https://example.com/tall.m3u8")
    }

    @Test func absentFieldIsNil() {
        let json = #"{"data":[{"id":"1","attributes":{"name":"A"}}]}"#
        #expect(MotionArtwork.parse(albumResponse: Data(json.utf8)) == nil)
    }
}

@Suite("Palette extraction")
struct PaletteTests {
    @Test func findsBothDominantColors() {
        let red = RGB(0.85, 0.1, 0.1), blue = RGB(0.1, 0.2, 0.8)
        let pixels = Array(repeating: red, count: 300) + Array(repeating: blue, count: 100)
        let palette = PaletteExtractor.palette(from: pixels, clusters: 3)
        let hues = palette.colors.map { $0.hsb.h }
        #expect(hues.contains { $0 < 0.05 || $0 > 0.95 })      // red
        #expect(hues.contains { abs($0 - 0.625) < 0.08 })      // blue
        #expect(palette.accent.hsb.b >= 0.8)
    }

    @Test func hsbRoundTrip() {
        let c = RGB(0.2, 0.6, 0.4)
        let (h, s, b) = c.hsb
        let back = RGB(hue: h, saturation: s, brightness: b)
        #expect(abs(back.r - c.r) < 1e-9 && abs(back.g - c.g) < 1e-9 && abs(back.b - c.b) < 1e-9)
    }

    @Test func tinyInputFallsBack() {
        #expect(PaletteExtractor.palette(from: [RGB(1, 1, 1)]) == .fallback)
    }
}

@Suite("Lyrics title matching")
struct LyricsTitleTests {
    @Test(arguments: [
        ("Here Comes the Sun - Remastered 2009", "Here Comes the Sun"),
        ("Stay (feat. Justin Bieber)", "Stay"),
        ("Blinding Lights", "Blinding Lights"),
        ("Bohemian Rhapsody - Live Aid", "Bohemian Rhapsody"),
        ("Creep [Explicit]", "Creep"),
        ("Levitating (Sped Up)", "Levitating"),
        ("Sunflower - Spider-Man: Into the Spider-Verse", "Sunflower - Spider-Man: Into the Spider-Verse"),
        ("Song ft. Someone", "Song"),
    ])
    func cleansTitles(raw: String, clean: String) {
        #expect(MusicText.lyricsTitle(raw) == clean)
    }

    @Test func firstArtist() {
        #expect(MusicText.primaryArtist("Central Cee feat. Dave") == "Central Cee")
        #expect(MusicText.primaryArtist("Post Malone, Swae Lee") == "Post Malone")
        #expect(MusicText.primaryArtist("Calvin Harris x Dua Lipa") == "Calvin Harris")
        #expect(MusicText.primaryArtist("Adele") == "Adele")
    }
}

@Suite("Lock click synthesis")
struct ClickSynthesisTests {
    @Test(arguments: [ClickSynthesis.Style.lock, .unlock])
    func isCleanAndNormalised(style: ClickSynthesis.Style) {
        let samples = ClickSynthesis.samples(style)
        #expect(samples.count == Int(ClickSynthesis.sampleRate * (style == .lock ? 0.13 : 0.17)))
        #expect(samples.allSatisfy { $0.isFinite })
        let peak = samples.map(abs).max() ?? 0
        #expect(abs(peak - ClickSynthesis.peak) < 0.001)
        // The tail must have decayed to near silence so the click doesn't "pop" at the end.
        let tail = samples.suffix(240).map(abs).max() ?? 1
        #expect(tail < 0.02)
    }

    @Test func unlockHasTwoClicks() {
        let samples = ClickSynthesis.samples(.unlock)
        let second = Int(0.062 * ClickSynthesis.sampleRate)
        let before = samples[(second - 200)..<second].map(abs).max() ?? 0
        let after = samples[second..<(second + 200)].map(abs).max() ?? 0
        #expect(after > before * 3)
    }

    @Test func wavDescribesTheSamples() {
        let samples = ClickSynthesis.samples(.unlock)
        let wav = ClickSynthesis.wav(.unlock)
        func text(_ at: Int) -> String { String(decoding: wav[at..<(at + 4)], as: UTF8.self) }
        func u16(_ at: Int) -> UInt16 { UInt16(wav[at]) | UInt16(wav[at + 1]) << 8 }
        func u32(_ at: Int) -> UInt32 { UInt32(u16(at)) | UInt32(u16(at + 2)) << 16 }
        #expect(text(0) == "RIFF" && text(8) == "WAVE" && text(12) == "fmt " && text(36) == "data")
        #expect(u32(4) == UInt32(wav.count - 8))
        #expect(u16(20) == 1 && u16(22) == 1 && u32(24) == 48_000 && u32(28) == 96_000 && u16(34) == 16)
        #expect(u32(40) == UInt32(samples.count * 2) && wav.count == 44 + samples.count * 2)
        let peak = stride(from: 44, to: wav.count, by: 2).map { abs(Int(Int16(bitPattern: u16($0)))) }.max() ?? 0
        #expect(abs(Float(peak) / Float(Int16.max) - ClickSynthesis.peak) < 0.001)
    }
}
