using System.ComponentModel;
using System.IO;
using System.Windows;
using CodexRemote.Windows.Bluetooth;
using CodexRemote.Windows.Speech;
using CodexRemote.Protocol.Ble;
using CodexRemote.Protocol.Audio;
using CodexRemote.Core.Audio;
using CodexRemote.Windows.Input;
using System.Buffers.Binary;
using System.Text;

namespace CodexRemote.WindowsApp;

public partial class SettingsWindow : Window
{
    private readonly WindowsBluetoothTransport bluetooth = new();
    private readonly DoubaoCredentialStore credentials;
    private readonly BleFragmentReassembler deviceInfoReassembler = new();
    private readonly BleFragmentReassembler controlReassembler = new();
    private readonly BleFragmentReassembler audioReassembler = new();
    private readonly SemaphoreSlim packetLock = new(1, 1);
    private readonly SpeechOverlay overlay;
    private SpeechAudioInputBridge? speechBridge;
    private ushort? activeSessionKey;
    private uint outgoingSequence = 1;
    private uint outgoingMessageId = 1;
    private bool allowClose;
    private bool started;

    public AppModel Model { get; } = new();
    public string[] ControlLabels { get; } = ["命令 1–6：等待设备布局", "编码器：等待设备布局", "摇杆：上 / 右 / 下 / 左"];

    public SettingsWindow(SpeechOverlay overlay)
    {
        this.overlay = overlay;
        InitializeComponent();
        DataContext = this;
        string credentialPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Codex Remote", "doubao-credentials.bin");
        credentials = new DoubaoCredentialStore(credentialPath);
        bluetooth.StateChanged += OnBluetoothStateChanged;
        bluetooth.PacketReceived += OnBluetoothPacket;
        bluetooth.TransportError += OnBluetoothError;
        Loaded += WindowLoaded;
    }

    private async void WindowLoaded(object sender, RoutedEventArgs e)
    {
        if (started) return;
        started = true;
        try { Model.LoggedIn = await credentials.LoadAsync(CancellationToken.None) is not null; }
        catch { Model.LoggedIn = false; }
        bluetooth.Start();
    }

    private void OnBluetoothStateChanged(BluetoothTransportState state) => Dispatcher.Invoke(() => Model.ConnectionStatus = state switch
    {
        BluetoothTransportState.Unavailable => "蓝牙不可用",
        BluetoothTransportState.Disconnected => "设备已断开，正在重试…",
        BluetoothTransportState.Scanning => "正在搜索 Codex Remote…",
        BluetoothTransportState.Connecting => "已发现设备，正在连接…",
        BluetoothTransportState.Discovering => "设备已连接，正在读取服务…",
        BluetoothTransportState.Subscribing => "设备已连接，正在订阅数据…",
        BluetoothTransportState.Ready => "Codex Remote 已连接",
        _ => state.ToString(),
    });

    private void OnBluetoothError(Exception error) => Dispatcher.Invoke(() => Model.ConnectionStatus = $"连接失败：{error.Message}");

    private void OnBluetoothPacket(BluetoothPacket packet) => _ = HandleBluetoothPacketAsync(packet);

    private async Task HandleBluetoothPacketAsync(BluetoothPacket packet)
    {
        if (packet.Channel is not (BluetoothLogicalChannel.DeviceInfo or BluetoothLogicalChannel.ControlToHost or BluetoothLogicalChannel.AudioToHost)) return;
        await packetLock.WaitAsync();
        try
        {
            BleFragmentReassembler reassembler = packet.Channel switch
            {
                BluetoothLogicalChannel.DeviceInfo => deviceInfoReassembler,
                BluetoothLogicalChannel.ControlToHost => controlReassembler,
                _ => audioReassembler,
            };
            byte[]? message = reassembler.Accept(packet.Bytes);
            if (message is null) return;
            BleEnvelope envelope = BleEnvelopeCodec.Decode(message);
            if (envelope.Type == BleMessageType.DeviceInfo) DecodeDeviceInfo(envelope.Payload);
            else if (envelope.Type == BleMessageType.PttBegin) await BeginPttAsync(envelope.Payload);
            else if (envelope.Type == BleMessageType.AudioFrame) await AppendAudioAsync(envelope.Payload);
            else if (envelope.Type == BleMessageType.PttEnd) await EndPttAsync(envelope.Payload);
        }
        catch (Exception error)
        {
            Dispatcher.Invoke(() => { Model.SpeechStatus = error.Message; overlay.SetState(error.Message, false); });
            if (speechBridge is not null) { await speechBridge.CancelAsync(); speechBridge = null; activeSessionKey = null; }
        }
        finally { packetLock.Release(); }
    }

    private void DecodeDeviceInfo(byte[] payload)
    {
            var reader = new BleBinaryReader(payload);
            byte protocolMajor = reader.ReadByte();
            _ = reader.ReadByte();
            if (protocolMajor != BleEnvelopeCodec.CurrentMajor) throw new BleProtocolException("设备协议版本不兼容。");
            _ = reader.ReadString(64);
            _ = reader.ReadUInt16();
            byte battery = reader.ReadByte();
            byte charging = reader.ReadByte();
            reader.RequireEnd();
            if (battery > 100 || charging > 1) throw new BleProtocolException("设备电量数据无效。");
            Dispatcher.Invoke(() => Model.BatteryText = charging == 1 ? $"{battery}%（充电中）" : $"{battery}%");
    }

