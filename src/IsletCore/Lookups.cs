using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace Islet.Core;

/// Text helpers for matching titles across services.
public static class MusicText
{
    /// Lowercases, folds diacritics, and drops edition noise such as "(Deluxe)" or " - Single".
    public static string Normalize(string text)
    {
        var s = FoldDiacritics(text).ToLowerInvariant();
        s = Regex.Replace(s, @"\s*[\(\[][^\)\]]*[\)\]]", "");
        s = Regex.Replace(s, @"\s+-\s+(single|ep|deluxe.*|remaster.*)$", "");
        s = Regex.Replace(s, @"\s+(feat\.?|ft\.?)\s.*$", "");
        s = Regex.Replace(s, @"[^\p{L}\p{N}]+", " ");
        return s.Trim();
    }

    /// A title as lyrics sites list it: without "(feat. …)", "- Remastered 2011",
    /// "(Live)", "[Explicit]" and similar edition tags that streaming services add.
    public static string LyricsTitle(string title)
    {
        const RegexOptions i = RegexOptions.IgnoreCase;
        var s = title;
        s = Regex.Replace(s, @"\s*[\(\[](feat\.?|ft\.?|featuring|with)\s[^\)\]]*[\)\]]", "", i);
        s = Regex.Replace(s, @"\s*[\(\[][^\)\]]*(remaster|version|edit|mono|stereo|explicit|clean|live|mix|deluxe|bonus|sped up|slowed)[^\)\]]*[\)\]]", "", i);
        s = Regex.Replace(s, @"\s+-\s+[^-]*(remaster|version|edit|mono|stereo|live|mix|single|sped up|slowed)[^-]*$", "", i);
        s = Regex.Replace(s, @"\s+(feat\.?|ft\.?|featuring)\s.*$", "", i);
        var trimmed = s.Trim();
        return trimmed.Length == 0 ? title : trimmed;
    }

    /// The first credited artist: "A feat. B", "A, B & C" and "A x B" all give "A".
    /// Only a fallback, since some band names contain commas or ampersands.
    public static string PrimaryArtist(string artist)
    {
        var s = Regex.Replace(artist, @"\s+(feat\.?|ft\.?|featuring|with|x)\s.*$", "", RegexOptions.IgnoreCase);
        var first = s.Split([',', '&'], StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? s;
        var trimmed = first.Trim();
        return trimmed.Length == 0 ? artist : trimmed;
    }

    /// Rewrites an mzstatic artwork URL ("…/100x100bb.jpg") to the requested pixel size.
    public static Uri? ResizedArtworkUrl(string url, int size) =>
        Uri.TryCreate(Regex.Replace(url, @"\d+x\d+bb", $"{size}x{size}bb"), UriKind.Absolute, out var u) ? u : null;

    private static string FoldDiacritics(string text)
    {
        var decomposed = text.Normalize(NormalizationForm.FormD);
        var sb = new StringBuilder(decomposed.Length);
        foreach (var c in decomposed)
            if (CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.NonSpacingMark) sb.Append(c);
        return sb.ToString().Normalize(NormalizationForm.FormC);
    }
}

/// Lyrics for one track.
[JsonPolymorphic(TypeDiscriminatorPropertyName = "kind")]
[JsonDerivedType(typeof(Synced), "synced")]
[JsonDerivedType(typeof(Plain), "plain")]
[JsonDerivedType(typeof(Instrumental), "instrumental")]
public abstract record LyricsContent
{
    public sealed record Synced(string Lrc) : LyricsContent;
    public sealed record Plain(string Text) : LyricsContent;
    public sealed record Instrumental : LyricsContent;
}

/// A small on-disk JSON cache shared by the lyrics clients: positive results forever,
/// "not found" for a day (lyrics get contributed over time).
internal sealed class DiskCache<T>(string? directory) where T : class
{
    private static readonly TimeSpan NegativeTtl = TimeSpan.FromDays(1);
    private readonly Dictionary<string, T?> _memory = [];
    private sealed record Entry(T? Value, DateTime SavedAt);

