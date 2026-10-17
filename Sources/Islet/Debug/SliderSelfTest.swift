import AppKit
import IsletCore
import SwiftUI

/// `Islet --slider-selftest`: drives the real sliders with synthetic mouse events, first
/// as a bare component and then inside the real island, full player and lock widget.
/// Test windows are placed off-screen; the preview store never touches real playback.
@MainActor
enum SliderSelfTest {
    final class Results {
        var commits: [String: Double] = [:]
    }

    static func run() {
        Task { @MainActor in
            await componentCases()
            await pinnedRelease()
            await realViewCases()
            await buttonCases()
            exit(0)
        }
    }

    // MARK: - Bare component

    private static func componentCases() async {
        let results = Results()
        // ISLET_CAPTURE_DIR=<dir>: also photograph the slider at rest and mid-drag (glass lens).
        if let directory = ProcessInfo.processInfo.environment["ISLET_CAPTURE_DIR"] {
            await captureDrag(to: URL(fileURLWithPath: directory))
        }
        for (index, groove) in [false, true].enumerated() {
            let name = groove ? "component+groove" : "component"
            let slider = GlassSlider(value: 0.1, groove: groove) { results.commits[name] = $0 }
                .frame(width: 300).padding(40)
            let window = host(slider.frame(width: 400, height: 80), size: CGSize(width: 400, height: 80), index: index)
            try? await Task.sleep(for: .milliseconds(300))
            await drag(in: window, from: CGPoint(x: 110, y: 40), to: CGPoint(x: 290, y: 40))
            report(name, ok: results.commits[name].map { abs($0 - 0.8) < 0.05 } ?? false,
                   detail: results.commits[name].map { String(format: "commit %.2f", $0) } ?? "no commit")
            window.orderOut(nil)
        }
    }

    /// Dragging past the end pins the value, and AppKit sends no action on that release;
    /// the drag must still end (the island waits for it before closing).
    private static func pinnedRelease() async {
        var editing = false
        var commit: Double?
        let slider = GlassSlider(value: 0.2, onEditingChanged: { editing = $0 }) { commit = $0 }
            .frame(width: 300).padding(40)
        let window = host(slider.frame(width: 400, height: 80), size: CGSize(width: 400, height: 80), index: 9)
        try? await Task.sleep(for: .milliseconds(300))
        await drag(in: window, from: CGPoint(x: 110, y: 40), to: CGPoint(x: 395, y: 40))
        report("pinned release", ok: !editing && commit.map { $0 > 0.99 } == true,
               detail: "editing \(editing), commit \(commit.map { String(format: "%.2f", $0) } ?? "none")")
        window.orderOut(nil)
    }

