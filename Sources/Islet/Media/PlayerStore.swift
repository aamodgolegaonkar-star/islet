import AppKit
import IsletCore
import Observation

enum LyricsState: Equatable {
    case idle
    case loading
    case synced([LyricLine])
    case plain(String)
    case instrumental
    case unavailable
}

/// Single source of truth for what is playing, shared by every surface of the app.
@MainActor
@Observable
final class PlayerStore {
    private(set) var snapshot: NowPlayingSnapshot?
    /// Artwork delivered with Now Playing (typically 600 px).
    private(set) var artwork: NSImage?
    /// Catalog artwork (1400 px) for large surfaces, when the album is found.
    private(set) var hiResArtwork: NSImage?
    private(set) var palette: Palette = .fallback
    private(set) var motion: MotionArtwork?
    private(set) var lyrics: LyricsState = .idle {
        didSet {
            guard lyrics != oldValue else { return }
            if case .synced(let lines) = lyrics {
                wordStream = WordStream(lines: lines)
            } else {
                wordStream = WordStream(lines: [])
            }
        }
    }
    /// Every sung word in order, for the Fisheye stack (built once per song, not per frame).
    private(set) var wordStream = WordStream(lines: [])
    private(set) var volume: Double = 0.5
    private(set) var sourceName = "Connecting…"
    /// Increments on every song change; drives the island's "bump".
    private(set) var trackChangeCount = 0

    var displayArtwork: NSImage? { hiResArtwork ?? artwork }
    var hasTrack: Bool { snapshot != nil }
    var isPlaying: Bool { snapshot?.isPlaying ?? false }
    var duration: TimeInterval { snapshot?.duration ?? 0 }
    /// The playback clock views schedule their redraws from.
    var timing: PlaybackTiming? { snapshot?.timing }
    var title: String { snapshot?.title ?? "Not Playing" }
    var artist: String { snapshot?.artist ?? "" }
    /// The web player a browser is playing (YouTube Music, Deezer…), when Islet recognises it.
    private(set) var webService: String?
    /// The artist, plus the web player's name when the music comes from a browser.
    var subtitle: String {
        guard let webService else { return artist }
        return artist.isEmpty ? webService : "\(artist) · \(webService)"
    }

    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored private let adapter = AdapterSource()
    @ObservationIgnored private let musicApp = MusicAppSource()
    @ObservationIgnored private let spotify = SpotifySource()
    /// The player chosen in Settings; `.automatic` follows the system Now Playing service.
    @ObservationIgnored private var mode = PlayerSource.automatic
    /// While the system service is down: the latest report from each app, to pick between.
    @ObservationIgnored private var fallbackEvents: [String: AdapterEvent] = [:]
    /// Volume or mute changed outside Islet (the keys): the island shows the level.
    @ObservationIgnored var onVolumeKeys: ((Float, Bool) -> Void)?
    /// Shuffle and repeat of the playing app (nil: not a player Islet can control that way).
    private(set) var shuffle: Bool?
    private(set) var repeatMode: RepeatMode?
    @ObservationIgnored private var usingFallback = false
    @ObservationIgnored private let systemVolume = SystemVolume()
    @ObservationIgnored private let lyricsClient: LRCLIBClient
    @ObservationIgnored private let appleLyricsClient: AppleMusicLyricsClient
    /// Tokens Apple refused; not tried again until they change.
    @ObservationIgnored private var refusedCredentials: AppleMusicLyricsClient.Credentials?
    @ObservationIgnored private let lookup = ITunesLookup()
    @ObservationIgnored private var lyricsTask: Task<Void, Never>?
    @ObservationIgnored private var lookupTask: Task<Void, Never>?
    @ObservationIgnored private var paletteTask: Task<Void, Never>?
    @ObservationIgnored private var lastTrackKey: String?
    /// Offscreen previews and self-tests: state changes only, no commands sent.
    @ObservationIgnored private(set) var isPreview = false
    /// The last transport command a control asked for (read by the self-test).
    @ObservationIgnored var lastCommand: MediaCommand?
    @ObservationIgnored private var lastArtworkRevision = -1
    /// Holds the user's seeks and play/pause until the source confirms them.
    @ObservationIgnored private var reconciler = PlaybackReconciler()

    init(settings: AppSettings) {
        self.settings = settings
        lyricsClient = LRCLIBClient(
            userAgent: "Islet/1.0 (personal macOS now-playing app)",
            cacheDirectory: settings.lyricsCacheDirectory)
        appleLyricsClient = AppleMusicLyricsClient(cacheDirectory: settings.lyricsCacheDirectory)
    }

