using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Islet.Core;

/// Islet Link: the wire format shared with the Android app (`Android/…/link/Wire.kt`) and the
/// Mac app. Change all sides together; `link-vectors.json` pins the crypto.
///
/// Every frame on the stream (TCP over Wi-Fi or USB) is a 4-byte big-endian length and that
/// many bytes. Before the handshake the bytes are a plain message; after it they are AES-GCM
/// sealed, each direction with its own key and a counter nonce, so nothing on the network can
/// read, change, replay or reorder them.
///
/// A message is a 4-byte big-endian header length, a JSON object (`"t"` names it), then an
/// optional binary body (artwork, an icon, a file chunk).
public static class Link
{
    public const ushort Port = 47480;
    /// DNS-SD service type, the same one the Mac advertises with Bonjour.
    public const string ServiceType = "_islet-link._tcp";
    public const int Version = 1;
    /// Upper bound on one frame, so a broken peer can't make us allocate gigabytes.
    public const int MaxFrame = 4 << 20;
    /// File chunks: big enough to keep a link busy, small enough to interleave controls.
    public const int ChunkSize = 512 << 10;
}

/// One message: a JSON header and an optional binary body.
public sealed class LinkMessage
{
    public byte[] Header { get; }
    public byte[] Body { get; }

    public LinkMessage(byte[] header, byte[]? body = null)
    {
        Header = header;
        Body = body ?? [];
    }

    /// `fields` values must be JSON-encodable: string, bool, numbers, null, lists, dictionaries.
    public LinkMessage(string type, IReadOnlyDictionary<string, object?>? fields = null, byte[]? body = null)
    {
        var all = new Dictionary<string, object?>(fields ?? new Dictionary<string, object?>()) { ["t"] = type };
        Header = Encoding.UTF8.GetBytes(LinkJson.Write(all));
        Body = body ?? [];
    }

    private JsonObject? _fields;
    public JsonObject Fields => _fields ??= ParseFields();

    private JsonObject ParseFields()
    {
        try { return JsonNode.Parse(Header) as JsonObject ?? []; }
        catch (JsonException) { return []; }
    }

    public string Type => Fields["t"] is JsonValue v && v.TryGetValue<string>(out var s) ? s : "";

    public string? String(string key) => Fields[key] is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;
    public double? Number(string key) => Fields[key] is JsonValue v && v.TryGetValue<double>(out var d) ? d : null;
    public bool? Bool(string key) => Fields[key] is JsonValue v && v.TryGetValue<bool>(out var b) ? b : null;

    public byte[] Encoded()
    {
        var output = new byte[4 + Header.Length + Body.Length];
        BinaryPrimitives.WriteUInt32BigEndian(output, (uint)Header.Length);
        Header.CopyTo(output, 4);
        Body.CopyTo(output, 4 + Header.Length);
        return output;
    }

    public static LinkMessage? Decode(ReadOnlySpan<byte> data)
    {
        if (data.Length < 4) return null;
        var length = BinaryPrimitives.ReadUInt32BigEndian(data);
        if (length > data.Length - 4) return null;
        return new LinkMessage(data.Slice(4, (int)length).ToArray(), data[(4 + (int)length)..].ToArray());
    }
}

/// JSON exactly as Foundation's JSONSerialization writes it with `.sortedKeys`: compact,
/// keys in order, "/" escaped, non-ASCII kept. The header bytes are pinned by the test vectors.
internal static class LinkJson
{
    public static string Write(object? value)
    {
        var sb = new StringBuilder();
        Append(sb, value);
        return sb.ToString();
    }

