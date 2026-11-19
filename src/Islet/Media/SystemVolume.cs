using System.Runtime.InteropServices;
using System.Windows.Threading;
using Islet.Native;

namespace Islet.Media;

/// The default output's volume and mute, with change notifications from Windows (no polling).
/// `UserChanged` fires for changes Islet didn't make itself (keys, the flyout, other apps),
/// which is what the island's level HUD shows.
[System.Runtime.InteropServices.ComVisible(true)]
internal sealed class SystemVolume : IMMNotificationClient, IAudioEndpointVolumeCallback, IDisposable
{
    private static Guid _ownChange = Guid.NewGuid();
    private readonly Dispatcher _dispatcher = Dispatcher.CurrentDispatcher;
    private readonly IMMDeviceEnumerator _enumerator = CoreAudio.Enumerator();
    private IMMDevice? _device;
    private IAudioEndpointVolume? _volume;
    private IAudioMeterInformation? _meter;

    public double Level { get; private set; } = 0.5;
    public bool Muted { get; private set; }
    public string? DeviceName { get; private set; }
    public string? DeviceId { get; private set; }

    /// Volume or mute changed (any cause). On the UI thread.
    public event Action? Changed;
    /// Changed by something other than Islet: the island shows the level.
    public event Action<double, bool>? UserChanged;
    /// The default output switched (headphones connected, a new device picked).
    public event Action? DeviceChanged;

    public void Start()
    {
        _enumerator.RegisterEndpointNotificationCallback(this);
        Attach();
    }

    private void Attach()
    {
        if (_volume is not null) { try { _volume.UnregisterControlChangeNotify(this); } catch { } Release(ref _volume); }
        Release(ref _meter);
        Release(ref _device);
        if (_enumerator.GetDefaultAudioEndpoint(EDataFlow.Render, ERole.Multimedia, out var device) != 0) return;
        _device = device;
        device.GetId(out var id);
        DeviceId = id;
        DeviceName = CoreAudio.Property(device, PropertyKey.FriendlyName);
        _volume = CoreAudio.Activate<IAudioEndpointVolume>(device, CoreAudio.IID_IAudioEndpointVolume);
        _meter = CoreAudio.Activate<IAudioMeterInformation>(device, CoreAudio.IID_IAudioMeterInformation);
        if (_volume is null) return;
        _volume.GetMasterVolumeLevelScalar(out var level);
        _volume.GetMute(out var muted);
        Level = level;
        Muted = muted;
        _volume.RegisterControlChangeNotify(this);
        Changed?.Invoke();
    }

    public void SetLevel(double value)
    {
        Level = Math.Clamp(value, 0, 1);
        _volume?.SetMasterVolumeLevelScalar((float)Level, ref _ownChange);
        Changed?.Invoke();
    }

    public void SetMuted(bool muted)
    {
        Muted = muted;
        _volume?.SetMute(muted, ref _ownChange);
        Changed?.Invoke();
    }

    private double _lastStepAt;

    /// One press of a volume key: 1/16 steps like the Mac (1/64 with Shift+Alt), from the
    /// device's real level unless a run of presses is still landing.
    public (double Level, bool Muted) Step(int direction, bool fine)
    {
        if (direction == 0)
        {
            SetMuted(!Muted);
            return (Level, Muted);
        }
        var step = fine ? 1.0 / 64 : 1.0 / 16;
        var now = Environment.TickCount64 / 1000.0;
        var baseLevel = Level;
        if (now - _lastStepAt >= 0.5 && _volume?.GetMasterVolumeLevelScalar(out var real) == 0) baseLevel = real;
        _lastStepAt = now;
        var next = Math.Clamp((Math.Round(baseLevel / step) + direction) * step, 0, 1);
        if (Muted) SetMuted(false);
        SetLevel(next);
        return (next, false);
    }

    /// The output's current peak (0…1), from Windows' own meter: no capture stream needed.
    public float Peak() => _meter?.GetPeakValue(out var peak) == 0 ? peak : 0;

    // IAudioEndpointVolumeCallback: called on an audio thread.
    int IAudioEndpointVolumeCallback.OnNotify(nint data)
    {
        var notification = Marshal.PtrToStructure<AudioVolumeNotificationData>(data);
        var own = notification.EventContext == _ownChange;
        _dispatcher.BeginInvoke(() =>
        {
            Level = notification.MasterVolume;
            Muted = notification.Muted;
            Changed?.Invoke();
            if (!own) UserChanged?.Invoke(Level, Muted);
        });
        return 0;
    }

    // IMMNotificationClient
    void IMMNotificationClient.OnDefaultDeviceChanged(EDataFlow flow, ERole role, string? id)
    {
        if (flow != EDataFlow.Render || role != ERole.Multimedia) return;
        _dispatcher.BeginInvoke(() =>
        {
            Attach();
            DeviceChanged?.Invoke();
        });
    }
    void IMMNotificationClient.OnDeviceStateChanged(string id, uint state) { }
    void IMMNotificationClient.OnDeviceAdded(string id) { }
    void IMMNotificationClient.OnDeviceRemoved(string id) { }
    void IMMNotificationClient.OnPropertyValueChanged(string id, PropertyKey key) { }

