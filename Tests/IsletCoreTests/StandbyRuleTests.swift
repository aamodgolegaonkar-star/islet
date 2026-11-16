import Foundation
import Testing
@testable import IsletCore

@Suite("Standby start rule")
struct StandbyRuleTests {
    let ready = StandbyConditions(enabled: true, onPower: true, idleSeconds: 301, idleMinutes: 5,
                                  sinceDismissed: nil, screenLocked: false, displayAsleep: false,
                                  otherAppHoldsDisplay: false)

    @Test func startsWhenIdleOnPower() { #expect(ready.shouldStart) }

    @Test func eachBlockerStopsIt() {
        var c = ready; c.enabled = false; #expect(!c.shouldStart)
        c = ready; c.onPower = false; #expect(!c.shouldStart)
        c = ready; c.idleSeconds = 299; #expect(!c.shouldStart)
        c = ready; c.screenLocked = true; #expect(!c.shouldStart)
        c = ready; c.displayAsleep = true; #expect(!c.shouldStart)
        c = ready; c.otherAppHoldsDisplay = true; #expect(!c.shouldStart)
    }

    @Test func needsAFreshIdleStretchAfterDismissal() {
        var c = ready
        c.sinceDismissed = 100  // idle began before the dismissal (e.g. unplugged, replugged)
        #expect(!c.shouldStart)
        c.sinceDismissed = 400  // dismissed, then left alone for 301 s
        #expect(c.shouldStart)
    }
}
