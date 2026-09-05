import Foundation
@preconcurrency import Network

enum ProxyError: Error, LocalizedError {
    case portInUse(port: Int, pids: String)
    case listenerFailed(String)

    var errorDescription: String? {
        switch self {
        case .portInUse(let port, let pids):
            return "Port \(port) is in use by PID(s): \(pids). Click Restart to free it."
        case .listenerFailed(let detail):
            return "Listener failed: \(detail). Click Restart to try again."
        }
    }
}

/// A simple timeout error with a human-readable message.
struct TimeoutError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct ProxyStats: Sendable {
    var aiRouted: Int = 0
    var passthrough: Int = 0
    var blocked: Int = 0
    var errors: Int = 0
    var uptime: TimeInterval = 0
}

@Observable
final class ProxyServer: @unchecked Sendable {
    private var httpListener: NWListener?
    private let queue = DispatchQueue(label: "com.jxproxy.proxy", qos: .userInitiated)
    /// Classifier instance kept in sync with the "Route OpenAI connections"
    /// switch (see syncConfigCache) so gating is consistent on every code path.
    /// Lock protecting mutable state accessed from multiple queues (proxy
    /// queue writes, MainActor reads). Using os_unfair_lock for the hot-path
    /// stats counters — it's the cheapest synchronization primitive on macOS.
    private let stateLock = NSLock()

    var isRunning = false
    var port: UInt16 = 5255
    var authToken: String = "jxproxy"
    private var _stats = ProxyStats()

