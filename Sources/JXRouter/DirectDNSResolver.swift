import Foundation
import Network

/// Lightweight DNS resolver that returns an IP address for a hostname.
/// Used by CurlClient to connect directly to IPs, bypassing slow or
/// poisoned system DNS resolvers.
struct DirectDNSResolver {
    static let shared = DirectDNSResolver()

    /// Single-shot completion gate: the connection state handler and the
    /// timeout both fire, but the continuation may be resumed only once (a
    /// second resume is a runtime crash). Thread-safe and Sendable.
    private final class ResolveGate: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func markDone() -> Bool {
            lock.withLock {
                if done { return false }
                done = true
                return true
            }
        }
    }

    /// Resolve a hostname to its first IPv4 address. Returns the original
    /// hostname on failure so callers can still attempt a connection.
    func resolve(_ host: String) async -> String? {
        return await withCheckedContinuation { continuation in
            let parameters = NWParameters()
            let endpoint = NWEndpoint.Host(host)
            let connection = NWConnection(host: endpoint, port: 80, using: parameters)
            let gate = ResolveGate()

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard gate.markDone() else { return }
                    connection.cancel()
                    if case .hostPort(let h, _) = connection.currentPath?.remoteEndpoint {
                        let resolved: String
                        switch h {
                        case .ipv4(let addr):
                            var sa = addr
                            resolved = withUnsafePointer(to: &sa) {
                                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ptr in
                                    String(cString: inet_ntoa(ptr.pointee.sin_addr))
                                }
                            }
                        default:
                            resolved = host
                        }
                        continuation.resume(returning: resolved)
                    } else {
                        continuation.resume(returning: host)
                    }
                case .failed:
                    guard gate.markDone() else { return }
                    connection.cancel()
                    continuation.resume(returning: host)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            // Timeout after 3 seconds
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                guard gate.markDone() else { return }
                connection.cancel()
                continuation.resume(returning: host)
            }
        }
    }
}
