import AppKit
import IsletCore
import SwiftUI

/// Developer hooks for a running Islet, enabled only with
/// `defaults write local.islet.Islet debugTools -bool true`.
///
/// Commands arrive as the object of the distributed notification "local.islet.debug"
/// (see scripts/islet-debug.sh). "capture" writes PNGs of Islet's own windows — including
/// real Liquid Glass — to ~/Library/Caches/Islet/captures without screen-recording access.
@MainActor
final class DebugTools: NSObject {
    private let island: IslandController
    private let player: FullPlayerController
    private let lockScreen: LockScreenController
    private let settings: AppSettings

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "debugTools") }

    static var captureDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Islet/captures")
    }

    /// Set by the app delegate for the settings/tutorial commands.
    var openSettings: () -> Void = {}
    var openTutorial: () -> Void = {}

    init(island: IslandController, player: FullPlayerController, lockScreen: LockScreenController, settings: AppSettings) {
        self.island = island
        self.player = player
        self.lockScreen = lockScreen
        self.settings = settings
        super.init()
        guard Self.isEnabled else { return }
        Log.media.notice("Debug tools enabled")
        // Selector-based so `.deliverImmediately` applies: NSApplication suspends distributed
        // notifications while the (always background) app is inactive.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(received(_:)), name: .init("local.islet.debug"),
            object: nil, suspensionBehavior: .deliverImmediately)
    }

    @objc private func received(_ note: Notification) {
        handle(note.object as? String ?? "")
    }

    private func handle(_ command: String) {
        Log.media.notice("Debug command: \(command, privacy: .public)")
        switch command {
        case "capture": captureAll()
        case "island.film": filmIslandExpand()
        case "island.frames": FrameProbe.run(island: island)
        case let click where click.hasPrefix("click:"): island.debugClick(String(click.dropFirst(6)))
        case "island.expand": island.debugSetPresentation(.expanded)
        case "island.collapse": island.debugSetPresentation(.compact)
        case "island.charging":
            island.showCharging(Battery.current() ?? BatteryState(level: 0.64, isCharging: true, isPluggedIn: true))
        case "island.unlock": island.showUnlocked()
        case "island.volume": island.showLevel(LevelHUD(kind: .volume, value: 0.62))
        case "island.controls": island.debugSetPresentation(.controls)
        case "island.hover": island.model.isHovered = true
        case "island.targets":
            try? island.debugTargets.write(to: Self.captureDirectory.appending(path: "targets.txt"), atomically: true, encoding: .utf8)
        case "island.shelf":
            island.debugShowShelf(adding: [])
        case "island.shelffiles":
            let folder = FileManager.default.temporaryDirectory.appending(path: "IsletShelfTest")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let files = ["Trip photos.jpg", "Budget 2026.numbers", "Lyrics draft.txt"].map { folder.appending(path: $0) }
            for file in files where !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: Data())
            }
            island.debugShowShelf(adding: files)
        case "island.shelfclear":
            island.model.shelf.clear()
        case "island.timer": island.startTimer(minutes: 25)
        case "island.timerdone":
            island.cancelTimer()
            island.debugShowTimerDone()
        case "outputs":
            for output in AudioOutputs.list() {
                Log.media.notice("Output \(output.name, privacy: .public) [\(output.symbol, privacy: .public)] current=\(output.isCurrent) connected=\(output.isConnected)")
            }
            Log.media.notice("Headphones: \(String(describing: HeadphoneStatus.current()), privacy: .public)")
        case "inject.placeholder":
            // A browser page's background sound taking the Now Playing slot.
            island.store.apply(.update(NowPlayingSnapshot(title: "A site is playing media", isPlaying: true,
                                                          bundleIdentifier: "com.operasoftware.OperaAir")))
            Log.media.notice("Now showing: \(self.island.store.title, privacy: .public)")
        case "inject.paused":
            // Another app, paused, taking the slot.
            island.store.apply(.update(NowPlayingSnapshot(title: "Some Video", artist: "Some Channel", isPlaying: false,
                                                          bundleIdentifier: "com.google.Chrome")))
            Log.media.notice("Now showing: \(self.island.store.title, privacy: .public)")
        case "inject.playing":
            // Another app actually playing a song: it should take over.
            island.store.apply(.update(NowPlayingSnapshot(title: "Other Song", artist: "Other Artist", isPlaying: true,
                                                          bundleIdentifier: "com.google.Chrome")))
            Log.media.notice("Now showing: \(self.island.store.title, privacy: .public)")
        case "levels":
            Log.media.notice("Levels \(WaveformLevels.shared.levels.map { String(format: "%.2f", $0) }.joined(separator: " "), privacy: .public) peak \(AudioTapEngine.shared.debugPeak, format: .fixed(precision: 4)) \(AudioTapEngine.shared.debugInfo, privacy: .public)")
        case "island.lowbattery": island.showLowBattery(20)
        case "island.mic": island.model.micActive.toggle()
        case "island.camera": island.model.cameraActive.toggle()
        case "island.tuck": island.debugTuck()
        case "island.volumesweep":
            // Like a Touch Bar slide: 60 level changes over 1.5 s.
            Task { @MainActor [island] in
                for step in 0..<60 {
                    island.showLevel(LevelHUD(kind: .volume, value: Double(step) / 59))
                    try? await Task.sleep(for: .milliseconds(25))
                }
            }
        case "island.brightness": island.showLevel(LevelHUD(kind: .brightness, value: 0.8))
        case "island.airpods":
            island.showHeadphones(HeadphoneCard(
                deviceName: "Paarth’s AirPods Pro",
                model: HeadphoneCatalog.identify(name: "AirPods Pro", vendorID: nil, productID: nil),
                battery: HeadphoneBattery(left: 92, right: 88, case: 45)))
        case "island.max":
            island.showHeadphones(HeadphoneCard(
                deviceName: "Paarth’s AirPods Max",
                model: HeadphoneCatalog.identify(name: "", vendorID: 0x004C, productID: 0x200A),
                battery: HeadphoneBattery(single: 64)))
        case "island.sony":
            island.showHeadphones(HeadphoneCard(
                deviceName: "WWIII survivor🫡",
                model: HeadphoneCatalog.identify(name: "", vendorID: 0x054C, productID: 0x0F1E),
                battery: HeadphoneBattery(single: 70)))
        case "player.open": player.open(from: island.artScreenRect())
        case "player.close": player.close()
        case "player.lyrics":
            withAnimation(.spring(response: 0.6, dampingFraction: 0.86)) { player.model.showLyrics.toggle() }
        case "settings.open": openSettings()
        case "tutorial.open": openTutorial()
        case "tutorial.next": NotificationCenter.default.post(name: OnboardingView.debugNext, object: nil)
        case "lock.preview": lockScreen.showPreview()
        case "lock.fail": lockScreen.authenticationFailed()
        case "lock.expand": lockScreen.debugExpand()
        case "lock.lyrics": lockScreen.debugToggleLyrics()
        case "lock.collapse": lockScreen.model.collapse()
        case "lock.hide": lockScreen.hidePreview()
        default:
            if command.hasPrefix("style."), let style = IslandStyle(rawValue: String(command.dropFirst(6))) {
                settings.islandStyle = style
                island.reposition()
            }
        }
    }

    /// Photographs the island at fixed times through the expand morph. Captures run on a
    /// background queue so they never hold up the main thread that drives the animation.
    private func filmIslandExpand() {
        island.debugSetPresentation(.compact)
        let windowID = UInt32(truncatingIfNeeded: island.window.windowNumber)
        let directory = Self.captureDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            let start = DispatchTime.now()
            self.island.debugSetPresentation(.expanded)
            DispatchQueue.global(qos: .userInteractive).async {
                for ms in [0, 30, 60, 90, 120, 160, 210, 280, 400, 700] {
                    let target = start + .milliseconds(ms)
                    while DispatchTime.now() < target { usleep(500) }
                    WindowCapture.capture(windowID: windowID,
                                          to: directory.appending(path: String(format: "film-%03d.png", ms)))
                }
            }
        }
    }

    private func captureAll() {
        let directory = Self.captureDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for window in NSApp.windows where window.isVisible && window.alphaValue > 0 && window.windowNumber > 0 {
            let name = window.identifier?.rawValue ?? "window-\(window.windowNumber)"
            Log.media.notice("Capture candidate \(String(describing: type(of: window)), privacy: .public) #\(window.windowNumber) \(name, privacy: .public)")
            WindowCapture.capture(window, to: directory.appending(path: "\(name).png"))
        }
        Log.media.notice("Captured windows to \(directory.path, privacy: .public)")
    }
}

