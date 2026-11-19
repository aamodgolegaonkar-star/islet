using System.Text.Json;
using Islet.Core;
using Xunit;

namespace IsletCore.Tests;

public class LinkTests
{
    private static readonly Dictionary<string, string> Vectors =
        JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "link-vectors.json")))!;

    private static byte[] Hex(string key) => Convert.FromHexString(Vectors[key]);

    [Fact]
    public void PairingMatchesVectors()
    {
        using var mac = LinkCrypto.KeyFromPrivate(Hex("macPrivate"));
        using var phone = LinkCrypto.KeyFromPrivate(Hex("phonePrivate"));
        Assert.Equal(Hex("macPublic"), LinkCrypto.X963(mac));
        Assert.Equal(Hex("phonePublic"), LinkCrypto.X963(phone));
        var shared = LinkCrypto.SharedSecret(mac, LinkCrypto.X963(phone));
        Assert.Equal(Hex("shared"), shared);
        var pairing = LinkCrypto.MakePairing(shared, Hex("macPublic"), Hex("phonePublic"));
        Assert.Equal(Hex("secret"), pairing.Secret);
        Assert.Equal(Vectors["code"], pairing.Code);
    }

    [Fact]
    public void SessionAndCipherMatchVectors()
    {
        var (macToPhone, phoneToMac) = LinkCrypto.Session(Hex("secret"), Hex("macNonce"), Hex("phoneNonce"));
        Assert.Equal(Hex("macToPhone"), macToPhone);
        Assert.Equal(Hex("phoneToMac"), phoneToMac);
        using var seal = new LinkCipher(macToPhone);
        var first = seal.Seal("hello"u8);
        var second = seal.Seal("hello"u8);
        Assert.Equal(Hex("sealed0"), first);
        Assert.Equal(Hex("sealed1"), second);
        using var open = new LinkCipher(macToPhone);
        Assert.Equal("hello"u8.ToArray(), open.Open(first));
        Assert.Equal("hello"u8.ToArray(), open.Open(second));
    }

    [Fact]
    public void ReplayedOrTamperedFramesFail()
    {
        var key = Enumerable.Repeat((byte)7, 32).ToArray();
        using var seal = new LinkCipher(key);
        var frame = seal.Seal("x"u8);
        using var open = new LinkCipher(key);
        open.Open(frame);
        Assert.ThrowsAny<Exception>(() => open.Open(frame));
        var tampered = (byte[])frame.Clone();
        tampered[0] ^= 1;
        using var fresh = new LinkCipher(key);
        Assert.ThrowsAny<Exception>(() => fresh.Open(tampered));
        // A failed open doesn't move the counter, so the genuine frame still opens.
        Assert.Equal("x"u8.ToArray(), fresh.Open(frame));
    }

    [Fact]
    public void MessageRoundTripAndFraming()
    {
        var message = new LinkMessage("media.state", new Dictionary<string, object?> { ["title"] = "Song", ["playing"] = true }, [1, 2, 3]);
        var frame = LinkFrameReader.Frame(message.Encoded());
        var reader = new LinkFrameReader();
        Assert.Empty(reader.Push(frame.AsSpan(0, 3)));
        var frames = reader.Push([.. frame.AsSpan(3), .. frame]);
        Assert.Equal(2, frames.Count);
        var decoded = LinkMessage.Decode(frames[0]);
        Assert.Equal("media.state", decoded?.Type);
        Assert.Equal("Song", decoded?.String("title"));
        Assert.Equal([1, 2, 3], decoded?.Body);
        Assert.Equal(Vectors["message"], Convert.ToHexString(message.Encoded()).ToLowerInvariant());
    }

    [Fact]
    public void HeaderJsonMatchesFoundation()
    {
        var m = new LinkMessage("x", new Dictionary<string, object?> { ["url"] = "a/b", ["n"] = 3, ["f"] = 1.5, ["é"] = "ü" });
        Assert.Equal("{\"f\":1.5,\"n\":3,\"t\":\"x\",\"url\":\"a\\/b\",\"é\":\"ü\"}", Encoding.UTF8.GetString(m.Header));
    }

    [Fact]
    public void OversizedFrameFails()
    {
        var reader = new LinkFrameReader();
        var bad = new byte[4];
        System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(bad, Link.MaxFrame + 1);
        reader.Push(bad);
        Assert.True(reader.Failed);
    }

    [Fact]
    public void FreshKeysAgree()
    {
        using var a = LinkCrypto.NewKey();
        using var b = LinkCrypto.NewKey();
        Assert.Equal(LinkCrypto.SharedSecret(a, LinkCrypto.X963(b)), LinkCrypto.SharedSecret(b, LinkCrypto.X963(a)));
        Assert.Throws<System.Security.Cryptography.CryptographicException>(() => LinkCrypto.SharedSecret(a, new byte[10]));
    }
}

