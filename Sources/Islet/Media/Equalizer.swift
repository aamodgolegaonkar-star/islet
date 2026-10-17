import Foundation

/// The equalizer's bands and presets, and the filter math (RBJ Audio EQ Cookbook biquads).
enum Equalizer {
    /// Centre frequencies of the ten bands, an octave apart.
    static let frequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let gainRange: ClosedRange<Double> = -12...12
    static let flat = [Double](repeating: 0, count: frequencies.count)

    /// Band labels for the sliders.
    static func label(_ frequency: Double) -> String {
        frequency >= 1000 ? "\(Int(frequency / 1000))k" : "\(Int(frequency))"
    }

    /// Coefficients of one band (b0, b1, b2, a1, a2, normalised by a0). The lowest band is a
    /// low shelf, the highest a high shelf, the rest peaks one octave wide.
    static func coefficients(band: Int, gain: Double, sampleRate: Double) -> [Float] {
        guard gain != 0, sampleRate > 0 else { return [1, 0, 0, 0, 0] }
        let frequency = min(frequencies[band], sampleRate * 0.45)
        let a = pow(10, gain / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let cosW = cos(w0), sinW = sin(w0)
        var b0, b1, b2, a0, a1, a2: Double
        if band == 0 || band == frequencies.count - 1 {
            // Shelf with slope 1.
            let alpha = sinW / 2 * sqrt(2)
            let root = 2 * sqrt(a) * alpha
            if band == 0 {
                b0 = a * ((a + 1) - (a - 1) * cosW + root)
                b1 = 2 * a * ((a - 1) - (a + 1) * cosW)
                b2 = a * ((a + 1) - (a - 1) * cosW - root)
                a0 = (a + 1) + (a - 1) * cosW + root
                a1 = -2 * ((a - 1) + (a + 1) * cosW)
                a2 = (a + 1) + (a - 1) * cosW - root
            } else {
                b0 = a * ((a + 1) + (a - 1) * cosW + root)
                b1 = -2 * a * ((a - 1) + (a + 1) * cosW)
                b2 = a * ((a + 1) + (a - 1) * cosW - root)
                a0 = (a + 1) - (a - 1) * cosW + root
                a1 = 2 * ((a - 1) - (a + 1) * cosW)
                a2 = (a + 1) - (a - 1) * cosW - root
            }
        } else {
            let alpha = sinW / (2 * 1.41)
            b0 = 1 + alpha * a
            b1 = -2 * cosW
            b2 = 1 - alpha * a
            a0 = 1 + alpha / a
            a1 = -2 * cosW
            a2 = 1 - alpha / a
        }
        return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0].map { Float($0) }
    }
}

enum EqualizerPreset: String, CaseIterable, Identifiable {
    case flat, bassBoost, bassReducer, trebleBoost, vocal, rock, pop, electronic, acoustic, lateNight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flat: "Flat"
        case .bassBoost: "Bass Boost"
        case .bassReducer: "Bass Reducer"
        case .trebleBoost: "Treble Boost"
        case .vocal: "Vocal"
        case .rock: "Rock"
        case .pop: "Pop"
        case .electronic: "Electronic"
        case .acoustic: "Acoustic"
        case .lateNight: "Late Night"
        }
    }

    var bands: [Double] {
        switch self {
        case .flat: Equalizer.flat
        case .bassBoost: [6, 5, 4, 2.5, 1, 0, 0, 0, 0, 0]
        case .bassReducer: [-6, -5, -4, -2.5, -1, 0, 0, 0, 0, 0]
        case .trebleBoost: [0, 0, 0, 0, 0, 1, 2.5, 4, 5, 6]
        case .vocal: [-2, -2, -1, 1, 3, 4, 3.5, 2, 0.5, -1]
        case .rock: [4.5, 3.5, 2, 0.5, -1, -0.5, 1.5, 3, 4, 4.5]
        case .pop: [-1, 0, 1.5, 3, 4, 3, 1, 0, -0.5, -1]
        case .electronic: [4.5, 4, 1.5, 0, -1.5, 1.5, 0.5, 1.5, 4, 5]
        case .acoustic: [4, 3.5, 2.5, 1, 1.5, 1.5, 3, 3.5, 3, 2]
        case .lateNight: [-3, -2, 0, 2, 3, 3, 2, 0, -2, -3]
        }
    }

    /// Headroom for presets that boost, so loud passages don't clip.
    var preamp: Double {
        let peak = bands.max() ?? 0
        return peak > 0 ? -(peak * 0.75).rounded() : 0
    }
}