/// Captures one of this process's own windows as composited by the window server.
@MainActor
enum WindowCapture {
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    @discardableResult
    nonisolated static func capture(windowID: UInt32, to url: URL) -> Bool {
        guard windowID > 0,
              let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else { return false }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        guard let image = create(.null, 1 << 3, windowID, 1 << 0)?.takeRetainedValue(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return false }
        return (try? png.write(to: url)) != nil
    }

    @discardableResult
    static func capture(_ window: NSWindow, to url: URL) -> Bool {
        // Windows not yet known to the window server have no (positive) number.
        guard let windowID = UInt32(exactly: window.windowNumber), windowID > 0 else { return false }
        // CGWindowListCreateImage is hidden from Swift in the current SDK but still present;
        // capturing our own windows needs no screen-recording permission.
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else { return false }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        // kCGWindowListOptionIncludingWindow, kCGWindowImageBoundsIgnoreFraming
        guard let image = create(.null, 1 << 3, windowID, 1 << 0)?.takeRetainedValue(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return false }
        return (try? png.write(to: url)) != nil
    }
}

/// `Islet --perf-probe [compact|expanded|player|lyrics] [seconds]`: shows a real surface with
/// a simulated playing track in the screen's lower-left corner and prints the process's own
/// CPU use and layout passes per second (each redraw costs one), so energy regressions can
/// be measured without touching real playback.
@MainActor
enum PerfProbe {
    static func run(surface: String, seconds: Double) {
        let settings = AppSettings()
        let store = PlayerStore(settings: settings)
        store.loadPreview(
            NowPlayingSnapshot(title: "Probe", artist: "Islet", duration: 240, elapsed: 30, timestamp: Date(),
                               playbackRate: 1, isPlaying: true, bundleIdentifier: "probe"),
            artwork: nil, palette: .fallback,
            // A line every 4 s, like a typical song.
            lyrics: .synced(LRCParser.parse((0..<60).map { "[0\($0 * 4 / 60):\(String(format: "%02d", $0 * 4 % 60)).00]Line \($0)" }
                .joined(separator: "\n"), duration: 240)))
        let screen = NSScreen.screens[0]
        let window: NSWindow
        switch surface {
        case "player", "lyrics":
            let model = FullPlayerModel()
            model.isPresented = true
            model.isOpen = true
            model.showLyrics = surface == "lyrics"
            let size = CGSize(width: 900, height: 620)
            window = IslandPanel(size: size)
            window.contentView = FirstMouseHostingView(rootView: FullPlayerView(model: model, store: store)
                .frame(width: size.width, height: size.height))
        default:
            let metrics = IslandMetrics.make(for: screen, style: settings.islandStyle)
            let model = IslandModel(metrics: metrics)
            model.presentation = surface == "expanded" ? .expanded : .compact
            window = IslandPanel(size: metrics.windowSize)
            window.contentView = FirstMouseHostingView(rootView: IslandView(model: model, store: store, settings: settings))
        }
        window.setFrameOrigin(screen.frame.origin)
        window.orderFrontRegardless()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            let start = (cpu: cpuSeconds(), wall: Date(), layouts: HostingStats.layouts)
            try? await Task.sleep(for: .seconds(seconds))
            let used = cpuSeconds() - start.cpu, wall = Date().timeIntervalSince(start.wall)
            let layouts = Double(HostingStats.layouts - start.layouts)
            print(String(format: "%@: %.2f%% CPU, %.1f layouts/s over %.0f s",
                         surface, used / wall * 100, layouts / wall, wall))
            exit(0)
        }
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let time = { (t: timeval) in Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return time(usage.ru_utime) + time(usage.ru_stime)
    }
}