    private async Task BeginPttAsync(byte[] payload)
    {
        var reader = new BleBinaryReader(payload); uint requestId = reader.ReadUInt32(); ushort sessionKey = reader.ReadUInt16(); uint firstSequence = reader.ReadUInt32(); reader.RequireEnd();
        if (speechBridge is not null) { await SendActionResultAsync(requestId, 2, "PTT 已在录音"); return; }
        DoubaoCredentials? value = await credentials.LoadAsync(CancellationToken.None);
        if (value is null) { await SendActionResultAsync(requestId, 1, "请先登录豆包"); Dispatcher.Invoke(() => Model.SpeechStatus = "请先登录豆包"); return; }
        try
        {
            speechBridge = new SpeechAudioInputBridge(new DoubaoRecognitionSessionFactory(value), new WindowsTextEmitter());
            await speechBridge.BeginAsync(firstSequence);
            activeSessionKey = sessionKey;
            Dispatcher.Invoke(() => { Model.SpeechStatus = "正在聆听…"; overlay.SetState("正在聆听…", true); });
            await SendActionResultAsync(requestId, 0, "PTT 已就绪");
        }
        catch (Exception error) { speechBridge = null; activeSessionKey = null; await SendActionResultAsync(requestId, 1, "语音服务不可用"); throw new InvalidOperationException("语音启动失败：" + error.Message, error); }
    }

    private async Task AppendAudioAsync(byte[] payload)
    {
        if (speechBridge is null || activeSessionKey is null) return;
        var reader = new BleBinaryReader(payload);
        uint sequence = reader.ReadUInt32(); ulong timestamp = reader.ReadUInt64(); short predictor = unchecked((short)reader.ReadUInt16()); byte stepIndex = reader.ReadByte(); ushort sampleCount = reader.ReadUInt16(); ushort byteCount = reader.ReadUInt16(); byte[] samples = reader.ReadBytes(byteCount); reader.RequireEnd();
        await speechBridge.AppendAsync(new AdpcmFrame(sequence, timestamp, predictor, stepIndex, sampleCount, samples));
    }

    private async Task EndPttAsync(byte[] payload)
    {
        var reader = new BleBinaryReader(payload); uint requestId = reader.ReadUInt32(); ushort sessionKey = reader.ReadUInt16(); _ = reader.ReadUInt32(); reader.RequireEnd();
        if (speechBridge is null || activeSessionKey != sessionKey) { await SendActionResultAsync(requestId, 2, "PTT 未开始"); return; }
        Dispatcher.Invoke(() => { Model.SpeechStatus = "正在识别…"; overlay.SetState("正在识别…", true); });
        try
        {
            await speechBridge.EndAsync(TimeSpan.FromSeconds(12));
            await SendActionResultAsync(requestId, 0, "PTT 已结束");
            Dispatcher.Invoke(() => { Model.SpeechStatus = "等待语音输入"; overlay.SetState("等待语音输入", false); });
        }
        catch (Exception error) { await SendActionResultAsync(requestId, 1, "识别失败"); throw new InvalidOperationException("语音识别失败：" + error.Message, error); }
        finally { speechBridge = null; activeSessionKey = null; }
    }

    private async Task SendActionResultAsync(uint requestId, byte result, string detail)
    {
        byte[] text = Encoding.UTF8.GetBytes(detail); if (text.Length > 192) text = text[..192];
        var payload = new byte[7 + text.Length]; BinaryPrimitives.WriteUInt32LittleEndian(payload, requestId); payload[4] = result; BinaryPrimitives.WriteUInt16LittleEndian(payload.AsSpan(5), (ushort)text.Length); text.CopyTo(payload, 7);
        byte[] envelope = BleEnvelopeCodec.Encode(new(BleEnvelopeCodec.CurrentMajor, BleEnvelopeCodec.CurrentMinor, BleMessageType.ActionResult, 0, outgoingSequence++, payload));
        foreach (byte[] fragment in BleFragmentCodec.Fragment(envelope, outgoingMessageId++, 180)) await bluetooth.SendAsync(BluetoothLogicalChannel.ControlToDevice, fragment);
    }

    public void CloseForExit() { allowClose = true; Close(); }

    protected override void OnClosing(CancelEventArgs e)
    {
        if (!allowClose) { e.Cancel = true; Hide(); }
        base.OnClosing(e);
    }

    protected override void OnClosed(EventArgs e)
    {
        bluetooth.StateChanged -= OnBluetoothStateChanged;
        bluetooth.PacketReceived -= OnBluetoothPacket;
        if (speechBridge is not null) speechBridge.CancelAsync().AsTask().GetAwaiter().GetResult();
        bluetooth.TransportError -= OnBluetoothError;
        bluetooth.DisposeAsync().AsTask().GetAwaiter().GetResult();
        base.OnClosed(e);
    }

    private async void LoginClicked(object sender, RoutedEventArgs e)
    {
        if (Model.LoggedIn)
        {
            await credentials.DeleteAsync(CancellationToken.None);
            Model.LoggedIn = false;
            return;
        }

        var login = new DoubaoLoginWindow(credentials) { Owner = this };
        if (login.ShowDialog() == true) Model.LoggedIn = true;
    }
}
