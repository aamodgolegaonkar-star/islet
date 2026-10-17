import Foundation
import Testing
@testable import IsletCore

@Suite("mediaremote-adapter stream decoding")
struct AdapterStreamDecoderTests {
    // Lines shaped like real `stream --micros` output captured on macOS 27.0.1.
    let full = #"{"type":"data","diff":false,"payload":{"title":"Not Like Us","artist":"Kendrick Lamar","album":"Not Like Us - Single","bundleIdentifier":"com.apple.Music","durationMicros":274192086,"elapsedTimeMicros":76806564,"timestampEpochMicros":1791922477096929,"playing":false,"playbackRate":0,"uniqueIdentifier":4674388228454884099}}"#

    @Test func emptyPayloadMeansNothingPlaying() {
        var decoder = AdapterStreamDecoder()
        #expect(decoder.consume(line: #"{"type":"data","diff":false,"payload":{}}"#) == .nothingPlaying)
    }

    @Test func fullPayloadDecodesMicroseconds() throws {
        var decoder = AdapterStreamDecoder()
        guard case let .update(s) = decoder.consume(line: full) else {
            Issue.record("expected update"); return
        }
        #expect(s.title == "Not Like Us")
        #expect(s.artist == "Kendrick Lamar")
        #expect(abs(s.duration - 274.192086) < 0.000_001)
        #expect(abs(s.elapsed - 76.806564) < 0.000_001)
        #expect(abs(s.timestamp.timeIntervalSince1970 - 1_791_922_477.096929) < 0.001)
        #expect(s.isPlaying == false)
        #expect(s.uniqueIdentifier == "4674388228454884099")
    }

    @Test func diffMergesAndNullRemoves() {
        var decoder = AdapterStreamDecoder()
        _ = decoder.consume(line: full)
        let diff = #"{"type":"data","diff":true,"payload":{"elapsedTimeMicros":90000000,"playing":true,"playbackRate":1,"album":null}}"#
        guard case let .update(s) = decoder.consume(line: diff) else {
            Issue.record("expected update"); return
        }
        #expect(s.elapsed == 90)
        #expect(s.isPlaying)
        #expect(s.album == "")
        #expect(s.title == "Not Like Us")
    }

    @Test func artworkDecodesAndBumpsRevision() {
        var decoder = AdapterStreamDecoder()
        _ = decoder.consume(line: full)
        let art = Data([0xFF, 0xD8, 0xFF, 0x01]).base64EncodedString()
        guard case let .update(s) = decoder.consume(line: #"{"type":"data","diff":true,"payload":{"artworkData":"\#(art)"}}"#) else {
            Issue.record("expected update"); return
        }
        #expect(s.artwork == Data([0xFF, 0xD8, 0xFF, 0x01]))
        #expect(s.artworkRevision == 1)
    }

    @Test func ignoresNonDataLines() {
        var decoder = AdapterStreamDecoder()
        #expect(decoder.consume(line: "garbage") == nil)
        #expect(decoder.consume(line: #"{"type":"other"}"#) == nil)
    }

    @Test func fallsBackToISOTimestamp() {
        var decoder = AdapterStreamDecoder()
        let line = #"{"type":"data","diff":false,"payload":{"title":"A","bundleIdentifier":"x","timestamp":"2026-10-13T20:14:37Z","elapsedTime":5.5,"duration":100}}"#
        guard case let .update(s) = decoder.consume(line: line) else {
            Issue.record("expected update"); return
        }
        #expect(s.elapsed == 5.5)
        #expect(s.timestamp == ISO8601DateFormatter().date(from: "2026-10-13T20:14:37Z"))
    }
}

@Suite("Elapsed-time interpolation")
struct ElapsedTests {
    let start = Date(timeIntervalSince1970: 1_000)

    @Test func advancesWhilePlaying() {
        let s = NowPlayingSnapshot(title: "x", duration: 200, elapsed: 10, timestamp: start, playbackRate: 1, isPlaying: true)
        #expect(s.elapsed(at: start.addingTimeInterval(5)) == 15)
    }

    @Test func frozenWhilePaused() {
        let s = NowPlayingSnapshot(title: "x", duration: 200, elapsed: 10, timestamp: start, isPlaying: false)
        #expect(s.elapsed(at: start.addingTimeInterval(60)) == 10)
    }

    @Test func clampsToDuration() {
        let s = NowPlayingSnapshot(title: "x", duration: 12, elapsed: 10, timestamp: start, playbackRate: 1, isPlaying: true)
        #expect(s.elapsed(at: start.addingTimeInterval(30)) == 12)
    }

    @Test func reanchorForOptimisticPause() {
        let s = NowPlayingSnapshot(title: "x", duration: 200, elapsed: 10, timestamp: start, playbackRate: 1, isPlaying: true)
        let paused = s.reanchored(at: start.addingTimeInterval(4), isPlaying: false)
        #expect(paused.elapsed == 14)
        #expect(paused.elapsed(at: start.addingTimeInterval(100)) == 14)
    }

    @Test func timeLabels() {
        #expect(TimeText.string(0) == "0:00")
        #expect(TimeText.string(76.9) == "1:16")
        #expect(TimeText.string(3725) == "1:02:05")
        #expect(TimeText.remaining(76.8, duration: 274.19) == "-3:18")
    }
}

@Suite("Playback ticks")
struct PlaybackTickTests {
    let start = Date(timeIntervalSince1970: 1_000)

