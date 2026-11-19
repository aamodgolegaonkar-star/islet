namespace Islet.Core;

/// A pair of headphones Islet recognises, for the connection card in the island.
/// `Symbol` keeps the Mac's glyph names; the Windows UI maps them to its own icons.
public sealed record HeadphoneModel(string Name, HeadphoneModel.Brand Maker, HeadphoneModel.Kind Shape, string Symbol)
{
    public enum Brand { Apple, Beats, Sony, Soundcore, Bose, Other }
    public enum Kind { Earbuds, OverEar }

    /// File name (without extension) of a 3D model the user can add for this model, e.g. "sony-ult-wear".
    public string ModelFileName => Regex.Replace(Name.ToLowerInvariant(), "[^a-z0-9]+", "-").Trim('-');
}

/// Identifies headphones from what Windows reports: the Bluetooth vendor and product IDs
/// first (they survive renaming, e.g. a Sony called "WWIII survivor"), then the device name.
public static class HeadphoneCatalog
{
    internal const int AppleVendor = 0x004C;
    internal const int SonyVendor = 0x054C;
    internal const int BoseVendor = 0x009E;

    private static HeadphoneModel New(string name, HeadphoneModel.Brand brand, HeadphoneModel.Kind kind, string symbol) =>
        new(name, brand, kind, symbol);

    private static readonly Dictionary<int, HeadphoneModel> Apple = new()
    {
        [0x2002] = New("AirPods", HeadphoneModel.Brand.Apple, HeadphoneModel.Kind.Earbuds, "airpods"),
        [0x200F] = New("AirPods", HeadphoneModel.Brand.Apple, HeadphoneModel.Kind.Earbuds, "airpods"),
        [0x2013] = New("AirPods (3rd generation)", HeadphoneModel.Brand.Apple, HeadphoneModel.Kind.Earbuds, "airpods.gen3"),
        [0x2019] = New("AirPods 4", HeadphoneModel.Brand.Apple, HeadphoneModel.Kind.Earbuds, "airpods.gen4"),
        [0x201B] = New("AirPods 4", HeadphoneModel.Brand.Apple, HeadphoneModel.Kind.Earbuds, "airpods.gen4"),
        [0x200E] = New("AirPods Pro", HeadphoneModel.Brand.Apple, HeadphoneModel.Kind.Earbuds, "airpods.pro"),
        [0x2014] = New("AirPods Pro", HeadphoneModel.Brand.Apple, HeadphoneModel.Kind.Earbuds, "airpods.pro"),
        [0x2024] = New("AirPods Pro", HeadphoneModel.Brand.Apple, HeadphoneModel.Kind.Earbuds, "airpods.pro"),
        [0x200A] = New("AirPods Max", HeadphoneModel.Brand.Apple, HeadphoneModel.Kind.OverEar, "airpods.max"),
        [0x201F] = New("AirPods Max", HeadphoneModel.Brand.Apple, HeadphoneModel.Kind.OverEar, "airpods.max"),
        [0x2006] = New("Beats Solo³", HeadphoneModel.Brand.Beats, HeadphoneModel.Kind.OverEar, "beats.headphones"),
        [0x200C] = New("Beats Solo Pro", HeadphoneModel.Brand.Beats, HeadphoneModel.Kind.OverEar, "beats.headphones"),
        [0x2025] = New("Beats Solo 4", HeadphoneModel.Brand.Beats, HeadphoneModel.Kind.OverEar, "beats.headphones"),
        [0x2009] = New("Beats Studio³", HeadphoneModel.Brand.Beats, HeadphoneModel.Kind.OverEar, "beats.headphones"),
        [0x2017] = New("Beats Studio Pro", HeadphoneModel.Brand.Beats, HeadphoneModel.Kind.OverEar, "beats.headphones"),
        [0x2026] = New("Beats Solo Buds", HeadphoneModel.Brand.Beats, HeadphoneModel.Kind.Earbuds, "beats.solobuds"),
        [0x2011] = New("Beats Studio Buds", HeadphoneModel.Brand.Beats, HeadphoneModel.Kind.Earbuds, "beats.studiobuds"),
        [0x2016] = New("Beats Studio Buds +", HeadphoneModel.Brand.Beats, HeadphoneModel.Kind.Earbuds, "beats.studiobuds"),
        [0x2012] = New("Beats Fit Pro", HeadphoneModel.Brand.Beats, HeadphoneModel.Kind.Earbuds, "beats.fitpro"),
        [0x200B] = New("Powerbeats Pro", HeadphoneModel.Brand.Beats, HeadphoneModel.Kind.Earbuds, "beats.powerbeats.pro"),
        [0x201D] = New("Powerbeats Pro 2", HeadphoneModel.Brand.Beats, HeadphoneModel.Kind.Earbuds, "beats.powerbeats.pro"),
    };

