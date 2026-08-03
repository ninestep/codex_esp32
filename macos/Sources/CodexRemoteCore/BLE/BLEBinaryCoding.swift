import Foundation

struct BLEBinaryEncoder: Sendable {
    private(set) var data = Data()

    mutating func append(_ value: UInt8) {
        data.append(value)
    }

    mutating func append(_ value: UInt16) {
        data.append(contentsOf: value.littleEndianBytes)
    }

    mutating func append(_ value: UInt32) {
        data.append(contentsOf: value.littleEndianBytes)
    }

    mutating func append(_ value: UInt64) {
        data.append(contentsOf: value.littleEndianBytes)
    }

    mutating func append(_ bytes: some Sequence<UInt8>) {
        data.append(contentsOf: bytes)
    }

    mutating func appendString(_ value: String, maxBytes: Int) throws {
        let bytes = Data(value.utf8)
        guard bytes.count <= maxBytes else {
            throw BLECodecError.stringTooLong(maximum: maxBytes, actual: bytes.count)
        }
        guard let length = UInt16(exactly: bytes.count) else {
            throw BLECodecError.numericOverflow
        }
        append(length)
        append(bytes)
    }
}

struct BLEBinaryDecoder: Sendable {
    private let data: Data
    private var offset = 0

    init(data: Data) {
        self.data = data
    }

    var remainingCount: Int {
        data.count - offset
    }

    mutating func readUInt8() throws -> UInt8 {
        let bytes = try readData(count: 1)
        return bytes[bytes.startIndex]
    }

    mutating func readUInt16() throws -> UInt16 {
        let bytes = try readData(count: 2)
        return UInt16(bytes[bytes.startIndex])
            | UInt16(bytes[bytes.index(after: bytes.startIndex)]) << 8
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readData(count: 4)
        return bytes.enumerated().reduce(UInt32(0)) { result, pair in
            result | UInt32(pair.element) << UInt32(pair.offset * 8)
        }
    }

    mutating func readUInt64() throws -> UInt64 {
        let bytes = try readData(count: 8)
        return bytes.enumerated().reduce(UInt64(0)) { result, pair in
            result | UInt64(pair.element) << UInt64(pair.offset * 8)
        }
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, remainingCount >= count else {
            throw BLECodecError.truncated
        }
        let start = data.index(data.startIndex, offsetBy: offset)
        let end = data.index(start, offsetBy: count)
        offset += count
        return Data(data[start..<end])
    }

    mutating func readString(maxBytes: Int) throws -> String {
        let length = Int(try readUInt16())
        guard length <= maxBytes else {
            throw BLECodecError.stringTooLong(maximum: maxBytes, actual: length)
        }
        let bytes = try readData(count: length)
        guard let value = String(data: bytes, encoding: .utf8) else {
            throw BLECodecError.invalidUTF8
        }
        return value
    }

    func requireEnd() throws {
        guard remainingCount == 0 else {
            throw BLECodecError.trailingBytes(remainingCount)
        }
    }
}

extension UInt16 {
    var littleEndianBytes: [UInt8] {
        [UInt8(truncatingIfNeeded: self), UInt8(truncatingIfNeeded: self >> 8)]
    }
}

extension UInt32 {
    var littleEndianBytes: [UInt8] {
        [
            UInt8(truncatingIfNeeded: self),
            UInt8(truncatingIfNeeded: self >> 8),
            UInt8(truncatingIfNeeded: self >> 16),
            UInt8(truncatingIfNeeded: self >> 24),
        ]
    }
}

extension UInt64 {
    var littleEndianBytes: [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: self >> UInt64($0 * 8)) }
    }
}

enum BLECRC32 {
    static func checksum(_ bytes: some Sequence<UInt8>) -> UInt32 {
        var crc = UInt32.max
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1
            }
        }
        return crc ^ UInt32.max
    }
}
