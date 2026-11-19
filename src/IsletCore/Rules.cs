using System.Text.Json;
using System.Text.Json.Nodes;

namespace Islet.Core;

/// When Standby may start on its own. Pure, so the rules are testable away from the OS.
public sealed record StandbyConditions(
    bool Enabled, bool OnPower, double IdleSeconds, int IdleMinutes,
    /// Seconds since Standby was last dismissed (null: never this session).
    double? SinceDismissed, bool ScreenLocked, bool DisplayAsleep,
    /// Another app (a video, a presentation) is holding the display awake.
    bool OtherAppHoldsDisplay,
    /// Seconds until Windows turns the display off by itself (null: never). Standby must
    /// come first, or it would never get its turn.
    double? SystemTimeout = null)
{
    /// No wait is ever shorter: until then nothing else is worth reading.
    public const double ShortestWait = 15;

    /// The idle wait actually used: the chosen minutes, or 20 s before the system's own
    /// timeout when that comes sooner (never under `ShortestWait`).
    public double WaitSeconds
    {
        get
        {
            double chosen = IdleMinutes * 60;
            if (SystemTimeout is not double timeout || timeout <= 0) return chosen;
            return Math.Min(chosen, Math.Max(timeout - 20, ShortestWait));
        }
    }

    /// Seconds until it's worth looking again: idle time only grows until someone touches
    /// the PC, so Standby can't start before the wait runs out. Blocked or off, a slow look.
    public double NextCheck
    {
        get
        {
            if (!Enabled || !OnPower) return 30;
            var remaining = WaitSeconds - IdleSeconds;
            return remaining > 0 ? Math.Min(Math.Max(remaining, 1), 120) : 30;
        }
    }

    public bool ShouldStart
    {
        get
        {
            if (!Enabled || !OnPower || ScreenLocked || DisplayAsleep || OtherAppHoldsDisplay || IdleSeconds < WaitSeconds) return false;
            // After a dismissal, only a fresh idle stretch (one that began after it) counts;
            // otherwise unplugging and replugging would bring it straight back.
            return SinceDismissed is not double since || IdleSeconds < since;
        }
    }
}

/// What a coding agent (Claude Code, Codex) reported, reduced to what the island shows.
public sealed record AgentEvent(AgentEvent.EventKind Kind, string Project, string Message)
{
    public enum EventKind
    {
        /// Waiting for the user to approve something.
        Permission,
        /// Idle, waiting for the next message.
        Waiting,
        /// Finished its turn.
        Done,
    }

    /// Claude Code hook input (JSON on stdin): Notification, PermissionRequest and Stop.
    public static AgentEvent? Claude(string json)
    {
        if (Parse(json) is not JsonObject o) return null;
        var project = FolderName(Str(o, "cwd"));
        var message = Str(o, "message") ?? "";
        return Str(o, "hook_event_name") switch
        {
            "Notification" => new AgentEvent(
                message.Contains("permission", StringComparison.CurrentCultureIgnoreCase) ? EventKind.Permission : EventKind.Waiting,
                project, message),
            "PermissionRequest" => new AgentEvent(EventKind.Permission, project,
                Str(o, "tool_name") is string tool ? $"Wants to use {tool}" : "Needs your permission"),
            "Stop" => new AgentEvent(EventKind.Done, project, ""),
            _ => null,
        };
    }

    /// Codex `notify` payload (JSON as the last argument): agent-turn-complete.
    public static AgentEvent? Codex(string argument)
    {
        if (Parse(argument) is not JsonObject o || Str(o, "type") != "agent-turn-complete") return null;
        return new AgentEvent(EventKind.Done, FolderName(Str(o, "cwd")), Summary(Str(o, "last-assistant-message") ?? ""));
    }

    /// The first line, at most 120 characters.
    public static string Summary(string text)
    {
        var line = LRCParser.Newline.Split(text).FirstOrDefault(l => l.Length > 0) ?? "";
        var elements = new StringInfo(line);
        return elements.LengthInTextElements > 120 ? elements.SubstringByTextElements(0, 119) + "…" : line;
    }

    internal static string FolderName(string? path)
    {
        if (string.IsNullOrEmpty(path)) return "";
        var trimmed = path.TrimEnd('/', '\\');
        var cut = trimmed.LastIndexOfAny(['/', '\\']);
        return cut < 0 ? trimmed : trimmed[(cut + 1)..];
    }

    private static JsonNode? Parse(string json)
    {
        try { return JsonNode.Parse(json); } catch (JsonException) { return null; }
    }

    private static string? Str(JsonObject o, string key) => o[key] is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;
}

/// Turns one two-finger touchpad gesture over the island into at most one action: up tucks
/// the island away, sideways ("Swipe to skip") changes the song. Movement is given in the
/// direction the fingers travel, whatever the scrolling setting.
public sealed class TwoFingerSwipe
{
    public enum Action { Tuck, Next, Previous }

