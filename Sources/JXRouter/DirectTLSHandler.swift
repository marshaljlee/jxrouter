import Foundation
import Network

/// Handles direct TLS-terminated connections from intercepted AI traffic
/// (CONNECT tunnels routed by MITMHandler). Terminates TLS on the proxy's
/// TLS port (port + 1) and feeds the decrypted request to ProviderRouter.
///
/// Flow:
/// 1. NWListener with TLS configured using multi-domain cert from CertificateAuthority
/// 2. App connects with TLS ClientHello (SNI = e.g. api.anthropic.com)
/// 3. TLS handshake completes (multi-domain cert covers *.anthropic.com etc.)
/// 4. Reads decrypted HTTP request
/// 5. Routes through ProviderRouter
/// 6. Writes response back (TLS auto-encrypts)
///
/// **No keychain access**: Uses PEMIdentityLoader to create sec_identity_t from
/// PEM files directly, avoiding the keychain import prompt entirely.
final class DirectTLSHandler: @unchecked Sendable {
    private var tlsListener: NWListener?
    private let queue = DispatchQueue(label: "com.jxproxy.directtls", qos: .userInitiated)
    private weak var providerRouter: ProviderRouter?

    /// F3: per-connection idle timers (dispatch sources) keyed by connection.
    /// All access is on `queue` — the same queue the receive callbacks and
    /// timer handlers run on, so no extra lock is needed.
    private var idleTimers: [ObjectIdentifier: DispatchSourceTimer] = [:]

