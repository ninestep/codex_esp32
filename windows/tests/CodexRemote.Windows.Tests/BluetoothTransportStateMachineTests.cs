using CodexRemote.Windows.Bluetooth;

namespace CodexRemote.Windows.Tests;

[TestClass]
public sealed class BluetoothTransportStateMachineTests
{
    [TestMethod]
    public void ReadyRequiresAllSixCharacteristicsAndThreeSubscriptions()
    {
        var machine = new BluetoothTransportStateMachine(); long generation = machine.StartScan(true);
        machine.DeviceFound(generation); machine.Connected(generation);
        foreach (BluetoothCharacteristic value in Enum.GetValues<BluetoothCharacteristic>()) machine.CharacteristicDiscovered(generation, value);
        Assert.AreEqual(BluetoothTransportState.Subscribing, machine.State);
        machine.Subscribed(generation, BluetoothCharacteristic.ControlToHost);
        machine.Subscribed(generation, BluetoothCharacteristic.AudioToHost);
        machine.Subscribed(generation, BluetoothCharacteristic.DeviceInfo);
        Assert.AreEqual(BluetoothTransportState.Ready, machine.State);
    }

    [TestMethod]
    public void StaleDisconnectDoesNotPolluteNewGeneration()
    {
        var machine = new BluetoothTransportStateMachine(); long stale = machine.StartScan(true); long current = machine.StartScan(true);
        machine.Disconnected(stale);
        Assert.IsTrue(machine.IsCurrent(current)); Assert.AreEqual(BluetoothTransportState.Scanning, machine.State);
    }

    [TestMethod]
    public void WriteOnlyCharacteristicCannotBeSubscribed()
    {
        var machine = ReadyToSubscribe(out long generation);
        Assert.ThrowsExactly<InvalidOperationException>(() => machine.Subscribed(generation, BluetoothCharacteristic.ControlToDevice));
    }

    private static BluetoothTransportStateMachine ReadyToSubscribe(out long generation)
    {
        var machine = new BluetoothTransportStateMachine(); generation = machine.StartScan(true); machine.DeviceFound(generation); machine.Connected(generation);
        foreach (BluetoothCharacteristic value in Enum.GetValues<BluetoothCharacteristic>()) machine.CharacteristicDiscovered(generation, value);
        return machine;
    }
}
