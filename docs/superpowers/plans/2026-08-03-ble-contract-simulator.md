# BLE Contract and Simulated Device Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Freeze the platform-neutral BLE protocol v1 and prove session control, state synchronization, framed IMA-ADPCM audio, and atomic JPEG asset synchronization against a deterministic simulated device.

**Architecture:** Extend `CodexRemoteCore` with a dependency-free binary wire contract shared by future macOS, Windows, and ESP-IDF adapters. Keep ATT transport and CoreBluetooth outside this phase; a pure Swift simulated device exercises fragmentation, reassembly, sequencing, request acknowledgement, audio recovery, and asset atomicity through in-memory byte packets and checked-in golden fixtures.

**Tech Stack:** Swift 6.2, Foundation, XCTest, binary little-endian codecs, CRC32/IEEE, IMA-ADPCM, JSON fixture manifests, zsh fixture verification.

---

## Scope and approval

This plan is phase two of the approved design. The user explicitly authorized continuing phase two on 2026-08-03, including the shared BLE contract. It does not add dependencies, modify persistent user configuration, install BlackHole, use CoreBluetooth, add SwiftUI, or create ESP-IDF firmware.

Protocol v1 decisions frozen by this plan:

- The logical envelope uses magic bytes `CR`, major version `1`, minor version `0`, a one-byte message type, one-byte flags, a 32-bit little-endian sequence, a 32-bit little-endian payload length, payload bytes, and a trailing CRC32/IEEE over header plus payload.
- Every integer is little-endian. Strings are UTF-8 with an unsigned 16-bit byte length. Invalid UTF-8, overflow, trailing bytes, unknown message types, incompatible major versions, malformed flags, and CRC mismatches are explicit decoding errors.
- ATT fragmentation occurs after envelope encoding. Each fragment carries a 32-bit message ID, 16-bit zero-based fragment index, 16-bit fragment count, and payload bytes. Reassembly is bounded to 256 KiB, 1,024 fragments, and one active message per channel.
- Session keys are connection-scoped `UInt16` values. Reconnection clears keys and state sequences; the host must send a full snapshot before deltas.
- Control requests use `UInt32 requestID`. Enter/Esc and selection are acknowledged exactly once by the simulated device; timeouts are reported and never automatically retried.
- Audio uses independent 20 ms, 16 kHz, mono IMA-ADPCM frames: 320 PCM samples, frame sequence, sample timestamp, predictor, step index, 160 ADPCM bytes, and frame CRC through the outer envelope.
- Asset v1 accepts baseline JPEG metadata and raw JPEG bytes. A manifest identifies an asset set, item count, total bytes, and per-item CRC. The simulator activates a new set only after every declared item is complete and verified.

## File map

```text
macos/
├── Sources/CodexRemoteCore/
│   ├── BLE/
│   │   ├── BLEProtocolVersion.swift
│   │   ├── BLEMessage.swift
│   │   ├── BLEBinaryCoding.swift
│   │   ├── BLEEnvelopeCodec.swift
│   │   ├── BLEFragmentCodec.swift
│   │   └── BLEMessageCodec.swift
│   ├── Audio/
│   │   └── IMAADPCMCodec.swift
│   ├── Assets/
│   │   └── AssetTransferState.swift
│   └── Simulation/
│       └── SimulatedRemoteDevice.swift
├── Tests/CodexRemoteCoreTests/
│   ├── BLEEnvelopeCodecTests.swift
│   ├── BLEFragmentCodecTests.swift
│   ├── BLEMessageCodecTests.swift
│   ├── IMAADPCMCodecTests.swift
│   ├── AssetTransferStateTests.swift
│   ├── SimulatedRemoteDeviceTests.swift
│   └── BLEGoldenFixtureTests.swift
├── Fixtures/ble-v1/
│   ├── manifest.json
│   └── *.hex
└── Tests/Scripts/ble-golden-fixtures.zsh
```

Each production file owns one responsibility. BLE wire types must not import AppKit, SwiftUI, CoreBluetooth, CoreAudio, or Ghostty types.

### Task 1: Freeze protocol primitives and logical envelope

