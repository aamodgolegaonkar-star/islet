using System.Security.Cryptography;

namespace Islet.Core;

/// The pure pieces of Portal (phone ⇄ PC over the local network): reading HTTP requests,
/// making received file names safe, and pairing secrets. Kept here, away from sockets and
/// UI, because every one of them stands between the network and the disk.
public static class Portal
{
    /// The fixed port, so a Home Screen web app saved on the phone keeps working.
    public const ushort Port = 47474;
    /// Largest request head (request line plus headers) accepted.
    public const int MaxHeadBytes = 16 * 1024;
    /// Largest file accepted in one request (a long 4K video fits).
    public const long MaxFileBytes = 8L * 1024 * 1024 * 1024;
    /// Largest text or link accepted.
    public const int MaxTextBytes = 1024 * 1024;
    /// How long a QR pairing code works.
    public static readonly TimeSpan PairingLifetime = TimeSpan.FromMinutes(5);

    /// A response's bytes: status line, headers, then the body.
    public static byte[] ResponseHead(int status, string reason, string contentType, long length,
                                      IReadOnlyDictionary<string, string>? extra = null)
    {
        var text = new StringBuilder($"HTTP/1.1 {status} {reason}\r\nContent-Type: {contentType}\r\nContent-Length: {length}\r\n");
        text.Append("Connection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n");
        foreach (var (name, value) in (extra ?? new Dictionary<string, string>()).OrderBy(p => p.Key, StringComparer.Ordinal))
            text.Append($"{name}: {value}\r\n");
        return Encoding.UTF8.GetBytes(text.Append("\r\n").ToString());
    }

    /// Only web links are ever opened from a phone; anything else is just copied.
    public static Uri? OpenableLink(string text)
    {
        var trimmed = text.Trim();
        if (trimmed.Any(char.IsWhiteSpace) || !Uri.TryCreate(trimmed, UriKind.Absolute, out var url)) return null;
        var scheme = url.Scheme.ToLowerInvariant();
        return (scheme is "http" or "https") && !string.IsNullOrEmpty(url.Host) ? url : null;
    }
}

/// A parsed request head. The body follows it on the connection; `ContentLength` says how much.
public sealed record PortalRequestHead(string Method, string Path, IReadOnlyDictionary<string, string> Query,
                                       IReadOnlyDictionary<string, string> Headers, long ContentLength)
{
    public string? Header(string name) => Headers.TryGetValue(name.ToLowerInvariant(), out var v) ? v : null;

    public abstract record ParseResult
    {
        /// More bytes are needed before the head is complete.
        public sealed record Incomplete : ParseResult;
        /// The head and how many bytes of the data it used (the body starts there).
        public sealed record Complete(PortalRequestHead Head, int HeadLength) : ParseResult;
        public sealed record Invalid : ParseResult;
    }

    private static readonly byte[] End = "\r\n\r\n"u8.ToArray();

    /// Parses the head at the start of `data`, if it has all arrived.
    public static ParseResult Parse(ReadOnlySpan<byte> data)
    {
        var end = data.IndexOf(End);
        if (end < 0) return data.Length > Portal.MaxHeadBytes ? new ParseResult.Invalid() : new ParseResult.Incomplete();
        var headLength = end + End.Length;
        if (headLength > Portal.MaxHeadBytes) return new ParseResult.Invalid();
        string text;
        try { text = new UTF8Encoding(false, true).GetString(data[..end]); }
        catch (DecoderFallbackException) { return new ParseResult.Invalid(); }

        var lines = text.Split("\r\n");
        var requestLine = lines[0].Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (requestLine.Length != 3 || !requestLine[2].StartsWith("HTTP/1.") || !requestLine[1].StartsWith('/'))
            return new ParseResult.Invalid();
        var target = requestLine[1];
        var question = target.IndexOf('?');
        var rawPath = question < 0 ? target : target[..question];
        if (rawPath.Contains('#')) rawPath = rawPath[..rawPath.IndexOf('#')];
        string path;
        try { path = Uri.UnescapeDataString(rawPath); } catch (UriFormatException) { return new ParseResult.Invalid(); }

        var headers = new Dictionary<string, string>();
        foreach (var line in lines.Skip(1))
        {
            var colon = line.IndexOf(':');
            if (colon < 0) return new ParseResult.Invalid();
            var name = line[..colon].Trim().ToLowerInvariant();
            if (name.Length == 0) return new ParseResult.Invalid();
            headers[name] = line[(colon + 1)..].Trim();
        }
        // No chunked uploads: every client here (the page, Shortcuts) sends a length.
        if (headers.ContainsKey("transfer-encoding")) return new ParseResult.Invalid();
        long length = 0;
        if (headers.TryGetValue("content-length", out var value))
        {
            if (!long.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out length) || length < 0)
                return new ParseResult.Invalid();
        }
        var query = new Dictionary<string, string>();
        if (question >= 0)
        {
            var rawQuery = target[(question + 1)..];
            if (rawQuery.Contains('#')) rawQuery = rawQuery[..rawQuery.IndexOf('#')];
            foreach (var item in rawQuery.Split('&', StringSplitOptions.RemoveEmptyEntries))
            {
                var eq = item.IndexOf('=');
                try
                {
                    var k = Uri.UnescapeDataString(eq < 0 ? item : item[..eq]);
                    query[k] = eq < 0 ? "" : Uri.UnescapeDataString(item[(eq + 1)..]);
                }
                catch (UriFormatException) { return new ParseResult.Invalid(); }
            }
        }
        return new ParseResult.Complete(new PortalRequestHead(requestLine[0], path, query, headers, length), headLength);
    }
}

