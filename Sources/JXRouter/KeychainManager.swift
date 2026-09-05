@preconcurrency import Foundation
@preconcurrency import Security
import LocalAuthentication

/// Secure storage for API keys and secrets using the macOS Keychain.
///
/// **Thread safety**: Because `SecItemCopyMatching` can hang when the Keychain
/// daemon is unresponsive (e.g. securityd issue, or the keychain is still
/// locked at login), ALL Keychain operations — reads AND writes — run on a
/// background queue with a timeout, so the UI thread can never block on the
/// Keychain.
///
/// **Prompt-free access (ticket: keychain ACL self-heal)**: macOS records, per
/// item, which applications may read it without a permission prompt. Items
/// written by the `security` CLI (or an old build) may list only that tool,
/// so the app gets a "wants to use your confidential information" prompt on
/// EVERY read — the "keeps asking for keychain password" symptom. Every write
/// therefore attaches the app's own trusted-application to the item's ACL,
/// and `repairAccessControlForAllKeys()` rewrites the ACL of any pre-existing
/// item, so reads are silent and stay silent across rebuilds (the trust is
/// the app's designated requirement at its bundle path, which is stable for
/// certificate-signed builds).
///
/// **Abstraction over secret storage** so the unit-test target can inject an
/// in-memory backend. The app always uses the real Keychain (testingBackend
/// stays nil); only the test bundle sets it.
protocol KeychainBackend {
    var isUnavailable: Bool { get }
    func store(key: String, value: String) throws
    func retrieve(key: String) -> String?
    func delete(key: String) throws
    func getAll() -> [String: String]
    func setIfMissing(key: String, value: String) throws
    func resetUnavailable()
}

enum KeychainManager {
    static let service = "com.jxproxy"

    /// Test seam — when non-nil, every operation routes to this backend
    /// instead of the real Keychain. Internal: never set by app code; the
    /// JXRouterTests bundle sets it in setUp and clears it in tearDown.
    static var testingBackend: KeychainBackend?

    // MARK: - In-memory read cache (the "900 keychain prompts" fix)
    //
    // Every SecItemCopyMatching is a separate Keychain interaction: launch,
    // each Settings open, each save, each verification, and every routed
    // request (apiKey(for:) per request) each read their own items. With ~10
    // items that is hundreds of interactions per session, and any item not
    // ACL-trusted by THIS build pops the macOS authorization dialog once per
    // READ — the "type your keychain password 900 times" symptom.
    //
    // The cache reads EVERYTHING in one batched getAll() on first access and
    // serves every later retrieve() from memory. Writes update the cache (and
    // the Keychain) together, so the cache can never go stale within a
    // session. One batched read = at most one "Always Allow" instead of one
    // prompt per item per read.

    private nonisolated(unsafe) static var cache: [String: String]?
    private static let cacheLock = NSLock()

    /// Serve `key` from the cache, batch-loading all items on first access.
    /// Once the cache is loaded it is AUTHORITATIVE: a nil result means "the
    /// key is absent" (e.g. just deleted) — NOT a miss — so it never triggers
    /// a re-load. Only an unloaded cache (nil cache itself) batch-loads.
    private static func cachedRetrieve(_ key: String) -> String? {
        if testingBackend != nil { return nil } // tests bypass the cache
        cacheLock.lock()
        let loaded = cache
        cacheLock.unlock()
        if let loaded { return loaded[key] }
        // First access this session: one batched read of every item.
        let all = getAll(service: service, bypassCache: true)
        cacheLock.lock()
        cache = all
        cacheLock.unlock()
        return all[key]
    }

    private static func cacheUpdate(_ key: String, value: String?) {
        if testingBackend != nil { return }
        cacheLock.lock()
        if cache != nil {
            if let value { cache?[key] = value } else { cache?.removeValue(forKey: key) }
        }
        cacheLock.unlock()
    }

    /// Drop the cache so the next read batch-loads fresh values from the
    /// Keychain (used after external writes, e.g. shell-config import).
    static func invalidateCache() {
        if testingBackend != nil { return }
        cacheLock.lock()
        cache = nil
        cacheLock.unlock()
    }

