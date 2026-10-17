import AppKit
import IsletCore

/// Plays a short sound when the screen locks or unlocks.
///
/// "iPhone-style" is synthesized here (no Apple audio assets are copied). "macOS Padlock"
/// plays the padlock sounds that ship with macOS, by path, without bundling them.
/// "Custom" plays lock.* / unlock.* files the user drops into Application Support.
///
/// Everything plays through NSSound, which reports failure instead of throwing: closing the
/// lid locks the screen while the audio device is shutting down for sleep, and an audio
/// engine raises an exception there that Swift can't catch. Nobody hears that click anyway,
/// so none is played while the displays or the system go to sleep.
@MainActor
final class LockSoundPlayer {
    enum Kind {
        case lock
        case unlock
    }

    private let settings: AppSettings
    /// The synthesized clicks, encoded once.
    private var clicks: [Kind: NSSound] = [:]
    private var sound: NSSound?
    private var screensAsleep = false
    private var systemSleeping = false
    private var observers: [NSObjectProtocol] = []

    private static let padlockDirectory = URL(fileURLWithPath: "/System/Library/Frameworks/SecurityInterface.framework/Versions/A/Resources")

    init(settings: AppSettings) {
        self.settings = settings
        let center = NSWorkspace.shared.notificationCenter
        let names = [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let name = note.name
                MainActor.assumeIsolated { self?.powerChanged(name) }
            }
        }
    }

    private func powerChanged(_ name: Notification.Name) {
        switch name {
        case NSWorkspace.screensDidSleepNotification: screensAsleep = true
        case NSWorkspace.screensDidWakeNotification: screensAsleep = false
        case NSWorkspace.willSleepNotification: systemSleeping = true
        case NSWorkspace.didWakeNotification: systemSleeping = false
        default: break
        }
    }

    func play(_ kind: Kind) {
        if kind == .lock, screensAsleep || systemSleeping { return }
        switch settings.lockSoundStyle {
        case .off:
            return
        case .iPhone:
            playClick(kind)
        case .macPadlock:
            let name = kind == .lock ? "lock.aif" : "unlock.aif"
            if !playFile(Self.padlockDirectory.appending(path: name)) { playClick(kind) }
        case .custom:
            if !playFile(customFile(kind)) { playClick(kind) }
        }
    }

    private func customFile(_ kind: Kind) -> URL? {
        let base = kind == .lock ? "lock" : "unlock"
        let files = (try? FileManager.default.contentsOfDirectory(at: settings.customSoundsDirectory,
                                                                    includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.deletingPathExtension().lastPathComponent.lowercased() == base }
    }

    private func playFile(_ url: URL?) -> Bool {
        guard let url, FileManager.default.fileExists(atPath: url.path),
              let sound = NSSound(contentsOf: url, byReference: true) else { return false }
        return start(sound)
    }

    private func playClick(_ kind: Kind) {
        if clicks[kind] == nil {
            clicks[kind] = NSSound(data: ClickSynthesis.wav(kind == .lock ? .lock : .unlock))
        }
        if let click = clicks[kind] { _ = start(click) }
    }

    private func start(_ next: NSSound) -> Bool {
        sound?.stop()
        sound = next
        return next.play()
    }
}
