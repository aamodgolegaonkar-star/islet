namespace Islet.Core;

/// Pictures for lyric words: "fire" → flame, "love" → heart, "rain" → cloud.rain.
///
/// Symbol names are the Mac's SF Symbol names, so both apps agree on which word gets which
/// picture; the Windows UI draws each name with its own glyph. On the Mac the full SF Symbols
/// catalogue (names, search keywords, categories) widens the match to any everyday noun;
/// Windows has no such catalogue, so `System` uses the curated list of words songs use a lot,
/// which is where nearly every hit comes from.
public sealed class WordSymbols
{
    private readonly Dictionary<string, string> _curated;
    private readonly Dictionary<string, string> _byName = [];
    private readonly Dictionary<string, string> _byKeyword;

    public WordSymbols(ISet<string> names, IReadOnlyDictionary<string, string[]> keywords, IReadOnlyDictionary<string, string[]> categories)
    {
        bool Friendly(string name)
        {
            var found = categories.TryGetValue(name, out var c) ? c : [];
            return found.Any(Everyday.Contains) && !found.Any(Technical.Contains);
        }
        // The filled variant reads better at lyric sizes.
        string Filled(string name) => names.Contains(name + ".fill") ? name + ".fill" : name;

        _curated = Common.Where(p => names.Contains(p.Value)).ToDictionary(p => p.Key, p => Filled(p.Value));
        foreach (var name in names)
            if (!name.Contains('.') && Friendly(name)) _byName[name] = Filled(name);
        var byKeyword = new Dictionary<string, (string Name, int Parts)>();
        foreach (var (name, words) in keywords)
        {
            if (!names.Contains(name) || !Friendly(name)) continue;
            var parts = name.Split('.').Length;
            if (parts > 2) continue;
            foreach (var word in words.Select(w => w.ToLowerInvariant()))
                if (parts < (byKeyword.TryGetValue(word, out var have) ? have.Parts : int.MaxValue)) byKeyword[word] = (name, parts);
        }
        _byKeyword = byKeyword.ToDictionary(p => p.Key, p => Filled(p.Value.Name));
    }

    /// The curated words, each with its filled symbol where the Mac has one.
    public static WordSymbols System => _system ??= new(
        new HashSet<string>(Common.Values.SelectMany(v => new[] { v, v + ".fill" })),
        new Dictionary<string, string[]>(), new Dictionary<string, string[]>());
    private static WordSymbols? _system;

    /// The symbol for one word. `lemma` is its dictionary form ("burning" → "burn").
    public string? Symbol(string word, string? lemma = null, bool isNoun = false)
    {
        var forms = new[] { Clean(word), lemma is null ? null : Clean(lemma) }.OfType<string>().Where(f => f.Length >= 3).ToList();
        foreach (var form in forms) if (_curated.TryGetValue(form, out var found)) return found;
        if (!isNoun) return null;
        foreach (var form in forms)
            if (_byName.TryGetValue(form, out var n) || _byKeyword.TryGetValue(form, out n)) return n;
        return null;
    }

    /// Gives each word of each line its symbol. Without a part-of-speech tagger on Windows,
    /// only curated words match, and a light stemmer finds dictionary forms ("burning" → "burn").
    public List<LyricLine> Annotate(IEnumerable<LyricLine> lines) => lines.Select(line =>
        line.Words.Count == 0 ? line
            : line with { Words = line.Words.Select(w => w with { Symbol = Symbol(w.Text, Lemma(Clean(w.Text))) }).ToList() }).ToList();

    /// Lowercase letters only: "Fire!" → "fire", "heart's" → "heart".
    internal static string Clean(string word)
    {
        word = word.ToLowerInvariant();
        if (word.EndsWith("'s") || word.EndsWith("\u2019s")) word = word[..^2];
        return new string(word.Where(char.IsLetter).ToArray());
    }

    // shortcut: suffix stripping, not a real lemmatizer; misses irregular forms ("flew").
    internal static string? Lemma(string word)
    {
        if (word.Length > 5 && word.EndsWith("ing"))
        {
            var stem = word[..^3];
            return stem.Length > 2 && stem[^1] == stem[^2] ? stem[..^1] : stem;
        }
        if (word.Length > 4 && word.EndsWith("ed")) return word[..^2];
        if (word.Length > 3 && word.EndsWith('s') && !word.EndsWith("ss")) return word[..^1];
        return null;
    }

