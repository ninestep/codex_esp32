import Foundation

@MainActor
public protocol HotkeyTestClock: AnyObject {
    func sleep(seconds: UInt64) async throws
}

public final class SuspendingHotkeyTestClock: HotkeyTestClock {
    public init() {}

    public func sleep(seconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
    }
}

public enum HotkeyTestResult: Equatable, Sendable {
    case eventSent(displayValue: String)

    public var message: String {
        switch self {
        case .eventSent:
            return "按键事件已发送"
        }
    }
}

public enum HotkeyTestError: Error, Equatable, Sendable {
    case invalidFormat
    case accessibilityPermissionRequired
    case sendFailed

    public var message: String {
        switch self {
        case .invalidFormat:
            return "快捷键格式无效"
        case .accessibilityPermissionRequired:
            return "需要辅助功能权限"
        case .sendFailed:
            return "按键事件发送失败"
        }
    }
}

@MainActor
public final class HotkeyTester {
    private let emitter: any HotkeyEmitting
    private let clock: any HotkeyTestClock
    private let parser: HotkeyParser

    public init(
        emitter: any HotkeyEmitting = CGEventHotkeyEmitter(),
        clock: any HotkeyTestClock = SuspendingHotkeyTestClock(),
        parser: HotkeyParser = HotkeyParser()
    ) {
        self.emitter = emitter
        self.clock = clock
        self.parser = parser
    }

    public func test(
        _ value: String,
        onCountdown: @MainActor (Int) -> Void = { _ in }
    ) async throws -> HotkeyTestResult {
        let hotkey: ParsedHotkey
        do {
            hotkey = try parser.parseRequired(value)
        } catch {
            throw HotkeyTestError.invalidFormat
        }

        guard emitter.isAuthorized else {
            throw HotkeyTestError.accessibilityPermissionRequired
        }

        for seconds in stride(from: 3, through: 1, by: -1) {
            onCountdown(seconds)
            try await clock.sleep(seconds: 1)
        }

        do {
            try emitter.keyDown(hotkey)
        } catch {
            throw HotkeyTestError.sendFailed
        }

        do {
            try emitter.keyUp(hotkey)
        } catch {
            emitter.recoverAfterKeyUpFailure(hotkey)
            throw HotkeyTestError.sendFailed
        }

        return .eventSent(displayValue: hotkey.displayValue)
    }
}
