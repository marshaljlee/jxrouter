import Foundation

/// Manages the `env` block JXProxy writes into Claude Code's settings file
/// (`~/.claude/settings.json`) so that every `claude` launch routes through
/// the local proxy — no shell aliases, no user-edited `.zshenv`, no launcher
/// script required.
///
/// Claude Code merges the `env` object from settings.json into the process
/// environment at startup, **overriding** the user's shell environment. That
/// gives us two superpowers:
///   1. `ANTHROPIC_BASE_URL` forces routing to `http://127.0.0.1:<port>` from
///      ANY launch context (Terminal, VS Code, tmux, cron, Spotlight, …).
///   2. Setting `ANTHROPIC_DEFAULT_*_MODEL` to `""` neutralises hardcoded model
///      overrides in `.zshenv`/`.zshrc`: an empty string is falsy, so Claude
///      Code falls back to its native tier names (`claude-sonnet-4-…`), which
///      JXProxy's tier routing then maps to the user's chosen models.
///
/// The block is applied only while the proxy is running and removed on stop,
/// restoring the user's original settings file from a one-time backup.
final class ClaudeSettingsWriter {
    static let shared = ClaudeSettingsWriter()

    /// Keys JXProxy manages inside the settings.json `env` block.
    static let managedEnvKeys: [String] = [
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_AUTH_TOKEN",
        "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY",
        "ANTHROPIC_DEFAULT_OPUS_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    ]

    private let fileManager = FileManager.default

    /// `~/.claude/settings.json`
    private var settingsURL: URL {
        home().appendingPathComponent(".claude/settings.json")
    }

    /// Backup of the pre-JXProxy settings file (one-time, before first write).
    private var backupURL: URL {
        home().appendingPathComponent(".claude/settings.json.jxproxy-bak")
    }

    private func home() -> URL { fileManager.homeDirectoryForCurrentUser }

    // MARK: - Apply

    /// Write the routing env block into Claude Code's settings. Creates the
    /// settings file and a one-time backup when needed. Returns false on failure.
    @discardableResult
    func apply(proxyPort: Int, authToken: String) -> Bool {
        var json = readSettings()

        // One-time backup of the pristine file (before our first write).
        if !fileManager.fileExists(atPath: backupURL.path) {
            if fileManager.fileExists(atPath: settingsURL.path) {
                try? fileManager.copyItem(at: settingsURL, to: backupURL)
            }
        }

        var env = json["env"] as? [String: String] ?? [:]
        env["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:\(proxyPort)"
        env["ANTHROPIC_AUTH_TOKEN"] = authToken
        env["CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY"] = "1"
        // Neutralise hardcoded shell overrides — empty string is falsy, so
        // Claude Code falls back to native tier names which JXProxy routes.
        env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = ""
        env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = ""
        env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = ""

        json["env"] = env
        return writeSettings(json)
    }

    // MARK: - Remove

    /// Remove the JXProxy routing block: strips ONLY the managed keys so any
    /// edits the user made to settings.json while the proxy ran are preserved.
    /// If JXProxy created the file from scratch (no backup existed) and nothing
    /// but the env block remains, the file is removed entirely so no trace is
    /// left behind.
    @discardableResult
    func remove() -> Bool {
        let hadBackup = fileManager.fileExists(atPath: backupURL.path)
        if hadBackup {
            try? fileManager.removeItem(at: backupURL)
        }

        guard fileManager.fileExists(atPath: settingsURL.path) else { return true }

        var json = readSettings()
        guard var env = json["env"] as? [String: String] else { return true }
        var changed = false
        for key in Self.managedEnvKeys where env.removeValue(forKey: key) != nil {
            changed = true
        }
        if !changed { return true }
        if env.isEmpty {
            json.removeValue(forKey: "env")
        } else {
            json["env"] = env
        }
        // File existed before JXProxy first ran → write the stripped version.
        if hadBackup { return writeSettings(json) }
        // JXProxy created the file → remove it entirely if nothing remains.
        if json.isEmpty {
            try? fileManager.removeItem(at: settingsURL)
            return true
        }
        return writeSettings(json)
    }

    /// True when the settings file currently carries any JXProxy-managed keys.
    func hasManagedEntries() -> Bool {
        guard fileManager.fileExists(atPath: settingsURL.path) else { return false }
        let json = readSettings()
        guard let env = json["env"] as? [String: String] else { return false }
        return Self.managedEnvKeys.contains(where: { env[$0] != nil })
    }

    // MARK: - IO

    private func readSettings() -> [String: Any] {
        guard fileManager.fileExists(atPath: settingsURL.path),
              let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    private func writeSettings(_ json: [String: Any]) -> Bool {
        let dir = settingsURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else {
            return false
        }
        do {
            try data.write(to: settingsURL, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
            return true
        } catch {
            print("[ClaudeSettingsWriter] Failed to write \(settingsURL.path): \(error)")
            return false
        }
    }
}

// MARK: - Constitution Manager

/// Seeds Claude Code's "constitution" (`~/.claude/CLAUDE.md`) with the user's
/// Agent Book core files so Claude Code integrates with them at its core and
/// obeys them on every session.
///
/// - The two Agent Book files (Joshua's Will v2 + AGENTS.md) are merged into
///   the constitution **as the default core**, so Claude Code loads them first.
/// - Any content the user already authored in `~/.claude/CLAUDE.md` is
///   **absorbed** (preserved) — never overwritten.
/// - The JXProxy-managed block is delimited by markers so re-starts update it
///   in place without duplicating, and uninstall can remove it cleanly.
final class ConstitutionManager {
    static let shared = ConstitutionManager()

    /// Constitution sources. First tries bundled app resources (for distributed
    /// builds), then falls back to local dev paths (Joshua's machine).
    static let sourcePaths: [String] = {
        var paths: [String] = []
        // Bundled resource — ships inside JXRouter.app/Contents/Resources/
        if let bundled = Bundle.main.url(forResource: "AGENTS", withExtension: "md") {
            paths.append(bundled.path)
        }
        // Dev fallback — local iCloud paths for Joshua's machine
        paths.append(contentsOf: [
            "/Users/joshua/Library/Mobile Documents/com~apple~CloudDocs/Agents Book/08 - Prompt Library/Part XVI - Utility & Tooling/113 - Joshua's Will v2.md",
            "/Users/joshua/Library/Mobile Documents/com~apple~CloudDocs/Agents Book/AGENTS.md",
        ])
        return paths
    }()

    /// Markers delimiting the JXProxy-managed block inside CLAUDE.md.
    private let startMarker = "<!-- JXProxy Constitution - managed - do not edit below -->"
    private let endMarker = "<!-- End JXProxy Constitution -->"

    private let fileManager = FileManager.default

    /// `~/.claude/CLAUDE.md`
    private var constitutionURL: URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".claude/CLAUDE.md")
    }

    // MARK: - Apply

    /// Install the Agent Book files into the constitution, absorbing any
    /// existing user content. Idempotent: re-starts update the managed block
    /// in place. Returns false when the source files are missing.
    @discardableResult
    func apply() -> Bool {
        // Read the source files; skip any that are missing (e.g. iCloud not
        // yet downloaded).
        var sources: [String] = []
        for path in Self.sourcePaths {
            guard fileManager.fileExists(atPath: path),
                  let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                print("[Constitution] Source not found (skipped): \(path)")
                continue
            }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { sources.append(trimmed) }
        }
        guard !sources.isEmpty else {
            print("[Constitution] No Agent Book sources available — leaving constitution untouched")
            return false
        }

        let existing = (try? String(contentsOfFile: constitutionURL.path, encoding: .utf8)) ?? ""
        let userPart = strippingManagedBlock(from: existing)

        let managedBlock = sources.joined(separator: "\n\n---\n\n")
        // "Set to default but absorb what the user already set up": the Agent
        // Book constitution is the default (primary) content and loads FIRST;
        // any user-authored constitution content is absorbed below it.
        let newContent: String
        if userPart.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            newContent = "\(startMarker)\n\n\(managedBlock)\n\n\(endMarker)\n"
        } else {
            newContent = "\(startMarker)\n\n\(managedBlock)\n\n\(endMarker)\n\n---\n\n\(userPart)\n"
        }

        // Idempotent: only write when the content actually changed.
        guard newContent != existing else { return true }

        let dir = constitutionURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        do {
            try newContent.write(to: constitutionURL, atomically: true, encoding: .utf8)
            print("[Constitution] Installed Agent Book constitution (\(sources.count) file(s))")
            return true
        } catch {
            print("[Constitution] Failed to write \(constitutionURL.path): \(error)")
            return false
        }
    }