    /// Thread-safe access to proxy stats. Reads/writes are serialized via
    /// stateLock so the proxy queue (writer) and MainActor (reader) never
    /// race on the same counters.
    var stats: ProxyStats {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _stats
        }
        set {
            stateLock.lock()
            defer { stateLock.unlock() }
            _stats = newValue
        }
    }

    /// Thread-safe in-place mutation of stats counters.
    private func mutateStats(_ mutate: (inout ProxyStats) -> Void) {
        stateLock.lock()
        defer { stateLock.unlock() }
        mutate(&_stats)
    }

    var connectedApps: [String] = []
    var onTrafficEntry: ((TrafficEntry) -> Void)?
    /// Called once routing completes for a routed request — reports which
    /// upstream provider served it and whether a fallback was used.
    var onTrafficServed: ((UUID, String?, Bool) -> Void)?

    /// In-process provider router (replaces external jxproxy-proxy binary).
    var providerRouter: ProviderRouter?

    /// Direct TLS handler for DNS-redirected AI API traffic.
    /// Listens on port+1 (e.g. 5256) with TLS terminated via multi-domain cert.
    private var directTLSHandler: DirectTLSHandler?

    /// Sweeps leftover DNS-hijack state written by OLD app versions
    /// (/etc/hosts blocks + pf anchor). The app itself never installs DNS
    /// redirection anymore — see DNSRedirectionManager.
    private let dnsManager = DNSRedirectionManager.shared

    /// Error state for UI propagation.
    var lastError: String?

    /// Cached config values for nonisolated access (updated via syncConfigCache).
    /// Access is serialized behind stateLock: syncConfigCache() runs on the
    /// MainActor while connection handlers read these on the proxy queue —
    /// unsynchronized access was a data race on String/Set payloads.
    private var _cachedProvider: String = "jxproxy"
    private var _cachedModelOpus: String = "claude-opus-4-8-20250701"
    private var _cachedModelSonnet: String = "claude-sonnet-5-20251001"
    private var _cachedModelHaiku: String = "claude-haiku-4-5-20251001"
    private var _cachedMitmHosts: Set<String> = ["api.anthropic.com"]
    private var _classifier = RequestClassifier()

    /// Thread-safe snapshot of the cached config for proxy-queue readers.
    private struct ConfigSnapshot {
        var provider: String
        var modelOpus: String
        var modelSonnet: String
        var modelHaiku: String
        var mitmHosts: Set<String>
        var classifier: RequestClassifier
    }

    private func configSnapshot() -> ConfigSnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        return ConfigSnapshot(
            provider: _cachedProvider,
            modelOpus: _cachedModelOpus,
            modelSonnet: _cachedModelSonnet,
            modelHaiku: _cachedModelHaiku,
            mitmHosts: _cachedMitmHosts,
            classifier: _classifier
        )
    }

    /// Sync cached config values from ConfigManager (call from MainActor).
    func syncConfigCache() {
        let provider = ConfigManager.shared.provider
        let modelOpus = ConfigManager.shared.modelOpus
        let modelSonnet = ConfigManager.shared.modelSonnet
        let modelHaiku = ConfigManager.shared.modelHaiku
        var mitmHosts = ConfigManager.shared.mitmHosts
        let routeOpenAI = ConfigManager.shared.routeOpenAI
        let classifier = RequestClassifier(routeOpenAI: routeOpenAI)

        // "Route OpenAI connections" switch: keep the classifier and the
        // CONNECT-intercept host set in sync so api.openai.com is left alone
        // when the user turns OpenAI routing off.
        if !routeOpenAI {
            mitmHosts = mitmHosts.filter { !RequestClassifier.isOpenAIHost($0) }
        }

        stateLock.lock()
        defer { stateLock.unlock() }
        _cachedProvider = provider
        _cachedModelOpus = modelOpus
        _cachedModelSonnet = modelSonnet
        _cachedModelHaiku = modelHaiku
        _cachedMitmHosts = mitmHosts
        _classifier = classifier
    }


    /// Read-only passthrough for the cached provider name (thread-safe).
    var cachedProvider: String { configSnapshot().provider }

    /// Whether auth enforcement is enabled.
    var authEnabled: Bool {
        !authToken.isEmpty
    }

    /// Watchdog timer that auto-restarts the proxy if unresponsive.
    private var watchdogTask: Task<Void, Never>?
    private let watchdogInterval: TimeInterval = 5.0
    private var watchdogFailCount: Int = 0
    private let maxWatchdogFailures: Int = 1

    /// If true, stop() was called by the user — don't auto-restart.
    private var userInitiatedStop = false
    /// Counter to prevent infinite auto-restart loops.
    private var autoRestartCount = 0
    /// Unexpected-listener-death restarts this session (NOT reset by start()).
    private var unexpectedRestarts = 0
    private let maxAutoRestarts = 10

    private var activeConnections: [UUID: NWConnection] = [:]
    private var appConnectionCounts: [String: Int] = [:]

    // MARK: - Start / Stop

    func start(port: UInt16) throws {
        self.port = port
        syncConfigCache()
        let params = NWParameters.tcp
        // Security: accept connections from loopback only. All bundled launchers,
        // install scripts, and docs point clients at http://127.0.0.1:<port>.
        // Port 0 in the local endpoint (the real port lives in the `on:` argument)
        // keeps the bind loopback-only; a specific port here makes NWListener
        // throw EINVAL on creation.
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 0)

        userInitiatedStop = false
        autoRestartCount = 0

        // Pre-flight check: make sure no other process is holding the port.
        // NWListener won't throw on a busy port — it fails asynchronously,
        // so we check synchronously here to give the caller an immediate error.
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        check.arguments = ["-ti", ":\(port)", "-sTCP:LISTEN"]
        let checkPipe = Pipe()
        check.standardOutput = checkPipe
        check.standardError = Pipe()
        do {
            try check.run()
            check.waitUntilExit()
        } catch {
            print("[ProxyServer] Pre-flight lsof check could not run: \(error)")
        }
        let checkData = checkPipe.fileHandleForReading.readDataToEndOfFile()
        let pids = String(data: checkData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !pids.isEmpty {
            throw ProxyError.portInUse(port: Int(port), pids: pids)
        }

        // Start HTTP proxy listener — throws synchronously if params are invalid,
        // async failure (port conflict) is caught by the state handler above.
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw ProxyError.listenerFailed("Invalid port: \(port)")
        }
        httpListener = try NWListener(using: params, on: nwPort)
        httpListener?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isRunning = true
                    self.lastError = nil
                    self.startWatchdog()
                case .failed(let error):
                    self.isRunning = false
                    let msg = "Proxy listener failed: \(error.localizedDescription)"
                    self.lastError = msg
                    print("[ProxyServer] \(msg)")
                    if !self.userInitiatedStop { self.scheduleAutoRestart() }
                case .cancelled:
                    self.isRunning = false
                    self.stopWatchdog()
                    if !self.userInitiatedStop { self.scheduleAutoRestart() }
                default:
                    break
                }
            }
        }

        httpListener?.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            connection.start(queue: self.queue)
            self.receiveFirstPacket(connection)
        }

        httpListener?.start(queue: queue)

        // Start DirectTLS handler on background thread (don't block menubar)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.startDirectTLS()
        }

        print("[ProxyServer] HTTP proxy started on port \(port)")
    }

    func stop() {
        userInitiatedStop = true
        stopWatchdog()

        // Stop HTTP proxy listener
        httpListener?.cancel()
        httpListener = nil

        // Stop DirectTLS listener
        stopDirectTLS()

        // Sweep leftover DNS-hijack state from old app versions. No-op (and
        // no admin prompt) when the system is already clean.
        dnsManager.uninstall()

        isRunning = false

        // Cancel all active connections
        for (_, conn) in activeConnections {
            conn.cancel()
        }
        activeConnections.removeAll()
        connectedApps.removeAll()
        appConnectionCounts.removeAll()

        print("[ProxyServer] Stopped")
    }

    /// Reset internal state after a recovery / restart.
    /// Clears error flags, restart counters, and any stale state.
    func resetForRestart() {
        lastError = nil
        userInitiatedStop = false
        autoRestartCount = 0
        unexpectedRestarts = 0
        activeConnections.removeAll()
        connectedApps.removeAll()
        appConnectionCounts.removeAll()
        stats = ProxyStats()
        print("[ProxyServer] Reset for restart")
    }

    /// Clear the unexpected-death auto-restart cap. Called on USER-initiated
    /// starts (Settings / menu-bar / web control): a user explicitly asking for
    /// the proxy to run resets the failure budget, so a fresh transient failure
    /// after their action still gets the bounded auto-restarts. start() itself
    /// must NOT reset this (scheduleAutoRestart calls start() and would defeat
    /// its own cap).
    func resetUnexpectedRestartCount() {
        unexpectedRestarts = 0
    }

    // MARK: - Direct TLS + DNS Management

    private func startDirectTLS() {
        directTLSHandler = DirectTLSHandler(providerRouter: providerRouter)
        let tlsPort = port + 1
        guard directTLSHandler?.start(port: tlsPort) == true else {
            print("[ProxyServer] Failed to start DirectTLS handler on port \(tlsPort)")
            return
        }
        print("[ProxyServer] DirectTLS handler started on port \(tlsPort)")
    }

    private func stopDirectTLS() {
        directTLSHandler?.stop()
        directTLSHandler = nil
    }

    // MARK: - Auto-Restart

    /// Bounded best-effort restart when the listener dies unexpectedly. A single
    /// transient listener failure (port race, kernel hiccup) must never leave
    /// the proxy dead until the user manually restarts — that silent death is
    /// what makes Claude Code report "cannot connect" while the app process is
    /// still running. Older builds disabled this to avoid osascript prompt
    /// loops; this app never prompts, and the counter is capped so it cannot
    /// loop forever. `unexpectedRestarts` is deliberately NOT reset by start()
    /// (start() resets autoRestartCount), so the cap is a true per-session cap.
    private func scheduleAutoRestart() {
        guard unexpectedRestarts < 3 else {
            print("[ProxyServer] Auto-restart cap reached (3) — proxy stays stopped; click Restart")
            return
        }
        unexpectedRestarts += 1
        let delay = Double(unexpectedRestarts) * 2.0
        print("[ProxyServer] Listener died unexpectedly — auto-restart \(unexpectedRestarts)/3 in \(delay)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            // Never clobber a proxy that a user action or earlier restart
            // already brought back up.
            guard !self.isRunning else { return }
            print("[ProxyServer] Auto-restarting listener on port \(self.port)")
            try? self.start(port: self.port)
        }
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        // Disabled to prevent infinite osascript prompt loops
    }

    private func stopWatchdog() {
        // Disabled
    }

    private func checkWatchdog() async throws {
        let checkPort = port
        let token = authToken
        guard let url = URL(string: "http://127.0.0.1:\(checkPort)/health") else { return }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5.0
            request.setValue(token, forHTTPHeaderField: "x-api-key")
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                watchdogFailCount = 0
            } else {
                watchdogFailCount += 1
            }
        } catch {
            watchdogFailCount += 1
        }

        if watchdogFailCount >= maxWatchdogFailures {
            lastError = "Proxy watchdog: auto-restarting (unresponsive after \(maxWatchdogFailures) checks)"
            print("[Watchdog] Proxy unresponsive — auto-restarting")
            stop()
            try? start(port: port)
        }
    }

    /// Decode ONLY the header block (up to and including CRLFCRLF) of a
    /// possibly-truncated first packet. The 64KB receive cap can cut a
    /// multi-byte UTF-8 character in the body in half, so decoding the whole
    /// buffer as UTF-8 must never be done — headers are ASCII and complete.
    private func decodeHeaders(from initialData: Data) -> String? {
        guard let range = initialData.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        return String(data: initialData[initialData.startIndex..<range.upperBound], encoding: .utf8)
    }

    // MARK: - Connection Handling

    private func receiveFirstPacket(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self = self, let data = data, error == nil else {
                connection.cancel()
                return
            }
            self.receiveRequestHeaders(connection, accumulated: data)
        }
    }

    /// Accumulate inbound bytes until the COMPLETE header block (terminated by
    /// CRLF CRLF) has arrived, then hand everything to processRequest.
    ///
    /// The first TCP segment frequently carries only PART of the request line
    /// + headers (real clients like Claude Code send large headers and bodies
    /// that span segments). Processing the first packet immediately made the
    /// parser see a partial header block: handleAIMessages returned
    /// "400 Bad Request" with an EMPTY body — which Claude Code reports as
    /// "API Error: 400 InvalidHTTPResponse" — and other paths silently dropped
    /// the connection ("POST /v1/" doesn't match the "POST " prefix check).
    /// The header terminator is the point where parsing is guaranteed correct.
    private func receiveRequestHeaders(_ connection: NWConnection, accumulated: Data) {
        let headerEnd = Data("\r\n\r\n".utf8)
        if accumulated.range(of: headerEnd) != nil {
            processRequest(connection, initialData: accumulated)
            return
        }
        guard accumulated.count < 65536 else {
            // Header block never terminated (or absurdly large) — drop it.
            connection.cancel()
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self = self, let data = data, error == nil else {
                connection.cancel()
                return
            }
            self.receiveRequestHeaders(connection, accumulated: accumulated + data)
        }
    }

    private func processRequest(_ connection: NWConnection, initialData: Data) {
        // Decode ONLY the header block (up to and including CRLFCRLF). The body
        // inside the first packet can be truncated mid-multibyte-UTF-8 at the
        // 64KB receive cap — decoding the whole buffer as UTF-8 then fails
        // whenever a multi-byte character straddles that boundary, which used to
        // reset the connection (or send an empty-body 400) and made Claude Code
        // report "API Error: 400 InvalidHTTPResponse" on real conversations.
        guard let requestStr = decodeHeaders(from: initialData) else {
            sendHttpResponse(connection, statusCode: 400, message: "Bad Request")
            return
        }

        // Identify the app making the connection
        var connectedApp = "Unknown"
        var ruleAction: RouteAction? = nil
        
        // Network.framework endpoint handling
        let endpointString = connection.endpoint.debugDescription
        // usually format is "127.0.0.1:54321" or "[::1]:54321"
        if let portStr = endpointString.components(separatedBy: ":").last, let sourcePort = UInt16(portStr) {
            if let appInfo = AppIdentifier.identifyApp(sourcePort: sourcePort) {
                connectedApp = appInfo.name
                
                // Track connected apps
                Task { @MainActor in
                    if !self.connectedApps.contains(appInfo.name) {
                        self.connectedApps.append(appInfo.name)
                        self.appConnectionCounts[appInfo.name] = 1
                    } else {
                        self.appConnectionCounts[appInfo.name, default: 0] += 1
                    }
                }
                
                // Check app rules
                let rulesJSON = ConfigManager.shared.appRoutesJSON
                if !rulesJSON.isEmpty, let data = rulesJSON.data(using: .utf8),
                   let rules = try? JSONDecoder().decode([AppRouteRule].self, from: data) {
                    if let matchingRule = rules.first(where: { $0.appName == appInfo.name || $0.bundleIdentifier == appInfo.bundleIdentifier }) {
                        if matchingRule.enabled {
                            ruleAction = matchingRule.action
                        }
                    }
                }
            }
        }
        
        // If the rule says block, drop it immediately.
        if ruleAction == .block {
            print("[ProxyServer] Blocked connection from \(connectedApp) due to AppRouteRule")
            sendHttpResponse(connection, statusCode: 403, message: "Blocked by JXProxy App Rule")
            updateStats(for: "local", action: .block)
            return
        }

        // CONNECT tunnels are transparent proxy traffic
        if requestStr.hasPrefix("CONNECT ") {
            let entry = TrafficEntry(
                timestamp: Date(),
                host: "CONNECT Tunnel",
                action: ruleAction ?? .passthrough,
                method: "CONNECT",
                url: requestStr.components(separatedBy: " ").dropFirst().first ?? "",
                appProcessName: connectedApp != "Unknown" ? connectedApp : nil,
                duration: nil
            )
            Task { @MainActor in self.onTrafficEntry?(entry) }
            
            handleConnect(connection, request: requestStr, initialData: initialData, ruleAction: ruleAction)
            return
        }

        // Auth enforcement on direct HTTP calls — scoped to the internal
        // endpoints and AI-routed hosts only. Plain-HTTP requests to any OTHER
        // site pass through the system proxy untouched (no token needed), so
        // the proxy never interferes with non-AI traffic. Hosts a per-app rule
        // forces to pass through (e.g. Pass Through OpenAI for Codex) are
        // exempt — they're not being routed, so no token is needed.
        if authEnabled {
            let requestHost = requestTargetHost(requestStr)
            let isInternal = requestHost == "127.0.0.1" || requestHost == "localhost"
            let snap = configSnapshot()
            let isAI = snap.classifier.isKnownAiHost(requestHost)
            if (isInternal || isAI), !ruleForcesPassthrough(ruleAction, host: requestHost) {
                let authResult = validateAuth(request: requestStr)
                switch authResult {
                case .denied(let reason):
                    sendHttpResponse(connection, statusCode: 401, message: reason)
                    return
                case .allowed:
                    break
                }
            }
        }

        if requestStr.hasPrefix("GET ") || requestStr.hasPrefix("POST ") ||
           requestStr.hasPrefix("PUT ") || requestStr.hasPrefix("DELETE ") ||
           requestStr.hasPrefix("PATCH ") || requestStr.hasPrefix("HEAD ") ||
           requestStr.hasPrefix("OPTIONS ") {
            handleHttp(connection, request: requestStr, initialData: initialData, ruleAction: ruleAction, connectedApp: connectedApp)
        } else {
            connection.cancel()
        }
    }

    // MARK: - Auth Enforcement

    private enum AuthResult {
        case allowed
        case denied(String)
    }

    private func validateAuth(request: String) -> AuthResult {
        guard authEnabled else { return .allowed }

        let lines = request.components(separatedBy: "\r\n")
        if let firstLine = lines.first {
            // Exempt only an exact /api/hello request target (origin-form or absolute-form).
            let targetParts = firstLine.components(separatedBy: " ")
            if targetParts.count >= 2 {
                let target = targetParts[1]
                let path: String
                if target.hasPrefix("http://") || target.hasPrefix("https://") {
                    path = URL(string: target)?.path ?? target
                } else {
                    path = target.components(separatedBy: "?").first ?? target
                }
                if path == "/api/hello" {
                    return .allowed
                }
            }
        }

        let headers = parseHeaders(from: request)
        let xApiKey = headers["x-api-key"]
        let authHeader = headers["authorization"]
        let bearerToken = authHeader.flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil }

        let provided = xApiKey ?? bearerToken
        guard let provided, constantTimeEquals(provided, authToken) else {
            return .denied("Invalid or missing auth token")
        }
        return .allowed
    }

    /// Constant-time string comparison: fixed loop over the longer length,
    /// XOR-accumulates every byte pair, no early exit on mismatch.
    private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        let length = max(aBytes.count, bBytes.count)
        var diff = UInt8(aBytes.count ^ bBytes.count)
        for i in 0..<length {
            let aByte = i < aBytes.count ? aBytes[i] : 0
            let bByte = i < bBytes.count ? bBytes[i] : 0
            diff |= aByte ^ bByte
        }
        return diff == 0
    }

    private func parseHeaders(from request: String) -> [String: String] {
        HTTPUtils.parseHeaders(from: request)
    }

    /// Extract the target host from an origin-form or absolute-form request
    /// line. Used to scope auth enforcement to internal endpoints and AI hosts.
    private func requestTargetHost(_ request: String) -> String {
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return "" }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return "" }
        let target = parts[1]
        if target.hasPrefix("http://") || target.hasPrefix("https://") {
            return URL(string: target)?.host ?? ""
        }
        return parseHeaders(from: request)["host"]?
            .split(separator: ":").first.map(String.init) ?? ""
    }

    // MARK: - HTTP Proxy Handler

    private func handleHttp(_ connection: NWConnection, request: String, initialData: Data, ruleAction: RouteAction?, connectedApp: String) {
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            connection.cancel()
            return
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            connection.cancel()
            return
        }

        let method = parts[0]
        let urlStr = parts[1]

        // Parse URL
        let url: URL
        let host: String
        let path: String
        let scheme: String

        if urlStr.hasPrefix("http://") || urlStr.hasPrefix("https://") {
            guard let parsed = URL(string: urlStr), let h = parsed.host, let s = parsed.scheme else {
                connection.cancel()
                return
            }
            url = parsed
            host = h
            path = url.path.isEmpty ? "/" : url.path
            scheme = s
        } else {
            let headers = parseHeaders(from: request)
            host = headers["host"] ?? "127.0.0.1"
            path = urlStr
            scheme = "http"
            let full = "http://\(host)\(path)"
            guard let parsed = URL(string: full) else {
                connection.cancel()
                return
            }
            url = parsed
        }

        let port: UInt16
        if let explicitPort = url.port {
            port = UInt16(explicitPort)
        } else {
            port = (scheme == "https") ? 443 : 80
        }

        // Check if this is an internal JXProxy endpoint
        let hostWithoutPort = host.split(separator: ":").first.map(String.init) ?? host
        // Strip query string from path for endpoint matching
        let basePath = path.components(separatedBy: "?").first ?? path
        if hostWithoutPort == "127.0.0.1" || hostWithoutPort == "localhost" {
            if basePath == "/admin" || basePath == "/admin/" {
                handleAdminEndpoint(connection)
                return
            }
            if basePath == "/health" || basePath == "/" {
                handleHealthEndpoint(connection)
                return
            }
            if basePath == "/api/hello" {
                handleHelloEndpoint(connection)
                return
            }
            if basePath == "/v1/models" {
                handleModelListEndpoint(connection)
                return
            }
            if basePath.hasPrefix("/v1/models/") {
                handleModelDetailEndpoint(connection, path: basePath)
                return
            }
            if basePath == "/v1/messages" || basePath == "/v1/v1/messages" || basePath == "/messages"
                || basePath == "/v1/chat/completions" || basePath == "/v1/v1/chat/completions" || basePath == "/chat/completions"
                || basePath == "/v1/responses" || basePath == "/v1/v1/responses" || basePath == "/responses" {
                // Loopback AI requests (Claude Code's /v1/messages, OpenAI
                // clients pointed at OPENAI_BASE_URL=http://127.0.0.1:<port>/v1
                // → /v1/chat/completions or /v1/responses) all route through
                // the provider chain. Previously only /v1/messages was
                // special-cased, so OpenAI loopback requests fell through to a
                // dead passthrough (127.0.0.1:80) and failed.
                handleAIRouted(connection, method: method, initialData: initialData, connectedApp: connectedApp, path: basePath)
                return
            }
        }

        // Override action if an app-specific rule exists: a "Pass Through"
        // rule bypasses everything, and "Pass Through OpenAI" bypasses OpenAI
        // hosts only (even when the global Route OpenAI switch is on) while
        // every other host still classifies normally.
        let snap = configSnapshot()
        let finalAction: RouteAction
        if let ruleAction = ruleAction {
            if ruleAction == .passthrough {
                finalAction = .passthrough
            } else if ruleAction == .passThroughOpenAI, RequestClassifier.isOpenAIHost(host) {
                finalAction = .passthrough
            } else {
                finalAction = snap.classifier.classify(host: host)
            }
        } else {
            finalAction = snap.classifier.classify(host: host)
        }
        
        updateStats(for: host, action: finalAction)
        
        let entry = TrafficEntry(
            timestamp: Date(),
            host: host,
            action: finalAction,
            method: method,
            url: path,
            appProcessName: connectedApp != "Unknown" ? connectedApp : nil,
            duration: nil
        )
        Task { @MainActor in
            self.onTrafficEntry?(entry)
        }

        switch finalAction {
        case .routeAI:
            routeViaProviderRouter(connection, initialData: initialData, host: host, port: port, entryId: entry.id)
        case .passthrough, .passThroughOpenAI:
            forwardDirectly(connection, initialData: initialData, host: host, port: port)
        case .block:
            sendHttpResponse(connection, statusCode: 403, message: "Blocked by JXProxy")
        }
    }

    // MARK: - Internal Endpoints

    private func handleAdminEndpoint(_ connection: NWConnection) {
        let total = stats.aiRouted + stats.passthrough
        let cfg = ConfigManager.shared
        let body = """
        <html><body style="background:#131517;color:#F3F4F6;font-family:system-ui;padding:2rem">
        <h1>JXProxy</h1>
        <p>Status: ✅ Running</p>
        <p>Provider: \(cfg.provider)</p>
        <p>Model: \(cfg.model)</p>
        <p>Port: \(cfg.port)</p>
        <p>Uptime: \(Int(stats.uptime))s</p>
        <p>Requests: \(total)</p>
        <p><a href="/health" style="color:#1A73E8">/health</a></p>
        </body></html>
        """
        let response = """
        HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.data(using: .utf8)?.count ?? 0)\r\nConnection: close\r\n\r\n\(body)
        """
        guard let data = response.data(using: .utf8) else {
            connection.cancel()
            return
        }
        connection.send(content: data, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }

    private func handleHelloEndpoint(_ connection: NWConnection) {
        let body = """
        {"status":"ok","provider":"\(cachedProvider)","version":"1.0.0"}
        """
        let response = """
        HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\nProxy-Agent: JXProxy\r\n\r\n\(body)
        """
        guard let data = response.data(using: .utf8) else {
            connection.cancel()
            return
        }
        connection.send(content: data, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }

    private func handleHealthEndpoint(_ connection: NWConnection) {
        let provider = cachedProvider
        let body = """
        {"status":"ok","provider":"\(provider)","version":"1.0.0"}
        """
        let response = """
        HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\nProxy-Agent: JXProxy\r\n\r\n\(body)
        """
        guard let data = response.data(using: .utf8) else {
            connection.cancel()
            return
        }
        connection.send(content: data, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }

    private func handleModelListEndpoint(_ connection: NWConnection) {
        let cfg = ConfigManager.shared

        // Only models the user can actually reach — see
        // ConfigManager.accessibleModels(). Previously every preset model from
        // every provider was listed, so Claude Code's /model picker showed
        // dozens of models the user has no access to.
        let models: [[String: Any]] = cfg.accessibleModels().map { entry in
            // Anthropic SDK requires type: "model", not object: "model"
            ["id": entry.id, "type": "model", "display_name": entry.id, "created_at": Date().ISO8601Format()]
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["type": "list", "data": models])) ?? Data()
        let body = String(data: data, encoding: .utf8) ?? "[]"
        let response = """
        HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\nProxy-Agent: JXProxy\r\n\r\n\(body)
        """
        guard let respData = response.data(using: .utf8) else {
            connection.cancel()
            return
        }
        connection.send(content: respData, completion: .contentProcessed({ _ in connection.cancel() }))
    }

    /// Handle GET /v1/models/{model_id} — return model details with context window.
    /// Claude Code queries this to determine token limits before sending prompts.
    private func handleModelDetailEndpoint(_ connection: NWConnection, path: String) {
        let modelId = path.replacingOccurrences(of: "/v1/models/", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Return model details with a generous context window (200K tokens)
        // so Claude Code doesn't reject prompts as "too long"
        let modelInfo: [String: Any] = [
            "id": modelId,
            "type": "model",
            "display_name": modelId,
            "created_at": Date().ISO8601Format(),
            "capabilities": [
                "context_window": 200000,
                "max_output_tokens": 4096,
                "supports_vision": true,
                "supports_streaming": true
            ],
            "permission": [
                "allow_create_engine": false,
                "allow_sampling": true,
                "allow_logprobs": true,
                "allow_search_indices": false,
                "allow_view": true,
                "allow_fine_tuning": false
            ]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: modelInfo)) ?? Data()
        let body = String(data: data, encoding: .utf8) ?? "{}"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\nProxy-Agent: JXProxy\r\n\r\n\(body)"
        guard let respData = response.data(using: .utf8) else {
            connection.cancel()
            return
        }
        connection.send(content: respData, completion: .contentProcessed({ _ in connection.cancel() }))
    }

    private func handleAIRouted(_ connection: NWConnection, method: String, initialData: Data, connectedApp: String, path: String) {
        if method == "HEAD" || method == "OPTIONS" {
            let response = "HTTP/1.1 204 No Content\r\nAllow: POST, HEAD, OPTIONS\r\nProxy-Agent: JXProxy\r\n\r\n"
            guard let data = response.data(using: .utf8) else { connection.cancel(); return }
            connection.send(content: data, completion: .contentProcessed({ _ in connection.cancel() }))
            return
        }

        // Loopback AI traffic (Claude Code, OpenAI-compatible clients) — log it
        // like any other routed request so the Logs tab shows it too.
        let entry = TrafficEntry(
            timestamp: Date(),
            host: "127.0.0.1",
            action: .routeAI,
            method: method,
            url: path,
            appProcessName: connectedApp != "Unknown" ? connectedApp : nil,
            duration: nil
        )
        Task { @MainActor in self.onTrafficEntry?(entry) }

        // Decode the header block only — the first packet's body may end
        // mid-multibyte-UTF-8 at the 64KB receive cap, and decoding the whole
        // buffer used to send an empty-body 400 ("400 InvalidHTTPResponse" in
        // Claude Code) whenever a multi-byte character straddled that boundary.
        guard let requestStr = decodeHeaders(from: initialData) else {
            sendHttpResponse(connection, statusCode: 400, message: "Bad Request")
            return
        }

        // Parse headers to find Content-Length
        let headers = parseHeaders(from: requestStr)
        let contentLength = headers["content-length"].flatMap { Int($0) } ?? 0

        // Split at the header/body boundary (byte-accurate)
        let separator = Data("\r\n\r\n".utf8)
        guard let separatorRange = initialData.range(of: separator) else {
            sendHttpResponse(connection, statusCode: 400, message: "Bad Request")
            return
        }
        let initialBodyData = initialData[separatorRange.upperBound...]
        let remainingBytes = contentLength - initialBodyData.count

        let router = self.providerRouter

        // Create the main request task so we can cancel it on timeout.
        let requestTask = Task { [connection] in
            do {
                var bodyData = Data(initialBodyData)

                // FIX #1: Body accumulation with 30-second timeout.
                // Previously this loop had NO timeout — a Content-Length mismatch
                // by even 1 byte caused an indefinite block.
                if remainingBytes > 0 {
                    var bytesLeft = remainingBytes
                    let readDeadline = DispatchTime.now() + 30
                    while bytesLeft > 0 {
                        try Task.checkCancellation()
                        let chunkSize = min(bytesLeft, 65536)
                        let chunkData = try waitForBody(connection: connection, maxLength: chunkSize, deadline: readDeadline)
                        bodyData.append(chunkData)
                        bytesLeft -= chunkData.count
                        if chunkData.isEmpty { break }
                    }
                }

                try Task.checkCancellation()
                let response = try await router?.route(
                    method: method,
                    path: path,
                    headers: headers,
                    body: bodyData
                )

                guard let response else {
                    sendHttpResponse(connection, statusCode: 502, message: "Provider Router unavailable")
                    return
                }

                // Report which upstream provider served the request.
                if let serving = response.servingProvider {
                    let entryId = entry.id
                    let usedFallback = response.usedFallback
                    Task { @MainActor in self.onTrafficServed?(entryId, serving, usedFallback) }
                }

                let statusLine = "HTTP/1.1 \(response.statusCode) \(statusText(response.statusCode))\r\n"
                var headerString = statusLine
                for (key, value) in response.headers {
                    headerString += "\(key): \(value)\r\n"
                }
                if response.stream == nil {
                    // Framing: a body without Content-Length/TE must be delimited
                    // by connection close — state it explicitly so clients never
                    // misparse a JSON error as an "InvalidHTTPResponse".
                    headerString += "Content-Length: \(response.body.count)\r\n"
                    headerString += "Connection: close\r\n"
                }
                headerString += "\r\n"

                guard let headerData = headerString.data(using: .utf8) else {
                    connection.cancel()
                    return
                }

                if let stream = response.stream {
                    // Streaming SSE: send headers, then pump chunks.
                    sendWithWatchdog(connection, data: headerData) { _ in
                        Task {
                            for await chunk in stream {
                                guard !chunk.isEmpty else { continue }
                                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                                    connection.send(content: chunk, completion: .contentProcessed({ _ in
                                        cont.resume()
                                    }))
                                }
                            }
                            connection.cancel()
                        }
                    }
                } else {
                    // Non-streaming: headers + body in ONE atomic send. The old
                    // two-stage send (headers, then body) could stall between
                    // stages and leave the client hanging with 0 bytes received
                    // — which is exactly what Claude Code reported as "cannot
                    // connect" every time the router returned a 503 after the
                    // fallback chain was exhausted. A single payload guarantees
                    // the client sees a complete, framable response, and the
                    // watchdog below guarantees the connection is torn down
                    // even if the send completion never fires.
                    var payload = headerData
                    payload.append(response.body)
                    sendWithWatchdog(connection, data: payload) { _ in
                        connection.cancel()
                    }
                }
            } catch is CancellationError {
                // Task was cancelled by the total-request timeout
                sendHttpResponse(connection, statusCode: 504, message: "Request timed out")
            } catch let error as TimeoutError {
                sendHttpResponse(connection, statusCode: 504, message: error.message)
            } catch {
                sendHttpResponse(connection, statusCode: 502, message: "Upstream error")
            }
        }

        // FIX #2: total-request timeout. Sized so a large local prefill (60k+
        // tokens can take 30s–4min on a local model) completes instead of being
        // cancelled mid-generation; the router's own chain caps are tighter.
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000_000)
            requestTask.cancel()
        }
    }

    /// Send a response payload and GUARANTEE the connection is torn down even
    /// if NWConnection never invokes the send completion (a wedged send would
    /// otherwise leave the client waiting with zero bytes until its own
    /// timeout). The completion fires at most once — on the real send
    /// completion, or via the hard watchdog after 5 seconds.
    private func sendWithWatchdog(_ connection: NWConnection, data: Data, completion: @escaping (Bool) -> Void) {
        var finished = false
        let lock = NSLock()
        let finish: (Bool) -> Void = { success in
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            completion(success)
        }
        connection.send(content: data, completion: .contentProcessed({ error in
            finish(error == nil)
        }))
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 5) { [weak connection] in
            lock.lock()
            let wasFinished = finished
            lock.unlock()
            // Only force-cancel when the send NEVER completed. A completed send
            // must never have its connection torn down here — streaming
            // responses legitimately live far past the 5s mark and the pump
            // task owns the connection from then on.
            if !wasFinished {
                finish(false)
                connection?.cancel()
            }
        }
    }

    private func statusText(_ code: Int) -> String { HTTPUtils.statusText(code) }

    // MARK: - Stats

    private func updateStats(for host: String, action: RouteAction) {
        // Thread-safe mutation via stateLock — no MainActor hop needed.
        mutateStats { stats in
            switch action {
            case .routeAI:
                stats.aiRouted += 1
            case .passthrough, .passThroughOpenAI:
                stats.passthrough += 1
            case .block:
                stats.blocked += 1
            }
        }
    }

    // MARK: - Connection Helpers

    private func sendHttpResponse(_ connection: NWConnection, statusCode: Int, message: String) {
        // Track error responses in stats for the analytics dashboard.
        if statusCode >= 400 {
            mutateStats { $0.errors += 1 }
        }
        // Always attach a parseable Anthropic-shaped JSON error body (with
        // Content-Length). Empty-body errors made Claude Code report every
        // 4xx/5xx as "InvalidHTTPResponse" because it couldn't decode them.
        let type: String
        switch statusCode {
        case 400: type = "invalid_request_error"
        case 401: type = "authentication_error"
        case 403: type = "permission_error"
        case 404: type = "not_found_error"
        case 429: type = "rate_limit_error"
        default: type = "api_error"
        }
        let escaped = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let body = "{\"type\":\"error\",\"error\":{\"type\":\"\(type)\",\"message\":\"\(escaped)\"}}"
        let response = "HTTP/1.1 \(statusCode) \(message)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\nProxy-Agent: JXProxy\r\n\r\n\(body)"
        guard let data = response.data(using: .utf8) else {
            connection.cancel()
            return
        }
        connection.send(content: data, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }

    /// Guards against self-connection loops: if a request targets this proxy's own
    /// loopback listener, reject it with a 502 and close the connection instead of
    /// opening an upstream connection back into ourselves. Returns true when rejected.
    private func rejectIfSelfTarget(_ connection: NWConnection, host: String, port: UInt16) -> Bool {
        let hostOnly = host.split(separator: ":").first.map(String.init) ?? host
        let isLoopback = hostOnly == "127.0.0.1" || hostOnly == "localhost"
        guard isLoopback && port == self.port else { return false }

        let body = "Request loop detected"
        let response = "HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\nProxy-Agent: JXProxy\r\n\r\n\(body)"
        guard let data = response.data(using: .utf8) else {
            connection.cancel()
            return true
        }
        connection.send(content: data, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
        return true
    }

    /// Synchronous blocking read of one body chunk. Kept as a non-async helper so the
    /// semaphore wait stays legal under Swift 6 (DispatchSemaphore.wait is unavailable
    /// in async contexts).
    private func waitForBody(connection: NWConnection, maxLength: Int, deadline: DispatchTime) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        var chunkData = Data()
        var chunkError: Error?

        connection.receive(minimumIncompleteLength: 1, maximumLength: maxLength) { data, _, _, error in
            if let d = data { chunkData = d }
            if let e = error { chunkError = e }
            semaphore.signal()
        }

        if semaphore.wait(timeout: deadline) == .timedOut {
            connection.cancel()
            throw TimeoutError("Body read timed out after 30s")
        }

        if let err = chunkError { throw err }
        return chunkData
    }

    // MARK: - CONNECT Tunnel Handler (Routes AI hosts through DirectTLS)

    private var _mitmHandler: MITMHandler?
    @MainActor
    private var mitmHandler: MITMHandler {
        if let h = _mitmHandler { return h }
        let h = MITMHandler(directTLSPort: port + 1)
        _mitmHandler = h
        return h
    }

    private func handleConnect(_ connection: NWConnection, request: String, initialData: Data, ruleAction: RouteAction?) {
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            connection.cancel()
            return
        }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count == 3 else {
            connection.cancel()
            return
        }
        let target = parts[1]
        let targetParts = target.split(separator: ":")
        guard targetParts.count >= 2, let connectPort = UInt16(targetParts.last!) else {
            connection.cancel()
            return
        }
        let connectHost = targetParts.dropLast().joined(separator: ":")

        // Reject CONNECT to our own listening port (self-connection loop).
        if rejectIfSelfTarget(connection, host: connectHost, port: connectPort) { return }

        // A per-app rule can force this host to pass through raw — e.g. a
        // "Pass Through OpenAI" rule for Codex, which must hit the real API
        // even when the global Route OpenAI switch is on.
        let forcedPassthrough = ruleForcesPassthrough(ruleAction, host: connectHost)

        // For AI hosts, attempt MITM handler (which now does TCP relay, no actual MITM)
        let snap = configSnapshot()
        let isMITMHost = snap.mitmHosts.contains { host in
            if host == connectHost { return true }
            if host.hasPrefix("*.") {
                let suffix = String(host.dropFirst(2))
                return connectHost == suffix || connectHost.hasSuffix("." + suffix)
            }
            return false
        }

        if !forcedPassthrough, isMITMHost || snap.classifier.isKnownAiHost(connectHost) {
            print("[ProxyServer] AI CONNECT tunnel: \(connectHost):\(connectPort) → DirectTLS:5256")
            Task { @MainActor in
                // Route AI CONNECT tunnels through DirectTLS → ProviderRouter
                mitmHandler.intercept(connection: connection, host: connectHost, port: connectPort)
            }
            return
        }

        // Non-AI CONNECT (or forced passthrough) → standard TCP passthrough
        Task { @MainActor in
            mitmHandler.intercept(connection: connection, host: connectHost, port: connectPort, forcePassthrough: forcedPassthrough)
        }
    }

    /// True when a per-app rule forces this host to pass through unmodified.
    /// A `.passthrough` rule bypasses everything; `.passThroughOpenAI` bypasses
    /// OpenAI hosts only (regardless of the global Route OpenAI switch).
    private func ruleForcesPassthrough(_ ruleAction: RouteAction?, host: String) -> Bool {
        guard let ruleAction else { return false }
        switch ruleAction {
        case .passthrough:
            return true
        case .passThroughOpenAI:
            return RequestClassifier.isOpenAIHost(host)
        case .routeAI, .block:
            return false
        }
    }

    // MARK: - Upstream Routing

    private func routeViaProviderRouter(_ connection: NWConnection, initialData: Data, host: String, port: UInt16, entryId: UUID) {
        // Header block only — the first packet's body may be truncated mid-UTF-8
        // at the 64KB receive cap (see processRequest).
        guard let requestStr = decodeHeaders(from: initialData) else {
            sendHttpResponse(connection, statusCode: 400, message: "Bad Request")
            return
        }
        let lines = requestStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            connection.cancel()
            return
        }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            connection.cancel()
            return
        }
        let method = parts[0]
        let rawPath = parts[1]

        let path: String
        if rawPath.hasPrefix("http://") || rawPath.hasPrefix("https://") {
            if let url = URL(string: rawPath) {
                path = url.path.isEmpty ? "/" : url.path
            } else {
                path = rawPath
            }
        } else {
            path = rawPath.components(separatedBy: "?").first ?? rawPath
        }

        let headers = parseHeaders(from: requestStr)
        // Byte-accurate body extraction (never round-trip the body through a
        // String — that corrupts binary content and can drop bytes).
        let separator = Data("\r\n\r\n".utf8)
        let bodyData: Data
        if let range = initialData.range(of: separator) {
            bodyData = Data(initialData[range.upperBound...])
        } else {
            bodyData = Data()
        }

        let router = self.providerRouter
        // F4: total-request timeout parity with handleAIRouted — a hung
        // upstream must yield a 504 to the client, not an endless open
        // connection. Local-model prefills need the long budget.
        let requestTask = Task {
            do {
                let response = try await router?.route(
                    method: method,
                    path: path,
                    headers: headers,
                body: bodyData
                )

                guard let response else {
                    sendHttpResponse(connection, statusCode: 502, message: "Provider Router unavailable")
                    return
                }

                // Report which upstream provider served the request.
                if let serving = response.servingProvider {
                    let usedFallback = response.usedFallback
                    Task { @MainActor in self.onTrafficServed?(entryId, serving, usedFallback) }
                }

                var headerString = "HTTP/1.1 \(response.statusCode) \(statusText(response.statusCode))\r\n"
                for (key, value) in response.headers {
                    headerString += "\(key): \(value)\r\n"
                }

                if response.stream == nil {
                    headerString += "Content-Length: \(response.body.count)\r\n"
                }
                headerString += "Connection: close\r\n"
                headerString += "Proxy-Agent: JXProxy\r\n"
                headerString += "\r\n"

                guard let headerData = headerString.data(using: .utf8) else {
                    connection.cancel()
                    return
                }

                if let stream = response.stream {
                    sendWithWatchdog(connection, data: headerData) { _ in
                        Task {
                            for await chunk in stream {
                                guard !chunk.isEmpty else { continue }
                                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                                    connection.send(content: chunk, completion: .contentProcessed({ _ in
                                        cont.resume()
                                    }))
                                }
                            }
                            connection.cancel()
                        }
                    }
                } else {
                    // Single atomic send: headers + body in one payload so the
                    // client always receives a framable response (parity with
                    // the handleAIRouted fix).
                    var payload = headerData
                    payload.append(response.body)
                    sendWithWatchdog(connection, data: payload) { _ in
                        connection.cancel()
                    }
                }
            } catch is CancellationError {
                sendHttpResponse(connection, statusCode: 504, message: "Request timed out")
            } catch let error as TimeoutError {
                sendHttpResponse(connection, statusCode: 504, message: error.message)
            } catch {
                sendHttpResponse(connection, statusCode: 502, message: "Upstream error")
            }
        }

        Task {
            try? await Task.sleep(nanoseconds: 300_000_000_000)
            requestTask.cancel()
        }
    }

    private func forwardDirectly(_ connection: NWConnection, initialData: Data, host: String, port: UInt16) {
        if rejectIfSelfTarget(connection, host: host, port: port) { return }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            print("[ProxyServer] Invalid forward port \(port)")
            connection.cancel()
            return
        }
        let target = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        target.start(queue: queue)

        target.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            if case .ready = state {
                target.send(content: initialData, completion: .contentProcessed({ _ in
                    self.relayLoop(source: target, destination: connection)
                    self.relayLoop(source: connection, destination: target)
                }))
            } else if case .failed = state {
                connection.cancel()
            }
        }
    }

    private func relayLoop(source: NWConnection, destination: NWConnection) {
        NetworkRelay.relayLoop(source: source, destination: destination, on: queue)
    }
}
