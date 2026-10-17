import AppKit
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: AppSettings!
    private var store: PlayerStore!
    private var island: IslandController!
    private var player: FullPlayerController!
    private var lockScreen: LockScreenController!
    private var statusMenu: StatusMenuController!
    private var debugTools: DebugTools?
    private var settingsWindow: SettingsController!
    private var onboarding: OnboardingController!
    private let headphones = HeadphoneMonitor()
    private let privacy = PrivacyMonitor()
    /// Sparkle: daily signed-update checks against the GitHub release feed.
    let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: UpdateFeed.shared,
                                               userDriverDelegate: UpdateFeed.shared)
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = AppSettings()
        let store = PlayerStore(settings: settings)
        let island = IslandController(store: store, settings: settings)
        let player = FullPlayerController(store: store)
        let lockScreen = LockScreenController(store: store, settings: settings)

        island.onOpenPlayer = { [weak player] rect in player?.open(from: rect) }
        player.closeTarget = { [weak island] in island?.artScreenRect() }
        player.onVisibilityChange = { [weak island] visible in island?.setPlayerVisible(visible) }

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

        store.start()
        stopCleanlyOnSignals()
        island.show()
        PowerMonitor.shared.onPluggedIn = { [weak island] battery in island?.showCharging(battery) }
        lockScreen.onUnlock = { [weak island] in island?.showUnlocked() }

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
            updater: updater.updater)
        statusMenu.openSettings = { [weak self] in self?.settingsWindow.show() }
        statusMenu.checkForUpdates = { [weak self] in self?.updater.checkForUpdates(nil) }
        statusMenu.whatsNew = { [weak self] in self?.onboarding.showLatest() }
        statusMenu.timerRunning = { [weak island] in island?.timerRunning ?? false }
        statusMenu.startTimer = { [weak island] minutes in island?.startTimer(minutes: minutes) }
        statusMenu.cancelTimer = { [weak island] in island?.cancelTimer() }
        debugTools?.openSettings = { [weak self] in self?.settingsWindow.show() }
        debugTools?.openTutorial = { [weak self] in self?.onboarding.show() }
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
            let levels = settings.liveWaveform && store.isPlaying && WaveformLevels.shared.viewers > 0
            AudioTapEngine.shared.setEqualizer(bands: settings.equalizerBands, preamp: settings.equalizerPreamp)
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

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                  state: SPUUserUpdateState) {
        guard handleShowingUpdate, !state.userInitiated else { return }
        NSApp.activate()
    }
}
