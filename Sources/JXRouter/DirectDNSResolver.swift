import Foundation
import Darwin

/// Resolves hostnames to IP addresses using Cloudflare DNS-over-HTTPS,
/// falling back to system resolver (getaddrinfo) if the external query fails.
///
/// The resolved IP is used by CurlClient with `--resolve` to bypass
/// the system proxy settings and connect directly to the upstream provider.
final class DirectDNSResolver {
    static let shared = DirectDNSResolver()

    private var cache: [String: String] = [:]

    func resolve(_ hostname: String) async -> String? {
        if let cached = cache[hostname] { return cached }

        // Local / loopback — skip DNS entirely
        if hostname == "127.0.0.1" || hostname == "localhost" || hostname == "0.0.0.0" {
            cache[hostname] = hostname
            return hostname
        }

        // Already an IP address — no need to resolve
        if hostname.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == ":") }),
           hostname.split(separator: ".").count == 4 {
            cache[hostname] = hostname
            return hostname
        }

        // Try Cloudflare DoH first (fast, privacy-respecting)
        if let ip = await resolveViaDoH(hostname) {
            cache[hostname] = ip
            return ip
        }

        // Fallback to system DNS (getaddrinfo) — works even when
        // cloudflare-dns.com is unreachable.
        if let ip = resolveViaSystem(hostname) {
            cache[hostname] = ip
            return ip
        }

        return nil
    }

    private func resolveViaDoH(_ hostname: String) async -> String? {
        guard let url = URL(string: "https://cloudflare-dns.com/dns-query?name=\(hostname)&type=A") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 5

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let answer = json["Answer"] as? [[String: Any]] else {
                return nil
            }
            for record in answer {
                if let type = record["type"] as? Int, type == 1, let ip = record["data"] as? String {
                    return ip
                }
            }
        } catch {
            print("[DirectDNSResolver] DoH failed for \(hostname): \(error)")
        }
        return nil
    }

    private func resolveViaSystem(_ hostname: String) -> String? {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_INET,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var addrInfo: UnsafeMutablePointer<addrinfo>? = nil
        let result = getaddrinfo(hostname, nil, &hints, &addrInfo)
        guard result == 0, let info = addrInfo else {
            print("[DirectDNSResolver] getaddrinfo failed for \(hostname): \(result)")
            return nil
        }
        defer { freeaddrinfo(addrInfo) }

        let addr = info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        let ipBytes = addr.sin_addr
        let ipStr = String(cString: inet_ntoa(ipBytes))
        return ipStr
    }
}