    public bool TryGet(string key, out T? value)
    {
        lock (_memory) if (_memory.TryGetValue(key, out value)) return true;
        value = null;
        if (directory is null) return false;
        try
        {
            var entry = JsonSerializer.Deserialize<Entry>(File.ReadAllBytes(Path.Combine(directory, key + ".json")));
            if (entry is null || (entry.Value is null && DateTime.UtcNow - entry.SavedAt > NegativeTtl)) return false;
            value = entry.Value;
            lock (_memory) _memory[key] = value;
            return true;
        }
        catch { return false; }
    }

    public void Set(string key, T? value)
    {
        lock (_memory) _memory[key] = value;
        if (directory is null) return;
        try
        {
            Directory.CreateDirectory(directory);
            var path = Path.Combine(directory, key + ".json");
            var temp = path + ".tmp";
            File.WriteAllBytes(temp, JsonSerializer.SerializeToUtf8Bytes(new Entry(value, DateTime.UtcNow)));
            File.Move(temp, path, overwrite: true);
        }
        catch { /* A cache that can't write just asks again next time. */ }
    }
}

/// Client for https://lrclib.net — a free, keyless, community lyrics database.
/// Lookup order: exact `/api/get` (duration ±2 s on the server), then `/api/search`
/// scored locally. Results (including "not found") are cached in memory and on disk.
public sealed class LRCLIBClient(HttpClient http, string userAgent, string? cacheDirectory = null)
{
    public sealed class RateLimitedException(TimeSpan? retryAfter) : Exception("LRCLIB rate limit")
    {
        public TimeSpan? RetryAfter { get; } = retryAfter;
    }
    public sealed class BadStatusException(int status) : Exception($"LRCLIB status {status}")
    {
        public int Status { get; } = status;
    }

    internal sealed record Record(string? TrackName, string? ArtistName, string? AlbumName, double? Duration,
                                  bool? Instrumental, string? PlainLyrics, string? SyncedLyrics);

    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    private readonly DiskCache<LyricsContent> _cache = new(cacheDirectory);

    public async Task<LyricsContent?> LyricsAsync(string title, string artist, string album, double duration, CancellationToken ct = default)
    {
        // The service needs both; a browser's "A site is playing media" has no artist.
        if (string.IsNullOrWhiteSpace(title) || string.IsNullOrWhiteSpace(artist)) return null;
        var key = CacheKey(title, artist, album, duration);
        if (_cache.TryGet(key, out var cached)) return cached;

        // As reported first; then as lyrics sites list it, with the full artist credit and
        // then just the first artist.
        var cleanTitle = MusicText.LyricsTitle(title);
        var firstArtist = MusicText.PrimaryArtist(artist);
        var result = await GetExact(title, artist, album, duration, ct);
        if (result is null && cleanTitle != title) result = await GetExact(cleanTitle, artist, album, duration, ct);
        result ??= await Search(cleanTitle, artist, duration, ct);
        if (result is null && firstArtist != artist) result = await Search(cleanTitle, firstArtist, duration, ct);
        var content = result is null ? null : Content(result);
        _cache.Set(key, content);
        return content;
    }

    private Task<Record?> GetExact(string title, string artist, string album, double duration, CancellationToken ct)
    {
        var items = new List<(string, string)> { ("track_name", title), ("artist_name", artist) };
        var albumName = CleanAlbum(album);
        if (albumName.Length > 0) items.Add(("album_name", albumName));
        if (duration > 0) items.Add(("duration", ((int)Math.Round(duration, MidpointRounding.AwayFromZero)).ToString(CultureInfo.InvariantCulture)));
        return Fetch<Record>("get", items, ct);
    }

    private async Task<Record?> Search(string title, string artist, double duration, CancellationToken ct)
    {
        var records = await Fetch<List<Record>>("search", [("track_name", title), ("artist_name", artist)], ct);
        return records is null ? null : BestMatch(records, title, artist, duration);
    }

    private async Task<T?> Fetch<T>(string path, List<(string Name, string Value)> items, CancellationToken ct) where T : class
    {
        var url = "https://lrclib.net/api/" + path + "?" + Query(items);
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.TryAddWithoutValidation("User-Agent", userAgent);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(12));
        using var response = await http.SendAsync(request, timeout.Token);
        switch ((int)response.StatusCode)
        {
            case 200: return JsonSerializer.Deserialize<T>(await response.Content.ReadAsStreamAsync(timeout.Token), Json);
            // 400: the service can't use this song's details; asking again won't change that.
            case 400 or 404: return null;
            case 429: throw new RateLimitedException(response.Headers.RetryAfter?.Delta);
            default: throw new BadStatusException((int)response.StatusCode);
        }
    }

