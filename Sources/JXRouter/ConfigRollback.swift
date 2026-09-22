import Foundation
import CryptoKit
import Darwin

/// One guarded file: where it lives, where its pristine copy is, and whether
/// it existed at backup time.
struct GuardedEntry: Sendable {
    let path: String
    let backup: String
    /// False means the file did not exist when guarded, so restore = delete.
    let existed: Bool
    var sha256: String?
}

enum RollbackError: LocalizedError {
    case readFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .readFailed(let p): return "Could not read \(p)"
        case .writeFailed(let p): return "Could not write \(p)"
        }
    }
}

/// Atomic backup/restore for config files JXRouter mutates on the user's
/// behalf (`~/.claude.json`, `~/.claude/settings.json`).
///
/// Ported from the Go implementation's `internal/sandbox`, with one
/// deliberate semantic change: **restore happens on abnormal termination, not
/// on normal quit.** The Go service restored on any exit because its edits
/// were session-scoped; JXRouter writes routing config the user explicitly
/// asked to persist, so reverting on a clean quit would silently undo the
/// app's whole purpose. Normal shutdown calls `release()` instead.
final class ConfigRollbackLedger: @unchecked Sendable {

    static let shared = ConfigRollbackLedger()

    /// Must match the Go suffix so stale backups from either build are found.
    static let backupSuffix = ".nexus_bak"

    private let lock = NSLock()
    private var entries: [GuardedEntry] = []

    private init() {}

    // MARK: - Guarding

    /// Backs up `path` → `path.nexus_bak`. Idempotent per path: the first
    /// backup is the pristine one and is never overwritten.
    func guardFile(_ path: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if entries.contains(where: { $0.path == path }) { return }

        let fm = FileManager.default
        let existed = fm.fileExists(atPath: path)
        let backup = path + Self.backupSuffix

        var sha: String?
        if existed {
            guard let raw = fm.contents(atPath: path) else {
                throw RollbackError.readFailed(path)
            }
            sha = Self.sha256(raw)
            try Self.atomicWrite(backup, data: raw)
        }
        entries.append(GuardedEntry(path: path, backup: backup, existed: existed, sha256: sha))
    }

    /// Backs up the standard Claude config paths.
    func guardStandard() {
        for p in Self.standardClaudePaths() {
            try? guardFile(p)
        }
    }

    static func standardClaudePaths() -> [String] {
        let home = NSHomeDirectory()
        return [
            (home as NSString).appendingPathComponent(".claude.json"),
            (home as NSString).appendingPathComponent(".claude/settings.json"),
        ]
    }

    // MARK: - Restoring

    /// Reverts every guarded file to its pristine state and removes backups.
    /// Idempotent.
    @discardableResult
    func restoreAll() -> [String] {
        lock.lock()
        let snapshot = entries
        entries = []
        lock.unlock()

        var restored: [String] = []
        for e in snapshot {
            do { try Self.restoreOne(e); restored.append(e.path) }
            catch { print("[Rollback] restore failed for \(e.path): \(error.localizedDescription)") }
        }
        return restored
    }

    /// Drops backups *without* reverting — the correct behaviour for a clean
    /// quit, where the user's config changes should survive.
    func release() {
        lock.lock()
        let snapshot = entries
        entries = []
        lock.unlock()
        for e in snapshot {
            try? FileManager.default.removeItem(atPath: e.backup)
        }
    }

    private static func restoreOne(_ e: GuardedEntry) throws {
        let fm = FileManager.default
        if e.existed {
            guard let raw = fm.contents(atPath: e.backup) else {
                throw RollbackError.readFailed(e.backup)
            }
            try atomicWrite(e.path, data: raw)
            try? fm.removeItem(atPath: e.backup)
        } else {
            if fm.fileExists(atPath: e.path) { try fm.removeItem(atPath: e.path) }
            try? fm.removeItem(atPath: e.backup)
        }
    }

