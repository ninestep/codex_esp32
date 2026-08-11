using System.Buffers.Binary;
using System.Text;

namespace CodexRemote.Protocol.Ble;

public sealed class BleProtocolException(string message) : Exception(message);

public enum BleMessageType : byte
{
    SelectSession = 0x01, Scroll = 0x02, TerminalKey = 0x03,
    PttBegin = 0x04, PttEnd = 0x05, ActionResult = 0x06,
    StateSnapshot = 0x07, StateDelta = 0x08, AudioFrame = 0x09,
    AssetManifest = 0x0a, AssetChunk = 0x0b, AssetAcknowledgement = 0x0c,
    DeviceInfo = 0x0d, ResyncRequired = 0x0e, TerminalShortcut = 0x0f,
    MicroControlLayout = 0x10,
}

public readonly record struct BleEnvelope(byte Major, byte Minor, BleMessageType Type, byte Flags, uint Sequence, byte[] Payload);

public static class BleEnvelopeCodec
{
    public const byte CurrentMajor = 1;
    public const byte CurrentMinor = 4;
    public const int FixedOverheadBytes = 18;
    public const int MaximumFrameBytes = 256 * 1024;

    public static byte[] Encode(BleEnvelope value)
    {
        if (value.Flags != 0) throw new BleProtocolException("Unsupported flags.");
        int length = checked(FixedOverheadBytes + value.Payload.Length);
        if (length > MaximumFrameBytes) throw new BleProtocolException("Frame too large.");
        var data = new byte[length];
        data[0] = 0x43; data[1] = 0x52; data[2] = value.Major; data[3] = value.Minor;
        data[4] = (byte)value.Type; data[5] = value.Flags;
        BinaryPrimitives.WriteUInt32LittleEndian(data.AsSpan(6), value.Sequence);
        BinaryPrimitives.WriteUInt32LittleEndian(data.AsSpan(10), (uint)value.Payload.Length);
        value.Payload.CopyTo(data, 14);
        BinaryPrimitives.WriteUInt32LittleEndian(data.AsSpan(length - 4), Crc32(data.AsSpan(0, length - 4)));
        return data;
    }

    public static BleEnvelope Decode(ReadOnlySpan<byte> data)
    {
        if (data.Length < FixedOverheadBytes) throw new BleProtocolException("Truncated envelope.");
        if (data.Length > MaximumFrameBytes) throw new BleProtocolException("Frame too large.");
        if (data[0] != 0x43 || data[1] != 0x52) throw new BleProtocolException("Invalid magic.");
        if (data[2] != CurrentMajor) throw new BleProtocolException("Incompatible major version.");
        if (!Enum.IsDefined(typeof(BleMessageType), data[4])) throw new BleProtocolException("Unknown message type.");
        if (data[5] != 0) throw new BleProtocolException("Unsupported flags.");
        int payloadLength = checked((int)BinaryPrimitives.ReadUInt32LittleEndian(data[10..14]));
        if (payloadLength != data.Length - FixedOverheadBytes) throw new BleProtocolException("Payload length mismatch.");
        uint expected = BinaryPrimitives.ReadUInt32LittleEndian(data[^4..]);
        if (Crc32(data[..^4]) != expected) throw new BleProtocolException("CRC mismatch.");
        return new(data[2], data[3], (BleMessageType)data[4], data[5],
            BinaryPrimitives.ReadUInt32LittleEndian(data[6..10]), data[14..^4].ToArray());
    }

    private static uint Crc32(ReadOnlySpan<byte> bytes)
    {
        uint crc = uint.MaxValue;
        foreach (byte value in bytes) {
            crc ^= value;
            for (int bit = 0; bit < 8; bit++) crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320u : crc >> 1;
        }
        return crc ^ uint.MaxValue;
    }
}

public static class BleFragmentCodec
{
    public const int HeaderBytes = 8;
    public const int MaximumMessageBytes = 256 * 1024;
    public const int MaximumFragments = 1024;

