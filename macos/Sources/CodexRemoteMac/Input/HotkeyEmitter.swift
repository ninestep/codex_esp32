import ApplicationServices
import Foundation

public struct SyntheticHotkeyEvent: Equatable, Sendable {
    public let keyCode: CGKeyCode
    public let keyDown: Bool
    public let type: CGEventType
    public let flags: CGEventFlags
}

public struct ParsedHotkey: Equatable, Sendable {
    public let keyDownEvents: [SyntheticHotkeyEvent]
    public let keyUpEvents: [SyntheticHotkeyEvent]
    public let displayValue: String
    public let requiresHoldMode: Bool

    public var keyCode: CGKeyCode { keyDownEvents.last!.keyCode }
    public var keyDownFlags: CGEventFlags { keyDownEvents.last!.flags }
    public var keyUpFlags: CGEventFlags { keyUpEvents.last!.flags }
    public var keyDownEventType: CGEventType { keyDownEvents.last!.type }
    public var keyUpEventType: CGEventType { keyUpEvents.last!.type }
}

public enum HotkeyParseError: Error, Equatable, Sendable {
    case empty
    case missingModifier
    case missingKey
    case multipleKeys
    case duplicateModifier(String)
    case functionKeyUnsupported
    case unknownToken(String)
}

public struct HotkeyParser: Sendable {
    public init() {}

    public func parse(_ value: String) -> ParsedHotkey? {
        try? parseRequired(value)
    }

    public func parseRequired(_ value: String) throws -> ParsedHotkey {
        let tokens = tokenize(value)
        guard !tokens.isEmpty else { throw HotkeyParseError.empty }
        let compactValue = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if compactValue.contains("fn") {
            throw HotkeyParseError.functionKeyUnsupported
        }

        var flags: CGEventFlags = []
        var modifierDisplays = Set<String>()
        var mainKey: (code: CGKeyCode, display: String)?

        for token in tokens {
            if let modifier = modifier(for: token) {
                guard !modifierDisplays.contains(modifier.display) else {
                    throw HotkeyParseError.duplicateModifier(modifier.display)
                }
                modifierDisplays.insert(modifier.display)
                flags.insert(modifier.flag)
                continue
            }

            if let parsedKey = key(for: token) {
                guard mainKey == nil else { throw HotkeyParseError.multipleKeys }
                mainKey = parsedKey
                continue
            }

            throw HotkeyParseError.unknownToken(token)
        }

        guard !modifierDisplays.isEmpty else { throw HotkeyParseError.missingModifier }
        let displayModifiers = ["⌘", "⌥", "⌃", "⇧"].filter { modifierDisplays.contains($0) }.joined()
        guard let mainKey else {
            guard modifierDisplays.count >= 2,
                  !modifierDisplays.contains("⇧"),
                  displayModifiers.last != nil
            else {
                throw HotkeyParseError.missingKey
            }
            let orderedModifiers = ["⌘", "⌥", "⌃"].filter { modifierDisplays.contains($0) }
            var activeFlags: CGEventFlags = []
            let keyDownEvents = orderedModifiers.map { display in
                let modifier = modifierDetails(for: display)!
                activeFlags.insert(modifier.flag)
                activeFlags.insert(modifier.deviceFlag)
                return SyntheticHotkeyEvent(
                    keyCode: modifier.keyCode,
                    keyDown: true,
                    type: .flagsChanged,
                    flags: activeFlags
                )
            }
            let keyUpEvents = orderedModifiers.reversed().map { display in
                let modifier = modifierDetails(for: display)!
                activeFlags.remove(modifier.flag)
                activeFlags.remove(modifier.deviceFlag)
                return SyntheticHotkeyEvent(
                    keyCode: modifier.keyCode,
                    keyDown: false,
                    type: .flagsChanged,
                    flags: activeFlags
                )
            }
            return ParsedHotkey(
                keyDownEvents: keyDownEvents,
                keyUpEvents: keyUpEvents,
                displayValue: displayModifiers,
                requiresHoldMode: true
            )
        }

        return ParsedHotkey(
            keyDownEvents: [SyntheticHotkeyEvent(
                keyCode: mainKey.code,
                keyDown: true,
                type: .keyDown,
                flags: flags
            )],
            keyUpEvents: [SyntheticHotkeyEvent(
                keyCode: mainKey.code,
                keyDown: false,
                type: .keyUp,
                flags: flags
            )],
            displayValue: "\(displayModifiers)\(mainKey.display)",
            requiresHoldMode: false
        )
    }

