import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class LockModel {
    /// The widgets are on screen; their content exists only then.
    var isPresented = false
    /// The album is open full screen (iOS-style), below the clock.
    var isAlbumOpen = false
    /// Height reserved at the top for the clock.
    var clockInset: CGFloat = 340
    var battery: BatteryState?
    var weather: WeatherService.Report?
    var headphones: HeadphoneStatus?
    var cpuLoad: Double?
    var widgetsWallpaper: WallpaperContext?
    var playerWallpaper: WallpaperContext?
    /// Artwork frames in their own windows (top-left coordinates), reported by the views.
    var playerArtFrame: CGRect = .zero
    var miniArtFrame: CGRect = .zero

    @ObservationIgnored var expandFromPlayer: () -> Void = {}
    @ObservationIgnored var expandFromMini: () -> Void = {}
    @ObservationIgnored var collapse: () -> Void = {}
}

/// Detects lock/unlock, plays the lock sounds, and shows Liquid Glass widgets and a player
/// on the lock screen through a private SkyLight space. Clicking the album opens it in a
/// large card below the clock, with lyrics.
@MainActor
final class LockScreenController {
    let sounds: LockSoundPlayer
    let model = LockModel()
    /// Called once the screen unlocks (the island plays its unlock animation).
    var onUnlock: (() -> Void)?
    /// True while the on-screen lyrics fill the lock screen, like the full-screen album: they
    /// bring their own backdrop and clock, so the widgets, player card and motion artwork step
    /// aside until the music stops.
    var lyricsFillLockScreen: () -> Bool = { false }
    private(set) var isLocked = false

    private let store: PlayerStore
    private let settings: AppSettings
    private var observers: [DistributedObserver] = []
    private var space: SkyLightSpace? { SkyLightSpace.shared }
    private var onLockScreen = false
    private var presentTask: Task<Void, Never>?
    private var batteryTimer: Timer?
    private var cpuTimer: Timer?
    private let cpu = CPULoadSampler()
    private var layout: LockLayout?
    /// Bumped on every present/dismiss, so a late fade-out can't hide a newer presentation.
    private var generation = 0

