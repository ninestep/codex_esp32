import XCTest
@testable import CodexRemoteCore

final class BLEEnvelopeCodecTests: XCTestCase {
    private let codec = BLEEnvelopeCodec()

    func testEncodesExactEmptyPayloadVector() throws {
        let data = try codec.encode(BLEEnvelope(type: .selectSession, sequence: 0, payload: Data()))

        XCTAssertEqual(data.hexString, "4352010401000000000000000000047d0b41")
    }

    func testRoundTripsBinaryPayload() throws {
        let envelope = BLEEnvelope(type: .audioFrame, sequence: 0x7856_3412, payload: Data([0x00, 0x7f, 0x80, 0xff]))

        XCTAssertEqual(try codec.decode(codec.encode(envelope)), envelope)
    }

    func testRejectsCorruptedCRC() throws {
        var data = try codec.encode(BLEEnvelope(type: .deviceInfo, sequence: 7, payload: Data([1, 2, 3])))
        data[data.index(data.startIndex, offsetBy: 14)] ^= 0xff

        XCTAssertThrowsError(try codec.decode(data)) { error in
            XCTAssertEqual(error as? BLECodecError, .crcMismatch)
        }
    }

    func testRejectsIncompatibleVersionUnknownTypeAndFlags() throws {
        let valid = try codec.encode(BLEEnvelope(type: .selectSession, sequence: 1, payload: Data()))

        XCTAssertEqual(try decodeError(replacing: 2, with: 2, in: valid), .incompatibleMajorVersion(2))
        XCTAssertEqual(try decodeError(replacing: 4, with: 0xff, in: valid), .unknownMessageType(0xff))
        XCTAssertEqual(try decodeError(replacing: 5, with: 1, in: valid), .unsupportedFlags(1))
    }

    func testRejectsTruncationPayloadLengthMismatchAndTrailingBytes() throws {
        let valid = try codec.encode(BLEEnvelope(type: .deviceInfo, sequence: 1, payload: Data([1, 2])))

        XCTAssertEqual(caughtError(Data(valid.prefix(10))), .truncated)

        var wrongLength = valid
        wrongLength[10] = 3
        rewriteCRC(&wrongLength)
        XCTAssertEqual(caughtError(wrongLength), .payloadLengthMismatch(expected: 3, actual: 2))

        var trailing = valid
        trailing.append(0)
        XCTAssertEqual(caughtError(trailing), .payloadLengthMismatch(expected: 2, actual: 3))
    }

    func testBinaryStringRejectsMalformedUTF8AndTruncation() throws {
        var malformed = BLEBinaryDecoder(data: Data([0x02, 0x00, 0xc3, 0x28]))
        XCTAssertThrowsError(try malformed.readString(maxBytes: 8)) { error in
            XCTAssertEqual(error as? BLECodecError, .invalidUTF8)
        }

        var truncated = BLEBinaryDecoder(data: Data([0x04, 0x00, 0x61]))
        XCTAssertThrowsError(try truncated.readString(maxBytes: 8)) { error in
            XCTAssertEqual(error as? BLECodecError, .truncated)
        }
    }

    func testEnforcesMaximumEncodedEnvelopeSize() throws {
        let maximumPayload = Data(repeating: 0xaa, count: BLEEnvelopeCodec.maximumFrameBytes - BLEEnvelopeCodec.fixedOverheadBytes)
        XCTAssertEqual(try codec.encode(BLEEnvelope(type: .assetChunk, sequence: 1, payload: maximumPayload)).count, BLEEnvelopeCodec.maximumFrameBytes)

        let oversizedPayload = Data(repeating: 0xaa, count: maximumPayload.count + 1)
        XCTAssertThrowsError(try codec.encode(BLEEnvelope(type: .assetChunk, sequence: 1, payload: oversizedPayload))) { error in
            XCTAssertEqual(error as? BLECodecError, .frameTooLarge(BLEEnvelopeCodec.maximumFrameBytes + 1))
        }
    }

    private func decodeError(replacing offset: Int, with byte: UInt8, in original: Data) throws -> BLECodecError? {
        var data = original
        data[offset] = byte
        rewriteCRC(&data)
        return caughtError(data)
    }

    private func caughtError(_ data: Data) -> BLECodecError? {
        do {
            _ = try codec.decode(data)
            return nil
        } catch {
            return error as? BLECodecError
        }
    }

    private func rewriteCRC(_ data: inout Data) {
        let body = data.dropLast(4)
        let checksum = BLECRC32.checksum(body)
        data.replaceSubrange(data.index(data.endIndex, offsetBy: -4)..<data.endIndex, with: checksum.littleEndianBytes)
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
