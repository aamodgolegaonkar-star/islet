namespace Islet.Core;

/// An sRGB color with components in 0...1.
public readonly record struct RGB(double R, double G, double B)
{
    public (double H, double S, double B) Hsb
    {
        get
        {
            double maxC = Math.Max(R, Math.Max(G, B)), minC = Math.Min(R, Math.Min(G, B)), delta = maxC - minC;
            var hue = 0.0;
            if (delta > 0)
            {
                if (maxC == R) hue = ((G - B) / delta) % 6;
                else if (maxC == G) hue = (B - R) / delta + 2;
                else hue = (R - G) / delta + 4;
                hue /= 6;
                if (hue < 0) hue += 1;
            }
            return (hue, maxC == 0 ? 0 : delta / maxC, maxC);
        }
    }

    public static RGB FromHsb(double hue, double saturation, double brightness)
    {
        double h = (hue - Math.Floor(hue)) * 6, s = Math.Clamp(saturation, 0, 1), v = Math.Clamp(brightness, 0, 1);
        double c = v * s, x = c * (1 - Math.Abs(h % 2 - 1)), m = v - c;
        var (r1, g1, b1) = (int)h switch
        {
            0 => (c, x, 0.0),
            1 => (x, c, 0.0),
            2 => (0.0, c, x),
            3 => (0.0, x, c),
            4 => (x, 0.0, c),
            _ => (c, 0.0, x),
        };
        return new RGB(r1 + m, g1 + m, b1 + m);
    }

    public RGB Mixed(RGB other, double t) => new(R + (other.R - R) * t, G + (other.G - G) * t, B + (other.B - B) * t);

    internal double DistanceSquared(RGB o)
    {
        double dr = R - o.R, dg = G - o.G, db = B - o.B;
        return dr * dr + dg * dg + db * db;
    }

    /// "#RRGGBB" or "#RRGGBBAA" (alpha is ignored), as colors are saved in Settings.
    public static RGB? FromHex(string hex)
    {
        var digits = hex.Trim();
        if (digits.StartsWith('#')) digits = digits[1..];
        if ((digits.Length != 6 && digits.Length != 8) ||
            !uint.TryParse(digits[..6], NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var value)) return null;
        return new RGB(((value >> 16) & 0xFF) / 255.0, ((value >> 8) & 0xFF) / 255.0, (value & 0xFF) / 255.0);
    }

    public string Hex
    {
        get
        {
            static int Byte(double v) => (int)Math.Round(Math.Clamp(v, 0, 1) * 255, MidpointRounding.AwayFromZero);
            return $"#{Byte(R):X2}{Byte(G):X2}{Byte(B):X2}";
        }
    }
}

/// Colors derived from album artwork for backgrounds and accents.
public sealed record Palette(IReadOnlyList<RGB> Colors, RGB Accent)
{
    public static readonly Palette Fallback = new(
        [new(0.36, 0.16, 0.42), new(0.12, 0.20, 0.45), new(0.55, 0.18, 0.30), new(0.10, 0.10, 0.18)],
        new RGB(0.98, 0.36, 0.48));

    public Palette Mixed(Palette other, double t)
    {
        var count = Math.Max(Colors.Count, other.Colors.Count);
        var blended = Enumerable.Range(0, count)
            .Select(i => Colors[i % Colors.Count].Mixed(other.Colors[i % other.Colors.Count], t)).ToList();
        return new Palette(blended, Accent.Mixed(other.Accent, t));
    }

    /// Bright versions of the album's colors for light (the screen-edge glow): the accent
    /// first, then each background color at full brightness and at least medium saturation.
    /// Grays would only dull the light, so they're left out unless the cover has nothing
    /// else, when it glows a soft white. Near-duplicates are dropped.
    public List<RGB> GlowColors
    {
        get
        {
            // Chroma, not saturation: a near-black with a faint tint has high saturation but
            // no real color, and brightening it would invent one.
            static bool IsColorful(RGB c) => Math.Max(c.R, Math.Max(c.G, c.B)) - Math.Min(c.R, Math.Min(c.G, c.B)) >= 0.08;
            var all = new List<RGB> { Accent };
            all.AddRange(Colors);
            var colorful = all.Where(IsColorful).ToList();
            var glow = new List<RGB>();
            foreach (var color in colorful.Count == 0 ? all : colorful)
            {
                var (h, s, _) = color.Hsb;
                var bright = RGB.FromHsb(h, IsColorful(color) ? Math.Max(s, 0.55) : 0, 1);
                if (!glow.Any(g => g.DistanceSquared(bright) < 0.04)) glow.Add(bright);
            }
            return glow;
        }
    }

    public bool Equals(Palette? other) => other is not null && Accent == other.Accent && Colors.SequenceEqual(other.Colors);
    public override int GetHashCode() => HashCode.Combine(Accent, Colors.Count);
}

