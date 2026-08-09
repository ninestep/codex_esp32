import Foundation
import OSLog

struct DoubaoRecognitionResultState {
    private(set) var latestText = ""
    private(set) var didReceiveServerFinish = false

    mutating func receiveResult(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        latestText = text
        return nil
    }

    mutating func receiveFinish() -> String {
        didReceiveServerFinish = true
        return latestText
    }
}

@MainActor
public final class DoubaoSpeechRecognitionSessionFactory: SpeechRecognitionSessionFactory {
    private let credentialsStore: DoubaoCredentialsStore

    public init(credentialsStore: DoubaoCredentialsStore = DoubaoCredentialsStore()) {
        self.credentialsStore = credentialsStore
    }

    public var dependencyStatus: AudioDependencyStatus {
        credentialsStore.load() == nil ? .speechRecognitionUnavailable : .ready
    }

    public func makeSession() throws -> any SpeechRecognitionSession {
        guard let credentials = credentialsStore.load() else {
            throw AudioInputBridgeError.dependencyMissing
        }
        return try DoubaoSpeechRecognitionSession(credentials: credentials)
    }
}

@MainActor
final class DoubaoSpeechRecognitionSession: SpeechRecognitionSession {
    private static let logger = Logger(subsystem: "CodexRemote", category: "DoubaoASR")
    private static let finishTimeout: Duration = .seconds(8)
    private static let resultSettleDelay: Duration = .milliseconds(900)

    private var socket: URLSessionWebSocketTask?
    private var connected = false
    private var isSending = false
    private var isFinishing = false
    private var pendingAudio: [Data] = []
    private var resultState = DoubaoRecognitionResultState()
    private var finishContinuation: CheckedContinuation<String, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var resultSettleTask: Task<Void, Never>?

