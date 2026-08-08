import Foundation
import Security

/// Manages a local CA certificate and issues per-host certificates for TLS interception.
///
/// Uses the Security framework for key generation and macOS `openssl` for X.509 certificate creation.
/// Identities are loaded via `PEMIdentityLoader` which uses `sec_identity_create_with_certificates`
/// to avoid importing into the Keychain (no keychain access prompts).
final class CertificateAuthority: @unchecked Sendable {
    static let shared = CertificateAuthority()

    private let appSupport: URL
    private let caCertPath: URL
    private let caKeyPath: URL

    /// Cached CA identity (loaded once, reused across all host certs).
    private var caIdentity: sec_identity_t?

    /// Cache of host identities: host -> sec_identity_t
    /// Once loaded, never re-imports — avoids keychain prompts.
    private var hostIdentities: [String: sec_identity_t] = [:]

    private init() {
        let appDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        appSupport = appDir.appendingPathComponent("JXProxy", isDirectory: true)
        caCertPath = appSupport.appendingPathComponent("ca-cert.pem")
        caKeyPath = appSupport.appendingPathComponent("ca-key.pem")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
    }

    /// Whether the CA has been generated.
    var isReady: Bool {
        FileManager.default.fileExists(atPath: caCertPath.path)
            && FileManager.default.fileExists(atPath: caKeyPath.path)
    }

    /// Ensure the CA exists. Returns true if ready.
    @discardableResult
    func ensureCA() -> Bool {
        if isReady, caIdentity != nil { return true }
        guard isReady || generateCA() else { return false }
        return loadCAIdentity() != nil
    }

    /// Get or create a `sec_identity_t` for the given host (signed by the CA).
    func identity(for host: String) -> sec_identity_t? {
        if let cached = hostIdentities[host] { return cached }

        guard ensureCA() else { return nil }
        guard generateHostCert(host: host) else { return nil }
        guard let identity = loadIdentity(host: host) else { return nil }

        hostIdentities[host] = identity
        return identity
    }

    /// Get the CA's own `sec_identity_t`.
    func caIdentityValue() -> sec_identity_t? {
        ensureCA()
        return loadCAIdentity()
    }

    // MARK: - CA Generation

    private func generateCA() -> Bool {
        // First generate PKCS#1 RSA Key
        guard runOpenssl(["genrsa", "-out", caKeyPath.path, "2048"]) else { return false }
        restrictKeyFile(at: caKeyPath)

        let args = [
            "req", "-x509", "-new",
            "-key", caKeyPath.path,
            "-out", caCertPath.path,
            "-days", "3650",
            "-subj", "/CN=JXProxy CA",
        ]
        return runOpenssl(args)
    }

    // MARK: - Host Certificate Generation

    private func generateHostCert(host: String) -> Bool {
        let safeHost = sanitizeHost(host)
        let keyPath = appSupport.appendingPathComponent("\(safeHost)-key.pem")
        let certPath = appSupport.appendingPathComponent("\(safeHost)-cert.pem")
        let csrPath = appSupport.appendingPathComponent("\(safeHost)-csr.pem")

        // If already generated, skip
        if FileManager.default.fileExists(atPath: certPath.path),
           FileManager.default.fileExists(atPath: keyPath.path) {
            return true
        }

        // First generate PKCS#1 RSA Key
        guard runOpenssl(["genrsa", "-out", keyPath.path, "2048"]) else { return false }
        restrictKeyFile(at: keyPath)

        // Generate CSR using that key
        let genArgs = [
            "req", "-new",
            "-key", keyPath.path,
            "-out", csrPath.path,
            "-subj", "/CN=*.anthropic.com",
        ]
        guard runOpenssl(genArgs) else { return false }

        // Create extensions file for TLS server auth
        let extFile = appSupport.appendingPathComponent("\(safeHost)-ext.cnf")
        let extContent = """
        [v3_req]
        basicConstraints = CA:FALSE
        keyUsage = digitalSignature, keyEncipherment
        extendedKeyUsage = serverAuth
        subjectAltName = DNS:\(host)

        """
        guard let extData = extContent.data(using: .utf8),
              (try? extData.write(to: extFile)) != nil else {
            try? FileManager.default.removeItem(at: csrPath)
            return false
        }
        defer { try? FileManager.default.removeItem(at: extFile) }

        // Sign with CA
        let signArgs = [
            "x509", "-req",
            "-in", csrPath.path,
            "-CA", caCertPath.path,
            "-CAkey", caKeyPath.path,
            "-CAcreateserial",
            "-out", certPath.path,
            "-days", "365",
            "-extfile", extFile.path,
            "-extensions", "v3_req",
        ]
        guard runOpenssl(signArgs) else {
            try? FileManager.default.removeItem(at: csrPath)
            return false
        }

        try? FileManager.default.removeItem(at: csrPath)
        return true
    }

    // MARK: - Identity Loading (no keychain import)

    private func loadCAIdentity() -> sec_identity_t? {
        if let cached = caIdentity { return cached }
        guard isReady else { return nil }
        caIdentity = PEMIdentityLoader.load(certPath: caCertPath, keyPath: caKeyPath)
        return caIdentity
    }