public class PortalTests
{
    [Fact]
    public void ParsesHeadAndBodyStart()
    {
        var raw = "POST /send?kind=file HTTP/1.1\r\nHost: mac.local\r\nX-Islet-Token: abc\r\nContent-Length: 5\r\n\r\nhello"u8.ToArray();
        var result = Assert.IsType<PortalRequestHead.ParseResult.Complete>(PortalRequestHead.Parse(raw));
        Assert.Equal("POST", result.Head.Method);
        Assert.Equal("/send", result.Head.Path);
        Assert.Equal("file", result.Head.Query["kind"]);
        Assert.Equal("abc", result.Head.Header("x-islet-token"));
        Assert.Equal(5, result.Head.ContentLength);
        Assert.Equal("hello", Encoding.UTF8.GetString(raw[result.HeadLength..]));
    }

    [Fact]
    public void WaitsForTheWholeHead() =>
        Assert.IsType<PortalRequestHead.ParseResult.Incomplete>(PortalRequestHead.Parse("GET / HTTP/1.1\r\nHost: x"u8));

    [Theory]
    [InlineData("GARBAGE\r\n\r\n")]
    [InlineData("POST /send HTTP/1.1\r\nContent-Length: -4\r\n\r\n")]
    [InlineData("POST /send HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")]
    [InlineData("GET http://evil/ HTTP/1.1\r\n\r\n")]
    public void RejectsBadRequests(string raw) =>
        Assert.IsType<PortalRequestHead.ParseResult.Invalid>(PortalRequestHead.Parse(Encoding.UTF8.GetBytes(raw)));

    [Fact]
    public void EndlessHeadIsCutOff() =>
        Assert.IsType<PortalRequestHead.ParseResult.Invalid>(PortalRequestHead.Parse(Enumerable.Repeat((byte)65, Portal.MaxHeadBytes + 1).ToArray()));

    [Fact]
    public void FileNamesCannotEscapeTheFolder()
    {
        Assert.Equal("authorized_keys", PortalFilename.Sanitize("../../.ssh/authorized_keys"));
        Assert.Equal("boot.ini", PortalFilename.Sanitize("..\\..\\boot.ini"));
        Assert.Equal("zshrc", PortalFilename.Sanitize(".zshrc"));
        Assert.Equal("Portal Item", PortalFilename.Sanitize("..."));
        Assert.Equal("Portal Item", PortalFilename.Sanitize(""));
        Assert.Equal("abc.jpg", PortalFilename.Sanitize("a\0b\nc.jpg"));
        Assert.Equal("IMG_0042.HEIC", PortalFilename.Sanitize("IMG_0042.HEIC"));
        var longName = PortalFilename.Sanitize(new string('x', 400) + ".mov");
        Assert.True(longName.EndsWith(".mov") && Encoding.UTF8.GetByteCount(longName) < 200);
    }

    [Fact]
    public void WindowsSpecialNamesAreDefused()
    {
        Assert.Equal("_CON.txt", PortalFilename.Sanitize("CON.txt"));
        Assert.Equal("_nul", PortalFilename.Sanitize("nul"));
        Assert.Equal("ab.txt", PortalFilename.Sanitize("a<b>.txt"));
        Assert.Equal("report", PortalFilename.Sanitize("report. . "));
        Assert.Equal("evil.exe", PortalFilename.Sanitize("C:evil.exe"));
    }

