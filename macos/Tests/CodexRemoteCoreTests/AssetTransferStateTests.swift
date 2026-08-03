import Foundation
import XCTest
@testable import CodexRemoteCore

final class AssetTransferStateTests: XCTestCase {
    func testActivatesOnlyAfterEveryItemPassesLengthAndCRC() throws {
        let first = Data([0xff, 0xd8, 1, 2, 0xff, 0xd9])
        let second = Data([0xff, 0xd8, 3, 4, 0xff, 0xd9])
        let manifest = makeManifest(setID: 1, assets: [(1, first), (2, second)])
        var state = AssetTransferState()

        try state.begin(manifest)
        XCTAssertEqual(try state.receive(AssetChunk(setID: 1, assetID: 1, offset: 0, bytes: first)), UInt32(first.count))
        XCTAssertNil(state.activeSet)
        XCTAssertThrowsError(try state.finalize()) { error in
            XCTAssertEqual(error as? AssetTransferError, .incompleteAsset(assetID: 2, expected: second.count, actual: 0))
        }

        _ = try state.receive(AssetChunk(setID: 1, assetID: 2, offset: 0, bytes: second))
        let active = try state.finalize()
        XCTAssertEqual(active.setID, 1)
        XCTAssertEqual(active.assets, [1: first, 2: second])
        XCTAssertEqual(state.activeSet, active)
    }

    func testInterruptedReplacementPreservesPreviousActiveSet() throws {
        let oldBytes = Data([0xff, 0xd8, 1, 0xff, 0xd9])
        let newBytes = Data([0xff, 0xd8, 2, 0xff, 0xd9])
        var state = AssetTransferState()

        try state.begin(makeManifest(setID: 1, assets: [(1, oldBytes)]))
        _ = try state.receive(AssetChunk(setID: 1, assetID: 1, offset: 0, bytes: oldBytes))
        let oldActive = try state.finalize()

        try state.begin(makeManifest(setID: 2, assets: [(1, newBytes)]))
        _ = try state.receive(AssetChunk(setID: 2, assetID: 1, offset: 0, bytes: Data(newBytes.prefix(2))))
        state.cancelPending()

        XCTAssertEqual(state.activeSet, oldActive)
    }

    func testDuplicateChunkIsIdempotentButConflictingDuplicateAndGapsFail() throws {
        let bytes = Data([0xff, 0xd8, 1, 2, 0xff, 0xd9])
        var state = AssetTransferState()
        try state.begin(makeManifest(setID: 4, assets: [(1, bytes)]))
        let first = AssetChunk(setID: 4, assetID: 1, offset: 0, bytes: Data(bytes.prefix(3)))

        XCTAssertEqual(try state.receive(first), 3)
        XCTAssertEqual(try state.receive(first), 3)
        XCTAssertThrowsError(try state.receive(AssetChunk(setID: 4, assetID: 1, offset: 0, bytes: Data([9, 9, 9])))) { error in
            XCTAssertEqual(error as? AssetTransferError, .conflictingDuplicate(assetID: 1, offset: 0))
        }
        XCTAssertThrowsError(try state.receive(AssetChunk(setID: 4, assetID: 1, offset: 4, bytes: Data([1])))) { error in
            XCTAssertEqual(error as? AssetTransferError, .offsetMismatch(assetID: 1, expected: 3, actual: 4))
        }
    }

    func testRejectsWrongSetUnknownAssetOverflowAndCRCFailure() throws {
        let bytes = Data([0xff, 0xd8, 1, 0xff, 0xd9])
        var state = AssetTransferState()
        try state.begin(makeManifest(setID: 5, assets: [(1, bytes)]))

        XCTAssertThrowsError(try state.receive(AssetChunk(setID: 6, assetID: 1, offset: 0, bytes: bytes))) { error in
            XCTAssertEqual(error as? AssetTransferError, .setMismatch(expected: 5, actual: 6))
        }
        XCTAssertThrowsError(try state.receive(AssetChunk(setID: 5, assetID: 2, offset: 0, bytes: bytes))) { error in
            XCTAssertEqual(error as? AssetTransferError, .unknownAsset(2))
        }
        XCTAssertThrowsError(try state.receive(AssetChunk(setID: 5, assetID: 1, offset: 0, bytes: bytes + Data([0])))) { error in
            XCTAssertEqual(error as? AssetTransferError, .assetOverflow(assetID: 1, maximum: bytes.count, attempted: bytes.count + 1))
        }

        let wrongCRC = AssetManifest(
            setID: 7,
            totalBytes: UInt32(bytes.count),
            items: [AssetItemDescriptor(assetID: 1, width: 480, height: 480, byteCount: UInt32(bytes.count), crc32: 0)]
        )
        try state.begin(wrongCRC)
        _ = try state.receive(AssetChunk(setID: 7, assetID: 1, offset: 0, bytes: bytes))
        XCTAssertThrowsError(try state.finalize()) { error in
            XCTAssertEqual(error as? AssetTransferError, .crcMismatch(assetID: 1))
        }
    }

    func testRejectsManifestLimitsAndInvalidJPEGMetadata() throws {
        let item = AssetItemDescriptor(assetID: 1, width: 480, height: 480, byteCount: 1, crc32: 0)
        var state = AssetTransferState()

        XCTAssertThrowsError(try state.begin(AssetManifest(setID: 1, totalBytes: 9, items: Array(repeating: item, count: 9)))) { error in
            XCTAssertEqual(error as? AssetTransferError, .tooManyAssets(9))
        }
        let oversized = AssetItemDescriptor(assetID: 1, width: 480, height: 480, byteCount: UInt32(AssetTransferState.maximumSetBytes + 1), crc32: 0)
        XCTAssertThrowsError(try state.begin(AssetManifest(setID: 1, totalBytes: oversized.byteCount, items: [oversized]))) { error in
            XCTAssertEqual(error as? AssetTransferError, .setTooLarge(AssetTransferState.maximumSetBytes + 1))
        }
        let invalidSize = AssetItemDescriptor(assetID: 1, width: 0, height: 480, byteCount: 1, crc32: 0)
        XCTAssertThrowsError(try state.begin(AssetManifest(setID: 1, totalBytes: 1, items: [invalidSize]))) { error in
            XCTAssertEqual(error as? AssetTransferError, .invalidJPEGMetadata(assetID: 1))
        }
    }

    private func makeManifest(setID: UInt32, assets: [(UInt16, Data)]) -> AssetManifest {
        AssetManifest(
            setID: setID,
            totalBytes: UInt32(assets.reduce(0) { $0 + $1.1.count }),
            items: assets.map { id, bytes in
                AssetItemDescriptor(
                    assetID: id,
                    width: 480,
                    height: 480,
                    byteCount: UInt32(bytes.count),
                    crc32: BLECRC32.checksum(bytes)
                )
            }
        )
    }
}
