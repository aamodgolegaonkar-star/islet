using System.Runtime.InteropServices;
using System.Windows.Interop;
using Islet.Island;
using Islet.Native;

namespace Islet.Services;

/// Power, battery and session events, delivered by Windows as window messages to a hidden
/// message-only window: no polling, nothing runs between events.
internal sealed class SystemEvents : IDisposable
{
    private readonly HwndSource _window;
    private readonly List<nint> _registrations = [];
    private bool? _onPower;
    private int? _percent;
    private int _lastWarning = 101;

    /// A charger was connected (with the battery's state then).
    public event Action<BatteryState>? Plugged;
    /// The battery crossed 20% or 10% while on battery.
    public event Action<int>? LowBattery;
    public event Action? Unlocked;
    public event Action? Locked;
    /// The display turned off or on (sleep, lid, power plan).
    public event Action<bool>? DisplayOn;
    /// Battery saver turned on or off.
    public event Action<bool>? BatterySaver;

    public bool IsLocked { get; private set; }
    public bool IsDisplayOn { get; private set; } = true;
    public bool IsBatterySaverOn { get; private set; }

    public SystemEvents()
    {
        // HWND_MESSAGE parent: never shown, never in the window list.
        _window = new HwndSource(new HwndSourceParameters("Islet events") { ParentWindow = -3, WindowStyle = 0 });
        _window.AddHook(WndProc);
        foreach (var guid in new[] { Win32.GUID_ACDC_POWER_SOURCE, Win32.GUID_BATTERY_PERCENTAGE_REMAINING, Win32.GUID_CONSOLE_DISPLAY_STATE, Win32.GUID_POWER_SAVING_STATUS })
        {
            var g = guid;
            var handle = Win32.RegisterPowerSettingNotification(_window.Handle, ref g, 0);
            if (handle != 0) _registrations.Add(handle);
        }
        Win32.WTSRegisterSessionNotification(_window.Handle, 0);
    }

    public BatteryState? Battery()
    {
        if (!Win32.GetSystemPowerStatus(out var status) || status.BatteryFlag == 128 || status.BatteryLifePercent > 100) return null;
        return new BatteryState(status.BatteryLifePercent / 100.0, (status.BatteryFlag & 8) != 0, status.ACLineStatus == 1);
    }

    public bool HasBattery => Battery() is not null;

    private nint WndProc(nint hwnd, int msg, nint wParam, nint lParam, ref bool handled)
    {
        if (msg == Win32.WM_POWERBROADCAST && wParam == Win32.PBT_POWERSETTINGCHANGE)
        {
            var setting = Marshal.PtrToStructure<Win32.POWERBROADCAST_SETTING>(lParam);
            if (setting.PowerSetting == Win32.GUID_ACDC_POWER_SOURCE)
            {
                var onPower = setting.Data == 0; // PoAc
                // The first report after registering is the current state, not a change.
                if (_onPower is bool was && !was && onPower && Battery() is { } battery) Plugged?.Invoke(battery with { OnPower = true, Charging = true });
                _onPower = onPower;
                if (onPower) _lastWarning = 101;
            }
            else if (setting.PowerSetting == Win32.GUID_BATTERY_PERCENTAGE_REMAINING)
            {
                var percent = (int)setting.Data;
                if (_percent is int previous && _onPower == false)
                {
                    foreach (var level in new[] { 20, 10 })
                        if (previous > level && percent <= level && _lastWarning > level)
                        {
                            _lastWarning = level;
                            LowBattery?.Invoke(percent);
                        }
                }
                _percent = percent;
            }
            else if (setting.PowerSetting == Win32.GUID_CONSOLE_DISPLAY_STATE)
            {
                IsDisplayOn = setting.Data != 0;
                DisplayOn?.Invoke(IsDisplayOn);
            }
            else if (setting.PowerSetting == Win32.GUID_POWER_SAVING_STATUS)
            {
                IsBatterySaverOn = setting.Data != 0;
                BatterySaver?.Invoke(IsBatterySaverOn);
            }
        }
        else if (msg == Win32.WM_WTSSESSION_CHANGE)
        {
            if (wParam == Win32.WTS_SESSION_LOCK) { IsLocked = true; Locked?.Invoke(); }
            else if (wParam == Win32.WTS_SESSION_UNLOCK) { IsLocked = false; Unlocked?.Invoke(); }
        }
        return 0;
    }

    public void Dispose()
    {
        foreach (var handle in _registrations) Win32.UnregisterPowerSettingNotification(handle);
        Win32.WTSUnRegisterSessionNotification(_window.Handle);
        _window.Dispose();
    }
}