    internal static Record? BestMatch(IEnumerable<Record> records, string title, string artist, double duration)
    {
        var wantTitle = MusicText.Normalize(MusicText.LyricsTitle(title));
        var wantArtist = MusicText.Normalize(artist);
        (double Score, Record Record)? best = null;
        foreach (var record in records)
        {
            if (record.Duration is double d && duration > 0 && Math.Abs(d - duration) > 3) continue;
            var score = 0.0;
            var gotTitle = MusicText.Normalize(record.TrackName ?? "");
            var gotArtist = MusicText.Normalize(record.ArtistName ?? "");
            if (gotTitle == wantTitle) score += 3; else if (gotTitle.Contains(wantTitle)) score += 1.5;
            if (gotArtist == wantArtist) score += 3;
            else if (gotArtist.Contains(wantArtist) || wantArtist.Contains(gotArtist)) score += 1.5;
            if (!string.IsNullOrEmpty(record.SyncedLyrics)) score += 1;
            if (score >= 4 && score > (best?.Score ?? 0)) best = (score, record);
        }
        return best?.Record;
    }

    private static LyricsContent? Content(Record record)
    {
        if (!string.IsNullOrEmpty(record.SyncedLyrics)) return new LyricsContent.Synced(record.SyncedLyrics);
        if (!string.IsNullOrEmpty(record.PlainLyrics)) return new LyricsContent.Plain(record.PlainLyrics);
        if (record.Instrumental == true) return new LyricsContent.Instrumental();
        return null;
    }

    internal static string CleanAlbum(string album) =>
        Regex.Replace(album, @"\s+-\s+(single|ep)$", "", RegexOptions.IgnoreCase);

    internal static string CacheKey(string title, string artist, string album, double duration)
    {
        var raw = string.Join('|', title, artist, album,
            ((int)Math.Round(duration, MidpointRounding.AwayFromZero)).ToString(CultureInfo.InvariantCulture)).ToLowerInvariant();
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(raw))).ToLowerInvariant();
    }

    internal static string Query(IEnumerable<(string Name, string Value)> items) =>
        string.Join('&', items.Select(i => Uri.EscapeDataString(i.Name) + "=" + Uri.EscapeDataString(i.Value)));
}

/// Word-timed lyrics from the Apple Music API, with the user's own tokens: a developer
/// token (paid Apple Developer Program) and a Music User Token (their subscription).
/// Without both, Islet uses LRCLIB alone. Any failure here just falls back to LRCLIB.
public sealed class AppleMusicLyricsClient(HttpClient http, string? cacheDirectory = null)
{
    public sealed class UnauthorizedException() : Exception("Apple Music refused the tokens");

    public sealed record Credentials(string DeveloperToken, string UserToken, string Storefront);

    private sealed class Holder { public string? Ttml { get; init; } }
    private readonly DiskCache<Holder> _cache = new(cacheDirectory);

    internal sealed record Song(string Id, string? Name, string? ArtistName, double? DurationInMillis);

    /// The song's lyrics as TTML, or null when Apple has none for it.
    public async Task<string?> TtmlAsync(string title, string artist, double duration, Credentials credentials, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(title) || string.IsNullOrWhiteSpace(artist)) return null;
        var key = "am-" + LRCLIBClient.CacheKey(title, artist, credentials.Storefront, duration);
        if (_cache.TryGet(key, out var cached)) return cached?.Ttml;