**Files:**
- Create: `macos/Sources/CodexRemoteCore/BLE/BLEProtocolVersion.swift`
- Create: `macos/Sources/CodexRemoteCore/BLE/BLEBinaryCoding.swift`
- Create: `macos/Sources/CodexRemoteCore/BLE/BLEEnvelopeCodec.swift`
- Test: `macos/Tests/CodexRemoteCoreTests/BLEEnvelopeCodecTests.swift`

- [x] **Step 1: Write failing tests**

Test the exact empty-payload vector, round-trip with binary payload, CRC rejection, incompatible major version, unknown message type, truncated fields, payload-length mismatch, trailing bytes, malformed UTF-8 helper input, and maximum 256 KiB envelope boundary.

- [x] **Step 2: Verify RED**

Run: `cd macos && swift test --filter BLEEnvelopeCodecTests`

Expected: compilation fails because the protocol types do not exist.

- [x] **Step 3: Implement minimal primitives**

Define `BLEProtocolVersion(major: 1, minor: 0)`, `BLEMessageType: UInt8`, `BLEEnvelope`, `BLECodecError`, `BLEBinaryEncoder`, `BLEBinaryDecoder`, and `BLEEnvelopeCodec`. CRC uses reflected polynomial `0xEDB88320`, initial value `0xFFFFFFFF`, and final XOR `0xFFFFFFFF`.

- [x] **Step 4: Verify GREEN**

Run: `cd macos && swift test --filter BLEEnvelopeCodecTests`

Expected: all envelope tests pass with no warnings.

### Task 2: Define the v1 message model and deterministic payload codec

**Files:**
- Create: `macos/Sources/CodexRemoteCore/BLE/BLEMessage.swift`
- Create: `macos/Sources/CodexRemoteCore/BLE/BLEMessageCodec.swift`
- Test: `macos/Tests/CodexRemoteCoreTests/BLEMessageCodecTests.swift`

- [x] **Step 1: Write failing round-trip and validation tests**

Cover these message cases with exact field equality:

```swift
case selectSession(requestID: UInt32, sessionKey: UInt16)
case scroll(sessionKey: UInt16, delta: Int16, sequence: UInt32)
case terminalKey(requestID: UInt32, sessionKey: UInt16, key: RemoteTerminalKey)
case pttBegin(requestID: UInt32, sessionKey: UInt16, firstAudioSequence: UInt32)
case pttEnd(requestID: UInt32, sessionKey: UInt16, lastAudioSequence: UInt32)
case actionResult(requestID: UInt32, result: RemoteActionResult, detail: String)
case stateSnapshot(generation: UInt32, sessions: [DeviceSession])
case stateDelta(generation: UInt32, sequence: UInt32, session: DeviceSession)
case audioFrame(ADPCMFrame)
case assetManifest(AssetManifest)
case assetChunk(AssetChunk)
case assetAcknowledgement(setID: UInt32, assetID: UInt16, nextOffset: UInt32, result: AssetAckResult)
case deviceInfo(DeviceInformation)
case resyncRequired(reason: ResyncReason)
```

Validate at most eight snapshot sessions, bounded title/detail UTF-8 lengths of 64/192 bytes, valid state/key/result enum values, chunk bounds, ADPCM sample count, no trailing payload bytes, and exact message-type/case agreement.

- [x] **Step 2: Verify RED**

Run: `cd macos && swift test --filter BLEMessageCodecTests`

Expected: compilation fails because `BLEMessage` and payload types do not exist.

- [x] **Step 3: Implement wire-only domain types and codec**

Keep `DeviceSession` separate from `RemoteSession`; it contains only connection-scoped key, bounded display fields, state, unread flag, capabilities bitset, and `updatedAtMilliseconds`. Add explicit conversion from `RemoteSession` in a small extension without exposing terminal, launcher, or provider IDs.

- [x] **Step 4: Verify GREEN and core boundary**

Run: `cd macos && swift test --filter 'BLEMessageCodecTests|ModuleBoundaryTests'`

Expected: all tests pass and `CodexRemoteCore` remains platform-neutral.

### Task 3: Add bounded ATT fragmentation and reassembly

**Files:**
- Create: `macos/Sources/CodexRemoteCore/BLE/BLEFragmentCodec.swift`
- Test: `macos/Tests/CodexRemoteCoreTests/BLEFragmentCodecTests.swift`

