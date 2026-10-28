import Foundation

/// An sRGB color with components in 0...1.
public struct RGB: Sendable, Equatable, Hashable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    public var hsb: (h: Double, s: Double, b: Double) {
        let maxC = max(r, g, b), minC = min(r, g, b), delta = maxC - minC
        var hue = 0.0
        if delta > 0 {
            if maxC == r { hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            else if maxC == g { hue = (b - r) / delta + 2 }
            else { hue = (r - g) / delta + 4 }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return (hue, maxC == 0 ? 0 : delta / maxC, maxC)
    }

    public init(hue: Double, saturation: Double, brightness: Double) {
        let h = (hue - floor(hue)) * 6, s = min(max(saturation, 0), 1), v = min(max(brightness, 0), 1)
        let c = v * s, x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)), m = v - c
        let (r1, g1, b1): (Double, Double, Double)
        switch Int(h) {
        case 0: (r1, g1, b1) = (c, x, 0)
        case 1: (r1, g1, b1) = (x, c, 0)
        case 2: (r1, g1, b1) = (0, c, x)
        case 3: (r1, g1, b1) = (0, x, c)
        case 4: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        self.init(r1 + m, g1 + m, b1 + m)
    }

    public func mixed(with other: RGB, _ t: Double) -> RGB {
        RGB(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t)
    }

    fileprivate func distanceSquared(_ o: RGB) -> Double {
        let dr = r - o.r, dg = g - o.g, db = b - o.b
        return dr * dr + dg * dg + db * db
    }
}

/// Colors derived from album artwork for backgrounds and accents.
public struct Palette: Sendable, Equatable {
    /// Background colors, most dominant first, tuned so white text stays readable.
    public var colors: [RGB]
    /// A vivid color that reads well on black (used for the island's equalizer).
    public var accent: RGB

    public init(colors: [RGB], accent: RGB) {
        self.colors = colors
        self.accent = accent
    }

    public static let fallback = Palette(
        colors: [RGB(0.36, 0.16, 0.42), RGB(0.12, 0.20, 0.45), RGB(0.55, 0.18, 0.30), RGB(0.10, 0.10, 0.18)],
        accent: RGB(0.98, 0.36, 0.48)
    )

    public func mixed(with other: Palette, _ t: Double) -> Palette {
        let count = max(colors.count, other.colors.count)
        let blended = (0..<count).map { i in
            colors[i % colors.count].mixed(with: other.colors[i % other.colors.count], t)
        }
        return Palette(colors: blended, accent: accent.mixed(with: other.accent, t))
    }
}

/// Deterministic k-means palette extraction over a small pixel sample.
public enum PaletteExtractor {
    public static func palette(from pixels: [RGB], clusters k: Int = 5, iterations: Int = 10) -> Palette {
        guard pixels.count >= k else { return .fallback }

        // Farthest-point initialisation keeps results stable and spread out.
        var centroids = [pixels[pixels.count / 2]]
        while centroids.count < k {
            let next = pixels.max { a, b in
                centroids.map(a.distanceSquared).min()! < centroids.map(b.distanceSquared).min()!
            }!
            centroids.append(next)
        }

        var assignment = [Int](repeating: 0, count: pixels.count)
        for _ in 0..<iterations {
            for (i, p) in pixels.enumerated() {
                var bestIndex = 0, bestDistance = Double.infinity
                for (j, c) in centroids.enumerated() {
                    let d = p.distanceSquared(c)
                    if d < bestDistance { bestDistance = d; bestIndex = j }
                }
                assignment[i] = bestIndex
            }
            var sums = [RGB](repeating: RGB(0, 0, 0), count: k), counts = [Int](repeating: 0, count: k)
            for (i, p) in pixels.enumerated() {
                let j = assignment[i]
                sums[j] = RGB(sums[j].r + p.r, sums[j].g + p.g, sums[j].b + p.b)
                counts[j] += 1
            }
            for j in 0..<k where counts[j] > 0 {
                let n = Double(counts[j])
                centroids[j] = RGB(sums[j].r / n, sums[j].g / n, sums[j].b / n)
            }
        }

        var counts = [Int](repeating: 0, count: k)
        for a in assignment { counts[a] += 1 }
        let ranked = zip(centroids, counts).filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        let total = Double(pixels.count)

        let background = ranked.map { color, _ -> RGB in
            let (h, s, v) = color.hsb
            let saturation = s < 0.08 ? s : min(1, s * 1.18 + 0.04)
            return RGB(hue: h, saturation: saturation, brightness: min(max(v, 0.20), 0.74))
        }

        let accentSource = ranked.max { a, b in
            score(a.0, share: Double(a.1) / total) < score(b.0, share: Double(b.1) / total)
        }?.0 ?? Palette.fallback.accent
        let (h, s, v) = accentSource.hsb
        let accent = s < 0.12
            ? RGB(hue: h, saturation: s, brightness: max(v, 0.85))
            : RGB(hue: h, saturation: max(s, 0.55), brightness: max(v, 0.82))

        var colors = background
        while colors.count < 3 { colors.append(colors.last ?? Palette.fallback.colors[0]) }
        return Palette(colors: colors, accent: accent)
    }

    private static func score(_ color: RGB, share: Double) -> Double {
        let (_, s, v) = color.hsb
        return s * v * (0.25 + share)
    }
}

/// "m:ss" style labels for playback times.
public enum TimeText {
    public static func string(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    public static func remaining(_ elapsed: TimeInterval, duration: TimeInterval) -> String {
        "-" + string(max(0, duration.rounded(.down) - elapsed.rounded(.down)))
    }
}

extension RGB {
    /// "#RRGGBB" or "#RRGGBBAA" (alpha is ignored), as colors are saved in Settings.
    public init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits.prefix(6), radix: 16) else { return nil }
        self.init(Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    public var hex: String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}

extension Palette {
    /// Bright versions of the album's colors for light (the screen-edge glow): the accent
    /// first, then each background color at full brightness and at least medium saturation.
    /// Grays would only dull the light, so they're left out unless the cover has nothing
    /// else, when it glows a soft white. Near-duplicates are dropped.
    public var glowColors: [RGB] {
        // Chroma (how far apart the channels are), not saturation: a near-black with a faint
        // tint has high saturation but no real color, and brightening it would invent one.
        func isColorful(_ color: RGB) -> Bool { max(color.r, color.g, color.b) - min(color.r, color.g, color.b) >= 0.08 }
        let all = [accent] + colors
        let colorful = all.filter(isColorful)
        var glow: [RGB] = []
        for color in colorful.isEmpty ? all : colorful {
            let (h, s, _) = color.hsb
            let bright = RGB(hue: h, saturation: isColorful(color) ? max(s, 0.55) : 0, brightness: 1)
            if !glow.contains(where: { $0.distanceSquared(bright) < 0.04 }) { glow.append(bright) }
        }
        return glow
    }
}
