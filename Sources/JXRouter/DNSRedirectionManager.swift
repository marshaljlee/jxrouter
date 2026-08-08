import Foundation
import Network

/// Manages DNS redirection and port forwarding for intercepting AI API traffic.
///
/// Uses two mechanisms together:
/// 1. `/etc/hosts` entries that resolve each AI API hostname to its own
///    dedicated loopback address (127.0.0.2, 127.0.0.3, ...)
/// 2. `pfctl` anchor with one `rdr` rule per loopback address, redirecting
///    only the hijacked hosts' :443 traffic to 127.0.0.1:{tlsPort}
///
/// **Admin consent**: privileged operations run via `do shell script ... with
/// administrator privileges`, prompting macOS for authorization. No admin
/// password is ever embedded in a process argument list (CWE-522).
final class DNSRedirectionManager: @unchecked Sendable {
    static let shared = DNSRedirectionManager()

    /// Marker comment in /etc/hosts to identify our entries.
    private let hostsMarker = "# JXProxy DNS Hijack \u{2014} do not edit manually"
    private let pfAnchorName = "com.apple/250.jxproxy"

    /// Whether DNS redirection is currently active.
    private(set) var isActive = false

    /// Whether a pf anchor has been set up (tracked for cleanup).
    private var pfAnchorInstalled = false

    /// When true, uninstall() skips the admin prompt and leaves redirection in
    /// place. Used during in-place restarts so we never tear down + reinstall
    /// healthy redirection (which would trigger two osascript prompts).
    var suppressUninstall = false

    /// Last error encountered by the DNS manager.
    private(set) var lastError: String?

    private init() {}

    // MARK: - Public API

    /// Install DNS redirection and pf port forwarding.
    /// - Parameter proxyPort: The local TLS listener port that pf redirects
    ///   hijacked :443 traffic to (the HTTP proxy port + 1).
    /// - Returns: true if both DNS and pf were installed successfully.
    @discardableResult
    func install(proxyPort: UInt16) -> Bool {
        lastError = nil

        // Idempotency fast path: redirection is already installed AND functional
        // (hosts entries resolve to our loopback addresses AND the pf redirect
        // actually lands connections on the TLS listener). No admin needed —
        // skip the osascript prompt entirely. This is what stops the app from
        // prompting for a password on every Start / launch / restart.
        if isInstalled() {
            isActive = true
            pfAnchorInstalled = true
            print("[DNSRedirection] Already installed — skipping admin prompt")
            return true
        }

        // Step 1: Read current /etc/hosts and prepare new content
        let hostsContent: String
        if let current = try? String(contentsOfFile: "/etc/hosts", encoding: .utf8) {
            hostsContent = buildHostsContent(from: current)
        } else {
            print("[DNSRedirection] Cannot read /etc/hosts")
            lastError = "Cannot read /etc/hosts"
            return false
        }

        // Step 2: Write temp files (no admin needed)
        let hostsPath = "/tmp/jxproxy-hosts.tmp"
        let pfPath = "/tmp/jxproxy-pf.conf"
        // One rdr rule per hijacked host's dedicated loopback address, so
        // unrelated local TLS services on 127.0.0.1:443 stay untouched.
        // pf rewrites the destination before socket lookup, so every rule
        // still lands on the 127.0.0.1-bound TLS listener.
        var pfLines = ["# JXProxy per-host pf redirect rules"]
        for address in loopbackAddresses() {
            pfLines.append("rdr pass on lo0 inet proto tcp from any to \(address) port 443 -> 127.0.0.1 port \(proxyPort)")
        }
        let pfConf = pfLines.joined(separator: "\n")

        do {
            try hostsContent.write(toFile: hostsPath, atomically: true, encoding: .utf8)
            try pfConf.write(toFile: pfPath, atomically: true, encoding: .utf8)
        } catch {
            print("[DNSRedirection] Failed to write temp files: \(error)")
            lastError = "Failed to write temp files"
            return false
        }

        // Step 3: Single osascript call that does everything
        let ok = runAdminScript("""
            # Enable pf if not already running
            if ! /sbin/pfctl -s status 2>/dev/null | grep -q "Status: Enabled"; then
                /sbin/pfctl -e 2>/dev/null || true
            fi
            # Copy hosts file
            cp \(hostsPath) /etc/hosts
            # Load pf anchor rules
            /sbin/pfctl -a \(pfAnchorName) -f \(pfPath) 2>/dev/null || true
            # Flush DNS cache
            /usr/bin/dscacheutil -flushcache 2>/dev/null || true
            /usr/bin/killall -HUP mDNSResponder 2>/dev/null || true
            """)

        try? FileManager.default.removeItem(atPath: hostsPath)
        try? FileManager.default.removeItem(atPath: pfPath)

        guard ok else {
            print("[DNSRedirection] Admin script failed")
            lastError = "Admin authorization cancelled or failed"
            return false
        }

        pfAnchorInstalled = true
        isActive = true
        print("[DNSRedirection] Installed: DNS + PF redirect to port \(proxyPort)")
        return true
    }

