import Foundation

public struct BLEMessageCodec: Sendable {
    private let envelopeCodec = BLEEnvelopeCodec()

    public init() {}

    public func encode(_ message: BLEMessage, sequence: UInt32) throws -> Data {
        let encoded = try encodePayload(message)
        return try envelopeCodec.encode(BLEEnvelope(type: encoded.type, sequence: sequence, payload: encoded.payload))
    }

    public func decode(_ data: Data) throws -> BLEDecodedMessage {
        let envelope = try envelopeCodec.decode(data)
        var decoder = BLEBinaryDecoder(data: envelope.payload)
        let message = try decodePayload(type: envelope.type, decoder: &decoder)
        try decoder.requireEnd()
        return BLEDecodedMessage(sequence: envelope.sequence, message: message)
    }

    private func encodePayload(_ message: BLEMessage) throws -> (type: BLEMessageType, payload: Data) {
        var encoder = BLEBinaryEncoder()
        let type: BLEMessageType

        switch message {
        case let .selectSession(requestID, sessionKey):
            type = .selectSession
            encoder.append(requestID)
            encoder.append(sessionKey)
        case let .scroll(sessionKey, delta, sequence):
            type = .scroll
            encoder.append(sessionKey)
            encoder.append(UInt16(bitPattern: delta))
            encoder.append(sequence)
        case let .terminalKey(requestID, sessionKey, key):
            type = .terminalKey
            encoder.append(requestID)
            encoder.append(sessionKey)
            encoder.append(key.rawValue)
        case let .pttBegin(requestID, sessionKey, firstAudioSequence):
            type = .pttBegin
            encoder.append(requestID)
            encoder.append(sessionKey)
            encoder.append(firstAudioSequence)
        case let .pttEnd(requestID, sessionKey, lastAudioSequence):
            type = .pttEnd
            encoder.append(requestID)
            encoder.append(sessionKey)
            encoder.append(lastAudioSequence)
        case let .actionResult(requestID, result, detail):
            type = .actionResult
            encoder.append(requestID)
            encoder.append(result.rawValue)
            try encoder.appendString(detail, maxBytes: 192)
        case let .stateSnapshot(generation, sessions):
            guard sessions.count <= 8 else { throw BLEMessageCodecError.tooManySessions(sessions.count) }
            type = .stateSnapshot
            encoder.append(generation)
            encoder.append(UInt8(sessions.count))
            for session in sessions { try encode(session, into: &encoder) }
        case let .stateDelta(generation, sequence, session):
            type = .stateDelta
            encoder.append(generation)
            encoder.append(sequence)
            try encode(session, into: &encoder)
        case let .audioFrame(frame):
            try validate(frame)
            type = .audioFrame
            encoder.append(frame.sequence)
            encoder.append(frame.sampleTimestamp)
            encoder.append(UInt16(bitPattern: frame.predictor))
            encoder.append(frame.stepIndex)
            encoder.append(frame.sampleCount)
            encoder.append(UInt16(frame.encodedSamples.count))
            encoder.append(frame.encodedSamples)
        case let .assetManifest(manifest):
            try validate(manifest)
            type = .assetManifest
            encoder.append(manifest.setID)
            encoder.append(manifest.totalBytes)
            encoder.append(UInt8(manifest.items.count))
            for item in manifest.items {
                encoder.append(item.assetID)
                encoder.append(item.width)
                encoder.append(item.height)
                encoder.append(item.byteCount)
                encoder.append(item.crc32)
            }
        case let .assetChunk(chunk):
            guard let length = UInt16(exactly: chunk.bytes.count) else {
                throw BLEMessageCodecError.chunkTooLarge(chunk.bytes.count)
            }
            type = .assetChunk
            encoder.append(chunk.setID)
            encoder.append(chunk.assetID)
            encoder.append(chunk.offset)
            encoder.append(length)
            encoder.append(chunk.bytes)
        case let .assetAcknowledgement(setID, assetID, nextOffset, result):
            type = .assetAcknowledgement
            encoder.append(setID)
            encoder.append(assetID)
            encoder.append(nextOffset)
            encoder.append(result.rawValue)
        case let .deviceInfo(info):
            guard info.batteryPercent <= 100 else {
                throw BLEMessageCodecError.invalidBatteryPercent(info.batteryPercent)
            }
            type = .deviceInfo
            encoder.append(BLEProtocolVersion.current.major)
            encoder.append(BLEProtocolVersion.current.minor)
            try encoder.appendString(info.firmwareVersion, maxBytes: 64)
            encoder.append(info.capabilities.rawValue)
            encoder.append(info.batteryPercent)
        case let .resyncRequired(reason):
            type = .resyncRequired
            encoder.append(reason.rawValue)
        }

        return (type, encoder.data)
    }

