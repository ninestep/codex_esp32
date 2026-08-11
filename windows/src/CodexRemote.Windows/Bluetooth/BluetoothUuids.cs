namespace CodexRemote.Windows.Bluetooth;

public static class BluetoothUuids
{
    public static readonly Guid Service = Guid.Parse("7D2E0000-7C6A-4E6D-A3E1-9F6B4C520001");
    public static readonly Guid ControlToHost = Guid.Parse("7D2E0001-7C6A-4E6D-A3E1-9F6B4C520001");
    public static readonly Guid ControlToDevice = Guid.Parse("7D2E0002-7C6A-4E6D-A3E1-9F6B4C520001");
    public static readonly Guid StateToDevice = Guid.Parse("7D2E0003-7C6A-4E6D-A3E1-9F6B4C520001");
    public static readonly Guid AudioToHost = Guid.Parse("7D2E0004-7C6A-4E6D-A3E1-9F6B4C520001");
    public static readonly Guid AssetToDevice = Guid.Parse("7D2E0005-7C6A-4E6D-A3E1-9F6B4C520001");
    public static readonly Guid DeviceInfo = Guid.Parse("7D2E0006-7C6A-4E6D-A3E1-9F6B4C520001");
}