    private lazy var widgetsPanel = makePanel("lock.widgets", LockLayout.widgetsSize,
                                              LockWidgetsRow(store: store, model: model, settings: settings))
    private lazy var playerPanel = makePanel("lock.player", LockLayout.playerSize,
                                             LockPlayerPlatter(store: store, model: model))
    /// The island on the lock screen: a padlock that shakes after a wrong attempt.
    private lazy var islandModel = IslandModel(
        metrics: IslandMetrics.make(for: NSScreen.screens.first, style: settings.islandStyle))
    private lazy var islandPanel: NSPanel = {
        let panel = makePanel("lock.island", islandModel.metrics.windowSize,
                              IslandView(model: islandModel, store: store, settings: settings))
        panel.ignoresMouseEvents = true
        return panel
    }()
    /// Motion artwork behind everything else, filling the screen.
    private lazy var motionPanel: NSPanel = {
        let panel = makePanel("lock.motion", CGSize(width: 1200, height: 800),
                              LockMotionBackground(store: store, model: model, settings: settings))
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: panel.level.rawValue - 1)
        return panel
    }()
    private var failTask: Task<Void, Never>?
    private let failureWatcher = AuthFailureWatcher()
    /// Full-screen album + lyrics, the same player as on the desktop.
    let albumModel = FullPlayerModel()
    private lazy var albumPanel = makePanel("lock.album", CGSize(width: 1200, height: 800),
                                            LockAlbumView(store: store, lock: model, player: albumModel))

    init(store: PlayerStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        sounds = LockSoundPlayer(settings: settings)
        observers = [
            DistributedObserver("com.apple.screenIsLocked") { [weak self] _ in self?.didLock() },
            DistributedObserver("com.apple.screenIsUnlocked") { [weak self] _ in self?.didUnlock() },
        ]
        isLocked = Self.screenIsLockedNow()
        Log.lock.info("Lock-screen space available: \(self.space != nil)")

        model.expandFromPlayer = { [weak self] in
            guard let self else { return }
            self.expand(from: self.playerPanel, localFrame: self.model.playerArtFrame)
        }
        model.expandFromMini = { [weak self] in
            guard let self else { return }
            self.expand(from: self.widgetsPanel, localFrame: self.model.miniArtFrame)
        }
        model.collapse = { [weak self] in self?.collapse() }
        failureWatcher.onFailure = { [weak self] in self?.authenticationFailed() }
        albumModel.close = { [weak self] in self?.collapse() }
    }

    /// Whether the private lock-screen space could be created on this macOS version.
    var lockScreenWidgetSupported: Bool { space != nil }

    static func screenIsLockedNow() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    // MARK: - Lock / unlock

    private func didLock() {
        guard !isLocked else { return }
        isLocked = true
        Log.lock.info("Screen locked")
        sounds.play(.lock)
        guard settings.lockWidgetEnabled else { return }
        guard space != nil else {
            Log.lock.error("Lock-screen space unavailable on this macOS version")
            return
        }
        failureWatcher.start()
        // Show at once, laid out around the clock (its size is known from LoginUIKit), then
        // settle around loginwindow's own panels once they're up.
        present(onLockScreen: true)
        presentTask?.cancel()
        presentTask = Task { @MainActor [weak self] in
            for delay in [350, 900] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard let self, !Task.isCancelled, self.isLocked else { return }
                self.relayout()
            }
        }
    }

    /// Moves the pieces if loginwindow's clock or login panel turned out elsewhere.
    private func relayout() {
        guard model.isPresented, !model.isAlbumOpen, let screen = NSScreen.screens.first else { return }
        let next = makeLayout(screen: screen, onLockScreen: onLockScreen)
        guard next.widgets != layout?.widgets || next.player != layout?.player else { return }
        layout = next
        model.clockInset = next.clockInset
        for (panel, frame) in [(widgetsPanel, next.widgets), (playerPanel, next.player)] where panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(frame, display: true)
            }
        }
        model.widgetsWallpaper = Wallpaper.context(for: screen, windowFrame: next.widgets)
        model.playerWallpaper = Wallpaper.context(for: screen, windowFrame: next.player)
    }

    private func makeLayout(screen: NSScreen, onLockScreen: Bool) -> LockLayout {
        LockLayout(screen: screen, loginWindows: onLockScreen ? LockLayout.loginWindowFrames() : [],
                   clockBottom: SystemClock.isAvailable ? SystemClock.clockBottom(screenHeight: screen.frame.height) : nil)
    }

    /// Builds the windows (and measures the clock) ahead of the first lock, so it shows at once.
    func prepare() {
        guard settings.lockWidgetEnabled, space != nil else { return }
        _ = (widgetsPanel, playerPanel, islandPanel, motionPanel)
        if let screen = NSScreen.screens.first, SystemClock.isAvailable {
            _ = SystemClock.clockBottom(screenHeight: screen.frame.height)
        }
    }

    private func didUnlock() {
        guard isLocked else { return }
        isLocked = false
        Log.lock.info("Screen unlocked")
        failureWatcher.stop()
        presentTask?.cancel()
        sounds.play(.unlock)
        dismiss(instantly: true)
        onUnlock?()
    }

    /// Stops background work before the app quits.
    func shutdown() {
        failureWatcher.stop()
    }

    /// A wrong fingerprint or password: the lock-screen island shakes with a red
    /// fingerprint, then settles back to the padlock.
    func authenticationFailed() {
        guard islandPanel.isVisible else { return }
        islandModel.activity = .lockFailed
        islandModel.shakes += 1
        failTask?.cancel()
        failTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, !Task.isCancelled, self.islandModel.activity == .lockFailed else { return }
            self.islandModel.activity = .locked
        }
    }

    // MARK: - Preview (debug: the same layout on the desktop)

    func showPreview() { present(onLockScreen: false) }
    func hidePreview() { dismiss() }

    /// The on-screen lyrics took over the lock screen (`filling`), or gave it back: hides or
    /// brings back the widgets, player card and motion artwork they stand in for.
    func lyricsFillChanged(_ filling: Bool) {
        guard model.isPresented, onLockScreen, !model.isAlbumOpen, let layout,
              let screen = NSScreen.screens.first else { return }
        if filling {
            for panel in [widgetsPanel, playerPanel, motionPanel] where panel.isVisible { panel.orderOut(nil) }
        } else {
            if settings.lockMotionBackground, !motionPanel.isVisible { show(motionPanel, at: screen.frame) }
            if !widgetsPanel.isVisible { show(widgetsPanel, at: layout.widgets) }
            if store.hasTrack, !playerPanel.isVisible { show(playerPanel, at: layout.player) }
        }
    }

    // MARK: - Presentation

    private func present(onLockScreen: Bool) {
        guard let screen = NSScreen.screens.first else { return }
        self.onLockScreen = onLockScreen
        let layout = makeLayout(screen: screen, onLockScreen: onLockScreen)
        self.layout = layout
        generation += 1
        model.battery = Battery.current()
        model.headphones = settings.lockHeadphones ? HeadphoneStatus.current() : nil
        model.weather = settings.lockWeather ? WeatherService.shared.report : nil
        if settings.lockWeather {
            Task { @MainActor [weak self] in
                let report = await WeatherService.shared.current()
                guard let self, self.model.isPresented, self.settings.lockWeather else { return }
                withAnimation(IslandMotion.subtle) { self.model.weather = report }
            }
        }
        model.clockInset = layout.clockInset
        model.isPresented = true
        model.isAlbumOpen = false
        albumModel.isOpen = false
        albumModel.isPresented = false
        albumModel.showLyrics = false
        albumPanel.orderOut(nil)

        // First, so it sits under the widgets in the lock screen's space too.
        let lyrics = lyricsFillLockScreen()
        if settings.lockMotionBackground, !lyrics {
            show(motionPanel, at: screen.frame)
        }

        // The island stays where it is on the desktop, now locked.
        islandModel.metrics = IslandMetrics.make(for: screen, style: settings.islandStyle)
        islandModel.activity = .locked
        let islandSize = islandModel.metrics.windowSize
        show(islandPanel, at: CGRect(x: screen.frame.midX - islandSize.width / 2, y: screen.frame.maxY - islandSize.height,
                                     width: islandSize.width, height: islandSize.height))
        islandModel.wallpaper = Wallpaper.context(for: screen, windowFrame: islandPanel.frame)
        if lyrics {
            widgetsPanel.orderOut(nil)
        } else {
            show(widgetsPanel, at: layout.widgets)
        }
        model.widgetsWallpaper = Wallpaper.context(for: screen, windowFrame: widgetsPanel.frame)
        if store.hasTrack, !lyrics {
            show(playerPanel, at: layout.player)
            model.playerWallpaper = Wallpaper.context(for: screen, windowFrame: playerPanel.frame)
        } else {
            playerPanel.orderOut(nil)
        }

        batteryTimer?.invalidate()
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.battery = Battery.current()
                if self.settings.lockHeadphones { self.model.headphones = HeadphoneStatus.current() }
            }
        }
        startCPU()
    }

    /// Samples CPU load every few seconds, only while the CPU widget is on screen.
    private func startCPU() {
        cpuTimer?.invalidate()
        cpuTimer = nil
        guard settings.lockWidgets.contains(.cpu) else { model.cpuLoad = nil; return }
        _ = cpu.sample()
        // A first reading soon after, rather than an empty ring for a whole interval.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, self.cpuTimer != nil, let load = self.cpu.sample() else { return }
            self.model.cpuLoad = load
        }
        cpuTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let load = self.cpu.sample() else { return }
                self.model.cpuLoad = load
            }
        }
    }

    private func show(_ panel: NSPanel, at frame: CGRect) {
        panel.setFrame(frame, display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        if onLockScreen { space?.attach(panel) }
        fade(panel, to: 1, duration: 0.2)
    }

    /// `instantly` on a real unlock: the panels sit in a level-400 space above the desktop,
    /// so even a 0.25 s fade showed them over it after loginwindow's shield had gone.
    private func dismiss(instantly: Bool = false) {
        batteryTimer?.invalidate()
        batteryTimer = nil
        cpuTimer?.invalidate()
        cpuTimer = nil
        generation += 1
        let dismissal = generation
        model.isAlbumOpen = false
        albumModel.isOpen = false
        for panel in [widgetsPanel, playerPanel, albumPanel, islandPanel, motionPanel] where panel.isVisible {
            if instantly { panel.orderOut(nil) } else { fade(panel, to: 0, duration: 0.25) { panel.orderOut(nil) } }
        }
        // Once faded, drop the content so nothing keeps running behind the desktop.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            guard let self, self.generation == dismissal else { return }
            self.model.isPresented = false
            self.albumModel.isPresented = false
            // Wallpaper pieces are cut again at the next lock; until then they're dead weight.
            self.model.widgetsWallpaper = nil
            self.model.playerWallpaper = nil
            self.islandModel.wallpaper = nil
            Wallpaper.releaseCrops()
            // The lock screen's views are gone, but their freed pages stay dirty (and counted
            // against Islet) until the allocator is asked to hand them back.
            try? await Task.sleep(for: .seconds(1))
            guard self.generation == dismissal else { return }
            malloc_zone_pressure_relief(nil, 0)
        }
    }

    private func fade(_ panel: NSPanel, to alpha: CGFloat, duration: TimeInterval, then done: (@MainActor () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = alpha
        } completionHandler: {
            MainActor.assumeIsolated { done?() }
        }
    }

    // MARK: - Open album (full screen, below the clock)

    private func expand(from source: NSWindow, localFrame: CGRect) {
        guard !model.isAlbumOpen, store.hasTrack, source.isVisible, localFrame.width > 1,
              let screen = NSScreen.screens.first else { return }
        // Source artwork in screen coordinates, then in the full-screen window's top-left space.
        let art = CGRect(x: source.frame.minX + localFrame.minX, y: source.frame.maxY - localFrame.maxY,
                         width: localFrame.width, height: localFrame.height)
        albumModel.origin = CGRect(x: art.minX - screen.frame.minX, y: screen.frame.maxY - art.maxY,
                                   width: art.width, height: art.height)
        albumModel.originCornerRadius = 12
        albumModel.showLyrics = false
        albumModel.isOpen = false
        albumModel.isPresented = true
        model.isAlbumOpen = true

        albumPanel.setFrame(screen.frame, display: true)
        albumPanel.alphaValue = 1
        albumPanel.orderFrontRegardless()
        if onLockScreen { space?.attach(albumPanel) }
        for panel in [widgetsPanel, playerPanel] where panel.isVisible {
            fade(panel, to: 0, duration: 0.25)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(24))
            withAnimation(IslandMotion.panel) { self.albumModel.isOpen = true }
        }
    }

    private func collapse() {
        guard model.isAlbumOpen, albumModel.isOpen else { return }
        for panel in [widgetsPanel, playerPanel] where panel.isVisible {
            fade(panel, to: 1, duration: 0.4)
        }
        withAnimation(IslandMotion.panel) {
            albumModel.isOpen = false
        } completion: { [weak self] in
            guard let self, !self.albumModel.isOpen else { return }
            self.albumPanel.orderOut(nil)
            self.albumModel.isPresented = false
            self.albumModel.showLyrics = false
            self.model.isAlbumOpen = false
        }
    }

    // MARK: - Windows

    private func makePanel(_ identifier: String, _ size: CGSize, _ root: some View) -> NSPanel {
        let panel = IslandPanel(size: size)
        panel.identifier = NSUserInterfaceItemIdentifier(identifier)
        panel.ignoresMouseEvents = false
        let router = ClickRouter()
        let host = FirstMouseHostingView(rootView: root.allowsWindowActivationEvents(true)
            .environment(\.clickRouter, router))
        host.clickRouter = router
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }

    // MARK: - Face ID

    private lazy var faceHUD = FaceHUDState()
    private lazy var faceHUDPanel: NSPanel = {
        let panel = makePanel("lock.faceid", CGSize(width: 190, height: 190), FaceIDHUDView(state: faceHUD))
        panel.ignoresMouseEvents = true
        return panel
    }()
    private var clickMonitor: Any?
    /// Clicking the lock-screen island (the notch) asks Face ID to look.
    var onIslandClick: (() -> Void)?
    var islandClickable = false {
        didSet {
            islandPanel.ignoresMouseEvents = !islandClickable
            if islandClickable, clickMonitor == nil {
                clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                    MainActor.assumeIsolated {
                        if let self, event.window === self.islandPanel { self.onIslandClick?() }
                    }
                    return event
                }
            }
        }
    }

    /// Face ID looking for you: in the island (pill) or as a square in the middle.
    func showFaceScan(_ phase: FaceScanPhase, square: Bool) {
        guard let screen = NSScreen.screens.first else { return }
        if square {
            if !faceHUDPanel.isVisible {
                let size = faceHUDPanel.frame.size
                show(faceHUDPanel, at: CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY + 40,
                                              width: size.width, height: size.height))
            }
            withAnimation(IslandMotion.subtle) { faceHUD.phase = phase }
        } else {
            if !islandPanel.isVisible {
                // Lock-screen widgets off: the island comes up just for Face ID.
                onLockScreen = isLocked
                islandModel.metrics = IslandMetrics.make(for: screen, style: settings.islandStyle)
                let size = islandModel.metrics.windowSize
                show(islandPanel, at: CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                                             width: size.width, height: size.height))
                islandModel.wallpaper = Wallpaper.context(for: screen, windowFrame: islandPanel.frame)
            }
            islandModel.activity = .faceScan(phase)
        }
        if phase == .needsPassword {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2.5))
                self?.hideFaceScan()
            }
        }
    }

    /// Face ID's light check: fills the screen with one colour (nil clears it). Below the
    /// island, so the Face ID pill stays in view; on the lock screen when locked.
    func flash(_ color: NSColor?) {
        guard let color else { return flashPanel.orderOut(nil) }
        flashPanel.backgroundColor = color
        guard !flashPanel.isVisible, let screen = NSScreen.screens.first else { return }
        flashPanel.setFrame(screen.frame, display: true)
        flashPanel.alphaValue = 1
        flashPanel.orderFrontRegardless()
        if isLocked { space?.attach(flashPanel) }
    }

    private lazy var flashPanel: NSPanel = {
        let panel = IslandPanel(size: .zero)
        panel.identifier = NSUserInterfaceItemIdentifier("lock.flash")
        panel.level = NSWindow.Level(rawValue: panel.level.rawValue - 1)
        panel.contentView = NSView()
        return panel
    }()

    /// Hidden windows swap their content only after fading, with no transition: a transition
    /// started in a window that's no longer drawn never finishes, and the scanning ring of
    /// dots inside it would keep animating unseen (about 15% CPU, for good).
    func hideFaceScan() {
        if faceHUDPanel.isVisible {
            fade(faceHUDPanel, to: 0, duration: 0.25) { [weak self] in
                guard let self else { return }
                self.faceHUDPanel.orderOut(nil)
                Self.withoutAnimation { self.faceHUD.phase = .matched }
            }
        }
        guard case .faceScan? = islandModel.activity else { return }
        guard !model.isPresented else { return islandModel.activity = .locked }
        fade(islandPanel, to: 0, duration: 0.25) { [weak self] in
            guard let self, case .faceScan? = self.islandModel.activity else { return }
            self.islandPanel.orderOut(nil)
            Self.withoutAnimation { self.islandModel.activity = .locked }
        }
    }

    private static func withoutAnimation(_ change: () -> Void) {
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet, change)
    }

    // MARK: - Debug

    func debugExpand() { model.expandFromPlayer() }
    func debugToggleLyrics() {
        withAnimation(IslandMotion.panel) { albumModel.showLyrics.toggle() }
    }
}
