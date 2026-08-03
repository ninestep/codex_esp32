import Foundation

public enum IMAADPCMError: Error, Equatable, Sendable {
    case invalidSampleCount(Int)
    case invalidEncodedByteCount(Int)
    case invalidStepIndex(UInt8)
}

public struct IMAADPCMCodec: Sendable {
    public static let samplesPerFrame = 320
    public static let encodedBytesPerFrame = 160

    private static let indexAdjustments = [
        -1, -1, -1, -1, 2, 4, 6, 8,
        -1, -1, -1, -1, 2, 4, 6, 8,
    ]

    private static let steps = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31,
        34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143,
        157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544,
        598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707,
        1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871,
        5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
        15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
    ]

    public init() {}

    public func encode(
        samples: [Int16],
        sequence: UInt32,
        sampleTimestamp: UInt64
    ) throws -> ADPCMFrame {
        guard samples.count == Self.samplesPerFrame else {
            throw IMAADPCMError.invalidSampleCount(samples.count)
        }

        let initialPredictor = samples[0]
        let initialStepIndex = 0
        var predictor = Int(initialPredictor)
        var stepIndex = initialStepIndex
        var encoded = Data(capacity: Self.encodedBytesPerFrame)

        for pairStart in stride(from: 0, to: samples.count, by: 2) {
            let low = encodeNibble(sample: Int(samples[pairStart]), predictor: &predictor, stepIndex: &stepIndex)
            let high = encodeNibble(sample: Int(samples[pairStart + 1]), predictor: &predictor, stepIndex: &stepIndex)
            encoded.append(low | (high << 4))
        }

        return ADPCMFrame(
            sequence: sequence,
            sampleTimestamp: sampleTimestamp,
            predictor: initialPredictor,
            stepIndex: UInt8(initialStepIndex),
            sampleCount: UInt16(Self.samplesPerFrame),
            encodedSamples: encoded
        )
    }

    public func decode(_ frame: ADPCMFrame) throws -> [Int16] {
        guard frame.sampleCount == Self.samplesPerFrame else {
            throw IMAADPCMError.invalidSampleCount(Int(frame.sampleCount))
        }
        guard frame.encodedSamples.count == Self.encodedBytesPerFrame else {
            throw IMAADPCMError.invalidEncodedByteCount(frame.encodedSamples.count)
        }
        guard frame.stepIndex <= 88 else {
            throw IMAADPCMError.invalidStepIndex(frame.stepIndex)
        }

        var predictor = Int(frame.predictor)
        var stepIndex = Int(frame.stepIndex)
        var samples: [Int16] = []
        samples.reserveCapacity(Self.samplesPerFrame)

        for byte in frame.encodedSamples {
            samples.append(decodeNibble(byte & 0x0f, predictor: &predictor, stepIndex: &stepIndex))
            samples.append(decodeNibble(byte >> 4, predictor: &predictor, stepIndex: &stepIndex))
        }
        return samples
    }

    private func encodeNibble(sample: Int, predictor: inout Int, stepIndex: inout Int) -> UInt8 {
        let step = Self.steps[stepIndex]
        var difference = sample - predictor
        var nibble = 0
        if difference < 0 {
            nibble = 8
            difference = -difference
        }

        var reconstructedDifference = step >> 3
        if difference >= step {
            nibble |= 4
            difference -= step
            reconstructedDifference += step
        }
        if difference >= step >> 1 {
            nibble |= 2
            difference -= step >> 1
            reconstructedDifference += step >> 1
        }
        if difference >= step >> 2 {
            nibble |= 1
            reconstructedDifference += step >> 2
        }

        predictor += (nibble & 8) == 0 ? reconstructedDifference : -reconstructedDifference
        predictor = min(Int(Int16.max), max(Int(Int16.min), predictor))
        stepIndex = min(88, max(0, stepIndex + Self.indexAdjustments[nibble]))
        return UInt8(nibble)
    }

    private func decodeNibble(_ nibble: UInt8, predictor: inout Int, stepIndex: inout Int) -> Int16 {
        let step = Self.steps[stepIndex]
        var difference = step >> 3
        if nibble & 4 != 0 { difference += step }
        if nibble & 2 != 0 { difference += step >> 1 }
        if nibble & 1 != 0 { difference += step >> 2 }

        predictor += nibble & 8 == 0 ? difference : -difference
        predictor = min(Int(Int16.max), max(Int(Int16.min), predictor))
        stepIndex = min(88, max(0, stepIndex + Self.indexAdjustments[Int(nibble)]))
        return Int16(predictor)
    }
}
