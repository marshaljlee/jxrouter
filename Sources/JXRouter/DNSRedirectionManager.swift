import Foundation

/// Manages DNS redirection and port forwarding for intercepting AI API traffic.
///
/// Uses two mechanisms together:
/// 1. `/etc/hosts` entries to resolve AI API hostnames to 127.0.0.1
/// 2. `pfctl` anchor to redirect 127.0.0.1:443 → 127.0.0.1:{proxyPort}
///
/// **Single osascript prompt**: All admin operations are batched into one
/// `do shell script ... with administrator privileges` call so the user only
/// authorizes once per install/uninstall.
final class DNSRedirectionManager: @unchecked Sendable {
    static let shared = DNSRedirectionManager()

    /// Marker comment in /etc/hosts to identify our entries.
    private let hostsMarker = "# JXProxy DNS Hijack \u{2014} do not edit manually"
    private let pfAnchorName = "com.apple/250.jxproxy"

    /// Whether DNS redirection is currently active.
    private(set) var isActive = false

    /// Whether a pf anchor has been set up (tracked for cleanup).
    private var pfAnchorInstalled = false

    /// Last error encountered by the DNS manager.
    private(set) var lastError: String?

    private init() {}

    // MARK: - Public API

    /// Install DNS redirection and pf port forwarding.
    /// - Parameter proxyPort: The local port the proxy listens on (e.g. 5255).
    /// - Returns: true if both DNS and pf were installed successfully.
    @discardableResult
    func install(proxyPort: UInt16) -> Bool {
        lastError = nil

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
        let pfConf = """
        rdr pass on lo0 inet proto tcp from any to 127.0.0.1 port 443 -> 127.0.0.1 port \(proxyPort)
        """

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

        // Single osascript call for all cleanup
        var script = ""
        if let hp = hostsPath {
            script += "cp \(hp) /etc/hosts\n"
        }
        if pfAnchorInstalled {
            script += "/sbin/pfctl -a \(pfAnchorName) -F all 2>/dev/null || true\n"
        }
        script += "/usr/bin/dscacheutil -flushcache 2>/dev/null || true\n"
        script += "/usr/bin/killall -HUP mDNSResponder 2>/dev/null || true\n"

        if !script.isEmpty {
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
        return ip == "127.0.0.1"
    }

    // MARK: - /etc/hosts Content Building

    /// AI API hostnames to redirect. Drawn from RequestClassifier patterns.
    private let aiHosts: [String] = [
        "api.anthropic.com",
        "api.openai.com",
        "api.openrouter.ai",
        "opencode.ai",
        "integrate.api.nvidia.com",
        "api.groq.com",
        "api.mistral.ai",
        "api.deepseek.com",
        "api.cerebras.ai",
        "api.cohere.ai",
        "api.perplexity.ai",
        "api.together.xyz",
        "api.fireworks.ai",
        "api.replicate.com",
        "api.x.ai",
        "api.sambanova.ai",
        "generativelanguage.googleapis.com",
    ]

    private func buildHostsContent(from current: String) -> String {
        var content = removeExistingEntries(current)
        var newEntries = "\n\(hostsMarker)\n"
        for host in aiHosts {
            newEntries += "127.0.0.1\t\(host)\n"
            newEntries += "127.0.0.1\t*.\(host)\n"
        }
        newEntries += "127.0.0.1\t*.anthropic.com\n"
        newEntries += "# End JXProxy DNS Hijack\n"
        content += newEntries
        return content
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
    /// Shows a single password prompt for the whole batch.
    @discardableResult
    private func runAdminScript(_ shellCommand: String) -> Bool {
        // Escape backslashes and double quotes for AppleScript
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\\\\\")
            .replacingOccurrences(of: "\"", with: "\\\\\\\"")
            
        let adminPassword = ConfigManager.shared.getApiKey(chainKey: ConfigManager.KeychainKey.adminPassword)
        let pwdEscaped = adminPassword
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            
        let authClause = adminPassword.isEmpty ? "with administrator privileges" : "password \"\(pwdEscaped)\" with administrator privileges"
        
        let script = "do shell script \"" + escaped + "\" \(authClause)"
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
