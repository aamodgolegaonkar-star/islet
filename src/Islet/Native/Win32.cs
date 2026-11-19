using System.Runtime.InteropServices;

namespace Islet.Native;

/// The Win32 calls Islet needs, declared once. Every one is public, documented API.
internal static partial class Win32
{
    public const int GWL_EXSTYLE = -20;
    public const long WS_EX_TOOLWINDOW = 0x80, WS_EX_NOACTIVATE = 0x08000000, WS_EX_TOPMOST = 0x8, WS_EX_TRANSPARENT = 0x20, WS_EX_LAYERED = 0x80000;
    public const int WM_MOUSEMOVE = 0x0200, WM_MOUSELEAVE = 0x02A3, WM_MOUSEACTIVATE = 0x0021, MA_NOACTIVATE = 3;
    public const int WM_DISPLAYCHANGE = 0x007E, WM_DPICHANGED = 0x02E0, WM_SETTINGCHANGE = 0x001A;
    public const int WM_POWERBROADCAST = 0x0218, PBT_POWERSETTINGCHANGE = 0x8013;
    public const int WM_WTSSESSION_CHANGE = 0x02B1, WTS_SESSION_LOCK = 0x7, WTS_SESSION_UNLOCK = 0x8;
    public const int WM_HOTKEY = 0x0312;

