import Foundation
import Network

/// Handles CONNECT tunnel requests for the system proxy.
///
/// For AI API hosts, CONNECT tunnels are piped through the DirectTLS listener
/// (which terminates TLS and routes through ProviderRouter) instead of doing
/// TCP passthrough to the real API. This catches ALL Anthropic calls from ALL
/// apps on the system and routes them through JXProxy's provider chain.
///
/// Non-AI hosts get standard TCP passthrough.
final class MITMHandler: @unchecked Sendable {
    /// Port the DirectTLS listener is on (port+1, e.g. 5256).
    let directTLSPort: UInt16

    init(directTLSPort: UInt16) {
        self.directTLSPort = directTLSPort
    }

    /// Handle a CONNECT tunnel request.
    /// Returns true if handled.
    ///
    /// - Parameter forcePassthrough: when true the tunnel is relayed raw even
    ///   for AI hosts — used by per-app rules like "Pass Through OpenAI",
    ///   which override the global routing switch for a specific app.
    func intercept(connection: NWConnection, host: String, port: UInt16, forcePassthrough: Bool = false) -> Bool {
        if !forcePassthrough, isAIHost(host) {
            print("[MITM] Routing AI CONNECT \(host):\(port) → DirectTLS:127.0.0.1:\(directTLSPort)")
            Task {
                await routeAITunnel(connection: connection, host: host, port: port)
            }
            return true
        }

        // Non-AI hosts (or forced passthrough): standard TCP passthrough
        print("[MITM] Passthrough CONNECT \(host):\(port)")
        startPassthrough(connection, host: host, port: port)
        return true
    }

    /// Route an AI API CONNECT tunnel through the DirectTLS listener.
    /// The DirectTLS handler terminates TLS and routes decrypted HTTP through ProviderRouter.
    private func routeAITunnel(connection: NWConnection, host: String, port: UInt16) async {
        let established = "HTTP/1.1 200 Connection Established\r\nProxy-Agent: JXProxy\r\n\r\n"
        guard let establishedData = established.data(using: .utf8) else {
            connection.cancel()
            return
        }

        connection.send(content: establishedData, completion: .contentProcessed({ [weak self] _ in
            guard let self else { return }

            // Pipe to DirectTLS listener instead of the real destination
            guard let directTLSPort = NWEndpoint.Port(rawValue: self.directTLSPort) else {
                print("[MITM] Invalid DirectTLS port \(self.directTLSPort)")
                connection.cancel()
                return
            }
            let target = NWConnection(
                host: NWEndpoint.Host("127.0.0.1"),
                port: directTLSPort,
                using: .tcp
            )

            target.stateUpdateHandler = { state in
                if case .ready = state {
                    self.relayLoop(source: connection, destination: target)
                    self.relayLoop(source: target, destination: connection)
                } else if case .failed = state {
                    print("[MITM] DirectTLS unavailable, raw passthrough for \(host):\(port)")
                    // "200" already sent above — just relay raw bytes without re-sending
                    guard let fallbackPort = NWEndpoint.Port(rawValue: port) else {
                        connection.cancel()
                        return
                    }
                    let fallback = NWConnection(
                        host: NWEndpoint.Host(host),
                        port: fallbackPort,
                        using: .tcp
                    )
                    fallback.stateUpdateHandler = { state in
                        if case .ready = state {
                            self.relayLoop(source: connection, destination: fallback)
                            self.relayLoop(source: fallback, destination: connection)
                        } else {
                            connection.cancel()
                        }
                    }
                    fallback.start(queue: self.queue)
                }
            }
            target.start(queue: self.queue)
        }))
    }

    /// Simple TCP passthrough for CONNECT tunnels.
    /// Sends "200 Connection Established" and relays raw TCP data bidirectionally.
    private func startPassthrough(_ connection: NWConnection, host: String, port: UInt16) {
        let established = "HTTP/1.1 200 Connection Established\r\nProxy-Agent: JXProxy\r\n\r\n"
        guard let establishedData = established.data(using: .utf8) else {
            connection.cancel()
            return
        }

        connection.send(content: establishedData, completion: .contentProcessed({ [weak self] _ in
            guard let self else { return }

            // Connect to the actual destination
            guard let targetPort = NWEndpoint.Port(rawValue: port) else {
                connection.cancel()
                return
            }
            let target = NWConnection(
                host: NWEndpoint.Host(host),
                port: targetPort,
                using: .tcp
            )

            target.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .ready = state {
                    self.relayLoop(source: connection, destination: target)
                    self.relayLoop(source: target, destination: connection)
                } else if case .failed = state {
                    connection.cancel()
                }
            }
            target.start(queue: queue)
        }))
    }

    /// Continuously relay data from source to destination.
    private func relayLoop(source: NWConnection, destination: NWConnection) {
        NetworkRelay.relayLoop(source: source, destination: destination, on: queue)
    }

    /// Check if a hostname is a known AI API host.
    /// Honors the "Route OpenAI connections" switch: with it off, OpenAI hosts
    /// get raw TCP passthrough here instead of a trip through DirectTLS.
    private func isAIHost(_ host: String) -> Bool {
        RequestClassifier(routeOpenAI: ConfigManager.shared.routeOpenAI).isKnownAiHost(host)
    }

    private let queue = DispatchQueue(label: "com.jxproxy.mitm", qos: .userInitiated)
}
