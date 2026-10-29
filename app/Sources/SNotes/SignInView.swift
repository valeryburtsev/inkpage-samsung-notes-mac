import AppKit
import SamsungNotesKit
import SwiftUI
import WebKit

/// Samsung's own sign-in page in a web view. The password goes to Samsung only; the app takes
/// the page's final redirect, which carries a one-time code.
struct SignInView: View {
    @Environment(AppModel.self) private var model
    @State private var pending: SamsungAccount.Pending?
    @State private var problem: String?
    @State private var finishing = false
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Samsung account").font(.headline)
                    Text("account.samsung.com").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if loading || finishing { ProgressView().controlSize(.small).accessibilityLabel("Loading") }
                // Cancelling also gives up an exchange that is already under way.
                Button("Cancel") { model.cancelSignIn() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            // Said again where the account is given: this is not Samsung's own app.
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                Text("\(LocalStore.appName) is not made or approved by Samsung. Samsung Cloud sync is experimental and at your own risk.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Risks…") { SamsungRisks.show() }.buttonStyle(.link)
            }
            .padding(.horizontal, 18).padding(.bottom, 10)
            Divider()
            ZStack {
                if let pending, !finishing {
                    SignInWebView(url: pending.signInURL, loading: $loading) { redirect in
                        finishing = true
                        Task { await model.finishSignIn(redirect: redirect, pending: pending) }
                    }
                } else if finishing {
                    VStack(spacing: 12) { ProgressView(); Text("Finishing sign-in…").foregroundStyle(.secondary) }
                } else if let problem {
                    ContentUnavailableView("Could not open the sign-in page", systemImage: "wifi.exclamationmark", description: Text(problem))
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Never taller than the window the sheet hangs from.
        .frame(width: 520, height: min(720, max(440, (NSApp.mainWindow ?? NSApp.keyWindow)?.frame.height ?? 780) - 40))
        .task {
            let region = Locale.current.region?.identifier ?? "US"
            let language = Locale.current.language.languageCode?.identifier ?? "en"
            do { pending = try await model.account.beginSignIn(country: region, language: language) } catch { problem = AppModel.describe(error) }
        }
    }
}

private struct SignInWebView: NSViewRepresentable {
    let url: URL
    @Binding var loading: Bool
    let onRedirect: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        if Launch.flag("--debug-sign-in") {
            let script = "window.__snErrors = []; window.addEventListener('error', e => window.__snErrors.push(String(e.message) + ' @' + String(e.filename).split('/').pop() + ':' + e.lineno)); window.addEventListener('unhandledrejection', e => window.__snErrors.push('rejection: ' + String(e.reason))); const ce = console.error; console.error = (...a) => { window.__snErrors.push('console: ' + a.map(String).join(' ').slice(0, 200)); ce(...a); };"
            configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        // Should the page reach its return address in a way that skips the navigation delegate,
        // the address still ends up here.
        configuration.setURLSchemeHandler(context.coordinator, forURLScheme: SamsungAccount.redirectScheme)
        let view = WKWebView(frame: .zero, configuration: configuration)
        if !Launch.flag("--safari-agent") { view.customUserAgent = SamsungAccount.browserUserAgent } else { view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15" }
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKURLSchemeHandler {
        let parent: SignInWebView
        var finished = false
        init(_ parent: SignInWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            if let url = urlSchemeTask.request.url, SamsungAccount.isRedirect(url), !finished {
                finished = true
                parent.onRedirect(url)
            }
            urlSchemeTask.didFailWithError(URLError(.cancelled))
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }
            if SamsungAccount.isRedirect(url) {
                if !finished { finished = true; parent.onRedirect(url) }
                return .cancel
            }
            // Only web pages are shown here; anything else has no business in the sign-in.
            return ["https", "about", "blob"].contains(url.scheme?.lowercased() ?? "") ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { parent.loading = true }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loading = false
            guard Launch.flag("--debug-sign-in") else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                webView.evaluateJavaScript("document.title + ' | ' + location.host + location.pathname + ' | text=' + (document.body ? document.body.innerText.slice(0, 300).replace(/\\n/g, ' / ') : '') + ' | errors=' + JSON.stringify(window.__snErrors || []).slice(0, 900) + ' | root=' + (document.getElementById('root') ? document.getElementById('root').children.length : 'none')") { value, error in
                    FileHandle.standardError.write(Data("sign-in page: \(value ?? error ?? "nil")\n".utf8))
                }
                webView.takeSnapshot(with: nil) { image, _ in
                    guard let folder = Launch.value("--window-snapshot"), let tiff = image?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
                    try? png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("09-sign-in-web.png"))
                    FileHandle.standardError.write(Data("sign-in web snapshot \(image?.size ?? .zero) frame=\(webView.frame)\n".utf8))
                }
            }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { parent.loading = false }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.loading = false
            if Launch.flag("--debug-sign-in") { FileHandle.standardError.write(Data("sign-in load failed: \(error)\n".utf8)) }
        }

        /// Links that ask for a new window open in this one.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }
    }
}