    /// Both Apple Music tokens, when the user has saved them; otherwise lyrics come from LRCLIB alone.
    private var appleCredentials: AppleMusicLyricsClient.Credentials? {
        guard let developer = settings.developerToken, let user = settings.musicUserToken else { return nil }
        return .init(developerToken: developer, userToken: user,
                     storefront: Locale.current.region?.identifier.lowercased() ?? "us")
    }

    func start() {
        adapter.onEvent = { [weak self] in self?.apply($0) }
        adapter.onUnavailable = { [weak self] in self?.switchToFallback() }
        musicApp.onEvent = { [weak self] in self?.direct($0, from: "music") }
        spotify.onEvent = { [weak self] in self?.direct($0, from: "spotify") }
        use(settings.playerSource)
        volume = Double(systemVolume.volume ?? 0.5)
        systemVolume.onChange = { [weak self] in self?.volume = Double($0) }
        systemVolume.onUserChange = { [weak self] volume, muted in self?.onVolumeKeys?(volume, muted) }
        systemVolume.startListening()
    }

    /// Stops the adapter process (called when the app quits).
    func stop() {
        adapter.stop()
        musicApp.stop()
        spotify.stop()
    }

    /// Switches which player Islet follows (Settings).
    func use(_ source: PlayerSource) {
        holding = nil
        adapter.stop()
        musicApp.stop()
        spotify.stop()
        usingFallback = false
        fallbackEvents = [:]
        lastArtworkRevision = -1
        mode = source
        switch source {
        case .automatic:
            if adapter.start() {
                sourceName = "System Now Playing"
                Log.media.info("Streaming Now Playing via mediaremote-adapter")
            } else {
                switchToFallback()
            }
        case .appleMusic:
            musicApp.start(pollInterval: 10)
            sourceName = "Apple Music"
        case .spotify:
            spotify.start(pollInterval: 10)
            sourceName = "Spotify"
        }
    }

    /// The app commands go to directly, when Islet isn't using the system service.
    private var directApp: String? {
        // Holding Music or Spotify on screen: the controls are for that player, not for
        // whatever has the system's Now Playing slot.
        if let holding { return holding.app }
        return switch mode {
        case .appleMusic: "Music"
        case .spotify: "Spotify"
        case .automatic: usingFallback ? (Self.scriptableApp(snapshot?.bundleIdentifier) ?? "Music") : nil
        }
    }

    private func refreshDirectSource() {
        if mode == .spotify || snapshot?.bundleIdentifier == SpotifySource.bundleID { spotify.refreshSoon() }
        if mode == .appleMusic || snapshot?.bundleIdentifier == "com.apple.Music" { musicApp.refreshSoon() }
    }

    /// Reports from the apps themselves: straight through when one app is chosen; while
    /// the system service is down, whichever app is playing wins.
    private func direct(_ event: AdapterEvent, from source: String) {
        if holding != nil { return holdUpdate(event) }
        guard mode == .automatic else {
            apply(event)
            return
        }
        fallbackEvents[source] = event
        let reports = fallbackEvents.values.compactMap { event -> NowPlayingSnapshot? in
            if case let .update(snapshot) = event { snapshot } else { nil }
        }
        if let pick = reports.first(where: \.isPlaying) ?? reports.first {
            apply(.update(pick))
        } else {
            apply(.nothingPlaying)
        }
    }

    func elapsed(at date: Date) -> TimeInterval {
        snapshot?.elapsed(at: date) ?? 0
    }

    /// The song position lyrics follow: the playback position plus the Settings offset.
    func lyricsPosition(at date: Date) -> TimeInterval {
        elapsed(at: date) + LiveTuning.shared.lyricsOffset
    }

    // MARK: - Commands (optimistic, then sent to the source)

    func togglePlayPause() {
        guard let current = snapshot else { return }
        let now = Date()
        snapshot = current.reanchored(at: now, isPlaying: !current.isPlaying)
        reconciler.userSetPlaying(!current.isPlaying, at: now)
        send(.togglePlayPause)
    }

    func next() { send(.nextTrack) }
    func previous() { send(.previousTrack) }

