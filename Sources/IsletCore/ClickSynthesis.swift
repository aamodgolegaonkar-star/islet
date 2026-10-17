import Foundation

/// Procedural lock / unlock clicks in the character of a phone's side button: a bright
/// transient over a short, slightly falling "thock". Original synthesis — no Apple audio.
public enum ClickSynthesis {
    public enum Style: Sendable {
        case lock
        case unlock
    }

    public static let sampleRate = 48_000.0
    public static let peak: Float = 0.82

    /// Mono samples in -1...1 at `sampleRate`.
    public static func samples(_ style: Style) -> [Float] {
        let length = style == .lock ? 0.13 : 0.17
        var out = [Float](repeating: 0, count: Int(sampleRate * length))
        switch style {
        case .lock:
            addClick(&out, at: 0, gain: 1, body: 300, bright: 2_150)
        case .unlock:
            addClick(&out, at: 0, gain: 0.62, body: 380, bright: 2_600)
            addClick(&out, at: 0.062, gain: 0.5, body: 460, bright: 3_000)
        }
        // Soft-clip, then normalise to a comfortable peak.
        for i in out.indices { out[i] = tanhf(out[i] * 1.4) }
        let loudest = out.map(abs).max() ?? 0
        if loudest > 0 {
            for i in out.indices { out[i] *= peak / loudest }
        }
        return out
    }

    /// The click as a 16-bit mono WAV file, for players that take encoded audio.
    public static func wav(_ style: Style) -> Data {
        let pcm = samples(style).map { Int16((max(-1, min(1, $0)) * Float(Int16.max)).rounded()) }
        let dataSize = UInt32(pcm.count * 2)
        var out = Data()
        out.reserveCapacity(44 + pcm.count * 2)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        }
        out.append(contentsOf: Array("RIFF".utf8))
        append(36 + dataSize)
        out.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))                 // format chunk size
        append(UInt16(1))                  // linear PCM
        append(UInt16(1))                  // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate) * 2)     // bytes per second
        append(UInt16(2))                  // bytes per frame
        append(UInt16(16))                 // bits per sample
        out.append(contentsOf: Array("data".utf8))
        append(dataSize)
        for sample in pcm { append(sample) }
        return out
    }

    private static func addClick(_ out: inout [Float], at start: Double, gain: Double, body: Double, bright: Double) {
        var seed: UInt32 = 0x1234_5678
        var highPassed = 0.0, lastNoise = 0.0
        for i in Int(start * sampleRate)..<out.count {
            let t = Double(i) / sampleRate - start
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Double(seed >> 8) / Double(1 << 24) * 2 - 1
            highPassed = 0.86 * (highPassed + noise - lastNoise)
            lastNoise = noise
            let transient = highPassed * exp(-t / 0.0011) * 0.9
            let ping = sin(2 * .pi * bright * t) * exp(-t / 0.0055) * 0.32
            let falling = body * (1 - 0.18 * min(t / 0.05, 1))
            let thock = sin(2 * .pi * falling * t) * exp(-t / 0.024) * 0.75
            let sub = sin(2 * .pi * 105 * t) * exp(-t / 0.035) * 0.3
            out[i] += Float(gain * (transient + ping + thock + sub))
        }
    }
}