    [LibraryImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    public static partial nint GetWindowLongPtr(nint hwnd, int index);

    [LibraryImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    public static partial nint SetWindowLongPtr(nint hwnd, int index, nint value);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool SetWindowPos(nint hwnd, nint after, int x, int y, int cx, int cy, uint flags);

    public static readonly nint HWND_TOPMOST = -1;
    public const uint SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2, SWP_NOACTIVATE = 0x10, SWP_SHOWWINDOW = 0x40, SWP_NOZORDER = 0x4;

    [LibraryImport("user32.dll")]
    public static partial int SetWindowRgn(nint hwnd, nint region, [MarshalAs(UnmanagedType.Bool)] bool redraw);

    [LibraryImport("gdi32.dll")]
    public static partial nint CreateRoundRectRgn(int left, int top, int right, int bottom, int widthEllipse, int heightEllipse);

    [LibraryImport("gdi32.dll")]
    public static partial nint CreateRectRgn(int left, int top, int right, int bottom);

    [LibraryImport("gdi32.dll")]
    public static partial int CombineRgn(nint dest, nint a, nint b, int mode);
    public const int RGN_OR = 2;

    [LibraryImport("gdi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool DeleteObject(nint obj);

    [StructLayout(LayoutKind.Sequential)]
    public struct TRACKMOUSEEVENT
    {
        public uint cbSize, dwFlags;
        public nint hwndTrack;
        public uint dwHoverTime;
    }
    public const uint TME_LEAVE = 0x2;

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool TrackMouseEvent(ref TRACKMOUSEEVENT track);

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GetCursorPos(out POINT point);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MONITORINFO
    {
        public uint cbSize;
        public RECT rcMonitor, rcWork;
        public uint dwFlags;
    }

    [LibraryImport("user32.dll")]
    public static partial nint MonitorFromPoint(POINT point, uint flags);

    [LibraryImport("user32.dll")]
    public static partial nint MonitorFromWindow(nint hwnd, uint flags);
    public const uint MONITOR_DEFAULTTOPRIMARY = 1, MONITOR_DEFAULTTONEAREST = 2;

    [LibraryImport("user32.dll", EntryPoint = "GetMonitorInfoW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GetMonitorInfo(nint monitor, ref MONITORINFO info);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GetWindowRect(nint hwnd, out RECT rect);

    [LibraryImport("user32.dll")]
    public static partial nint GetForegroundWindow();

    [LibraryImport("user32.dll")]
    public static partial nint GetShellWindow();

    [LibraryImport("user32.dll")]
    public static partial nint GetDesktopWindow();

    [LibraryImport("user32.dll", EntryPoint = "GetClassNameW", StringMarshalling = StringMarshalling.Utf16)]
    public static partial int GetClassName(nint hwnd, [Out] char[] name, int max);

    [LibraryImport("shcore.dll")]
    public static partial int GetDpiForMonitor(nint monitor, int type, out uint dpiX, out uint dpiY);

    // DWM: transparent client area and no system frame, corners or border.
    [StructLayout(LayoutKind.Sequential)]
    public struct MARGINS { public int Left, Right, Top, Bottom; }

    [LibraryImport("dwmapi.dll")]
    public static partial int DwmExtendFrameIntoClientArea(nint hwnd, ref MARGINS margins);

    [LibraryImport("dwmapi.dll")]
    public static partial int DwmSetWindowAttribute(nint hwnd, int attribute, ref int value, int size);
    public const int DWMWA_NCRENDERING_POLICY = 2, DWMWA_TRANSITIONS_FORCEDISABLED = 3, DWMWA_WINDOW_CORNER_PREFERENCE = 33,
        DWMWA_BORDER_COLOR = 34, DWMWA_SYSTEMBACKDROP_TYPE = 38, DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
    public const int DWMWCP_DONOTROUND = 1, DWMWA_COLOR_NONE = unchecked((int)0xFFFFFFFE);

    // Keyboard hook for the volume and brightness keys.
    public delegate nint HookProc(int code, nint wParam, nint lParam);

    [LibraryImport("user32.dll", EntryPoint = "SetWindowsHookExW")]
    public static partial nint SetWindowsHookEx(int idHook, HookProc proc, nint module, uint threadId);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool UnhookWindowsHookEx(nint hook);

    [LibraryImport("user32.dll")]
    public static partial nint CallNextHookEx(nint hook, int code, nint wParam, nint lParam);

    [LibraryImport("kernel32.dll", EntryPoint = "GetModuleHandleW", StringMarshalling = StringMarshalling.Utf16)]
    public static partial nint GetModuleHandle(string? name);

    public const int WH_KEYBOARD_LL = 13, WM_KEYDOWN = 0x100, WM_KEYUP = 0x101, WM_SYSKEYDOWN = 0x104, WM_SYSKEYUP = 0x105;
    public const int VK_VOLUME_MUTE = 0xAD, VK_VOLUME_DOWN = 0xAE, VK_VOLUME_UP = 0xAF;
    public const uint LLKHF_INJECTED = 0x10;

    [StructLayout(LayoutKind.Sequential)]
    public struct KBDLLHOOKSTRUCT
    {
        public uint vkCode, scanCode, flags, time;
        public nuint dwExtraInfo;
    }

    // Foreground changes, for hiding over full-screen apps without polling.
    public delegate void WinEventProc(nint hook, uint eventType, nint hwnd, int idObject, int idChild, uint thread, uint time);

    [LibraryImport("user32.dll")]
    public static partial nint SetWinEventHook(uint min, uint max, nint module, WinEventProc proc, uint process, uint thread, uint flags);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool UnhookWinEvent(nint hook);
    public const uint EVENT_SYSTEM_FOREGROUND = 0x0003, EVENT_OBJECT_LOCATIONCHANGE = 0x800B, WINEVENT_OUTOFCONTEXT = 0;

    [LibraryImport("shell32.dll")]
    public static partial int SHQueryUserNotificationState(out int state);
    public const int QUNS_BUSY = 2, QUNS_RUNNING_D3D_FULL_SCREEN = 3, QUNS_PRESENTATION_MODE = 4;

    [LibraryImport("wtsapi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool WTSRegisterSessionNotification(nint hwnd, int flags);

    [LibraryImport("wtsapi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool WTSUnRegisterSessionNotification(nint hwnd);

    // Battery saver / power source changes, delivered as messages (no polling).
    [LibraryImport("user32.dll")]
    public static partial nint RegisterPowerSettingNotification(nint recipient, ref Guid setting, int flags);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool UnregisterPowerSettingNotification(nint handle);

    public static Guid GUID_ACDC_POWER_SOURCE = new("5d3e9a59-e9D5-4b00-a6bd-ff34ff516548");
    public static Guid GUID_BATTERY_PERCENTAGE_REMAINING = new("a7ad8041-b45a-4cae-87a3-eecbb468a9e1");
    public static Guid GUID_POWER_SAVING_STATUS = new("e00958c0-c213-4ace-ac77-fecced2eeea5");
    public static Guid GUID_CONSOLE_DISPLAY_STATE = new("6fe69556-704a-47a0-8f24-c28d936fda47");

    [StructLayout(LayoutKind.Sequential)]
    public struct POWERBROADCAST_SETTING
    {
        public Guid PowerSetting;
        public uint DataLength;
        public uint Data;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct SYSTEM_POWER_STATUS
    {
        public byte ACLineStatus, BatteryFlag, BatteryLifePercent, SystemStatusFlag;
        public int BatteryLifeTime, BatteryFullLifeTime;
    }

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS status);

    // EcoQoS: let Windows run Islet on efficient cores at low clocks while it's at rest.
    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_POWER_THROTTLING_STATE
    {
        public uint Version, ControlMask, StateMask;
    }
    public const int ProcessPowerThrottling = 4;
    public const uint PROCESS_POWER_THROTTLING_EXECUTION_SPEED = 0x1, PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION = 0x4;

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool SetProcessInformation(nint process, int infoClass, ref PROCESS_POWER_THROTTLING_STATE info, int size);

    [LibraryImport("kernel32.dll")]
    public static partial nint GetCurrentProcess();

    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO { public uint cbSize, dwTime; }

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GetLastInputInfo(ref LASTINPUTINFO info);

    [LibraryImport("kernel32.dll")]
    public static partial ulong GetTickCount64();

    /// Seconds since the last keyboard or mouse input anywhere in the session.
    public static double IdleSeconds()
    {
        var info = new LASTINPUTINFO { cbSize = (uint)Marshal.SizeOf<LASTINPUTINFO>() };
        if (!GetLastInputInfo(ref info)) return 0;
        // dwTime is a 32-bit tick count; compare in 32 bits so the wrap after 49 days is harmless.
        return unchecked((uint)GetTickCount64() - info.dwTime) / 1000.0;
    }

    public static void SetEcoQoS(bool on)
    {
        var state = new PROCESS_POWER_THROTTLING_STATE
        {
            Version = 1,
            ControlMask = PROCESS_POWER_THROTTLING_EXECUTION_SPEED | PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION,
            StateMask = on ? PROCESS_POWER_THROTTLING_EXECUTION_SPEED | PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION : 0,
        };
        SetProcessInformation(GetCurrentProcess(), ProcessPowerThrottling, ref state, Marshal.SizeOf<PROCESS_POWER_THROTTLING_STATE>());
    }

    public static void AddExStyle(nint hwnd, long add, long remove = 0)
    {
        var style = (long)GetWindowLongPtr(hwnd, GWL_EXSTYLE);
        var next = (style | add) & ~remove;
        if (next != style) SetWindowLongPtr(hwnd, GWL_EXSTYLE, (nint)next);
    }
}