    func seek(to seconds: TimeInterval) {
        guard let current = snapshot else { return }
        let target = min(max(seconds, 0), current.duration > 0 ? current.duration : seconds)
        let now = Date()
        snapshot = current.reanchored(at: now, elapsed: target)
        reconciler.userSeeked(at: now)
        let bundle = current.bundleIdentifier
        guard !isPreview else { return }
        let app = directApp
        Task {
            if let app {
                _ = await MusicAppSource.seek(to: target, in: app)
                refreshDirectSource()
            } else if await adapter.seek(to: target) {
                Log.media.info("Seek to \(target, format: .fixed(precision: 1)) s")
            } else if let app = Self.scriptableApp(bundle) {
                Log.media.notice("Adapter seek failed; using AppleScript")
                _ = await MusicAppSource.seek(to: target, in: app)
            }
        }
    }

    /// The volume keys, when Islet handles them itself: one step up or down (1/16, or a
    /// quarter step with ⌥⇧), or mute. Returns the new level for the island.
    func stepVolume(_ direction: Int, fine: Bool) -> (volume: Double, muted: Bool) {
        if direction == 0 {
            let muted = !systemVolume.muted
            systemVolume.setMuted(muted)
            return (volume, muted)
        }
        let step = fine ? 1.0 / 64 : 1.0 / 16
        // Step from the device's real level, which may have changed without Islet noticing,
        // except mid-run of presses: the previous write may still be in flight.
        let now = ProcessInfo.processInfo.systemUptime
        let base = now - lastVolumeStepAt < 0.5 ? volume : Double(systemVolume.volume ?? Float(volume))
        lastVolumeStepAt = now
        let next = min(max(((base / step).rounded() + Double(direction)) * step, 0), 1)
        if systemVolume.muted { systemVolume.setMuted(false) }
        setVolume(next)
        return (next, false)
    }
    private var lastVolumeStepAt: TimeInterval = 0

    func setVolume(_ value: Double) {
        volume = min(max(value, 0), 1)
        guard !isPreview else { return }
        systemVolume.setVolume(Float(volume))
    }

    private func send(_ command: MediaCommand) {
        lastCommand = command
        guard !isPreview else { return }
        let bundle = snapshot?.bundleIdentifier
        let app = directApp
        Task {
            var sent = false
            if let app {
                sent = await MusicAppSource.send(command, to: app)
                refreshDirectSource()
            } else if await adapter.send(command) {
                sent = true
            } else if let app = Self.scriptableApp(bundle) {
                sent = await MusicAppSource.send(command, to: app)
            }
            Log.media.notice("\(String(describing: command), privacy: .public) \(sent ? "sent" : "failed", privacy: .public)")
        }
    }

    /// Players Islet can also drive over AppleScript when the system channel fails.
    private static func scriptableApp(_ bundle: String?) -> String? {
        switch bundle {
        case "com.apple.Music": "Music"
        case "com.spotify.client": "Spotify"
        default: nil
        }
    }

    // MARK: - Shuffle & repeat

    /// Reads shuffle and repeat from the playing app (Music or Spotify), e.g. when the
    /// full player opens. Other players hide the buttons.
    func refreshPlaybackOptions() {
        guard !isPreview, let app = Self.scriptableApp(snapshot?.bundleIdentifier), isRunning(app) else {
            shuffle = nil
            repeatMode = nil
            return
        }
        Task {
            let script = app == "Music"
                ? "tell application \"Music\" to return (shuffle enabled as text) & tab & (song repeat as text)"
                : "tell application \"Spotify\" to return (shuffling as text) & tab & (repeating as text)"
            guard let output = await MusicAppSource.osascript(script) else { return }
            let fields = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\t")
            guard fields.count == 2 else { return }
            self.shuffle = fields[0] == "true"
            self.repeatMode = switch fields[1] {
            case "all", "true": .all
            case "one": .one
            default: .off
            }
        }
    }

    func toggleShuffle() {
        guard let current = shuffle, let app = Self.scriptableApp(snapshot?.bundleIdentifier) else { return }
        shuffle = !current
        let script = app == "Music"
            ? "tell application \"Music\" to set shuffle enabled to \(!current)"
            : "tell application \"Spotify\" to set shuffling to \(!current)"
        Task { _ = await MusicAppSource.osascript(script) }
    }

