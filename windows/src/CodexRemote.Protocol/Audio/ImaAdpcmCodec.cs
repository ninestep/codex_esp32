namespace CodexRemote.Protocol.Audio;

public readonly record struct AdpcmFrame(uint Sequence, ulong SampleTimestamp, short Predictor, byte StepIndex, ushort SampleCount, byte[] EncodedSamples);

public static class ImaAdpcmCodec
{
    public const int SamplesPerFrame = 320;
    public const int EncodedBytesPerFrame = 160;
    private static readonly int[] IndexAdjustments = [-1,-1,-1,-1,2,4,6,8,-1,-1,-1,-1,2,4,6,8];
    private static readonly int[] Steps = [7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,73,80,88,97,107,118,130,143,157,173,190,209,230,253,279,307,337,371,408,449,494,544,598,658,724,796,876,963,1060,1166,1282,1411,1552,1707,1878,2066,2272,2499,2749,3024,3327,3660,4026,4428,4871,5358,5894,6484,7132,7845,8630,9493,10442,11487,12635,13899,15289,16818,18500,20350,22385,24623,27086,29794,32767];

    public static short[] Decode(AdpcmFrame frame)
    {
        if (frame.SampleCount != SamplesPerFrame) throw new ArgumentException("Invalid sample count.");
        if (frame.EncodedSamples.Length != EncodedBytesPerFrame) throw new ArgumentException("Invalid encoded byte count.");
        if (frame.StepIndex > 88) throw new ArgumentException("Invalid step index.");
        int predictor = frame.Predictor, stepIndex = frame.StepIndex, outputIndex = 0;
        var output = new short[SamplesPerFrame];
        foreach (byte value in frame.EncodedSamples) {
            output[outputIndex++] = DecodeNibble(value & 0x0f, ref predictor, ref stepIndex);
            output[outputIndex++] = DecodeNibble(value >> 4, ref predictor, ref stepIndex);
        }
        return output;
    }

    private static short DecodeNibble(int nibble, ref int predictor, ref int stepIndex)
    {
        int step = Steps[stepIndex], difference = step >> 3;
        if ((nibble & 4) != 0) difference += step;
        if ((nibble & 2) != 0) difference += step >> 1;
        if ((nibble & 1) != 0) difference += step >> 2;
        predictor = Math.Clamp(predictor + ((nibble & 8) == 0 ? difference : -difference), short.MinValue, short.MaxValue);
        stepIndex = Math.Clamp(stepIndex + IndexAdjustments[nibble], 0, 88);
        return (short)predictor;
    }
}
