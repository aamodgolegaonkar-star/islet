import SwiftUI

/// The open island's output button: the current output's glyph, plus the headphones'
/// noise-control mode when they have it. A click opens the output picker.
struct OutputButton: View {
    let model: IslandModel
    var diameter: CGFloat?
    @Environment(\.clickRouter) private var router
    @State private var anchor = ShareAnchor.Holder()
    private var status: OutputStatus { .shared }

    var body: some View {
        RoutedButton(id, action: open) { content }
            .background(ShareAnchor(holder: anchor))
        .help(status.name.isEmpty ? "Sound Output" : "Playing on \(status.name)")
        .onAppear { status.refresh() }
    }

    private var id: String { diameter == nil ? "island.output" : "cc.output" }

    @ViewBuilder
    private var content: some View {
        if let diameter {
            Image(systemName: status.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(.white.opacity(router?.pressed == id ? 0.22 : 0.12)))
        } else {
            HStack(spacing: 4) {
                Image(systemName: status.symbol)
                if let mode = status.listeningMode, mode != .off {
                    Image(systemName: mode.symbol)
                        .foregroundStyle(mode == .noiseCancellation ? Color.cyan : .green)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .contentTransition(.symbolEffect(.replace))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(.white.opacity(0.12)))
            .animation(IslandMotion.subtle, value: status.listeningMode)
        }
    }

    private func open() {
        guard let view = anchor.view else { return }
        model.isInteracting = true
        OutputMenu.shared.show(from: view)
        model.isInteracting = false
        model.interactionEnded()
        // A switch takes a moment to land.
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            status.refresh()
        }
    }
}
