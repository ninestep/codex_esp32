import Foundation
import XCTest
@testable import CodexRemoteCore

final class IMAADPCMCodecTests: XCTestCase {
    private let codec = IMAADPCMCodec()

    func testSilenceProducesIndependent160ByteFrame() throws {
        let frame = try codec.encode(samples: Array(repeating: 0, count: 320), sequence: 7, sampleTimestamp: 12_345)

        XCTAssertEqual(frame.sequence, 7)
        XCTAssertEqual(frame.sampleTimestamp, 12_345)
        XCTAssertEqual(frame.predictor, 0)
        XCTAssertEqual(frame.stepIndex, 0)
        XCTAssertEqual(frame.sampleCount, 320)
        XCTAssertEqual(frame.encodedSamples, Data(repeating: 0, count: 160))
        XCTAssertEqual(try codec.decode(frame), Array(repeating: 0, count: 320))
    }

    func testDeterministicSpeechShapeVectorsStayWithinErrorBounds() throws {
        let vectors: [(String, [Int16], Double)] = [
            ("impulse", impulse(), 1_500),
            ("ascending", (0..<320).map { Int16(-16_000 + $0 * 100) }, 1_500),
            ("descending", (0..<320).map { Int16(16_000 - $0 * 100) }, 1_500),
            ("clipped", (0..<320).map { $0.isMultiple(of: 2) ? Int16.min : Int16.max }, 8_000),
        ]

        for (name, samples, maximumError) in vectors {
            let decoded = try codec.decode(codec.encode(samples: samples, sequence: 1, sampleTimestamp: 0))
            XCTAssertLessThanOrEqual(meanAbsoluteError(samples, decoded), maximumError, name)
        }
    }

    func testLaterFrameDecodesWithoutEarlierFrameState() throws {
        let first = try codec.encode(samples: (0..<320).map { Int16($0 * 20) }, sequence: 1, sampleTimestamp: 0)
        let secondSamples = (0..<320).map { Int16(10_000 - $0 * 30) }
        let second = try codec.encode(samples: secondSamples, sequence: 2, sampleTimestamp: 320)

        _ = try codec.decode(first)
        let afterFirst = try codec.decode(second)
        let independently = try IMAADPCMCodec().decode(second)

        XCTAssertEqual(afterFirst, independently)
        XCTAssertLessThan(meanAbsoluteError(secondSamples, independently), 1_500)
    }

    func testRejectsInvalidPCMCountStepIndexAndEncodedLength() throws {
        XCTAssertThrowsError(try codec.encode(samples: Array(repeating: 0, count: 319), sequence: 1, sampleTimestamp: 0)) { error in
            XCTAssertEqual(error as? IMAADPCMError, .invalidSampleCount(319))
        }

        let invalidIndex = ADPCMFrame(
            sequence: 1,
            sampleTimestamp: 0,
            predictor: 0,
            stepIndex: 89,
            sampleCount: 320,
            encodedSamples: Data(repeating: 0, count: 160)
        )
        XCTAssertThrowsError(try codec.decode(invalidIndex)) { error in
            XCTAssertEqual(error as? IMAADPCMError, .invalidStepIndex(89))
        }

        let invalidBytes = ADPCMFrame(
            sequence: 1,
            sampleTimestamp: 0,
            predictor: 0,
            stepIndex: 0,
            sampleCount: 320,
            encodedSamples: Data(repeating: 0, count: 159)
        )
        XCTAssertThrowsError(try codec.decode(invalidBytes)) { error in
            XCTAssertEqual(error as? IMAADPCMError, .invalidEncodedByteCount(159))
        }
    }

    private func impulse() -> [Int16] {
        var samples = Array(repeating: Int16(0), count: 320)
        samples[80] = 20_000
        samples[160] = -20_000
        return samples
    }

    private func meanAbsoluteError(_ expected: [Int16], _ actual: [Int16]) -> Double {
        zip(expected, actual)
            .map { abs(Double($0) - Double($1)) }
            .reduce(0, +) / Double(expected.count)
    }
}