    /// Off → all → one → off (Spotify's AppleScript has no repeat-one: off ↔ all).
    func cycleRepeat() {
        guard let current = repeatMode, let app = Self.scriptableApp(snapshot?.bundleIdentifier) else { return }
        let next: RepeatMode = switch current {
        case .off: .all
        case .all: app == "Music" ? .one : .off
        case .one: .off
        }
        repeatMode = next
        let script = app == "Music"
            ? "tell application \"Music\" to set song repeat to \(next.rawValue)"
            : "tell application \"Spotify\" to set repeating to \(next != .off)"
        Task { _ = await MusicAppSource.osascript(script) }
    }

    private func isRunning(_ app: String) -> Bool {
        let bundle = app == "Music" ? "com.apple.Music" : SpotifySource.bundleID
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty
    }

    // MARK: - Source events

    private func switchToFallback() {
        guard !usingFallback else { return }
        holding = nil
        usingFallback = true
        adapter.stop()
        lastArtworkRevision = -1
        musicApp.start(pollInterval: 1.5)
        spotify.start(pollInterval: 5)
        sourceName = "Apple Music & Spotify (direct)"
        Log.media.notice("Adapter unavailable; following Music and Spotify directly")
    }

    // MARK: - What's playing comes first

    /// A playing Music or Spotify kept on screen while the system's Now Playing slot shows
    /// something that isn't really playing; `other` is that report, shown once the player stops.
    @ObservationIgnored private var holding: (other: AdapterEvent, app: String)?

    /// Events from the system service. macOS gives its one Now Playing slot to whichever app
    /// changed last, so a paused video or a page's background sound ("A site is playing
    /// media") could push the song you're listening to off the island. Here what's actually
    /// playing wins:
    /// - while Music or Spotify plays, something paused, silent or a browser placeholder
    ///   doesn't replace it (Islet follows the player directly meanwhile);
    /// - a real song starting anywhere else does replace it;
    /// - once the held player pauses, another song that's playing takes over, but a page's
    ///   background sound doesn't push out your paused song.
    func apply(_ event: AdapterEvent) {
        guard mode == .automatic, !usingFallback, !isPreview else { return present(event) }
        let incoming: NowPlayingSnapshot? = if case let .update(track) = event { track } else { nil }
        let playsForReal = incoming.map { $0.isPlaying && !Self.isBrowserPlaceholder($0) } ?? false

        if let held = holding {
            if let incoming, incoming.bundleIdentifier == Self.bundle(of: held.app) {
                // The system reports the held player again: follow it; if it stopped and the
                // other report is playing, that one is what's on now.
                releaseHold()
                if !incoming.isPlaying, case let .update(other) = held.other, other.isPlaying,
                   !Self.isBrowserPlaceholder(other) {
                    return present(held.other)
                }
                return present(event)
            }
            if playsForReal {
                releaseHold()
                return present(event)
            }
            holding?.other = event
            return
        }

        if let current = snapshot, let app = Self.scriptableApp(current.bundleIdentifier),
           incoming?.bundleIdentifier != current.bundleIdentifier, !playsForReal {
            if current.isPlaying { return hold(event, behind: app) }
            // Your paused song stays while its app is open; a page's sound isn't a song.
            if let incoming, Self.isBrowserPlaceholder(incoming), isRunning(app) { return }
        }
        present(event)
    }

    /// Keeps the playing player on screen, following it directly until it stops.
    private func hold(_ other: AdapterEvent, behind app: String) {
        holding = (other, app)
        Log.media.notice("Keeping \(app, privacy: .public) on screen: it's the one playing")
        if app == "Music" { musicApp.start(pollInterval: 2) } else { spotify.start(pollInterval: 3) }
    }

    /// A report from the held player: shown while it plays. Once it pauses, another song
    /// that's playing takes over, otherwise the paused player stays; if it quits, the other
    /// report is shown.
    private func holdUpdate(_ event: AdapterEvent) {
        guard let holding else { return }
        if case let .update(track) = event, track.isPlaying { return present(event) }
        releaseHold()
        // Another song playing takes over; a page's background sound doesn't replace your
        // paused song (it would leave nothing to resume from the island).
        if case .update(let other) = holding.other, other.isPlaying, !Self.isBrowserPlaceholder(other) {
            present(holding.other)
        } else if case .nothingPlaying = event, case .update = holding.other {
            // The held player quit: show what the system reports instead.
            present(holding.other)
        } else {
            present(event)
        }
    }

    private func releaseHold() {
        guard let holding else { return }
        self.holding = nil
        if holding.app == "Music" { musicApp.stop() } else { spotify.stop() }
    }