    /// Remove DNS redirection and pf port forwarding.
    func uninstall() {
        lastError = nil

        // In-place restart: keep redirection in place (install() re-verifies
        // and repairs it on the way back up, so a restart prompts zero times).
        // Note: we deliberately do NOT re-verify here — during stop the TLS
        // listener is already down, so a connectivity probe would falsely
        // report "not installed" and re-trigger an admin prompt.
        if suppressUninstall {
            print("[DNSRedirection] Suppressed uninstall during restart — redirection kept")
            return
        }

        // Read current /etc/hosts and strip our entries
        let newHostsContent: String?
        if let current = try? String(contentsOfFile: "/etc/hosts", encoding: .utf8) {
            let cleaned = removeExistingEntries(current)
            newHostsContent = cleaned != current ? cleaned : nil
        } else {
            newHostsContent = nil
        }

        // Write cleaned hosts to temp file if needed
        var hostsPath: String? = nil
        if let content = newHostsContent {
            hostsPath = "/tmp/jxproxy-hosts-clean.tmp"
            try? content.write(toFile: hostsPath!, atomically: true, encoding: .utf8)
        }

        // Single osascript call for all cleanup — but ONLY when there is actually
        // something to clean. Previously the DNS-cache-flush lines always made the
        // script non-empty, so every stop()/quit triggered an admin prompt even
        // when nothing was installed.
        var script = ""
        if let hp = hostsPath {
            script += "cp \(hp) /etc/hosts\n"
        }
        // Flush the pf anchor when it was installed this session OR when stale
        // hosts entries were found — a killed session leaves the anchor behind
        // but pfAnchorInstalled resets to false, so the hosts marker is the
        // only signal that redirection may still be active.
        if pfAnchorInstalled || hostsPath != nil {
            script += "/sbin/pfctl -a \(pfAnchorName) -F all 2>/dev/null || true\n"
        }
        if !script.isEmpty {
            script += "/usr/bin/dscacheutil -flushcache 2>/dev/null || true\n"
            script += "/usr/bin/killall -HUP mDNSResponder 2>/dev/null || true\n"
            runAdminScript(script)
        }

        if let hp = hostsPath {
            try? FileManager.default.removeItem(atPath: hp)
        }

        pfAnchorInstalled = false
        isActive = false
        print("[DNSRedirection] Uninstalled")
    }

    /// Check whether the DNS redirection is currently effective.
    func verify() -> Bool {
        let host = CFHostCreateWithName(nil, "api.anthropic.com" as CFString).takeRetainedValue()
        var resolved = DarwinBoolean(false)
        CFHostStartInfoResolution(host, .addresses, nil)
        guard let addresses = CFHostGetAddressing(host, &resolved)?.takeUnretainedValue() as? [Data],
              let first = addresses.first else {
            return false
        }
        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        first.withUnsafeBytes { ptr in
            let sockaddr = ptr.bindMemory(to: sockaddr.self)
            if let base = sockaddr.baseAddress {
                getnameinfo(base, socklen_t(first.count),
                           &hostname, socklen_t(hostname.count),
                           nil, 0, NI_NUMERICHOST)
            }
        }
        let ip = String(cString: hostname)
        return loopbackAddresses().contains(ip)
    }

