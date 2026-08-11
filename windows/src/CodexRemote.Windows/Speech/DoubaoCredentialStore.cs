using System.Runtime.InteropServices;
using System.Text.Json;
using CodexRemote.Core;

namespace CodexRemote.Windows.Speech;

public sealed class DoubaoCredentialStore(string path) : ICredentialStore<DoubaoCredentials>
{
    private static readonly byte[] Entropy = "CodexRemote.Windows.Doubao.v1"u8.ToArray();

    public async ValueTask<DoubaoCredentials?> LoadAsync(CancellationToken cancellationToken)
    {
        if (!File.Exists(path)) return null;
        byte[] encrypted = await File.ReadAllBytesAsync(path, cancellationToken);
        byte[] plaintext = Dpapi.Unprotect(encrypted, Entropy);
        try {
            DoubaoCredentials value = JsonSerializer.Deserialize<DoubaoCredentials>(plaintext) ?? throw new InvalidDataException("Credential payload is empty.");
            value.Validate(); return value;
        } finally { System.Security.Cryptography.CryptographicOperations.ZeroMemory(plaintext); }
    }

    public async ValueTask SaveAsync(DoubaoCredentials value, CancellationToken cancellationToken)
    {
        value.Validate(); byte[] plaintext = JsonSerializer.SerializeToUtf8Bytes(value);
        try {
            byte[] encrypted = Dpapi.Protect(plaintext, Entropy);
            string? directory = Path.GetDirectoryName(path); if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
            string temporary = path + ".tmp";
            await File.WriteAllBytesAsync(temporary, encrypted, cancellationToken);
            File.Move(temporary, path, overwrite: true);
        } finally { System.Security.Cryptography.CryptographicOperations.ZeroMemory(plaintext); }
    }

    public ValueTask DeleteAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested(); if (File.Exists(path)) File.Delete(path); return ValueTask.CompletedTask;
    }

    private static class Dpapi
    {
        private const uint CryptProtectUiForbidden = 0x1;
        [StructLayout(LayoutKind.Sequential)] private struct Blob { internal int Length; internal nint Data; }

        internal static byte[] Protect(byte[] input, byte[] entropy) => Transform(input, entropy, protect: true);
        internal static byte[] Unprotect(byte[] input, byte[] entropy) => Transform(input, entropy, protect: false);

        private static byte[] Transform(byte[] input, byte[] entropy, bool protect)
        {
            Blob inputBlob = Allocate(input), entropyBlob = Allocate(entropy), outputBlob = default;
            try {
                bool success = protect
                    ? CryptProtectData(ref inputBlob, null, ref entropyBlob, 0, 0, CryptProtectUiForbidden, out outputBlob)
                    : CryptUnprotectData(ref inputBlob, 0, ref entropyBlob, 0, 0, CryptProtectUiForbidden, out outputBlob);
                if (!success) throw new System.ComponentModel.Win32Exception(Marshal.GetLastPInvokeError());
                var output = new byte[outputBlob.Length]; Marshal.Copy(outputBlob.Data, output, 0, output.Length); return output;
            } finally {
                if (inputBlob.Data != 0) { ZeroAndFree(inputBlob); }
                if (entropyBlob.Data != 0) { ZeroAndFree(entropyBlob); }
                if (outputBlob.Data != 0) LocalFree(outputBlob.Data);
            }
        }

        private static Blob Allocate(byte[] value) { nint data = Marshal.AllocHGlobal(value.Length); Marshal.Copy(value, 0, data, value.Length); return new() { Length = value.Length, Data = data }; }
        private static void ZeroAndFree(Blob blob) { for (int index = 0; index < blob.Length; index++) Marshal.WriteByte(blob.Data, index, 0); Marshal.FreeHGlobal(blob.Data); }
        [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CryptProtectData(ref Blob input, string? description, ref Blob entropy, nint reserved, nint prompt, uint flags, out Blob output);
        [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CryptUnprotectData(ref Blob input, nint description, ref Blob entropy, nint reserved, nint prompt, uint flags, out Blob output);
        [DllImport("kernel32.dll")] private static extern nint LocalFree(nint memory);
    }
}
