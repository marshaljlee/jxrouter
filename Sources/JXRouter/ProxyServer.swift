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
    var uptime: TimeInterval = 0
}

@Observable
final class ProxyServer: @unchecked Sendable {
    private var httpListener: NWListener?
    private let queue = DispatchQueue(label: "com.jxproxy.proxy", qos: .userInitiated)
    private let classifier = RequestClassifier()

    var isRunning = false
    var port: UInt16 = 5255
    var authToken: String = "jxproxy"
    var stats = ProxyStats()
    var connectedApps: [String] = []
    var onTrafficEntry: ((TrafficEntry) -> Void)?

    /// In-process provider router (replaces external jxproxy-proxy binary).
    var providerRouter: ProviderRouter?

    /// Direct TLS handler for DNS-redirected AI API traffic.
    /// Listens on port+1 (e.g. 5256) with TLS terminated via multi-domain cert.
    private var directTLSHandler: DirectTLSHandler?

    /// DNS redirection manager.
    private let dnsManager = DNSRedirectionManager.shared

    /// Error state for UI propagation.
    var lastError: String?

    /// Cached config values for nonisolated access (updated via syncFromConfig).
    var cachedProvider: String = "jxproxy"
    var cachedModelOpus: String = "claude-opus-4-8-20250701"
    var cachedModelSonnet: String = "claude-sonnet-5-20251001"
    var cachedModelHaiku: String = "claude-haiku-4-5-20251001"
    var cachedMitmHosts: Set<String> = ["api.anthropic.com"]

    /// Whether DNS redirection is enabled.
    var dnsRedirectEnabled = false

    /// Sync cached config values from ConfigManager (call from MainActor).
    func syncConfigCache() {
        cachedProvider = ConfigManager.shared.provider
        cachedModelOpus = ConfigManager.shared.modelOpus
        cachedModelSonnet = ConfigManager.shared.modelSonnet
        cachedModelHaiku = ConfigManager.shared.modelHaiku
        cachedMitmHosts = ConfigManager.shared.mitmHosts
        cachedProvider = ConfigManager.shared.provider
    }

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
    private let maxAutoRestarts = 10

    private var activeConnections: [UUID: NWConnection] = [:]
    private var appConnectionCounts: [String: Int] = [:]

    // MARK: - Start / Stop

