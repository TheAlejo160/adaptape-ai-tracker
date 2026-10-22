import AppKit
import WebKit

/// Embedded sign-in for subscription accounts without a public API. The web view uses a
/// non-persistent data store: nothing is shared with Safari or written to disk, and only the
/// provider's cookies end up in our Keychain.
@MainActor
enum WebLogin {
    /// The open window, kept alive until it closes. One at a time.
    private static var current: LoginWindowController?

    /// Loads the provider's `.webLogin` URL and calls `completion(true)` once the captured session
    /// passed the connector's own check and was saved; `false` if the user closes the window.
    /// Fires exactly once.
    static func present(for connector: any WebLoginConnector, completion: @escaping (Bool) -> Void) {
        guard case .webLogin(let url) = connector.info.auth, let host = url.host() else { return completion(false) }
        current?.window.close()
        let controller = LoginWindowController(connector: connector, url: url, host: host) { ok in
            current = nil
            completion(ok)
        }
        current = controller
        // Agent app: activate so the window comes to the front (the menu bar panel closes, by design).
        NSApp.activate()
        controller.window.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class LoginWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
    let window: NSWindow
    private let webView: WKWebView
    private let connector: any WebLoginConnector
    private let host: String
    private var completion: ((Bool) -> Void)?
    /// Debounced cookie check; replaced on every cookie change or page load.
    private var pendingCheck: Task<Void, Never>?

    init(connector: any WebLoginConnector, url: URL, host: String, completion: @escaping (Bool) -> Void) {
        self.connector = connector
        self.host = host
        self.completion = completion

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = WebSession.userAgent

        window = LoginWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()

        window.isReleasedWhenClosed = false
        window.title = "Conectar \(connector.info.name)"
        window.contentView = makeContent()
        window.center()
        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        config.websiteDataStore.httpCookieStore.add(self)
        webView.load(URLRequest(url: url))
    }

    private func makeContent() -> NSView {
        let note = NSTextField(wrappingLabelWithString: "Inicia sesión con tu correo: el acceso con Google o Apple puede no funcionar en esta ventana. La sesión se guarda solo en tu Llavero.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor

        let content = NSView()
        for view in [webView, note] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: content.topAnchor),
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            note.topAnchor.constraint(equalTo: webView.bottomAnchor, constant: 8),
            note.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            note.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            note.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
        return content
    }

    // MARK: Cookie watch

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) { checkCookies() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { checkCookies() }

    /// Sign-in buttons that open a popup load in place instead; there is no second window.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        webView.load(navigationAction.request)
        return nil
    }

    /// Waits 1 s of cookie quiet (ChatGPT sets its chunked session `.0`, `.1`… one by one), then proves
    /// the session with a real request before saving. Anything less keeps the window open.
    private func checkCookies() {
        pendingCheck?.cancel()
        pendingCheck = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, completion != nil else { return }
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                .filter { WebSession.applies($0, to: host) }
            let hasRequired = connector.requiredCookies.allSatisfy { required in
                cookies.contains { WebSession.matches($0.name, required: required) }
            }
            guard hasRequired,
                  await connector.validate(WebSession.headers(for: cookies)),
                  !Task.isCancelled, completion != nil else { return }
            finish((try? WebSession.save(cookies, id: connector.info.id)) != nil)
            window.close()
        }
    }

    // MARK: Teardown

    func windowWillClose(_ notification: Notification) { finish(false) }

    /// Runs once: success, or the user closed the window.
    private func finish(_ ok: Bool) {
        guard let completion else { return }
        self.completion = nil
        pendingCheck?.cancel()
        webView.configuration.websiteDataStore.httpCookieStore.remove(self)
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        completion(ok)
    }
}

/// An agent app may have no Edit menu, so ⌘C/⌘V (pasting a password) would never reach the web view.
private final class LoginWindow: NSWindow {
    private static let actions: [String: Selector] = [
        "c": #selector(NSText.copy(_:)),
        "v": #selector(NSText.paste(_:)),
        "x": #selector(NSText.cut(_:)),
        "a": #selector(NSResponder.selectAll(_:)),
        "z": Selector(("undo:")),
        "w": #selector(NSWindow.performClose(_:)),
    ]

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let action = Self.actions[event.charactersIgnoringModifiers ?? ""],
              NSApp.sendAction(action, to: nil, from: self)
        else { return super.performKeyEquivalent(with: event) }
        return true
    }
}