    [Fact]
    public void UniqueNamesNumberDuplicates()
    {
        var folder = Path.Combine("portal");
        var taken = new HashSet<string> { Path.Combine(folder, "Photo.jpg"), Path.Combine(folder, "Photo 2.jpg") };
        Assert.Equal("Photo 3.jpg", Path.GetFileName(PortalFilename.Unique("Photo.jpg", folder, taken.Contains)));
    }

    [Fact]
    public void TokensMatchOnlyTheirHash()
    {
        var token = PortalSecret.Make();
        var stored = PortalSecret.Hash(token);
        Assert.True(token.Length >= 43);
        Assert.True(PortalSecret.Matches(token, stored));
        Assert.False(PortalSecret.Matches(token + "x", stored));
        Assert.False(PortalSecret.Matches("", stored));
        Assert.NotEqual(token, PortalSecret.Make());
    }

    [Fact]
    public void PairingCodesWorkOnceAndExpire()
    {
        var start = DateTime.UtcNow;
        var code = new PortalPairingCode(start);
        var wrong = code.Redeem("wrong", start);
        var first = code.Redeem(code.Code, start.AddSeconds(10));
        var again = code.Redeem(code.Code, start.AddSeconds(11));
        Assert.True(!wrong && first && !again);
        var late = new PortalPairingCode(start);
        Assert.False(late.Redeem(late.Code, start + Portal.PairingLifetime + TimeSpan.FromSeconds(1)));
    }

    [Fact]
    public void OnlyWebLinksOpen()
    {
        Assert.Equal("example.com", Portal.OpenableLink(" https://example.com/a?b=1 ")?.Host);
        Assert.NotNull(Portal.OpenableLink("http://example.com"));
        Assert.Null(Portal.OpenableLink("file:///etc/passwd"));
        Assert.Null(Portal.OpenableLink("javascript:alert(1)"));
        Assert.Null(Portal.OpenableLink("ms-settings:privacy"));
        Assert.Null(Portal.OpenableLink("hello world https://a.com"));
    }
}

public class StandbyRuleTests
{
    private readonly StandbyConditions _ready = new(true, true, 301, 5, null, false, false, false);

    [Fact] public void StartsWhenIdleOnPower() => Assert.True(_ready.ShouldStart);

    [Fact]
    public void EachBlockerStopsIt()
    {
        Assert.False((_ready with { Enabled = false }).ShouldStart);
        Assert.False((_ready with { OnPower = false }).ShouldStart);
        Assert.False((_ready with { IdleSeconds = 299 }).ShouldStart);
        Assert.False((_ready with { ScreenLocked = true }).ShouldStart);
        Assert.False((_ready with { DisplayAsleep = true }).ShouldStart);
        Assert.False((_ready with { OtherAppHoldsDisplay = true }).ShouldStart);
    }

    [Fact]
    public void NeedsAFreshIdleStretchAfterDismissal()
    {
        Assert.False((_ready with { SinceDismissed = 100 }).ShouldStart);
        Assert.True((_ready with { SinceDismissed = 400 }).ShouldStart);
    }

    [Fact]
    public void StartsBeforeTheDisplayTurnsOff()
    {
        var c = _ready with { IdleSeconds = 100, SystemTimeout = 120 };
        Assert.Equal(100, c.WaitSeconds);
        Assert.True(c.ShouldStart);
        Assert.Equal(15, (c with { SystemTimeout = 10 }).WaitSeconds);
        c = c with { SystemTimeout = null };
        Assert.Equal(300, c.WaitSeconds);
        Assert.False(c.ShouldStart);
    }

