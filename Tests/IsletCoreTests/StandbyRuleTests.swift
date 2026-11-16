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

    @Test func startsBeforeTheDisplayTurnsOff() {
        var c = ready
        c.idleSeconds = 100
        c.systemTimeout = 120  // display off after 2 min: Standby at 100 s, not 5 min
        #expect(c.waitSeconds == 100)
        #expect(c.shouldStart)
        c.systemTimeout = 10   // absurdly short: still waits 15 s
        #expect(c.waitSeconds == 15)
        c.systemTimeout = nil
        #expect(c.waitSeconds == 300)
        #expect(!c.shouldStart)
    }
}