/// Deterministic k-means palette extraction over a small pixel sample.
public static class PaletteExtractor
{
    public static Palette FromPixels(IReadOnlyList<RGB> pixels, int clusters = 5, int iterations = 10)
    {
        var k = clusters;
        if (pixels.Count < k) return Palette.Fallback;

        // Farthest-point initialisation keeps results stable and spread out.
        var centroids = new List<RGB> { pixels[pixels.Count / 2] };
        while (centroids.Count < k)
        {
            // Swift's max(by:) keeps the first of equal maxima; match it so results agree.
            RGB next = pixels[0];
            var bestDistance = double.NegativeInfinity;
            foreach (var p in pixels)
            {
                var d = centroids.Min(p.DistanceSquared);
                if (d > bestDistance) { bestDistance = d; next = p; }
            }
            centroids.Add(next);
        }

        var assignment = new int[pixels.Count];
        for (var iteration = 0; iteration < iterations; iteration++)
        {
            for (var i = 0; i < pixels.Count; i++)
            {
                int bestIndex = 0;
                var bestDistance = double.PositiveInfinity;
                for (var j = 0; j < centroids.Count; j++)
                {
                    var d = pixels[i].DistanceSquared(centroids[j]);
                    if (d < bestDistance) { bestDistance = d; bestIndex = j; }
                }
                assignment[i] = bestIndex;
            }
            var sums = new (double R, double G, double B)[k];
            var counts = new int[k];
            for (var i = 0; i < pixels.Count; i++)
            {
                var j = assignment[i];
                sums[j] = (sums[j].R + pixels[i].R, sums[j].G + pixels[i].G, sums[j].B + pixels[i].B);
                counts[j]++;
            }
            for (var j = 0; j < k; j++)
                if (counts[j] > 0) centroids[j] = new RGB(sums[j].R / counts[j], sums[j].G / counts[j], sums[j].B / counts[j]);
        }

        var finalCounts = new int[k];
        foreach (var a in assignment) finalCounts[a]++;
        var ranked = centroids.Zip(finalCounts).Where(p => p.Second > 0).OrderByDescending(p => p.Second).ToList();
        double total = pixels.Count;

        var background = ranked.Select(p =>
        {
            var (h, s, v) = p.First.Hsb;
            var saturation = s < 0.08 ? s : Math.Min(1, s * 1.18 + 0.04);
            return RGB.FromHsb(h, saturation, Math.Clamp(v, 0.20, 0.74));
        }).ToList();

        var accentSource = ranked.Count == 0 ? Palette.Fallback.Accent
            : ranked.Aggregate((a, b) => Score(b.First, b.Second / total) > Score(a.First, a.Second / total) ? b : a).First;
        var (ah, asat, av) = accentSource.Hsb;
        var accent = asat < 0.12
            ? RGB.FromHsb(ah, asat, Math.Max(av, 0.85))
            : RGB.FromHsb(ah, Math.Max(asat, 0.55), Math.Max(av, 0.82));

        var colors = background;
        while (colors.Count < 3) colors.Add(colors.Count > 0 ? colors[^1] : Palette.Fallback.Colors[0]);
        return new Palette(colors, accent);
    }

    private static double Score(RGB color, double share)
    {
        var (_, s, v) = color.Hsb;
        return s * v * (0.25 + share);
    }
}

/// "m:ss" style labels for playback times.
public static class TimeText
{
    public static string Format(double seconds)
    {
        if (!double.IsFinite(seconds)) return "0:00";
        var total = (int)Math.Floor(seconds);
        int h = total / 3600, m = total % 3600 / 60, s = total % 60;
        return h > 0 ? $"{h}:{m:00}:{s:00}" : $"{m}:{s:00}";
    }

    public static string Remaining(double elapsed, double duration) =>
        "-" + Format(Math.Max(0, Math.Floor(duration) - Math.Floor(elapsed)));
}

/// Finds beats in the music's low end, for the edge glow's pulse.
///
/// Fed the audio tap's band levels (0…1, lowest band first) about 30 times a second. A beat
/// is a sudden rise in bass energy well above its recent average, at most every 0.28 s
/// (about 214 bpm), so a sustained loud passage doesn't count as a stream of beats.
public sealed class BeatDetector
{
    /// How many of the lowest bands make up "the bass".
    public const int BassBands = 3;
    internal const double MinimumGap = 0.28;

    private float _average, _variance;
    private double _lastBeat = double.NegativeInfinity;
    private int _primed;

    /// Feeds one frame of levels heard at `time`; true when it's a beat.
    public bool Feed(ReadOnlySpan<float> levels, double time)
    {
        if (levels.IsEmpty) return false;
        var bass = levels[..Math.Min(BassBands, levels.Length)];
        float sum = 0;
        foreach (var l in bass) sum += l;
        var energy = sum / bass.Length;
        // About a second of memory at 30 frames a second.
        var deviation = energy - _average;
        var isBeat = _primed >= 10 && deviation > Math.Max(0.06f, 1.4f * MathF.Sqrt(_variance))
                     && energy > 0.15f && time - _lastBeat >= MinimumGap;
        _average += 0.06f * deviation;
        _variance += 0.06f * (deviation * deviation - _variance);
        _primed++;
        if (isBeat) _lastBeat = time;
        return isBeat;
    }

    /// Back to no memory, e.g. after a pause or a new song.
    public void Reset()
    {
        _average = 0; _variance = 0; _lastBeat = double.NegativeInfinity; _primed = 0;
    }
}
