import AppKit
import IOKit.pwr_mgt
import IsletCore
import SwiftUI

/// Big word-by-word lyrics on the screen itself (Settings → Music & Lyrics → On Screen),
/// after Verci. A transparent window covers the main display, ignores the mouse, and shows
/// `ScreenLyricsView` while music with synced lyrics plays.
///
/// On the lock screen a second window joins the lock-screen widgets' SkyLight space, just
/// under them: it fills the screen with the album backdrop (motion artwork, or the blurred,
/// drifting cover) and the clock, with the lyrics where the player card would be. On the
/// desktop it floats over other windows (below the island) and steps aside while the
/// full-screen player is open.
@MainActor
final class ScreenLyricsController {
    private let store: PlayerStore
    private let settings: AppSettings
    private let model = ScreenLyricsModel()
    private var locked = LockScreenController.screenIsLockedNow()
    private var playerVisible = false
    private var observers: [DistributedObserver] = []
    private var space: SkyLightSpace? { SkyLightSpace.shared }
    private lazy var desktopPanel = makePanel("screenLyrics.desktop")
    private lazy var lockPanel: NSPanel = {
        let panel = makePanel("screenLyrics.lock")
        panel.canBecomeVisibleWithoutLogin = true
        return panel
    }()
    private var hideTask: Task<Void, Never>?
    /// Closed with its button: the lyrics stay off the lock screen until the next lock.
    private var dismissedOnLock = false
    /// The close button, in its own small window so the full-screen lyrics can keep ignoring
    /// the mouse (and never get between a click and the password field).
    private lazy var closePanel: NSPanel = {
        let panel = IslandPanel(size: CGSize(width: 44, height: 44))
        panel.identifier = NSUserInterfaceItemIdentifier("screenLyrics.close")
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.canBecomeVisibleWithoutLogin = true
        panel.ignoresMouseEvents = false
        let router = ClickRouter()
        let host = FirstMouseHostingView(rootView: LockLyricsCloseButton { [weak self] in self?.dismissOnLock() }
            .environment(\.clickRouter, router))
        host.clickRouter = router
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }()
    private var awakeAssertion = IOPMAssertionID(0)
    private var holdingAwake = false
    private var lyrics: LyricsState = .idle
    private var screenObserver: NSObjectProtocol?
    /// Told when the lyrics take over the lock screen or give it back.
    var onLockScreenFillChange: ((Bool) -> Void)?
    /// The lock-screen window is up (not hidden or fading away).
    private var fillingLockScreen = false {
        // Only while locked: on unlock the lock screen is going away anyway, and bringing its
        // player card back for a moment would flash.
        didSet { if fillingLockScreen != oldValue, locked { onLockScreenFillChange?(fillingLockScreen) } }
    }

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
            MainActor.assumeIsolated { self?.update() }
        }
        observe()
        update()
    }

    func stop() {
        hideTask?.cancel()
        closePanel.orderOut(nil)
        desktopPanel.orderOut(nil)
        lockPanel.orderOut(nil)
        keepAwake(false)
    }

    /// The full-screen player shows its own lyrics; the desktop overlay waits until it closes.
    func setPlayerVisible(_ visible: Bool) {
        playerVisible = visible
        update()
    }

    /// Lyrics will fill the lock screen, so it leaves out its player card and motion artwork.
    var fillsLockScreen: Bool {
        guard settings.screenLyrics, !dismissedOnLock, store.hasTrack, store.isPlaying, case .synced = store.lyrics else { return false }
        return true
    }

    /// Debug: act as if the screen locked or unlocked (lays out for the lock screen).
    func debugSetLocked(_ isLocked: Bool) { setLocked(isLocked) }

    private func setLocked(_ isLocked: Bool) {
        locked = isLocked
        dismissedOnLock = false
        update()
        // loginwindow settles its layout a moment after locking; recentre on it then.
        if isLocked {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(900))
                guard let self, self.locked else { return }
                self.update()
            }
        }
    }

    /// Re-runs `update` whenever a setting or the playback state it depends on changes.
    private func observe() {
        withObservationTracking {
            _ = wanted
            _ = (settings.screenLyricsSize, settings.screenLyricsKeepAwake)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
    }

    /// Whether the lyrics should be on screen now.
    private var wanted: Bool {
        guard settings.screenLyrics, store.hasTrack, store.isPlaying, case .synced = store.lyrics else { return false }
        return locked ? !dismissedOnLock : (settings.screenLyricsPlace == .everywhere && !playerVisible)
    }

    /// Shows, moves or hides the overlay to match the settings and what's playing.
    private func update() {
        if store.lyrics != lyrics {
            lyrics = store.lyrics
            if case .synced(let lines) = lyrics {
                model.stream = WordStream(lines: lines)
            } else {
                model.stream = WordStream(lines: [])
            }
        }
        let show = wanted && !model.stream.words.isEmpty
        model.onLockScreen = locked
        Log.lyrics.debug("Screen lyrics: show \(show) (locked \(self.locked), words \(self.model.stream.words.count))")

        let panel = locked ? lockPanel : desktopPanel
        let other = locked ? desktopPanel : lockPanel
        if other.isVisible { other.orderOut(nil) }

        if show, let screen = NSScreen.screens.first {
            hideTask?.cancel()
            hideTask = nil
            layOut(on: screen)
            if panel.frame != screen.frame { panel.setFrame(screen.frame, display: false) }
            if !panel.isVisible || panel.alphaValue < 1 {
                if locked {
                    // At once: with the display asleep behind the lock, a fade may never run.
                    panel.alphaValue = 1
                    panel.orderFrontRegardless()
                    space?.attach(panel)
                } else {
                    if !panel.isVisible { panel.alphaValue = 0 }
                    panel.orderFrontRegardless()
                    fade(panel, to: 1)
                }
            }
            model.isVisible = true
            fillingLockScreen = locked
            showCloseButton(locked, on: screen)
            keepAwake(settings.screenLyricsKeepAwake)
        } else if panel.isVisible, hideTask == nil {
            // Pausing for a moment, or the gap between songs, shouldn't blink the lyrics away.
            hideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, !Task.isCancelled else { return }
                self.hideTask = nil
                self.model.isVisible = false
                self.fillingLockScreen = false
                self.showCloseButton(false)
                self.keepAwake(false)
                // Unless it was asked back while fading.
                self.fade(panel, to: 0) { [weak self] in
                    if self?.model.isVisible == false { panel.orderOut(nil) }
                }
            }
        } else if !panel.isVisible {
            model.isVisible = false
            fillingLockScreen = false
            showCloseButton(false)
            keepAwake(false)
        }
        if !locked { fillingLockScreen = false }
    }

    /// The large word is about a fifth of the screen's height (as big as in Verci's own demo)
    /// and at most 60% of its width, and sits a little below the middle (56% down). On the
    /// lock screen the stack fills the space between the clock and the password field.
    private func layOut(on screen: NSScreen) {
        let height = screen.frame.height
        model.wordSize = (height * 0.2 * settings.screenLyricsSize).rounded()
        model.maxWordWidth = screen.frame.width * 0.6
        if locked {
            let layout = LockLayout(screen: screen, loginWindows: LockLayout.loginWindowFrames(),
                                    clockBottom: SystemClock.isAvailable ? SystemClock.clockBottom(screenHeight: height) : nil)
            // The widgets step aside, so the stack has the whole space under the clock.
            model.centerOffset = (screen.frame.maxY - layout.content.midY) - height / 2
            model.clockInset = layout.clockInset
            model.wordSize = min(model.wordSize, (layout.content.height / 3).rounded())
        } else {
            model.centerOffset = height * 0.06
        }
    }

    /// The lyrics step aside at once (no pause-grace fade), and the widgets and player card
    /// come back in their place.
    private func dismissOnLock() {
        guard locked else { return }
        dismissedOnLock = true
        hideTask?.cancel()
        hideTask = nil
        model.isVisible = false
        fillingLockScreen = false
        showCloseButton(false)
        keepAwake(false)
        fade(lockPanel, to: 0) { [weak self] in
            if self?.model.isVisible == false { self?.lockPanel.orderOut(nil) }
        }
    }

    private func showCloseButton(_ show: Bool, on screen: NSScreen? = nil) {
        guard show, let screen else {
            if closePanel.isVisible { closePanel.orderOut(nil) }
            return
        }
        // Top-left, where the full-screen player keeps its close button.
        closePanel.setFrameOrigin(CGPoint(x: screen.frame.minX + 26, y: screen.frame.maxY - 26 - 44))
        guard !closePanel.isVisible else { return }
        closePanel.alphaValue = 1
        closePanel.orderFrontRegardless()
        space?.attach(closePanel)
    }

    // MARK: - Display sleep

    /// Without this the lock screen goes dark after a minute, lyrics and all.
    private func keepAwake(_ on: Bool) {
        guard on != holdingAwake else { return }
        if on {
            holdingAwake = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Islet: lyrics on screen" as CFString, &awakeAssertion) == kIOReturnSuccess
        } else {
            IOPMAssertionRelease(awakeAssertion)
            holdingAwake = false
        }
    }

    // MARK: - Windows

    private func makePanel(_ identifier: String) -> NSPanel {
        let panel = IslandPanel(size: NSScreen.screens.first?.frame.size ?? CGSize(width: 1440, height: 900))
        panel.identifier = NSUserInterfaceItemIdentifier(identifier)
        // Over other apps, under the island.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView: ScreenLyricsView(store: store, settings: settings, model: model))
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }

    private func fade(_ panel: NSPanel, to alpha: CGFloat, then done: (@MainActor () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            panel.animator().alphaValue = alpha
        } completionHandler: {
            MainActor.assumeIsolated { done?() }
        }
    }
}

/// The lock-screen lyrics' close button: the same glass chevron as the full-screen player.
private struct LockLyricsCloseButton: View {
    let close: () -> Void

    var body: some View {
        RoutedButton("lyrics.close", action: close) {
            Image(systemName: "chevron.down")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
        }
        .help("Hide lyrics")
        .environment(\.colorScheme, .dark)
    }
}
