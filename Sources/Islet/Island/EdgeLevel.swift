import AppKit
import SwiftUI

/// The volume or brightness level as a tall glass slider at the left or right edge of the
/// screen (Settings → Live Activities → Position), instead of in the island.
@MainActor
final class EdgeLevelHUD {
    static let shared = EdgeLevelHUD()

    @Observable
    final class Model {
        var hud = LevelHUD(kind: .volume, value: 0)
        var visible = false
    }

    private let model = Model()
    private var panel: IslandPanel?
    private var hideTask: Task<Void, Never>?
    private static let size = CGSize(width: 64, height: 236)

    func show(_ hud: LevelHUD, on side: LevelPosition) {
        let panel = panel ?? makePanel()
        self.panel = panel
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = screen.visibleFrame
            let x = side == .leftEdge ? frame.minX + 14 : frame.maxX - Self.size.width - 14
            panel.setFrame(CGRect(x: x, y: frame.midY - Self.size.height / 2,
                                  width: Self.size.width, height: Self.size.height), display: false)
        }
        model.hud = hud
        panel.orderFrontRegardless()
        if !model.visible {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { model.visible = true }
        }
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.22)) { self.model.visible = false }
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else { return }
            self.panel?.orderOut(nil)
        }
    }

    private func makePanel() -> IslandPanel {
        let panel = IslandPanel(size: Self.size)
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView: EdgeLevelView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }
}

private struct EdgeLevelView: View {
    let model: EdgeLevelHUD.Model
    private let shape = Capsule()

    var body: some View {
        let hud = model.hud
        let value = hud.muted ? 0 : min(max(hud.value, 0), 1)
        VStack(spacing: 10) {
            Text("\(Int((value * 100).rounded()))")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
                .contentTransition(.numericText())
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule()
                        .fill(hud.kind == .brightness ? Color.yellow.gradient : Color.white.gradient)
                        .frame(height: max(geo.size.width, geo.size.height * value))
                        .opacity(value > 0 ? 1 : 0)
                }
            }
            .frame(width: 10)
            .animation(.spring(response: 0.25, dampingFraction: 0.85), value: value)
            Image(systemName: symbol(hud))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(height: 20)
        }
        .padding(.vertical, 18)
        .frame(width: 48, height: 220)
        .glassEffect(.regular, in: shape)
        .environment(\.colorScheme, .dark)
        .scaleEffect(model.visible ? 1 : 0.8)
        .opacity(model.visible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func symbol(_ hud: LevelHUD) -> String {
        switch hud.kind {
        case .brightness: hud.value < 0.5 ? "sun.min.fill" : "sun.max.fill"
        case .volume:
            if hud.muted || hud.value == 0 { "speaker.slash.fill" }
            else if hud.value < 0.34 { "speaker.wave.1.fill" }
            else if hud.value < 0.67 { "speaker.wave.2.fill" }
            else { "speaker.wave.3.fill" }
        }
    }
}
