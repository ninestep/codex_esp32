using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Devices.Enumeration;
using Windows.Storage.Streams;

namespace CodexRemote.Windows.Bluetooth;

public enum BluetoothLogicalChannel { ControlToHost, ControlToDevice, StateToDevice, AudioToHost, AssetToDevice, DeviceInfo }
public sealed record BluetoothPacket(BluetoothLogicalChannel Channel, byte[] Bytes);

public sealed class WindowsBluetoothTransport : IAsyncDisposable
{
    private readonly BluetoothTransportStateMachine stateMachine = new();
    private readonly Dictionary<BluetoothCharacteristic, GattCharacteristic> characteristics = [];
    private BluetoothLEAdvertisementWatcher? watcher;
    private BluetoothLEDevice? device;
    private GattDeviceService? service;
    private int connecting;
    private bool disposed;

    public BluetoothTransportState State => stateMachine.State;
    public event Action<BluetoothTransportState>? StateChanged;
    public event Action<BluetoothPacket>? PacketReceived;
    public event Action<Exception>? TransportError;

    public void Start()
    {
        ObjectDisposedException.ThrowIf(disposed, this); StopWatcher();
        long generation = stateMachine.StartScan(radioAvailable: true); PublishState();
        watcher = new BluetoothLEAdvertisementWatcher { ScanningMode = BluetoothLEScanningMode.Active };
        watcher.AdvertisementFilter.Advertisement.ServiceUuids.Add(BluetoothUuids.Service);
        watcher.Received += (sender, args) => { _ = ConnectAsync(args.BluetoothAddress, generation); };
        watcher.Stopped += (sender, args) => { if (stateMachine.IsCurrent(generation) && State == BluetoothTransportState.Scanning) ScheduleRestart(generation); };
        watcher.Start();
        _ = ConnectPairedDeviceAsync(generation);
    }

    public async Task SendAsync(BluetoothLogicalChannel channel, ReadOnlyMemory<byte> bytes, CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (State != BluetoothTransportState.Ready) throw new InvalidOperationException("Bluetooth transport is not ready.");
        BluetoothCharacteristic role = channel switch {
            BluetoothLogicalChannel.ControlToDevice => BluetoothCharacteristic.ControlToDevice,
            BluetoothLogicalChannel.StateToDevice => BluetoothCharacteristic.StateToDevice,
            BluetoothLogicalChannel.AssetToDevice => BluetoothCharacteristic.AssetToDevice,
            _ => throw new InvalidOperationException("The selected channel is not writable."),
        };
        using var writer = new DataWriter(); writer.WriteBytes(bytes.ToArray()); IBuffer buffer = writer.DetachBuffer();
        GattWriteResult result = await characteristics[role].WriteValueWithResultAsync(buffer, GattWriteOption.WriteWithResponse).AsTask(cancellationToken);
        if (result.Status != GattCommunicationStatus.Success) throw new IOException($"GATT write failed: {result.Status}, protocolError={result.ProtocolError}.");
    }

    public async ValueTask DisposeAsync()
    {
        if (disposed) return; disposed = true; StopWatcher(); await DisconnectAsync();
    }

    private async Task ConnectAsync(ulong address, long generation)
    {
        if (!stateMachine.IsCurrent(generation) || Interlocked.Exchange(ref connecting, 1) != 0) return;
        try {
            StopWatcher(); stateMachine.DeviceFound(generation); PublishState();
            BluetoothLEDevice? candidate = await BluetoothLEDevice.FromBluetoothAddressAsync(address);
            if (candidate is null || !stateMachine.IsCurrent(generation)) throw new IOException("Unable to open the discovered BLE device.");
            device = candidate; device.ConnectionStatusChanged += DeviceConnectionStatusChanged;
            stateMachine.Connected(generation); PublishState();
            GattDeviceServicesResult services = await device.GetGattServicesForUuidAsync(BluetoothUuids.Service, BluetoothCacheMode.Uncached);
            if (services.Status != GattCommunicationStatus.Success || services.Services.Count != 1) throw new IOException("Codex Remote GATT service was not found.");
            service = services.Services[0];
            await DiscoverAsync(generation);
        } catch (Exception error) {
            TransportError?.Invoke(error); stateMachine.Disconnected(generation); PublishState(); await DisconnectAsync(); ScheduleRestart(generation);
        } finally { Interlocked.Exchange(ref connecting, 0); }
    }

    private async Task ConnectPairedDeviceAsync(long generation)
    {
        try
        {
            DeviceInformationCollection paired = await DeviceInformation.FindAllAsync(BluetoothLEDevice.GetDeviceSelectorFromPairingState(true));
            foreach (DeviceInformation information in paired)
            {
                if (!stateMachine.IsCurrent(generation) || State != BluetoothTransportState.Scanning) return;
                if (!information.Name.Contains("Codex Remote", StringComparison.OrdinalIgnoreCase)
                    && !information.Name.Contains("Codex Micro", StringComparison.OrdinalIgnoreCase)) continue;
                BluetoothLEDevice? candidate = null;
                GattDeviceServicesResult? services = null;
                try
                {
                    candidate = await BluetoothLEDevice.FromIdAsync(information.Id);
                    if (candidate is null) continue;
                    services = await candidate.GetGattServicesForUuidAsync(BluetoothUuids.Service, BluetoothCacheMode.Cached);
                    if (services.Status != GattCommunicationStatus.Success || services.Services.Count != 1)
                    {
                        services = await candidate.GetGattServicesForUuidAsync(BluetoothUuids.Service, BluetoothCacheMode.Uncached);
                    }
                }
                catch { candidate?.Dispose(); continue; }
                if (services.Status != GattCommunicationStatus.Success || services.Services.Count != 1) { candidate.Dispose(); continue; }
                if (Interlocked.Exchange(ref connecting, 1) != 0) { candidate.Dispose(); return; }
                try
                {
                    StopWatcher(); stateMachine.DeviceFound(generation); PublishState();
                    device = candidate; device.ConnectionStatusChanged += DeviceConnectionStatusChanged;
                    stateMachine.Connected(generation); PublishState();
                    service = services.Services[0];
                    await DiscoverAsync(generation);
                    return;
                }
                catch (Exception error)
                {
                    TransportError?.Invoke(error); stateMachine.Disconnected(generation); PublishState(); await DisconnectAsync(); ScheduleRestart(generation); return;
                }
                finally { Interlocked.Exchange(ref connecting, 0); }
            }
        }
        catch { /* Paired-device probing is best-effort; advertisement scanning remains active. */ }
    }

