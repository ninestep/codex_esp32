import Foundation

public struct ActiveAssetSet: Equatable, Sendable {
    public let setID: UInt32
    public let assets: [UInt16: Data]

    public init(setID: UInt32, assets: [UInt16: Data]) {
        self.setID = setID
        self.assets = assets
    }
}

public enum AssetTransferError: Error, Equatable, Sendable {
    case noPendingSet
    case tooManyAssets(Int)
    case setTooLarge(Int)
    case duplicateAssetID(UInt16)
    case invalidManifestTotal(expected: Int, actual: Int)
    case invalidJPEGMetadata(assetID: UInt16)
    case setMismatch(expected: UInt32, actual: UInt32)
    case unknownAsset(UInt16)
    case offsetMismatch(assetID: UInt16, expected: Int, actual: Int)
    case conflictingDuplicate(assetID: UInt16, offset: Int)
    case assetOverflow(assetID: UInt16, maximum: Int, attempted: Int)
    case incompleteAsset(assetID: UInt16, expected: Int, actual: Int)
    case crcMismatch(assetID: UInt16)
}

public struct AssetTransferState: Sendable {
    public static let maximumAssets = 8
    public static let maximumSetBytes = 4 * 1024 * 1024
    public static let maximumDimension = 480

    public private(set) var activeSet: ActiveAssetSet?
    private var pending: PendingSet?

    public init(activeSet: ActiveAssetSet? = nil) {
        self.activeSet = activeSet
    }

    public mutating func begin(_ manifest: AssetManifest) throws {
        guard !manifest.items.isEmpty, manifest.items.count <= Self.maximumAssets else {
            throw AssetTransferError.tooManyAssets(manifest.items.count)
        }
        guard Int(manifest.totalBytes) <= Self.maximumSetBytes else {
            throw AssetTransferError.setTooLarge(Int(manifest.totalBytes))
        }

        var ids = Set<UInt16>()
        var describedTotal = 0
        for item in manifest.items {
            guard ids.insert(item.assetID).inserted else {
                throw AssetTransferError.duplicateAssetID(item.assetID)
            }
            guard item.width > 0,
                  item.height > 0,
                  item.width <= Self.maximumDimension,
                  item.height <= Self.maximumDimension,
                  item.byteCount > 0
            else {
                throw AssetTransferError.invalidJPEGMetadata(assetID: item.assetID)
            }
            describedTotal += Int(item.byteCount)
        }
        guard describedTotal == Int(manifest.totalBytes) else {
            throw AssetTransferError.invalidManifestTotal(expected: Int(manifest.totalBytes), actual: describedTotal)
        }

        pending = PendingSet(
            manifest: manifest,
            buffers: Dictionary(uniqueKeysWithValues: manifest.items.map { ($0.assetID, Data()) })
        )
    }

    public mutating func receive(_ chunk: AssetChunk) throws -> UInt32 {
        guard var pending else {
            throw AssetTransferError.noPendingSet
        }
        guard chunk.setID == pending.manifest.setID else {
            throw AssetTransferError.setMismatch(expected: pending.manifest.setID, actual: chunk.setID)
        }
        guard let descriptor = pending.manifest.items.first(where: { $0.assetID == chunk.assetID }),
              var buffer = pending.buffers[chunk.assetID]
        else {
            throw AssetTransferError.unknownAsset(chunk.assetID)
        }

        let offset = Int(chunk.offset)
        if offset < buffer.count {
            let end = offset + chunk.bytes.count
            guard end <= buffer.count else {
                throw AssetTransferError.offsetMismatch(assetID: chunk.assetID, expected: buffer.count, actual: offset)
            }
            let startIndex = buffer.index(buffer.startIndex, offsetBy: offset)
            let endIndex = buffer.index(startIndex, offsetBy: chunk.bytes.count)
            guard Data(buffer[startIndex..<endIndex]) == chunk.bytes else {
                throw AssetTransferError.conflictingDuplicate(assetID: chunk.assetID, offset: offset)
            }
            return UInt32(buffer.count)
        }
        guard offset == buffer.count else {
            throw AssetTransferError.offsetMismatch(assetID: chunk.assetID, expected: buffer.count, actual: offset)
        }

        let attempted = buffer.count + chunk.bytes.count
        let maximum = Int(descriptor.byteCount)
        guard attempted <= maximum else {
            throw AssetTransferError.assetOverflow(assetID: chunk.assetID, maximum: maximum, attempted: attempted)
        }
        buffer.append(chunk.bytes)
        pending.buffers[chunk.assetID] = buffer
        self.pending = pending
        return UInt32(buffer.count)
    }

    public mutating func finalize() throws -> ActiveAssetSet {
        guard let pending else {
            throw AssetTransferError.noPendingSet
        }
        for descriptor in pending.manifest.items {
            let bytes = pending.buffers[descriptor.assetID] ?? Data()
            guard bytes.count == Int(descriptor.byteCount) else {
                throw AssetTransferError.incompleteAsset(
                    assetID: descriptor.assetID,
                    expected: Int(descriptor.byteCount),
                    actual: bytes.count
                )
            }
            guard BLECRC32.checksum(bytes) == descriptor.crc32 else {
                throw AssetTransferError.crcMismatch(assetID: descriptor.assetID)
            }
        }

        let activated = ActiveAssetSet(setID: pending.manifest.setID, assets: pending.buffers)
        activeSet = activated
        self.pending = nil
        return activated
    }

    public mutating func cancelPending() {
        pending = nil
    }
}

private struct PendingSet: Sendable {
    let manifest: AssetManifest
    var buffers: [UInt16: Data]
}
