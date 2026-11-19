using System.Diagnostics;

namespace Islet;

/// A tiny log: debug output always, and a rolling file only with debug tools on
/// (%LocalAppData%\Islet\islet.log), so normal runs never touch the disk for logging.
internal static class Log
{
    private static readonly object Gate = new();
    private static string? _file;

    public static void EnableFile(string folder)
    {
        Directory.CreateDirectory(folder);
        _file = Path.Combine(folder, "islet.log");
        try { if (new FileInfo(_file).Length > 1 << 20) File.Delete(_file); } catch { }
    }

    public static void Info(string area, string message) => Write("info", area, message);
    public static void Debug(string area, string message) => Write("debug", area, message);
    public static void Error(string area, Exception e) => Write("error", area, e.ToString());
    public static void Error(string area, string message) => Write("error", area, message);

    private static void Write(string level, string area, string message)
    {
        var line = $"{DateTime.Now:HH:mm:ss.fff} [{level}] {area}: {message}";
        System.Diagnostics.Debug.WriteLine(line);
        if (_file is null) return;
        lock (Gate)
        {
            try { File.AppendAllText(_file, line + Environment.NewLine); } catch { }
        }
    }
}