    // MARK: - Installed-State Detection (no admin required)

    /// True when DNS redirection is currently installed AND functional.
    /// - `/etc/hosts` is world-readable, so the marker check needs no admin.
    /// - pf rules can't be read without root, so we verify functionality
    ///   instead: a TCP connect to a hijacked loopback address on port 443
    ///   only succeeds when the pf redirect is live (the destination is
    ///   rewritten to 127.0.0.1:{tlsPort} before socket lookup).
    func isInstalled() -> Bool {
        guard let hosts = try? String(contentsOfFile: "/etc/hosts", encoding: .utf8),
              hosts.contains(hostsMarker) else { return false }
        return canConnectToHijackedAddress()
    }

    /// Try a TCP connect to each hijacked loopback address on port 443.
    /// Returns true when at least one connect succeeds (pf redirect live).
    /// Loopback connects are sub-millisecond when pf is live, so a short
    /// timeout bounds the worst case (probe races a just-started listener)
    /// while healthy installs are detected almost instantly.
    private func canConnectToHijackedAddress() -> Bool {
        for address in loopbackAddresses() {
            guard let port = NWEndpoint.Port(rawValue: 443) else { continue }
            let connection = NWConnection(
                host: NWEndpoint.Host(address), port: port, using: .tcp
            )
            let semaphore = DispatchSemaphore(value: 0)
            var connected = false
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: connected = true; semaphore.signal()
                case .failed, .cancelled: semaphore.signal()
                default: break
                }
            }
            connection.start(queue: DispatchQueue(label: "jxproxy.dns-check"))
            _ = semaphore.wait(timeout: .now() + 0.6)
            connection.cancel()
            if connected { return true }
        }
        return false
    }

    // MARK: - /etc/hosts Content Building

    /// Hostnames to transparently redirect to the local proxy.
    ///
    /// **Anthropic-only by design.** JXProxy routes Claude traffic; it must
    /// never hijack other AI providers' hostnames (OpenAI, etc.) because that
    /// silently breaks every other app that talks to them ("connection refused"
    /// on api.openai.com when the pf redirect is down). Other providers are
    /// reached explicitly by configuring the app to point at the proxy.
    private let aiHosts: [String] = [
        "api.anthropic.com",
    ]

    private func buildHostsContent(from current: String) -> String {
        var content = removeExistingEntries(current)
        var newEntries = "\n\(hostsMarker)\n"
        for (index, host) in aiHosts.enumerated() {
            let loopback = "127.0.0.\(index + 2)"
            newEntries += "\(loopback)\t\(host)\n"
            newEntries += "\(loopback)\t*.\(host)\n"
        }
        newEntries += "# End JXProxy DNS Hijack\n"
        content += newEntries
        return content
    }

    /// Dedicated loopback address (127.0.0.2, 127.0.0.3, ...) per hijacked
    /// host, used both in the /etc/hosts entries and the per-address pf
    /// redirect rules. 127.0.0.1 is never used so unrelated local TLS
    /// services bound there are left alone.
    private func loopbackAddresses() -> [String] {
        aiHosts.indices.map { "127.0.0.\($0 + 2)" }
    }

    private func removeExistingEntries(_ content: String) -> String {
        var lines = content.components(separatedBy: "\n")
        var inBlock = false
        lines = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == hostsMarker { inBlock = true; return false }
            if inBlock && trimmed == "# End JXProxy DNS Hijack" { inBlock = false; return false }
            if inBlock { return false }
            return true
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Admin Script Helper

    /// Run a shell command with administrator privileges via osascript.
    /// macOS prompts for authorization per operation. A stored admin password
    /// (SettingsView "Mac Admin Password") is intentionally NOT read or used:
    /// embedding it would leak it through `ps` (CWE-522).
    @discardableResult
    private func runAdminScript(_ shellCommand: String) -> Bool {
        // Escape backslashes and double quotes for AppleScript
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\\\\\")
            .replacingOccurrences(of: "\"", with: "\\\\\\\"")

        let script = "do shell script \"" + escaped + "\" with administrator privileges"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]

        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            print("[DNSRedirection] osascript failed: \(error)")
            return false
        }
    }
}