- [x] **Step 1: Write failing tests**

Test fragmentation at payload sizes 20, 185, and 512; ordered reassembly; duplicate fragment rejection; out-of-order rejection with resync; mismatched message ID/count rejection; zero count; count above 1,024; aggregate bytes above 256 KiB; connection reset; and a second message replacing no incomplete message silently.

- [x] **Step 2: Verify RED**

Run: `cd macos && swift test --filter BLEFragmentCodecTests`

Expected: compilation fails because fragment types do not exist.

- [x] **Step 3: Implement fragment codec and stateful reassembler**

Require transport payload capacity greater than the 8-byte fragment header. Emit fragments in index order. `BLEFragmentReassembler` accepts one connection/channel stream, returns `.waiting` or `.complete(Data)`, and throws explicit errors without retaining malformed partial data.

- [x] **Step 4: Verify GREEN**

Run: `cd macos && swift test --filter BLEFragmentCodecTests`

Expected: all fragmentation tests pass.

### Task 4: Implement independent-frame IMA-ADPCM

**Files:**
- Create: `macos/Sources/CodexRemoteCore/Audio/IMAADPCMCodec.swift`
- Test: `macos/Tests/CodexRemoteCoreTests/IMAADPCMCodecTests.swift`

- [x] **Step 1: Write failing codec tests**

Use deterministic vectors for silence, impulse, ascending ramp, descending ramp, and clipped extrema. Assert 320 samples encode to 160 bytes, predictor and step index are carried per frame, decoding a later frame does not depend on earlier frames, invalid step index is rejected, and mean absolute error stays within the checked vector bounds.

- [x] **Step 2: Verify RED**

Run: `cd macos && swift test --filter IMAADPCMCodecTests`

Expected: compilation fails because `IMAADPCMCodec` does not exist.

- [x] **Step 3: Implement the standard IMA state machine**

Use the standard 89-entry step table and 16-entry index adjustment table. Pack the earlier sample in the low nibble and later sample in the high nibble. Clamp predictor to `Int16` and step index to `0...88`; reject input frames whose PCM count is not 320.

- [x] **Step 4: Verify GREEN**

Run: `cd macos && swift test --filter IMAADPCMCodecTests`

Expected: all audio vectors pass.

### Task 5: Implement atomic asset-set transfer

**Files:**
- Create: `macos/Sources/CodexRemoteCore/Assets/AssetTransferState.swift`
- Test: `macos/Tests/CodexRemoteCoreTests/AssetTransferStateTests.swift`

- [x] **Step 1: Write failing state-machine tests**

Test manifest acceptance, ordered chunks, duplicate exact chunk idempotency, conflicting duplicate rejection, offset gaps, per-item CRC failure, total-byte mismatch, interruption preserving the active set, complete verified set activation, set replacement, maximum item and byte limits, and baseline-JPEG metadata validation without decoding image pixels.

- [x] **Step 2: Verify RED**

Run: `cd macos && swift test --filter AssetTransferStateTests`

Expected: compilation fails because `AssetTransferState` does not exist.

- [x] **Step 3: Implement pending/active asset sets**

Store bytes only in memory in this phase. Limit one pending set to eight images and 4 MiB total. `receive(manifest:)` starts a pending transaction; `receive(chunk:)` returns the next required offset; only `finalize()` after all lengths and CRC values match replaces `activeSet` atomically.

- [x] **Step 4: Verify GREEN**

Run: `cd macos && swift test --filter AssetTransferStateTests`

Expected: all asset transaction tests pass.

### Task 6: Build the deterministic simulated device

**Files:**
- Create: `macos/Sources/CodexRemoteCore/Simulation/SimulatedRemoteDevice.swift`
- Test: `macos/Tests/CodexRemoteCoreTests/SimulatedRemoteDeviceTests.swift`

- [x] **Step 1: Write failing integration tests**

Drive only encoded and fragmented bytes, never call simulator internals directly. Cover handshake/device info, snapshot-before-delta, eight-session limit, stale generation rejection, session selection ACK, unavailable session error, scroll sequence deduplication, Enter/Esc request deduplication, PTT rejection without a selected session, PTT begin/audio/end, dropped audio sequence accounting, resync after fragment error, disconnect clearing session keys, and interrupted/complete asset transfer.