    /// A browser's "A site is playing media": a page making sound, not a song.
    private static func isBrowserPlaceholder(_ track: NowPlayingSnapshot) -> Bool {
        guard track.isPlaceholder else { return false }
        // Browsers say "A site is playing media" (or "…is playing audio").
        let title = track.title.lowercased()
        return WebPlayers.isBrowser(track.bundleIdentifier)
            || title.contains("is playing media") || title.contains("is playing audio")
    }

    private static func bundle(of app: String) -> String {
        app == "Music" ? "com.apple.Music" : SpotifySource.bundleID
    }

    private func present(_ event: AdapterEvent) {
        guard case let .update(incoming) = event else {
            if snapshot != nil { Log.media.debug("Now Playing cleared (\(self.sourceName, privacy: .public))") }
            if snapshot != nil { snapshot = nil }
            lastTrackKey = nil
            return
        }
        let next = reconciler.reconcile(incoming, with: snapshot, at: Date())
        let trackChanged = next.trackKey != lastTrackKey
        // Unchanged reports (common: the source repeats itself) mustn't redraw anything.
        if next != snapshot { snapshot = next }
        if next.artworkRevision != lastArtworkRevision {
            lastArtworkRevision = next.artworkRevision
            updateArtwork(next.artwork)
        }
        if trackChanged {
            lastTrackKey = next.trackKey
            trackDidChange(next)
        }
    }