    private func loadIdentity(host: String) -> sec_identity_t? {
        let safeHost = sanitizeHost(host)
        let certPath = appSupport.appendingPathComponent("\(safeHost)-cert.pem")
        let keyPath = appSupport.appendingPathComponent("\(safeHost)-key.pem")

        guard FileManager.default.fileExists(atPath: certPath.path),
              FileManager.default.fileExists(atPath: keyPath.path) else {
            return nil
        }
        return PEMIdentityLoader.load(certPath: certPath, keyPath: keyPath)
    }

    // MARK: - Multi-Domain Certificate

    /// Generate or retrieve a multi-domain certificate covering all AI API hosts.
    /// Returns a `sec_identity_t` without importing into the keychain.
    func multiDomainIdentity() -> sec_identity_t? {
        let certPath = appSupport.appendingPathComponent("multi-domain-cert.pem")
        let keyPath = appSupport.appendingPathComponent("multi-domain-key.pem")

        // If already generated, load directly
        if FileManager.default.fileExists(atPath: certPath.path),
           FileManager.default.fileExists(atPath: keyPath.path) {
            return PEMIdentityLoader.load(certPath: certPath, keyPath: keyPath)
        }

        // Generate the multi-domain cert
        guard ensureCA() else { return nil }
        guard generateMultiDomainCert(certPath: certPath, keyPath: keyPath) else { return nil }
        return PEMIdentityLoader.load(certPath: certPath, keyPath: keyPath)
    }

    private func generateMultiDomainCert(certPath: URL, keyPath: URL) -> Bool {
        let csrPath = appSupport.appendingPathComponent("multi-domain-csr.pem")

        // SAN entries covering all common AI API hosts
        let sanHosts = [
            "*.anthropic.com", "api.anthropic.com",
            "*.openai.com", "api.openai.com",
            "*.openrouter.ai", "api.openrouter.ai",
            "*.opencode.ai", "opencode.ai",
            "*.nvidia.com", "integrate.api.nvidia.com",
            "*.groq.com", "api.groq.com",
            "*.mistral.ai", "api.mistral.ai",
            "*.deepseek.com", "api.deepseek.com",
            "*.cerebras.ai", "api.cerebras.ai",
            "*.cohere.ai", "api.cohere.ai",
            "*.perplexity.ai", "api.perplexity.ai",
            "*.x.ai", "api.x.ai",
            "*.sambanova.ai", "api.sambanova.ai",
            "generativelanguage.googleapis.com",
        ]
        let sanEntries = sanHosts.map { "DNS:\($0)" }.joined(separator: ", ")

        // First generate PKCS#1 RSA Key
        guard runOpenssl(["genrsa", "-out", keyPath.path, "2048"]) else { return false }
        restrictKeyFile(at: keyPath)

        // Generate CSR using that key
        let genArgs = [
            "req", "-new",
            "-key", keyPath.path,
            "-out", csrPath.path,
            "-subj", "/CN=*.anthropic.com",
        ]
        guard runOpenssl(genArgs) else { return false }

        // Extensions file with SAN
        let extFile = appSupport.appendingPathComponent("multi-domain-ext.cnf")
        let extContent = """
        [v3_req]
        basicConstraints = CA:FALSE
        keyUsage = digitalSignature, keyEncipherment
        extendedKeyUsage = serverAuth
        subjectAltName = \(sanEntries)

        """
        guard let extData = extContent.data(using: .utf8),
              (try? extData.write(to: extFile)) != nil else {
            try? FileManager.default.removeItem(at: csrPath)
            return false
        }
        defer { try? FileManager.default.removeItem(at: extFile) }

        // Sign with CA
        let signArgs = [
            "x509", "-req",
            "-in", csrPath.path,
            "-CA", caCertPath.path,
            "-CAkey", caKeyPath.path,
            "-CAcreateserial",
            "-out", certPath.path,
            "-days", "365",
            "-extfile", extFile.path,
            "-extensions", "v3_req",
        ]
        guard runOpenssl(signArgs) else {
            try? FileManager.default.removeItem(at: csrPath)
            return false
        }

        try? FileManager.default.removeItem(at: csrPath)
        return true
    }

    // MARK: - Helpers

    private func sanitizeHost(_ host: String) -> String {
        host.replacingOccurrences(of: "[^a-zA-Z0-9._-]", with: "_", options: .regularExpression)
    }

    /// Restrict a generated private key file to the current user (0600).
    /// Public certificates stay readable; only private keys are locked down.
    private func restrictKeyFile(at path: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    @discardableResult
    private func runOpenssl(_ args: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        task.arguments = args
        let pipe = Pipe()
        task.standardError = pipe
        task.standardOutput = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let str = String(data: data, encoding: .utf8) {
                print("[OpenSSL] args: \(args) -> \(str)")
            }
            return task.terminationStatus == 0
        } catch {
            print("[OpenSSL] error: \(error)")
            return false
        }
    }
}