    func start(port: UInt16) throws {
        self.port = port
        syncConfigCache()
        let params = NWParameters.tcp

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
        try? check.run()
        check.waitUntilExit()
        let checkData = checkPipe.fileHandleForReading.readDataToEndOfFile()
        let pids = String(data: checkData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !pids.isEmpty {
            throw ProxyError.portInUse(port: Int(port), pids: pids)
        }

        // Start HTTP proxy listener — throws synchronously if params are invalid,
        // async failure (port conflict) is caught by the state handler above.
        httpListener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
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
            // Install DNS redirection after TLS is ready
            if self.dnsRedirectEnabled {
                self.installDNS()
            }
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

        // Remove DNS redirection
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
        activeConnections.removeAll()
        connectedApps.removeAll()
        appConnectionCounts.removeAll()
        stats = ProxyStats()
        print("[ProxyServer] Reset for restart")
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

    /// Install DNS redirection (best-effort, may prompt for admin).
    private func installDNS() {
        Task { @MainActor in
            let ok = dnsManager.install(proxyPort: port + 1) // Redirect to TLS listener port
            if ok {
                print("[ProxyServer] DNS redirection installed")
            } else {
                print("[ProxyServer] DNS redirection not available (will use system proxy only)")
                lastError = "DNS redirection unavailable — some AI apps may need system proxy"
            }
        }
    }

    // MARK: - Auto-Restart

    private func scheduleAutoRestart() {
        // Disabled to prevent infinite osascript prompt loops if the port fails to bind
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

    // MARK: - Connection Handling

    private func receiveFirstPacket(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self = self, let data = data, error == nil else {
                connection.cancel()
                return
            }
            self.processRequest(connection, initialData: data)
        }
    }

    private func processRequest(_ connection: NWConnection, initialData: Data) {
        guard let requestStr = String(data: initialData, encoding: .utf8) else {
            connection.cancel()
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
            
            handleConnect(connection, request: requestStr, initialData: initialData)
            return
        }

        // Auth enforcement on direct HTTP calls
        if authEnabled {
            let authResult = validateAuth(request: requestStr)
            switch authResult {
            case .denied(let reason):
                sendHttpResponse(connection, statusCode: 401, message: reason)
                return
            case .allowed:
                break
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
            if firstLine.contains("/api/hello") {
                return .allowed
            }
        }

        let headers = parseHeaders(from: request)
        let xApiKey = headers["x-api-key"]
        let authHeader = headers["authorization"]
        let bearerToken = authHeader.flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil }

        let provided = xApiKey ?? bearerToken
        guard let provided, provided == authToken else {
            return .denied("Invalid or missing auth token")
        }
        return .allowed
    }

    private func parseHeaders(from request: String) -> [String: String] {
        HTTPUtils.parseHeaders(from: request)
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
            if basePath == "/v1/messages" || basePath == "/v1/v1/messages" || basePath == "/messages" {
                handleAIMessages(connection, method: method, initialData: initialData)
                return
            }
        }

        // Override action if an app-specific rule exists (e.g. Bypass)
        let finalAction: RouteAction
        if let ruleAction = ruleAction, ruleAction == .passthrough {
            finalAction = .passthrough
        } else {
            finalAction = classifier.classify(host: host)
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
            routeViaProviderRouter(connection, initialData: initialData, host: host, port: port)
        case .passthrough:
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
        let now = Int(Date().timeIntervalSince1970)
        let cfg = ConfigManager.shared
        
        // Sanitize model IDs to remove newlines and excess whitespace.
        let sanitize: (String) -> String = { $0.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? $0 }
        
        var models: [[String: Any]] = [
            ["id": sanitize(cfg.modelOpus), "object": "model", "created": now, "owned_by": "jxproxy"],
            ["id": sanitize(cfg.modelSonnet), "object": "model", "created": now, "owned_by": "jxproxy"],
            ["id": sanitize(cfg.modelHaiku), "object": "model", "created": now, "owned_by": "jxproxy"],
        ]
        for preset in ProviderPreset.all {
            for modelId in preset.models {
                models.append(["id": sanitize(modelId), "object": "model", "created": now, "owned_by": preset.id])
            }
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["data": models])) ?? Data()
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
        let now = Int(Date().timeIntervalSince1970)
        
        // Return model details with a generous context window (200K tokens)
        // so Claude Code doesn't reject prompts as "too long"
        let modelInfo: [String: Any] = [
            "id": modelId,
            "object": "model",
            "created": now,
            "owned_by": "jxproxy",
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

    private func handleAIMessages(_ connection: NWConnection, method: String, initialData: Data) {
        if method == "HEAD" || method == "OPTIONS" {
            let response = "HTTP/1.1 204 No Content\r\nAllow: POST, HEAD, OPTIONS\r\nProxy-Agent: JXProxy\r\n\r\n"
            guard let data = response.data(using: .utf8) else { connection.cancel(); return }
            connection.send(content: data, completion: .contentProcessed({ _ in connection.cancel() }))
            return
        }

        guard let requestStr = String(data: initialData, encoding: .utf8) else {
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
                        let semaphore = DispatchSemaphore(value: 0)
                        var chunkData = Data()
                        var chunkError: Error?

                        connection.receive(minimumIncompleteLength: 1, maximumLength: chunkSize) { data, _, _, error in
                            if let d = data { chunkData = d }
                            if let e = error { chunkError = e }
                            semaphore.signal()
                        }

                        if semaphore.wait(timeout: readDeadline) == .timedOut {
                            connection.cancel()
                            throw TimeoutError("Body read timed out after 30s")
                        }

                        if let err = chunkError { throw err }
                        bodyData.append(chunkData)
                        bytesLeft -= chunkData.count
                        if chunkData.isEmpty { break }
                    }
                }

                try Task.checkCancellation()

                let response = try await router?.route(
                    method: method,
                    path: "/v1/messages",
                    headers: headers,
                    body: bodyData
                )

                guard let response else {
                    sendHttpResponse(connection, statusCode: 502, message: "Provider Router unavailable")
                    return
                }

                let statusLine = "HTTP/1.1 \(response.statusCode) \(statusText(response.statusCode))\r\n"
                var headerString = statusLine
                for (key, value) in response.headers {
                    headerString += "\(key): \(value)\r\n"
                }
                headerString += "\r\n"

                guard let headerData = headerString.data(using: .utf8) else {
                    connection.cancel()
                    return
                }

                connection.send(content: headerData, completion: .contentProcessed({ _ in
                    if let stream = response.stream {
                        // Streaming SSE: pump chunks from AsyncStream into the connection
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
                    } else {
                        connection.send(content: response.body, completion: .contentProcessed({ _ in
                            connection.cancel()
                        }))
                    }
                }))
            } catch is CancellationError {
                // Task was cancelled by the 90-second timeout
                sendHttpResponse(connection, statusCode: 504, message: "Request timed out")
            } catch let error as TimeoutError {
                sendHttpResponse(connection, statusCode: 504, message: error.message)
            } catch {
                sendHttpResponse(connection, statusCode: 502, message: "Upstream error")
            }
        }

        // FIX #2: 90-second total request timeout.
        // Ensures every request terminates even if all other safeguards fail.
        Task {
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            requestTask.cancel()
        }
    }