    private func updateArtwork(_ data: Data?) {
        paletteTask?.cancel()
        guard let data, let image = NSImage(data: data) else {
            artwork = nil
            return
        }
        artwork = image
        paletteTask = Task { [weak self] in
            let palette = await Task.detached(priority: .utility) {
                ArtworkPixels.palette(from: data)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.palette = palette
        }
    }

    /// Gives lyric words their pictures (used when Settings turns word icons on). Tagging
    /// words takes a few milliseconds per song, so it runs off the main thread.
    private nonisolated static func withSymbols(_ lines: [LyricLine]) async -> [LyricLine] {
        await Task.detached(priority: .utility) { WordSymbols.system?.annotate(lines) ?? lines }.value
    }

    private func trackDidChange(_ track: NowPlayingSnapshot) {
        trackChangeCount += 1
        Log.media.info("Track: \(track.title, privacy: .public) — \(track.artist, privacy: .public) [\(track.bundleIdentifier, privacy: .public)]")
        hiResArtwork = nil
        motion = nil
        webService = nil
        if WebPlayers.isBrowser(track.bundleIdentifier), !track.isPlaceholder, !isPreview {
            let (bundle, title, key) = (track.bundleIdentifier, track.title, track.trackKey)
            Task { [weak self] in
                // The tab's title catches up with the song a moment after it starts.
                try? await Task.sleep(for: .milliseconds(800))
                let service = await WebPlayers.service(bundle: bundle, title: title)
                guard let self, self.lastTrackKey == key else { return }
                self.webService = service
            }
        }
        lyrics = .loading
        lyricsTask?.cancel()
        lookupTask?.cancel()
        // Nothing to look up for a browser's "A site is playing media".
        guard !track.isPlaceholder else {
            lyrics = .unavailable
            return
        }

        let key = track.trackKey
        let (title, artist, album, duration) = (track.title, track.artist, track.album, track.duration)
        let client = lyricsClient
        let apple = appleLyricsClient
        let credentials = appleCredentials.flatMap { $0 == refusedCredentials ? nil : $0 }
        lyricsTask = Task { [weak self] in
            // Apple Music times every word; try it first when the user has given Islet the tokens.
            if let credentials {
                do {
                    if let ttml = try await apple.ttml(title: title, artist: artist, duration: duration, credentials: credentials) {
                        let lines = TTMLParser.parse(ttml)
                        if !lines.isEmpty {
                            let pictured = await Self.withSymbols(lines)
                            guard let self, !Task.isCancelled, self.lastTrackKey == key else { return }
                            self.lyrics = .synced(pictured)
                            let exact = lines.contains(where: \.hasExactWordTiming)
                            Log.lyrics.info("Apple Music lyrics: \(lines.count) rows, timed by \(exact ? "word" : "line", privacy: .public)")
                            return
                        }
                    }
                    Log.lyrics.info("No Apple Music lyrics; trying LRCLIB")
                } catch AppleMusicLyricsClient.Failure.unauthorized {
                    Log.lyrics.error("Apple Music refused the tokens; using LRCLIB until they change")
                    self?.refusedCredentials = credentials
                } catch {
                    Log.lyrics.notice("Apple Music lyrics failed (\(String(describing: error), privacy: .public)); trying LRCLIB")
                }
                guard !Task.isCancelled else { return }
            }
            // A failed request (offline after wake, a timeout, rate limiting) is not "no
            // lyrics": retry a few times before giving up. A real "not found" returns at once.
            var content: LyricsContent?
            var failed = false
            for delay in [1.0, 3.0, 8.0, nil] {
                do {
                    content = try await client.lyrics(title: title, artist: artist, album: album, duration: duration)
                    failed = false
                    break
                } catch {
                    failed = true
                    guard let delay else { break }
                    var wait = delay
                    if case LRCLIBClient.Failure.rateLimited(let retryAfter?) = error { wait = max(wait, retryAfter) }
                    Log.lyrics.notice("Lyrics lookup failed (\(String(describing: error), privacy: .public)); retrying in \(wait) s")
                    try? await Task.sleep(for: .seconds(wait))
                    guard !Task.isCancelled else { return }
                }
            }
            var lines: [LyricLine] = []
            if case .synced(let lrc)? = content {
                lines = await Self.withSymbols(LRCParser.parse(lrc, duration: duration))
            }
            guard let self, !Task.isCancelled, self.lastTrackKey == key else { return }
            switch content {
            case .synced?:
                self.lyrics = lines.isEmpty ? .unavailable : .synced(lines)
                let exact = lines.contains(where: \.hasExactWordTiming)
                Log.lyrics.info("Synced lyrics: \(lines.count) rows, words \(exact ? "timed" : "estimated", privacy: .public)")
            case .plain(let text)?: self.lyrics = .plain(text)
            case .instrumental?: self.lyrics = .instrumental
            case nil:
                self.lyrics = .unavailable
                if failed {
                    Log.lyrics.error("Lyrics lookup kept failing")
                } else {
                    Log.lyrics.info("No lyrics found")
                }
            }
        }

        if track.bundleIdentifier == "com.spotify.client" { spotifyArtworkFallback(for: key) }

        let lookup = lookup
        let token = settings.animatedArtworkEnabled ? settings.developerToken : nil
        lookupTask = Task { [weak self] in
            let country = Locale.current.region?.identifier.lowercased() ?? "us"
            guard let found = await lookup.album(title: title, artist: artist, album: album, country: country)
            else { return }
            if let url = found.artworkURL(size: 1400),
               let data = try? await URLSession.shared.data(from: url).0,
               let self, !Task.isCancelled, self.lastTrackKey == key {
                self.hiResArtwork = NSImage(data: data)
                // Players that publish no artwork (some Spotify tracks) get the catalog's.
                if self.artwork == nil { self.updateArtwork(data) }
                Log.artwork.info("Hi-res artwork for album \(found.collectionID): \(data.count) bytes")
            }
            if let token {
                let catalog = AppleMusicCatalog(developerToken: token, storefront: country)
                let motion = await catalog.motionArtwork(albumID: found.collectionID)
                guard let self, !Task.isCancelled, self.lastTrackKey == key else { return }
                self.motion = motion
                Log.artwork.info("Motion artwork: \(motion == nil ? "none" : "found", privacy: .public)")
            }
        }
    }

    /// Spotify usually publishes artwork with Now Playing; if a track arrives without any
    /// (and the Apple catalog has no match), ask Spotify for its artwork link instead.
    private func spotifyArtworkFallback(for key: String) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, self.lastTrackKey == key, self.artwork == nil,
                  let url = await MusicAppSource.spotifyArtworkURL(),
                  let data = try? await URLSession.shared.data(from: url).0,
                  self.lastTrackKey == key, self.artwork == nil else { return }
            self.updateArtwork(data)
            Log.artwork.info("Spotify artwork: \(data.count) bytes")
        }
    }

    // MARK: - Previews

    /// Injects fixed state for offscreen snapshot rendering.
    func loadPreview(_ snapshot: NowPlayingSnapshot, artwork: NSImage?, palette: Palette, lyrics: LyricsState) {
        self.snapshot = snapshot
        self.artwork = artwork
        self.palette = palette
        self.lyrics = lyrics
        isPreview = true
        sourceName = "Preview"
    }
}

/// A player's repeat setting; raw values are Music's AppleScript terms.
enum RepeatMode: String {
    case off, all, one
}