    init(credentials: DoubaoASRCredentials) throws {
        guard let url = Self.makeURL(credentials: credentials) else {
            throw AudioInputBridgeError.audioSystemFailure
        }
        var request = URLRequest(url: url)
        request.setValue(credentials.cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("https://www.doubao.com", forHTTPHeaderField: "Origin")
        request.timeoutInterval = 8

        let socket = URLSession.shared.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        receiveNext()
        socket.sendPing { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    Self.logger.error("Doubao WebSocket connection failed: \(error.localizedDescription, privacy: .public)")
                    self.fail(AudioInputBridgeError.audioSystemFailure)
                    return
                }
                self.connected = true
                Self.logger.info("Doubao WebSocket connected")
                self.sendNextIfNeeded()
            }
        }
    }

    func append(samples: [Int16]) throws {
        guard !isFinishing, socket != nil else { throw AudioInputBridgeError.notActive }
        guard !samples.isEmpty else { return }
        var data = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            var value = sample.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        pendingAudio.append(data)
        sendNextIfNeeded()
    }

    func finish() async throws -> String {
        guard socket != nil, finishContinuation == nil else {
            throw AudioInputBridgeError.notActive
        }
        isFinishing = true
        return try await withCheckedThrowingContinuation { continuation in
            finishContinuation = continuation
            if resultState.didReceiveServerFinish {
                complete(resultState.latestText)
                return
            }
            scheduleResultSettlementIfReady()
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: Self.finishTimeout)
                guard !Task.isCancelled else { return }
                self?.finishAfterTimeout()
            }
        }
    }

    func cancel() {
        timeoutTask?.cancel()
        timeoutTask = nil
        resultSettleTask?.cancel()
        resultSettleTask = nil
        finishContinuation = nil
        pendingAudio.removeAll()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        connected = false
        isSending = false
        isFinishing = false
    }

    private func sendNextIfNeeded() {
        guard connected, !isSending, !pendingAudio.isEmpty, let socket else { return }
        isSending = true
        let data = pendingAudio.removeFirst()
        socket.send(.data(data)) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.isSending = false
                if error != nil {
                    self.fail(AudioInputBridgeError.audioSystemFailure)
                    return
                }
                self.sendNextIfNeeded()
                self.scheduleResultSettlementIfReady()
            }
        }
    }

    private func receiveNext() {
        socket?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let message):
                    self.handle(message)
                    if self.socket != nil { self.receiveNext() }
                case .failure(let error):
                    if self.socket != nil {
                        Self.logger.error("Doubao WebSocket receive failed: \(error.localizedDescription, privacy: .public)")
                        self.fail(AudioInputBridgeError.audioSystemFailure)
                    }
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text):
            guard let value = text.data(using: .utf8) else { return }
            data = value
        case .data(let value):
            data = value
        @unknown default:
            return
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let code = json["code"] as? Int ?? 0
        if code != 0 {
            Self.logger.error("Doubao ASR rejected request with code \(code)")
            fail(AudioInputBridgeError.audioSystemFailure)
            return
        }
        switch json["event"] as? String {
        case "result":
            if let result = json["result"] as? [String: Any],
               let text = result["Text"] as? String,
               !text.isEmpty {
                _ = resultState.receiveResult(text)
                Self.logger.debug("Doubao ASR result characters=\(text.count)")
                scheduleResultSettlementIfReady()
            }
        case "finish":
            let text = resultState.receiveFinish()
            if isFinishing { complete(text) }
        default:
            break
        }
    }

    private func finishAfterTimeout() {
        if resultState.latestText.isEmpty {
            fail(AudioInputBridgeError.audioSystemFailure)
        } else {
            complete(resultState.latestText)
        }
    }

    private func scheduleResultSettlementIfReady() {
        guard isFinishing,
              !resultState.latestText.isEmpty,
              !isSending,
              pendingAudio.isEmpty,
              !resultState.didReceiveServerFinish
        else { return }
        resultSettleTask?.cancel()
        resultSettleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.resultSettleDelay)
            guard !Task.isCancelled else { return }
            self?.completeSettledResult()
        }
    }

    private func completeSettledResult() {
        guard isFinishing,
              !resultState.latestText.isEmpty,
              !isSending,
              pendingAudio.isEmpty
        else { return }
        complete(resultState.latestText)
    }

    private func complete(_ text: String) {
        timeoutTask?.cancel()
        timeoutTask = nil
        resultSettleTask?.cancel()
        resultSettleTask = nil
        guard let continuation = finishContinuation else { return }
        finishContinuation = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        continuation.resume(returning: text)
    }

    private func fail(_ error: Error) {
        timeoutTask?.cancel()
        timeoutTask = nil
        resultSettleTask?.cancel()
        resultSettleTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        guard let continuation = finishContinuation else { return }
        finishContinuation = nil
        continuation.resume(throwing: error)
    }

    private static func makeURL(credentials: DoubaoASRCredentials) -> URL? {
        var components = URLComponents(string: "wss://ws-samantha.doubao.com/samantha/audio/asr")
        components?.queryItems = [
            URLQueryItem(name: "version_code", value: "20800"),
            URLQueryItem(name: "language", value: "zh"),
            URLQueryItem(name: "device_platform", value: "web"),
            URLQueryItem(name: "aid", value: "497858"),
            URLQueryItem(name: "real_aid", value: "497858"),
            URLQueryItem(name: "pkg_type", value: "release_version"),
            URLQueryItem(name: "device_id", value: credentials.deviceID),
            URLQueryItem(name: "pc_version", value: "3.12.3"),
            URLQueryItem(name: "web_id", value: credentials.webID),
            URLQueryItem(name: "tea_uuid", value: credentials.webID),
            URLQueryItem(name: "region", value: ""),
            URLQueryItem(name: "sys_region", value: ""),
            URLQueryItem(name: "samantha_web", value: "1"),
            URLQueryItem(name: "use-olympus-account", value: "1"),
            URLQueryItem(name: "web_tab_id", value: UUID().uuidString),
            URLQueryItem(name: "format", value: "pcm"),
        ]
        return components?.url
    }
}