    private func decodePayload(type: BLEMessageType, decoder: inout BLEBinaryDecoder) throws -> BLEMessage {
        switch type {
        case .selectSession:
            return .selectSession(requestID: try decoder.readUInt32(), sessionKey: try decoder.readUInt16())
        case .scroll:
            return .scroll(
                sessionKey: try decoder.readUInt16(),
                delta: Int16(bitPattern: try decoder.readUInt16()),
                sequence: try decoder.readUInt32()
            )
        case .terminalKey:
            let requestID = try decoder.readUInt32()
            let sessionKey = try decoder.readUInt16()
            let raw = try decoder.readUInt8()
            guard let key = RemoteTerminalKey(rawValue: raw) else {
                throw BLEMessageCodecError.unknownEnum(field: "terminalKey", rawValue: raw)
            }
            return .terminalKey(requestID: requestID, sessionKey: sessionKey, key: key)
        case .pttBegin:
            return .pttBegin(
                requestID: try decoder.readUInt32(),
                sessionKey: try decoder.readUInt16(),
                firstAudioSequence: try decoder.readUInt32()
            )
        case .pttEnd:
            return .pttEnd(
                requestID: try decoder.readUInt32(),
                sessionKey: try decoder.readUInt16(),
                lastAudioSequence: try decoder.readUInt32()
            )
        case .actionResult:
            let requestID = try decoder.readUInt32()
            let raw = try decoder.readUInt8()
            guard let result = RemoteActionResult(rawValue: raw) else {
                throw BLEMessageCodecError.unknownEnum(field: "actionResult", rawValue: raw)
            }
            return .actionResult(requestID: requestID, result: result, detail: try decoder.readString(maxBytes: 192))
        case .stateSnapshot:
            let generation = try decoder.readUInt32()
            let count = Int(try decoder.readUInt8())
            guard count <= 8 else { throw BLEMessageCodecError.tooManySessions(count) }
            var sessions: [DeviceSession] = []
            sessions.reserveCapacity(count)
            for _ in 0..<count { sessions.append(try decodeSession(from: &decoder)) }
            return .stateSnapshot(generation: generation, sessions: sessions)
        case .stateDelta:
            return .stateDelta(
                generation: try decoder.readUInt32(),
                sequence: try decoder.readUInt32(),
                session: try decodeSession(from: &decoder)
            )
        case .audioFrame:
            let frame = ADPCMFrame(
                sequence: try decoder.readUInt32(),
                sampleTimestamp: try decoder.readUInt64(),
                predictor: Int16(bitPattern: try decoder.readUInt16()),
                stepIndex: try decoder.readUInt8(),
                sampleCount: try decoder.readUInt16(),
                encodedSamples: try decoder.readData(count: Int(try decoder.readUInt16()))
            )
            try validate(frame)
            return .audioFrame(frame)
        case .assetManifest:
            let setID = try decoder.readUInt32()
            let totalBytes = try decoder.readUInt32()
            let count = Int(try decoder.readUInt8())
            guard count <= 8 else { throw BLEMessageCodecError.tooManyAssets(count) }
            var items: [AssetItemDescriptor] = []
            items.reserveCapacity(count)
            for _ in 0..<count {
                items.append(AssetItemDescriptor(
                    assetID: try decoder.readUInt16(),
                    width: try decoder.readUInt16(),
                    height: try decoder.readUInt16(),
                    byteCount: try decoder.readUInt32(),
                    crc32: try decoder.readUInt32()
                ))
            }
            let manifest = AssetManifest(setID: setID, totalBytes: totalBytes, items: items)
            try validate(manifest)
            return .assetManifest(manifest)
        case .assetChunk:
            return .assetChunk(AssetChunk(
                setID: try decoder.readUInt32(),
                assetID: try decoder.readUInt16(),
                offset: try decoder.readUInt32(),
                bytes: try decoder.readData(count: Int(try decoder.readUInt16()))
            ))
        case .assetAcknowledgement:
            let setID = try decoder.readUInt32()
            let assetID = try decoder.readUInt16()
            let nextOffset = try decoder.readUInt32()
            let raw = try decoder.readUInt8()
            guard let result = AssetAckResult(rawValue: raw) else {
                throw BLEMessageCodecError.unknownEnum(field: "assetAckResult", rawValue: raw)
            }
            return .assetAcknowledgement(setID: setID, assetID: assetID, nextOffset: nextOffset, result: result)
        case .deviceInfo:
            let major = try decoder.readUInt8()
            _ = try decoder.readUInt8()
            guard major == BLEProtocolVersion.current.major else {
                throw BLECodecError.incompatibleMajorVersion(major)
            }
            let firmware = try decoder.readString(maxBytes: 64)
            let capabilities = DeviceFeatureCapabilities(rawValue: try decoder.readUInt16())
            let battery = try decoder.readUInt8()
            guard battery <= 100 else { throw BLEMessageCodecError.invalidBatteryPercent(battery) }
            return .deviceInfo(DeviceInformation(firmwareVersion: firmware, capabilities: capabilities, batteryPercent: battery))
        case .resyncRequired:
            let raw = try decoder.readUInt8()
            guard let reason = ResyncReason(rawValue: raw) else {
                throw BLEMessageCodecError.unknownEnum(field: "resyncReason", rawValue: raw)
            }
            return .resyncRequired(reason: reason)
        }
    }