    private static readonly Dictionary<int, HeadphoneModel> Sony = new()
    {
        [0x0EAF] = New("Sony WH-CH720N", HeadphoneModel.Brand.Sony, HeadphoneModel.Kind.OverEar, "headphones"),
        [0x0F1E] = New("Sony ULT WEAR", HeadphoneModel.Brand.Sony, HeadphoneModel.Kind.OverEar, "headphones"),
    };

    private static readonly Dictionary<int, HeadphoneModel> Bose = new()
    {
        [0x4066] = New("Bose QuietComfort Ultra", HeadphoneModel.Brand.Bose, HeadphoneModel.Kind.OverEar, "headphones"),
    };

    /// Name fragments for devices without model numbers (or unknown ones), most specific first.
    private static readonly (string Fragment, HeadphoneModel Model)[] Names =
    [
        ("airpods max", New("AirPods Max", HeadphoneModel.Brand.Apple, HeadphoneModel.Kind.OverEar, "airpods.max")),
        ("airpods pro", New("AirPods Pro", HeadphoneModel.Brand.Apple, HeadphoneModel.Kind.Earbuds, "airpods.pro")),
        ("airpods", New("AirPods", HeadphoneModel.Brand.Apple, HeadphoneModel.Kind.Earbuds, "airpods")),
        ("solo buds", New("Beats Solo Buds", HeadphoneModel.Brand.Beats, HeadphoneModel.Kind.Earbuds, "beats.solobuds")),
        ("beats solo", New("Beats Solo", HeadphoneModel.Brand.Beats, HeadphoneModel.Kind.OverEar, "beats.headphones")),
        ("beats studio buds", New("Beats Studio Buds", HeadphoneModel.Brand.Beats, HeadphoneModel.Kind.Earbuds, "beats.studiobuds")),
        ("beats studio", New("Beats Studio", HeadphoneModel.Brand.Beats, HeadphoneModel.Kind.OverEar, "beats.headphones")),
        ("ult wear", New("Sony ULT WEAR", HeadphoneModel.Brand.Sony, HeadphoneModel.Kind.OverEar, "headphones")),
        ("wh-ult900n", New("Sony ULT WEAR", HeadphoneModel.Brand.Sony, HeadphoneModel.Kind.OverEar, "headphones")),
        ("ch720n", New("Sony WH-CH720N", HeadphoneModel.Brand.Sony, HeadphoneModel.Kind.OverEar, "headphones")),
        ("space q45", New("soundcore Space Q45", HeadphoneModel.Brand.Soundcore, HeadphoneModel.Kind.OverEar, "headphones")),
        ("space one", New("soundcore Space One", HeadphoneModel.Brand.Soundcore, HeadphoneModel.Kind.OverEar, "headphones")),
        ("qc45", New("Bose QC45", HeadphoneModel.Brand.Bose, HeadphoneModel.Kind.OverEar, "headphones")),
        ("qc 45", New("Bose QC45", HeadphoneModel.Brand.Bose, HeadphoneModel.Kind.OverEar, "headphones")),
        ("quietcomfort 45", New("Bose QC45", HeadphoneModel.Brand.Bose, HeadphoneModel.Kind.OverEar, "headphones")),
        ("qc ultra", New("Bose QuietComfort Ultra", HeadphoneModel.Brand.Bose, HeadphoneModel.Kind.OverEar, "headphones")),
        ("quietcomfort ultra", New("Bose QuietComfort Ultra", HeadphoneModel.Brand.Bose, HeadphoneModel.Kind.OverEar, "headphones")),
    ];

    /// The model, or null for audio devices Islet doesn't know (shown with a generic glyph).
    public static HeadphoneModel? Identify(string name, int? vendorId, int? productId)
    {
        if (vendorId is int vendor && productId is int product)
        {
            var table = vendor switch { AppleVendor => Apple, SonyVendor => Sony, BoseVendor => Bose, _ => null };
            if (table is not null && table.TryGetValue(product, out var model)) return model;
        }
        var lowered = name.ToLowerInvariant();
        foreach (var (fragment, model) in Names) if (lowered.Contains(fragment)) return model;
        return null;
    }

    /// Parses "0x054C" style numbers.
    public static int? Number(string? text)
    {
        if (text is null) return null;
        var digits = text.StartsWith("0x", StringComparison.OrdinalIgnoreCase) ? text[2..] : text;
        return int.TryParse(digits, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var n) ? n : null;
    }
}

