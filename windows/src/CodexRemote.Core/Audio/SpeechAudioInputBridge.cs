using CodexRemote.Protocol.Audio;

namespace CodexRemote.Core.Audio;

public enum SpeechBridgeState { Idle, Recording, Processing, Failed }
public sealed record AudioDiagnostics(long ReceivedFrames, long DuplicateFrames, long MissingFrames, long InvalidFrames);

public sealed class SpeechAudioInputBridge(IRecognitionSessionFactory sessions, ITextEmitter emitter)
{
    private IRecognitionSession? session;
    private object? target;
    private uint? nextSequence;
    private long received, duplicates, missing, invalid;
    public SpeechBridgeState State { get; private set; }
    public string? RetainedText { get; private set; }
    public AudioDiagnostics Diagnostics => new(received, duplicates, missing, invalid);
    public event Action<double>? LevelChanged;

    public async ValueTask BeginAsync(uint firstSequence, CancellationToken cancellationToken = default)
    {
        if (State != SpeechBridgeState.Idle) throw new InvalidOperationException("PTT session is already active.");
        target = emitter.CaptureTarget();
        session = await sessions.CreateAsync(cancellationToken);
        nextSequence = firstSequence;
        RetainedText = null;
        State = SpeechBridgeState.Recording;
    }

    public async ValueTask AppendAsync(AdpcmFrame frame, CancellationToken cancellationToken = default)
    {
        if (State != SpeechBridgeState.Recording || session is null || nextSequence is null) throw new InvalidOperationException("PTT is not recording.");
        if (frame.Sequence < nextSequence) { duplicates++; return; }
        try {
            while (nextSequence < frame.Sequence) {
                await session.AppendPcmAsync(new short[ImaAdpcmCodec.SamplesPerFrame], cancellationToken);
                nextSequence++; missing++;
            }
            short[] pcm = ImaAdpcmCodec.Decode(frame);
            await session.AppendPcmAsync(pcm, cancellationToken);
            LevelChanged?.Invoke(WaveformLevelReducer.Reduce(pcm));
            nextSequence++; received++;
        } catch { invalid++; State = SpeechBridgeState.Failed; throw; }
    }

    public async Task<TextEmissionResult> EndAsync(TimeSpan timeout, CancellationToken cancellationToken = default)
    {
        if (State != SpeechBridgeState.Recording || session is null || target is null) throw new InvalidOperationException("PTT is not recording.");
        State = SpeechBridgeState.Processing;
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(timeout);
        try {
            string? text = await session.CompleteAsync(deadline.Token);
            if (string.IsNullOrWhiteSpace(text)) return new(true);
            RetainedText = text;
            TextEmissionResult result = await emitter.EmitAsync(target, text, deadline.Token);
            if (!result.Succeeded) State = SpeechBridgeState.Failed;
            return result;
        } catch { State = SpeechBridgeState.Failed; throw; }
        finally { await session.DisposeAsync(); session = null; target = null; nextSequence = null; if (State != SpeechBridgeState.Failed) State = SpeechBridgeState.Idle; }
    }

    public async ValueTask CancelAsync()
    {
        if (session is not null) { await session.CancelAsync(); await session.DisposeAsync(); }
        session = null; target = null; nextSequence = null; State = SpeechBridgeState.Idle;
    }
}

public static class WaveformLevelReducer
{
    public static double Reduce(ReadOnlySpan<short> samples)
    {
        if (samples.IsEmpty) return 0;
        double sum = 0;
        foreach (short sample in samples) { double normalized = sample / 32768d; sum += normalized * normalized; }
        return Math.Clamp(Math.Sqrt(sum / samples.Length), 0, 1);
    }
}
