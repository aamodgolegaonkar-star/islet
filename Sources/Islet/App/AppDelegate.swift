import AppKit
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: AppSettings!
    private var store: PlayerStore!
    private var island: IslandController!
    private var player: FullPlayerController!
    private var lockScreen: LockScreenController!
    private var screenLyrics: ScreenLyricsController?
    private var standby: StandbyController?
    private var edgeGlow: EdgeGlowController?
    private var statusMenu: StatusMenuController!
    private var debugTools: DebugTools?
    private var settingsWindow: SettingsController!
    private var onboarding: OnboardingController!
    private let headphones = HeadphoneMonitor()
    private let privacy = PrivacyMonitor()
    private let focus = FocusMonitor()
    private var corners: ScreenCorners?
    /// Sparkle: daily signed-update checks against the GitHub release feed.
    let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: UpdateFeed.shared,
                                               userDriverDelegate: UpdateFeed.shared)
    private var signalSources: [DispatchSourceSignal] = []
    private var captureObserver: NSObjectProtocol?
    private var portal: PortalController!
    private var link: LinkController!
    private var settingsPaneObserver: NSObjectProtocol?
    private var faceID: FaceIDController!

    /// "Hide from screen recordings": Islet's overlay panels (island, lyrics, glow, player)
    /// opt out of screenshots, recordings and screen sharing. Each panel is set as it
    /// appears, and all of them again whenever the setting changes.
    private func followCaptureSetting() {
        withObservationTracking { applyCaptureSetting() } onChange: {
            Task { @MainActor [weak self] in self?.followCaptureSetting() }
        }
    }

    private func applyCaptureSetting() {
        let type: NSWindow.SharingType = settings.hideFromScreenCapture ? .none : .readOnly
        for window in NSApp.windows where (window is NSPanel || window is FullPlayerWindow) && window.sharingType != type {
            window.sharingType = type
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = AppSettings()
        let store = PlayerStore(settings: settings)
        let island = IslandController(store: store, settings: settings)
        let player = FullPlayerController(store: store)
        let lockScreen = LockScreenController(store: store, settings: settings)
        let screenLyrics = ScreenLyricsController(store: store, settings: settings)
        self.screenLyrics = screenLyrics
        let edgeGlow = EdgeGlowController(store: store, settings: settings)
        self.edgeGlow = edgeGlow
        lockScreen.lyricsFillLockScreen = { [weak screenLyrics] in screenLyrics?.fillsLockScreen ?? false }
        screenLyrics.onLockScreenFillChange = { [weak lockScreen] filling in lockScreen?.lyricsFillChanged(filling) }

        island.onOpenPlayer = { [weak player] rect in player?.open(from: rect) }
        player.closeTarget = { [weak island] in island?.artScreenRect() }
        player.onVisibilityChange = { [weak island, weak screenLyrics] visible in
            island?.setPlayerVisible(visible)
            screenLyrics?.setPlayerVisible(visible)
        }

        statusMenu = StatusMenuController(
            store: store, settings: settings, lockScreen: lockScreen,
            styleChanged: { [weak island] in island?.reposition() }
        ) { [weak island, weak player] in
            player?.toggle(from: island?.artScreenRect())
        }

        self.settings = settings
        self.store = store
        self.island = island
        self.player = player
        self.lockScreen = lockScreen

        debugTools = DebugTools(island: island, player: player, lockScreen: lockScreen, settings: settings)
        debugTools?.screenLyrics = screenLyrics
        debugTools?.edgeGlow = edgeGlow

        store.start()
        screenLyrics.start()
        edgeGlow.start()
        stopCleanlyOnSignals()
        island.show()
        PowerMonitor.shared.onPluggedIn = { [weak island, weak settings] battery in
            guard settings?.showChargingAlert == true else { return }
            island?.showCharging(battery)
        }
        followCaptureSetting()
        portal = PortalController(settings: settings, island: island)
        portal.start()
        debugTools?.portal = portal
        link = LinkController(store: store, island: island, portal: portal)
        island.model.link = link
        portal.sendThroughLink = { [weak link] files, text in link?.send(files: files, text: text) ?? false }
        link.start()
        debugTools?.link = link
        debugTools?.faceID = faceID
        captureObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // A window just appeared or hid: catch new overlays as they show.
            MainActor.assumeIsolated { self?.applyCaptureSetting() }
        }
        let standby = StandbyController(settings: settings, store: store)
        StandbyController.shared = standby
        self.standby = standby
        standby.begin()
        let faceID = FaceIDController(settings: settings, lockScreen: lockScreen)
        self.faceID = faceID
        faceID.start()
        // Touch ID or the password: the fingerprint animation. Face ID: its own.
        lockScreen.onUnlock = { [weak island, weak faceID] in island?.showUnlocked(face: faceID?.unlockedByFace ?? false) }
        // Off the launch path: get the lock-screen windows ready for the first lock.
        Task { @MainActor [weak lockScreen] in
            try? await Task.sleep(for: .seconds(3))
            lockScreen?.prepare()
        }

        // Live activities: volume, brightness, headphones.
        store.onVolumeKeys = { [weak island, weak settings] volume, muted in
            guard settings?.showVolumeInIsland == true else { return }
            island?.showLevel(LevelHUD(kind: .volume, value: Double(volume), muted: muted))
        }
        BrightnessMonitor.shared.onUserChange = { [weak island, weak settings] value in
            guard settings?.showBrightnessInIsland == true else { return }
            island?.showLevel(LevelHUD(kind: .brightness, value: value))
        }
        BrightnessMonitor.shared.start()
        island.model.onLevelDrag = { [weak store] kind, value in
            switch kind {
            case .volume: store?.setVolume(value)
            case .brightness: BrightnessMonitor.shared.set(value)
            }
        }
        headphones.onConnect = { [weak island, weak settings] card in
            guard settings?.showHeadphonesInIsland == true else { return }
            island?.showHeadphones(card)
        }
        headphones.start()
        OutputStatus.shared.start()
        privacy.onChange = { [weak island, weak settings] mic, camera in
            let show = settings?.showPrivacyDots == true
            island?.model.micActive = show && mic
            island?.model.cameraActive = show && camera
        }
        privacy.start()
        focus.onChange = { [weak island, weak lockScreen, weak settings] mode, ended in
            island?.focus = mode
            lockScreen?.model.focus = mode
            guard settings?.showFocusInIsland == true else { return }
            if let mode { island?.showFocus(mode, on: true) } else if let ended { island?.showFocus(ended, on: false) }
        }
        focus.start()
        corners = ScreenCorners(settings: settings)
        corners?.start()
        island.focus = focus.active
        lockScreen.model.focus = focus.active
        PowerMonitor.shared.onLow = { [weak island, weak settings] percent in
            guard settings?.showLowBattery == true else { return }
            island?.showLowBattery(percent)
        }
        MediaKeys.shared.onKey = { [weak island, weak store] key, fine in
            guard let island, let store else { return }
            switch key {
            case .volumeUp, .volumeDown, .mute:
                let direction = key == .volumeUp ? 1 : key == .volumeDown ? -1 : 0
                let level = store.stepVolume(direction, fine: fine)
                island.showLevel(LevelHUD(kind: .volume, value: level.volume, muted: level.muted))
            case .brightnessUp, .brightnessDown:
                guard let value = BrightnessMonitor.shared.step(key == .brightnessUp ? 1 : -1, fine: fine) else {
                    return MediaKeys.shared.brightnessUnavailable()
                }
                island.showLevel(LevelHUD(kind: .brightness, value: value))
            }
        }
        if settings.replaceSystemIndicator { MediaKeys.shared.setEnabled(true) }
        island.model.onAgentTap = { [weak island] alert in
            island?.dismissActivity()
            if let app = alert.app,
               let running = NSRunningApplication.runningApplications(withBundleIdentifier: app).first {
                running.activate()
            }
        }

        onboarding = OnboardingController(settings: settings) { [weak self] in self?.settingsWindow.show() }
        settingsWindow = SettingsController(
            settings: settings, sounds: lockScreen.sounds,
            islandChanged: { [weak island] in island?.reposition() },
            previewIsland: { [weak island] on in island?.previewExpanded(on) },
            showTutorial: { [weak self] in self?.onboarding.show() },
            sourceChanged: { [weak store, weak settings] in
                guard let settings else { return }
                store?.use(settings.playerSource)
            },
            updater: updater.updater, portal: portal, faceID: faceID, link: link)
        settingsPaneObserver = NotificationCenter.default.addObserver(
            forName: .openSettingsPane, object: nil, queue: .main
        ) { [weak self] note in
            let pane = note.object as? String
            MainActor.assumeIsolated {
                if let pane { UserDefaults.standard.set(pane, forKey: "settingsPane") }
                self?.settingsWindow.show()
            }
        }
        statusMenu.openSettings = { [weak self] in self?.settingsWindow.show() }
        statusMenu.checkForUpdates = { [weak self] in self?.updater.checkForUpdates(nil) }
        statusMenu.whatsNew = { [weak self] in self?.onboarding.showLatest() }
        statusMenu.timerRunning = { [weak island] in island?.timerRunning ?? false }
        statusMenu.startTimer = { [weak island] minutes in island?.startTimer(minutes: minutes) }
        statusMenu.cancelTimer = { [weak island] in island?.cancelTimer() }
        debugTools?.openSettings = { [weak self] in self?.settingsWindow.show() }
        debugTools?.openTutorial = { [weak self] in self?.onboarding.show() }
        debugTools?.openWhatsNew = { [weak self] in self?.onboarding.showLatest() }
        if !settings.onboardingDone { onboarding.show() } else { onboarding.showWhatsNewIfUpdated() }
        PowerMonitor.shared.start()
        WaveformLevels.shared.onViewersChanged = { [weak self] in self?.updateAudioTap() }
        updateAudioTap()
    }

    /// Keeps the audio tap (equalizer and live bars) in step with what's playing and the
    /// settings; re-runs whenever anything it read changes.
    private func updateAudioTap() {
        guard let settings, let store else { return }
        let wants = withObservationTracking {
            let bundle = store.hasTrack ? store.snapshot?.bundleIdentifier : nil
            let equalizer = settings.equalizerEnabled && ["com.apple.Music", "com.spotify.client"].contains(bundle ?? "")
            // The bars, or the edge glow's beat, are watching.
            let levels = (settings.liveWaveform || settings.edgeGlowBeat) && store.isPlaying
                && WaveformLevels.shared.viewers > 0
            let curve = settings.equalizer(for: bundle)
            AudioTapEngine.shared.setEqualizer(bands: curve.bands, preamp: curve.preamp)
            return AudioTapEngine.Wants(target: bundle, equalizer: equalizer, levels: levels)
        } onChange: {
            Task { @MainActor [weak self] in self?.updateAudioTap() }
        }
        AudioTapEngine.shared.update(wants)
    }

    /// islet://agent links from the Claude Code / Codex hook command.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard settings?.showAgentAlerts == true, let alert = AgentAlert(url: url) else { continue }
            // "Finished" isn't news if you're already looking at that terminal.
            if alert.event.kind == .done, let app = alert.app,
               NSWorkspace.shared.frontmostApplication?.bundleIdentifier == app { continue }
            island?.showAgent(alert)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AudioTapEngine.shared.stop()
        store?.stop()
        lockScreen?.shutdown()
        screenLyrics?.stop()
        edgeGlow?.stop()
    }

    /// `kill`, logout scripts and Ctrl-C bypass applicationWillTerminate; without this the
    /// Now Playing adapter (a child perl process) would keep running after Islet is gone.
    private func stopCleanlyOnSignals() {
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    AudioTapEngine.shared.stop()
                    self?.store?.stop()
                    self?.lockScreen?.shutdown()
                }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}

/// Testing hook: `defaults write local.islet.Islet updateFeedOverride <url>` points the
/// updater at another feed (e.g. a local test release) instead of the GitHub one.
///
/// Also Sparkle's "gentle reminders": Islet has no Dock icon and is never the active app,
/// so a scheduled "update available" window would open behind whatever you're using.
/// Islet brings it to the front instead.
@MainActor
final class UpdateFeed: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    static let shared = UpdateFeed()

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: "updateFeedOverride")
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// On the developer's Mac the app folder is kept read-only (scripts/sync-local.sh), so
    /// tools can't drop files beside Contents and break the signature. The installer has to
    /// move the old app aside, which needs it writable again.
    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) { makeAppWritable() }
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) { makeAppWritable() }

    private func makeAppWritable() {
        let path = Bundle.main.bundlePath
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue, mode & 0o200 == 0 else { return }
        try? FileManager.default.setAttributes([.posixPermissions: mode | 0o200], ofItemAtPath: path)
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                  state: SPUUserUpdateState) {
        guard handleShowingUpdate, !state.userInitiated else { return }
        NSApp.activate()
    }
}
