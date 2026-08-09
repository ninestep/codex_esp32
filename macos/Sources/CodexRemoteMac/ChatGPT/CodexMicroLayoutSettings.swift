import Foundation

public enum CodexMicroControlSlot: String, CaseIterable, Equatable, Sendable {
    case act06 = "ACT06"
    case act07 = "ACT07"
    case act08 = "ACT08"
    case act09 = "ACT09"
    case act10 = "ACT10"
    case act11 = "ACT11"
    case act10Act11 = "ACT10_ACT11"
    case act12 = "ACT12"
}

public enum CodexMicroResolvedAction: Equatable, Sendable {
    case command(id: String)
    case pushToTalk
    case skill(id: String)
    case unassigned

    public var displayName: String {
        switch self {
        case .pushToTalk:
            return "按住说话"
        case .unassigned:
            return "未分配"
        case .skill(let id):
            return "技能：\(id)"
        case .command(let id):
            return Self.commandNames[id] ?? id
        }
    }

    private static let commandNames = [
        "composer.toggleFastMode": "快速模式",
        "approval.approve": "批准",
        "approval.decline": "拒绝",
        "forkThread": "在新会话中继续",
        "composer.submit": "发送",
        "composer.togglePlanMode": "计划模式",
        "navigateForward": "前进",
        "navigateBack": "后退",
        "toggleSidebar": "显示或隐藏侧栏",
    ]
}

public struct CodexMicroSlotMapping: Equatable, Sendable {
    public let slot: CodexMicroControlSlot
    public let keycapID: String
    public let action: CodexMicroResolvedAction

    public init(slot: CodexMicroControlSlot, keycapID: String, action: CodexMicroResolvedAction) {
        self.slot = slot
        self.keycapID = keycapID
        self.action = action
    }
}

public struct CodexMicroLayoutSettings: Equatable, Sendable {
    public let version: Int
    public let separateMicrophoneKeys: Bool
    public let slots: [CodexMicroControlSlot: CodexMicroSlotMapping]

    public init(
        version: Int,
        separateMicrophoneKeys: Bool,
        slots: [CodexMicroControlSlot: CodexMicroSlotMapping]
    ) {
        self.version = version
        self.separateMicrophoneKeys = separateMicrophoneKeys
        self.slots = slots
    }

    public var activeCommandSlots: [CodexMicroSlotMapping] {
        let slotOrder: [CodexMicroControlSlot] = separateMicrophoneKeys
            ? [.act06, .act07, .act08, .act09, .act10, .act11, .act12]
            : [.act06, .act07, .act08, .act09, .act10Act11, .act12]
        return slotOrder.compactMap { slots[$0] }
    }

    public static let defaults = CodexMicroLayoutSettings(
        version: 1,
        separateMicrophoneKeys: false,
        slots: CodexMicroLayoutParser.defaultSlots
    )
}

public enum CodexMicroLayoutReadError: Error, Equatable, Sendable {
    case unreadableConfiguration
    case unsupportedVersion(Int)
    case malformedValue(line: Int)
}

public protocol CodexMicroLayoutReading: Sendable {
    func read() throws -> CodexMicroLayoutSettings
}

public struct CodexMicroLayoutReader: CodexMicroLayoutReading, Sendable {
    public let configurationURL: URL

    public init(configurationURL: URL = Self.defaultConfigurationURL()) {
        self.configurationURL = configurationURL
    }

    public func read() throws -> CodexMicroLayoutSettings {
        guard let data = FileManager.default.contents(atPath: configurationURL.path),
              let source = String(data: data, encoding: .utf8)
        else {
            throw CodexMicroLayoutReadError.unreadableConfiguration
        }
        return try CodexMicroLayoutParser().parse(source)
    }

    public static func defaultConfigurationURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml")
    }
}

