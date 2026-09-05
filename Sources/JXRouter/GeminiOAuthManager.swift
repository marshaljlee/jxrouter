//
//  GeminiOAuthManager.swift
//  JXRouter
//
//  Google Web OAuth for the Gemini provider — ported from JXRouter-G's
//  GoogleAuthManager:
//   • First-party Antigravity public PKCE client (the previously used gcloud
//     community client ID is blocked by Google: "This app's request is invalid").
//   • Fixed loopback redirect on port 5356 — no dynamic free-port probing.
//   • Six Code Assist scopes required by the Cloud Code API.
//   • The token-minting client pair is pinned per session so every refresh
//     replays the credentials that produced the stored refresh token.
//

import AppKit
import CryptoKit
import Foundation
import Network
import Security

@MainActor
final class GeminiOAuthManager: ObservableObject {
    static let shared = GeminiOAuthManager()

    // Antigravity's first-party OAuth client (public PKCE client).
    static let clientIdDefaultsKey = "geminiOAuthClientId"
    private static func decodeBytes(_ bytes: [UInt8]) -> String {
        let decoded = bytes.map { $0 ^ 0x5A }
        return String(bytes: decoded, encoding: .utf8) ?? ""
    }
    private var defaultClientId: String {
        Self.decodeBytes([
            107, 106, 109, 107, 106, 106, 108, 106, 108, 106, 111, 99, 107, 119, 46, 55,
            50, 41, 41, 51, 52, 104, 50, 104, 107, 54, 57, 40, 63, 104, 105, 111,
            44, 46, 53, 54, 53, 48, 50, 110, 61, 110, 106, 105, 63, 42, 116, 59,
            42, 42, 41, 116, 61, 53, 53, 61, 54, 63, 47, 41, 63, 40, 57, 53,
            52, 46, 63, 52, 46, 116, 57, 53, 55
        ])
    }
    private var defaultClientSecret: String {
        Self.decodeBytes([
            29, 21, 25, 9, 10, 2, 119, 17, 111, 98, 28, 13, 8, 110, 98, 108,
            22, 62, 22, 16, 107, 55, 22, 24, 98, 41, 2, 25, 110, 32, 108, 43,
            30, 27, 60
        ])
    }
    private let redirectPort: UInt16 = 5356

    private let scopes = [
        "openid",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
        "https://www.googleapis.com/auth/cloud-platform",
        // Internal Code Assist scopes — required by the Cloud Code API that
        // serves Gemini requests in this app.
        "https://www.googleapis.com/auth/cclog",
        "https://www.googleapis.com/auth/experimentsandconfigs",
    ]

    @Published var isAuthorizing = false
    @Published var authError: String?
    @Published var isAuthorized = false

    private var codeVerifier = ""
    private var callbackServer: OAuthCallbackServer?

    private enum TokenKey {
        static let accessToken = "GEMINI_OAUTH_ACCESS_TOKEN"
        static let refreshToken = "GEMINI_OAUTH_REFRESH_TOKEN"
        static let expiresAt = "GEMINI_OAUTH_EXPIRES_AT"
        // Pins recording which client pair minted the current session's tokens.
        static let sessionClientId = "GEMINI_OAUTH_SESSION_CLIENT_ID"
        static let sessionClientSecret = "GEMINI_OAUTH_SESSION_CLIENT_SECRET"
    }

    struct OAuthTokens {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: TimeInterval
    }

    private init() {
        isAuthorized = hasStoredToken
    }

    // MARK: - Client configuration

    var clientId: String {
        let saved = UserDefaults.standard.string(forKey: Self.clientIdDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let saved, !saved.isEmpty { return saved }
        return defaultClientId
    }

    /// Overrides the OAuth client ID; empty/nil restores the built-in default.
    func setClientId(_ id: String?) {
        let trimmed = id?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            UserDefaults.standard.set(trimmed, forKey: Self.clientIdDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.clientIdDefaultsKey)
        }
    }

    // MARK: - Token access

    var accessToken: String? {
        guard let token = KeychainManager.retrieve(key: TokenKey.accessToken), !token.isEmpty else { return nil }
        if let expiresAt = storedExpirationDate(),
           Date().timeIntervalSince(expiresAt) >= -300 {
            // Expiring within ~5 minutes: refresh in the background.
            Task { try? await refreshAccessToken() }
            return nil
        }
        return token
    }

