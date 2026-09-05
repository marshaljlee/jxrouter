import Foundation
import Security

/// Loads a TLS identity from PEM files on disk.
/// Returns `sec_identity_t?` (Network.framework type).
struct PEMIdentityLoader {
    static func load(certPath: URL, keyPath: URL) -> sec_identity_t? {
        guard let certData = try? Data(contentsOf: certPath),
              let keyData = try? Data(contentsOf: keyPath) else { return nil }

        guard let secCert = SecCertificateCreateWithData(nil, certData as CFData) else { return nil }

        // Extract private key from PEM
        let keyStr = String(data: keyData, encoding: .utf8) ?? ""
        let stripped = keyStr
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let derData = Data(base64Encoded: stripped) else { return nil }

        // Create private key
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        guard let privKey = SecKeyCreateWithData(derData as CFData, attributes as CFDictionary, nil) else { return nil }

        // Store cert + key in keychain, then query for the identity
        let certTag = "com.jxproxy.cert-\(UUID().uuidString)"
        let keyTag = "com.jxproxy.key-\(UUID().uuidString)"

        let certQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: secCert,
            kSecAttrApplicationTag as String: certTag.data(using: .utf8)!,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(certQuery as CFDictionary, nil)

        let keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecValueRef as String: privKey,
            kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(keyQuery as CFDictionary, nil)

        // Query for the identity
        let identityQuery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var identityRef: AnyObject?
        let status = SecItemCopyMatching(identityQuery as CFDictionary, &identityRef)

        // Cleanup temp items
        SecItemDelete(certQuery as CFDictionary)
        SecItemDelete(keyQuery as CFDictionary)

        guard status == errSecSuccess else { return nil }
        guard let identity = identityRef else { return nil }
        // Use unsafeBitCast since the downcast warning is about CFTypeRef -> SecIdentity
        let secIdentity: SecIdentity = unsafeBitCast(identity, to: SecIdentity.self)
        return sec_identity_create(secIdentity)
    }

    static func load(certPath: String, keyPath: String) -> sec_identity_t? {
        load(certPath: URL(fileURLWithPath: certPath), keyPath: URL(fileURLWithPath: keyPath))
    }
}
