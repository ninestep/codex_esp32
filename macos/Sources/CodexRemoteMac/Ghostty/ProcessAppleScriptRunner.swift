import Foundation

public protocol AppleScriptRunning: Sendable {
    func run(source: String) async throws -> String
}

public struct ProcessAppleScriptRunner: AppleScriptRunning {
    public init() {}

    public func run(source: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        async let outputData = Self.readData(from: stdout.fileHandleForReading)
        async let errorData = Self.readData(from: stderr.fileHandleForReading)
        let terminationStatus = try await Self.runAndWaitForTermination(process)

        let output = String(data: try await outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: try await errorData, encoding: .utf8) ?? ""

        guard terminationStatus == 0 else {
            throw GhosttyControllerError.appleScriptFailed(errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func readData(from fileHandle: FileHandle) async throws -> Data {
        var data = Data()
        for try await byte in fileHandle.bytes {
            data.append(byte)
        }
        return data
    }

    private static func runAndWaitForTermination(_ process: Process) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}
