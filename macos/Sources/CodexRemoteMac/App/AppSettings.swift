import Foundation

public enum HotkeyTriggerMode: String, Codable, CaseIterable, Sendable {
    case hold
    case toggle
}

public enum AudioDependencyStatus: Equatable, Sendable {
    case ready
    case blackHoleMissing

    public var userMessage: String {
        switch self {
        case .ready:
            return "BlackHole 2ch 已就绪"
        case .blackHoleMissing:
            return "未检测到 BlackHole 2ch，语音功能不可用"
        }
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var socketPath: String
    public var automaticBLEReconnect: Bool
    public var doubaoHotkey: String
    public var hotkeyMode: HotkeyTriggerMode
    public var lastTestedDoubaoHotkey: String?

    public init(
        socketPath: String,
        automaticBLEReconnect: Bool,
        doubaoHotkey: String,
        hotkeyMode: HotkeyTriggerMode,
        lastTestedDoubaoHotkey: String? = nil
    ) {
        self.socketPath = socketPath
        self.automaticBLEReconnect = automaticBLEReconnect
        self.doubaoHotkey = doubaoHotkey
        self.hotkeyMode = hotkeyMode
        self.lastTestedDoubaoHotkey = lastTestedDoubaoHotkey
    }

    public static func defaults(temporaryDirectory: String, userID: UInt32) -> AppSettings {
        let root = temporaryDirectory.hasSuffix("/")
            ? String(temporaryDirectory.dropLast())
            : temporaryDirectory
        return AppSettings(
            socketPath: "\(root)/codex-remote-\(userID)/events.sock",
            automaticBLEReconnect: true,
            doubaoHotkey: "",
            hotkeyMode: .hold
        )
    }

    public func canUsePTT(hasSelectedSession: Bool, blackHoleAvailable: Bool) -> Bool {
        hasSelectedSession && blackHoleAvailable && !doubaoHotkey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public mutating func normalizeDoubaoHotkey() throws {
        doubaoHotkey = try normalizedDoubaoHotkey()
    }

    public var wasCurrentHotkeyTested: Bool {
        guard let tested = lastTestedDoubaoHotkey,
              let current = HotkeyParser().parse(doubaoHotkey)?.displayValue
        else {
            return false
        }
        return tested == current
    }

    public mutating func recordSuccessfulHotkeyTest(displayValue: String) {
        lastTestedDoubaoHotkey = HotkeyParser().parse(displayValue)?.displayValue
    }

    public func normalizedDoubaoHotkey() throws -> String {
        let trimmed = doubaoHotkey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return try HotkeyParser().parseRequired(trimmed).displayValue
    }

    private enum CodingKeys: String, CodingKey {
        case socketPath
        case automaticBLEReconnect
        case doubaoHotkey
        case hotkeyMode
        case lastTestedDoubaoHotkey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        socketPath = try container.decodeIfPresent(String.self, forKey: .socketPath)
            ?? "/tmp/codex-remote/events.sock"
        automaticBLEReconnect = try container.decodeIfPresent(Bool.self, forKey: .automaticBLEReconnect)
            ?? true
        let decodedHotkey = try container.decodeIfPresent(String.self, forKey: .doubaoHotkey) ?? ""
        if let parsed = HotkeyParser().parse(decodedHotkey) {
            doubaoHotkey = parsed.displayValue
        } else {
            doubaoHotkey = decodedHotkey
        }
        if let decodedMode = try? container.decode(String.self, forKey: .hotkeyMode),
           let mode = HotkeyTriggerMode(rawValue: decodedMode) {
            hotkeyMode = mode
        } else {
            hotkeyMode = .hold
        }
        let decodedTestedHotkey = try? container.decode(String.self, forKey: .lastTestedDoubaoHotkey)
        lastTestedDoubaoHotkey = decodedTestedHotkey.flatMap { HotkeyParser().parse($0)?.displayValue }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(socketPath, forKey: .socketPath)
        try container.encode(automaticBLEReconnect, forKey: .automaticBLEReconnect)
        try container.encode(normalizedDoubaoHotkey(), forKey: .doubaoHotkey)
        try container.encode(hotkeyMode, forKey: .hotkeyMode)
        try container.encodeIfPresent(lastTestedDoubaoHotkey, forKey: .lastTestedDoubaoHotkey)
    }
}