    // MARK: - Remove

    /// Remove only the JXProxy-managed block, preserving user content.
    /// If nothing remains after stripping, the file is removed entirely.
    func remove() {
        guard fileManager.fileExists(atPath: constitutionURL.path),
              let existing = try? String(contentsOfFile: constitutionURL.path, encoding: .utf8) else { return }
        let userPart = strippingManagedBlock(from: existing)
        let clean = userPart.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            try? fileManager.removeItem(at: constitutionURL)
            print("[Constitution] Removed empty constitution file")
        } else if clean != existing.trimmingCharacters(in: .whitespacesAndNewlines) {
            try? (clean + "\n").write(to: constitutionURL, atomically: true, encoding: .utf8)
            print("[Constitution] Removed JXProxy block; user content preserved")
        }
    }

    /// True when the constitution currently carries the JXProxy-managed block.
    func isInstalled() -> Bool {
        guard fileManager.fileExists(atPath: constitutionURL.path),
              let existing = try? String(contentsOfFile: constitutionURL.path, encoding: .utf8) else { return false }
        return existing.contains(startMarker)
    }

    // MARK: - Helpers

    /// Strip the JXProxy-managed block (between the markers) from content,
    /// returning only the user-authored part.
    private func strippingManagedBlock(from content: String) -> String {
        guard content.contains(startMarker) else { return content }
        var lines = content.components(separatedBy: "\n")
        var inBlock = false
        lines = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == startMarker { inBlock = true; return false }
            if trimmed == endMarker { inBlock = false; return false }
            return !inBlock
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Skill Manager

/// Installs JXRouter's bundled replacement skills into `~/.claude/skills/` on
/// app start, and removes them on stop. Skills are free, standalone overrides
/// for broken or paid native tools (web search, web fetch, shell, file editor,
/// desktop automation).
///
/// - Skills are read from `JXRouter.app/Contents/Resources/skills/` at runtime.
/// - Only JXRouter-managed skill directories are removed on stop; any skills
///   the user installed independently are never touched.
/// - The install is idempotent — re-starts overwrite in place.
final class SkillManager {
    static let shared = SkillManager()

    /// Replacement skill names bundled with the app.
    static let skillNames = [
        "web-search-free",
        "web-fetch-free",
        "shell-ops",
        "file-editor",
        "desktop-automation",
    ]

    /// Marker file placed inside each skill directory to identify JXRouter-managed
    /// skills during cleanup. Contents are irrelevant — existence is the signal.
    private let markerFilename = ".jxrouter-managed"

    private let fileManager = FileManager.default

    /// `~/.claude/skills/`
    private var skillsDir: URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills")
    }

    // MARK: - Apply

    /// Copy all bundled replacement skills into `~/.claude/skills/`.
    /// Idempotent: re-starts overwrite existing managed skill directories.
    @discardableResult
    func apply() -> Bool {
        guard let resourcesURL = Bundle.main.resourceURL else {
            print("[SkillManager] No Bundle.main.resourceURL — skipping skill install")
            return false
        }

        let bundledSkillsDir = resourcesURL.appendingPathComponent("skills")
        guard fileManager.fileExists(atPath: bundledSkillsDir.path) else {
            print("[SkillManager] No bundled skills directory found — skipping")
            return false
        }

        var installed = 0
        for name in Self.skillNames {
            let src = bundledSkillsDir.appendingPathComponent(name)
            let dst = skillsDir.appendingPathComponent(name)

            guard fileManager.fileExists(atPath: src.path) else {
                print("[SkillManager] Skill not found in bundle (skipped): \(name)")
                continue
            }

            // Create destination parent if needed.
            let parent = dst.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parent.path) {
                try? fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            }

            // Remove existing copy (idempotent).
            if fileManager.fileExists(atPath: dst.path) {
                try? fileManager.removeItem(at: dst)
            }

            do {
                try fileManager.copyItem(at: src, to: dst)
                // Write marker so we know this skill was installed by us.
                let marker = dst.appendingPathComponent(markerFilename)
                try? "jxrouter".write(to: marker, atomically: true, encoding: .utf8)
                installed += 1
            } catch {
                print("[SkillManager] Failed to install \(name): \(error)")
            }
        }

        print("[SkillManager] Installed \(installed)/\(Self.skillNames.count) replacement skills")
        return installed > 0
    }

    // MARK: - Remove

    /// Remove only JXRouter-managed skill directories (identified by the marker
    /// file). Skills the user installed independently are never touched.
    func remove() {
        guard fileManager.fileExists(atPath: skillsDir.path) else { return }

        var removed = 0
        for name in Self.skillNames {
            let skillDir = skillsDir.appendingPathComponent(name)
            let marker = skillDir.appendingPathComponent(markerFilename)

            // Only remove if the marker exists — this is our managed skill.
            guard fileManager.fileExists(atPath: marker.path) else { continue }

            do {
                try fileManager.removeItem(at: skillDir)
                removed += 1
            } catch {
                print("[SkillManager] Failed to remove \(name): \(error)")
            }
        }

        print("[SkillManager] Removed \(removed) managed skill(s)")
    }

    /// True when at least one managed skill is installed.
    func isInstalled() -> Bool {
        guard fileManager.fileExists(atPath: skillsDir.path) else { return false }
        return Self.skillNames.contains { name in
            let marker = skillsDir.appendingPathComponent(name).appendingPathComponent(markerFilename)
            return fileManager.fileExists(atPath: marker.path)
        }
    }
}
