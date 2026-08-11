using CodexRemote.Windows.Speech;

namespace CodexRemote.Windows.Tests;

[TestClass]
public sealed class DoubaoCredentialsTests
{
    [TestMethod]
    public void DiagnosticStringRedactsEveryIdentifier()
    {
        var value = new DoubaoCredentials("session=secret", "device-secret", "web-secret");
        string text = value.ToString();
        Assert.IsTrue(!text.Contains("session=secret", StringComparison.Ordinal));
        Assert.IsTrue(!text.Contains("device-secret", StringComparison.Ordinal));
        Assert.IsTrue(!text.Contains("web-secret", StringComparison.Ordinal));
    }

    [TestMethod]
    public async Task DpapiStoreRoundTripsAndDeletesForCurrentUser()
    {
        string directory = Path.Combine(Path.GetTempPath(), "codex-remote-tests", Guid.NewGuid().ToString("N"));
        string path = Path.Combine(directory, "credentials.bin"); var store = new DoubaoCredentialStore(path);
        var expected = new DoubaoCredentials("session=secret", "device", "web");
        try {
            await store.SaveAsync(expected, CancellationToken.None);
            byte[] disk = await File.ReadAllBytesAsync(path);
            Assert.IsTrue(!System.Text.Encoding.UTF8.GetString(disk).Contains("secret", StringComparison.Ordinal));
            Assert.AreEqual(expected, await store.LoadAsync(CancellationToken.None));
            await store.DeleteAsync(CancellationToken.None); Assert.IsTrue(!File.Exists(path));
        } finally { if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true); }
    }
}