- [x] **Step 2: Verify RED**

Run: `cd macos && swift test --filter SimulatedRemoteDeviceTests`

Expected: compilation fails because `SimulatedRemoteDevice` does not exist.

- [x] **Step 3: Implement the simulator**

The simulator owns connection generation, session projection, selected key, control request results, audio counters, and `AssetTransferState`. It accepts transport fragments by logical characteristic, reassembles and decodes envelopes, applies messages, and returns encoded response fragments. It records bounded diagnostics containing only message type, IDs, byte counts, sequence gaps, and result codes.

- [x] **Step 4: Verify GREEN**

Run: `cd macos && swift test --filter SimulatedRemoteDeviceTests`

Expected: all end-to-end simulated behaviors pass.

### Task 7: Check in golden fixtures and cross-check regeneration

**Files:**
- Create: `macos/Fixtures/ble-v1/manifest.json`
- Create: `macos/Fixtures/ble-v1/*.hex`
- Create: `macos/Tests/CodexRemoteCoreTests/BLEGoldenFixtureTests.swift`
- Create: `macos/Tests/Scripts/ble-golden-fixtures.zsh`

- [x] **Step 1: Write failing fixture tests**

The manifest names each vector, message type, sequence, and hex file. Include at least: empty control result, select session, terminal Enter, four-session snapshot, eight-session snapshot, one state delta, one ADPCM silence frame, one asset manifest, one asset chunk, device info, bad CRC, incompatible major version, and two-fragment message.

- [x] **Step 2: Verify RED**

Run: `cd macos && swift test --filter BLEGoldenFixtureTests`

Expected: failure because fixture files do not exist.

- [x] **Step 3: Generate and check in deterministic vectors**

Add a test-only fixture generator that emits lowercase contiguous hex. The zsh script regenerates into a temporary directory, compares every file and the manifest byte-for-byte, rejects undeclared files, and leaves the repository untouched.

- [x] **Step 4: Verify fixtures**

Run: `zsh macos/Tests/Scripts/ble-golden-fixtures.zsh`

Expected: exit 0 and no output.

### Task 8: Phase-two completion review

**Files:**
- Create: `macos/Docs/phase-2-verification.md`
- Modify: `docs/superpowers/specs/2026-08-02-codex-remote-control-design.md` only if tests disprove an assumption

- [x] **Step 1: Run fresh verification**

Run:

```bash
cd macos && swift test --parallel
swift build
cd .. && zsh macos/Tests/Scripts/codex-shim.zsh
zsh macos/Tests/Scripts/ble-golden-fixtures.zsh
```

Expected: all commands exit 0.

- [x] **Step 2: Scan boundaries and fixture integrity**

Run:

```bash
rg -n 'import (AppKit|SwiftUI|CoreBluetooth|CoreAudio)|Ghostty|AppleScript' macos/Sources/CodexRemoteCore
rg -n 'terminalTargetID|launcherInstanceID|providerSessionID' macos/Sources/CodexRemoteCore/BLE macos/Fixtures/ble-v1
git diff --check
```

Expected: no platform imports in core; no private terminal/provider identifiers in the BLE contract or fixtures; no whitespace errors.

- [x] **Step 3: Write the Chinese verification report**

Record the protocol version and byte order, golden vector count, automated test count, simulator scenarios, audio error bounds, asset limits, exact commands and exit codes, and every item that still requires CoreBluetooth or real hardware.

- [x] **Step 4: Stop at the phase-three gate**

Present the report. Do not begin ESP-IDF/BSP dependency work, modify partitions, install toolchains, or start CoreBluetooth/BlackHole integration without the next explicit instruction.

## Completion criteria

- All phase-two source code remains in `CodexRemoteCore` and imports no platform framework.
- The v1 envelope and every v1 message have deterministic encode/decode tests and checked-in golden bytes.
- The simulator proves session/control/state behavior through fragmented byte transport.
- Every audio frame is independently decodable after loss.
- Interrupted asset synchronization leaves the old active set intact; only a fully verified set activates.
- The report separates simulated evidence from BLE/ESP32 hardware evidence.