    /// Prevents ALL user interaction during Keychain operations. JXProxy
    /// launches at login (a login item), where the login keychain can still
    /// be locked — without this, every SecItem read/write popped the macOS
    /// "enter your password to unlock keychain" dialog, and the ACL self-heal
    /// re-prompted for authorization ("JXRouter wants to make changes to your
    /// keychain") on every retry when the user declined. Operations now fail
    /// silently instead; the app's own items stay readable because every
    /// write attaches the app's ACL trust (see `selfTrustedAccess`).
    ///
    /// Uses an LAContext with `interactionNotAllowed` (the modern,
    /// non-deprecated equivalent of kSecUseAuthenticationUIFail).
    private static func noPromptContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    /// Runs `body` on a background queue, waiting up to `seconds`. Returns nil
    /// when the operation timed out (Keychain daemon unresponsive, keychain
    /// locked, permission prompt pending) — never blocks the caller forever.
    private static func timed<T>(_ seconds: TimeInterval, _ body: @escaping () -> T) -> T? {
        let group = DispatchGroup()
        group.enter()
        let box = Box<T>()
        DispatchQueue.global().async {
            box.value = body()
            group.leave()
        }
        guard group.wait(timeout: .now() + seconds) != .timedOut else { return nil }
        return box.value
    }

    /// Performs `SecItemCopyMatching` with a 3-second timeout. Callers build
    /// the query with the prompt-free LAContext attached (see
    /// `noPromptContext`), so reads never show a keychain-unlock or
    /// authorization dialog. Returns `(status, result)` on success, or `nil`
    /// on timeout.
    private static func copyMatching(_ query: CFDictionary) -> (OSStatus, AnyObject?)? {
        let group = DispatchGroup()
        group.enter()

        // Use an actor-like box to share status/result across threads safely.
        final class Box: @unchecked Sendable {
            var status: OSStatus = errSecItemNotFound
            var result: AnyObject? = nil
        }

        let box = Box()
        DispatchQueue.global().async {
            box.status = SecItemCopyMatching(query, &box.result)
            group.leave()
        }

        guard group.wait(timeout: .now() + 3.0) != .timedOut else {
            print("[Keychain] SecItemCopyMatching timed out — entering retry cooldown")
            enterCooldown()
            return nil
        }
        return (box.status, box.result)
    }

    /// Set to a future date after the first timeout so Keychain reads are
    /// skipped during the cooldown. Unlike the old permanent "unavailable"
    /// latch, reads RETRY once the cooldown passes — a keychain that was
    /// briefly locked at login (or stalled behind a permission prompt) must
    /// not make the app report "no API key" for the entire session.
    private nonisolated(unsafe) static var unavailableUntil = Date.distantPast

    /// After a timeout, wait this long before trying the Keychain again.
    private static let cooldownDuration: TimeInterval = 20

    private static func enterCooldown() {
        unavailableUntil = Date().addingTimeInterval(cooldownDuration)
    }

    /// Whether the most recent Keychain read cycle failed (timed out).
    /// ConfigManager snapshots this at startup to distinguish "the user
    /// cleared a field" from "the app never saw the real keys".
    static var isUnavailable: Bool {
        testingBackend?.isUnavailable ?? (Date() < unavailableUntil)
    }

    /// Reset the unavailable flag after a recovery cycle (or after the
    /// cooldown passes — reads retry on their own).
    static func resetUnavailable() {
        if testingBackend != nil {
            testingBackend?.resetUnavailable()
            return
        }
        unavailableUntil = .distantPast
    }

    // MARK: - Legacy keychain ACL shims
    //
    // SecTrustedApplicationCreateFromPath / SecAccessCreate are marked
    // deprecated since macOS 10.10, but there is NO replacement for
    // classic-keychain application-trust ACLs — SecAccessControl only covers
    // data-protection keychain (which also needs an entitlement this
    // non-sandboxed app doesn't have). They are bound here directly to the C
    // symbols via @_silgen_name, which bypasses the Clang importer's
    // deprecation annotation entirely, so the build stays warning-free
    // without a C/bridging-header shim.

    @_silgen_name("SecTrustedApplicationCreateFromPath")
    private static func jxSecTrustedApplicationCreateFromPath(_ path: UnsafePointer<CChar>?, _ app: UnsafeMutablePointer<SecTrustedApplication?>) -> OSStatus

