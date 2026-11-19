using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows.Threading;

namespace Islet.Settings;

public enum IslandStyle { Black, Acrylic, ClearAcrylic }
public enum LevelPosition { Island, LeftEdge, RightEdge }
public enum HidePausedPlayer { Never, After10Seconds, After1Minute, After5Minutes }
public enum BatteryIconStyle { Battery, Ring, Percent }
public enum LyricStyle { WordByWord, LineByLine }

/// Every user setting, saved as JSON in %AppData%\Islet\settings.json. Defaults match the
/// Mac app's registered defaults so both feel the same out of the box.
public sealed class AppSettings : INotifyPropertyChanged
{
    public static AppSettings Shared { get; } = Load();

    public event PropertyChangedEventHandler? PropertyChanged;

    // Island
    public bool ExpandOnHover { get => _expandOnHover; set => Set(ref _expandOnHover, value); }
    public IslandStyle IslandStyle { get => _islandStyle; set => Set(ref _islandStyle, value); }
    public double IslandWidthScale { get => _islandWidthScale; set => Set(ref _islandWidthScale, Math.Clamp(value, 0.8, 1.3)); }
    public double IslandHeightScale { get => _islandHeightScale; set => Set(ref _islandHeightScale, Math.Clamp(value, 0.8, 1.3)); }
    public bool SwipeToSkip { get => _swipeToSkip; set => Set(ref _swipeToSkip, value); }
    public bool IslandClock { get => _islandClock; set => Set(ref _islandClock, value); }
    public bool ShowIslandLyrics { get => _showIslandLyrics; set => Set(ref _showIslandLyrics, value); }
    public HidePausedPlayer HidePausedPlayer { get => _hidePausedPlayer; set => Set(ref _hidePausedPlayer, value); }
    public bool HideInFullScreen { get => _hideInFullScreen; set => Set(ref _hideInFullScreen, value); }
    public bool PrivacyDots { get => _privacyDots; set => Set(ref _privacyDots, value); }
    public bool ReduceMotion { get => _reduceMotion; set => Set(ref _reduceMotion, value); }

    // Levels and system events
    public bool ShowVolumeInIsland { get => _showVolume; set => Set(ref _showVolume, value); }
    public bool ShowBrightnessInIsland { get => _showBrightness; set => Set(ref _showBrightness, value); }
    /// Take over the volume keys so Windows' own flyout doesn't show alongside the island.
    public bool ReplaceSystemHUD { get => _replaceHud; set => Set(ref _replaceHud, value); }
    public LevelPosition LevelPosition { get => _levelPosition; set => Set(ref _levelPosition, value); }
    public bool ShowChargingAlert { get => _showCharging; set => Set(ref _showCharging, value); }
    public double ChargingAlertDuration { get => _chargingDuration; set => Set(ref _chargingDuration, Math.Clamp(value, 2, 10)); }
    public BatteryIconStyle BatteryIconStyle { get => _batteryIcon; set => Set(ref _batteryIcon, value); }
    public bool ShowHeadphonesInIsland { get => _showHeadphones; set => Set(ref _showHeadphones, value); }
    public bool ShowUnlockInIsland { get => _showUnlock; set => Set(ref _showUnlock, value); }
    public bool AgentAlerts { get => _agentAlerts; set => Set(ref _agentAlerts, value); }

    // Music and lyrics
    public LyricStyle LyricStyle { get => _lyricStyle; set => Set(ref _lyricStyle, value); }
    public double LyricsOffset { get => _lyricsOffset; set => Set(ref _lyricsOffset, Math.Clamp(value, -2, 2)); }
    public bool LyricWordIcons { get => _wordIcons; set => Set(ref _wordIcons, value); }
    public string? AppleMusicDeveloperToken { get => _amDev; set => Set(ref _amDev, value); }
    public string? AppleMusicUserToken { get => _amUser; set => Set(ref _amUser, value); }
    public string AppleMusicStorefront { get => _amStore; set => Set(ref _amStore, value); }

    // Shelf
    public bool ShelfEnabled { get => _shelf; set => Set(ref _shelf, value); }
    public bool ShelfKeepsCopies { get => _shelfCopies; set => Set(ref _shelfCopies, value); }

    // App
    public bool Onboarded { get => _onboarded; set => Set(ref _onboarded, value); }
    public bool LaunchAtLogin { get => _launchAtLogin; set => Set(ref _launchAtLogin, value); }
    public bool DebugTools { get => _debugTools; set => Set(ref _debugTools, value); }

    private bool _expandOnHover = true;
    private IslandStyle _islandStyle = IslandStyle.Black;
    private double _islandWidthScale = 1, _islandHeightScale = 1;
    private bool _swipeToSkip = true, _islandClock, _showIslandLyrics = true, _hideInFullScreen = true, _privacyDots = true, _reduceMotion;
    private HidePausedPlayer _hidePausedPlayer = HidePausedPlayer.Never;
    private bool _showVolume = true, _showBrightness = true, _replaceHud;
    private LevelPosition _levelPosition = LevelPosition.Island;
    private bool _showCharging = true;
    private double _chargingDuration = 3.5;
    private BatteryIconStyle _batteryIcon = BatteryIconStyle.Battery;
    private bool _showHeadphones = true, _showUnlock = true, _agentAlerts = true;
    private LyricStyle _lyricStyle = LyricStyle.WordByWord;
    private double _lyricsOffset;
    private bool _wordIcons;
    private string? _amDev, _amUser;
    private string _amStore = "us";
    private bool _shelf = true, _shelfCopies;
    private bool _onboarded, _launchAtLogin = true, _debugTools;

    [JsonIgnore] public static string Folder { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Islet");
    [JsonIgnore] public static string CacheFolder { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Islet", "Cache");
    private static string FilePath => Path.Combine(Folder, "settings.json");

    private static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
        IgnoreReadOnlyProperties = true,
    };

    private DispatcherTimer? _saveTimer;

    private void Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
        ScheduleSave();
    }

    /// Writes once things settle, so dragging a slider doesn't write the file 60 times a second.
    private void ScheduleSave()
    {
        if (System.Windows.Application.Current?.Dispatcher is not { } dispatcher) { Save(); return; }
        dispatcher.BeginInvoke(() =>
        {
            _saveTimer ??= new DispatcherTimer(TimeSpan.FromMilliseconds(400), DispatcherPriority.Background, (_, _) =>
            {
                _saveTimer!.Stop();
                Save();
            }, dispatcher);
            _saveTimer.Stop();
            _saveTimer.Start();
        });
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Folder);
            var temp = FilePath + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(this, Json));
            File.Move(temp, FilePath, overwrite: true);
        }
        catch (Exception e) { Log.Error("settings", e); }
    }

    private static AppSettings Load()
    {
        try
        {
            if (File.Exists(FilePath)) return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath), Json) ?? new();
        }
        catch (Exception e) { Log.Error("settings", e); }
        return new AppSettings();
    }

    /// Seconds a paused song stays in the island, or null to keep it.
    public double? HidePausedDelay => HidePausedPlayer switch
    {
        HidePausedPlayer.After10Seconds => 10,
        HidePausedPlayer.After1Minute => 60,
        HidePausedPlayer.After5Minutes => 300,
        _ => null,
    };
}