    private static void Append(StringBuilder sb, object? value)
    {
        switch (value)
        {
            case null: sb.Append("null"); break;
            case bool b: sb.Append(b ? "true" : "false"); break;
            case string s: AppendString(sb, s); break;
            case int or long or short or byte or uint or ushort or ulong or sbyte:
                sb.Append(Convert.ToString(value, CultureInfo.InvariantCulture)); break;
            case double d: AppendDouble(sb, d); break;
            case float f: AppendDouble(sb, f); break;
            case decimal m: sb.Append(m.ToString(CultureInfo.InvariantCulture)); break;
            case JsonNode node: sb.Append(node.ToJsonString()); break;
            case IReadOnlyDictionary<string, object?> dict: AppendObject(sb, dict); break;
            case IDictionary<string, object?> dict: AppendObject(sb, dict.AsReadOnly()); break;
            case System.Collections.IEnumerable list:
                sb.Append('[');
                var first = true;
                foreach (var item in list)
                {
                    if (!first) sb.Append(',');
                    first = false;
                    Append(sb, item);
                }
                sb.Append(']');
                break;
            default: throw new ArgumentException($"Not JSON-encodable: {value.GetType()}");
        }
    }

    private static void AppendObject(StringBuilder sb, IReadOnlyDictionary<string, object?> dict)
    {
        sb.Append('{');
        var first = true;
        foreach (var key in dict.Keys.OrderBy(k => k, StringComparer.Ordinal))
        {
            if (!first) sb.Append(',');
            first = false;
            AppendString(sb, key);
            sb.Append(':');
            Append(sb, dict[key]);
        }
        sb.Append('}');
    }

    private static void AppendDouble(StringBuilder sb, double d)
    {
        if (!double.IsFinite(d)) throw new ArgumentException("JSON has no NaN or infinity");
        // Whole numbers print without a fraction, like JSONSerialization.
        sb.Append(d == Math.Floor(d) && Math.Abs(d) < 1e15 ? ((long)d).ToString(CultureInfo.InvariantCulture)
                                                          : d.ToString("R", CultureInfo.InvariantCulture));
    }

    private static void AppendString(StringBuilder sb, string s)
    {
        sb.Append('"');
        foreach (var c in s)
        {
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '/': sb.Append("\\/"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                case '\b': sb.Append("\\b"); break;
                case '\f': sb.Append("\\f"); break;
                default:
                    if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4"));
                    else sb.Append(c);
                    break;
            }
        }
        sb.Append('"');
    }
}

/// Splits a byte stream into frames.
public sealed class LinkFrameReader
{
    private byte[] _buffer = new byte[4096];
    private int _count;
    public bool Failed { get; private set; }

    /// Adds received bytes; returns every complete frame. A frame over `Link.MaxFrame` marks
    /// the stream as failed (the caller drops the connection).
    public List<byte[]> Push(ReadOnlySpan<byte> bytes)
    {
        var frames = new List<byte[]>();
        if (Failed) return frames;
        if (_count + bytes.Length > _buffer.Length)
            Array.Resize(ref _buffer, Math.Max(_buffer.Length * 2, _count + bytes.Length));
        bytes.CopyTo(_buffer.AsSpan(_count));
        _count += bytes.Length;
        var offset = 0;
        while (_count - offset >= 4)
        {
            var length = BinaryPrimitives.ReadUInt32BigEndian(_buffer.AsSpan(offset));
            if (length > Link.MaxFrame) { Failed = true; break; }
            if (_count - offset < 4 + length) break;
            frames.Add(_buffer.AsSpan(offset + 4, (int)length).ToArray());
            offset += 4 + (int)length;
        }
        if (offset > 0)
        {
            Buffer.BlockCopy(_buffer, offset, _buffer, 0, _count - offset);
            _count -= offset;
        }
        return frames;
    }

    public static byte[] Frame(ReadOnlySpan<byte> payload)
    {
        var output = new byte[payload.Length + 4];
        BinaryPrimitives.WriteUInt32BigEndian(output, (uint)payload.Length);
        payload.CopyTo(output.AsSpan(4));
        return output;
    }
}

/// Pairing and session keys.
public static class LinkCrypto
{
    /// `Secret`: the long-term key both sides keep for this pair. `Code`: six digits both
    /// screens show; matching codes mean nobody sits in between.
    public sealed record Pairing(byte[] Secret, string Code);