    private static func captureDrag(to directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let backdrop = LinearGradient(colors: [Color(red: 0.55, green: 0.15, blue: 0.5), Color(red: 0.2, green: 0.3, blue: 0.7)],
                                      startPoint: .leading, endPoint: .trailing)
        let view = ZStack {
            backdrop
            VStack(spacing: 30) {
                GlassSlider(value: 0.35, groove: true, thumb: .always) { _ in }
                GlassSlider(value: 0.6, thumb: .always) { _ in }
                // Island-style: times inline, small slider.
                HStack(spacing: 9) {
                    Text("0:26").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                    GlassSlider(value: 0.2, restHeight: 5, activeHeight: 10, thumb: .always) { _ in }
                    Text("-3:00").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(width: 300)
        }
        let size = CGSize(width: 400, height: 200)
        let panel = IslandPanel(size: size)
        panel.ignoresMouseEvents = false
        let probe = SliderProbe()
        let host = FirstMouseHostingView(rootView: view.frame(width: size.width, height: size.height)
            .environment(\.sliderProbe, probe))
        host.sizingOptions = []
        panel.contentView = host
        panel.setFrameOrigin(CGPoint(x: 40, y: 40))
        panel.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(500))
        WindowCapture.capture(panel, to: directory.appending(path: "slider-rest.png"))
        // Press and drag the top slider fast, then photograph before releasing. Probe frames
        // are top-left window coordinates; events use bottom-left.
        guard let top = probe.frames.min(by: { $0.minY < $1.minY }) else { return }
        let y = size.height - top.midY
        func post(_ type: NSEvent.EventType, _ x: CGFloat) {
            if let event = NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y), modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                                              clickCount: 1, pressure: 1) {
                NSApp.postEvent(event, atStart: false)
            }
        }
        // GCD, not tasks: AppKit tracks the drag inside the press (see `drag`).
        let at = { (seconds: Double, work: @escaping @MainActor () -> Void) in
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated(work) }
        }
        at(0) { post(.leftMouseDown, 150) }
        for step in 1...6 { at(Double(step) * 0.016) { post(.leftMouseDragged, 150 + CGFloat(step) * 14) } }
        at(0.18) { WindowCapture.capture(panel, to: directory.appending(path: "slider-dragging.png")) }
        at(0.6) { WindowCapture.capture(panel, to: directory.appending(path: "slider-holding.png")) }
        at(0.62) { post(.leftMouseUp, 234) }
        try? await Task.sleep(for: .milliseconds(1_000))
        panel.orderOut(nil)
    }

    // MARK: - Real views

    private static func realViewCases() async {
        let settings = AppSettings()
        let store = PlayerStore(settings: settings)
        let reset = {
            store.loadPreview(
                NowPlayingSnapshot(title: "Test", artist: "Artist", duration: 200, elapsed: 10,
                                   timestamp: Date(), isPlaying: false, bundleIdentifier: "test"),
                artwork: nil, palette: .fallback, lyrics: .unavailable)
            store.setVolume(0.2)
        }

        // Island (expanded) in the real panel configuration.
        reset()
        let metrics = IslandMetrics.make(for: NSScreen.screens[0], style: settings.islandStyle)
        let islandModel = IslandModel(metrics: metrics)
        islandModel.presentation = .expanded
        await check("island scrubber", store: store, size: metrics.windowSize, index: 2,
                    view: IslandView(model: islandModel, store: store, settings: settings),
                    pick: 0, expect: { abs(store.elapsed(at: Date()) - 160) < 12 })

        // Full player: scrubber (upper slider) and volume (lower slider).
        reset()
        let playerModel = FullPlayerModel()
        playerModel.isPresented = true
        playerModel.isOpen = true
        await check("player scrubber", store: store, size: CGSize(width: 1440, height: 900), index: 3,
                    view: FullPlayerView(model: playerModel, store: store),
                    pick: 0, expect: { abs(store.elapsed(at: Date()) - 160) < 12 })
        reset()
        await check("player volume", store: store, size: CGSize(width: 1440, height: 900), index: 4,
                    view: FullPlayerView(model: playerModel, store: store),
                    pick: 1, expect: { abs(store.volume - 0.8) < 0.06 })

        // Lock widget.
        reset()
        let lockModel = LockModel()
        lockModel.isPresented = true
        await check("lock scrubber", store: store, size: LockLayout.playerSize, index: 5,
                    view: LockPlayerPlatter(store: store, model: lockModel),
                    pick: 0, expect: { abs(store.elapsed(at: Date()) - 160) < 12 })
    }

    private static func check(_ name: String, store: PlayerStore, size: CGSize, index: Int,
                              view: some View, pick: Int, expect: () -> Bool) async {
        let probe = SliderProbe()
        let window = host(view.environment(\.sliderProbe, probe), size: size, index: index)
        try? await Task.sleep(for: .milliseconds(500))
        let frames = probe.frames.sorted { $0.minY < $1.minY }
        guard pick < frames.count else {
            report(name, ok: false, detail: "slider not found (\(frames.count) registered)")
            window.orderOut(nil)
            return
        }
        let frame = frames[pick]
        // Probe frames are top-left window coordinates; events use bottom-left.
        let y = size.height - frame.midY
        await drag(in: window, from: CGPoint(x: frame.minX + frame.width * 0.2, y: y),
                   to: CGPoint(x: frame.minX + frame.width * 0.8, y: y))
        report(name, ok: expect(), detail: String(format: "elapsed %.1f s, volume %.2f",
                                                  store.elapsed(at: Date()), store.volume))
        window.orderOut(nil)
    }

    // MARK: - Transport buttons

    /// Clicks previous, play/pause and next in the island, full player and lock widget.
    private static func buttonCases() async {
        let settings = AppSettings()
        let store = PlayerStore(settings: settings)
        let metrics = IslandMetrics.make(for: NSScreen.screens.first, style: settings.islandStyle)
        let islandModel = IslandModel(metrics: metrics)
        islandModel.presentation = .expanded
        let playerModel = FullPlayerModel()
        playerModel.isPresented = true
        playerModel.isOpen = true
        let lockModel = LockModel()
        lockModel.isPresented = true
        let surfaces: [(String, CGSize, AnyView)] = [
            ("island", metrics.windowSize, AnyView(IslandView(model: islandModel, store: store, settings: settings))),
            ("player", CGSize(width: 1440, height: 900), AnyView(FullPlayerView(model: playerModel, store: store))),
            ("lock", LockLayout.playerSize, AnyView(LockPlayerPlatter(store: store, model: lockModel))),
        ]
        let expected: [(String, MediaCommand)] = [("previous", .previousTrack), ("playPause", .togglePlayPause),
                                                  ("next", .nextTrack)]
        for (index, (name, size, view)) in surfaces.enumerated() {
            store.loadPreview(
                NowPlayingSnapshot(title: "Test", artist: "Artist", duration: 200, elapsed: 10,
                                   timestamp: Date(), isPlaying: false, bundleIdentifier: "test"),
                artwork: nil, palette: .fallback, lyrics: .unavailable)
            let probe = SliderProbe()
            let window = host(view.environment(\.sliderProbe, probe), size: size, index: 6 + index)
            // Let the island's controls capsule spring fully out first.
            try? await Task.sleep(for: .milliseconds(900))
            for (button, command) in expected {
                let label = "\(name) \(button)"
                guard let frame = probe.buttons[button] else {
                    report(label, ok: false, detail: "button not found")
                    continue
                }
                store.lastCommand = nil
                let wasPlaying = store.isPlaying
                let point = CGPoint(x: frame.midX, y: size.height - frame.midY)
                // Real clicks into an inactive app reach a view only if it accepts the first mouse.
                let hit = window.contentView?.hitTest(point)
                let firstMouse = hit?.acceptsFirstMouse(for: nil) ?? false
                // Islet is never the active app: click as the island really is clicked.
                NSApp.deactivate()
                try? await Task.sleep(for: .milliseconds(150))
                await click(in: window, at: point)
                let flipped = command != .togglePlayPause || store.isPlaying != wasPlaying
                report(label, ok: store.lastCommand == command && flipped && firstMouse,
                       detail: "sent \(store.lastCommand.map { "\($0)" } ?? "nothing"), playing \(store.isPlaying), "
                           + "hit \(hit.map { String(describing: type(of: $0)).prefix(40) } ?? "none") first mouse \(firstMouse)")
            }
            window.orderOut(nil)
        }
    }

    // MARK: - Helpers

    private static func click(in window: NSWindow, at point: CGPoint) async {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
                NSApp.postEvent(event, atStart: false)
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
        try? await Task.sleep(for: .milliseconds(200))
    }

    private static func host(_ view: some View, size: CGSize, index: Int) -> NSWindow {
        let panel = IslandPanel(size: size)
        panel.ignoresMouseEvents = false
        let router = ClickRouter()
        let host = FirstMouseHostingView(rootView: view.frame(width: size.width, height: size.height)
            .environment(\.clickRouter, router))
        host.clickRouter = router
        host.sizingOptions = []
        panel.contentView = host
        // Far off-screen so the test never flashes on the user's display.
        panel.setFrameOrigin(CGPoint(x: -20_000 - CGFloat(index) * 2_000, y: -20_000))
        panel.orderFrontRegardless()
        return panel
    }

    /// Posts a press, eight moves and a release 30 ms apart. They go through GCD, which
    /// keeps running while AppKit tracks the drag inside the press (Swift tasks don't).
    private static func drag(in window: NSWindow, from start: CGPoint, to end: CGPoint) async {
        let number = window.windowNumber
        func post(_ type: NSEvent.EventType, _ point: CGPoint, after index: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.03) {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: number,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
                else { return }
                NSApp.postEvent(event, atStart: false)
            }
        }
        post(.leftMouseDown, start, after: 0)
        for step in 1...8 {
            let t = CGFloat(step) / 8
            post(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y), after: step)
        }
        post(.leftMouseUp, end, after: 9)
        try? await Task.sleep(for: .milliseconds(500))
    }

    private static func report(_ name: String, ok: Bool, detail: String) {
        print("\(ok ? "PASS" : "FAIL")  \(name.padding(toLength: 18, withPad: " ", startingAt: 0))  \(detail)")
    }
}
