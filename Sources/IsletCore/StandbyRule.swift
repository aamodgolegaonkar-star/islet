import Foundation

/// When Standby may start on its own. Pure, so the rules are testable away from IOKit.
public struct StandbyConditions: Sendable {
    public var enabled: Bool
    public var onPower: Bool
    public var idleSeconds: TimeInterval
    public var idleMinutes: Int
    /// Seconds since Standby was last dismissed (nil: never this session).
    public var sinceDismissed: TimeInterval?
    public var screenLocked: Bool
    public var displayAsleep: Bool
    /// Another app (a video, a presentation) is holding the display awake.
    public var otherAppHoldsDisplay: Bool
    /// Seconds until macOS turns the display off or starts the screen saver by itself (nil:
    /// never). Standby must come first, or it would never get its turn.
    public var systemTimeout: TimeInterval?

    public init(enabled: Bool, onPower: Bool, idleSeconds: TimeInterval, idleMinutes: Int,
                sinceDismissed: TimeInterval?, screenLocked: Bool, displayAsleep: Bool, otherAppHoldsDisplay: Bool,
                systemTimeout: TimeInterval? = nil) {
        self.enabled = enabled
        self.onPower = onPower
        self.idleSeconds = idleSeconds
        self.idleMinutes = idleMinutes
        self.sinceDismissed = sinceDismissed
        self.screenLocked = screenLocked
        self.displayAsleep = displayAsleep
        self.otherAppHoldsDisplay = otherAppHoldsDisplay
        self.systemTimeout = systemTimeout
    }

    /// The idle wait actually used: the chosen minutes, or 20 s before macOS's own timeout
    /// when that comes sooner (never under 15 s).
    public var waitSeconds: TimeInterval {
        let chosen = Double(idleMinutes * 60)
        guard let systemTimeout, systemTimeout > 0 else { return chosen }
        return min(chosen, max(systemTimeout - 20, 15))
    }

    public var shouldStart: Bool {
        guard enabled, onPower, !screenLocked, !displayAsleep, !otherAppHoldsDisplay,
              idleSeconds >= waitSeconds else { return false }
        // After a dismissal, only a fresh idle stretch (one that began after it) counts;
        // otherwise unplugging and replugging would bring it straight back.
        if let sinceDismissed { return idleSeconds < sinceDismissed }
        return true
    }
}
