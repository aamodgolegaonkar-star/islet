import SwiftUI

/// The island's motion vocabulary. Every morph uses one of three springs, so opening,
/// closing and live activities all feel like the same object; and content never just
/// fades: it comes into focus as the shape opens around it, like the iPhone's island.
enum IslandMotion {
    /// Opening: quick, with a small overshoot as the island settles at full size.
    static let open = Animation.spring(duration: 0.46, bounce: 0.24)
    /// Closing: a touch faster and without bounce, so it tucks away cleanly.
    static let close = Animation.spring(duration: 0.38, bounce: 0.04)
    /// Live activities arriving, changing and leaving.
    static let activity = Animation.spring(duration: 0.48, bounce: 0.28)
    /// Small state changes inside the island (hover lift, tuck, style).
    static let subtle = Animation.spring(duration: 0.34, bounce: 0.16)
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
