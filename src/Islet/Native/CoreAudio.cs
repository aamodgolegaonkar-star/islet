using System.Runtime.InteropServices;

namespace Islet.Native;

// Windows Core Audio (MMDevice API + endpoint volume), declared by hand so Islet needs no
// audio library. Only the members Islet calls are typed; the rest keep their vtable slots.

internal enum EDataFlow { Render, Capture, All }
internal enum ERole { Console, Multimedia, Communications }

[StructLayout(LayoutKind.Sequential)]
internal struct PropertyKey(Guid fmtid, uint pid)
{
    public Guid Fmtid = fmtid;
    public uint Pid = pid;
    public static readonly PropertyKey FriendlyName = new(new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), 14);
    public static readonly PropertyKey FormFactor = new(new Guid("1da5d803-d492-4edd-8c23-e0c0ffee7f0e"), 0);
    public static readonly PropertyKey InstanceId = new(new Guid("78c34fc8-104a-4aca-9ea4-524d52996e57"), 256);
}

[StructLayout(LayoutKind.Explicit)]
internal struct PropVariant
{
    [FieldOffset(0)] public ushort vt;
    [FieldOffset(8)] public nint pointer;
    [FieldOffset(8)] public uint uintValue;

    public readonly string? AsString() => vt == 31 /* VT_LPWSTR */ ? Marshal.PtrToStringUni(pointer) : null;
    public readonly uint? AsUInt() => vt is 19 or 3 ? uintValue : null;

    [DllImport("ole32.dll")]
    private static extern int PropVariantClear(ref PropVariant value);
    public void Clear() => PropVariantClear(ref this);
}

[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
internal class MMDeviceEnumeratorComObject;

[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMMDeviceEnumerator
{
    [PreserveSig] int EnumAudioEndpoints(EDataFlow flow, uint stateMask, out IMMDeviceCollection devices);
    [PreserveSig] int GetDefaultAudioEndpoint(EDataFlow flow, ERole role, out IMMDevice device);
    [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
    [PreserveSig] int RegisterEndpointNotificationCallback(IMMNotificationClient client);
    [PreserveSig] int UnregisterEndpointNotificationCallback(IMMNotificationClient client);
}

[ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMMDeviceCollection
{
    [PreserveSig] int GetCount(out uint count);
    [PreserveSig] int Item(uint index, out IMMDevice device);
}

[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMMDevice
{
    [PreserveSig] int Activate(ref Guid iid, uint context, nint activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object instance);
    [PreserveSig] int OpenPropertyStore(uint access, out IPropertyStore properties);
    [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
    [PreserveSig] int GetState(out uint state);
}

[ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IPropertyStore
{
    [PreserveSig] int GetCount(out uint count);
    [PreserveSig] int GetAt(uint index, out PropertyKey key);
    [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
}

[ComImport, Guid("7991EEC9-7E89-4D85-8390-6C703CEC60C0"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMMNotificationClient
{
    void OnDeviceStateChanged([MarshalAs(UnmanagedType.LPWStr)] string id, uint state);
    void OnDeviceAdded([MarshalAs(UnmanagedType.LPWStr)] string id);
    void OnDeviceRemoved([MarshalAs(UnmanagedType.LPWStr)] string id);
    void OnDefaultDeviceChanged(EDataFlow flow, ERole role, [MarshalAs(UnmanagedType.LPWStr)] string? id);
    void OnPropertyValueChanged([MarshalAs(UnmanagedType.LPWStr)] string id, PropertyKey key);
}

[ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IAudioEndpointVolume
{
    [PreserveSig] int RegisterControlChangeNotify(IAudioEndpointVolumeCallback callback);
    [PreserveSig] int UnregisterControlChangeNotify(IAudioEndpointVolumeCallback callback);
    [PreserveSig] int GetChannelCount(out uint count);
    [PreserveSig] int SetMasterVolumeLevel(float db, ref Guid context);
    [PreserveSig] int SetMasterVolumeLevelScalar(float level, ref Guid context);
    [PreserveSig] int GetMasterVolumeLevel(out float db);
    [PreserveSig] int GetMasterVolumeLevelScalar(out float level);
    [PreserveSig] int SetChannelVolumeLevel(uint channel, float db, ref Guid context);
    [PreserveSig] int SetChannelVolumeLevelScalar(uint channel, float level, ref Guid context);
    [PreserveSig] int GetChannelVolumeLevel(uint channel, out float db);
    [PreserveSig] int GetChannelVolumeLevelScalar(uint channel, out float level);
    [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid context);
    [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
}

[StructLayout(LayoutKind.Sequential)]
internal struct AudioVolumeNotificationData
{
    public Guid EventContext;
    [MarshalAs(UnmanagedType.Bool)] public bool Muted;
    public float MasterVolume;
    public uint Channels;
}

[ComImport, Guid("657804FA-D6AD-4496-8A60-352752AF4F89"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IAudioEndpointVolumeCallback
{
    [PreserveSig] int OnNotify(nint data);
}

/// A cheap system peak meter: the level Windows already computes for the endpoint, with no
/// capture stream of Islet's own.
[ComImport, Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IAudioMeterInformation
{
    [PreserveSig] int GetPeakValue(out float peak);
    [PreserveSig] int GetMeteringChannelCount(out uint count);
    [PreserveSig] int GetChannelsPeakValues(uint count, [Out, MarshalAs(UnmanagedType.LPArray)] float[] peaks);
}

/// Switching the default output: the long-standing (undocumented but stable since Vista)
/// IPolicyConfig interface that Windows' own Sound settings use.
[ComImport, Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9")]
internal class PolicyConfigComObject;

[ComImport, Guid("f8679f50-850a-41cf-9c72-430f290290c8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IPolicyConfig
{
    void GetMixFormat(); void GetDeviceFormat(); void ResetDeviceFormat(); void SetDeviceFormat();
    void GetProcessingPeriod(); void SetProcessingPeriod(); void GetShareMode(); void SetShareMode();
    void GetPropertyValue(); void SetPropertyValue();
    [PreserveSig] int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string id, ERole role);
    void SetEndpointVisibility();
}

internal static class CoreAudio
{
    public static readonly Guid IID_IAudioEndpointVolume = typeof(IAudioEndpointVolume).GUID;
    public static readonly Guid IID_IAudioMeterInformation = typeof(IAudioMeterInformation).GUID;
    public const uint CLSCTX_ALL = 0x17, DEVICE_STATE_ACTIVE = 1;

    public static IMMDeviceEnumerator Enumerator() => (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();

    public static T? Activate<T>(IMMDevice device, Guid iid) where T : class
    {
        var id = iid;
        return device.Activate(ref id, CLSCTX_ALL, 0, out var instance) == 0 ? instance as T : null;
    }

    public static string? Property(IMMDevice device, PropertyKey key)
    {
        if (device.OpenPropertyStore(0, out var store) != 0) return null;
        try
        {
            var k = key;
            if (store.GetValue(ref k, out var value) != 0) return null;
            var text = value.AsString();
            value.Clear();
            return text;
        }
        finally { Marshal.ReleaseComObject(store); }
    }

    public static uint? UIntProperty(IMMDevice device, PropertyKey key)
    {
        if (device.OpenPropertyStore(0, out var store) != 0) return null;
        try
        {
            var k = key;
            if (store.GetValue(ref k, out var value) != 0) return null;
            var number = value.AsUInt();
            value.Clear();
            return number;
        }
        finally { Marshal.ReleaseComObject(store); }
    }
}
