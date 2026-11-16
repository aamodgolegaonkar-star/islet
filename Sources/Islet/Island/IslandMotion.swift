import AppKit
import SwiftUI

/// The island's motion vocabulary. Every morph uses one of three springs, so opening,
/// closing and live activities all feel like the same object; and content never just
/// fades: it comes into focus as the shape opens around it, like the iPhone's island.
enum IslandMotion {
    /// System Settings → Accessibility → Display → Reduce motion. Every token below
    /// collapses to a short, bounce-free fade-in-place when it's on.
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// `full`, or the Reduce Motion fade. For curves tuned to something else (the music).
    static func respecting(_ full: Animation) -> Animation {
        reduced ? .easeOut(duration: 0.16) : full
    }

    /// Opening: quick, with a small overshoot as the island settles at full size.
    static var open: Animation { respecting(.spring(duration: 0.46, bounce: 0.24)) }
    /// Closing: a touch faster and without bounce, so it tucks away cleanly.
    static var close: Animation { respecting(.spring(duration: 0.38, bounce: 0.04)) }
    /// Live activities arriving, changing and leaving.
    static var activity: Animation { respecting(.spring(duration: 0.48, bounce: 0.28)) }
    /// Small state changes inside the island (hover lift, tuck, style).
    static var subtle: Animation { respecting(.spring(duration: 0.34, bounce: 0.16)) }

    // App-wide, outside the island: one vocabulary for every surface.

    /// Presses, hovers, toggles, HUD values: things touched many times a day.
    static var quick: Animation { respecting(.spring(duration: 0.24, bounce: 0.08)) }
    /// Cards, panels, pages and sheets moving or resizing.
    static var panel: Animation { respecting(.spring(duration: 0.5, bounce: 0.14)) }
    /// Rare, happy moments (unlocking, a Portal drop, Standby): a livelier bounce.
    static var playful: Animation { respecting(.spring(duration: 0.6, bounce: 0.36)) }
    /// Something fading out of the way: exits are quicker and quieter than entrances.
    static var exit: Animation { .easeIn(duration: reduced ? 0.12 : 0.16) }
}

extension View {
    /// Drops in from the notch each time `trigger` changes, like it fell onto this desktop.
    func islandArrival(_ trigger: Int) -> some View {
        keyframeAnimator(initialValue: ArrivalFrame(), trigger: trigger) { content, frame in
            // A non-finite scale reaching AppKit aborts the app, so never pass one on.
            content
                .scaleEffect(frame.scale.isFinite ? frame.scale : 1, anchor: .top)
                .offset(y: frame.y.isFinite ? frame.y : 0)
                .opacity(frame.opacity.isFinite ? frame.opacity : 1)
        } keyframes: { _ in
            let reduced = IslandMotion.reduced
            KeyframeTrack(\.opacity) {
                MoveKeyframe(0)
                CubicKeyframe(1, duration: reduced ? 0.2 : 0.18)
            }
            KeyframeTrack(\.scale) {
                MoveKeyframe(reduced ? 1 : 0.82)
                SpringKeyframe(1, duration: 0.55, spring: .init(duration: 0.5, bounce: reduced ? 0 : 0.42))
            }
            KeyframeTrack(\.y) {
                MoveKeyframe(reduced ? 0 : -14)
                SpringKeyframe(0, duration: 0.55, spring: .init(duration: 0.45, bounce: reduced ? 0 : 0.3))
            }
        }
    }
}

struct ArrivalFrame {
    var scale: CGFloat = 1
    var y: CGFloat = 0
    var opacity: Double = 1
}

extension AnyTransition {
    /// Content arriving: it trails the shape slightly, then sharpens from a blur while
    /// growing into place from the top. Leaving: it blurs out quickly before the shape
    /// closes over it.
    static func materialize(delay: Double = 0.06) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(active: Focus(amount: 1), identity: Focus(amount: 0))
                .animation(.spring(duration: 0.4, bounce: 0.1).delay(delay)),
            removal: .modifier(active: Focus(amount: 0.7), identity: Focus(amount: 0))
                .animation(.easeIn(duration: 0.13)))
    }
}

/// How far out of focus content is: 0 is sharp and in place, 1 is blurred, shrunk, gone.
private struct Focus: ViewModifier {
    let amount: Double

    func body(content: Content) -> some View {
        content
            .blur(radius: amount * 7)
            .scaleEffect(1 - amount * 0.08, anchor: .top)
            .opacity(1 - amount)
    }
}