    private static readonly HashSet<string> Everyday = ["nature", "weather", "transportation", "automotive", "human", "home", "fitness", "health", "gaming", "commerce", "time", "objectsandtools", "communication", "devices", "maps"];
    private static readonly HashSet<string> Technical = ["textformatting", "arrows", "editing", "keyboard", "math", "indices", "shapes", "privacyandsecurity", "connectivity", "accessibility", "media"];

    /// Words songs use a lot, for which the symbol names alone pick nothing or the wrong thing.
    internal static readonly Dictionary<string, string> Common = new()
    {
        ["love"] = "heart", ["kiss"] = "heart", ["heart"] = "heart", ["fire"] = "flame", ["burn"] = "flame",
        ["flame"] = "flame", ["night"] = "moon.stars", ["moon"] = "moon", ["star"] = "star", ["stars"] = "sparkles",
        ["sun"] = "sun.max", ["summer"] = "sun.max", ["sunshine"] = "sun.max", ["sunrise"] = "sunrise",
        ["sunset"] = "sunset", ["sky"] = "cloud", ["cloud"] = "cloud", ["rain"] = "cloud.rain",
        ["storm"] = "cloud.bolt", ["thunder"] = "cloud.bolt", ["lightning"] = "bolt", ["snow"] = "snowflake",
        ["winter"] = "snowflake", ["ice"] = "snowflake", ["cold"] = "thermometer.snowflake", ["wind"] = "wind",
        ["ocean"] = "water.waves", ["sea"] = "water.waves", ["wave"] = "water.waves", ["waves"] = "water.waves",
        ["water"] = "drop", ["tears"] = "drop", ["tear"] = "drop", ["cry"] = "drop", ["money"] = "dollarsign",
        ["cash"] = "dollarsign", ["gold"] = "crown", ["king"] = "crown", ["queen"] = "crown", ["crown"] = "crown",
        ["diamond"] = "diamond", ["dream"] = "sparkles", ["heaven"] = "sparkles", ["angel"] = "sparkles",
        ["shine"] = "sparkles", ["glow"] = "sparkles", ["dance"] = "figure.dance", ["run"] = "figure.run",
        ["sing"] = "music.mic", ["song"] = "music.note", ["music"] = "music.note", ["radio"] = "radio",
        ["guitar"] = "guitars", ["drive"] = "car", ["car"] = "car", ["ride"] = "car", ["call"] = "phone",
        ["phone"] = "phone", ["sleep"] = "moon.zzz", ["bed"] = "bed.double", ["world"] = "globe",
        ["earth"] = "globe.americas", ["time"] = "clock", ["clock"] = "clock", ["road"] = "road.lanes",
        ["fly"] = "bird", ["wings"] = "bird", ["bird"] = "bird", ["plane"] = "airplane", ["boat"] = "sailboat",
        ["train"] = "tram", ["home"] = "house", ["house"] = "house", ["city"] = "building.2", ["eyes"] = "eye",
        ["eye"] = "eye", ["hand"] = "hand.raised", ["hands"] = "hands.clap", ["mind"] = "brain.head.profile",
        ["brain"] = "brain", ["breath"] = "lungs", ["party"] = "party.popper", ["key"] = "key", ["lock"] = "lock",
        ["door"] = "door.left.hand.open", ["mountain"] = "mountain.2", ["tree"] = "tree", ["leaf"] = "leaf",
        ["flower"] = "camera.macro", ["rose"] = "camera.macro", ["gift"] = "gift", ["wine"] = "wineglass",
        ["drink"] = "wineglass", ["smile"] = "face.smiling", ["light"] = "lightbulb", ["lights"] = "lightbulb",
        ["gun"] = "scope", ["bullet"] = "scope", ["game"] = "gamecontroller", ["trophy"] = "trophy",
        ["medal"] = "medal", ["letter"] = "envelope", ["book"] = "book", ["picture"] = "photo", ["photo"] = "photo",
        ["camera"] = "camera", ["shoes"] = "shoe", ["dress"] = "tshirt", ["shirt"] = "tshirt",
        ["beach"] = "beach.umbrella", ["island"] = "beach.umbrella", ["umbrella"] = "umbrella", ["dog"] = "dog",
        ["cat"] = "cat", ["fish"] = "fish", ["bell"] = "bell", ["pill"] = "pills", ["pills"] = "pills",
        ["hot"] = "thermometer.sun",
    };
}
