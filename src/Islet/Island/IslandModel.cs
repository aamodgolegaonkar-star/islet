using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows;
using Islet.Settings;

namespace Islet.Island;

public enum IslandPresentation { Compact, Expanded, Shelf, Controls, Phone }

public enum LevelKind { Volume, Brightness }

public sealed record LevelHUD(LevelKind Kind, double Value, bool Muted = false);

public sealed record BatteryState(double Level, bool Charging, bool OnPower);

/// Short-lived system events the island shows on its own, like the iPhone.
public abstract record IslandActivity
{
    public sealed record Charging(BatteryState Battery) : IslandActivity;
    /// The PC was just unlocked: the fingerprint goes red to green, then the padlock opens.
    public sealed record Unlocked : IslandActivity;
    /// Volume or brightness changed: the level itself lives in `IslandModel.Level`, so a stream
    /// of changes only moves the bar instead of re-running the activity's entrance.
    public sealed record Level(LevelKind Kind) : IslandActivity;
    public sealed record Headphones(string Name, string Symbol, int? Battery) : IslandActivity;
    public sealed record Agent(Core.AgentEvent Event) : IslandActivity;
    public sealed record LowBattery(int Percent) : IslandActivity;
    public sealed record TimerDone : IslandActivity;
    public sealed record Focus(string Name, bool On) : IslandActivity;
    public sealed record Portal(string Title, string Detail, bool Incoming) : IslandActivity;
    public sealed record Phone(string Title, string Detail, string? App) : IslandActivity;

    /// Shown as a card (expanded shape) rather than a pill.
    public bool IsCard => this is Headphones or Agent or Portal or Phone;
    /// Cards with buttons: the pointer on them keeps them up instead of opening the island.
    public bool HoldsHover => this is Phone or Agent;

    /// Same kind of activity (a level update shouldn't re-bounce the island).
    public bool SameKind(IslandActivity? other) => other is not null &&
        (this is Level a && other is Level b ? a.Kind == b.Kind : GetType() == other.GetType());
}

/// Island geometry for one screen, in device-independent pixels. Windows PCs have no notch,
/// so this is the Mac's no-notch layout: a floating pill just under the top edge, with the
/// transport controls split into their own capsule below the open card.
public sealed record IslandMetrics(
    double TopInset, double CompactHeight, double IdleWidth, double CompactWidth, double ChargingWidth,
    Size ExpandedSize, Size WindowSize)
{
    public Size ControlsSize { get; init; } = new(300, 52);
    public double ControlsGap { get; init; } = 12;

    public static IslandMetrics Make(AppSettings settings)
    {
        double w = settings.IslandWidthScale, h = settings.IslandHeightScale;
        return new IslandMetrics(
            TopInset: 8, CompactHeight: Math.Round(28 * h), IdleWidth: 112 * w, CompactWidth: 190 * w,
            ChargingWidth: 256 * w, ExpandedSize: new Size(384 * w, 180 - 56), WindowSize: new Size(620, 300));
    }

    public double TimerWidth => CompactWidth;
    public double ShelfHeight => 122;
    public double ControlsHeight => 178;
    public double PhoneHeight => 196;
    public double HeadphoneCardWidth => Math.Max(ExpandedSize.Width + 24, 400);
    public double UnlockedWidth => CompactWidth;
    public const double PhoneBubbleSize = 44, PhoneBubbleGap = 10;
    public double PhoneBubbleY => 10;

    public Size SizeFor(IslandPresentation presentation, bool busy, IslandActivity? activity = null) => activity switch
    {
        IslandActivity.Charging => new(ChargingWidth, CompactHeight),
        IslandActivity.Unlocked => new(UnlockedWidth, CompactHeight),
        IslandActivity.Level => new(ChargingWidth, CompactHeight),
        IslandActivity.Headphones => new(HeadphoneCardWidth, CompactHeight + 76),
        IslandActivity.Agent => new(HeadphoneCardWidth, CompactHeight + 58),
        IslandActivity.Portal => new(HeadphoneCardWidth, CompactHeight + 84),
        IslandActivity.Phone => new(HeadphoneCardWidth, CompactHeight + 66),
        IslandActivity.LowBattery or IslandActivity.TimerDone or IslandActivity.Focus => new(ChargingWidth, CompactHeight),
        _ => presentation switch
        {
            IslandPresentation.Expanded when busy => ExpandedSize,
            IslandPresentation.Shelf => new(ExpandedSize.Width, ShelfHeight),
            IslandPresentation.Controls => new(ExpandedSize.Width, ControlsHeight),
            IslandPresentation.Phone => new(ExpandedSize.Width, PhoneHeight),
            _ => new(busy ? CompactWidth : IdleWidth, CompactHeight),
        },
    };

    public double CornerRadius(IslandPresentation presentation, bool busy, IslandActivity? activity = null)
    {
        var expanded = (presentation == IslandPresentation.Expanded && busy && activity is null) || activity?.IsCard == true
            || (presentation is IslandPresentation.Shelf or IslandPresentation.Controls or IslandPresentation.Phone && activity is null);
        return expanded ? 36 : CompactHeight / 2;
    }
}

/// What the island shows and how. One instance, on the UI thread.
public sealed class IslandModel : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    public IslandModel(IslandMetrics metrics) => _metrics = metrics;

    private IslandMetrics _metrics;
    public IslandMetrics Metrics { get => _metrics; set => Set(ref _metrics, value); }

    private IslandPresentation _presentation;
    public IslandPresentation Presentation { get => _presentation; set => Set(ref _presentation, value); }

    private IslandActivity? _activity;
    /// A transient system event (e.g. a charger was connected) shown in place of the pill.
    public IslandActivity? Activity { get => _activity; set => Set(ref _activity, value); }

    private bool _isTucked, _isHovered, _showsTrack = true, _isInteracting, _isSuppressed;
    /// Swiped away (two fingers up) so it doesn't cover what's behind it, for a moment.
    public bool IsTucked { get => _isTucked; set => Set(ref _isTucked, value); }
    /// The pointer is over the island (it lifts slightly when it won't open on hover).
    public bool IsHovered { get => _isHovered; set => Set(ref _isHovered, value); }
    /// False once a paused song has been dropped from the island; back when anything plays.
    public bool ShowsTrack { get => _showsTrack; set => Set(ref _showsTrack, value); }
    /// A slider in the island is being dragged; it doesn't collapse meanwhile.
    public bool IsInteracting { get => _isInteracting; set => Set(ref _isInteracting, value); }
    /// Hidden over full-screen apps and the full-screen player.
    public bool IsSuppressed { get => _isSuppressed; set => Set(ref _isSuppressed, value); }

    private bool _micActive, _cameraActive;
    public bool MicActive { get => _micActive; set => Set(ref _micActive, value); }
    public bool CameraActive { get => _cameraActive; set => Set(ref _cameraActive, value); }

    private DateTime? _timerEnd;
    /// A running timer's end; the compact island shows the countdown.
    public DateTime? TimerEnd { get => _timerEnd; set => Set(ref _timerEnd, value); }

    private LevelHUD _level = new(LevelKind.Volume, 0);
    public LevelHUD Level { get => _level; set => Set(ref _level, value); }

    private int _shakes, _arrivals;
    public int Shakes { get => _shakes; set => Set(ref _shakes, value); }
    public int Arrivals { get => _arrivals; set => Set(ref _arrivals, value); }

    private void Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }
}
