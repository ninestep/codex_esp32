using CodexRemote.Protocol.Audio;

namespace CodexRemote.Core;

public interface IRecognitionSession : IAsyncDisposable
{
    ValueTask AppendPcmAsync(ReadOnlyMemory<short> samples, CancellationToken cancellationToken);
    Task<string?> CompleteAsync(CancellationToken cancellationToken);
    ValueTask CancelAsync();
}

public interface IRecognitionSessionFactory
{
    ValueTask<IRecognitionSession> CreateAsync(CancellationToken cancellationToken);
}

public interface ITextEmitter
{
    object CaptureTarget();
    ValueTask<TextEmissionResult> EmitAsync(object target, string text, CancellationToken cancellationToken);
}

public readonly record struct TextEmissionResult(bool Succeeded, string? Error = null);
public interface ICredentialStore<T> { ValueTask<T?> LoadAsync(CancellationToken cancellationToken); ValueTask SaveAsync(T value, CancellationToken cancellationToken); ValueTask DeleteAsync(CancellationToken cancellationToken); }
public interface ICodexMicroLayoutReader { MicroControlLayout Read(string path); }
public sealed record MicroControlLayout(IReadOnlyList<string> Controls, string Encoder, IReadOnlyList<string> Directions);
