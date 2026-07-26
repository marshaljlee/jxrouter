import Foundation
import Network

/// Handles CONNECT tunnel requests for the system proxy.
///
/// This is a simplified replacement for the old MITM loopback-TLS approach.
///
/// **Why this changed**: The old MITM approach tried to intercept TLS connections
/// by creating a loopback TLS listener and relaying encrypted data through it.
/// This was fragile, had race conditions, blocked @MainActor with DispatchSemaphore,
/// and broke with certificate-pinned apps (like Claude Code).
///
/// **New approach**: For all CONNECT tunnels, we simply forward the raw TCP stream
/// to the intended destination. No TLS interception, no MITM.
///
/// **How AI API traffic is still intercepted**: Instead of MITM on CONNECT tunnels,
/// DNS redirection (DNSRedirectionManager) resolves `api.anthropic.com` and other
/// AI hosts directly to `127.0.0.1`. Combined with pf port forwarding (443 → proxy port),
/// apps connect directly to the proxy. The DirectTLSHandler (separate from this)
/// terminates TLS cleanly and routes the decrypted HTTP through ProviderRouter.
final class MITMHandler: @unchecked Sendable {
    let providerRouter: ProviderRouter?

    init(providerRouter: ProviderRouter?) {
        self.providerRouter = providerRouter
    }

    /// Handle a CONNECT tunnel request.
    /// Returns true if handled (always returns true — CONNECT tunnels are always relayed).
    func intercept(connection: NWConnection, host: String, port: UInt16) -> Bool {
        print("[MITM] Relay CONNECT \(host):\(port) — no MITM, pure TCP forward")

        // For AI API hosts, we attempt to route directly via ProviderRouter.
        // This is a "best effort" — if it fails, we fall through to passthrough.
        if isAIHost(host) {
            Task {
                await tryAITunnel(connection: connection, host: host, port: port)
            }
            return true
        }

        // Non-AI hosts: simple TCP passthrough
        startPassthrough(connection, host: host, port: port)
        return true
    }

    /// Try to detect and handle an AI API tunnel.
    /// Since we can't MITM the TLS, we fall back to passthrough.
    /// The real interception happens via DNS redirection + DirectTLSHandler.
    private func tryAITunnel(connection: NWConnection, host: String, port: UInt16) async {
        // Just passthrough — the AI interception happens via DNS redirect + DirectTLS
        startPassthrough(connection, host: host, port: port)
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
            let target = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!,
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
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            guard let data = data, !data.isEmpty, error == nil else {
                source.cancel()
                destination.cancel()
                return
            }
            destination.send(content: data, completion: .contentProcessed({ _ in
                self.relayLoop(source: source, destination: destination)
            }))
        }
    }

    /// Check if a hostname is a known AI API host.
    private func isAIHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        let aiPatterns = RequestClassifier().aiHostPatterns
        let aiSuffixes = RequestClassifier().aiHostSuffixes

        if aiPatterns.contains(lower) { return true }
        for suffix in aiSuffixes {
            if lower.hasSuffix(suffix) { return true }
        }
        return false
    }

    private let queue = DispatchQueue(label: "com.jxproxy.mitm", qos: .userInitiated)
}
