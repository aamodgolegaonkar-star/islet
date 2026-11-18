import AppKit
import SwiftUI

/// Ten vertical band sliders and a preamp, like the Music app's equalizer.
struct EqualizerEditor: View {
    @Bindable var settings: AppSettings
    /// With a curve per app: editing Spotify's instead of Apple Music's.
    @State private var spotify = false

    /// The curve being edited.
    private var curve: Binding<EqualizerCurve> {
        Binding(get: { spotify && settings.equalizerPerApp ? settings.spotifyEqualizer : settings.equalizer(for: nil) },
                set: { curve in
                    if spotify && settings.equalizerPerApp {
                        settings.spotifyEqualizer = curve
                    } else {
                        settings.equalizerBands = curve.bands
                        settings.equalizerPreamp = curve.preamp
                        settings.equalizerPreset = curve.preset
                    }
                })
    }

    var body: some View {
        VStack(spacing: 10) {
            Toggle("Separate for Apple Music and Spotify", isOn: $settings.equalizerPerApp.animation(IslandMotion.subtle))
            if settings.equalizerPerApp {
                Picker("App", selection: $spotify.animation(IslandMotion.subtle)) {
                    Text("Apple Music").tag(false)
                    Text("Spotify").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            HStack {
                Picker("Preset", selection: presetBinding) {
                    Text("Custom").tag(EqualizerPreset?.none)
                    ForEach(EqualizerPreset.allCases) { Text($0.title).tag(EqualizerPreset?.some($0)) }
                }
                .frame(maxWidth: 240)
                Spacer()
                Button("Reset") {
                    withAnimation(IslandMotion.subtle) { curve.wrappedValue = EqualizerCurve(bands: EqualizerPreset.flat.bands, preamp: 0, preset: .flat) }
                }
                .disabled(curve.wrappedValue.bands == Equalizer.flat && curve.wrappedValue.preamp == 0)
            }
            HStack(alignment: .bottom, spacing: 0) {
                band(label: "Pre", value: Binding(get: { curve.wrappedValue.preamp },
                                                   set: { curve.wrappedValue.preamp = $0; curve.wrappedValue.preset = nil }))
                Divider().frame(height: 120).padding(.horizontal, 6)
                ForEach(Equalizer.frequencies.indices, id: \.self) { index in
                    band(label: Equalizer.label(Equalizer.frequencies[index]), value: Binding(
                        get: { curve.wrappedValue.bands[index] },
                        set: {
                            curve.wrappedValue.bands[index] = $0
                            curve.wrappedValue.preset = nil
                        }))
                }
            }
        }
    }

    private var presetBinding: Binding<EqualizerPreset?> {
        Binding(get: { curve.wrappedValue.preset },
                set: { preset in
                    guard let preset else { return }
                    withAnimation(IslandMotion.subtle) {
                        curve.wrappedValue = EqualizerCurve(bands: preset.bands, preamp: preset.preamp, preset: preset)
                    }
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
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Label(granted ? "Audio access allowed" : "Islet needs System Audio Recording access",
                      systemImage: granted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(granted ? AnyShapeStyle(.green) : AnyShapeStyle(.orange))
                if !granted {
                    // macOS asks only apps signed by a registered developer, so this is a
                    // one-time switch instead of a prompt.
                    Text("In Privacy Settings, turn on Islet under System Audio Recording Only. If it isn't listed, click + and choose Islet from Applications.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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