        string? ttml = null;
        if (await SongId(title, artist, duration, credentials, ct) is string id)
        {
            // Word timing first; plain "lyrics" may still be timed by line.
            ttml = await Lyrics(id, "syllable-lyrics", credentials, ct) ?? await Lyrics(id, "lyrics", credentials, ct);
        }
        _cache.Set(key, ttml is null ? null : new Holder { Ttml = ttml });
        return ttml;
    }

    private async Task<string?> SongId(string title, string artist, double duration, Credentials c, CancellationToken ct)
    {
        var clean = MusicText.LyricsTitle(title);
        var json = await Fetch("search", [("term", $"{clean} {MusicText.PrimaryArtist(artist)}"), ("types", "songs"), ("limit", "10")], c, ct);
        var data = json?["results"]?["songs"]?["data"]?.AsArray();
        if (data is null) return null;
        var songs = data.Select(item => new Song(
            item?["id"]?.GetValue<string>() ?? "",
            item?["attributes"]?["name"]?.GetValue<string>(),
            item?["attributes"]?["artistName"]?.GetValue<string>(),
            item?["attributes"]?["durationInMillis"]?.GetValue<double>())).ToList();
        return BestMatch(songs, clean, artist, duration);
    }

    private async Task<string?> Lyrics(string id, string kind, Credentials c, CancellationToken ct)
    {
        var json = await Fetch($"songs/{Uri.EscapeDataString(id)}/{kind}", [], c, ct);
        var ttml = json?["data"]?[0]?["attributes"]?["ttml"]?.GetValue<string>();
        return string.IsNullOrEmpty(ttml) ? null : ttml;
    }

    private async Task<JsonNode?> Fetch(string path, List<(string, string)> items, Credentials c, CancellationToken ct)
    {
        var storefront = Uri.EscapeDataString(c.Storefront);
        var url = $"https://api.music.apple.com/v1/catalog/{storefront}/{path}" + (items.Count > 0 ? "?" + LRCLIBClient.Query(items) : "");
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", c.DeveloperToken);
        request.Headers.TryAddWithoutValidation("Music-User-Token", c.UserToken);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(12));
        using var response = await http.SendAsync(request, timeout.Token);
        switch ((int)response.StatusCode)
        {
            case 200:
                try { return JsonNode.Parse(await response.Content.ReadAsStringAsync(timeout.Token)); }
                catch (JsonException) { return null; }
            case 204 or 400 or 404: return null;
            case 401 or 403: throw new UnauthorizedException();
            default: throw new LRCLIBClient.BadStatusException((int)response.StatusCode);
        }
    }

    internal static string? BestMatch(IEnumerable<Song> songs, string title, string artist, double duration)
    {
        var wantTitle = MusicText.Normalize(MusicText.LyricsTitle(title));
        var wantArtist = MusicText.Normalize(artist);
        (double Score, string Id)? best = null;
        foreach (var song in songs)
        {
            if (song.DurationInMillis is double millis && duration > 0 && Math.Abs(millis / 1000 - duration) > 3) continue;
            var gotTitle = MusicText.Normalize(MusicText.LyricsTitle(song.Name ?? ""));
            var gotArtist = MusicText.Normalize(song.ArtistName ?? "");
            var score = 0.0;
            if (gotTitle == wantTitle) score += 3; else if (gotTitle.Contains(wantTitle) || wantTitle.Contains(gotTitle)) score += 1.5;
            if (gotArtist == wantArtist) score += 3; else if (gotArtist.Contains(wantArtist) || wantArtist.Contains(gotArtist)) score += 1.5;
            if (score >= 4.5 && score > (best?.Score ?? 0)) best = (score, song.Id);
        }
        return best?.Id;
    }
}

/// An album in the Apple catalog, found through the keyless iTunes Search API.
public sealed record CatalogAlbum(long CollectionId, string Name, string Artist, string? ArtworkTemplate)
{
    public Uri? ArtworkUrl(int size) => ArtworkTemplate is null ? null : MusicText.ResizedArtworkUrl(ArtworkTemplate, size);
}

/// Finds the playing album in the iTunes catalog (≈20 requests/min limit, so results are cached).
/// On Windows this is also how most players' missing or tiny thumbnails get a full-size cover.
public sealed class ITunesLookup(HttpClient http)
{
    private readonly Dictionary<string, CatalogAlbum?> _cache = [];

