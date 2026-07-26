import Foundation
import Network

/// Handles direct TLS-terminated connections from DNS-redirected traffic.
///
/// When DNS resolution points AI API hosts to `127.0.0.1` (via DNSRedirectionManager)
/// and pf redirects port 443 to the proxy's TLS port, apps connect directly to this
/// handler thinking they're talking to the real API server.
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
    private let queue = DispatchQueue(label: "com.jxrouter.directtls", qos: .userInitiated)
    private weak var providerRouter: ProviderRouter?

    /// Whether the TLS listener is active.
    private(set) var isRunning = false

    /// Cached multi-domain identity (loaded once, reused).
    private var multiDomainIdentity: sec_identity_t?

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

        guard let listener = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!) else {
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
            connection.receive(minimumIncompleteLength: 1, maximumLength: 131_072) { data, _, _, error in
                guard let data = data, error == nil else { connection.cancel(); return }
                Task { await self.routeHTTP(connection: connection, requestData: data) }
            }
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
    }

    // MARK: - Connection Handling

    private func routeHTTP(connection: NWConnection, requestData: Data) async {
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

        // Parse headers
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.isEmpty else { break }
            let hParts = line.split(separator: ":", maxSplits: 1)
            if hParts.count == 2 {
                headers[String(hParts[0]).trimmingCharacters(in: .whitespaces).lowercased()] =
                    String(hParts[1]).trimmingCharacters(in: .whitespaces)
            }
        }

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

        guard let router = providerRouter else {
            sendError(connection, statusCode: 502, message: "Provider Router unavailable")
            return
        }

        do {
            let response = try await router.route(method: method, path: path, headers: headers, body: trimmedBody)

            var respStr = "HTTP/1.1 \(response.statusCode) \(statusText(response.statusCode))\r\n"
            for (key, value) in response.headers {
                respStr += "\(key): \(value)\r\n"
            }
            respStr += "Content-Length: \(response.body.count)\r\n"
            respStr += "Proxy-Agent: JXRouter\r\n"
            respStr += "\r\n"

            var fullResponse = Data(respStr.utf8)
            fullResponse.append(response.body)

            connection.send(content: fullResponse, completion: .contentProcessed({ _ in connection.cancel() }))
        } catch {
            sendError(connection, statusCode: 502, message: "Upstream error: \(error.localizedDescription)")
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
        let resp = "HTTP/1.1 \(statusCode) \(statusText(statusCode))\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\nProxy-Agent: JXRouter\r\n\r\n\(body)"
        guard let data = resp.data(using: .utf8) else { connection.cancel(); return }
        connection.send(content: data, completion: .contentProcessed({ _ in connection.cancel() }))
    }

    private func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 408: return "Request Timeout"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "Unknown"
        }
    }
}