    private async Task DiscoverAsync(long generation)
    {
        var roles = new (BluetoothCharacteristic Role, Guid Uuid)[] {
            (BluetoothCharacteristic.ControlToHost, BluetoothUuids.ControlToHost), (BluetoothCharacteristic.ControlToDevice, BluetoothUuids.ControlToDevice),
            (BluetoothCharacteristic.StateToDevice, BluetoothUuids.StateToDevice), (BluetoothCharacteristic.AudioToHost, BluetoothUuids.AudioToHost),
            (BluetoothCharacteristic.AssetToDevice, BluetoothUuids.AssetToDevice), (BluetoothCharacteristic.DeviceInfo, BluetoothUuids.DeviceInfo),
        };
        foreach ((BluetoothCharacteristic role, Guid uuid) in roles) {
            GattCharacteristicsResult result = await service!.GetCharacteristicsForUuidAsync(uuid, BluetoothCacheMode.Uncached);
            if (result.Status != GattCommunicationStatus.Success || result.Characteristics.Count != 1) throw new IOException($"Required GATT characteristic is missing: {role}.");
            characteristics[role] = result.Characteristics[0]; stateMachine.CharacteristicDiscovered(generation, role);
        }
        PublishState();
        foreach (BluetoothCharacteristic role in new[] { BluetoothCharacteristic.ControlToHost, BluetoothCharacteristic.AudioToHost, BluetoothCharacteristic.DeviceInfo }) {
            GattCharacteristic characteristic = characteristics[role]; characteristic.ValueChanged += CharacteristicValueChanged;
            GattCommunicationStatus status = await characteristic.WriteClientCharacteristicConfigurationDescriptorAsync(GattClientCharacteristicConfigurationDescriptorValue.Notify);
            if (status != GattCommunicationStatus.Success) throw new IOException($"GATT notification subscription failed: {role}.");
            stateMachine.Subscribed(generation, role);
        }
        PublishState();
        GattReadResult initialDeviceInfo = await characteristics[BluetoothCharacteristic.DeviceInfo].ReadValueAsync(BluetoothCacheMode.Uncached);
        if (initialDeviceInfo.Status == GattCommunicationStatus.Success) PublishPacket(BluetoothLogicalChannel.DeviceInfo, initialDeviceInfo.Value);
    }

    private void CharacteristicValueChanged(GattCharacteristic sender, GattValueChangedEventArgs args)
    {
        BluetoothLogicalChannel? channel = sender.Uuid == BluetoothUuids.ControlToHost ? BluetoothLogicalChannel.ControlToHost
            : sender.Uuid == BluetoothUuids.AudioToHost ? BluetoothLogicalChannel.AudioToHost
            : sender.Uuid == BluetoothUuids.DeviceInfo ? BluetoothLogicalChannel.DeviceInfo : null;
        if (channel is null) return;
        PublishPacket(channel.Value, args.CharacteristicValue);
    }

    private void PublishPacket(BluetoothLogicalChannel channel, IBuffer buffer)
    {
        using DataReader reader = DataReader.FromBuffer(buffer); var bytes = new byte[reader.UnconsumedBufferLength]; reader.ReadBytes(bytes);
        PacketReceived?.Invoke(new(channel, bytes));
    }

    private void DeviceConnectionStatusChanged(BluetoothLEDevice sender, object args)
    {
        if (sender.ConnectionStatus == BluetoothConnectionStatus.Connected) return;
        long generation = stateMachine.Generation; stateMachine.Disconnected(generation); PublishState(); _ = DisconnectAsync(); ScheduleRestart(generation);
    }

    private async Task DisconnectAsync()
    {
        foreach (GattCharacteristic characteristic in characteristics.Values) characteristic.ValueChanged -= CharacteristicValueChanged;
        characteristics.Clear(); service?.Dispose(); service = null;
        if (device is not null) { device.ConnectionStatusChanged -= DeviceConnectionStatusChanged; device.Dispose(); device = null; }
        await Task.CompletedTask;
    }

    private void ScheduleRestart(long generation) => _ = Task.Run(async () => { await Task.Delay(TimeSpan.FromSeconds(1)); if (!disposed && stateMachine.IsCurrent(generation) && State == BluetoothTransportState.Disconnected) Start(); });
    private void StopWatcher() { if (watcher is null) return; watcher.Stop(); watcher = null; }
    private void PublishState() => StateChanged?.Invoke(State);
}