    [Fact]
    public void LooksAgainWhenTheWaitRunsOut()
    {
        var idle = _ready with { IdleMinutes = 5, IdleSeconds = 100 };
        Assert.Equal(120, idle.NextCheck);
        idle = idle with { SystemTimeout = 140 };
        Assert.Equal(20, idle.NextCheck);
        Assert.True((idle with { IdleSeconds = 120 }).ShouldStart);
        Assert.Equal(30, (idle with { OnPower = false }).NextCheck);
    }
}

public class AgentEventTests
{
    [Fact]
    public void ClaudePermission() =>
        Assert.Equal(new AgentEvent(AgentEvent.EventKind.Permission, "Islet", "Claude needs your permission to use Bash"),
            AgentEvent.Claude("""{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash","cwd":"/Users/me/Islet"}"""));

    [Fact]
    public void ClaudeWaitingAndDone()
    {
        Assert.Equal(AgentEvent.EventKind.Waiting, AgentEvent.Claude("""{"hook_event_name":"Notification","message":"Claude is waiting for your input","cwd":"/a/b"}""")?.Kind);
        Assert.Equal(new AgentEvent(AgentEvent.EventKind.Done, "web", ""), AgentEvent.Claude("""{"hook_event_name":"Stop","cwd":"/a/web"}"""));
        Assert.Equal("Wants to use Edit", AgentEvent.Claude("""{"hook_event_name":"PermissionRequest","tool_name":"Edit"}""")?.Message);
        Assert.Null(AgentEvent.Claude("""{"hook_event_name":"PreToolUse"}"""));
        Assert.Null(AgentEvent.Claude("not json"));
    }

    [Fact]
    public void WindowsPathsGiveTheFolderName() =>
        Assert.Equal("api", AgentEvent.Claude("""{"hook_event_name":"Stop","cwd":"C:\\Users\\me\\api"}""")?.Project);

    [Fact]
    public void CodexTurnComplete()
    {
        Assert.Equal(new AgentEvent(AgentEvent.EventKind.Done, "api", "Fixed the build."),
            AgentEvent.Codex("""{"type":"agent-turn-complete","last-assistant-message":"Fixed the build.\nDetails…","cwd":"/x/api"}"""));
        Assert.Null(AgentEvent.Codex("""{"type":"other"}"""));
        Assert.Equal(120, AgentEvent.Summary(new string('a', 200)).Length);
    }
}

public class HeadphoneCatalogTests
{
    [Fact]
    public void RenamedSonyIsFoundByModelNumber()
    {
        var model = HeadphoneCatalog.Identify("WWIII survivor🫡", 0x054C, 0x0F1E);
        Assert.Equal("Sony ULT WEAR", model?.Name);
        Assert.Equal(HeadphoneModel.Kind.OverEar, model?.Shape);
    }

    [Fact]
    public void ModelNumbersWinOverNames()
    {
        Assert.Equal("Sony WH-CH720N", HeadphoneCatalog.Identify("WH-CH720N", 0x054C, 0x0EAF)?.Name);
        Assert.Equal(HeadphoneModel.Brand.Bose, HeadphoneCatalog.Identify("Zidane's BOSE", 0x009E, 0x4066)?.Maker);
        Assert.Equal("airpods.max", HeadphoneCatalog.Identify("Studio", 0x004C, 0x200A)?.Symbol);
    }

    [Fact]
    public void NamesWhenThereAreNoModelNumbers()
    {
        Assert.Equal("soundcore Space One", HeadphoneCatalog.Identify("soundcore Space One", null, null)?.Name);
        Assert.Equal(HeadphoneModel.Brand.Soundcore, HeadphoneCatalog.Identify("Soundcore Space Q45", null, null)?.Maker);
        Assert.Equal(HeadphoneModel.Kind.OverEar, HeadphoneCatalog.Identify("Paarth’s AirPods Max", null, null)?.Shape);
        Assert.Equal("airpods.pro", HeadphoneCatalog.Identify("Paarth’s AirPods Pro", null, null)?.Symbol);
        Assert.Equal(HeadphoneModel.Brand.Beats, HeadphoneCatalog.Identify("Beats Solo 4", null, null)?.Maker);
        Assert.Equal(HeadphoneModel.Brand.Bose, HeadphoneCatalog.Identify("Bose QC Ultra Headphones", null, null)?.Maker);
    }