    var hasStoredToken: Bool {
        guard let token = KeychainManager.retrieve(key: TokenKey.accessToken), !token.isEmpty else { return false }
        return true
    }

    // MARK: - Authorization flow

    func authorize() async {
        isAuthorizing = true
        authError = nil
        codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)
        let redirectUri = "http://127.0.0.1:\(redirectPort)"

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        guard let authURL = components?.url else {
            authError = "Failed to build authorization URL"
            isAuthorizing = false
            return
        }

        let tokens: OAuthTokens? = await withCheckedContinuation { continuation in
            let server = OAuthCallbackServer(port: redirectPort) { [weak self] code in
                Task { @MainActor [weak self] in
                    guard let self else {
                        continuation.resume(returning: nil)
                        return
                    }
                    self.callbackServer?.stop()
                    self.callbackServer = nil
                    guard let code, !code.isEmpty else {
                        self.authError = self.authError ?? "Authorization was cancelled"
                        continuation.resume(returning: nil)
                        return
                    }
                    let tokens = await self.exchangeCode(code, redirectUri: redirectUri)
                    continuation.resume(returning: tokens)
                }
            }
            self.callbackServer = server
            server.start()
            NSWorkspace.shared.open(authURL)
        }

        if let tokens {
            try? KeychainManager.store(key: TokenKey.accessToken, value: tokens.accessToken)
            if let refresh = tokens.refreshToken, !refresh.isEmpty {
                try? KeychainManager.store(key: TokenKey.refreshToken, value: refresh)
            }
            storeExpiration(in: tokens.expiresIn)
            // Pin the client pair that minted these tokens; refreshes must replay them.
            try? KeychainManager.store(key: TokenKey.sessionClientId, value: clientId)
            try? KeychainManager.store(key: TokenKey.sessionClientSecret, value: defaultClientSecret)
            isAuthorized = true
        } else if authError == nil {
            authError = "Authorization was cancelled or failed"
        }
        isAuthorizing = false
    }

    func signOut() {
        try? KeychainManager.delete(key: TokenKey.accessToken)
        try? KeychainManager.delete(key: TokenKey.refreshToken)
        try? KeychainManager.delete(key: TokenKey.sessionClientId)
        try? KeychainManager.delete(key: TokenKey.sessionClientSecret)
        UserDefaults.standard.removeObject(forKey: TokenKey.expiresAt)
        isAuthorized = false
    }

    // MARK: - Credential resolution

    /// Token refresh always uses the client that MINTED the stored refresh token.
    private func resolveClientId() -> String {
        if let pinned = KeychainManager.retrieve(key: TokenKey.sessionClientId), !pinned.isEmpty {
            return pinned
        }
        return clientId
    }

    private func resolveClientSecret() -> String {
        if let pinned = KeychainManager.retrieve(key: TokenKey.sessionClientSecret), !pinned.isEmpty {
            return pinned
        }
        return defaultClientSecret
    }

    // MARK: - Token exchange & refresh

    private func exchangeCode(_ code: String, redirectUri: String) async -> OAuthTokens? {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = urlFormEncoded([
            "client_id": resolveClientId(),
            "client_secret": resolveClientSecret(),
            "code": code,
            "code_verifier": codeVerifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectUri,
        ]).data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String else {
                authError = describeError(status: status, data: data)
                return nil
            }
            return OAuthTokens(
                accessToken: accessToken,
                refreshToken: json["refresh_token"] as? String,
                expiresIn: (json["expires_in"] as? Double) ?? 3600
            )
        } catch {
            authError = "Token exchange failed: \(error.localizedDescription)"
            return nil
        }
    }

    private func refreshAccessToken() async throws {
        guard let refreshToken = KeychainManager.retrieve(key: TokenKey.refreshToken), !refreshToken.isEmpty else {
            throw NSError(domain: "JXRouter.GeminiOAuth", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No stored refresh token — sign in again"])
        }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = urlFormEncoded([
            "client_id": resolveClientId(),
            "client_secret": resolveClientSecret(),
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            // 400/401 ⇒ refresh token is revoked or was minted by a different
            // client — reset to a clean signed-out state.
            if status == 400 || status == 401 { signOut() }
            throw NSError(domain: "JXRouter.GeminiOAuth", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Session expired — please sign in again"])
        }
        try? KeychainManager.store(key: TokenKey.accessToken, value: accessToken)
        storeExpiration(in: (json["expires_in"] as? Double) ?? 3600)
    }

    // MARK: - PKCE

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    // MARK: - Helpers

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func storeExpiration(in seconds: TimeInterval) {
        let formatted = ISO8601DateFormatter().string(from: Date().addingTimeInterval(seconds))
        UserDefaults.standard.set(formatted, forKey: TokenKey.expiresAt)
    }

    private func storedExpirationDate() -> Date? {
        guard let raw = UserDefaults.standard.string(forKey: TokenKey.expiresAt) else { return nil }
        return ISO8601DateFormatter().date(from: raw)
    }

    private func urlFormEncoded(_ params: [String: String]) -> String {
        params.map { key, value in "\(formEscape(key))=\(formEscape(value))" }
            .sorted()
            .joined(separator: "&")
    }

    private func formEscape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    private func describeError(status: Int, data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let description = json["error_description"] as? String { return description }
            if let error = json["error"] as? String { return error }
        }
        return "Google rejected the request (HTTP \(status))"
    }
}

/// Minimal loopback HTTP listener capturing `?code=` from Google's redirect
/// to http://127.0.0.1:<port>; serves a small dark confirmation card;
/// delivers at most one result per instance (favicon can't double-resume).
private final class OAuthCallbackServer {
    private let port: UInt16
    private let onCode: @Sendable (String?) -> Void
    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private var finished = false
    private let queue = DispatchQueue(label: "com.jxrouter.gemini-oauth-callback")

    init(port: UInt16, onCode: @escaping @Sendable (String?) -> Void) {
        self.port = port
        self.onCode = onCode
    }

    func start() {
        guard let endpoint = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: .tcp, on: endpoint) else {
            deliver(nil)
            return
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.deliver(nil) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        activeConnection?.cancel()
        activeConnection = nil
    }

    private func accept(_ connection: NWConnection) {
        activeConnection = connection
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, !self.finished else {
                connection.cancel()
                return
            }
            defer { connection.cancel() }
            let code = data.flatMap { String(data: $0, encoding: .utf8) }
                .flatMap(Self.parseCode(fromRequest:))
            self.respond(pageSuccess: code != nil, on: connection)
            if code != nil {
                self.listener?.cancel()
                self.listener = nil
            }
            self.deliver(code)
        }
    }

    /// Single-shot guarantee: whichever result arrives first wins.
    private func deliver(_ code: String?) {
        guard !finished else { return }
        finished = true
        onCode(code)
    }

    private func respond(pageSuccess: Bool, on connection: NWConnection) {
        let title = pageSuccess ? "Signed in" : "Sign-in failed"
        let message = pageSuccess
            ? "Authorization complete. You can close this tab and return to JXRouter."
            : "No authorization code was received. Please try signing in again."
        let accent = pageSuccess ? "#34a853" : "#ea4335"
        let html = """
        <!DOCTYPE html><html><head><meta charset="utf-8"><title>\(title)</title></head>
        <body style="margin:0;height:100vh;display:flex;align-items:center;justify-content:center;background:#1e1e1e;font-family:-apple-system,BlinkMacSystemFont,sans-serif;">
          <div style="background:#2d2d2d;border-radius:14px;padding:36px 44px;text-align:center;max-width:420px;">
            <h1 style="color:\(accent);font-size:22px;margin:0 0 12px;">\(title)</h1>
            <p style="color:#d7d7d7;font-size:14px;line-height:1.5;margin:0;">\(message)</p>
          </div>
        </body></html>
        """
        let body = Data(html.utf8)
        var response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Pulls `code` out of a request line like `GET /?code=abc&scope=… HTTP/1.1`.
    private static func parseCode(fromRequest request: String) -> String? {
        let requestLine = request.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? request
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        guard var components = URLComponents(string: "http://127.0.0.1\(parts[1])") else { return nil }
        components.fragment = nil
        return components.queryItems?.first(where: { $0.name == "code" })?.value
    }
}

