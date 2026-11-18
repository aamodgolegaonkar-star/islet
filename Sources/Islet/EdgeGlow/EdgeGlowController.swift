import AppKit
import IsletCore
import QuartzCore
import SwiftUI

/// The screen-edge glow (Settings → Music & Lyrics → Edge Glow), after Lumn's rim lighting:
/// a transparent window over the main display (or every display) that ignores the mouse and
/// shows `EdgeGlowView` while music plays. It fades in when a song starts and out shortly
/// after it pauses. In between it breathes slowly, or, with "Pulse to the beat", flares on
/// each beat the audio tap hears in the bass.
@MainActor
final class EdgeGlowController {
    private let store: PlayerStore
    private let settings: AppSettings
    private var locked = LockScreenController.screenIsLockedNow()
    private var lockSignal: LockSignal?
    private var screenObserver: NSObjectProtocol?
    /// One window per display it shows on, keyed by display number.
    private var panels: [CGDirectDisplayID: NSPanel] = [:]
    private var hideTask: Task<Void, Never>?
    /// Wanted on screen (it may still be fading in or out).
    private var showing = false
    private var beats = BeatDetector()
    /// Registered as a viewer of the audio levels (so the tap runs for the beat).
    private var listening = false

    init(store: PlayerStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    func start() {
        lockSignal = LockSignal { [weak self] locked in self?.setLocked(locked) }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncPanels() }
        }
        WaveformLevels.shared.onFrame = { [weak self] levels in self?.heard(levels) }
        observe()
        update()
    }

    func stop() {
        hideTask?.cancel()
        listen(false)
        for panel in panels.values { panel.orderOut(nil) }
    }

    /// Debug: act as if the screen locked or unlocked.
    func debugSetLocked(_ isLocked: Bool) { setLocked(isLocked) }

    private func setLocked(_ isLocked: Bool) {
        locked = isLocked
        update()
    }

    /// Re-runs `update` whenever something it depends on changes.
    private func observe() {
        withObservationTracking {
            _ = wanted
            _ = (LiveTuning.shared.batterySaving, settings.edgeGlowBeat, settings.edgeGlowAllDisplays)
            _ = WaveformLevels.shared.isLive
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
    }

    /// The lock screen has its own look, so the glow is for the desktop only.
    private var wanted: Bool {
        settings.edgeGlow && store.hasTrack && store.isPlaying && !locked
    }

    private func update() {
        Log.media.debug("Edge glow: wanted \(self.wanted) (locked \(self.locked)), showing \(self.showing)")
        if wanted {
            hideTask?.cancel()
            hideTask = nil
            syncPanels()
            if !showing {
                showing = true
                for panel in panels.values {
                    if !panel.isVisible { panel.alphaValue = 0 }
                    panel.orderFrontRegardless()
                    fade(panel, to: 1, duration: 0.8)
                }
            }
            listen(settings.edgeGlowBeat)
            // Breathing is the motion when there's no beat to follow.
            breathe(!LiveTuning.shared.batterySaving && !(settings.edgeGlowBeat && WaveformLevels.shared.isLive))
        } else if showing, hideTask == nil {
            // A pause between songs shouldn't blink the glow off and on.
            hideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.2))
                guard let self, !Task.isCancelled else { return }
                self.hideTask = nil
                self.showing = false
                self.listen(false)
                self.breathe(false)
                for panel in self.panels.values {
                    self.fade(panel, to: 0, duration: 0.8) { [weak self] in
                        // Unless it was asked back while fading.
                        guard let self, !self.showing else { return }
                        panel.orderOut(nil)
                    }
                }
            }
        }
    }

    // MARK: - Beat

    private func listen(_ on: Bool) {
        guard on != listening else { return }
        listening = on
        beats.reset()
        if on { WaveformLevels.shared.appeared() } else { WaveformLevels.shared.disappeared() }
    }

    private func heard(_ levels: [Float]) {
        guard listening, showing, beats.feed(levels, at: ProcessInfo.processInfo.systemUptime) else { return }
        for panel in panels.values { flare(panel) }
    }

    /// A quick brightening on the beat that falls away, added on top of whatever else the
    /// glow's layer is doing (run by Core Animation on the window server).
    private func flare(_ panel: NSPanel) {
        guard let layer = panel.contentView?.layer else { return }
        let flare = CAKeyframeAnimation(keyPath: "opacity")
        flare.values = [0, 0.45, 0]
        flare.keyTimes = [0, 0.12, 1]
        flare.duration = 0.45
        flare.isAdditive = true
        flare.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
        layer.add(flare, forKey: "beat")
    }

    /// A slow rise and fall of the whole glow, run by Core Animation on the window server.
    private func breathe(_ on: Bool) {
        for panel in panels.values {
            guard let layer = panel.contentView?.layer else { continue }
            if on {
                guard layer.animation(forKey: "breathe") == nil else { continue }
                let animation = CABasicAnimation(keyPath: "opacity")
                animation.fromValue = 1
                animation.toValue = 0.62
                animation.duration = 3.2
                animation.autoreverses = true
                animation.repeatCount = .infinity
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(animation, forKey: "breathe")
            } else {
                layer.removeAnimation(forKey: "breathe")
            }
        }
    }

    // MARK: - Windows

    /// One window per wanted display, each covering its screen; windows for displays that
    /// left (or aren't wanted any more) go away.
    private func syncPanels() {
        let screens = settings.edgeGlowAllDisplays ? NSScreen.screens : Array(NSScreen.screens.prefix(1))
        var wantedIDs: Set<CGDirectDisplayID> = []
        for screen in screens {
            guard let id = Self.displayID(screen) else { continue }
            wantedIDs.insert(id)
            let panel = panels[id] ?? makePanel(for: screen, main: screen == NSScreen.screens.first)
            panels[id] = panel
            if panel.frame != screen.frame { panel.setFrame(screen.frame, display: true) }
            if showing, !panel.isVisible {
                panel.alphaValue = 1
                panel.orderFrontRegardless()
            }
        }
        for (id, panel) in panels where !wantedIDs.contains(id) {
            panel.orderOut(nil)
            panels[id] = nil
        }
    }

    private static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func makePanel(for screen: NSScreen, main: Bool) -> NSPanel {
        let panel = IslandPanel(size: screen.frame.size)
        let id = Self.displayID(screen).map(String.init) ?? "?"
        panel.identifier = NSUserInterfaceItemIdentifier(main ? "edgeGlow" : "edgeGlow.\(id)")
        // Over other apps, under the on-screen lyrics and the island.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView: EdgeGlowView(store: store, settings: settings,
                                                        notch: IslandMetrics.hardwareNotch(of: screen)))
        host.sizingOptions = []
        host.wantsLayer = true
        panel.contentView = host
        return panel
    }

    private func fade(_ panel: NSPanel, to alpha: CGFloat, duration: TimeInterval, then done: (@MainActor () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = alpha
        } completionHandler: {
            MainActor.assumeIsolated { done?() }
        }
    }
}
