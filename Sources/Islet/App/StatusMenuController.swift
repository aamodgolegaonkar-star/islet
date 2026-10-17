import AppKit
import ServiceManagement

/// The menu-bar item: the only way to reach settings and Quit, since Islet has no Dock icon.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let store: PlayerStore
    private let settings: AppSettings
    private let lockScreen: LockScreenController
    private let openPlayer: () -> Void
    private let styleChanged: () -> Void
    /// Opens the Settings window (set by the app delegate).
    var openSettings: () -> Void = {}
    var checkForUpdates: () -> Void = {}
    var whatsNew: () -> Void = {}
    var timerRunning: () -> Bool = { false }
    var startTimer: (Int) -> Void = { _ in }
    var cancelTimer: () -> Void = {}

    init(store: PlayerStore, settings: AppSettings, lockScreen: LockScreenController,
         styleChanged: @escaping () -> Void, openPlayer: @escaping () -> Void) {
        self.store = store
        self.settings = settings
        self.lockScreen = lockScreen
        self.openPlayer = openPlayer
        self.styleChanged = styleChanged
        super.init()
        item.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Islet")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let nowPlaying = store.hasTrack ? "\(store.title) — \(store.artist)" : "Nothing Playing"
        menu.addItem(disabled(nowPlaying))
        menu.addItem(disabled("Source: \(store.sourceName)"))
        menu.addItem(.separator())
        menu.addItem(action("Open Now Playing", #selector(openPlayerAction), key: "p"))
        menu.addItem(action("Settings…", #selector(openSettingsAction), key: ","))
        menu.addItem(action("Check for Updates…", #selector(checkForUpdatesAction)))
        menu.addItem(action("What's New…", #selector(whatsNewAction)))
        let timer = NSMenu()
        for minutes in [1, 3, 5, 10, 15, 25, 30, 45, 60] {
            let entry = action(minutes == 60 ? "1 hour" : "\(minutes) min", #selector(startTimerAction(_:)))
            entry.tag = minutes
            timer.addItem(entry)
        }
        if timerRunning() {
            timer.addItem(.separator())
            timer.addItem(action("Cancel Timer", #selector(cancelTimerAction)))
        }
        menu.addItem(submenu("Timer", timer))
        menu.addItem(.separator())

        let styles = NSMenu()
        for style in IslandStyle.allCases {
            let entry = action(style.title, #selector(selectIslandStyle(_:)))
            entry.representedObject = style.rawValue
            entry.state = settings.islandStyle == style ? .on : .off
            styles.addItem(entry)
        }
        menu.addItem(submenu("Island Style", styles))
        menu.addItem(toggle("Expand Island on Hover", settings.expandOnHover, #selector(toggleHover)))
        let lockTitle = lockScreen.lockScreenWidgetSupported
            ? "Show Widget on Lock Screen" : "Show Widget on Lock Screen (unsupported)"
        let lockItem = toggle(lockTitle, settings.lockWidgetEnabled, #selector(toggleLockWidget))
        lockItem.isEnabled = lockScreen.lockScreenWidgetSupported
        menu.addItem(lockItem)

        let sounds = NSMenu()
        for style in LockSoundStyle.allCases {
            let entry = action(style.title, #selector(selectSound(_:)))
            entry.representedObject = style.rawValue
            entry.state = settings.lockSoundStyle == style ? .on : .off
            sounds.addItem(entry)
        }
        sounds.addItem(.separator())
        sounds.addItem(action("Play Lock Sound", #selector(testLock)))
        sounds.addItem(action("Play Unlock Sound", #selector(testUnlock)))
        sounds.addItem(action("Open Custom Sounds Folder…", #selector(openSoundsFolder)))
        menu.addItem(submenu("Lock & Unlock Sounds", sounds))

        let motion = NSMenu()
        motion.addItem(toggle("Use Motion Artwork When Available", settings.animatedArtworkEnabled, #selector(toggleMotion)))
        motion.addItem(disabled(settings.developerToken == nil ? "No Apple Music developer token" : "Developer token saved"))
        motion.addItem(action("Set Apple Music Developer Token…", #selector(setToken)))
        if settings.developerToken != nil { motion.addItem(action("Remove Token", #selector(clearToken))) }
        menu.addItem(submenu("Animated Artwork", motion))

        menu.addItem(.separator())
        menu.addItem(toggle("Launch at Login", SMAppService.mainApp.status == .enabled, #selector(toggleLogin)))
        menu.addItem(action("Third-Party Notices", #selector(showNotices)))
        menu.addItem(.separator())
        menu.addItem(action("Quit Islet", #selector(quit), key: "q"))
    }

    // MARK: - Builders

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        entry.target = self
        return entry
    }

    private func toggle(_ title: String, _ on: Bool, _ selector: Selector) -> NSMenuItem {
        let entry = action(title, selector)
        entry.state = on ? .on : .off
        return entry
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.submenu = menu
        return entry
    }

    // MARK: - Actions

    @objc private func openPlayerAction() { openPlayer() }
    @objc private func openSettingsAction() { openSettings() }
    @objc private func checkForUpdatesAction() { checkForUpdates() }
    @objc private func whatsNewAction() { whatsNew() }
    @objc private func startTimerAction(_ sender: NSMenuItem) { startTimer(sender.tag) }
    @objc private func cancelTimerAction() { cancelTimer() }
    @objc private func toggleHover() { settings.expandOnHover.toggle() }
    @objc private func toggleLockWidget() { settings.lockWidgetEnabled.toggle() }
    @objc private func toggleMotion() { settings.animatedArtworkEnabled.toggle() }
    @objc private func testLock() { lockScreen.sounds.play(.lock) }
    @objc private func testUnlock() { lockScreen.sounds.play(.unlock) }
    @objc private func clearToken() { settings.setDeveloperToken(nil) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func selectIslandStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = IslandStyle(rawValue: raw) else { return }
        settings.islandStyle = style
        styleChanged()
    }

    @objc private func selectSound(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = LockSoundStyle(rawValue: raw) else { return }
        settings.lockSoundStyle = style
        lockScreen.sounds.play(.lock)
    }

    @objc private func openSoundsFolder() {
        NSWorkspace.shared.open(settings.customSoundsDirectory)
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSSound.beep()
        }
    }

    @objc private func showNotices() {
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "txt") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func setToken() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Apple Music Developer Token"
        alert.informativeText = """
        Motion artwork uses the official Apple Music API, which needs a developer token from a \
        paid Apple Developer Program account. Apple does not currently guarantee motion artwork \
        to third-party apps, so many albums will still show the animated color background.
        """
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 380, height: 24))
        field.placeholderString = "eyJhbGciOiJFUzI1NiIs…"
        field.stringValue = settings.developerToken ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            settings.setDeveloperToken(field.stringValue)
        }
    }
}