    internal sealed record Item(long? CollectionId, string? CollectionName, string? ArtistName, string? TrackName, string? ArtworkUrl100);
    private sealed record Response(List<Item> Results);
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    public async Task<CatalogAlbum?> AlbumAsync(string title, string artist, string album, string country)
    {
        var key = string.Join('|', new[] { artist, album, country }.Select(MusicText.Normalize));
        lock (_cache) if (_cache.TryGetValue(key, out var hit)) return hit;
        var found = await Search($"{title} {artist}", "song", title, artist, album, country);
        if (found is null && album.Length > 0) found = await Search($"{artist} {album}", "album", null, artist, album, country);
        lock (_cache) _cache[key] = found;
        return found;
    }

    private async Task<CatalogAlbum?> Search(string term, string entity, string? title, string artist, string album, string country)
    {
        var url = "https://itunes.apple.com/search?" + LRCLIBClient.Query([
            ("term", term), ("entity", entity), ("media", "music"), ("limit", "15"), ("country", country)]);
        try
        {
            using var response = await http.GetAsync(url);
            if (response.StatusCode != HttpStatusCode.OK) return null;
            var decoded = JsonSerializer.Deserialize<Response>(await response.Content.ReadAsStreamAsync(), Json);
            return decoded is null ? null : Best(decoded.Results, title, artist, album);
        }
        catch { return null; }
    }

    internal static CatalogAlbum? Best(IEnumerable<Item> items, string? title, string artist, string album)
    {
        var wantArtist = MusicText.Normalize(artist);
        var wantAlbum = MusicText.Normalize(album);
        var wantTitle = title is null ? null : MusicText.Normalize(title);
        (double Score, CatalogAlbum Album)? best = null;
        foreach (var item in items)
        {
            if (item.CollectionId is not long id) continue;
            var gotArtist = MusicText.Normalize(item.ArtistName ?? "");
            var gotAlbum = MusicText.Normalize(item.CollectionName ?? "");
            var score = 0.0;
            if (gotArtist == wantArtist) score += 3;
            else if (gotArtist.Contains(wantArtist) || wantArtist.Contains(gotArtist)) score += 1.5;
            else continue;
            if (wantAlbum.Length > 0)
            {
                if (gotAlbum == wantAlbum) score += 3;
                else if (gotAlbum.Contains(wantAlbum) || wantAlbum.Contains(gotAlbum)) score += 1.5;
            }
            if (wantTitle is not null && MusicText.Normalize(item.TrackName ?? "") == wantTitle) score += 2;
            if (score >= 4.5 && score > (best?.Score ?? 0))
                best = (score, new CatalogAlbum(id, item.CollectionName ?? "", item.ArtistName ?? "", item.ArtworkUrl100));
        }
        return best?.Album;
    }
}

/// HLS URLs for an album's motion artwork.
public sealed record MotionArtwork(Uri? Square, Uri? Tall)
{
    /// Parses `data[0].attributes.editorialVideo` from an Apple Music API album response.
    public static MotionArtwork? Parse(string albumResponse)
    {
        JsonNode? video;
        try { video = JsonNode.Parse(albumResponse)?["data"]?[0]?["attributes"]?["editorialVideo"]; }
        catch (JsonException) { return null; }
        if (video is not JsonObject) return null;
        Uri? Url(params string[] keys)
        {
            foreach (var key in keys)
                if (video[key]?["video"] is JsonValue v && v.TryGetValue<string>(out var s) && Uri.TryCreate(s, UriKind.Absolute, out var u))
                    return u;
            return null;
        }
        var art = new MotionArtwork(Url("motionDetailSquare", "motionSquareVideo1x1"), Url("motionDetailTall", "motionTallVideo3x4"));
        return art.Square is null && art.Tall is null ? null : art;
    }
}

/// Official Apple Music API access for motion (video) album artwork. Needs a developer token;
/// Apple doesn't offer `editorialVideo` to third parties, so null is the expected norm.
public sealed record AppleMusicCatalog(string DeveloperToken, string Storefront)
{
    public async Task<MotionArtwork?> MotionArtworkAsync(long albumId, HttpClient http)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get,
            $"https://api.music.apple.com/v1/catalog/{Uri.EscapeDataString(Storefront)}/albums/{albumId}?extend=editorialVideo");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", DeveloperToken);
        try
        {
            using var response = await http.SendAsync(request);
            return response.StatusCode == HttpStatusCode.OK ? MotionArtwork.Parse(await response.Content.ReadAsStringAsync()) : null;
        }
        catch { return null; }
    }
}