    /// From an ECDH (P-256) shared secret and both public keys (X9.63, 65 bytes each).
    /// The computer side keeps the Mac's role and name ("mac") so phones pair unchanged.
    public static Pairing MakePairing(byte[] shared, byte[] macKey, byte[] phoneKey)
    {
        var salt = Concat(macKey, phoneKey);
        var secret = HKDF.DeriveKey(HashAlgorithmName.SHA256, shared, 32, salt, Encoding.UTF8.GetBytes("islet-link pair v1"));
        var sas = HKDF.DeriveKey(HashAlgorithmName.SHA256, shared, 4, salt, Encoding.UTF8.GetBytes("islet-link code v1"));
        var number = BinaryPrimitives.ReadUInt32BigEndian(sas) % 1_000_000;
        return new Pairing(secret, number.ToString("D6", CultureInfo.InvariantCulture));
    }

    /// Per-connection keys from the pair's secret and both hello nonces.
    public static (byte[] MacToPhone, byte[] PhoneToMac) Session(byte[] secret, byte[] macNonce, byte[] phoneNonce)
    {
        var keys = HKDF.DeriveKey(HashAlgorithmName.SHA256, secret, 64, Concat(macNonce, phoneNonce),
                                  Encoding.UTF8.GetBytes("islet-link session v1"));
        return (keys[..32], keys[32..]);
    }

    public static byte[] RandomNonce() => RandomNumberGenerator.GetBytes(32);

    /// A new P-256 key pair for pairing.
    public static ECDiffieHellman NewKey() => ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);

    /// A key pair from its raw 32-byte private scalar (tests, and keys kept in storage).
    public static ECDiffieHellman KeyFromPrivate(byte[] d)
    {
        // Derive Q on the curve so every platform accepts the import.
        using var signer = ECDsa.Create(new ECParameters { Curve = ECCurve.NamedCurves.nistP256, D = d });
        var full = signer.ExportParameters(true);
        return ECDiffieHellman.Create(full);
    }

    /// The public key in X9.63 form: 0x04 ‖ X ‖ Y.
    public static byte[] X963(ECDiffieHellman key)
    {
        var q = key.ExportParameters(false).Q;
        return [0x04, .. q.X!, .. q.Y!];
    }

    /// The raw ECDH shared secret (the X coordinate), like CryptoKit's SharedSecret bytes.
    public static byte[] SharedSecret(ECDiffieHellman mine, byte[] peerX963)
    {
        if (peerX963.Length != 65 || peerX963[0] != 0x04) throw new CryptographicException("Bad public key");
        using var peer = ECDiffieHellman.Create(new ECParameters
        {
            Curve = ECCurve.NamedCurves.nistP256,
            Q = new ECPoint { X = peerX963[1..33], Y = peerX963[33..] },
        });
        return mine.DeriveRawSecretAgreement(peer.PublicKey);
    }

    internal static byte[] Concat(byte[] a, byte[] b) => [.. a, .. b];
}

/// One direction of an encrypted stream: AES-256-GCM, nonce = 4 zero bytes + 8-byte counter.
public sealed class LinkCipher(byte[] key) : IDisposable
{
    private readonly AesGcm _aes = new(key, 16);
    private ulong _counter;

    public byte[] Seal(ReadOnlySpan<byte> plain)
    {
        var output = new byte[plain.Length + 16];
        _aes.Encrypt(Nonce(), plain, output.AsSpan(0, plain.Length), output.AsSpan(plain.Length));
        _counter++;
        return output;
    }

    /// The counter only moves on success, so a frame that fails (a plain one arriving before
    /// the other side switched to encryption) can still be read another way.
    public byte[] Open(ReadOnlySpan<byte> sealedBytes)
    {
        if (sealedBytes.Length < 16) throw new AuthenticationTagMismatchException();
        var plain = new byte[sealedBytes.Length - 16];
        _aes.Decrypt(Nonce(), sealedBytes[..^16], sealedBytes[^16..], plain);
        _counter++;
        return plain;
    }

    private byte[] Nonce()
    {
        var nonce = new byte[12];
        BinaryPrimitives.WriteUInt64BigEndian(nonce.AsSpan(4), _counter);
        return nonce;
    }

    public void Dispose() => _aes.Dispose();
}