struct CodexMicroLayoutParser: Sendable {
    static let defaultSlots: [CodexMicroControlSlot: CodexMicroSlotMapping] = {
        let definitions: [(CodexMicroControlSlot, String, CodexMicroResolvedAction)] = [
            (.act06, "FAST", .command(id: "composer.toggleFastMode")),
            (.act07, "APPR", .command(id: "approval.approve")),
            (.act08, "REJ", .command(id: "approval.decline")),
            (.act09, "SPLIT", .command(id: "forkThread")),
            (.act10, "MIC1", .pushToTalk),
            (.act11, "EMPT1", .unassigned),
            (.act10Act11, "MIC", .pushToTalk),
            (.act12, "CODEX", .command(id: "composer.submit")),
        ]
        return Dictionary(uniqueKeysWithValues: definitions.map { slot, keycap, action in
            (slot, CodexMicroSlotMapping(slot: slot, keycapID: keycap, action: action))
        })
    }()

    private static let layoutTable = "desktop.codex-micro-layout"

    func parse(_ source: String) throws -> CodexMicroLayoutSettings {
        var table = ""
        var values: [String: String] = [:]

        for (offset, rawLine) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = offset + 1
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.first == "[", line.last == "]" {
                table = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard table == Self.layoutTable || table.hasPrefix(Self.layoutTable + ".") else {
                continue
            }
            guard let equals = line.firstIndex(of: "=") else {
                throw CodexMicroLayoutReadError.malformedValue(line: lineNumber)
            }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else {
                throw CodexMicroLayoutReadError.malformedValue(line: lineNumber)
            }
            values["\(table).\(key)"] = value
        }

        guard values.keys.contains(where: { $0.hasPrefix(Self.layoutTable + ".") }) else {
            return .defaults
        }
        let version = try integer(values["\(Self.layoutTable).version"], default: 1)
        guard version == 1 else { throw CodexMicroLayoutReadError.unsupportedVersion(version) }
        let separate = try boolean(
            values["\(Self.layoutTable).separateMicrophoneKeys"],
            default: false
        )
        var slots = Self.defaultSlots
        for slot in CodexMicroControlSlot.allCases {
            let prefix = "\(Self.layoutTable).slots.\(slot.rawValue)"
            let keycap = try string(values["\(prefix).keycapId"])
                ?? Self.defaultSlots[slot]?.keycapID
                ?? ""
            let actionType = try string(values["\(prefix).action.type"])
            let nestedCommandID = try string(values["\(prefix).action.commandId"])
            let directCommandID = try string(values["\(prefix).commandId"])
            let skillID = try string(values["\(prefix).action.skillId"])
                ?? string(values["\(prefix).action.skillPath"])
            let action = resolveAction(
                actionType: actionType,
                commandID: nestedCommandID ?? directCommandID,
                skillID: skillID,
                keycapID: keycap
            )
            slots[slot] = CodexMicroSlotMapping(slot: slot, keycapID: keycap, action: action)
        }
        return CodexMicroLayoutSettings(
            version: version,
            separateMicrophoneKeys: separate,
            slots: slots
        )
    }

    private func resolveAction(
        actionType: String?,
        commandID: String?,
        skillID: String?,
        keycapID: String
    ) -> CodexMicroResolvedAction {
        if actionType == "skill", let skillID, !skillID.isEmpty {
            return .skill(id: skillID)
        }
        if let commandID, !commandID.isEmpty {
            return .command(id: commandID)
        }
        return Self.defaultSlots.values.first { $0.keycapID == keycapID }?.action ?? .unassigned
    }

    private func integer(_ raw: String?, default defaultValue: Int) throws -> Int {
        guard let raw else { return defaultValue }
        guard let value = Int(raw) else { throw CodexMicroLayoutReadError.malformedValue(line: 0) }
        return value
    }

    private func boolean(_ raw: String?, default defaultValue: Bool) throws -> Bool {
        guard let raw else { return defaultValue }
        switch raw {
        case "true": return true
        case "false": return false
        default: throw CodexMicroLayoutReadError.malformedValue(line: 0)
        }
    }

    private func string(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        guard raw.count >= 2, raw.first == "\"", raw.last == "\"" else {
            throw CodexMicroLayoutReadError.malformedValue(line: 0)
        }
        let body = raw.dropFirst().dropLast()
        return body
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private func stripComment(_ line: String) -> String {
        var quoted = false
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped {
                escaped = false
            } else if character == "\\", quoted {
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
            } else if character == "#", !quoted {
                return String(line[..<index])
            }
        }
        return line
    }
}
