import IsletCore
import AppKit
import SwiftUI

/// Borderless, non-activating panel that floats above the menu bar on every Space.
final class IslandPanel: NSPanel {
    init(size: CGSize) {
        super.init(contentRect: CGRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that accepts the first click, so controls work without activating the app.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Fires registered controls when SwiftUI won't (see `ClickRouter`).
    var clickRouter: ClickRouter?
    private var pressTarget: String?

    override func mouseDown(with event: NSEvent) {
        clickRouter?.pressBegan()
        pressTarget = clickRouter?.target(at: topLeft(event))
        clickRouter?.pressed = pressTarget
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if let id = pressTarget, clickRouter?.target(at: topLeft(event)) == id { clickRouter?.fire(id) }
        clickRouter?.pressed = nil
        pressTarget = nil
    }

    private func topLeft(_ event: NSEvent) -> CGPoint {
        let point = event.locationInWindow
        return CGPoint(x: point.x, y: (window?.contentView?.bounds.height ?? bounds.height) - point.y)
    }

    override func layout() {
        HostingStats.layouts += 1
        super.layout()
    }
}

/// Layout passes across all hosting views, reported by `--perf-probe` (a redraw costs one).
enum HostingStats {
    nonisolated(unsafe) static var layouts = 0
}

/// Owns the island panel: placement, hover-to-expand and click-through outside the island.
@MainActor
final class IslandController {
    let model: IslandModel
    var onOpenPlayer: ((CGRect?) -> Void)?

    let store: PlayerStore
    private let settings: AppSettings
    private let panel: IslandPanel
    private var monitors: [Any] = []
    private var pending: Task<Void, Never>?
    private var hoverCheck: Timer?
    private var router: ClickRouter?
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var isShown = false

    init(store: PlayerStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        let metrics = IslandMetrics.make(for: Self.menuBarScreen, style: settings.islandStyle)
        model = IslandModel(metrics: metrics)
        panel = IslandPanel(size: metrics.windowSize)
        panel.identifier = NSUserInterfaceItemIdentifier("island")
        let router = ClickRouter()
        let host = FirstMouseHostingView(rootView: IslandView(model: model, store: store, settings: settings)
            .allowsWindowActivationEvents(true)
            .environment(\.clickRouter, router))
        host.clickRouter = router
        self.router = router
        host.sizingOptions = []
        panel.contentView = host

        model.openPlayer = { [weak self] in self?.openPlayer() }
        model.onShelfDrop = { [weak self] in self?.fileDragActive = false }
        model.requestExpand = { [weak self] in self?.setPresentation(.expanded) }
        model.interactionEnded = { [weak self] in self?.mouseMoved() }
        // One Space at a time (not every Space at once), so a three-finger swipe carries the
        // island off with the old desktop; `followSpace` then brings it to the new one.
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.followSpace() }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
    }

    /// The screen with the menu bar; nil while macOS reports no displays at all (a laptop
    /// lid closing with nothing attached), until the screens come back.
    static var menuBarScreen: NSScreen? {
        NSScreen.screens.first
    }

    func show() {
        isShown = true
        reposition()
        panel.orderFrontRegardless()
        installMonitors()
        followPauses()
    }

    /// The swipe has finished on another desktop (or full-screen app): ordering the panel
    /// in again puts it on the active Space, where it drops in from the notch.
    private func followSpace() {
        guard isShown, !panel.isOnActiveSpace else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
        model.arrivals += 1
    }

    /// A song to show: the player's, unless a paused one has been dropped from the island.
    private var hasTrack: Bool { store.hasTrack && model.showsTrack }

    // MARK: - Hide the player when music pauses

    private var pauseHideTask: Task<Void, Never>?

    /// Drops a paused song from the island after the chosen delay, so it rests as if
    /// nothing were playing; anything playing again brings it straight back. Re-runs
    /// whenever what it read changes.
    private func followPauses() {
        let (paused, delay) = withObservationTracking {
            (store.hasTrack && !store.isPlaying, settings.hidePausedPlayer)
        } onChange: {
            Task { @MainActor [weak self] in self?.followPauses() }
        }
        guard paused, delay != .never else {
            pauseHideTask?.cancel()
            pauseHideTask = nil
            if !model.showsTrack { withAnimation(IslandMotion.open) { model.showsTrack = true } }
            return
        }
        // Already counting down (playback reports keep arriving while paused) or gone.
        guard model.showsTrack, pauseHideTask == nil else { return }
        pauseHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay.rawValue))
            // Never snatched away while it's open, under the pointer, or behind the full-screen
            // player (whose closing animation lands on the island's artwork).
            while let self, !Task.isCancelled,
                  self.model.presentation != .compact || self.model.isHovered || self.model.isSuppressed {
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self, !Task.isCancelled else { return }
            self.pauseHideTask = nil
            withAnimation(IslandMotion.close) { self.model.showsTrack = false }
        }
    }

    /// Screen rectangle of the island's artwork, for the full-player hero animation.
    /// Still valid while suppressed: the island keeps its (invisible) compact layout,
    /// which is exactly where the closing hero should land.
    func artScreenRect() -> CGRect? {
        let frame = model.artFrame
        guard frame.width > 1, hasTrack else { return nil }
        return CGRect(x: panel.frame.minX + frame.minX, y: panel.frame.maxY - frame.maxY,
                      width: frame.width, height: frame.height)
    }

    /// Debug hook used by DebugTools to drive the island without a mouse.
    func debugSetPresentation(_ presentation: IslandPresentation) {
        debugPinned = presentation == .expanded
        setPresentation(presentation)
    }

    /// Settings: keep the island open while its size and glass are adjusted.
    func previewExpanded(_ on: Bool) {
        debugPinned = on
        setPresentation(on ? .expanded : .compact)
    }

    /// Debug: the timer's "done" moment, and a swipe-up tuck.
    func debugShowTimerDone() { show(.timerDone, for: .seconds(5)) }
    func debugTuck() { tuck() }
    /// Debug: press a routed control by its id, as a real click would.
    func debugClick(_ id: String) { router?.fire(id) }
    var debugTargets: String { router?.dump ?? "" }

    /// Debug: open the shelf (optionally with some files on it).
    func debugShowShelf(adding urls: [URL]) {
        model.shelf.add(urls)
        debugPinned = true
        setPresentation(.shelf)
    }

    /// While pinned by a debug command, hover logic doesn't collapse the island.
    private var debugPinned = false

    var window: NSWindow { panel }

    /// Collapses and pauses hover handling while the full-screen player is visible.
    func setPlayerVisible(_ visible: Bool) {
        if visible { setPresentation(.compact) }
        model.isSuppressed = visible
    }

    // MARK: - Placement

    /// Recomputes geometry for the current screen and style.
    func reposition() {
        guard let screen = Self.menuBarScreen else { return }
        model.metrics = IslandMetrics.make(for: screen, style: settings.islandStyle)
        let size = model.metrics.windowSize
        panel.setFrame(CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
    }

    // MARK: - Hover and click-through

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated {
                self?.trackFileDrag(type)
                self?.mouseMoved()
            }
        }) {
            monitors.append(global)
        } else {
            Log.island.error("No global mouse monitor: the island can't notice the pointer")
        }
        // Local events: a press that starts on the island owns the pointer until release.
        let local: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel]
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: local, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch event.type {
                case .leftMouseDown where event.window === self.panel:
                    Log.island.debug("Press on island at \(event.locationInWindow.debugDescription, privacy: .public)")
                    self.pressOnIsland = true
                case .leftMouseUp:
                    self.pressOnIsland = false
                    self.fileDragActive = false
                    self.mouseMoved()
                case .scrollWheel where event.window === self.panel:
                    self.scrolled(event)
                default:
                    self.mouseMoved()
                }
            }
            return event
        }) { monitors.append(monitor) }
    }

    /// Safety net for missed exit events (e.g. the cursor jumping between displays). Runs
    /// only while the pointer is over the island or it is open, so an idle island never wakes.
    private func setHoverCheck(_ needed: Bool) {
        if needed, hoverCheck == nil {
            hoverCheck = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.mouseMoved() }
            }
            hoverCheck?.tolerance = 0.2
        } else if !needed, let timer = hoverCheck {
            timer.invalidate()
            hoverCheck = nil
        }
    }

    private func islandScreenRect() -> CGRect {
        let busy = hasTrack || model.timerEnd != nil
        let local = model.metrics.islandRect(for: model.presentation, hasTrack: busy, activity: model.activity)
        return CGRect(x: panel.frame.minX + local.minX, y: panel.frame.maxY - local.maxY,
                      width: local.width, height: local.height)
    }

    /// True from a mouse-down on the island until the button is released.
    private var pressOnIsland = false

    /// Changes click-through only when it really changes: re-setting it mid-drag makes the
    /// window server drop the drag in progress (the slider "doesn't work").
    private func setClickThrough(_ ignore: Bool) {
        guard panel.ignoresMouseEvents != ignore else { return }
        panel.ignoresMouseEvents = ignore
        Log.island.debug("Island \(ignore ? "lets clicks through" : "takes clicks", privacy: .public)")
    }

    // MARK: - File drags (the shelf)

    /// A drag carrying files is under way somewhere on screen.
    private var fileDragActive = false
    private var dragCountAtPress = NSPasteboard(name: .drag).changeCount

    /// Spots file drags: the drag pasteboard changes after the press, and it holds files.
    private func trackFileDrag(_ type: NSEvent.EventType) {
        let board = NSPasteboard(name: .drag)
        switch type {
        case .leftMouseDown:
            dragCountAtPress = board.changeCount
            fileDragActive = false
        case .leftMouseDragged where !fileDragActive:
            fileDragActive = board.changeCount != dragCountAtPress && board.types?.contains(.fileURL) == true
        case .leftMouseUp:
            fileDragActive = false
        default:
            break
        }
    }

    // MARK: - Swipe up to tuck away

    private var tuckedAt: TimeInterval = 0
    private var untuckTask: Task<Void, Never>?

    private var swipe = TwoFingerSwipe()

    /// Two fingers over the island (in the direction they move, whatever the scrolling
    /// setting): up tucks it away; left or right ("Swipe to skip") plays the next or previous song.
    private func scrolled(_ event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, !model.isTucked else { return }
        if event.phase == .began { swipe.begin() }
        let inverted = event.isDirectionInvertedFromDevice
        // Only the fingers themselves (not the coasting after), and not over the shelf or
        // Control Center, whose own contents may scroll sideways.
        let canSkip = event.momentumPhase.isEmpty && settings.swipeToSkip && hasTrack && !pressOnIsland
            && (model.presentation == .compact || model.presentation == .expanded)
        switch swipe.move(up: inverted ? -event.scrollingDeltaY : event.scrollingDeltaY,
                          right: inverted ? event.scrollingDeltaX : -event.scrollingDeltaX, canSkip: canSkip) {
        case .tuck?: tuck()
        case .next?: store.next(); Haptics.tap()
        case .previous?: store.previous(); Haptics.tap()
        case nil: break
        }
    }

    private func tuck() {
        cancelPending()
        model.presentation = .compact
        model.isTucked = true
        tuckedAt = ProcessInfo.processInfo.systemUptime
        setClickThrough(true)
        setHoverCheck(true)
    }

    /// It stays away while the pointer is still around it, and drops back a moment after
    /// the pointer leaves (at least two seconds after the swipe).
    private func checkTucked() {
        let near = islandScreenRect().insetBy(dx: -50, dy: -50).contains(NSEvent.mouseLocation)
        if near {
            untuckTask?.cancel()
            untuckTask = nil
            return
        }
        guard untuckTask == nil else { return }
        untuckTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let held = max(0, 2 - (ProcessInfo.processInfo.systemUptime - self.tuckedAt))
            try? await Task.sleep(for: .seconds(max(1.2, held)))
            guard !Task.isCancelled else { return }
            self.untuck()
        }
    }

    private func untuck() {
        untuckTask?.cancel()
        untuckTask = nil
        guard model.isTucked else { return }
        model.isTucked = false
        mouseMoved()
    }

    private func mouseMoved() {
        if model.isTucked {
            setClickThrough(true)
            checkTucked()
            return
        }
        guard !model.isSuppressed else {
            setClickThrough(true)
            setHoverCheck(false)
            return
        }
        // Files dragged toward the island open the shelf as a drop target.
        if fileDragActive, settings.shelfEnabled,
           islandScreenRect().insetBy(dx: -90, dy: -70).contains(NSEvent.mouseLocation) {
            cancelPending()
            setClickThrough(false)
            setHoverCheck(true)
            if model.presentation != .shelf { setPresentation(.shelf) }
            return
        }
        // While a press that began on the island is held (a slider drag), leave everything
        // alone: the window keeps the events and the island stays open.
        if pressOnIsland, NSEvent.pressedMouseButtons & 1 != 0 { return }
        pressOnIsland = false
        let hot = islandScreenRect().insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation)
        if model.isHovered != hot { model.isHovered = hot }
        setClickThrough(!hot)
        setHoverCheck(hot || model.presentation != .compact)
        if hot {
            if model.presentation == .compact, settings.expandOnHover, hasTrack {
                schedule(.expanded, after: .milliseconds(60))
            } else if model.presentation == .compact, settings.expandOnHover, settings.shelfEnabled,
                      !model.shelf.items.isEmpty {
                // Nothing playing: hovering opens the shelf if it holds files.
                schedule(.shelf, after: .milliseconds(60))
            } else if model.presentation == .compact, settings.expandOnHover, !hasTrack,
                      model.timerEnd == nil, model.activity == nil {
                // Nothing playing and nothing on the shelf: Control Center.
                schedule(.controls, after: .milliseconds(60))
            } else {
                cancelPending()
            }
        } else if model.presentation != .compact, !model.isInteracting, !debugPinned, !fileDragActive {
            schedule(.compact, after: .milliseconds(320))
        } else {
            cancelPending()
        }
    }

    private var pendingTarget: IslandPresentation?

    private func schedule(_ presentation: IslandPresentation, after delay: Duration) {
        guard pendingTarget != presentation else { return }
        cancelPending()
        pendingTarget = presentation
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.setPresentation(presentation)
        }
    }

    private func cancelPending() {
        pending?.cancel()
        pending = nil
        pendingTarget = nil
    }

    private func setPresentation(_ presentation: IslandPresentation) {
        cancelPending()
        guard model.presentation != presentation else { return }
        if presentation == .expanded, !hasTrack { return }
        // Opening (music or shelf) takes over from a transient activity.
        if presentation != .compact {
            clearActivity()
        }
        model.presentation = presentation
    }

    // MARK: - Activities (charging, unlock)

    private var activityTask: Task<Void, Never>?

    /// Something went through Portal.
    func showPortal(_ arrival: PortalArrival) {
        show(.portal(arrival), for: .seconds(4.5))
    }

    /// Shows the charging animation for a few seconds, like the iPhone when plugged in.
    func showCharging(_ battery: BatteryState) {
        show(.charging(battery), for: .seconds(settings.chargingAlertDuration))
    }

    /// Volume or brightness level, kept up while the keys are pressed.
    func showLevel(_ hud: LevelHUD) {
        if settings.levelPosition != .island {
            EdgeLevelHUD.shared.show(hud, on: settings.levelPosition)
            return
        }
        // The headphones card stays up for its few seconds.
        if case .headphones? = model.activity { return }
        if model.level != hud { model.level = hud }
        if case .level(hud.kind)? = model.activity {
            // Already showing: only the bar moves; just keep it up a little longer.
            keepActivity(for: .seconds(1.5))
        } else {
            show(.level(hud.kind), for: .seconds(1.5))
        }
    }

    /// A coding agent wants attention: longer for questions than for "finished".
    func showAgent(_ alert: AgentAlert) {
        show(.agent(alert), for: .seconds(alert.event.kind == .done ? 6 : 12))
    }

    /// The battery dropped to a warning level.
    func showLowBattery(_ percent: Int) {
        show(.lowBattery(percent), for: .seconds(4))
    }

    // MARK: - Timer

    private var timerTask: Task<Void, Never>?

    var timerRunning: Bool { model.timerEnd != nil }

    func startTimer(minutes: Int) {
        let end = Date().addingTimeInterval(TimeInterval(minutes * 60))
        model.timerEnd = end
        timerTask?.cancel()
        timerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(until: .now + .seconds(end.timeIntervalSinceNow), tolerance: .milliseconds(50))
            guard let self, !Task.isCancelled else { return }
            self.model.timerEnd = nil
            NSSound(named: "Glass")?.play()
            Haptics.tap()
            self.show(.timerDone, for: .seconds(5))
        }
    }

    func cancelTimer() {
        timerTask?.cancel()
        timerTask = nil
        model.timerEnd = nil
    }

    /// Hides the current activity (e.g. an agent card that was clicked).
    func dismissActivity() {
        clearActivity()
    }

    /// The headphones that just connected.
    func showHeadphones(_ card: HeadphoneCard) {
        show(.headphones(card), for: .seconds(4))
    }

    /// The Touch ID → open padlock moment, right after the Mac unlocks.
    func showUnlocked(face: Bool = false) {
        model.unlockedWithFace = face
        show(.unlocked, for: .seconds(2))
    }

    private func show(_ activity: IslandActivity, for duration: Duration) {
        guard !model.isSuppressed else { return }
        // News brings a tucked-away island back.
        untuck()
        if model.presentation == .expanded { model.presentation = .compact }
        model.activity = activity
        keepActivity(for: duration)
    }

    /// (Re)starts the countdown that clears the current activity.
    private func keepActivity(for duration: Duration) {
        activityTask?.cancel()
        activityTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.clearActivity()
        }
    }

    private func clearActivity() {
        // Not while the pill's slider is held.
        if model.isInteracting, case .level? = model.activity {
            keepActivity(for: .seconds(1))
            return
        }
        activityTask?.cancel()
        activityTask = nil
        if model.activity != nil { model.activity = nil }
    }

    private func openPlayer() {
        let rect = artScreenRect()
        onOpenPlayer?(rect)
    }
}
