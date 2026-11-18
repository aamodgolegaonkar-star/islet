import AppKit
import notify

/// The screen locking or unlocking, told once per change.
///
/// loginwindow announces it twice: as a distributed notification, which goes through
/// distnoted and can arrive seconds late on a busy wake (the lock-screen widgets then sat
/// over the desktop meanwhile), and as notifyd state, which arrives at once. Whichever
/// comes first wins; the other is ignored. Unlock has its own notifyd key, and as in Canopy's
/// LockState, a 1 s poll of the session state while locked catches an unlock both channels miss.
@MainActor
final class LockSignal {
    private(set) var isLocked: Bool
    private let changed: (Bool) -> Void
    private var observers: [DistributedObserver] = []
    private var tokens: [Int32] = []
    private var poll: Timer?
    private var displayObservers: [NSObjectProtocol] = []
    /// No unlock can happen with the display off: the poll rests then.
    private var displayAsleep = false

    init(_ changed: @escaping (Bool) -> Void) {
        self.changed = changed
        isLocked = LockScreenController.screenIsLockedNow()
        observers = [
            DistributedObserver("com.apple.screenIsLocked") { [weak self] _ in self?.set(true, via: "distributed") },
            DistributedObserver("com.apple.screenIsUnlocked") { [weak self] _ in self?.set(false, via: "distributed") },
        ]
        var token = NOTIFY_TOKEN_INVALID
        notify_register_dispatch("com.apple.sessionagent.screenIsLocked", &token, .main) { [weak self] token in
            var state: UInt64 = 0
            guard notify_get_state(token, &state) == NOTIFY_STATUS_OK else { return }
            MainActor.assumeIsolated { self?.set(state != 0, via: "notifyd") }
        }
        tokens.append(token)
        // Unlock is its own key, posted without state.
        notify_register_dispatch("com.apple.sessionagent.screenIsUnlocked", &token, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.set(false, via: "notifyd") }
        }
        tokens.append(token)
        // The lock UI hides ~40 ms earlier (also when the display sleeps), so only a session check.
        notify_register_dispatch("com.apple.sessionagent.screenLockUIIsHidden", &token, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkUnlocked(via: "notifyd") }
        }
        tokens.append(token)
        let center = NSWorkspace.shared.notificationCenter
        for (name, asleep) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false)] {
            displayObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.displayAsleep = asleep
                    self?.updatePoll()
                    if !asleep { self?.checkUnlocked(via: "wake") }
                }
            })
        }
        updatePoll()
    }

    /// The session reported locked since the last lock signal: until then an unlocked reading may
    /// just be loginwindow not having flipped it yet, not a missed unlock.
    private var sessionSawLock = false

    private func checkUnlocked(via channel: String) {
        guard isLocked else { return }
        if LockScreenController.screenIsLockedNow() { sessionSawLock = true } else if sessionSawLock { set(false, via: channel) }
    }

    private func updatePoll() {
        guard isLocked, !displayAsleep else { poll?.invalidate(); poll = nil; return }
        guard poll == nil else { return }
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkUnlocked(via: "poll") }
        }
        poll?.tolerance = 0.2
        if let poll { RunLoop.main.add(poll, forMode: .common) }
    }

    /// Which channel told first, and when, so the other's lag can be logged once.
    private var first: (channel: String, at: TimeInterval)?

    private func set(_ locked: Bool, via channel: String) {
        let now = ProcessInfo.processInfo.systemUptime
        guard locked != isLocked else {
            if let first, first.channel != channel, now - first.at < 10 {
                Log.lock.notice("\(locked ? "Lock" : "Unlock", privacy: .public) via \(first.channel, privacy: .public) first; \(channel, privacy: .public) \(Int(((now - first.at) * 1000).rounded())) ms later")
                self.first = nil
            }
            return
        }
        isLocked = locked
        sessionSawLock = false
        first = (channel, now)
        if !locked { Log.lock.notice("Unlock via \(channel, privacy: .public)") }
        updatePoll()
        changed(locked)
    }

    func cancel() {
        observers.forEach { $0.cancel() }
        observers = []
        displayObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        displayObservers = []
        tokens.forEach { notify_cancel($0) }
        tokens = []
        poll?.invalidate()
        poll = nil
    }
}
