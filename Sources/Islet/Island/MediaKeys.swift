import AppKit
import ApplicationServices
import AudioToolbox
import os

/// Handles the volume and brightness keys itself, so the island's level replaces the
/// macOS indicator (which apps can't move or restyle). Opt-in: catching these keys needs
/// the Accessibility permission. Every other key passes through untouched.
///
/// The event tap runs on its own high-priority thread (as Canopy does), never the main one:
/// a tap that answers late is switched off by macOS and the key falls through to the system
/// indicator, which used to happen whenever the island was busy animating. The tap thread
/// only decides whether to keep a key; the work happens on the main thread afterwards.
@MainActor
final class MediaKeys {
    static let shared = MediaKeys()

    enum Key: Sendable { case volumeUp, volumeDown, mute, brightnessUp, brightnessDown }

    /// Called on the main thread for each key press (and its repeats) that was kept.
    var onKey: ((Key, _ fine: Bool) -> Void)?
    private var tap: KeyTap?
    private var screenObserver: NSObjectProtocol?
    private var waitForPermission: Task<Void, Never>?

    var isTrusted: Bool { AXIsProcessTrusted() }

    /// Whether the brightness keys are kept: only while the main display's brightness can
    /// be set (an external monitor's can't, so macOS keeps those keys). Read on the tap thread.
    nonisolated private static let takesBrightness = OSAllocatedUnfairLock(initialState: true)

    /// Turns key handling on (asking for Accessibility first if needed) or off.
    func setEnabled(_ enabled: Bool) {
        waitForPermission?.cancel()
        waitForPermission = nil
        guard enabled else { return uninstall() }
        if isTrusted { return install() }
        // kAXTrustedCheckOptionPrompt's value (a global var Swift 6 won't read).
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        // Start as soon as the permission is granted (checked every 2 s for 3 minutes).
        waitForPermission = Task { @MainActor [weak self] in
            for _ in 0..<90 {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                if self.isTrusted {
                    self.install()
                    return
                }
            }
        }
    }

    /// Brightness couldn't be set: let macOS have the brightness keys again.
    func brightnessUnavailable() {
        Self.takesBrightness.withLock { $0 = false }
    }

    private func install() {
        guard tap == nil else { return }
        refreshBrightness()
        guard let tap = KeyTap() else {
            Log.island.error("Couldn't take over the volume and brightness keys")
            return
        }
        self.tap = tap
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { MediaKeys.shared.refreshBrightness() }
        }
        Log.island.notice("Handling volume and brightness keys")
    }

    private func uninstall() {
        tap?.stop()
        tap = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }

    private func refreshBrightness() {
        let settable = BrightnessMonitor.shared.current != nil
        Self.takesBrightness.withLock { $0 = settable }
    }

    // MARK: - On the tap thread

    /// Decides at once whether to keep a key (true: it's swallowed) and hands kept key
    /// presses to the main thread.
    nonisolated fileprivate static func handle(_ cgEvent: CGEvent) -> Bool {
        guard let event = NSEvent(cgEvent: cgEvent), event.type == .systemDefined,
              event.subtype.rawValue == 8 else { return false }
        let code = (event.data1 & 0xFFFF_0000) >> 16
        let state = (event.data1 & 0xFF00) >> 8
        let key: Key? = switch code {
        case 0: .volumeUp           // NX_KEYTYPE_SOUND_UP
        case 1: .volumeDown         // NX_KEYTYPE_SOUND_DOWN
        case 7: .mute               // NX_KEYTYPE_MUTE
        case 2: .brightnessUp       // NX_KEYTYPE_BRIGHTNESS_UP
        case 3: .brightnessDown     // NX_KEYTYPE_BRIGHTNESS_DOWN
        default: nil
        }
        guard let key else { return false }
        if key == .brightnessUp || key == .brightnessDown, !takesBrightness.withLock({ $0 }) { return false }
        switch state {
        case 0x0A:
            // Key-down and its repeats.
            let fine = event.modifierFlags.contains([.option, .shift])
            DispatchQueue.main.async {
                MainActor.assumeIsolated { MediaKeys.shared.onKey?(key, fine) }
            }
        case 0x0B where key == .volumeUp || key == .volumeDown:
            // Key-up: the click macOS plays when "Play feedback when volume is changed" is on.
            VolumeFeedback.playIfEnabled()
        default:
            break
        }
        return true
    }
}

/// The event tap and the thread its run loop lives on.
private final class KeyTap: @unchecked Sendable {
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?

    init?() {
        // System-defined events (type 14) carry the media and brightness keys.
        let mask = CGEventMask(1 << 14)
        let callback: CGEventTapCallBack = { _, type, event, info in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let info, let port = Unmanaged<KeyTap>.fromOpaque(info).takeUnretainedValue().port {
                    CGEvent.tapEnable(tap: port, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }
            return MediaKeys.handle(event) ? nil : Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let runLoopSource = CFMachPortCreateRunLoopSource(nil, port, 0)
        else { return nil }
        self.port = port

        nonisolated(unsafe) let source = runLoopSource
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let loop = CFRunLoopGetCurrent()
            runLoop = loop
            CFRunLoopAddSource(loop, source, .commonModes)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "local.islet.mediaKeys"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        CGEvent.tapEnable(tap: port, enable: true)
    }

    func stop() {
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let runLoop { CFRunLoopStop(runLoop) }
    }
}

/// The volume click macOS's own indicator plays (its sound file, from BezelServices).
private enum VolumeFeedback {
    private static let sound: SystemSoundID? = {
        let url = URL(fileURLWithPath: "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff")
        var id: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &id) == noErr else { return nil }
        return id
    }()

    static func playIfEnabled() {
        // Sound settings → "Play feedback when volume is changed" (off when never set).
        guard UserDefaults(suiteName: "NSGlobalDomain")?.bool(forKey: "com.apple.sound.beep.feedback") == true,
              let sound else { return }
        AudioServicesPlaySystemSound(sound)
    }
}