    private func statusText(_ code: Int) -> String { HTTPUtils.statusText(code) }

    // MARK: - Stats

    private func updateStats(for host: String, action: RouteAction) {
        switch action {
        case .routeAI:
            stats.aiRouted += 1
        case .passthrough:
            stats.passthrough += 1
        case .block:
            stats.blocked += 1
        }
    }

    // MARK: - Connection Helpers

    private func sendHttpResponse(_ connection: NWConnection, statusCode: Int, message: String) {
        let response = "HTTP/1.1 \(statusCode) \(message)\r\nContent-Length: 0\r\nConnection: close\r\nProxy-Agent: JXProxy\r\n\r\n"
        guard let data = response.data(using: .utf8) else {
            connection.cancel()
            return
        }
        connection.send(content: data, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }

    // MARK: - CONNECT Tunnel Handler (Routes AI hosts through DirectTLS)

    private var _mitmHandler: MITMHandler?
    @MainActor
    private var mitmHandler: MITMHandler {
        if let h = _mitmHandler { return h }
        let h = MITMHandler(providerRouter: providerRouter, directTLSPort: port + 1)
        _mitmHandler = h
        return h
    }

    private func handleConnect(_ connection: NWConnection, request: String, initialData: Data) {
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

        // For AI hosts, attempt MITM handler (which now does TCP relay, no actual MITM)
        let isMITMHost = cachedMitmHosts.contains { host in
            if host == connectHost { return true }
            if host.hasPrefix("*.") {
                let suffix = String(host.dropFirst(2))
                return connectHost == suffix || connectHost.hasSuffix("." + suffix)
            }
            return false
        }

        if isMITMHost || classifier.isKnownAiHost(connectHost) {
            print("[ProxyServer] AI CONNECT tunnel: \(connectHost):\(connectPort) → DirectTLS:5256")
            Task { @MainActor in
                // Route AI CONNECT tunnels through DirectTLS → ProviderRouter
                mitmHandler.intercept(connection: connection, host: connectHost, port: connectPort)
            }
            return
        }

        // Non-AI CONNECT → standard TCP passthrough
        Task { @MainActor in
            mitmHandler.intercept(connection: connection, host: connectHost, port: connectPort)
        }
    }

    // MARK: - Upstream Routing

    private func routeViaProviderRouter(_ connection: NWConnection, initialData: Data, host: String, port: UInt16) {
        guard let requestStr = String(data: initialData, encoding: .utf8) else {
            connection.cancel()
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
        let bodyComponents = requestStr.components(separatedBy: "\r\n\r\n")
        let bodyData: Data
        if bodyComponents.count >= 2 {
            bodyData = Data(bodyComponents.dropFirst().joined(separator: "\r\n\r\n").utf8)
        } else {
            bodyData = Data()
        }

        let router = self.providerRouter
        Task {
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

                connection.send(content: headerData, completion: .contentProcessed({ _ in
                    if let stream = response.stream {
                        Task {
                            for await chunk in stream {
                                connection.send(content: chunk, completion: .contentProcessed({ _ in }))
                            }
                            connection.cancel()
                        }
                    } else {
                        connection.send(content: response.body, completion: .contentProcessed({ _ in
                            connection.cancel()
                        }))
                    }
                }))
            } catch {
                sendHttpResponse(connection, statusCode: 502, message: "Upstream error")
            }
        }
    }

    private func forwardDirectly(_ connection: NWConnection, initialData: Data, host: String, port: UInt16) {
        let target = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
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