    [Fact]
    public void ModelFileNames()
    {
        Assert.Equal("sony-ult-wear", HeadphoneCatalog.Identify("", 0x054C, 0x0F1E)?.ModelFileName);
        Assert.Equal("sony-wh-ch720n", HeadphoneCatalog.Identify("WH-CH720N", null, null)?.ModelFileName);
        Assert.Equal("bose-qc45", HeadphoneCatalog.Identify("Bose QC45", null, null)?.ModelFileName);
    }

    [Fact]
    public void UnknownDevices()
    {
        Assert.Null(HeadphoneCatalog.Identify("JBL TUNE510BT", 0x005D, 0x223B));
        Assert.Equal(0x054C, HeadphoneCatalog.Number("0x054C"));
        Assert.Null(HeadphoneCatalog.Number(null));
    }
}

public class TwoFingerSwipeTests
{
    private static List<TwoFingerSwipe.Action> Run(IEnumerable<(double Up, double Right)> moves, bool canSkip = true)
    {
        var swipe = new TwoFingerSwipe();
        swipe.Begin();
        return moves.Select(m => swipe.Move(m.Up, m.Right, canSkip)).OfType<TwoFingerSwipe.Action>().ToList();
    }

    private static IEnumerable<(double, double)> Repeat(double up, double right, int count) => Enumerable.Repeat((up, right), count);

    [Fact]
    public void LeftIsNextRightIsPrevious()
    {
        Assert.Equal([TwoFingerSwipe.Action.Next], Run(Repeat(0, -10, 6)));
        Assert.Equal([TwoFingerSwipe.Action.Previous], Run(Repeat(0, 10, 6)));
    }

    [Fact] public void UpTucks() => Assert.Equal([TwoFingerSwipe.Action.Tuck], Run(Repeat(10, 0, 4)));
    [Fact] public void OneActionPerGesture() => Assert.Equal([TwoFingerSwipe.Action.Next], Run(Repeat(0, -30, 10)));
    [Fact] public void DiagonalTucks() => Assert.Equal([TwoFingerSwipe.Action.Tuck], Run(Repeat(10, 5, 6)));

    [Fact]
    public void SidewaysIgnoredWhenSkippingIsOff()
    {
        Assert.Empty(Run(Repeat(0, -30, 5), canSkip: false));
        Assert.Equal([TwoFingerSwipe.Action.Tuck], Run(Repeat(10, -30, 4), canSkip: false));
    }

    [Fact]
    public void BeginStartsAFreshGesture()
    {
        var swipe = new TwoFingerSwipe();
        swipe.Begin();
        swipe.Move(0, -50, true);
        swipe.Begin();
        Assert.Equal(TwoFingerSwipe.Action.Previous, swipe.Move(0, 50, true));
    }
}

public class ClickSynthesisTests
{
    [Theory]
    [InlineData(ClickSynthesis.Style.Lock)]
    [InlineData(ClickSynthesis.Style.Unlock)]
    public void IsCleanAndNormalised(ClickSynthesis.Style style)
    {
        var samples = ClickSynthesis.Samples(style);
        Assert.Equal((int)(ClickSynthesis.SampleRate * (style == ClickSynthesis.Style.Lock ? 0.13 : 0.17)), samples.Length);
        Assert.All(samples, s => Assert.True(float.IsFinite(s)));
        Assert.True(Math.Abs(samples.Max(MathF.Abs) - ClickSynthesis.Peak) < 0.001);
        Assert.True(samples[^240..].Max(MathF.Abs) < 0.02);
    }

    [Fact]
    public void UnlockHasTwoClicks()
    {
        var samples = ClickSynthesis.Samples(ClickSynthesis.Style.Unlock);
        var second = (int)(0.062 * ClickSynthesis.SampleRate);
        Assert.True(samples[second..(second + 200)].Max(MathF.Abs) > samples[(second - 200)..second].Max(MathF.Abs) * 3);
    }

