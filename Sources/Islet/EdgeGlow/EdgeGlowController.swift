import AppKit
import QuartzCore
import SwiftUI

/// The screen-edge glow (Settings → Music & Lyrics → Edge Glow): a transparent window over
/// the main display that ignores the mouse and shows `EdgeGlowView` while music plays. It
/// fades in when a song starts, out shortly after it pauses, and breathes slowly in between.
@MainActor
final class EdgeGlowController {
    private let store: PlayerStore
    private let settings: AppSettings
    private var locked = LockScreenController.screenIsLockedNow()
    private var observers: [DistributedObserver] = []
    private var screenObserver: NSObjectProtocol?
    private lazy var panel = makePanel()
    private var hideTask: Task<Void, Never>?
    /// Wanted on screen (it may still be fading in or out).
    private var showing = false

    init(store: PlayerStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    func start() {
        observers = [
            DistributedObserver("com.apple.screenIsLocked") { [weak self] _ in self?.setLocked(true) },
            DistributedObserver("com.apple.screenIsUnlocked") { [weak self] _ in self?.setLocked(false) },
        ]
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitToScreen() }
        }
        observe()
        update()
    }

    func stop() {
        hideTask?.cancel()
        panel.orderOut(nil)
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
            _ = LiveTuning.shared.batterySaving
        } onChange: {
            Task { @MainActor [weak self] in
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
            if !showing {
                showing = true
                fitToScreen()
                if !panel.isVisible { panel.alphaValue = 0 }
                panel.orderFrontRegardless()
                fade(to: 1, duration: 0.8)
            }
            breathe(!LiveTuning.shared.batterySaving)
        } else if showing, hideTask == nil {
            // A pause between songs shouldn't blink the glow off and on.
            hideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.2))
                guard let self, !Task.isCancelled else { return }
                self.hideTask = nil
                self.showing = false
                self.breathe(false)
                self.fade(to: 0, duration: 0.8) { [weak self] in
                    // Unless it was asked back while fading.
                    guard let self, !self.showing else { return }
                    self.panel.orderOut(nil)
                }
            }
        }
    }

    private func fitToScreen() {
        guard let screen = NSScreen.screens.first else { return }
        panel.setFrame(screen.frame, display: true)
    }

    /// A slow rise and fall of the whole glow, run by Core Animation on the window server.
    private func breathe(_ on: Bool) {
        guard let layer = panel.contentView?.layer else { return }
        if on {
            guard layer.animation(forKey: "breathe") == nil else { return }
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

    // MARK: - Window

    private func makePanel() -> NSPanel {
        let panel = IslandPanel(size: NSScreen.screens.first?.frame.size ?? CGSize(width: 1440, height: 900))
        panel.identifier = NSUserInterfaceItemIdentifier("edgeGlow")
        // Over other apps, under the on-screen lyrics and the island.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView: EdgeGlowView(store: store, settings: settings))
        host.sizingOptions = []
        host.wantsLayer = true
        panel.contentView = host
        return panel
    }

    private func fade(to alpha: CGFloat, duration: TimeInterval, then done: (@MainActor () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = alpha
        } completionHandler: {
            MainActor.assumeIsolated { done?() }
        }
    }
}
