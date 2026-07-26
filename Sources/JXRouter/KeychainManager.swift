@preconcurrency import Foundation
@preconcurrency import Security

/// Secure storage for API keys and secrets using the macOS Keychain.
///
/// **Thread safety**: Because `SecItemCopyMatching` can hang when the Keychain
/// daemon is unresponsive (e.g. securityd issue), all Keychain reads use a
/// background dispatch with a 3-second timeout.
enum KeychainManager {
    static let service = "com.jxrouter"

    /// Performs `SecItemCopyMatching` with a 3-second timeout.
    /// Returns `(status, result)` on success, or `nil` on timeout.
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
            print("[Keychain] SecItemCopyMatching timed out — marking Keychain unavailable")
            unavailable = true
            return nil
        }
        return (box.status, box.result)
    }

    /// Set to true after the first timeout to skip Keychain reads in subsequent calls.
    private nonisolated(unsafe) static var unavailable = false

    /// Store a secret value in the Keychain.
    static func store(key: String, value: String) throws {
        guard !value.isEmpty else {
            try delete(key: key)
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: Data(value.utf8),
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            print("[Keychain] store(\(key)) failed: \(status)")
        }
        guard status == errSecSuccess else {
            throw KeychainError.storeFailed(status: status)
        }
    }

    /// Retrieve a secret value from the Keychain.
    /// Returns nil on timeout or error (never hangs indefinitely).
    static func retrieve(key: String) -> String? {
        guard !unavailable else { return nil }

        guard let (status, result) = copyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary),
              status == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Delete a secret from the Keychain.
    static func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status: status)
        }
    }

    /// Retrieve all stored keys and values.
    static func getAll() -> [String: String] {
        guard !unavailable else { return [:] }

        guard let (status, result) = copyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnData: true,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ] as CFDictionary),
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

    /// Set a value only if it doesn't already exist (for migration).
    static func setIfMissing(key: String, value: String) throws {
        guard retrieve(key: key) == nil, !value.isEmpty else { return }
        try store(key: key, value: value)
    }
}

enum KeychainError: LocalizedError {
    case storeFailed(status: OSStatus)
    case deleteFailed(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .storeFailed(let status):
            return "Keychain store failed (OSStatus: \(status))"
        case .deleteFailed(let status):
            return "Keychain delete failed (OSStatus: \(status))"
        }
    }
}
