using CodexRemote.Protocol.Audio;
using CodexRemote.Protocol.Ble;
using System.Text.Json;

namespace CodexRemote.Protocol.Tests;

[TestClass]
public sealed class ProtocolTests
{
    [TestMethod]
    public void EnvelopeRoundTripsAndRejectsBadCrc()
    {
        var source = new BleEnvelope(1, 4, BleMessageType.SelectSession, 0, 42, [1, 2, 3]);
        byte[] encoded = BleEnvelopeCodec.Encode(source);
        BleEnvelope decoded = BleEnvelopeCodec.Decode(encoded);
        Assert.AreEqual(source.Major, decoded.Major);
        Assert.AreEqual(source.Minor, decoded.Minor);
        Assert.AreEqual(source.Type, decoded.Type);
        Assert.AreEqual(source.Sequence, decoded.Sequence);
        CollectionAssert.AreEqual(source.Payload, decoded.Payload);
        encoded[14] ^= 1;
        Assert.ThrowsExactly<BleProtocolException>(() => BleEnvelopeCodec.Decode(encoded));
    }

    [TestMethod]
    public void FragmentReassemblyRejectsOutOfOrderAndRecovers()
    {
        byte[] message = Enumerable.Range(0, 30).Select(i => (byte)i).ToArray();
        var packets = BleFragmentCodec.Fragment(message, 7, 16);
        var reassembler = new BleFragmentReassembler();
        Assert.ThrowsExactly<BleProtocolException>(() => reassembler.Accept(packets[1]));
        byte[]? result = null;
        foreach (byte[] packet in packets) result = reassembler.Accept(packet);
        CollectionAssert.AreEqual(message, result);
    }

    [TestMethod]
    public void AdpcmSilenceDecodesToExpectedSampleCount()
    {
        short[] pcm = ImaAdpcmCodec.Decode(new(1, 0, 0, 0, 320, new byte[160]));
        Assert.AreEqual(320, pcm.Length);
        Assert.IsTrue(pcm.All(sample => sample >= 0));
    }

    [TestMethod]
    public void AllBleV1GoldenFixturesMatchEnvelopeAndFragmentContract()
    {
        string root = FindRepositoryRoot(); string fixtures = Path.Combine(root, "macos", "Fixtures", "ble-v1");
        using JsonDocument manifest = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(fixtures, "manifest.json")));
        foreach (JsonElement vector in manifest.RootElement.GetProperty("vectors").EnumerateArray()) {
            string file = vector.GetProperty("file").GetString()!; string kind = vector.GetProperty("kind").GetString()!; string outcome = vector.GetProperty("outcome").GetString()!;
            string[] lines = File.ReadAllLines(Path.Combine(fixtures, file)).Where(line => !string.IsNullOrWhiteSpace(line)).ToArray();
            if (kind == "fragmentSet") {
                var reassembler = new BleFragmentReassembler(); byte[]? message = null;
                foreach (string line in lines) message = reassembler.Accept(Convert.FromHexString(line.Trim()));
                Assert.IsTrue(message is not null); _ = BleEnvelopeCodec.Decode(message);
            } else if (outcome == "valid") {
                _ = BleEnvelopeCodec.Decode(Convert.FromHexString(lines[0].Trim()));
            } else {
                Assert.ThrowsExactly<BleProtocolException>(() => BleEnvelopeCodec.Decode(Convert.FromHexString(lines[0].Trim())));
            }
        }
    }

    private static string FindRepositoryRoot()
    {
        DirectoryInfo? directory = new(AppContext.BaseDirectory);
        while (directory is not null) { if (Directory.Exists(Path.Combine(directory.FullName, "macos", "Fixtures", "ble-v1"))) return directory.FullName; directory = directory.Parent; }
        throw new DirectoryNotFoundException("Repository root was not found.");
    }
}
