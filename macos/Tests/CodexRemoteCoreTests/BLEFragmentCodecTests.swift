import Foundation
import XCTest
@testable import CodexRemoteCore

final class BLEFragmentCodecTests: XCTestCase {
    func testFragmentsAtDifferentTransportPayloadCapacities() throws {
        let codec = BLEFragmentCodec()

        XCTAssertEqual(try codec.fragment(Data(repeating: 1, count: 20), messageID: 1, maximumPacketBytes: 20).map(\.count), [20, 16])
        XCTAssertEqual(try codec.fragment(Data(repeating: 2, count: 185), messageID: 2, maximumPacketBytes: 185).map(\.count), [185, 16])
        XCTAssertEqual(try codec.fragment(Data(repeating: 3, count: 512), messageID: 3, maximumPacketBytes: 185).map(\.count), [185, 185, 166])
    }

    func testReassemblesOrderedFragments() throws {
        let source = Data((0..<255).map(UInt8.init) + (0..<45).map(UInt8.init))
        let fragments = try BLEFragmentCodec().fragment(source, messageID: 42, maximumPacketBytes: 64)
        var reassembler = BLEFragmentReassembler()

        for fragment in fragments.dropLast() {
            XCTAssertEqual(try reassembler.accept(fragment), .waiting)
        }
        XCTAssertEqual(try reassembler.accept(fragments.last!), .complete(source))
    }

    func testRejectsDuplicateAndOutOfOrderFragmentsAndClearsPartialState() throws {
        let fragments = try BLEFragmentCodec().fragment(Data(repeating: 9, count: 100), messageID: 7, maximumPacketBytes: 40)
        var reassembler = BLEFragmentReassembler()

        XCTAssertEqual(try reassembler.accept(fragments[0]), .waiting)
        XCTAssertThrowsError(try reassembler.accept(fragments[0])) { error in
            XCTAssertEqual(error as? BLEFragmentError, .unexpectedFragmentIndex(expected: 1, actual: 0))
        }

        XCTAssertThrowsError(try reassembler.accept(fragments[1])) { error in
            XCTAssertEqual(error as? BLEFragmentError, .unexpectedFragmentIndex(expected: 0, actual: 1))
        }

        XCTAssertEqual(try reassembler.accept(fragments[0]), .waiting)
        XCTAssertThrowsError(try reassembler.accept(fragments[2])) { error in
            XCTAssertEqual(error as? BLEFragmentError, .unexpectedFragmentIndex(expected: 1, actual: 2))
        }
    }

    func testRejectsMessageIDAndFragmentCountChanges() throws {
        let first = try BLEFragmentCodec().fragment(Data(repeating: 1, count: 50), messageID: 1, maximumPacketBytes: 32)
        let second = try BLEFragmentCodec().fragment(Data(repeating: 2, count: 80), messageID: 2, maximumPacketBytes: 32)
        var reassembler = BLEFragmentReassembler()

        XCTAssertEqual(try reassembler.accept(first[0]), .waiting)
        XCTAssertThrowsError(try reassembler.accept(second[0])) { error in
            XCTAssertEqual(error as? BLEFragmentError, .unexpectedMessageID(expected: 1, actual: 2))
        }

        XCTAssertEqual(try reassembler.accept(first[0]), .waiting)
        var changedCount = first[1]
        changedCount[6] = 99
        XCTAssertThrowsError(try reassembler.accept(changedCount)) { error in
            XCTAssertEqual(error as? BLEFragmentError, .fragmentCountMismatch(expected: UInt16(first.count), actual: 99))
        }
    }

    func testRejectsInvalidCountsPacketCapacityAndAggregateSize() throws {
        let codec = BLEFragmentCodec()
        XCTAssertThrowsError(try codec.fragment(Data([1]), messageID: 1, maximumPacketBytes: 8)) { error in
            XCTAssertEqual(error as? BLEFragmentError, .packetTooSmall(8))
        }
        XCTAssertThrowsError(try codec.fragment(Data(repeating: 0, count: BLEFragmentCodec.maximumMessageBytes + 1), messageID: 1, maximumPacketBytes: 185)) { error in
            XCTAssertEqual(error as? BLEFragmentError, .messageTooLarge(BLEFragmentCodec.maximumMessageBytes + 1))
        }

        var reassembler = BLEFragmentReassembler()
        XCTAssertThrowsError(try reassembler.accept(fragmentHeader(messageID: 1, index: 0, count: 0))) { error in
            XCTAssertEqual(error as? BLEFragmentError, .invalidFragmentCount(0))
        }
        XCTAssertThrowsError(try reassembler.accept(fragmentHeader(messageID: 1, index: 0, count: 1_025))) { error in
            XCTAssertEqual(error as? BLEFragmentError, .tooManyFragments(1_025))
        }
    }

    func testResetDiscardsIncompleteMessage() throws {
        let fragments = try BLEFragmentCodec().fragment(Data(repeating: 4, count: 40), messageID: 1, maximumPacketBytes: 24)
        var reassembler = BLEFragmentReassembler()

        XCTAssertEqual(try reassembler.accept(fragments[0]), .waiting)
        reassembler.reset()
        XCTAssertThrowsError(try reassembler.accept(fragments[1])) { error in
            XCTAssertEqual(error as? BLEFragmentError, .unexpectedFragmentIndex(expected: 0, actual: 1))
        }
    }

    private func fragmentHeader(messageID: UInt32, index: UInt16, count: UInt16) -> Data {
        Data(messageID.littleEndianBytes + index.littleEndianBytes + count.littleEndianBytes)
    }
}
