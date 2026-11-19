using System.Xml;

namespace Islet.Core;

/// One displayable lyric row. Interludes are synthetic rows for instrumental gaps.
public sealed record LyricLine(int Id, double Start, double End, string Text, bool IsInterlude = false)
{
    /// The line's words with their own timing; empty for interludes.
    public IReadOnlyList<LyricWord> Words { get; init; } = [];
    /// The words were timed by the lyrics source (Apple Music, Enhanced LRC), rather than
    /// estimated by spreading the line's time across them.
    public bool HasExactWordTiming { get; init; }
}

/// One line before rows are numbered and interludes are added: a time, the sung text and,
/// when the source times words, its pieces. A null `End` runs to the next line.
internal sealed record TimedEntry(double Time, double? End, string Text, List<TimedPiece> Pieces);

/// Parser for LRC (and the line part of Enhanced LRC) as served by LRCLIB.
public static class LRCParser
{
    /// Gaps at least this long become an interlude row with animated dots.
    public const double InterludeThreshold = 4.5;

    private static readonly Regex TimeTag = new(@"\G\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]", RegexOptions.Compiled);
    private static readonly Regex WordTag = new(@"<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>", RegexOptions.Compiled);
    private static readonly Regex OffsetTag = new(@"\[offset:\s*([+-]?\d+)\s*\]", RegexOptions.Compiled | RegexOptions.IgnoreCase);
    // Swift's Character.isNewline, with CRLF as one break.
    internal static readonly Regex Newline = new("\r\n|[\n\r\u000B\u000C\u0085\u2028\u2029]", RegexOptions.Compiled);

    public static List<LyricLine> Parse(string lrc, double? duration = null)
    {
        double offset = 0;
        var offsetMatch = OffsetTag.Match(lrc);
        // A positive offset makes lyrics appear sooner.
        if (offsetMatch.Success && double.TryParse(offsetMatch.Groups[1].Value, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var ms))
            offset = ms / 1000;

        var entries = new List<TimedEntry>();
        foreach (var rawLine in Newline.Split(lrc))
        {
            var times = new List<double>();
            var position = 0;
            for (var m = TimeTag.Match(rawLine, 0); m.Success; m = TimeTag.Match(rawLine, position))
            {
                times.Add(Seconds(m) - offset);
                position = m.Index + m.Length;
            }
            if (times.Count == 0) continue;
            var rest = rawLine[position..];
            var text = WordTag.Replace(rest, "").Trim();
            var pieces = text.Length == 0 ? [] : WordPieces(rest, offset);
            var first = times[0];
            foreach (var time in times)
            {
                // Word tags hold the first occurrence's times; a repeated chorus shifts them.
                var shift = time - first;
                var moved = pieces.Select(p => p with { Start = Math.Max(0, p.Start + shift) }).ToList();
                entries.Add(new TimedEntry(Math.Max(0, time), null, text, moved));
            }
        }
        // OrderBy is stable, keeping duet lines with equal timestamps in file order.
        return BuildLines(entries.OrderBy(e => e.Time).ToList(), duration);
    }

    /// Enhanced LRC word tags: `<00:12.00>Look <00:12.40>at <00:12.70>the<00:13.10>`. Each tag
    /// times the text after it; a trailing tag marks when the last word ends.
    private static List<TimedPiece> WordPieces(string body, double offset)
    {
        var matches = WordTag.Matches(body);
        var pieces = new List<TimedPiece>();
        for (var i = 0; i < matches.Count; i++)
        {
            var m = matches[i];
            var upper = i + 1 < matches.Count ? matches[i + 1].Index : body.Length;
            var text = body[(m.Index + m.Length)..upper];
            // Text before the first tag belongs to the first word.
            if (i == 0) text = body[..m.Index] + text;
            pieces.Add(new TimedPiece(Seconds(m) - offset, text));
        }
        return pieces;
    }

    /// Index of the row that should be highlighted at `time`, or null before the first row.
    public static int? ActiveIndex(IReadOnlyList<LyricLine> lines, double time, double lead = 0.15)
    {
        var target = time + lead;
        int low = 0, high = lines.Count - 1;
        int? found = null;
        while (low <= high)
        {
            var mid = (low + high) / 2;
            if (lines[mid].Start <= target) { found = mid; low = mid + 1; }
            else high = mid - 1;
        }
        return found;
    }

    private static double Seconds(Match m)
    {
        var value = double.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture) * 60
                    + double.Parse(m.Groups[2].Value, CultureInfo.InvariantCulture);
        var fraction = m.Groups[3].Value;
        // "4" -> 0.4, "43" -> 0.43, "430" -> 0.430
        if (fraction.Length > 0)
            value += double.Parse(fraction, CultureInfo.InvariantCulture) / Math.Pow(10, fraction.Length);
        return value;
    }

    /// Numbers the sung lines, gives each its words (timed by the source, or estimated) and
    /// adds interlude rows for long gaps. Shared with `TTMLParser`.
    internal static List<LyricLine> BuildLines(List<TimedEntry> entries, double? duration)
    {
        var sung = new List<(double Start, double End, string Text, List<TimedPiece> Pieces)>();
        for (var i = 0; i < entries.Count; i++)
        {
            var entry = entries[i];
            if (entry.Text.Length == 0) continue;
            double? next = null;
            for (var j = i + 1; j < entries.Count; j++)
                if (entries[j].Time > entry.Time) { next = entries[j].Time; break; }
            var end = entry.End ?? next ?? Math.Max(duration ?? 0, entry.Time + 5);
            sung.Add((entry.Time, end, entry.Text, entry.Pieces));
        }

        var lines = new List<LyricLine>();
        void Add(double start, double end, string text, List<TimedPiece>? pieces, bool interlude)
        {
            var line = new LyricLine(lines.Count, start, end, text, interlude);
            if (!interlude)
            {
                var timed = WordTiming.Words(pieces ?? [], end);
                line = line with
                {
                    Words = timed.Count == 0 ? WordTiming.Estimate(text, start, end) : timed,
                    HasExactWordTiming = timed.Count > 0,
                };
            }
            lines.Add(line);
        }
        if (sung.Count > 0 && sung[0].Start >= InterludeThreshold) Add(0, sung[0].Start, "", null, true);
        for (var i = 0; i < sung.Count; i++)
        {
            var line = sung[i];
            Add(line.Start, line.End, line.Text, line.Pieces, false);
            if (i + 1 < sung.Count && sung[i + 1].Start - line.End >= InterludeThreshold)
                Add(line.End, sung[i + 1].Start, "", null, true);
        }
        return lines;
    }
}

