using System.Buffers.Binary;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using CodexRemote.Core;

namespace CodexRemote.Windows.Speech;

public sealed class DoubaoRecognitionResultState
{
    public string LatestText { get; private set; } = string.Empty;
    public bool DidReceiveServerFinish { get; private set; }
    public int Revision { get; private set; }
    public void ReceiveResult(string text) { if (text.Length == 0) return; LatestText = text; Revision++; }
    public string ReceiveFinish() { DidReceiveServerFinish = true; Revision++; return LatestText; }
}

public sealed class DoubaoRecognitionSessionFactory(DoubaoCredentials credentials) : IRecognitionSessionFactory
{
    public async ValueTask<IRecognitionSession> CreateAsync(CancellationToken cancellationToken)
    {
        credentials.Validate(); return await DoubaoRecognitionSession.ConnectAsync(credentials, cancellationToken);
    }
}

public sealed class DoubaoRecognitionSession : IRecognitionSession
{
    private static readonly TimeSpan FinishTimeout = TimeSpan.FromSeconds(8);
    private static readonly TimeSpan SettleDelay = TimeSpan.FromMilliseconds(900);
    private readonly ClientWebSocket socket;
    private readonly SemaphoreSlim sendLock = new(1, 1);
    private readonly CancellationTokenSource lifetime = new();
    private readonly DoubaoRecognitionResultState state = new();
    private readonly TaskCompletionSource<string> serverFinish = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly Task receiveTask;
    private bool finishing;
    private bool disposed;

    private DoubaoRecognitionSession(ClientWebSocket socket)
    {
        this.socket = socket; receiveTask = ReceiveLoopAsync();
    }

    public static async Task<DoubaoRecognitionSession> ConnectAsync(DoubaoCredentials credentials, CancellationToken cancellationToken)
    {
        var socket = new ClientWebSocket();
        socket.Options.SetRequestHeader("Cookie", credentials.CookieHeader);
        socket.Options.SetRequestHeader("Origin", "https://www.doubao.com");
        await socket.ConnectAsync(BuildEndpoint(credentials), cancellationToken);
        return new(socket);
    }

    public async ValueTask AppendPcmAsync(ReadOnlyMemory<short> samples, CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (finishing || socket.State != WebSocketState.Open) throw new InvalidOperationException("Recognition session is not accepting audio.");
        if (samples.IsEmpty) return;
        var bytes = new byte[samples.Length * sizeof(short)];
        for (int index = 0; index < samples.Length; index++) BinaryPrimitives.WriteInt16LittleEndian(bytes.AsSpan(index * 2), samples.Span[index]);
        await sendLock.WaitAsync(cancellationToken);
        try { await socket.SendAsync(bytes, WebSocketMessageType.Binary, true, cancellationToken); }
        finally { sendLock.Release(); }
    }

    public async Task<string?> CompleteAsync(CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(disposed, this); if (finishing) throw new InvalidOperationException("Recognition session is already finishing."); finishing = true;
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, lifetime.Token); deadline.CancelAfter(FinishTimeout);
        try {
            while (!deadline.IsCancellationRequested) {
                if (serverFinish.Task.IsCompleted) return await serverFinish.Task.WaitAsync(deadline.Token);
                int revision = state.Revision;
                if (state.LatestText.Length != 0) {
                    await Task.Delay(SettleDelay, deadline.Token);
                    if (revision == state.Revision && !serverFinish.Task.IsCompleted) return state.LatestText;
                } else {
                    await Task.WhenAny(serverFinish.Task, Task.Delay(SettleDelay, deadline.Token));
                }
            }
            return string.IsNullOrEmpty(state.LatestText) ? throw new TimeoutException("ASR returned no final text.") : state.LatestText;
        } catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested && !lifetime.IsCancellationRequested) {
            return string.IsNullOrEmpty(state.LatestText) ? throw new TimeoutException("ASR returned no final text.") : state.LatestText;
        }
    }

    public async ValueTask CancelAsync()
    {
        if (disposed) return; lifetime.Cancel();
        if (socket.State is WebSocketState.Open or WebSocketState.CloseReceived) await socket.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, null, CancellationToken.None);
    }

    public async ValueTask DisposeAsync()
    {
        if (disposed) return; await CancelAsync(); disposed = true;
        try { await receiveTask; } catch (OperationCanceledException) { }
        socket.Dispose(); sendLock.Dispose(); lifetime.Dispose();
    }

    private async Task ReceiveLoopAsync()
    {
        var buffer = new byte[16 * 1024];
        try {
            while (!lifetime.IsCancellationRequested && socket.State == WebSocketState.Open) {
                using var message = new MemoryStream(); WebSocketReceiveResult result;
                do { result = await socket.ReceiveAsync(buffer, lifetime.Token); if (result.MessageType == WebSocketMessageType.Close) return; message.Write(buffer, 0, result.Count); } while (!result.EndOfMessage);
                HandleMessage(message.ToArray());
            }
        } catch (Exception error) when (error is OperationCanceledException or WebSocketException) {
            if (!lifetime.IsCancellationRequested) serverFinish.TrySetException(new IOException("ASR WebSocket failed.", error));
        }
    }

    private void HandleMessage(byte[] bytes)
    {
        using JsonDocument document = JsonDocument.Parse(bytes);
        JsonElement root = document.RootElement;
        if (root.TryGetProperty("code", out JsonElement code) && code.TryGetInt32(out int value) && value != 0) { serverFinish.TrySetException(new IOException($"ASR rejected request with code {value}.")); return; }
        if (!root.TryGetProperty("event", out JsonElement eventValue)) return;
        switch (eventValue.GetString()) {
            case "result" when root.TryGetProperty("result", out JsonElement result) && result.TryGetProperty("Text", out JsonElement text): state.ReceiveResult(text.GetString() ?? string.Empty); break;
            case "finish": serverFinish.TrySetResult(state.ReceiveFinish()); break;
        }
    }

    internal static Uri BuildEndpoint(DoubaoCredentials credentials)
    {
        var values = new Dictionary<string, string> { ["version_code"]="20800", ["language"]="zh", ["device_platform"]="web", ["aid"]="497858", ["real_aid"]="497858", ["pkg_type"]="release_version", ["device_id"]=credentials.DeviceId, ["pc_version"]="3.12.3", ["web_id"]=credentials.WebId, ["tea_uuid"]=credentials.WebId, ["region"]="", ["sys_region"]="", ["samantha_web"]="1", ["use-olympus-account"]="1", ["web_tab_id"]=Guid.NewGuid().ToString(), ["format"]="pcm" };
        string query = string.Join('&', values.Select(pair => $"{Uri.EscapeDataString(pair.Key)}={Uri.EscapeDataString(pair.Value)}"));
        return new Uri("wss://ws-samantha.doubao.com/samantha/audio/asr?" + query);
    }
}
