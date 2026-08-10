import SwiftUI
import WebKit

/// The JXProxy Remote control panel as a native WKWebView shell.
///
/// Point it at your Mac's JXProxy Remote Web Control port and sign in with
/// the proxy auth token (shown in JXProxy Settings → General).
///
/// Tip: in the iOS Simulator, `http://127.0.0.1:5355` reaches the host Mac
/// directly, so the default URL works out of the box. On a real device, use
/// your Mac's LAN IP (e.g. http://192.168.1.20:5355).
struct ContentView: View {
    @AppStorage("serverURL") private var urlString = "http://127.0.0.1:5355"
    @State private var editedURL = "http://127.0.0.1:5355"
    @State private var reloadToken = 0

    var body: some View {
        VStack(spacing: 0) {
            // Address bar
            HStack(spacing: 8) {
                TextField("http://mac-ip:5355", text: $editedURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(go)
                Button(action: go) {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 22))
                }
                Button(action: reload) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16))
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)

            WebView(url: URL(string: urlString), reloadToken: reloadToken)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private func go() {
        var value = editedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.lowercased().hasPrefix("http://"), !value.lowercased().hasPrefix("https://") {
            value = "http://\(value)"
        }
        urlString = value
        reload()
    }

    private func reload() {
        reloadToken += 1
    }
}

/// Minimal WKWebView wrapper. ATS allows arbitrary loads (LAN http) — see
/// Info.plist NSAppTransportSecurity.
struct WebView: UIViewRepresentable {
    let url: URL?
    let reloadToken: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.allowsBackForwardNavigationGestures = true
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard let url else { return }
        if webView.url != url || reloadToken != context.coordinator.lastToken {
            context.coordinator.lastToken = reloadToken
            webView.load(URLRequest(url: url))
        }
    }

    final class Coordinator {
        var lastToken = 0
    }
}

#Preview {
    ContentView()
}