    /// Applies `mutate` to `~/.claude.json` under guard. The only sanctioned
    /// mutation path for Claude config.
    func modifyClaudeConfig(_ mutate: (Data?) throws -> Data) throws {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".claude.json")
        try guardFile(path)
        let current = FileManager.default.contents(atPath: path)
        let next = try mutate(current)
        try Self.atomicWrite(path, data: next)
    }

    // MARK: - Crash recovery

    /// Cleans up backups left behind by a previous hard crash (`kill -9`).
    /// A guarded file that changed after its backup is reverted; an unchanged
    /// one just loses its stale backup. Call once at startup.
    func recoverStale(paths: [String]? = nil) -> [String] {
        var restored: [String] = []
        for p in paths ?? Self.standardClaudePaths() {
            let bak = p + Self.backupSuffix
            guard let raw = FileManager.default.contents(atPath: bak) else { continue }
            let current = FileManager.default.contents(atPath: p)

            if let current {
                if current != raw {
                    if (try? Self.atomicWrite(p, data: raw)) != nil { restored.append(p) }
                }
            } else if FileManager.default.fileExists(atPath: p) {
                // Created by the crashed session; the pristine state was absent.
                if (try? Self.atomicWrite(p, data: raw)) != nil { restored.append(p) }
            }
            try? FileManager.default.removeItem(atPath: bak)
        }
        return restored
    }

    // MARK: - Audit

    func snapshot() -> [GuardedEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return entries.isEmpty }

    // MARK: - Helpers

    /// Writes via temp file → fsync → chmod 0600 → rename, so a crash can
    /// never leave a half-written config.
    static func atomicWrite(_ path: String, data: Data) throws {
        let dir = (path as NSString).deletingLastPathComponent
        let tmp = dir + "/.nexus_tmp_\(UUID().uuidString)"
        guard FileManager.default.createFile(atPath: tmp, contents: data) else {
            throw RollbackError.writeFailed(tmp)
        }
        chmod(tmp, 0o600)
        // Flush to disk before the rename, otherwise a crash right after can
        // leave the renamed file with no content on disk.
        if let fh = FileHandle(forWritingAtPath: tmp) {
            try? fh.synchronize()
            try? fh.close()
        }
        // rename is atomic within a filesystem
        if rename(tmp, path) != 0 {
            try? FileManager.default.removeItem(atPath: tmp)
            throw RollbackError.writeFailed(path)
        }
    }

    static func sha256(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Sentinel

/// Reverts guarded config when the process is told to terminate, so an
/// interrupted run never leaves `~/.claude` pointing at a dead proxy.
///
/// Deliberately does **not** re-raise the signal or call exit: `AppDelegate`
/// already owns termination (it disables the system proxy, then exits), and
/// terminating here first would skip that cleanup and leave the machine with
/// no working network. This only restores files.
final class RollbackSentinel: @unchecked Sendable {

    static let shared = RollbackSentinel()

    private let queue = DispatchQueue(label: "com.jxrouter.rollback.sentinel")
    private let once = NSLock()
    private var didFire = false
    private var restoredAt: Date?

    private init() {}

    /// One-shot restore on the calling queue. Safe to call repeatedly.
    ///
    /// Synchronous on purpose: `AppDelegate` may `exit(0)` immediately after,
    /// and an async restore would be cut off mid-write, leaving a half-restored
    /// config — exactly the state this exists to prevent.
    @discardableResult
    func fireSynchronously() -> [String] {
        queue.sync {
            if self.didFire { return [String]() }
            self.didFire = true
            let restored = ConfigRollbackLedger.shared.restoreAll()
            self.restoredAt = Date()
            if !restored.isEmpty {
                print("[Rollback] restored \(restored.count) file(s): \(restored.joined(separator: ", "))")
            }
            return restored
        }
    }

    /// Convenience async variant for non-urgent call sites.
    func fire() {
        queue.async { [weak self] in _ = self?.fireSynchronously() }
    }

    /// Clean up on a normal quit: no restore (the app has already reverted
    /// Claude's settings via stopProxy), just drop the now-redundant backups
    /// so no stray .nexus_bak files are left behind.
    func disarm() {
        once.lock()
        defer { once.unlock() }
        ConfigRollbackLedger.shared.release()
    }

    func restorTimestamp() -> Date? { restoredAt }
}