    [Fact]
    public void WavDescribesTheSamples()
    {
        var samples = ClickSynthesis.Samples(ClickSynthesis.Style.Unlock);
        var wav = ClickSynthesis.Wav(ClickSynthesis.Style.Unlock);
        string Text(int at) => Encoding.ASCII.GetString(wav, at, 4);
        ushort U16(int at) => BitConverter.ToUInt16(wav, at);
        uint U32(int at) => BitConverter.ToUInt32(wav, at);
        Assert.True(Text(0) == "RIFF" && Text(8) == "WAVE" && Text(12) == "fmt " && Text(36) == "data");
        Assert.Equal((uint)(wav.Length - 8), U32(4));
        Assert.True(U16(20) == 1 && U16(22) == 1 && U32(24) == 48_000 && U32(28) == 96_000 && U16(34) == 16);
        Assert.True(U32(40) == samples.Length * 2 && wav.Length == 44 + samples.Length * 2);
    }
}

public class PaletteTests
{
    [Fact]
    public void FindsBothDominantColors()
    {
        RGB red = new(0.85, 0.1, 0.1), blue = new(0.1, 0.2, 0.8);
        var pixels = Enumerable.Repeat(red, 300).Concat(Enumerable.Repeat(blue, 100)).ToList();
        var palette = PaletteExtractor.FromPixels(pixels, 3);
        var hues = palette.Colors.Select(c => c.Hsb.H).ToList();
        Assert.Contains(hues, h => h < 0.05 || h > 0.95);
        Assert.Contains(hues, h => Math.Abs(h - 0.625) < 0.08);
        Assert.True(palette.Accent.Hsb.B >= 0.8);
    }

    [Fact]
    public void HsbRoundTrip()
    {
        RGB c = new(0.2, 0.6, 0.4);
        var (h, s, b) = c.Hsb;
        var back = RGB.FromHsb(h, s, b);
        Assert.True(Math.Abs(back.R - c.R) < 1e-9 && Math.Abs(back.G - c.G) < 1e-9 && Math.Abs(back.B - c.B) < 1e-9);
    }

    [Fact] public void TinyInputFallsBack() => Assert.Equal(Palette.Fallback, PaletteExtractor.FromPixels([new RGB(1, 1, 1)]));

    [Fact]
    public void HexColors()
    {
        Assert.Equal(new RGB(1, 0x42 / 255.0, 0x58 / 255.0), RGB.FromHex("#FF4258FF"));
        Assert.Null(RGB.FromHex("zz"));
        Assert.Equal("#FF8000", new RGB(1, 0.5, 0).Hex);
    }

    [Fact]
    public void GlowIsBrightAndStartsWithTheAccent()
    {
        var glow = new Palette([new(0.3, 0.05, 0.05), new(0.31, 0.05, 0.05), new(0.05, 0.1, 0.3)], new RGB(0.9, 0.3, 0.5)).GlowColors;
        Assert.Equal(1, glow[0].Hsb.B);
        Assert.True(Math.Abs(glow[0].Hsb.H - new RGB(0.9, 0.3, 0.5).Hsb.H) < 0.01);
        Assert.Equal(3, glow.Count);
        Assert.All(glow, g => Assert.True(g.Hsb.B > 0.99));
    }

    [Fact]
    public void GraysAreLeftOutOfColorfulCovers()
    {
        var glow = new Palette([new(0.2, 0.2, 0.2), new(0.1, 0.1, 0.12)], new RGB(0.95, 0.3, 0.5)).GlowColors;
        Assert.Single(glow);
        Assert.All(glow, g => Assert.True(g.Hsb.S >= 0.5));
    }

    [Fact]
    public void GraysStayGray() =>
        Assert.All(new Palette([new(0.2, 0.2, 0.2)], new RGB(0.2, 0.2, 0.21)).GlowColors, g => Assert.True(g.Hsb.S < 0.12));
}

