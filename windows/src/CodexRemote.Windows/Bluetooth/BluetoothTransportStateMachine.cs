namespace CodexRemote.Windows.Bluetooth;

public enum BluetoothTransportState
{
    Unavailable, Disconnected, Scanning, Connecting, Discovering, Subscribing, Ready,
}

public enum BluetoothCharacteristic
{
    ControlToHost, ControlToDevice, StateToDevice, AudioToHost, AssetToDevice, DeviceInfo,
}

public sealed class BluetoothTransportStateMachine
{
    private static readonly HashSet<BluetoothCharacteristic> Required = Enum.GetValues<BluetoothCharacteristic>().ToHashSet();
    private static readonly HashSet<BluetoothCharacteristic> Notifications =
        [BluetoothCharacteristic.ControlToHost, BluetoothCharacteristic.AudioToHost, BluetoothCharacteristic.DeviceInfo];
    private readonly HashSet<BluetoothCharacteristic> discovered = [];
    private readonly HashSet<BluetoothCharacteristic> subscribed = [];

    public BluetoothTransportState State { get; private set; } = BluetoothTransportState.Disconnected;
    public long Generation { get; private set; }

    public long StartScan(bool radioAvailable)
    {
        ResetConnection(); Generation++;
        State = radioAvailable ? BluetoothTransportState.Scanning : BluetoothTransportState.Unavailable;
        return Generation;
    }

    public void DeviceFound(long generation) { Require(generation, BluetoothTransportState.Scanning); State = BluetoothTransportState.Connecting; }
    public void Connected(long generation) { Require(generation, BluetoothTransportState.Connecting); State = BluetoothTransportState.Discovering; }

    public void CharacteristicDiscovered(long generation, BluetoothCharacteristic characteristic)
    {
        Require(generation, BluetoothTransportState.Discovering);
        discovered.Add(characteristic);
        if (discovered.SetEquals(Required)) State = BluetoothTransportState.Subscribing;
    }

    public void Subscribed(long generation, BluetoothCharacteristic characteristic)
    {
        Require(generation, BluetoothTransportState.Subscribing);
        if (!Notifications.Contains(characteristic)) throw new InvalidOperationException($"{characteristic} must not be subscribed.");
        subscribed.Add(characteristic);
        if (subscribed.SetEquals(Notifications)) State = BluetoothTransportState.Ready;
    }

    public void Disconnected(long generation)
    {
        if (generation != Generation) return;
        ResetConnection(); State = BluetoothTransportState.Disconnected;
    }

    public void RadioUnavailable()
    {
        Generation++; ResetConnection(); State = BluetoothTransportState.Unavailable;
    }

    public bool IsCurrent(long generation) => generation == Generation;

    private void Require(long generation, BluetoothTransportState expected)
    {
        if (generation != Generation) throw new InvalidOperationException("Stale Bluetooth generation.");
        if (State != expected) throw new InvalidOperationException($"Expected {expected}, found {State}.");
    }

    private void ResetConnection() { discovered.Clear(); subscribed.Clear(); }
}