    /// Points of upward travel that tuck the island away.
    internal const double TuckDistance = 28;
    /// Points of sideways travel that skip, and how much more sideways than vertical it must be.
    internal const double SkipDistance = 40;
    internal const double SkipDominance = 1.5;

    private double _up, _sideways;
    private bool _finished;

    /// The fingers touched down: a new gesture.
    public void Begin()
    {
        _up = 0;
        _sideways = 0;
        _finished = false;
    }

    /// Adds movement and returns the action it completes, once per gesture. `canSkip` is
    /// false while skipping isn't possible; sideways travel is then ignored.
    public Action? Move(double up, double right, bool canSkip)
    {
        if (_finished) return null;
        _up += up;
        if (canSkip) _sideways += right;
        if (canSkip && Math.Abs(_sideways) > SkipDistance && Math.Abs(_sideways) > Math.Abs(_up) * SkipDominance)
        {
            _finished = true;
            // Like paging: fingers left bring the next song in, right go back.
            return _sideways < 0 ? Action.Next : Action.Previous;
        }
        if (_up > TuckDistance && _up > Math.Abs(_sideways))
        {
            _finished = true;
            return Action.Tuck;
        }
        return null;
    }
}

/// Procedural lock / unlock clicks in the character of a phone's side button: a bright
/// transient over a short, slightly falling "thock". Original synthesis.
public static class ClickSynthesis
{
    public enum Style { Lock, Unlock }

    public const double SampleRate = 48_000;
    public const float Peak = 0.82f;

    /// Mono samples in -1...1 at `SampleRate`.
    public static float[] Samples(Style style)
    {
        var length = style == Style.Lock ? 0.13 : 0.17;
        var output = new float[(int)(SampleRate * length)];
        if (style == Style.Lock) AddClick(output, 0, 1, 300, 2_150);
        else
        {
            AddClick(output, 0, 0.62, 380, 2_600);
            AddClick(output, 0.062, 0.5, 460, 3_000);
        }
        // Soft-clip, then normalise to a comfortable peak.
        for (var i = 0; i < output.Length; i++) output[i] = MathF.Tanh(output[i] * 1.4f);
        var loudest = output.Length == 0 ? 0 : output.Max(MathF.Abs);
        if (loudest > 0) for (var i = 0; i < output.Length; i++) output[i] *= Peak / loudest;
        return output;
    }

    /// The click as a 16-bit mono WAV file, for players that take encoded audio.
    public static byte[] Wav(Style style)
    {
        var pcm = Samples(style).Select(s => (short)MathF.Round(Math.Clamp(s, -1, 1) * short.MaxValue)).ToArray();
        var dataSize = (uint)(pcm.Length * 2);
        using var stream = new MemoryStream(44 + pcm.Length * 2);
        using var w = new BinaryWriter(stream);
        w.Write("RIFF"u8);
        w.Write(36 + dataSize);
        w.Write("WAVEfmt "u8);
        w.Write(16u);                       // format chunk size
        w.Write((ushort)1);                 // linear PCM
        w.Write((ushort)1);                 // mono
        w.Write((uint)SampleRate);
        w.Write((uint)SampleRate * 2);      // bytes per second
        w.Write((ushort)2);                 // bytes per frame
        w.Write((ushort)16);                // bits per sample
        w.Write("data"u8);
        w.Write(dataSize);
        foreach (var sample in pcm) w.Write(sample);
        w.Flush();
        return stream.ToArray();
    }

    private static void AddClick(float[] output, double start, double gain, double body, double bright)
    {
        uint seed = 0x1234_5678;
        double highPassed = 0, lastNoise = 0;
        for (var i = (int)(start * SampleRate); i < output.Length; i++)
        {
            var t = i / SampleRate - start;
            seed = unchecked(seed * 1_664_525 + 1_013_904_223);
            var noise = (seed >> 8) / (double)(1 << 24) * 2 - 1;
            highPassed = 0.86 * (highPassed + noise - lastNoise);
            lastNoise = noise;
            var transient = highPassed * Math.Exp(-t / 0.0011) * 0.9;
            var ping = Math.Sin(2 * Math.PI * bright * t) * Math.Exp(-t / 0.0055) * 0.32;
            var falling = body * (1 - 0.18 * Math.Min(t / 0.05, 1));
            var thock = Math.Sin(2 * Math.PI * falling * t) * Math.Exp(-t / 0.024) * 0.75;
            var sub = Math.Sin(2 * Math.PI * 105 * t) * Math.Exp(-t / 0.035) * 0.3;
            output[i] += (float)(gain * (transient + ping + thock + sub));
        }
    }
}
