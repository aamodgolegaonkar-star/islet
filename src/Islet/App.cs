using System.Windows;
using System.Windows.Threading;
using Islet.Island;
using Islet.Media;
using Islet.Native;
using Islet.Services;
using Islet.Settings;
using Microsoft.Win32;
using Forms = System.Windows.Forms;

namespace Islet;

/// Islet for Windows: a Dynamic Island under the top edge of the screen. One instance, no
/// taskbar button; a tray icon for Settings and Quit.
public sealed class App : Application
{
    private static Mutex? _single;
    private readonly AppSettings _settings = AppSettings.Shared;
    private PlayerStore _store = null!;
    private IslandController _island = null!;
    private SystemVolume _volume = null!;
    private VolumeKeys? _volumeKeys;
    private Services.SystemEvents _events = null!;
    private SystemControls _controls = null!;
    private Forms.NotifyIcon? _tray;

    [STAThread]
    public static void Main(string[] args)
    {
        _single = new Mutex(true, @"Local\Islet.SingleInstance", out var first);
        if (!first) return;
        var app = new App { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        app.Run();
    }

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        if (_settings.DebugTools) Log.EnableFile(Path.Combine(AppSettings.CacheFolder, ".."));
        DispatcherUnhandledException += (_, args) =>
        {
            Log.Error("ui", args.Exception);
            args.Handled = true;
        };
        // Rest on efficient cores at low clocks; full speed only while the island moves.
        Win32.SetEcoQoS(true);
        SpringDriver.Animating += moving => Win32.SetEcoQoS(!moving);

        _store = new PlayerStore(_settings);
        _volume = new SystemVolume();
        _events = new Services.SystemEvents();
        _controls = new SystemControls();
        _island = new IslandController(_store, _settings);
        Wire();
        _island.Show();
        _volume.Start();
        _ = _store.StartAsync();
        _ = _controls.StartAsync();
        UseVolumeKeys(_settings.ReplaceSystemHUD);
        ApplyLaunchAtLogin();
        _tray = Tray();
    }

    private void Wire()
    {
        var window = _island.Window;
        window.LevelDragged += (kind, value) =>
        {
            if (kind == LevelKind.Volume)
            {
                if (_volume.Muted) _volume.SetMuted(false);
                _volume.SetLevel(value);
                _island.Model.Level = new LevelHUD(LevelKind.Volume, value);
            }
            else
            {
                _controls.SetBrightness(value);
                _island.Model.Level = new LevelHUD(LevelKind.Brightness, value);
            }
        };
        window.OutputClicked += ShowOutputs;
        window.ControlCenterFactory = () => new ControlCenterView(_controls, _volume, _island.Model, _store,
            showMusic: () => { _island.Model.ShowsTrack = true; window.SetPresentation(IslandPresentation.Expanded); },
            showShelf: null,
            startTimer: () => { _island.StartTimer(5); window.SetPresentation(IslandPresentation.Compact); });

        _volume.UserChanged += (level, muted) => _island.ShowLevel(new LevelHUD(LevelKind.Volume, level, muted));
        _controls.BrightnessChanged += level => Dispatcher.BeginInvoke(() => _island.ShowLevel(new LevelHUD(LevelKind.Brightness, level)));
        _events.Plugged += _island.ShowCharging;
        _events.LowBattery += _island.ShowLowBattery;
        _events.Unlocked += () =>
        {
            _island.ShowUnlocked();
            _island.CheckFullScreen();
        };
        _settings.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(AppSettings.ReplaceSystemHUD)) UseVolumeKeys(_settings.ReplaceSystemHUD);
            if (e.PropertyName == nameof(AppSettings.LaunchAtLogin)) ApplyLaunchAtLogin();
        };
        Microsoft.Win32.SystemEvents.DisplaySettingsChanged += (_, _) => Dispatcher.BeginInvoke(window.Reposition);
    }

    /// The volume keys go through Islet only when it replaces the Windows flyout.
    private void UseVolumeKeys(bool on)
    {
        if (!on)
        {
            _volumeKeys?.Dispose();
            _volumeKeys = null;
            return;
        }
        _volumeKeys ??= new VolumeKeys((direction, fine) => Dispatcher.BeginInvoke(() =>
        {
            var (level, muted) = _volume.Step(direction, fine);
            _island.ShowLevel(new LevelHUD(LevelKind.Volume, level, muted));
        }));
        _volumeKeys.Start();
    }

    private void ShowOutputs()
    {
        var menu = new Forms.ContextMenuStrip { ShowImageMargin = false };
        foreach (var (id, name) in _volume.Outputs())
        {
            var item = new Forms.ToolStripMenuItem(name) { Checked = id == _volume.DeviceId };
            item.Click += (_, _) => _volume.UseOutput(id);
            menu.Items.Add(item);
        }
        Win32.GetCursorPos(out var p);
        menu.Show(p.X, p.Y);
    }

    private Forms.NotifyIcon Tray()
    {
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("Islet", null, null!).Enabled = false;
        menu.Items.Add(new Forms.ToolStripSeparator());
        var hover = new Forms.ToolStripMenuItem("Open on Hover") { Checked = _settings.ExpandOnHover, CheckOnClick = true };
        hover.CheckedChanged += (_, _) => _settings.ExpandOnHover = hover.Checked;
        menu.Items.Add(hover);
        var hud = new Forms.ToolStripMenuItem("Replace the Windows Volume Flyout") { Checked = _settings.ReplaceSystemHUD, CheckOnClick = true };
        hud.CheckedChanged += (_, _) => _settings.ReplaceSystemHUD = hud.Checked;
        menu.Items.Add(hud);
        var clock = new Forms.ToolStripMenuItem("Clock in the Island") { Checked = _settings.IslandClock, CheckOnClick = true };
        clock.CheckedChanged += (_, _) => _settings.IslandClock = clock.Checked;
        menu.Items.Add(clock);
        var login = new Forms.ToolStripMenuItem("Open at Login") { Checked = _settings.LaunchAtLogin, CheckOnClick = true };
        login.CheckedChanged += (_, _) => _settings.LaunchAtLogin = login.Checked;
        menu.Items.Add(login);
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Quit Islet", null, (_, _) => Quit());
        var icon = new Forms.NotifyIcon
        {
            Icon = System.Drawing.Icon.ExtractAssociatedIcon(Environment.ProcessPath!) ?? System.Drawing.SystemIcons.Application,
            Text = "Islet",
            ContextMenuStrip = menu,
            Visible = true,
        };
        return icon;
    }

    private void ApplyLaunchAtLogin()
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
            if (_settings.LaunchAtLogin && Environment.ProcessPath is string path) key.SetValue("Islet", $"\"{path}\"");
            else key.DeleteValue("Islet", false);
        }
        catch (Exception e) { Log.Error("login", e); }
    }

    private void Quit()
    {
        _settings.Save();
        _tray?.Dispose();
        _volumeKeys?.Dispose();
        _island.Stop();
        _controls.Stop();
        _volume.Dispose();
        _events.Dispose();
        Shutdown();
    }
}
