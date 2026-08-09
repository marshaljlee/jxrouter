import Foundation

/// ⛔️ PERMANENTLY DISABLED — DNS + pf hijacking must NEVER be re-added.
///
/// This app used to "redirect" AI API hostnames by writing blocks into
/// `/etc/hosts` (mapping hosts to loopback addresses) and loading `pfctl`
/// `rdr` anchors that forwarded their :443 traffic to the local TLS port.
/// That mechanism repeatedly took down the user's WHOLE system connection:
/// a `cp /etc/hosts` race or truncated write, a stale system proxy pointing
/// at a dead port, leftover pf anchors surviving crashes/reboots, and legacy
/// `# ProxySwitch DNS Hijack` blocks from older app versions all produced
/// "no internet until the user manually sed-ed /etc/hosts". Every agent that
/// touched the feature re-broke it.
///
/// AI traffic is now routed WITHOUT any admin-level system mutation:
///   • Claude Code        → ~/.claude/settings.json base-URL override
///   • Other AI apps      → the optional system-wide HTTP proxy (Settings)
///   • Launchers          → jxclaude / jxcodex / jxpi export explicit base URLs
///
/// This class therefore contains NO install path. It exists only to sweep
/// leftover hijack state written by old versions (hosts blocks with any
/// "DNS Hijack" marker, including the legacy ProxySwitch one, and the old pf
/// anchor) so the system is left exactly as the user expects it. Do not
/// re-add `install()` / hosts writes / pf rules. See
/// `.agents/rules/00-master-foundry.md` (standing constraints).
final class DNSRedirectionManager: @unchecked Sendable {
    static let shared = DNSRedirectionManager()

    /// Old pf anchor name — flushed during cleanup if present.
    private let pfAnchorName = "com.apple/250.jxproxy"

    /// Last error encountered by the cleanup manager.
    private(set) var lastError: String?

    private init() {}

    // MARK: - Cleanup

    /// Remove ALL leftover DNS-hijack state from old app versions:
    /// `/etc/hosts` blocks (current "JXProxy DNS Hijack" marker and legacy
    /// "ProxySwitch DNS Hijack" marker, which older builds wrote and nothing
    /// ever cleaned) plus the old pf anchor.
    ///
    /// An admin script runs ONLY when there is actually something to clean, so
    /// a healthy system never sees an admin prompt. This is a no-op when the
    /// system is already clean — call it freely on launch, stop, and uninstall.
    func uninstall() {
        lastError = nil

        // 1. Read /etc/hosts and strip every hijack block (any marker line
        //    containing "DNS Hijack", through its "# End … DNS Hijack" line).
        let newContent: String?
        if let current = try? String(contentsOfFile: "/etc/hosts", encoding: .utf8) {
            let cleaned = Self.cleanedHostsContent(current)
            newContent = cleaned != current ? cleaned : nil
        } else {
            newContent = nil
        }

        // 2. Build a single admin script, but only when there is real work.
        //    The pf anchor cannot be inspected without root, so it is flushed
        //    whenever we are already asking for admin for hosts cleanup. On a
        //    clean system (no hosts blocks) we never prompt.
        var script = ""
        var hostsTempPath: String?
        if let content = newContent {
            let tmp = "/tmp/jxproxy-hosts-clean.tmp"
            do {
                try content.write(toFile: tmp, atomically: true, encoding: .utf8)
                hostsTempPath = tmp
                script += "cp \(tmp) /etc/hosts\n"
            } catch {
                print("[DNSRedirection] Failed to write temp hosts file: \(error)")
            }
        }
        if !script.isEmpty {
            script += "/sbin/pfctl -a \(pfAnchorName) -F all 2>/dev/null || true\n"
            script += "/usr/bin/dscacheutil -flushcache 2>/dev/null || true\n"
            script += "/usr/bin/killall -HUP mDNSResponder 2>/dev/null || true\n"
            runAdminScript(script)
        }

        if let hostsTempPath {
            try? FileManager.default.removeItem(atPath: hostsTempPath)
        }

        print("[DNSRedirection] Cleanup finished (hosts changed: \(newContent != nil))")
    }

    /// True when a leftover hijack block is still present in /etc/hosts.
    /// Read-only — used for diagnostics and to decide whether cleanup will
    /// prompt for admin. Never installs anything.
    func isInstalled() -> Bool {
        guard let hosts = try? String(contentsOfFile: "/etc/hosts", encoding: .utf8) else {
            return false
        }
        return hosts.contains("DNS Hijack")
    }

    // MARK: - /etc/hosts Content Building

    /// Remove every hijack block from the given /etc/hosts content, handling
    /// both the current "# JXProxy DNS Hijack — …" block and the legacy
    /// "# ProxySwitch DNS Hijack" block (with or without an end marker — the
    /// blocks were always appended at the end of the file, so skipping to EOF
    /// when no end marker exists is safe).
    static func cleanedHostsContent(_ content: String) -> String {
        var lines = content.components(separatedBy: "\n")
        var inBlock = false
        lines = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inBlock {
                // Start of any hijack block: a comment line whose text contains
                // "DNS Hijack". Covers "# JXProxy DNS Hijack …", "# ProxySwitch
                // DNS Hijack", and any future variant.
                if trimmed.hasPrefix("#"), trimmed.contains("DNS Hijack") {
                    inBlock = true
                    return false
                }
                return true
            }
            // Inside a block: skip until the end marker.
            if trimmed.hasPrefix("# End"), trimmed.contains("DNS Hijack") {
                inBlock = false
            }
            return false
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Admin Script Helper

    /// Run a shell command with administrator privileges via osascript.
    /// macOS prompts for authorization per operation. A stored admin password
    /// is intentionally NOT read or used: embedding it would leak it through
    /// `ps` (CWE-522).
    @discardableResult
    private func runAdminScript(_ shellCommand: String) -> Bool {
        // Escape backslashes and double quotes for AppleScript
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

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