public class BeatDetectorTests
{
    private static int Beats(double period, double seconds, float quiet = 0.2f, float loud = 0.8f)
    {
        var detector = new BeatDetector();
        var count = 0;
        var frames = (int)(seconds * 30);
        var perBeat = (int)(period * 30);
        for (var frame = 0; frame < frames; frame++)
        {
            var level = frame % perBeat < 2 && frame > 0 ? loud : quiet;
            if (detector.Feed([level, level, level, 0.3f, 0.3f], frame / 30.0)) count++;
        }
        return count;
    }

    [Fact] public void FindsAKickAt120bpm() => Assert.InRange(Beats(0.5, 10), 16, 20);

    [Fact]
    public void SteadyLoudnessIsNotABeat()
    {
        var detector = new BeatDetector();
        var count = 0;
        for (var frame = 0; frame < 300; frame++) if (detector.Feed([0.7f, 0.7f, 0.7f], frame / 30.0)) count++;
        Assert.Equal(0, count);
    }

    [Fact] public void SilenceIsNotABeat() => Assert.Equal(0, Beats(0.5, 5, 0.01f, 0.05f));
    [Fact] public void NeverFasterThanTheMinimumGap() => Assert.True(Beats(0.1, 6) <= (int)(6 / 0.28) + 1);
}

public class PlaybackTests
{
    private static readonly DateTime Start = DateTime.UnixEpoch.AddSeconds(1_000);

    private static NowPlayingSnapshot Report(double elapsed, DateTime at, bool playing = true, string title = "x") =>
        new() { Title = title, Duration = 300, Elapsed = elapsed, Timestamp = at, PlaybackRate = playing ? 1 : 0, IsPlaying = playing };

    [Fact]
    public void AdvancesWhilePlaying() =>
        Assert.Equal(15, new NowPlayingSnapshot { Title = "x", Duration = 200, Elapsed = 10, Timestamp = Start, PlaybackRate = 1, IsPlaying = true }.ElapsedAt(Start.AddSeconds(5)));

    [Fact]
    public void FrozenWhilePaused() =>
        Assert.Equal(10, new NowPlayingSnapshot { Title = "x", Duration = 200, Elapsed = 10, Timestamp = Start }.ElapsedAt(Start.AddSeconds(60)));

    [Fact]
    public void ClampsToDuration() =>
        Assert.Equal(12, new NowPlayingSnapshot { Title = "x", Duration = 12, Elapsed = 10, Timestamp = Start, PlaybackRate = 1, IsPlaying = true }.ElapsedAt(Start.AddSeconds(30)));

    [Fact]
    public void ReanchorForOptimisticPause()
    {
        var s = new NowPlayingSnapshot { Title = "x", Duration = 200, Elapsed = 10, Timestamp = Start, PlaybackRate = 1, IsPlaying = true };
        var paused = s.Reanchored(Start.AddSeconds(4), isPlaying: false);
        Assert.Equal(14, paused.Elapsed);
        Assert.Equal(14, paused.ElapsedAt(Start.AddSeconds(100)));
    }

    [Fact]
    public void TimeLabels()
    {
        Assert.Equal("0:00", TimeText.Format(0));
        Assert.Equal("1:16", TimeText.Format(76.9));
        Assert.Equal("1:02:05", TimeText.Format(3725));
        Assert.Equal("-3:18", TimeText.Remaining(76.8, 274.19));
    }

    [Fact]
    public void TicksAlignToWholeSecondSteps()
    {
        var timing = new PlaybackTiming(10.3, Start, 1, 200);
        var first = timing.NextTick(Start, 4)!.Value;
        Assert.True(Math.Abs((first - Start).TotalSeconds - 0.2) < 1e-5);
        var second = timing.NextTick(first, 4)!.Value;
        Assert.True(Math.Abs((second - first).TotalSeconds - 0.25) < 1e-5);
    }

