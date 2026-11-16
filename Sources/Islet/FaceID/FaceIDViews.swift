import SwiftUI

/// The Face ID mark, alive: a ring of dots circles the face while it looks, it becomes a
/// green tick when it knows you, and shakes red when the password is needed.
struct FaceIDMark: View {
    let phase: FaceScanPhase
    var size: CGFloat = 22
    @State private var shake = 0

    var body: some View {
        ZStack {
            if phase == .matched {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.62, weight: .bold))
                    .foregroundStyle(.green)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            } else {
                Image(systemName: "faceid")
                    .font(.system(size: size * 0.82, weight: .regular))
                    .foregroundStyle(phase == .needsPassword ? Color.red : .white)
                    .symbolEffect(.pulse, options: .repeating, isActive: phase == .scanning)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            if phase == .scanning {
                TimelineView(.animation) { timeline in
                    let turn = timeline.date.timeIntervalSinceReferenceDate * 250
                    ZStack {
                        ForEach(0..<12, id: \.self) { index in
                            Circle()
                                .fill(.white)
                                .frame(width: max(1.5, size * 0.075), height: max(1.5, size * 0.075))
                                .offset(y: -size * 0.66)
                                .rotationEffect(.degrees(Double(index) * 30))
                                .opacity(0.15 + Double(index) / 14)
                        }
                    }
                    .rotationEffect(.degrees(turn))
                }
                .transition(.opacity)
            }
        }
        .frame(width: size * 1.5, height: size * 1.5)
        .modifier(FaceShake(shakes: CGFloat(shake)))
        .animation(IslandMotion.playful, value: phase)
        .animation(.linear(duration: 0.45), value: shake)
        .onChange(of: phase) { _, next in if next == .needsPassword { shake += 1 } }
    }
}

private struct FaceShake: GeometryEffect {
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let progress = shakes - shakes.rounded(.down)
        return ProjectionTransform(CGAffineTransform(translationX: 7 * (1 - progress) * sin(progress * .pi * 6), y: 0))
    }
}

/// The lock-screen island while Face ID looks: the padlock on one side, the living Face ID
/// mark on the other.
struct FaceScanContent: View {
    let phase: FaceScanPhase

    var body: some View {
        HStack {
            Image(systemName: phase == .matched ? "lock.open.fill" : "lock.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 24)
            Spacer(minLength: 0)
            FaceIDMark(phase: phase, size: 17)
        }
        .padding(.horizontal, 12)
    }
}

/// The unlock moment after Face ID: the face is recognised (the ring of dots, then a
/// tick), then it turns into an open padlock as "Unlocked" fades in.
struct FaceUnlockContent: View {
    private enum Step { case scanning, recognised, open }
    @State private var step = Step.scanning

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                FaceIDMark(phase: step == .scanning ? .scanning : .matched, size: 17)
                    .scaleEffect(step == .open ? 0.5 : 1)
                    .opacity(step == .open ? 0 : 1)
                Image(systemName: "lock.open.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.bounce, value: step == .open)
                    .scaleEffect(step == .open ? 1 : 0.5)
                    .opacity(step == .open ? 1 : 0)
            }
            .frame(width: 26)
            Spacer(minLength: 6)
            Text("Unlocked")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .opacity(step == .open ? 1 : 0)
                .offset(x: step == .open ? 0 : 6)
        }
        .padding(.horizontal, 12)
        .task {
            try? await Task.sleep(for: .milliseconds(260))
            withAnimation(IslandMotion.playful) { step = .recognised }
            try? await Task.sleep(for: .milliseconds(480))
            withAnimation(IslandMotion.playful) { step = .open }
        }
    }
}

@MainActor
@Observable
final class FaceHUDState {
    var phase = FaceScanPhase.scanning
}

/// "A big, clean square with the Face ID mark", in the middle of the lock screen.
struct FaceIDHUDView: View {
    let state: FaceHUDState

    var body: some View {
        VStack(spacing: 14) {
            FaceIDMark(phase: state.phase, size: 62)
            Text(caption)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .contentTransition(.opacity)
        }
        .frame(width: 170, height: 170)
        .background(RoundedRectangle(cornerRadius: 38, style: .continuous).fill(.black.opacity(0.72)))
        .overlay(RoundedRectangle(cornerRadius: 38, style: .continuous).stroke(.white.opacity(0.12)))
        .frame(width: 190, height: 190)
    }

    private var caption: String {
        switch state.phase {
        case .scanning: "Face ID"
        case .matched: "Welcome back"
        case .needsPassword: "Enter your password"
        }
    }
}