    /// Every active output, for the output picker.
    public List<(string Id, string Name)> Outputs()
    {
        var result = new List<(string, string)>();
        if (_enumerator.EnumAudioEndpoints(EDataFlow.Render, CoreAudio.DEVICE_STATE_ACTIVE, out var devices) != 0) return result;
        devices.GetCount(out var count);
        for (uint i = 0; i < count; i++)
        {
            if (devices.Item(i, out var device) != 0) continue;
            device.GetId(out var id);
            result.Add((id, CoreAudio.Property(device, PropertyKey.FriendlyName) ?? "Speakers"));
            Marshal.ReleaseComObject(device);
        }
        Marshal.ReleaseComObject(devices);
        return result;
    }

    /// Makes `id` the default output, the way Sound settings does. Falls back to nothing
    /// (the picker just stays) if this Windows build doesn't offer the interface.
    public bool UseOutput(string id)
    {
        try
        {
            var policy = (IPolicyConfig)new PolicyConfigComObject();
            var ok = policy.SetDefaultEndpoint(id, ERole.Multimedia) == 0;
            policy.SetDefaultEndpoint(id, ERole.Console);
            Marshal.ReleaseComObject(policy);
            return ok;
        }
        catch (Exception e)
        {
            Log.Error("audio", e);
            return false;
        }
    }

    private static void Release<T>(ref T? com) where T : class
    {
        if (com is not null && Marshal.IsComObject(com)) Marshal.ReleaseComObject(com);
        com = null;
    }

    public void Dispose()
    {
        try { _enumerator.UnregisterEndpointNotificationCallback(this); } catch { }
        if (_volume is not null) { try { _volume.UnregisterControlChangeNotify(this); } catch { } }
        Release(ref _volume);
        Release(ref _meter);
        Release(ref _device);
    }
}

/// Takes over the volume keys so only the island shows the level (Settings: "Replace the
/// Windows volume flyout"). The hook runs on its own thread with its own message loop, so a
/// busy UI thread can never make Windows drop it, and it does nothing but read three keys.
internal sealed class VolumeKeys : IDisposable
{
    private readonly Action<int, bool> _press;
    private Thread? _thread;
    private uint _threadId;
    private nint _hook;
    private Win32.HookProc? _proc;

    /// `press(direction, fine)`: +1 up, −1 down, 0 mute. Called on the hook thread.
    public VolumeKeys(Action<int, bool> press) => _press = press;

    public void Start()
    {
        if (_thread is not null) return;
        _thread = new Thread(Run) { IsBackground = true, Name = "Islet volume keys", Priority = ThreadPriority.AboveNormal };
        _thread.Start();
    }

    private void Run()
    {
        _threadId = GetCurrentThreadId();
        _proc = Hook;
        _hook = Win32.SetWindowsHookEx(Win32.WH_KEYBOARD_LL, _proc, Win32.GetModuleHandle(null), 0);
        while (GetMessage(out var msg, 0, 0, 0) > 0) { TranslateMessage(ref msg); DispatchMessage(ref msg); }
        if (_hook != 0) Win32.UnhookWindowsHookEx(_hook);
    }

    private nint Hook(int code, nint wParam, nint lParam)
    {
        if (code >= 0)
        {
            var key = Marshal.PtrToStructure<Win32.KBDLLHOOKSTRUCT>(lParam);
            var direction = key.vkCode switch
            {
                Win32.VK_VOLUME_UP => 1,
                Win32.VK_VOLUME_DOWN => -1,
                Win32.VK_VOLUME_MUTE => 0,
                _ => (int?)null,
            };
            // Injected keys (other tools) pass through untouched.
            if (direction is int d && (key.flags & Win32.LLKHF_INJECTED) == 0)
            {
                if (wParam is Win32.WM_KEYDOWN or Win32.WM_SYSKEYDOWN)
                {
                    var fine = (GetAsyncKeyState(0x10) & 0x8000) != 0 && (GetAsyncKeyState(0x12) & 0x8000) != 0;
                    _press(d, fine);
                }
                return 1;
            }
        }
        return Win32.CallNextHookEx(_hook, code, wParam, lParam);
    }

    public void Dispose()
    {
        if (_threadId != 0) PostThreadMessage(_threadId, 0x0012 /* WM_QUIT */, 0, 0);
        _thread = null;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG { public nint hwnd; public uint message; public nint wParam, lParam; public uint time; public Win32.POINT pt; }

    [DllImport("user32.dll")] private static extern int GetMessage(out MSG msg, nint hwnd, uint min, uint max);
    [DllImport("user32.dll")] private static extern bool TranslateMessage(ref MSG msg);
    [DllImport("user32.dll")] private static extern nint DispatchMessage(ref MSG msg);
    [DllImport("user32.dll")] private static extern bool PostThreadMessage(uint thread, uint msg, nint wParam, nint lParam);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
}