    public static IReadOnlyList<byte[]> Fragment(ReadOnlySpan<byte> message, uint messageId, int maximumPacketBytes)
    {
        if (maximumPacketBytes <= HeaderBytes) throw new BleProtocolException("Packet too small.");
        if (message.Length > MaximumMessageBytes) throw new BleProtocolException("Message too large.");
        int capacity = maximumPacketBytes - HeaderBytes;
        int count = Math.Max(1, (message.Length + capacity - 1) / capacity);
        if (count > MaximumFragments) throw new BleProtocolException("Too many fragments.");
        var result = new List<byte[]>(count);
        for (int index = 0; index < count; index++) {
            int offset = index * capacity, size = Math.Min(capacity, message.Length - offset);
            var packet = new byte[HeaderBytes + Math.Max(0, size)];
            BinaryPrimitives.WriteUInt32LittleEndian(packet, messageId);
            BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(4), (ushort)index);
            BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(6), (ushort)count);
            if (size > 0) message.Slice(offset, size).CopyTo(packet.AsSpan(HeaderBytes));
            result.Add(packet);
        }
        return result;
    }
}

public sealed class BleFragmentReassembler
{
    private uint? messageId;
    private ushort? fragmentCount;
    private ushort nextIndex;
    private readonly MemoryStream bytes = new();

    public byte[]? Accept(ReadOnlySpan<byte> packet)
    {
        try {
            if (packet.Length < BleFragmentCodec.HeaderBytes) throw new BleProtocolException("Malformed fragment.");
            uint incomingId = BinaryPrimitives.ReadUInt32LittleEndian(packet);
            ushort incomingIndex = BinaryPrimitives.ReadUInt16LittleEndian(packet[4..]);
            ushort incomingCount = BinaryPrimitives.ReadUInt16LittleEndian(packet[6..]);
            if (incomingCount is 0 or > BleFragmentCodec.MaximumFragments || incomingIndex >= incomingCount)
                throw new BleProtocolException("Invalid fragment header.");
            if (messageId is not null && messageId != incomingId) throw new BleProtocolException("Unexpected message ID.");
            if (fragmentCount is not null && fragmentCount != incomingCount) throw new BleProtocolException("Fragment count mismatch.");
            if (incomingIndex != nextIndex) throw new BleProtocolException("Unexpected fragment index.");
            messageId ??= incomingId; fragmentCount ??= incomingCount;
            if (bytes.Length + packet.Length - BleFragmentCodec.HeaderBytes > BleFragmentCodec.MaximumMessageBytes)
                throw new BleProtocolException("Message too large.");
            bytes.Write(packet[BleFragmentCodec.HeaderBytes..]); nextIndex++;
            if (nextIndex != incomingCount) return null;
            byte[] complete = bytes.ToArray(); Reset(); return complete;
        } catch { Reset(); throw; }
    }

    public void Reset() { messageId = null; fragmentCount = null; nextIndex = 0; bytes.SetLength(0); }
}

public ref struct BleBinaryReader(ReadOnlySpan<byte> data)
{
    private ReadOnlySpan<byte> remaining = data;
    public int Remaining => remaining.Length;
    public byte ReadByte() { Require(1); byte value = remaining[0]; remaining = remaining[1..]; return value; }
    public ushort ReadUInt16() { Require(2); ushort value = BinaryPrimitives.ReadUInt16LittleEndian(remaining); remaining = remaining[2..]; return value; }
    public uint ReadUInt32() { Require(4); uint value = BinaryPrimitives.ReadUInt32LittleEndian(remaining); remaining = remaining[4..]; return value; }
    public ulong ReadUInt64() { Require(8); ulong value = BinaryPrimitives.ReadUInt64LittleEndian(remaining); remaining = remaining[8..]; return value; }
    public byte[] ReadBytes(int count) { Require(count); byte[] value = remaining[..count].ToArray(); remaining = remaining[count..]; return value; }
    public string ReadString(int maximum) { int length = ReadUInt16(); if (length > maximum) throw new BleProtocolException("String too long."); return new UTF8Encoding(false, true).GetString(ReadBytes(length)); }
    public void RequireEnd() { if (!remaining.IsEmpty) throw new BleProtocolException("Trailing bytes."); }
    private readonly void Require(int count) { if (count < 0 || remaining.Length < count) throw new BleProtocolException("Truncated payload."); }
}
