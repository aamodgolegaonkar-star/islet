using System.Diagnostics;
using System.Management;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using Windows.Devices.Radios;

namespace Islet.Services;

/// The switches behind Control Center: Wi-Fi and Bluetooth radios, dark mode, keeping the PC
/// awake, brightness, lock and screenshot. Each reads its state when the page opens and is
/// told about changes by Windows where Windows offers that.
internal sealed class SystemControls
{
    private Radio? _wifi, _bluetooth;
    private ManagementEventWatcher? _brightnessWatcher;

    public event Action? Changed;
    /// Brightness changed by the keys or Windows itself (0…1).
    public event Action<double>? BrightnessChanged;

    public async Task StartAsync()
    {
        try
        {
            if (await Radio.RequestAccessAsync() == RadioAccessStatus.Allowed)
            {
                foreach (var radio in await Radio.GetRadiosAsync())
                {
                    if (radio.Kind == RadioKind.WiFi) _wifi ??= radio;
                    if (radio.Kind == RadioKind.Bluetooth) _bluetooth ??= radio;
                }
                if (_wifi is not null) _wifi.StateChanged += (_, _) => Changed?.Invoke();
                if (_bluetooth is not null) _bluetooth.StateChanged += (_, _) => Changed?.Invoke();
            }
        }
        catch (Exception e) { Log.Error("radios", e); }
        WatchBrightness();
    }

    public bool HasWifi => _wifi is not null;
    public bool HasBluetooth => _bluetooth is not null;
    public bool WifiOn => _wifi?.State == RadioState.On;
    public bool BluetoothOn => _bluetooth?.State == RadioState.On;

    public async Task SetWifi(bool on)
    {
        if (_wifi is not null) await _wifi.SetStateAsync(on ? RadioState.On : RadioState.Off);
        Changed?.Invoke();
    }

    public async Task SetBluetooth(bool on)
    {
        if (_bluetooth is not null) await _bluetooth.SetStateAsync(on ? RadioState.On : RadioState.Off);
        Changed?.Invoke();
    }

    // Dark mode: the same two values Settings → Personalization → Colors writes.
    private const string Personalize = @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";

    public bool DarkMode
    {
        get => Registry.CurrentUser.OpenSubKey(Personalize)?.GetValue("AppsUseLightTheme") is int light && light == 0;
        set
        {
            using var key = Registry.CurrentUser.CreateSubKey(Personalize);
            key.SetValue("AppsUseLightTheme", value ? 0 : 1, RegistryValueKind.DWord);
            key.SetValue("SystemUsesLightTheme", value ? 0 : 1, RegistryValueKind.DWord);
            // Tell running apps and the shell, as Settings does.
            SendMessageTimeout(0xFFFF, 0x001A, 0, "ImmersiveColorSet", 2, 200, out _);
            Changed?.Invoke();
        }
    }

    // Keep awake: an execution-state request held by Islet's UI thread while it's on.
    private bool _awake;
    public bool KeepAwake
    {
        get => _awake;
        set
        {
            _awake = value;
            SetThreadExecutionState(value ? 0x80000000 | 0x00000002 | 0x00000001 : 0x80000000);
            Changed?.Invoke();
        }
    }

    // Brightness: built-in displays through WMI (laptops, tablets). External monitors don't
    // report through WMI; the slider is hidden when nothing answers.
    public double? Brightness
    {
        get
        {
            try
            {
                using var searcher = new ManagementObjectSearcher(@"root\WMI", "SELECT CurrentBrightness FROM WmiMonitorBrightness");
                foreach (ManagementObject item in searcher.Get()) return Convert.ToDouble(item["CurrentBrightness"]) / 100;
            }
            catch { }
            return null;
        }
    }

    public void SetBrightness(double value)
    {
        try
        {
            using var searcher = new ManagementObjectSearcher(@"root\WMI", "SELECT * FROM WmiMonitorBrightnessMethods");
            foreach (ManagementObject item in searcher.Get())
                item.InvokeMethod("WmiSetBrightness", [(uint)1, (byte)Math.Round(Math.Clamp(value, 0, 1) * 100)]);
        }
        catch (Exception e) { Log.Error("brightness", e); }
    }

    private void WatchBrightness()
    {
        try
        {
            _brightnessWatcher = new ManagementEventWatcher(new ManagementScope(@"root\WMI"), new EventQuery("SELECT * FROM WmiMonitorBrightnessEvent"));
            _brightnessWatcher.EventArrived += (_, e) => BrightnessChanged?.Invoke(Convert.ToDouble(e.NewEvent["Brightness"]) / 100);
            _brightnessWatcher.Start();
        }
        catch { _brightnessWatcher = null; }
    }

    public void Lock() => LockWorkStation();

    public void Screenshot()
    {
        try { Process.Start(new ProcessStartInfo("ms-screenclip:") { UseShellExecute = true }); }
        catch (Exception e) { Log.Error("screenshot", e); }
    }

    public void Stop()
    {
        _brightnessWatcher?.Stop();
        _brightnessWatcher?.Dispose();
        if (_awake) KeepAwake = false;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern nint SendMessageTimeout(nint hwnd, uint msg, nint wParam, string lParam, uint flags, uint timeout, out nint result);

    [DllImport("kernel32.dll")]
    private static extern uint SetThreadExecutionState(uint flags);

    [DllImport("user32.dll")]
    private static extern bool LockWorkStation();
}
