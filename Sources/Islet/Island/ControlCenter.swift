import SwiftUI

/// Control Center in the island: round switches on the left; volume, brightness and a row
/// of actions on the right, like the iPhone's, sized to the open island.
struct ControlCenterView: View {
    let model: IslandModel
    let store: PlayerStore
    var notchHeight: CGFloat?
    let showMusic: () -> Void
    let showShelf: (() -> Void)?
    private var controls: SystemControls { .shared }
    @Environment(\.clickRouter) private var router
    @State private var brightness = BrightnessMonitor.shared.level ?? 0.5
    /// The volume being dragged to; late reports from the audio device can't pull it back.
    @State private var draggedVolume: Double?

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
                Grid(horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        toggle("Wi-Fi", symbol: controls.wifiOn ? "wifi" : "wifi.slash", on: controls.wifiOn,
                               tint: .blue, id: "cc.wifi", action: controls.toggleWiFi)
                        toggle(controls.bluetoothAllowed ? "Bluetooth" : "Allow…", symbol: "dot.radiowaves.left.and.right",
                               on: controls.bluetoothOn && controls.bluetoothAllowed,
                               tint: .blue, id: "cc.bluetooth", action: controls.toggleBluetooth)
                            .opacity(controls.bluetoothAllowed ? 1 : 0.55)
                            .help(controls.bluetoothAllowed ? "Bluetooth" : "Allow Islet to use Bluetooth in System Settings")
                    }
                    GridRow {
                        toggle("Dark", symbol: "circle.lefthalf.filled", on: controls.darkMode,
                               tint: .indigo, id: "cc.dark", action: controls.toggleDarkMode)
                        toggle("Awake", symbol: "cup.and.heat.waves.fill", on: controls.keepAwake,
                               tint: .orange, id: "cc.awake", action: controls.toggleKeepAwake)
                    }
                }
                VStack(spacing: 16) {
                    level(symbol: volumeSymbol, value: draggedVolume ?? store.volume, tint: .white,
                          editing: { draggedVolume = $0 ? store.volume : nil }) {
                        draggedVolume = $0
                        store.setVolume($0)
                    }
                    level(symbol: "sun.max.fill", value: brightness, tint: .yellow) {
                        brightness = $0
                        BrightnessMonitor.shared.set($0)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        action("Lock Screen", symbol: "lock.fill", id: "cc.lock", run: controls.lockScreen)
                        action("Screenshot", symbol: "camera.viewfinder", id: "cc.screenshot", run: controls.screenshot)
                        OutputButton(model: model, diameter: 28)
                        Spacer()
                        if let showShelf { action("Shelf", symbol: "tray.full.fill", id: "cc.shelf", run: showShelf) }
                        if store.hasTrack { action("Now Playing", symbol: "music.note", id: "cc.music", run: showMusic) }
                    }
                }
                .padding(.top, 12)
        }
        .padding(.top, (notchHeight ?? 0) + 16)
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
        .onAppear {
            controls.refresh()
            brightness = BrightnessMonitor.shared.level ?? brightness
        }
    }

    /// A round switch with its name underneath; filled with its color while on. It sinks
    /// slightly under a press and springs back on release, so every click is felt at once.
    private func toggle(_ title: String, symbol: String, on: Bool, tint: Color, id: String,
                        action: @escaping () -> Void) -> some View {
        let pressed = router?.pressed == id
        return Button(action: ClickRouter.guarded(router, id, action)) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(on ? .white : .white.opacity(0.85))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(on ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(.white.opacity(0.14))))
                    .brightness(pressed ? -0.12 : 0)
                    .scaleEffect(pressed ? 0.88 : (on ? 1 : 0.96))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .contentShape(Rectangle())
            .animation(IslandMotion.subtle, value: on)
            .animation(.spring(duration: 0.18, bounce: 0.3), value: pressed)
        }
        .buttonStyle(.plain)
        .routedClick(id, action: action)
        .help(title)
    }

    private func level(symbol: String, value: Double, tint: Color, editing: @escaping (Bool) -> Void = { _ in },
                       set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 18)
            GlassSlider(value: value, tint: tint, restHeight: 4, thumb: .always,
                        onEditingChanged: { active in
                            editing(active)
                            model.isInteracting = active
                            if !active { model.interactionEnded() }
                        },
                        onChange: set, onCommit: set)
        }
    }

    private func action(_ help: String, symbol: String, id: String, run: @escaping () -> Void) -> some View {
        Button(action: ClickRouter.guarded(router, id, run)) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(GlassIconButtonStyle(diameter: 28, look: .highlight))
        .routedClick(id, action: run)
        .help(help)
    }

    private var volumeSymbol: String {
        switch store.volume {
        case 0: "speaker.slash.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }
}

/// A small labelled capsule in the open island (the shelf and Control Center buttons).
struct IslandPillButton: View {
    @Environment(\.clickRouter) private var router
    let label: String?
    let symbol: String
    let help: String
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: ClickRouter.guarded(router, id, action)) {
            Group {
                if let label { Label(label, systemImage: symbol) } else { Image(systemName: symbol) }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(.white.opacity(0.12)))
        .routedClick(id, action: action)
        .help(help)
    }
}