    @_silgen_name("SecAccessCreate")
    private static func jxSecAccessCreate(_ descriptor: CFString, _ trustedList: CFArray?, _ access: UnsafeMutablePointer<SecAccess?>) -> OSStatus

    /// A `SecAccess` that trusts the app's own binary — the exact "trust this
    /// app" entry macOS records when a user clicks Allow/Always Allow. Built
    /// from the app's bundle path so the item's ACL carries the app's
    /// designated requirement (certificate-based for signed builds → stable
    /// across rebuilds, so the permission never comes back).
    static func selfTrustedAccess() -> SecAccess? {
        var app: SecTrustedApplication?
        let path = Bundle.main.bundlePath
        let status = path.isEmpty
            ? jxSecTrustedApplicationCreateFromPath(nil, &app)
            : jxSecTrustedApplicationCreateFromPath(path, &app)
        guard status == errSecSuccess, let app else { return nil }
        var access: SecAccess?
        guard jxSecAccessCreate(service as CFString, [app] as CFArray, &access) == errSecSuccess else { return nil }
        return access
    }

    /// Store a secret value in the Keychain.
    /// The item's access-control list is set to trust the app itself, so reads
    /// never trigger a permission prompt (even for items that previously only
    /// trusted the `security` CLI or an old build).
    static func store(key: String, value: String) throws {
        if let backend = testingBackend {
            try backend.store(key: key, value: value)
            return
        }
        guard !value.isEmpty else {
            try delete(key: key)
            return
        }

        // NOTE: deliberately NOT using kSecUseDataProtectionKeychain. That flag
        // requires the keychain-access-groups entitlement (errSecMissingEntitlement
        // -34018 otherwise) and this app is non-sandboxed with no entitlements.
        // Classic login-keychain storage works without any entitlement and is
        // visible to reads (retrieve/getAll) and the `security` CLI.
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        // No unlock/authorization dialogs (see noPromptContext) — a locked
        // keychain fails the write silently instead of popping the macOS
        // password prompt. The next write after the keychain is unlocked
        // succeeds normally.
        query[kSecUseAuthenticationContext as String] = noPromptContext()
        // Trust the app itself (self-healing ACL): the update path also
        // re-applies it, repairing items that were previously only readable
        // with a permission prompt.
        if let access = selfTrustedAccess() {
            query[kSecAttrAccess as String] = access
        }

        // Add first; only update when the item already exists. NEVER
        // delete-then-add: if the add fails (e.g. Keychain interaction is
        // temporarily blocked), the previous secret must survive. A lost key
        // here silently breaks every provider that used it.
        guard let status = timed(3.0, {
            var status = SecItemAdd(query as CFDictionary, nil)
            if status == errSecDuplicateItem {
                var update = query
                update.removeValue(forKey: kSecValueData as String)
                status = SecItemUpdate(update as CFDictionary, [kSecValueData: Data(value.utf8)] as CFDictionary)
            }
            return status
        }) else {
            print("[Keychain] store(\(key)) timed out — Keychain unresponsive; key not saved")
            throw KeychainError.timedOut
        }
        if status != errSecSuccess {
            print("[Keychain] store(\(key)) failed: \(status)")
            throw KeychainError.storeFailed(status: status)
        }
        // Keep the cache in sync so a store-followed-by-read never re-hits
        // the Keychain (and can never re-prompt for the same item).
        cacheUpdate(key, value: value)
    }

    /// Retrieve a secret value from the Keychain. Reads are served from the
    /// in-memory cache (batch-loaded once per launch) so repeated lookups —
    /// per request, per Settings open, per save — never touch the Keychain
    /// daemon and can never repeat an authorization prompt.
    /// Returns nil on timeout or error (never hangs indefinitely).
    static func retrieve(key: String) -> String? {
        if let backend = testingBackend {
            return backend.retrieve(key: key)
        }
        guard !isUnavailable else { return nil }
        return cachedRetrieve(key)
    }

    /// Delete a secret from the Keychain.
    static func delete(key: String) throws {
        if let backend = testingBackend {
            try backend.delete(key: key)
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        var noPromptQuery = query
        noPromptQuery[kSecUseAuthenticationContext as String] = noPromptContext()
        guard let status = timed(3.0, { SecItemDelete(noPromptQuery as CFDictionary) }) else {
            print("[Keychain] delete(\(key)) timed out — Keychain unresponsive")
            throw KeychainError.timedOut
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status: status)
        }
        cacheUpdate(key, value: nil)
    }