    /// Arm an idle timer that closes the connection when `deadline` passes.
    private func storeTimer(connection: NWConnection, deadline: DispatchTime) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: deadline)
        timer.setEventHandler { [weak self, weak connection] in
            guard let self, let connection else { return }
            idleTimers.removeValue(forKey: ObjectIdentifier(connection))
            guard connection.state != .cancelled else { return }
            print("[DirectTLS] Idle timeout — closing idle connection")
            sendError(connection, statusCode: 408, message: "Request timeout")
            connection.cancel()
        }
        timer.resume()
        idleTimers[ObjectIdentifier(connection)] = timer
    }

    /// Push a live connection's idle deadline forward (data arrived).
    private func rearmTimer(connection: NWConnection, deadline: DispatchTime) {
        idleTimers[ObjectIdentifier(connection)]?.schedule(deadline: deadline)
    }

    /// Drop the connection's idle timer once a full request has arrived and
    /// routing has begun (the timer exists only to bound the idle wait).
    private func cancelTimer(connection: NWConnection) {
        if let t = idleTimers.removeValue(forKey: ObjectIdentifier(connection)) { t.cancel() }
    }

    /// Whether the TLS listener is active.
    private(set) var isRunning = false

    /// Cached multi-domain identity (loaded once, reused).
    private var multiDomainIdentity: sec_identity_t?

    /// Paths the provider router understands. Anything else on an intercepted
    /// AI host (OpenAI's /v1/embeddings, /v1/models/{id}, …) is passed through
    /// as a fresh TLS connection to the real host so the proxy never
    /// interferes with endpoints it doesn't route. /v1/responses (the OpenAI
    /// Responses API, used by Codex and recent SDKs) IS routed — it is
    /// translated to chat completions and back by the router.
    private static let routedPaths: Set<String> = [
        "/v1/messages", "/v1/v1/messages", "/messages",
        "/v1/messages/count_tokens",
        "/v1/chat/completions", "/v1/v1/chat/completions", "/chat/completions",
        "/v1/responses", "/v1/v1/responses", "/responses",
        "/v1/models",
        "/health", "/", "/api/hello", "/v1/api/hello",
        "/stop",
    ]

    /// Maximum request bytes accumulated before the connection is rejected (16 MiB).
    private let maxBodyBytes = 16 * 1024 * 1024
    /// Idle timeout: the connection is closed if no data arrives within this window.
    private let idleTimeout: TimeInterval = 60

    init(providerRouter: ProviderRouter?) {
        self.providerRouter = providerRouter
    }

    /// Start the TLS listener on the given port.
    /// Returns true if the listener started successfully.
    @discardableResult
    func start(port: UInt16) -> Bool {
        guard tlsListener == nil else { return true }

        // Load multi-domain identity (no keychain access)
        guard ensureIdentity() else {
            print("[DirectTLS] Failed to get multi-domain certificate identity")
            return false
        }

        // Build TLS parameters
        let tlsOptions = NWProtocolTLS.Options()
        guard let identity = multiDomainIdentity else {
            print("[DirectTLS] No identity available")
            return false
        }
        sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, identity)

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = false
        let params = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        // Security: accept connections from loopback only. This listener handles
        // DNS-redirected traffic that pf forwards to 127.0.0.1:{proxyPort + 1}.
        // Port 0 in the local endpoint (real port in `on:`) keeps the bind
        // loopback-only; a specific port here throws EINVAL at listener creation.
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 0)

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            print("[DirectTLS] Invalid port \(port)")
            return false
        }
        guard let listener = try? NWListener(using: params, on: nwPort) else {
            print("[DirectTLS] Failed to create TLS listener on port \(port)")
            return false
        }

        listener.service = nil
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                print("[DirectTLS] TLS listener ready on port \(port)")
                isRunning = true
            case .failed(let error):
                print("[DirectTLS] TLS listener failed: \(error)")
                isRunning = false
                tlsListener = nil
            case .cancelled:
                isRunning = false
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue)
            self.receiveRequest(connection: connection, accumulatedData: Data(), deadline: DispatchTime.now() + self.idleTimeout)
        }

        listener.start(queue: queue)
        tlsListener = listener
        return true
    }

    /// Stop the TLS listener.
    func stop() {
        tlsListener?.cancel()
        tlsListener = nil
        isRunning = false
        queue.async { [weak self] in
            guard let self else { return }
            for (_, t) in self.idleTimers { t.cancel() }
            self.idleTimers.removeAll()
        }
    }

    // MARK: - Connection Handling

    private func receiveRequest(connection: NWConnection, accumulatedData: Data, deadline: DispatchTime) {
        // F3 fix: real idle timeout. The old code only compared the deadline
        // inside the receive callback — which never fires on an idle
        // connection — so "idle" connections were held forever. A queue timer
        // closes the connection when its deadline passes and is re-armed on
        // every data arrival.
        if accumulatedData.isEmpty {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: deadline)
            storeTimer(connection: connection, deadline: deadline)
        } else {
            rearmTimer(connection: connection, deadline: deadline)
        }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 131_072) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            
            var newData = accumulatedData
            if let data = data, !data.isEmpty {
                newData.append(data)
            }
            
            // Cap total accumulated bytes to bound memory usage — stop recursing.
            if newData.count > self.maxBodyBytes {
                self.sendError(connection, statusCode: 413, message: "Request body too large")
                connection.cancel()
                return
            }
            
            // Idle timeout: close the connection if nothing arrived before the deadline.
            if DispatchTime.now() >= deadline {
                self.sendError(connection, statusCode: 408, message: "Request timeout")
                connection.cancel()
                return
            }
            
            if error != nil {
                connection.cancel()
                return
            }
            
            if let headerEnd = newData.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = newData.prefix(upTo: headerEnd.lowerBound)
                if let headerStr = String(data: headerData, encoding: .utf8) {
                    let headers = self.parseHeaders(headerStr)
                    
                    if let clStr = headers["content-length"], let cl = Int(clStr) {
                        let bodySize = newData.count - headerEnd.upperBound
                        if bodySize >= cl {
                            // Full body received
                            let requestToProcess = newData
                            Task { await self.routeHTTP(connection: connection, requestData: requestToProcess) }
                            return
                        }
                    } else if headers["transfer-encoding"]?.lowercased() == "chunked" {
                        if newData.range(of: Data("0\r\n\r\n".utf8)) != nil {
                            let requestToProcess = newData
                            Task { await self.routeHTTP(connection: connection, requestData: requestToProcess) }
                            return
                        }
                    } else {
                        // No body or unknown
                        let requestToProcess = newData
                        Task { await self.routeHTTP(connection: connection, requestData: requestToProcess) }
                        return
                    }
                }
            }
            
            if isComplete {
                if !newData.isEmpty {
                    Task { await self.routeHTTP(connection: connection, requestData: newData) }
                } else {
                    connection.cancel()
                }
                return
            }
            
            self.receiveRequest(connection: connection, accumulatedData: newData, deadline: DispatchTime.now() + self.idleTimeout)
        }
    }
    
    private func parseHeaders(_ headerStr: String) -> [String: String] {
        HTTPUtils.parseHeaders(from: headerStr)
    }

    private func routeHTTP(connection: NWConnection, requestData: Data) async {
        cancelTimer(connection: connection)
        guard let requestStr = String(data: requestData, encoding: .utf8) else {
            sendError(connection, statusCode: 400, message: "Invalid HTTP request")
            return
        }

        let lines = requestStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendError(connection, statusCode: 400, message: "No request line")
            return
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendError(connection, statusCode: 400, message: "Invalid request line")
            return
        }

        let method = parts[0]
        let pathRaw = parts[1]
        let path = pathRaw.components(separatedBy: "?").first ?? pathRaw

        let headers = parseHeaders(requestStr)

        // Extract body
        let bodyData: Data
        if let bodyStart = requestStr.range(of: "\r\n\r\n") {
            let bodyStr = String(requestStr[bodyStart.upperBound...])
            bodyData = Data(bodyStr.utf8)
        } else {
            bodyData = Data()
        }

        let contentLength = headers["content-length"].flatMap { Int($0) } ?? bodyData.count
        let trimmedBody = bodyData.prefix(contentLength)

        // Pass through AI-host paths the router doesn't handle (OpenAI's
        // /v1/embeddings, /v1/models/{id}, …) as a fresh TLS connection to the
        // real host. The client's own request and auth reach the real API
        // untouched — no interference with endpoints we don't route. (Non-AI
        // hosts never reach this handler; they get a raw TCP relay in
        // MITMHandler.)
        if !Self.routedPaths.contains(path) {
            let targetHost = headers["host"]?.split(separator: ":").first.map(String.init) ?? ""
            guard !targetHost.isEmpty, targetHost != "127.0.0.1", targetHost != "localhost" else {
                print("[DirectTLSHandler] No routable host for \(path)")
                sendError(connection, statusCode: 502, message: "Cannot route \(path)")
                return
            }
            print("[DirectTLSHandler] Passthrough \(targetHost)\(path)")
            passthroughTLS(connection: connection, requestData: requestData, host: targetHost, port: 443)
            return
        }

        guard let router = providerRouter else {
            print("[DirectTLSHandler] Error: providerRouter is nil"); sendError(connection, statusCode: 502, message: "Provider Router unavailable")
            return
        }

        do {
            print("[DirectTLSHandler] Calling route"); let response = try await router.route(method: method, path: path, headers: headers, body: trimmedBody)

            print("[DirectTLSHandler] Got response \(response.statusCode)"); var respStr = "HTTP/1.1 \(response.statusCode) \(statusText(response.statusCode))\r\n"
            for (key, value) in response.headers {
                respStr += "\(key): \(value)\r\n"
            }
            respStr += "Proxy-Agent: JXProxy\r\n"
            
            if let stream = response.stream {
                respStr += "Transfer-Encoding: chunked\r\n\r\n"
                connection.send(content: Data(respStr.utf8), completion: .contentProcessed({ _ in }))
                
                for await chunk in stream {
                    let chunkStr = String(format: "%X\r\n", chunk.count)
                    var chunkData = Data(chunkStr.utf8)
                    chunkData.append(chunk)
                    chunkData.append(Data("\r\n".utf8))
                    connection.send(content: chunkData, completion: .contentProcessed({ _ in }))
                }
                
                let endChunk = Data("0\r\n\r\n".utf8)
                connection.send(content: endChunk, completion: .contentProcessed({ [weak self] _ in
                    self?.receiveRequest(connection: connection, accumulatedData: Data(), deadline: DispatchTime.now() + (self?.idleTimeout ?? 60))
                }))
            } else {
                respStr += "Content-Length: \(response.body.count)\r\n\r\n"
                var fullResponse = Data(respStr.utf8)
                fullResponse.append(response.body)

                connection.send(content: fullResponse, completion: .contentProcessed({ [weak self] _ in 
                    self?.receiveRequest(connection: connection, accumulatedData: Data(), deadline: DispatchTime.now() + (self?.idleTimeout ?? 60))
                }))
            }
        } catch {
            print("[DirectTLSHandler] Error: \(error)"); sendError(connection, statusCode: 502, message: "Upstream error: \(error.localizedDescription)")
        }
    }

    /// Relay a decrypted request to the real host over a fresh TLS connection
    /// and stream the response back. Used for AI-host paths the provider router
    /// doesn't handle, so unsupported endpoints keep working exactly as if the
    /// proxy weren't there.
    private func passthroughTLS(connection: NWConnection, requestData: Data, host: String, port: UInt16) {
        let params = NWParameters(tls: NWProtocolTLS.Options())
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            print("[DirectTLS] Invalid passthrough port \(port)")
            connection.cancel()
            return
        }
        let target = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        target.start(queue: queue)

        target.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                target.send(content: requestData, completion: .contentProcessed({ _ in
                    NetworkRelay.relayLoop(source: target, destination: connection, on: self.queue)
                    NetworkRelay.relayLoop(source: connection, destination: target, on: self.queue)
                }))
            case .failed:
                print("[DirectTLSHandler] Upstream TLS to \(host) failed")
                self.sendError(connection, statusCode: 502, message: "Upstream connection to \(host) failed")
            default:
                break
            }
        }
    }

    // MARK: - Identity Management

    /// Load the multi-domain identity using PEMIdentityLoader (no keychain access).
    private func ensureIdentity() -> Bool {
        if multiDomainIdentity != nil { return true }
        multiDomainIdentity = CertificateAuthority.shared.multiDomainIdentity()
        return multiDomainIdentity != nil
    }

    // MARK: - Utilities

    private func sendError(_ connection: NWConnection, statusCode: Int, message: String) {
        let escaped = message.replacingOccurrences(of: "\"", with: "\\\"")
        let body = "{\"type\":\"error\",\"error\":{\"type\":\"api_error\",\"message\":\"\(escaped)\"}}"
        let resp = "HTTP/1.1 \(statusCode) \(statusText(statusCode))\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\nProxy-Agent: JXProxy\r\n\r\n\(body)"
        guard let data = resp.data(using: .utf8) else { connection.cancel(); return }
        connection.send(content: data, completion: .contentProcessed({ _ in connection.cancel() }))
    }

    private func statusText(_ code: Int) -> String { HTTPUtils.statusText(code) }
}