/// "island.frames": plays the island's main animations while timing every display refresh
/// on the main thread (where SwiftUI animates), and writes how many frames arrived late to
/// captures/frames.txt. A frame is late when it took over 1.5 refresh intervals.
@MainActor
final class FrameProbe: NSObject {
    private static var current: FrameProbe?
    private var stamps: [CFTimeInterval] = []
    private var link: CADisplayLink?
    private var marks: [(String, Int)] = []

    static func run(island: IslandController) {
        guard current == nil, let screen = NSScreen.screens.first else { return }
        let probe = FrameProbe()
        current = probe
        probe.link = screen.displayLink(target: probe, selector: #selector(tick(_:)))
        probe.link?.add(to: .main, forMode: .common)
        let steps: [(String, () -> Void)] = [
            ("expand", { island.debugSetPresentation(.expanded) }),
            ("collapse", { island.debugSetPresentation(.compact) }),
            ("volume", { island.showLevel(LevelHUD(kind: .volume, value: 0.62)) }),
            ("charging", { island.showCharging(BatteryState(level: 0.64, isCharging: true, isPluggedIn: true)) }),
            ("expand2", { island.debugSetPresentation(.expanded) }),
            ("collapse2", { island.debugSetPresentation(.compact) }),
        ]
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            for (name, step) in steps {
                probe.marks.append((name, probe.stamps.count))
                step()
                try? await Task.sleep(for: .milliseconds(1400))
            }
            probe.finish()
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        stamps.append(link.timestamp)
    }

    private func finish() {
        link?.invalidate()
        let expected = link.map { $0.targetTimestamp - $0.timestamp } ?? (1.0 / 60)
        var lines = [String(format: "refresh %.1f ms", expected * 1000)]
        let bounds = marks.map(\.1) + [stamps.count]
        for (index, (name, start)) in marks.enumerated() {
            // The first 700 ms after each step: the animation itself.
            let end = bounds[index + 1]
            let slice = Array(stamps[start..<end])
            let window = slice.prefix { $0 - (slice.first ?? 0) < 0.7 }
            let gaps = zip(window.dropFirst(), window).map { $0 - $1 }
            let late = gaps.filter { $0 > expected * 1.5 }
            let worst = (gaps.max() ?? 0) * 1000
            let missed = late.reduce(0) { $0 + Int(($1 / expected).rounded()) - 1 }
            lines.append(String(format: "%@: %d frames, %d late, ~%d missed, worst %.1f ms",
                                name, gaps.count, late.count, missed, worst))
        }
        let text = lines.joined(separator: "\n")
        Log.media.notice("Frames: \(text, privacy: .public)")
        try? text.write(to: DebugTools.captureDirectory.appending(path: "frames.txt"), atomically: true, encoding: .utf8)
        Self.current = nil
    }
}
