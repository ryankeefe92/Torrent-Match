import Foundation
#if canImport(WebKit)
import WebKit

@MainActor
final class WebViewHTMLLoader: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<String, Error>?
    private var webView: WKWebView?
    private var timeoutTask: Task<Void, Never>?

    func loadHTML(from url: URL, referer: URL? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .default()
            let webView = WKWebView(frame: .zero, configuration: configuration)
            webView.navigationDelegate = self
            webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"
            self.webView = webView

            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            if let referer {
                request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
            }

            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await self?.finish(with: ProviderError.accessBlocked(provider: "1337x", reason: "Web view load timed out"))
            }

            webView.load(request)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] value, error in
            Task { @MainActor in
                if let error {
                    self?.finish(with: error)
                    return
                }
                let html = value as? String ?? ""
                self?.finish(with: html)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            finish(with: error)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            finish(with: error)
        }
    }

    private func finish(with html: String) {
        guard let continuation else { return }
        cleanup()
        continuation.resume(returning: html)
    }

    private func finish(with error: Error) {
        guard let continuation else { return }
        cleanup()
        continuation.resume(throwing: error)
    }

    private func cleanup() {
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation = nil
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
    }
}
#endif