    private func encode(_ session: DeviceSession, into encoder: inout BLEBinaryEncoder) throws {
        encoder.append(session.sessionKey)
        try encoder.appendString(session.displayTitle, maxBytes: 64)
        try encoder.appendString(session.workingDirectoryLabel, maxBytes: 64)
        encoder.append(session.state.rawValue)
        try encoder.appendString(session.statusDetail, maxBytes: 192)
        encoder.append(UInt8(session.unread ? 1 : 0))
        encoder.append(session.capabilities.rawValue)
        encoder.append(session.updatedAtMilliseconds)
    }

    private func decodeSession(from decoder: inout BLEBinaryDecoder) throws -> DeviceSession {
        let sessionKey = try decoder.readUInt16()
        let title = try decoder.readString(maxBytes: 64)
        let directory = try decoder.readString(maxBytes: 64)
        let rawState = try decoder.readUInt8()
        guard let state = DeviceSessionState(rawValue: rawState) else {
            throw BLEMessageCodecError.unknownEnum(field: "sessionState", rawValue: rawState)
        }
        let detail = try decoder.readString(maxBytes: 192)
        let rawUnread = try decoder.readUInt8()
        guard rawUnread <= 1 else { throw BLEMessageCodecError.invalidBoolean(rawUnread) }
        return DeviceSession(
            sessionKey: sessionKey,
            displayTitle: title,
            workingDirectoryLabel: directory,
            state: state,
            statusDetail: detail,
            unread: rawUnread == 1,
            capabilities: DeviceSessionCapabilities(rawValue: try decoder.readUInt16()),
            updatedAtMilliseconds: try decoder.readUInt64()
        )
    }

    private func validate(_ frame: ADPCMFrame) throws {
        guard frame.sampleCount == 320 else {
            throw BLEMessageCodecError.invalidAudioSampleCount(frame.sampleCount)
        }
        guard frame.encodedSamples.count == 160 else {
            throw BLEMessageCodecError.invalidAudioByteCount(frame.encodedSamples.count)
        }
        guard frame.stepIndex <= 88 else {
            throw BLEMessageCodecError.invalidStepIndex(frame.stepIndex)
        }
    }

    private func validate(_ manifest: AssetManifest) throws {
        guard !manifest.items.isEmpty, manifest.items.count <= 8 else {
            throw BLEMessageCodecError.tooManyAssets(manifest.items.count)
        }
        let uniqueIDs = Set(manifest.items.map(\.assetID))
        let total = manifest.items.reduce(UInt64(0)) { $0 + UInt64($1.byteCount) }
        guard uniqueIDs.count == manifest.items.count,
              total == UInt64(manifest.totalBytes),
              manifest.items.allSatisfy({ $0.width > 0 && $0.height > 0 && $0.byteCount > 0 })
        else {
            throw BLEMessageCodecError.invalidAssetManifest
        }
    }
}