    [Fact]
    public void NoTicksWhilePausedOrAfterTheEnd()
    {
        Assert.Null(new PlaybackTiming(10, Start, 0, 200).NextTick(Start, 4));
        Assert.Null(new PlaybackTiming(200, Start, 1, 200).NextTick(Start, 4));
    }

    [Fact]
    public void LastTickLandsOnTheEnd()
    {
        var timing = new PlaybackTiming(199.9, Start, 1, 199.95);
        var last = timing.NextTick(Start, 1)!.Value;
        Assert.True(Math.Abs((last - Start).TotalSeconds - 0.05) < 1e-5);
        Assert.Null(timing.NextTick(last, 1));
    }

    [Fact]
    public void StaleReportAfterSeekKeepsTheTarget()
    {
        var r = new PlaybackReconciler();
        var seeked = Report(120, Start);
        r.UserSeeked(Start);
        var now = Start.AddSeconds(0.4);
        Assert.True(Math.Abs(r.Reconcile(Report(40.4, now), seeked, now).ElapsedAt(now) - 120.4) < 1e-6);
    }

    [Fact]
    public void ConfirmingReportEndsTheSeekHold()
    {
        var r = new PlaybackReconciler();
        var seeked = Report(120, Start);
        r.UserSeeked(Start);
        var now = Start.AddSeconds(0.6);
        r.Reconcile(Report(120.9, now), seeked, now);
        var later = Start.AddSeconds(1);
        Assert.Equal(30, r.Reconcile(Report(30, later), seeked, later).ElapsedAt(later));
    }

    [Fact]
    public void SeekHoldExpires()
    {
        var r = new PlaybackReconciler();
        var seeked = Report(120, Start);
        r.UserSeeked(Start);
        var late = Start.AddSeconds(3);
        Assert.Equal(40, r.Reconcile(Report(40, late), seeked, late).Elapsed);
    }

    [Fact]
    public void StaleIsPlayingAfterPauseIsIgnored()
    {
        var r = new PlaybackReconciler();
        var paused = Report(50, Start, playing: false);
        r.UserSetPlaying(false, Start);
        var now = Start.AddSeconds(0.2);
        var shown = r.Reconcile(Report(50.2, now, playing: true), paused, now);
        Assert.False(shown.IsPlaying);
        Assert.Equal(50, shown.ElapsedAt(now.AddSeconds(5)));
        var confirmed = r.Reconcile(Report(50.3, now, playing: false), shown, now);
        Assert.False(confirmed.IsPlaying);
        Assert.Equal(50, confirmed.Elapsed);
    }

    [Fact]
    public void SmallCorrectionsKeepTheClockLargeOnesApply()
    {
        var r = new PlaybackReconciler();
        var current = Report(60, Start);
        var now = Start.AddSeconds(10);
        Assert.Equal(Start, r.Reconcile(Report(69.85, now), current, now).Timestamp);
        Assert.Equal(90, r.Reconcile(Report(90, now), current, now).ElapsedAt(now));
    }

    [Fact]
    public void NewTrackIsTakenAsIs()
    {
        var r = new PlaybackReconciler();
        r.UserSeeked(Start);
        var next = Report(0, Start, title: "y");
        Assert.Equal(next, r.Reconcile(next, Report(120, Start), Start));
    }

    [Fact]
    public void SiteMakingSoundIsAPlaceholder()
    {
        Assert.True(new NowPlayingSnapshot { Title = "A site is playing media", SourceApp = "Chrome" }.IsPlaceholder);
        Assert.False(new NowPlayingSnapshot { Title = "9", Artist = "Drake", Album = "Views" }.IsPlaceholder);
        Assert.False(new NowPlayingSnapshot { Title = "Song", Artist = "Artist", SourceApp = "Chrome" }.IsPlaceholder);
    }

    [Fact]
    public async Task LyricsSkipSongsWithoutAnArtist()
    {
        var client = new LRCLIBClient(new HttpClient(), "IsletTests");
        Assert.Null(await client.LyricsAsync("A site is playing media", "", "", 0));
    }
}
