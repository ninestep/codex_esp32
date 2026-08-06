import Foundation
import XCTest
@testable import CodexRemoteCore

final class BLEGoldenFixtureTests: XCTestCase {
    func testCheckedInFixturesMatchCurrentCodecAndExpectedOutcomes() throws {
        let directory = fixtureDirectory
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(FixtureManifest.self, from: Data(contentsOf: manifestURL))
        let generated = try makeFixtureSet()

        XCTAssertEqual(manifest.protocolMajor, 1)
        XCTAssertEqual(manifest.protocolMinor, 2)
        XCTAssertEqual(Set(manifest.vectors.map(\.file)), Set(generated.files.keys.filter { $0.hasSuffix(".hex") }))

        for vector in manifest.vectors {
            let checkedIn = try String(contentsOf: directory.appendingPathComponent(vector.file), encoding: .utf8)
            XCTAssertEqual(checkedIn, generated.files[vector.file], vector.name)
            try assertOutcome(vector, text: checkedIn)
        }
    }

    func testGenerateFixtures() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["BLE_FIXTURE_OUTPUT_DIR"] else { return }
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixtureSet = try makeFixtureSet()
        for (name, content) in fixtureSet.files {
            try Data(content.utf8).write(to: output.appendingPathComponent(name), options: .atomic)
        }
        try fixtureSet.manifest.write(to: output.appendingPathComponent("manifest.json"), options: .atomic)
    }

    private var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ble-v1", isDirectory: true)
    }

    private func makeFixtureSet() throws -> GeneratedFixtureSet {
        let codec = BLEMessageCodec()
        let sessions = (1...8).map { fixtureSession(key: UInt16($0)) }
        let jpeg = Data([0xff, 0xd8, 1, 2, 0xff, 0xd9])
        let manifest = AssetManifest(
            setID: 9,
            totalBytes: UInt32(jpeg.count),
            items: [AssetItemDescriptor(
                assetID: 1,
                width: 480,
                height: 480,
                byteCount: UInt32(jpeg.count),
                crc32: BLECRC32.checksum(jpeg)
            )]
        )
        let silence = try IMAADPCMCodec().encode(
            samples: Array(repeating: 0, count: 320),
            sequence: 10,
            sampleTimestamp: 3_200
        )

        let valid: [(String, String, UInt32, BLEMessage)] = [
            ("empty-action-result", "actionResult", 0, .actionResult(requestID: 0, result: .success, detail: "")),
            ("select-session", "selectSession", 1, .selectSession(requestID: 1, sessionKey: 2)),
            ("terminal-enter", "terminalKey", 2, .terminalKey(requestID: 3, sessionKey: 2, key: .enter)),
            ("terminal-up", "terminalKey", 3, .terminalKey(requestID: 4, sessionKey: 2, key: .up)),
            ("terminal-backspace", "terminalKey", 4, .terminalKey(requestID: 5, sessionKey: 2, key: .backspace)),
            ("terminal-clear-line", "terminalKey", 5, .terminalKey(requestID: 6, sessionKey: 2, key: .clearLine)),
            ("terminal-compact", "terminalShortcut", 6, .terminalShortcut(requestID: 7, sessionKey: 2, shortcut: .compact)),
            ("snapshot-four", "stateSnapshot", 7, .stateSnapshot(generation: 4, sessions: Array(sessions.prefix(4)))),
            ("snapshot-eight", "stateSnapshot", 8, .stateSnapshot(generation: 5, sessions: sessions)),
            ("state-delta", "stateDelta", 9, .stateDelta(generation: 5, sequence: 1, session: sessions[0])),
            ("adpcm-silence", "audioFrame", 10, .audioFrame(silence)),
            ("asset-manifest", "assetManifest", 11, .assetManifest(manifest)),
            ("asset-chunk", "assetChunk", 12, .assetChunk(AssetChunk(setID: 9, assetID: 1, offset: 0, bytes: jpeg))),
            ("device-info", "deviceInfo", 13, .deviceInfo(DeviceInformation(firmwareVersion: "sim-1", capabilities: [.display, .microphone], batteryPercent: 80))),
        ]

        var files: [String: String] = [:]
        var vectors: [FixtureVector] = []
        for (name, type, sequence, message) in valid {
            let file = "\(name).hex"
            files[file] = try codec.encode(message, sequence: sequence).hexLine
            vectors.append(FixtureVector(name: name, file: file, kind: "envelope", messageType: type, sequence: sequence, outcome: "valid"))
        }

        var badCRC = try codec.encode(.selectSession(requestID: 1, sessionKey: 2), sequence: 14)
        badCRC[14] ^= 0xff
        files["bad-crc.hex"] = badCRC.hexLine
        vectors.append(FixtureVector(name: "bad-crc", file: "bad-crc.hex", kind: "envelope", messageType: "selectSession", sequence: 14, outcome: "crcMismatch"))

        var incompatible = try codec.encode(.selectSession(requestID: 1, sessionKey: 2), sequence: 15)
        incompatible[2] = 2
        rewriteCRC(&incompatible)
        files["incompatible-major.hex"] = incompatible.hexLine
        vectors.append(FixtureVector(name: "incompatible-major", file: "incompatible-major.hex", kind: "envelope", messageType: "selectSession", sequence: 15, outcome: "incompatibleMajor"))

        let fragmentedEnvelope = try codec.encode(.selectSession(requestID: 4, sessionKey: 3), sequence: 16)
        let fragments = try BLEFragmentCodec().fragment(fragmentedEnvelope, messageID: 99, maximumPacketBytes: 20)
        let fragmentFile = "two-fragment-message.hex"
        files[fragmentFile] = fragments.map(\.hex).joined(separator: "\n") + "\n"
        vectors.append(FixtureVector(name: "two-fragment-message", file: fragmentFile, kind: "fragmentSet", messageType: "selectSession", sequence: 16, outcome: "valid"))

        let fixtureManifest = FixtureManifest(protocolMajor: 1, protocolMinor: 2, byteOrder: "little", crc: "CRC32/IEEE", vectors: vectors)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var manifestData = try encoder.encode(fixtureManifest)
        manifestData.append(0x0a)
        return GeneratedFixtureSet(manifest: manifestData, files: files)
    }

    private func assertOutcome(_ vector: FixtureVector, text: String) throws {
        if vector.kind == "fragmentSet" {
            var reassembler = BLEFragmentReassembler()
            var completed: Data?
            for line in text.split(separator: "\n") {
                if case let .complete(data) = try reassembler.accept(Data(hex: String(line))) {
                    completed = data
                }
            }
            XCTAssertEqual(try completed.map { try BLEMessageCodec().decode($0).sequence }, vector.sequence)
            return
        }

        let data = Data(hex: text.trimmingCharacters(in: .whitespacesAndNewlines))
        switch vector.outcome {
        case "valid":
            XCTAssertEqual(try BLEMessageCodec().decode(data).sequence, vector.sequence)
        case "crcMismatch":
            XCTAssertThrowsError(try BLEMessageCodec().decode(data)) { error in
                XCTAssertEqual(error as? BLECodecError, .crcMismatch)
            }
        case "incompatibleMajor":
            XCTAssertThrowsError(try BLEMessageCodec().decode(data)) { error in
                XCTAssertEqual(error as? BLECodecError, .incompatibleMajorVersion(2))
            }
        default:
            XCTFail("未知 fixture outcome：\(vector.outcome)")
        }
    }

    private func fixtureSession(key: UInt16) -> DeviceSession {
        DeviceSession(
            sessionKey: key,
            displayTitle: "session-\(key)",
            workingDirectoryLabel: "macos",
            state: key.isMultiple(of: 2) ? .working : .idle,
            statusDetail: "BLE v1",
            unread: false,
            capabilities: [.scroll, .terminalKeys, .ptt, .navigationKeys, .terminalShortcuts],
            updatedAtMilliseconds: 1_700_000_000_000 + UInt64(key)
        )
    }

    private func rewriteCRC(_ data: inout Data) {
        let checksum = BLECRC32.checksum(data.dropLast(4))
        data.replaceSubrange(data.index(data.endIndex, offsetBy: -4)..<data.endIndex, with: checksum.littleEndianBytes)
    }
}

private struct FixtureManifest: Codable {
    let protocolMajor: Int
    let protocolMinor: Int
    let byteOrder: String
    let crc: String
    let vectors: [FixtureVector]
}

private struct FixtureVector: Codable {
    let name: String
    let file: String
    let kind: String
    let messageType: String
    let sequence: UInt32
    let outcome: String
}

private struct GeneratedFixtureSet {
    let manifest: Data
    let files: [String: String]
}

private extension Data {
    init(hex: String) {
        self.init()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
    }

    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }

    var hexLine: String {
        hex + "\n"
    }
}