    /// Retrieve all stored keys and values from the app's own service.
    static func getAll() -> [String: String] {
        getAll(service: service, bypassCache: false)
    }

    /// Retrieve all stored keys and values from a given service. When
    /// `bypassCache` is set the values are read from the Keychain directly —
    /// used by the cache's own batch-load and by the cache invalidation path.
    private static func getAll(service: String, bypassCache: Bool) -> [String: String] {
        if !bypassCache, let backend = testingBackend {
            return backend.getAll()
        }
        if let backend = testingBackend {
            return backend.getAll()
        }
        guard !isUnavailable else { return [:] }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        // Prompt-free: a locked keychain or an un-trusted item fails silently
        // instead of popping the macOS password dialog.
        query[kSecUseAuthenticationContext as String] = noPromptContext()

        guard let (status, result) = copyMatching(query as CFDictionary),
              status == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return [:]
        }

        var dict: [String: String] = [:]
        for item in items {
            if let account = item[kSecAttrAccount as String] as? String,
               let data = item[kSecValueData as String] as? Data,
               let value = String(data: data, encoding: .utf8) {
                dict[account] = value
            }
        }
        return dict
    }

    /// One-time self-heal: make every item in this app's service readable by
    /// the app WITHOUT a permission prompt.
    ///
    /// Why this exists: items written by the `security` CLI (or a very old
    /// build) list only that writer in their access-control list, so the app
    /// gets a "wants to use your confidential information" prompt on EVERY
    /// read — every launch, every Settings open, every key lookup. Rewriting
    /// the ACL with the app's own trust (see `selfTrustedAccess`) makes reads
    /// silent from then on. Only the access-control list is touched; values
    /// are never modified.
    ///
    /// The write is prompt-free (`kSecUseAuthenticationUIFail`): it succeeds
    /// when the app is already trusted (or the keychain is unlocked and
    /// updating is permitted), and fails silently otherwise. No password
    /// dialog is ever shown.
    ///
    /// - Returns: false when any item's repair is still pending (write
    ///   refused or the keychain stayed busy), so the caller can schedule a
    ///   bounded retry.
    static func repairAccessControlForAllKeys() -> Bool {
        guard testingBackend == nil, !isUnavailable, let access = selfTrustedAccess() else { return false }
        var allRepaired = true
        // Items written by an older or differently-signed build list only
        // that writer in their ACL, so the app prompts on EVERY read — the
        // "keeps asking for keychain password" symptom.
        for serviceName in [service] {
            let accounts = getAll(service: serviceName, bypassCache: true).keys
            for account in accounts {
                var query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: serviceName,
                    kSecAttrAccount as String: account,
                ]
                query[kSecUseAuthenticationContext as String] = noPromptContext()
                guard let status = timed(45.0, {
                    SecItemUpdate(query as CFDictionary, [kSecAttrAccess: access] as CFDictionary)
                }) else {
                    print("[Keychain] ACL repair for \(account) timed out — will retry next launch")
                    enterCooldown()
                    allRepaired = false
                    continue
                }
                if status != errSecSuccess {
                    print("[Keychain] ACL repair for \(account) failed: \(status)")
                    allRepaired = false
                }
            }
        }
        return allRepaired
    }

    /// Set a value only if it doesn't already exist (for migration).
    static func setIfMissing(key: String, value: String) throws {
        if let backend = testingBackend {
            try backend.setIfMissing(key: key, value: value)
            return
        }
        guard retrieve(key: key) == nil, !value.isEmpty else { return }
        try store(key: key, value: value)
    }
}

/// Thread-safe box for sharing a value across the timeout boundary.
private final class Box<T>: @unchecked Sendable {
    var value: T?
}

enum KeychainError: LocalizedError {
    case storeFailed(status: OSStatus)
    case deleteFailed(status: OSStatus)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .storeFailed(let status):
            return "Keychain store failed (OSStatus: \(status))"
        case .deleteFailed(let status):
            return "Keychain delete failed (OSStatus: \(status))"
        case .timedOut:
            return "Keychain did not respond in time"
        }
    }
}
