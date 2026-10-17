import AppKit
import ApplicationServices

/// Handles the volume and brightness keys itself, so the island's level replaces the
/// macOS indicator (which apps can't move or restyle). Opt-in: catching these keys needs
/// the Accessibility permission. Every other key passes through untouched.
@MainActor
final class MediaKeys {
    static let shared = MediaKeys()

    enum Key { case volumeUp, volumeDown, mute, brightnessUp, brightnessDown }

    /// Return true when handled (the key is then swallowed); false lets macOS have it.
    var onKey: ((Key, _ fine: Bool) -> Bool)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var waitForPermission: Task<Void, Never>?

    var isTrusted: Bool { AXIsProcessTrusted() }

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

    private func install() {
        guard tap == nil else { return }
        // System-defined events (type 14) carry the media and brightness keys.
        let mask = CGEventMask(1 << 14)
        let callback: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated { MediaKeys.shared.reenable() }
                return Unmanaged.passUnretained(event)
            }
            let handled = MainActor.assumeIsolated { MediaKeys.shared.handle(event) }
            return handled ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback, userInfo: nil) else {
            Log.island.error("Couldn't take over the volume and brightness keys")
            return
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.island.notice("Handling volume and brightness keys")
    }

    private func uninstall() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private func handle(_ cgEvent: CGEvent) -> Bool {
        guard let event = NSEvent(cgEvent: cgEvent), event.subtype.rawValue == 8 else { return false }
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
        Log.island.debug("Media key \(code) state \(state) \(key == nil ? "passed on" : "taken", privacy: .public)")
        guard let key else { return false }
        // Act on key-down (and its repeats); swallow the matching key-up too.
        guard state == 0x0A else { return true }
        let fine = event.modifierFlags.contains([.option, .shift])
        return onKey?(key, fine) ?? false
    }
}
