namespace Islet.Core;

/// One sung word and when it's sung. `Symbol` names a glyph that pictures the word
/// ("fire" → flame), set by `WordSymbols` for the words that have one.
public sealed record LyricWord(string Text, double Start, double End, string? Symbol = null);

/// A timed piece of a line as a source delivers it: a word, a syllable ("beau", "ti", "ful")
/// or, with no text, the moment singing stops. Whitespace in `Text` separates words; pieces
/// that touch without whitespace are parts of one word. A null `End` lasts until the next piece.
public sealed record TimedPiece(double Start, string Text, double? End = null);

/// Word-level timing: from a source's timed pieces, or estimated for lyrics timed by line.
public static class WordTiming
{
    /// About one sung syllable per three letters, at a pop tempo.
    internal const double SecondsPerWeight = 0.12;
    /// Even a short line takes a moment to sing.
    internal const double MinimumSpan = 1.2;

    /// Joins timed pieces into words. Empty when there are no pieces.
    public static List<LyricWord> Words(IReadOnlyList<TimedPiece> pieces, double lineEnd)
    {
        var words = new List<LyricWord>();
        // The previous piece stopped mid-word, so the next one continues it.
        var continues = false;
        for (var i = 0; i < pieces.Count; i++)
        {
            var piece = pieces[i];
            var next = i + 1 < pieces.Count ? pieces[i + 1].Start : lineEnd;
            var end = Math.Max(piece.Start, piece.End ?? next);
            var tokens = Tokens(piece.Text);
            if (tokens.Length == 0) { continues = false; continue; }
            var joinsPrevious = continues && piece.Text.Length > 0 && !char.IsWhiteSpace(piece.Text[0]);
            var slices = Slices(tokens, piece.Start, end);
            for (var t = 0; t < tokens.Length; t++)
            {
                if (t == 0 && joinsPrevious && words.Count > 0)
                {
                    var last = words[^1];
                    words[^1] = last with { Text = last.Text + tokens[t], End = slices[t].End };
                }
                else words.Add(new LyricWord(tokens[t], slices[t].Start, slices[t].End));
            }
            continues = piece.Text.Length > 0 && !char.IsWhiteSpace(piece.Text[^1]);
        }
        return words;
    }

    /// Spreads a line's time across its words, longer words taking longer. Singing rarely
    /// fills the whole gap to the next line, so the words move at a natural pace and finish
    /// a little before the line ends.
    public static List<LyricWord> Estimate(string text, double start, double end)
    {
        var tokens = Tokens(text);
        if (tokens.Length == 0) return [];
        var length = Math.Max(end - start, 0);
        var pace = Weights(tokens).Sum() * SecondsPerWeight;
        var span = Math.Min(length * 0.9, Math.Max(MinimumSpan, pace));
        var slices = Slices(tokens, start, start + span);
        return tokens.Select((t, i) => new LyricWord(t, slices[i].Start, slices[i].End)).ToList();
    }

    /// Where singing is within a line, counted in words: 2.5 is halfway through the third
    /// word. −1 before the first word starts; `words.Count` once the last has ended.
    public static double Focus(IReadOnlyList<LyricWord> words, double time)
    {
        if (words.Count == 0 || time < words[0].Start) return -1;
        for (var i = 0; i < words.Count; i++)
        {
            var word = words[i];
            if (time >= word.End) continue;
            if (time <= word.Start) return i;
            return i + (time - word.Start) / Math.Max(word.End - word.Start, 0.001);
        }
        return words.Count;
    }

    /// How far through word `index` singing is (0 to 1), given `Focus`.
    public static double Progress(int index, double focus) => Math.Min(Math.Max(focus - index, 0), 1);

    internal static string[] Tokens(string text) =>
        text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);

    /// Letters plus one, so short words ("a", "I") still take a beat.
    private static double[] Weights(string[] tokens) =>
        tokens.Select(t => (double)t.EnumerateRunes().Count(IsAlphanumeric) + 1).ToArray();

    // Foundation's CharacterSet.alphanumerics: letters, marks and numbers.
    private static bool IsAlphanumeric(Rune r) => Rune.IsLetterOrDigit(r) || Rune.GetUnicodeCategory(r) is
        UnicodeCategory.NonSpacingMark or UnicodeCategory.SpacingCombiningMark or UnicodeCategory.EnclosingMark
        or UnicodeCategory.LetterNumber or UnicodeCategory.OtherNumber;

    private static (double Start, double End)[] Slices(string[] tokens, double start, double end)
    {
        var weights = Weights(tokens);
        var total = weights.Sum();
        var length = Math.Max(end - start, 0);
        var cursor = start;
        var result = new (double, double)[weights.Length];
        for (var i = 0; i < weights.Length; i++)
        {
            var next = cursor + length * weights[i] / total;
            result[i] = (cursor, next);
            cursor = next;
        }
        return result;
    }
}

/// Every sung word of a song in order, across line breaks: what the on-screen lyrics walk
/// through one word at a time.
public sealed class WordStream
{
    public IReadOnlyList<LyricWord> Words { get; }

    public WordStream(IEnumerable<LyricLine> lines)
    {
        // OrderBy is stable, so duet words that start together keep their order.
        Words = lines.Where(l => !l.IsInterlude).SelectMany(l => l.Words).OrderBy(w => w.Start).ToList();
    }

    /// The word being sung, or the last one sung, at `time`; null before the first.
    public int? Index(double time)
    {
        int low = 0, high = Words.Count - 1;
        int? found = null;
        while (low <= high)
        {
            var mid = (low + high) / 2;
            if (Words[mid].Start <= time) { found = mid; low = mid + 1; }
            else high = mid - 1;
        }
        return found;
    }

    /// Between phrases: the last word ended a while ago and the next isn't about to start,
    /// so the screen can clear instead of holding an old word through an instrumental.
    public bool IsResting(double time, double after = 1.6, double before = 0.5)
    {
        if (Index(time) is not int index) return true;
        var sinceEnd = time - Words[index].End;
        var untilNext = index + 1 < Words.Count ? Words[index + 1].Start - time : double.PositiveInfinity;
        return sinceEnd > after && untilNext > before;
    }
}
