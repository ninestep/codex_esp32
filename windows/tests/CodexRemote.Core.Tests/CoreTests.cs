using CodexRemote.Core.Audio;
using CodexRemote.Core.Configuration;
using CodexRemote.Protocol.Audio;

namespace CodexRemote.Core.Tests;

[TestClass]
public sealed class CoreTests
{
    [TestMethod]
    public async Task BridgePadsSequenceGapsAndEmitsFinalTextOnce()
    {
        var recognition = new FakeRecognition("你好"); var emitter = new FakeEmitter();
        var bridge = new SpeechAudioInputBridge(new FakeFactory(recognition), emitter);
        await bridge.BeginAsync(10);
        await bridge.AppendAsync(new(12, 0, 0, 0, 320, new byte[160]));
        TextEmissionResult result = await bridge.EndAsync(TimeSpan.FromSeconds(1));
        Assert.IsTrue(result.Succeeded); Assert.AreEqual(3, recognition.Frames.Count);
        Assert.AreEqual("你好", emitter.Text); Assert.AreEqual(2, bridge.Diagnostics.MissingFrames);
    }

    [TestMethod]
    public void LayoutReaderRequiresAllElevenLabels()
    {
        string path = Path.GetTempFileName();
        try {
            File.WriteAllText(path, "[desktop.codex-micro-layout]\nslot1=\"1\"\nslot2=\"2\"\nslot3=\"3\"\nslot4=\"4\"\nslot5=\"5\"\nslot6=\"6\"\nencoderMode=\"scroll\"\nup=\"u\"\nright=\"r\"\ndown=\"d\"\nleft=\"l\"\n");
            MicroControlLayout layout = new CodexMicroLayoutReader().Read(path);
            Assert.AreEqual(6, layout.Controls.Count); Assert.AreEqual(4, layout.Directions.Count);
        } finally { File.Delete(path); }
    }

    private sealed class FakeFactory(FakeRecognition session) : IRecognitionSessionFactory { public ValueTask<IRecognitionSession> CreateAsync(CancellationToken cancellationToken) => ValueTask.FromResult<IRecognitionSession>(session); }
    private sealed class FakeRecognition(string text) : IRecognitionSession {
        public List<short[]> Frames { get; } = [];
        public ValueTask AppendPcmAsync(ReadOnlyMemory<short> samples, CancellationToken cancellationToken) { Frames.Add(samples.ToArray()); return ValueTask.CompletedTask; }
        public Task<string?> CompleteAsync(CancellationToken cancellationToken) => Task.FromResult<string?>(text);
        public ValueTask CancelAsync() => ValueTask.CompletedTask; public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
    private sealed class FakeEmitter : ITextEmitter {
        public string? Text { get; private set; } public object CaptureTarget() => new();
        public ValueTask<TextEmissionResult> EmitAsync(object target, string text, CancellationToken cancellationToken) { Text = text; return ValueTask.FromResult(new TextEmissionResult(true)); }
    }
}