    @Test func ticksAlignToWholeSecondSteps() throws {
        let timing = PlaybackTiming(elapsed: 10.3, timestamp: start, rate: 1, duration: 200)
        let first = try #require(timing.nextTick(after: start, steps: 4))
        #expect(abs(first.timeIntervalSince(start) - 0.2) < 1e-6)       // 10.3 -> 10.5
        let second = try #require(timing.nextTick(after: first, steps: 4))
        #expect(abs(second.timeIntervalSince(first) - 0.25) < 1e-6)     // 10.5 -> 10.75
    }

    @Test func noTicksWhilePausedOrAfterTheEnd() {
        let paused = PlaybackTiming(elapsed: 10, timestamp: start, rate: 0, duration: 200)
        #expect(paused.nextTick(after: start, steps: 4) == nil)
        let ended = PlaybackTiming(elapsed: 200, timestamp: start, rate: 1, duration: 200)
        #expect(ended.nextTick(after: start, steps: 4) == nil)
    }

    @Test func lastTickLandsOnTheEnd() throws {
        let timing = PlaybackTiming(elapsed: 199.9, timestamp: start, rate: 1, duration: 199.95)
        let last = try #require(timing.nextTick(after: start, steps: 1))
        #expect(abs(last.timeIntervalSince(start) - 0.05) < 1e-6)
        #expect(timing.nextTick(after: last, steps: 1) == nil)
    }
}

@Suite("Playback reconciliation")
struct PlaybackReconcilerTests {
    let start = Date(timeIntervalSince1970: 1_000)

    func report(elapsed: TimeInterval, at date: Date, playing: Bool = true, title: String = "x") -> NowPlayingSnapshot {
        NowPlayingSnapshot(title: title, duration: 300, elapsed: elapsed, timestamp: date,
                           playbackRate: playing ? 1 : 0, isPlaying: playing)
    }

    @Test func staleReportAfterSeekKeepsTheTarget() {
        var reconciler = PlaybackReconciler()
        let seeked = report(elapsed: 120, at: start)
        reconciler.userSeeked(at: start)
        let now = start.addingTimeInterval(0.4)
        let shown = reconciler.reconcile(report(elapsed: 40.4, at: now), with: seeked, at: now)
        #expect(abs(shown.elapsed(at: now) - 120.4) < 1e-6)
    }

    @Test func confirmingReportEndsTheSeekHold() {
        var reconciler = PlaybackReconciler()
        let seeked = report(elapsed: 120, at: start)
        reconciler.userSeeked(at: start)
        let now = start.addingTimeInterval(0.6)
        _ = reconciler.reconcile(report(elapsed: 120.9, at: now), with: seeked, at: now)
        // Once confirmed, a genuine jump (e.g. the user seeking in Music) is shown at once.
        let later = start.addingTimeInterval(1)
        let shown = reconciler.reconcile(report(elapsed: 30, at: later), with: seeked, at: later)
        #expect(shown.elapsed(at: later) == 30)
    }

    @Test func seekHoldExpires() {
        var reconciler = PlaybackReconciler()
        let seeked = report(elapsed: 120, at: start)
        reconciler.userSeeked(at: start)
        let late = start.addingTimeInterval(3)
        #expect(reconciler.reconcile(report(elapsed: 40, at: late), with: seeked, at: late).elapsed == 40)
    }

    @Test func staleIsPlayingAfterPauseIsIgnored() {
        var reconciler = PlaybackReconciler()
        let paused = report(elapsed: 50, at: start, playing: false)
        reconciler.userSetPlaying(false, at: start)
        let now = start.addingTimeInterval(0.2)
        let shown = reconciler.reconcile(report(elapsed: 50.2, at: now, playing: true), with: paused, at: now)
        #expect(shown.isPlaying == false)
        #expect(shown.elapsed(at: now.addingTimeInterval(5)) == 50)
        let confirmed = reconciler.reconcile(report(elapsed: 50.3, at: now, playing: false), with: shown, at: now)
        #expect(confirmed.isPlaying == false)
        #expect(confirmed.elapsed == 50)   // within tolerance: the paused position doesn't twitch
    }

    @Test func smallCorrectionsKeepTheClockLargeOnesApply() {
        var reconciler = PlaybackReconciler()
        let current = report(elapsed: 60, at: start)
        let now = start.addingTimeInterval(10)
        let nudged = reconciler.reconcile(report(elapsed: 69.85, at: now), with: current, at: now)
        #expect(nudged.timestamp == start)
        let jumped = reconciler.reconcile(report(elapsed: 90, at: now), with: current, at: now)
        #expect(jumped.elapsed(at: now) == 90)
    }

    @Test func newTrackIsTakenAsIs() {
        var reconciler = PlaybackReconciler()
        reconciler.userSeeked(at: start)
        let next = report(elapsed: 0, at: start, title: "y")
        #expect(reconciler.reconcile(next, with: report(elapsed: 120, at: start), at: start) == next)
    }
}

@Suite("Browser placeholders")
struct PlaceholderTests {
    @Test func siteMakingSoundIsAPlaceholder() {
        // What Opera Air reports for a page's background sound.
        let page = NowPlayingSnapshot(title: "A site is playing media", bundleIdentifier: "com.operasoftware.OperaAir")
        #expect(page.isPlaceholder)
    }

    @Test func realSongsAreNot() {
        #expect(!NowPlayingSnapshot(title: "9", artist: "Drake", album: "Views").isPlaceholder)
        // A web player that names the artist (YouTube Music in a browser).
        #expect(!NowPlayingSnapshot(title: "Song", artist: "Artist", bundleIdentifier: "com.google.Chrome").isPlaceholder)
    }

    @Test func lyricsSkipSongsWithoutAnArtist() async throws {
        let client = LRCLIBClient(userAgent: "IsletTests", cacheDirectory: nil)
        let result = try await client.lyrics(title: "A site is playing media", artist: "", album: "", duration: 0)
        #expect(result == nil)
    }
}