/// Parser for the TTML lyrics Apple Music serves. Word-timed ("syllable") lyrics put each
/// word or syllable in a timed `<span>`; line-timed lyrics only time each `<p>`.
/// Background vocals (`ttm:role="x-bg"`), translations and the `<head>` are left out.
public static class TTMLParser
{
    public static List<LyricLine> Parse(string ttml)
    {
        var entries = new List<TimedEntry>();
        double? duration = null;
        var untimed = false;
        var inBody = false;
        (double Start, double? End)? line = null;
        var pieces = new List<TimedPiece>();
        var lineText = new StringBuilder();
        // Open spans; true for one whose words are left out (background vocals).
        var spans = new List<bool>();
        (double Start, double? End, StringBuilder Text)? span = null;
        // Whitespace between spans: the next span starts a new word.
        var spaceBefore = false;
        bool Skipping() => spans.Contains(true);

        void Characters(string s)
        {
            if (line is null || Skipping()) return;
            if (span is { } open) open.Text.Append(s);
            else
            {
                lineText.Append(s);
                if (s.Any(char.IsWhiteSpace)) spaceBefore = true;
            }
        }

        try
        {
            using var reader = XmlReader.Create(new StringReader(ttml), new XmlReaderSettings
            {
                DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, IgnoreComments = true,
            });
            while (reader.Read())
            {
                switch (reader.NodeType)
                {
                    case XmlNodeType.Element:
                    {
                        var isEmpty = reader.IsEmptyElement;
                        var name = reader.LocalName;
                        if (name == "body")
                        {
                            inBody = true;
                            duration = Seconds(reader.GetAttribute("dur"));
                        }
                        else if (name == "p" && inBody)
                        {
                            if (Seconds(reader.GetAttribute("begin")) is not double start) { untimed = true; break; }
                            line = (start, Seconds(reader.GetAttribute("end")));
                            pieces = [];
                            lineText.Clear();
                            spaceBefore = false;
                        }
                        else if (name == "span" && line is not null)
                        {
                            var role = "";
                            if (reader.MoveToFirstAttribute())
                            {
                                do { if (reader.LocalName == "role") role = reader.Value; } while (reader.MoveToNextAttribute());
                                reader.MoveToElement();
                            }
                            var skip = role.StartsWith("x-bg") || role.StartsWith("x-translation") || role.StartsWith("x-roman");
                            spans.Add(skip);
                            if (!Skipping() && Seconds(reader.GetAttribute("begin")) is double start)
                                span = (start, Seconds(reader.GetAttribute("end")), new StringBuilder());
                        }
                        if (isEmpty) goto case XmlNodeType.EndElement;
                        break;
                    }
                    case XmlNodeType.Text:
                    case XmlNodeType.Whitespace:
                    case XmlNodeType.SignificantWhitespace:
                    case XmlNodeType.CDATA:
                        Characters(reader.Value);
                        break;
                    case XmlNodeType.EndElement:
                    {
                        var name = reader.LocalName;
                        if (name == "span" && spans.Count > 0)
                        {
                            if (span is { } open && !Skipping())
                            {
                                var prefix = spaceBefore ? " " : "";
                                pieces.Add(new TimedPiece(open.Start, prefix + open.Text, open.End));
                                lineText.Append(prefix).Append(open.Text);
                                spaceBefore = false;
                                span = null;
                            }
                            spans.RemoveAt(spans.Count - 1);
                        }
                        else if (name == "p" && line is { } done)
                        {
                            var text = string.Join(' ', WordTiming.Tokens(lineText.ToString()));
                            entries.Add(new TimedEntry(done.Start, done.End, text, pieces));
                            line = null;
                        }
                        else if (name == "body") inBody = false;
                        break;
                    }
                }
            }
        }
        catch (XmlException) { return []; }
        if (untimed || entries.Count == 0) return [];
        return LRCParser.BuildLines(entries, duration);
    }

    /// "13.4", "1:02.345", "01:02:03.456" or "13.4s", in seconds.
    internal static double? Seconds(string? text)
    {
        text = text?.Trim();
        if (string.IsNullOrEmpty(text)) return null;
        if (text.EndsWith('s')) text = text[..^1];
        double total = 0;
        foreach (var part in text.Split(':'))
        {
            if (!double.TryParse(part, NumberStyles.Float, CultureInfo.InvariantCulture, out var value)) return null;
            total = total * 60 + value;
        }
        return total;
    }
}
