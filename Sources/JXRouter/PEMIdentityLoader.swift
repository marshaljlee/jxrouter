import Foundation
@preconcurrency import Security

/// Utility to create Security framework identities from PEM files
/// WITHOUT importing into the Keychain (avoids keychain access prompts).
///
/// Two-phase approach:
/// 1. `SecIdentityCreate` creates a `SecIdentityRef` from cert + key (no keychain)
/// 2. `sec_identity_create` wraps it into a `sec_identity_t` for Network.framework
///
/// No keychain writes = no system dialogs asking for keychain permission.
enum PEMIdentityLoader {

    /// Create a `sec_identity_t` from PEM certificate and private key files.
    /// - Parameters:
    ///   - certPath: Path to PEM-encoded certificate file
    ///   - keyPath: Path to PEM-encoded private key file
    /// - Returns: A `sec_identity_t` suitable for `sec_protocol_options_set_local_identity`,
    ///           or nil if parsing fails.
    static func load(certPath: URL, keyPath: URL) -> sec_identity_t? {
        guard let certificate = loadCertificate(certPath) else {
            print("[PEMIdentity] Failed to load certificate from \(certPath.path)")
            return nil
        }
        guard let privateKey = loadPrivateKey(keyPath) else {
            print("[PEMIdentity] Failed to load private key from \(keyPath.path)")
            return nil
        }
        // Phase 1: Create SecIdentityRef from certificate + private key (no keychain)
        guard let secIdentity = SecIdentityCreate(
            nil,        // default allocator
            certificate,
            privateKey
        ) else {
            print("[PEMIdentity] SecIdentityCreate returned nil — key doesn't match certificate")
            return nil
        }
        // Phase 2: Wrap in sec_identity_t for Network.framework
        guard let identity = sec_identity_create(secIdentity) else {
            print("[PEMIdentity] sec_identity_create returned nil")
            return nil
        }
        return identity
    }

    /// Load a `SecCertificate` from a PEM file.
    private static func loadCertificate(_ path: URL) -> SecCertificate? {
        guard let pemData = try? Data(contentsOf: path),
              let pemString = String(data: pemData, encoding: .utf8) else {
            return nil
        }
        guard let derData = extractPEMBlock(pemString, "CERTIFICATE") else {
            return nil
        }
        return SecCertificateCreateWithData(nil, derData as CFData)
    }

    /// Load a `SecKey` from a PEM-encoded RSA private key file.
    private static func loadPrivateKey(_ path: URL) -> SecKey? {
        guard let pemData = try? Data(contentsOf: path),
              let pemString = String(data: pemData, encoding: .utf8) else {
            return nil
        }

        // Try RSA private key format
        if let derData = extractPEMBlock(pemString, "RSA PRIVATE KEY") {
            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            ]
            return SecKeyCreateWithData(derData as CFData, attributes as CFDictionary, nil)
        }

        // Try PKCS#8 private key format
        if let derData = extractPEMBlock(pemString, "PRIVATE KEY") {
            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            ]
            return SecKeyCreateWithData(derData as CFData, attributes as CFDictionary, nil)
        }

        return nil
    }

    /// Extract a DER-encoded block from a PEM string.
    /// Returns the raw DER data (without PEM headers/footers or base64 encoding).
    private static func extractPEMBlock(_ pem: String, _ label: String) -> Data? {
        let lines = pem.components(separatedBy: .newlines)
        var inBlock = false
        var base64Lines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "-----BEGIN \(label)-----" {
                inBlock = true
                continue
            }
            if trimmed == "-----END \(label)-----" {
                inBlock = false
                break
            }
            if inBlock {
                base64Lines.append(trimmed)
            }
        }

        guard !base64Lines.isEmpty else { return nil }
        let base64 = base64Lines.joined()
        return Data(base64Encoded: base64)
    }
}
