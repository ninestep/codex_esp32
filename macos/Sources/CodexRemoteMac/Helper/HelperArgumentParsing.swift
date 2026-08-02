import Foundation

public struct HelperStdinPolicy: Sendable {
    public static func shouldReadStdin(arguments: [String]) -> Bool {
        arguments.first == "hook"
    }
}

public struct HelperServeArguments: Equatable, Sendable {
    public let socketPath: String

    public static func parse(_ arguments: [String]) throws -> HelperServeArguments {
        let parser = try HelperOptionParser(
            arguments: arguments,
            valuedOptions: ["--socket"],
            flags: []
        )
        return HelperServeArguments(socketPath: try parser.required("--socket"))
    }
}

public struct HelperOptionParser: Sendable {
    private let options: [String: String]
    private let flags: Set<String>

    public init(arguments: [String], valuedOptions: Set<String>, flags allowedFlags: Set<String>) throws {
        var parsed: [String: String] = [:]
        var parsedFlags: Set<String> = []
        var index = 0

        while index < arguments.count {
            let token = arguments[index]
            guard token.hasPrefix("--") else {
                throw HelperOptionError.unexpectedPositional(token)
            }

            if valuedOptions.contains(token) {
                guard parsed[token] == nil else {
                    throw HelperOptionError.duplicate(token)
                }
                let valueIndex = index + 1
                guard valueIndex < arguments.count, !arguments[valueIndex].hasPrefix("--") else {
                    throw HelperOptionError.missing(token)
                }
                guard Self.hasNonWhitespace(arguments[valueIndex]) else {
                    throw HelperOptionError.blank(token)
                }
                parsed[token] = arguments[valueIndex]
                index += 2
                continue
            }

            if allowedFlags.contains(token) {
                guard !parsedFlags.contains(token) else {
                    throw HelperOptionError.duplicate(token)
                }
                let nextIndex = index + 1
                if nextIndex < arguments.count, !arguments[nextIndex].hasPrefix("--") {
                    throw HelperOptionError.flagDoesNotTakeValue(token)
                }
                parsedFlags.insert(token)
                index += 1
                continue
            }

            throw HelperOptionError.unknown(token)
        }

        self.options = parsed
        self.flags = parsedFlags
    }

    public func has(_ name: String) -> Bool {
        options.keys.contains(name) || flags.contains(name)
    }

    public func required(_ name: String) throws -> String {
        guard let value = options[name] else {
            throw HelperOptionError.missing(name)
        }
        return value
    }

    public func requiredURL(_ name: String) throws -> URL {
        URL(fileURLWithPath: try required(name))
    }

    private static func hasNonWhitespace(_ value: String) -> Bool {
        value.unicodeScalars.contains { !CharacterSet.whitespacesAndNewlines.contains($0) }
    }
}

public enum HelperOptionError: Error, Equatable, CustomStringConvertible, Sendable {
    case missing(String)
    case duplicate(String)
    case unknown(String)
    case unexpectedPositional(String)
    case flagDoesNotTakeValue(String)
    case blank(String)

    public var description: String {
        switch self {
        case .missing(let option):
            "missing \(option)"
        case .duplicate(let option):
            "duplicate \(option)"
        case .unknown(let option):
            "unknown \(option)"
        case .unexpectedPositional(let value):
            "unexpected positional \(value)"
        case .flagDoesNotTakeValue(let option):
            "\(option) does not take a value"
        case .blank(let option):
            "blank \(option)"
        }
    }
}
