using System.Media;
using System.Windows.Threading;
using Islet.Core;
using Islet.Media;
using Islet.Native;
using Islet.Settings;

namespace Islet.Island;

/// Owns the island: which activity shows and for how long, the timer, hiding a paused song,
/// and stepping out of the way of full-screen apps.
public sealed class IslandController
{
    public IslandModel Model { get; }
    public IslandWindow Window { get; }
    private readonly PlayerStore _store;
    private readonly AppSettings _settings;
    private readonly DispatcherTimer _activityTimer = new(DispatcherPriority.Normal);
    private readonly DispatcherTimer _pausedTimer = new(DispatcherPriority.Background);
    private DispatcherTimer? _timer;
    private nint _foregroundHook;
    private Win32.WinEventProc? _foregroundProc;

    /// The Focus (Do Not Disturb) state, when known: alerts switched off for Focus stay hidden.
    public bool FocusOn { get; set; }

    public IslandController(PlayerStore store, AppSettings settings)
    {
        _store = store;
        _settings = settings;
        Model = new IslandModel(IslandMetrics.Make(settings));
        Window = new IslandWindow(Model, store, settings);
        Window.ActivityCleared += ClearActivity;
        _activityTimer.Tick += (_, _) => ClearActivity();
        _pausedTimer.Tick += (_, _) => DropPausedSong();
        store.PropertyChanged += (_, e) => { if (e.PropertyName is nameof(PlayerStore.IsPlaying) or nameof(PlayerStore.HasTrack)) FollowPauses(); };
        settings.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(AppSettings.HidePausedPlayer)) FollowPauses(); };
    }

    public void Show()
    {
        Window.Show();
        WatchFullScreen();
    }

    // MARK: Activities

    public void ShowActivity(IslandActivity activity, TimeSpan duration)
    {
        if (Model.IsSuppressed && activity is not IslandActivity.Agent) return;
        // An open island (music, the shelf) stays open: the activity waits its turn.
        if (Model.Presentation != IslandPresentation.Compact && !activity.IsCard) return;
        if (activity.IsCard) Model.Presentation = IslandPresentation.Compact;
        Model.Activity = activity;
        KeepActivity(duration);
    }

    private void KeepActivity(TimeSpan duration)
    {
        _activityTimer.Stop();
        _activityTimer.Interval = duration;
        _activityTimer.Start();
    }

    public void ClearActivity()
    {
        _activityTimer.Stop();
        // The pointer on a card with buttons keeps it up.
        if (Model.Activity?.HoldsHover == true && Model.IsHovered)
        {
            KeepActivity(TimeSpan.FromSeconds(1.5));
            return;
        }
        Model.Activity = null;
    }

    public void ShowCharging(BatteryState battery)
    {
        if (!_settings.ShowChargingAlert || FocusOn) return;
        ShowActivity(new IslandActivity.Charging(battery), TimeSpan.FromSeconds(_settings.ChargingAlertDuration));
    }

    public void ShowLowBattery(int percent)
    {
        if (FocusOn) return;
        ShowActivity(new IslandActivity.LowBattery(percent), TimeSpan.FromSeconds(4));
    }

    public void ShowUnlocked()
    {
        if (!_settings.ShowUnlockInIsland) return;
        ShowActivity(new IslandActivity.Unlocked(), TimeSpan.FromSeconds(2.2));
    }

    /// Volume or brightness, kept up while the keys are pressed. A stream of changes only moves
    /// the bar; it doesn't re-run the entrance.
    public void ShowLevel(LevelHUD hud)
    {
        if (hud.Kind == LevelKind.Volume ? !_settings.ShowVolumeInIsland : !_settings.ShowBrightnessInIsland) return;
        if (Model.Activity is IslandActivity.Headphones) return;
        if (Model.Level != hud) Model.Level = hud;
        if (Model.Activity is IslandActivity.Level level && level.Kind == hud.Kind) KeepActivity(TimeSpan.FromSeconds(1.5));
        else ShowActivity(new IslandActivity.Level(hud.Kind), TimeSpan.FromSeconds(1.5));
    }

    public void ShowHeadphones(string name, string symbol, int? battery)
    {
        if (!_settings.ShowHeadphonesInIsland || FocusOn) return;
        ShowActivity(new IslandActivity.Headphones(name, symbol, battery), TimeSpan.FromSeconds(4));
    }

    /// A coding agent wants attention: longer for questions than for "finished".
    public void ShowAgent(AgentEvent e)
    {
        if (!_settings.AgentAlerts) return;
        ShowActivity(new IslandActivity.Agent(e), TimeSpan.FromSeconds(e.Kind == AgentEvent.EventKind.Done ? 6 : 12));
    }

    public void ShowFocus(string name, bool on) => ShowActivity(new IslandActivity.Focus(name, on), TimeSpan.FromSeconds(2.5));

    // MARK: Timer

    public bool TimerRunning => Model.TimerEnd is not null;

    public void StartTimer(int minutes)
    {
        var end = DateTime.UtcNow.AddMinutes(minutes);
        Model.TimerEnd = end;
        _timer?.Stop();
        _timer = new DispatcherTimer(DispatcherPriority.Normal) { Interval = end - DateTime.UtcNow };
        _timer.Tick += (_, _) =>
        {
            _timer!.Stop();
            Model.TimerEnd = null;
            SystemSounds.Asterisk.Play();
            ShowActivity(new IslandActivity.TimerDone(), TimeSpan.FromSeconds(5));
        };
        _timer.Start();
    }

    public void CancelTimer()
    {
        _timer?.Stop();
        Model.TimerEnd = null;
    }

    // MARK: A paused song leaves after the chosen delay (Settings → Island)

    private void FollowPauses()
    {
        _pausedTimer.Stop();
        if (_store.IsPlaying || !_store.HasTrack) { if (_store.IsPlaying) Model.ShowsTrack = true; return; }
        if (_settings.HidePausedDelay is not double delay) return;
        _pausedTimer.Interval = TimeSpan.FromSeconds(delay);
        _pausedTimer.Start();
    }

    private void DropPausedSong()
    {
        // Not while it's open or under the pointer; look again in a second.
        if (Model.Presentation != IslandPresentation.Compact || Model.IsHovered)
        {
            _pausedTimer.Interval = TimeSpan.FromSeconds(1);
            return;
        }
        _pausedTimer.Stop();
        if (!_store.IsPlaying) Model.ShowsTrack = false;
    }

    // MARK: Full-screen apps

    /// Hides the island while a full-screen app, game or presentation is in front, by
    /// listening for foreground changes (an event, not a timer).
    private void WatchFullScreen()
    {
        _foregroundProc = (_, _, _, _, _, _, _) => Window.Dispatcher.BeginInvoke(CheckFullScreen);
        _foregroundHook = Win32.SetWinEventHook(Win32.EVENT_SYSTEM_FOREGROUND, Win32.EVENT_SYSTEM_FOREGROUND, 0, _foregroundProc, 0, 0, Win32.WINEVENT_OUTOFCONTEXT);
        _settings.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(AppSettings.HideInFullScreen)) CheckFullScreen(); };
        CheckFullScreen();
    }

    public bool PlayerCovering { get; set; }

    public void CheckFullScreen()
    {
        var fullScreen = false;
        if (_settings.HideInFullScreen && Win32.SHQueryUserNotificationState(out var state) == 0)
            fullScreen = state is Win32.QUNS_BUSY or Win32.QUNS_RUNNING_D3D_FULL_SCREEN or Win32.QUNS_PRESENTATION_MODE;
        var suppressed = fullScreen || PlayerCovering;
        if (suppressed && Model.Presentation != IslandPresentation.Compact) Model.Presentation = IslandPresentation.Compact;
        Model.IsSuppressed = suppressed;
        if (!suppressed) Window.Raise();
    }

    public void Stop()
    {
        if (_foregroundHook != 0) Win32.UnhookWinEvent(_foregroundHook);
    }
}
