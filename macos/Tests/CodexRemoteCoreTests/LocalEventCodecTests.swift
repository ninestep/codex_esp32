import Foundation
import XCTest
@testable import CodexRemoteCore

final class LocalEventCodecTests: XCTestCase {
    func testLaunchRegisteredRoundTripsThroughCodec() throws {
        let codec = LocalEventCodec()
        let event = LocalEvent.launchRegistered(
            LaunchRegistration(
                launcherInstanceID: "launch-1",
                terminalTargetID: "terminal-7",
                displayTitle: "ESP32",
                workingDirectoryLabel: "~/esp32"
            )
        )

        let encoded = try codec.encode(event)
        let decoded = try codec.decode(LocalEvent.self, from: encoded)

        XCTAssertEqual(decoded, event)
    }

    func testHookReceivedRoundTripsThroughCodec() throws {
        let codec = LocalEventCodec()
        let event = LocalEvent.hookReceived(
            HookPayload(
                hookEventName: "PermissionRequest",
                sessionID: "codex-99",
                launcherInstanceID: "launch-1",
                message: "允许执行受保护操作？",
                lastAssistantMessage: nil
            )
        )

        let encoded = try codec.encode(event)
        let decoded = try codec.decode(LocalEvent.self, from: encoded)

        XCTAssertEqual(decoded, event)
    }

    func testDecodeRejectsFrameLargerThanMaximum() throws {
        let codec = LocalEventCodec()
        let oversizedFrame = Data(repeating: 0x20, count: 65_537)

        do {
            _ = try codec.decode(LocalEvent.self, from: oversizedFrame)
            XCTFail("Expected frameTooLarge")
        } catch let error as LocalEventCodecError {
            XCTAssertEqual(error, .frameTooLarge(65_537))
        } catch {
            XCTFail("Expected LocalEventCodecError, got \(error)")
        }
    }

    func testEncodeRejectsPayloadLargerThanMaximum() throws {
        let codec = LocalEventCodec()
        let event = LocalEvent.hookReceived(
            HookPayload(
                hookEventName: "Stop",
                sessionID: "codex-99",
                launcherInstanceID: "launch-1",
                message: nil,
                lastAssistantMessage: String(repeating: "A", count: 70 * 1024)
            )
        )

        do {
            _ = try codec.encode(event)
            XCTFail("Expected frameTooLarge")
        } catch let error as LocalEventCodecError {
            guard case let .frameTooLarge(size) = error else {
                XCTFail("Expected frameTooLarge, got \(error)")
                return
            }
            XCTAssertGreaterThan(size, LocalEventCodec.maximumFrameBytes)
        } catch {
            XCTFail("Expected LocalEventCodecError, got \(error)")
        }
    }

    func testMaximumFrameBytesIs64KiB() {
        XCTAssertEqual(LocalEventCodec.maximumFrameBytes, 64 * 1024)
    }
}
