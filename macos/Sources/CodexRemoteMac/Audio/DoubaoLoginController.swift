import AppKit
import Foundation
import WebKit

public enum DoubaoLoginState: Equatable, Sendable {
    case loggedOut
    case loginWindowOpen
    case ready
    case failed(String)
}

@MainActor
public final class DoubaoLoginController: NSObject {
    public var onStateChange: ((DoubaoLoginState) -> Void)?
    public private(set) var state: DoubaoLoginState {
        didSet { onStateChange?(state) }
    }
    public private(set) var credentials: DoubaoASRCredentials?

    private let credentialsStore: DoubaoCredentialsStore
    private var webView: WKWebView?
    private var window: NSWindow?
    private var statusLabel: NSTextField?

    public init(credentialsStore: DoubaoCredentialsStore = DoubaoCredentialsStore()) {
        self.credentialsStore = credentialsStore
        self.state = .loggedOut
        super.init()
    }

    public func restoreCredentials() async {
        let credentialsStore = self.credentialsStore
        let restored = await Task.detached(priority: .utility) {
            credentialsStore.load()
        }.value
        guard state == .loggedOut else { return }
        credentials = restored
        state = restored == nil ? .loggedOut : .ready
    }

    public func showLoginWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            state = .loginWindowOpen
            return
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36"
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false

        let statusLabel = NSTextField(labelWithString: "登录豆包后，点击右侧按钮保存识别凭证。")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let completeButton = NSButton(title: "登录完成，保存凭证", target: self, action: #selector(completeLogin))
        completeButton.bezelStyle = .rounded

        let footer = NSStackView(views: [statusLabel, completeButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 12
        footer.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        completeButton.setContentHuggingPriority(.required, for: .horizontal)

        let contentView = NSView()
        contentView.addSubview(webView)
        contentView.addSubview(footer)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: contentView.topAnchor),
            webView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex Remote - 登录豆包语音识别"
        window.contentView = contentView
        window.isReleasedWhenClosed = false
        window.center()

        self.webView = webView
        self.window = window
        self.statusLabel = statusLabel
        webView.load(URLRequest(url: URL(string: "https://www.doubao.com/chat/")!))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        state = .loginWindowOpen
    }

    public func logout() {
        do {
            try credentialsStore.clear()
            credentials = nil
            state = .loggedOut
        } catch {
            state = .failed("清除豆包登录凭证失败")
        }
    }

    @objc private func completeLogin() {
        statusLabel?.stringValue = "正在检查登录状态…"
        Task { @MainActor [weak self] in
            await self?.captureCredentials()
        }
    }

    private func captureCredentials() async {
        guard let webView else {
            state = .failed("豆包登录窗口不可用")
            return
        }

        let cookies = await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies {
                continuation.resume(returning: $0)
            }
        }.filter { $0.domain.hasSuffix("doubao.com") }

        let deviceID = await localStorageWebID(
            key: "samantha_web_web_id",
            webView: webView
        )
        let webID = await localStorageWebID(
            key: "__tea_cache_tokens_497858",
            webView: webView
        )
        let cookieMap = Dictionary(cookies.map { ($0.name, $0.value) }, uniquingKeysWith: { _, latest in latest })
        let credentials = DoubaoASRCredentials(
            cookies: cookieMap,
            deviceID: deviceID,
            webID: webID
        )
        guard credentials.isValid else {
            statusLabel?.stringValue = "未检测到有效登录，请在网页完成登录后重试。"
            state = .failed("未检测到有效豆包登录")
            return
        }

        do {
            try credentialsStore.save(credentials)
            self.credentials = credentials
            statusLabel?.stringValue = "登录凭证已安全保存。"
            state = .ready
            window?.orderOut(nil)
        } catch {
            statusLabel?.stringValue = "保存登录凭证失败。"
            state = .failed("保存豆包登录凭证失败")
        }
    }

    private func localStorageWebID(key: String, webView: WKWebView) async -> String {
        let script = "localStorage.getItem('\(key)')"
        guard let raw = try? await webView.evaluateJavaScript(script) as? String,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["web_id"] as? String
        else { return "" }
        return value
    }
}

extension DoubaoLoginController: WKNavigationDelegate {
    public nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor [weak self] in
            self?.statusLabel?.stringValue = "豆包页面加载失败：\(error.localizedDescription)"
            self?.state = .failed("豆包登录页面加载失败")
        }
    }

    public nonisolated func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor [weak self] in
            self?.statusLabel?.stringValue = "豆包页面加载失败：\(error.localizedDescription)"
            self?.state = .failed("豆包登录页面加载失败")
        }
    }
}

extension DoubaoLoginController: WKUIDelegate {
    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        webView.load(navigationAction.request)
        return nil
    }
}
