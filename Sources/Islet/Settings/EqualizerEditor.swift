import AppKit
import SwiftUI

/// Ten vertical band sliders and a preamp, like the Music app's equalizer.
struct EqualizerEditor: View {
    @Bindable var settings: AppSettings

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Picker("Preset", selection: presetBinding) {
                    Text("Custom").tag(EqualizerPreset?.none)
                    ForEach(EqualizerPreset.allCases) { Text($0.title).tag(EqualizerPreset?.some($0)) }
                }
                .frame(maxWidth: 240)
                Spacer()
                Button("Reset") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { settings.applyEqualizer(.flat) }
                }
                .disabled(settings.equalizerBands == Equalizer.flat && settings.equalizerPreamp == 0)
            }
            HStack(alignment: .bottom, spacing: 0) {
                band(label: "Pre", value: Binding(get: { settings.equalizerPreamp },
                                                   set: { settings.equalizerPreamp = $0; settings.equalizerPreset = nil }))
                Divider().frame(height: 120).padding(.horizontal, 6)
                ForEach(Equalizer.frequencies.indices, id: \.self) { index in
                    band(label: Equalizer.label(Equalizer.frequencies[index]), value: Binding(
                        get: { settings.equalizerBands[index] },
                        set: {
                            settings.equalizerBands[index] = $0
                            settings.equalizerPreset = nil
                        }))
                }
            }
        }
    }

    private var presetBinding: Binding<EqualizerPreset?> {
        Binding(get: { settings.equalizerPreset },
                set: { preset in
                    guard let preset else { return }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { settings.applyEqualizer(preset) }
                })
    }

    private func band(label: String, value: Binding<Double>) -> some View {
        VStack(spacing: 6) {
            Text(value.wrappedValue == 0 ? "0" : String(format: "%+.0f", value.wrappedValue))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            VerticalSlider(value: value, range: Equalizer.gainRange)
                .frame(width: 22, height: 120)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A vertical slider snapping to half-decibel steps; double-click returns it to 0.
private struct VerticalSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let span = range.upperBound - range.lowerBound
            let fraction = (value - range.lowerBound) / span
            let thumbY = height * (1 - fraction)
            let zeroY = height * (1 - (0 - range.lowerBound) / span)
            ZStack(alignment: .top) {
                Capsule().fill(.quaternary).frame(width: 4).frame(maxHeight: .infinity)
                Capsule().fill(Color.accentColor)
                    .frame(width: 4, height: abs(thumbY - zeroY))
                    .offset(y: min(thumbY, zeroY))
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                    .frame(width: 16, height: 16)
                    .offset(y: thumbY - 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let position = min(max(drag.location.y / height, 0), 1)
                let raw = range.upperBound - position * span
                value = (raw * 2).rounded() / 2
            })
            .onTapGesture(count: 2) { value = 0 }
        }
    }
}

/// Whether Islet may hear the music (System Settings → Privacy & Security → Screen &
/// System Audio Recording → System Audio Recording Only), with a shortcut there.
struct AudioAccessRow: View {
    @State private var granted = AudioCapturePermission.status == .granted

    var body: some View {
        HStack {
            Label(granted ? "Audio access allowed" : "Islet needs System Audio Recording access",
                  systemImage: granted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? AnyShapeStyle(.green) : AnyShapeStyle(.orange))
            Spacer()
            if !granted {
                Button("Open Privacy Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .task {
            // Notice the switch being turned on while Settings is open.
            while !Task.isCancelled, !granted {
                try? await Task.sleep(for: .seconds(1.5))
                granted = AudioCapturePermission.status == .granted
            }
        }
    }
}