public static class PortalFilename
{
    private static readonly HashSet<string> Reserved = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    };

    /// A name that is safe to create inside the save folder: no folders, no hidden or special
    /// names, no control characters, a sane length. Falls back to `fallback`. On Windows it also
    /// drops the characters NTFS forbids and the reserved device names (CON, NUL, COM1…).
    public static string Sanitize(string raw, string fallback = "Portal Item")
    {
        // Only the last path component, whichever separator the sender used.
        var last = raw.Split(['/', '\\', ':'], StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? "";
        var name = new string(last.Where(c => !char.IsControl(c) && "<>\"|?*".IndexOf(c) < 0).ToArray()).Trim();
        name = name.TrimStart('.');
        // Windows ignores trailing dots and spaces, which would let two names collide.
        name = name.TrimEnd('.', ' ');
        if (Reserved.Contains(System.IO.Path.GetFileNameWithoutExtension(name))) name = "_" + name;
        if (name.Length == 0) name = fallback;
        // Keep the extension when shortening.
        if (Encoding.UTF8.GetByteCount(name) > 200)
        {
            var ext = Extension(name);
            var stem = ext.Length == 0 ? name : name[..^(ext.Length + 1)];
            var shortened = new StringBuilder();
            foreach (var element in Graphemes(stem))
            {
                if (Encoding.UTF8.GetByteCount(shortened + element) >= 180) break;
                shortened.Append(element);
            }
            name = ext.Length == 0 || Encoding.UTF8.GetByteCount(ext) > 16 ? shortened.ToString() : $"{shortened}.{ext}";
        }
        return name;
    }

    /// `name` inside `folder`, numbered ("Photo 2.jpg") if that file already exists.
    public static string Unique(string name, string folder, Func<string, bool> exists)
    {
        var first = System.IO.Path.Combine(folder, name);
        if (!exists(first)) return first;
        var ext = Extension(name);
        var stem = ext.Length == 0 ? name : name[..^(ext.Length + 1)];
        for (var number = 2; number < int.MaxValue; number++)
        {
            var candidate = System.IO.Path.Combine(folder, ext.Length == 0 ? $"{stem} {number}" : $"{stem} {number}.{ext}");
            if (!exists(candidate)) return candidate;
        }
        return first;
    }

    /// NSString.pathExtension: the text after the last dot, if the dot isn't the first character.
    private static string Extension(string name)
    {
        var dot = name.LastIndexOf('.');
        return dot <= 0 || dot == name.Length - 1 ? "" : name[(dot + 1)..];
    }

    private static IEnumerable<string> Graphemes(string s)
    {
        var e = StringInfo.GetTextElementEnumerator(s);
        while (e.MoveNext()) yield return (string)e.Current;
    }
}

public static class PortalSecret
{
    /// A new random secret (256 bits), URL-safe.
    public static string Make() =>
        Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)).Replace('+', '-').Replace('/', '_').TrimEnd('=');

    /// What is stored for a paired phone: the hash, never the token itself.
    public static string Hash(string token) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(token))).ToLowerInvariant();

    /// Whether `token` matches a stored hash, comparing in constant time.
    public static bool Matches(string token, string storedHash) =>
        CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(Hash(token)), Encoding.UTF8.GetBytes(storedHash));
}

/// The QR code's one-time pairing code: good once, for a few minutes.
public sealed class PortalPairingCode
{
    public string Code { get; } = PortalSecret.Make();
    public DateTime Expires { get; }
    public bool Used { get; private set; }

    public PortalPairingCode(DateTime? now = null) => Expires = (now ?? DateTime.UtcNow) + Portal.PairingLifetime;

    /// Accepts `candidate` once, before it expires.
    public bool Redeem(string candidate, DateTime? now = null)
    {
        if (Used || (now ?? DateTime.UtcNow) >= Expires || !PortalSecret.Matches(candidate, PortalSecret.Hash(Code))) return false;
        Used = true;
        return true;
    }
}
