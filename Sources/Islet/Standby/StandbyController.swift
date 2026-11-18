import AppKit
import IsletCore
import CoreGraphics
import IOKit.pwr_mgt
import SwiftUI

/// What the Standby screen shows; refreshed while it's up.
@MainActor @Observable
final class StandbyModel {
    var battery = Battery.current()
    var weather: WeatherService.Report?
    /// Flips on a beat after the window appears, so everything animates in.
    var shown = false
    /// A tiny shift every minute, so nothing sits on the same pixels all night.
    var drift = CGSize.zero
}

/// Standby: while the Mac is on its charger and nobody has touched it for a while, the
/// screen becomes a big clock with what's playing, the weather and the battery. Any input
/// ends it. It never starts while the screen is locked, the display is asleep, or another
/// app is holding the display awake (a video playing).
@MainActor
final class StandbyController {
    /// The running controller, for the Settings preview and the menu bar.
    static weak var shared: StandbyController?

    private let settings: AppSettings
    private let store: PlayerStore
    private let model = StandbyModel()
    private var panel: NSPanel?
    private var pollTimer: Timer?
    private var refreshTimer: Timer?
    private var startedAt = Date.distantPast
    private var assertion: IOPMAssertionID = 0
    /// After Standby is dismissed it waits for a fresh idle stretch before coming back.
    private var dismissedAt = Date.distantPast

    var isShowing: Bool { panel?.isVisible == true }

    init(settings: AppSettings, store: PlayerStore) {
        self.settings = settings
        self.store = store
    }