    private func modifierDetails(
        for display: String
    ) -> (keyCode: CGKeyCode, flag: CGEventFlags, deviceFlag: CGEventFlags)? {
        switch display {
        case "⌘": (55, .maskCommand, CGEventFlags(rawValue: 0x00000008))
        case "⌥": (58, .maskAlternate, CGEventFlags(rawValue: 0x00000020))
        case "⌃": (59, .maskControl, CGEventFlags(rawValue: 0x00000001))
        default: nil
        }
    }

    private func tokenize(_ value: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for character in value.trimmingCharacters(in: .whitespacesAndNewlines) {
            if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }

            if "⌘⌥⌃⇧".contains(character) {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                tokens.append(String(character))
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private func modifier(for token: String) -> (display: String, flag: CGEventFlags)? {
        switch token.lowercased() {
        case "⌘", "cmd", "command":
            return ("⌘", .maskCommand)
        case "⌥", "option", "opt", "alt":
            return ("⌥", .maskAlternate)
        case "⌃", "control", "ctrl":
            return ("⌃", .maskControl)
        case "⇧", "shift":
            return ("⇧", .maskShift)
        default:
            return nil
        }
    }

    private func key(for token: String) -> (code: CGKeyCode, display: String)? {
        let lowered = token.lowercased()
        if token.count == 1, let scalar = lowered.unicodeScalars.first {
            if scalar.value >= 97, scalar.value <= 122 {
                return (letterKeyCodes[Character(lowered)]!, token.uppercased())
            }
            if scalar.value >= 48, scalar.value <= 57 {
                return (digitKeyCodes[Character(lowered)]!, token)
            }
        }

        switch lowered {
        case "space", "空格":
            return (49, "Space")
        case "return", "enter":
            return (36, "Enter")
        case "tab":
            return (48, "Tab")
        case "↑", "arrowup", "up":
            return (126, "↑")
        case "↓", "arrowdown", "down":
            return (125, "↓")
        case "←", "arrowleft", "left":
            return (123, "←")
        case "→", "arrowright", "right":
            return (124, "→")
        default:
            return nil
        }
    }

    private let letterKeyCodes: [Character: CGKeyCode] = [
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34,
        "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35, "q": 12,
        "r": 15, "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
    ]

    private let digitKeyCodes: [Character: CGKeyCode] = [
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21,
        "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
    ]
}

@MainActor
public protocol HotkeyEmitting: AnyObject {
    var isAuthorized: Bool { get }
    func keyDown(_ hotkey: ParsedHotkey) throws
    func keyUp(_ hotkey: ParsedHotkey) throws
    func recoverAfterKeyUpFailure(_ hotkey: ParsedHotkey)
}

public extension HotkeyEmitting {
    func recoverAfterKeyUpFailure(_ hotkey: ParsedHotkey) {}
}

@MainActor
public final class CGEventHotkeyEmitter: HotkeyEmitting {
    private let authorizationReader: () -> Bool
    private let eventPoster: (SyntheticHotkeyEvent) throws -> Void

    public init() {
        authorizationReader = { AXIsProcessTrusted() }
        eventPoster = Self.postSystemEvent
    }

    init(
        authorizationReader: @escaping () -> Bool,
        eventPoster: @escaping (SyntheticHotkeyEvent) throws -> Void
    ) {
        self.authorizationReader = authorizationReader
        self.eventPoster = eventPoster
    }

    public var isAuthorized: Bool { authorizationReader() }

    public func keyDown(_ hotkey: ParsedHotkey) throws {
        guard isAuthorized else { throw AudioInputBridgeError.accessibilityNotGranted }
        var postedKeyCodes = Set<CGKeyCode>()
        do {
            for event in hotkey.keyDownEvents {
                try eventPoster(event)
                postedKeyCodes.insert(event.keyCode)
            }
        } catch {
            for event in hotkey.keyUpEvents where postedKeyCodes.contains(event.keyCode) {
                try? eventPoster(event)
            }
            throw error
        }
    }

    public func keyUp(_ hotkey: ParsedHotkey) throws {
        guard isAuthorized else { throw AudioInputBridgeError.accessibilityNotGranted }
        for event in hotkey.keyUpEvents {
            try eventPoster(event)
        }
    }

    public func recoverAfterKeyUpFailure(_ hotkey: ParsedHotkey) {
        for event in hotkey.keyUpEvents {
            try? eventPoster(event)
        }
    }

    private static func postSystemEvent(_ descriptor: SyntheticHotkeyEvent) throws {
        guard let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: descriptor.keyCode,
            keyDown: descriptor.keyDown
        ) else {
            throw AudioInputBridgeError.audioSystemFailure
        }
        event.type = descriptor.type
        event.flags = descriptor.flags
        event.post(tap: .cghidEventTap)
    }
}