    /// Looks whether Standby should start, then sleeps until the soonest moment it could:
    /// a few wakeups per idle stretch rather than one every few seconds.
    func begin() {
        schedulePoll(after: 10)
        // Standby is for a screen someone might look at. Once the display sleeps it ends
        // (input would end it on wake anyway) and nothing is checked until the display
        // wakes: no polling through the night.
        let center = NSWorkspace.shared.notificationCenter
        displayObservers = [
            center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.stop()
                    self?.pollTimer?.invalidate()
                    self?.pollTimer = nil
                }
            },
            center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedulePoll(after: 10) }
            },
        ]
    }

    private var displayObservers: [NSObjectProtocol] = []

    /// `repeating`: the quick input watch while Standby is up; otherwise one look, after which
    /// `poll` picks the next.
    private func schedulePoll(after interval: TimeInterval, repeating: Bool = false) {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: repeating) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        pollTimer?.tolerance = repeating ? 0.05 : min(interval * 0.1, 5)
    }

    private func poll() {
        if isShowing {
            // Any input since it appeared (after a moment's grace for the click that
            // started it) wakes the Mac back up.
            let lastInput = Date().addingTimeInterval(-Self.idleSeconds)
            if lastInput > startedAt.addingTimeInterval(1) || LockScreenController.screenIsLockedNow()
                || (!Self.onPower && !manual) {
                stop()
            }
            return
        }
        let next = check()
        // Started: `start` set up the input watch.
        if !isShowing { schedulePoll(after: next) }
    }

    /// Starts Standby if it's time; otherwise returns how long until the next look. The cheap facts
    /// come first: the power-assertion list and `pmset` are read only once the Mac has sat
    /// idle and unlocked on its charger for at least the shortest wait.
    private func check() -> TimeInterval {
        guard settings.standbyEnabled, Self.onPower else { return 30 }
        let idle = Self.idleSeconds
        guard idle >= StandbyConditions.shortestWait else { return max(StandbyConditions.shortestWait - idle, 1) }
        // Locked (often for the night): a slow look, and nothing costly.
        if LockScreenController.screenIsLockedNow() { return 60 }
        let conditions = StandbyConditions(
            enabled: true, onPower: true, idleSeconds: idle,
            idleMinutes: settings.standbyIdleMinutes,
            sinceDismissed: dismissedAt == .distantPast ? nil : Date().timeIntervalSince(dismissedAt),
            screenLocked: LockScreenController.screenIsLockedNow(),
            displayAsleep: CGDisplayIsAsleep(CGMainDisplayID()) != 0,
            otherAppHoldsDisplay: Self.otherAppKeepsDisplayAwake,
            systemTimeout: Self.systemTimeout)
        guard conditions.shouldStart else { return conditions.nextCheck }
        start(manually: false)
        return conditions.nextCheck
    }

    private var manual = false
    /// The app that was in front; it gets focus back when Standby ends.
    private var previousApp: NSRunningApplication?

    /// Shows Standby now (from Settings or the menu bar), or after the idle wait.
    func start(manually: Bool) {
        guard !isShowing, let screen = NSScreen.screens.first else { return }
        manual = manually
        startedAt = Date()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(screen.frame, display: true)
        model.shown = false
        model.battery = Battery.current()
        model.weather = WeatherService.shared.report
        panel.alphaValue = 0
        // Standby takes the keyboard, so the key that wakes it doesn't also type into
        // whatever app sits underneath.
        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = IslandMotion.reduced ? 0.2 : 0.45
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            panel.animator().alphaValue = 1
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            withAnimation(IslandMotion.playful) { self?.model.shown = true }
        }
        if settings.standbyKeepAwake {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Islet Standby" as CFString, &assertion)
        }
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refreshTimer?.tolerance = 5
        schedulePoll(after: 0.25, repeating: true)
        Log.island.info("Standby started (\(manually ? "by hand" : "idle on power"))")
    }

    func stop() {
        guard let panel, panel.isVisible else { return }
        dismissedAt = Date()
        refreshTimer?.invalidate()
        refreshTimer = nil
        if assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
        schedulePoll(after: 10)
        if let previousApp, previousApp != .current { previousApp.activate() }
        previousApp = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { [weak self] in
                guard let self, self.panel?.alphaValue == 0 else { return }
                self.panel?.orderOut(nil)
                // Nothing keeps drawing behind the desktop until the next Standby.
                self.panel?.contentView = nil
                self.panel = nil
            }
        }
    }

    private func refresh() {
        model.battery = Battery.current()
        withAnimation(.easeInOut(duration: 2)) {
            model.drift = IslandMotion.reduced ? .zero
                : CGSize(width: .random(in: -10...10), height: .random(in: -8...8))
        }
        guard settings.lockWeather else { return }
        Task { @MainActor [weak self] in
            let report = await WeatherService.shared.current()
            guard let self, self.isShowing else { return }
            withAnimation(IslandMotion.panel) { self.model.weather = report }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = StandbyPanel(contentRect: NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.identifier = NSUserInterfaceItemIdentifier("standby")
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // Clicks land on Standby (and end it) rather than on whatever sits underneath.
        panel.ignoresMouseEvents = false
        panel.backgroundColor = .black
        panel.isOpaque = true
        panel.contentView = NSHostingView(rootView: StandbyView(model: model, store: store, settings: settings))
        return panel
    }

    // MARK: - System state

    /// Seconds since the last key press, click, scroll or mouse move, anywhere.
    static var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// On a charger, or a desktop Mac (no battery at all).
    static var onPower: Bool { Battery.current()?.isPluggedIn ?? true }

    /// A video or presentation is holding the display awake; Standby stays out of its way.
    /// Not counted: Islet's own holds (lock-screen lyrics, Keep Awake) and the audio
    /// service, which holds one for any sound playing, and music is exactly when Standby
    /// is wanted.
    static var otherAppKeepsDisplayAwake: Bool {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let processes = byProcess?.takeRetainedValue() as? [Int: [[String: Any]]] else { return false }
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        return processes.contains { pid, assertions in
            guard pid != me, !Self.isAudioService(pid) else { return false }
            return assertions.contains {
                ($0[kIOPMAssertionTypeKey] as? String) == kIOPMAssertionTypePreventUserIdleDisplaySleep
                    && ($0[kIOPMAssertionLevelKey] as? Int ?? 0) == kIOPMAssertionLevelOn
            }
        }
    }

    private static func isAudioService(_ pid: Int) -> Bool {
        var name = [CChar](repeating: 0, count: 64)
        return proc_name(Int32(pid), &name, 64) > 0 && String(cString: name) == "coreaudiod"
    }

    /// Seconds until macOS turns the display off on the charger or starts the screen saver
    /// (whichever is sooner), or nil when neither will happen.
    static var systemTimeout: TimeInterval? {
        var timeouts: [TimeInterval] = []
        if let minutes = displaySleepMinutes, minutes > 0 { timeouts.append(Double(minutes * 60)) }
        if let seconds = CFPreferencesCopyValue("idleTime" as CFString, "com.apple.screensaver" as CFString,
                                                kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? Int, seconds > 0 {
            timeouts.append(Double(seconds))
        }
        return timeouts.min()
    }

    /// The display-sleep setting for the power source in use (Standby only runs on the
    /// charger, so that one). The API for it is private; `pmset -g` prints it, read at most
    /// every ten minutes (it changes only in System Settings).
    private static var displaySleepMinutes: Int? {
        if let cached = displaySleepCache, Date().timeIntervalSince(cached.read) < 600 { return cached.minutes }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let minutes = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("displaysleep") }
            .flatMap { $0.split(separator: " ", omittingEmptySubsequences: true).dropFirst().first }
            .flatMap { Int($0) }
        displaySleepCache = (Date(), minutes)
        return minutes
    }
    private static var displaySleepCache: (read: Date, minutes: Int?)?
}

/// Standby's window: it takes key presses (and swallows them without a beep), so the
/// key that ends Standby never reaches the app underneath.
final class StandbyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {}
}
