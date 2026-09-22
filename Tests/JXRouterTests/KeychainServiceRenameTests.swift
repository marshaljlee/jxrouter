import XCTest

/// Tests for the Keychain service rename (`com.jxproxy` → `com.marshaljlee.jxrouter`).
///
/// The failure mode this guards against is specific and quiet: rename the
/// service, and every API key the user already saved becomes invisible — the
/// secrets are still on disk, just under a service name this build no longer
/// reads. `ConfigManager.migrateLegacyKeychainServices()` is what prevents
/// that, and its correctness rests on two properties:
///
/// 1. `com.jxproxy` is in the sweep list, ahead of the older names.
/// 2. An install that already latched the old one-shot boolean still sweeps
///    `com.jxproxy` — the flag it set only ever vouched for the two services
///    that predated the rename.
///
/// (2) is the subtle one. A single boolean would have suppressed the sweep on
/// exactly the machines that need it most: real, existing installs.
final class KeychainServiceRenameTests: XCTestCase {

    // MARK: - Service identity

    func testCurrentServiceMatchesBundleIdentifier() {
        XCTAssertEqual(KeychainManager.service, "com.marshaljlee.jxrouter")
    }

    func testLegacyServiceIsThePreRenameName() {
        XCTAssertEqual(KeychainManager.legacyService, "com.jxproxy")
        XCTAssertNotEqual(KeychainManager.service, KeychainManager.legacyService,
                          "Renaming `service` without keeping the old name reachable orphans stored keys.")
    }

    // MARK: - Sweep list

    func testFreshInstallSweepsEveryLegacyServiceNewestFirst() {
        let pending = ConfigManager.pendingLegacyServices(sweptServices: [])
        // Newest build first: a key present in more than one old service is
        // taken from the one the user most recently ran.
        XCTAssertEqual(pending.first, KeychainManager.legacyService)
        XCTAssertTrue(pending.contains("com.jxrouter-g"))
        XCTAssertTrue(pending.contains("com.proxyswitch"))
    }

    func testExistingInstallWithOldFlagStillSweepsRenamedService() {
        // The install already ran the migration when only two services were
        // known, so the boolean is latched but no per-service record exists.
        let swept = ConfigManager.sweptLegacyServices(recorded: [], legacyBoolMigrated: true)

        // The two services the old flag vouched for are treated as done...
        XCTAssertTrue(swept.contains("com.jxrouter-g"))
        XCTAssertTrue(swept.contains("com.proxyswitch"))
        // ...but the renamed service must NOT be: this install has never swept
        // it, and latching it here is what would orphan its keys.
        XCTAssertFalse(swept.contains(KeychainManager.legacyService))

        XCTAssertEqual(ConfigManager.pendingLegacyServices(sweptServices: swept),
                       [KeychainManager.legacyService])
    }

    func testFullySweptInstallSweepsNothing() {
        let swept = ConfigManager.sweptLegacyServices(
            recorded: [KeychainManager.legacyService, "com.jxrouter-g", "com.proxyswitch"],
            legacyBoolMigrated: false
        )
        XCTAssertTrue(ConfigManager.pendingLegacyServices(sweptServices: swept).isEmpty)
    }

    func testRecordedServicesAreRespected() {
        // A later launch that already swept com.jxproxy must not redo it.
        let swept: Set<String> = [KeychainManager.legacyService]
        let pending = ConfigManager.pendingLegacyServices(sweptServices: swept)
        XCTAssertFalse(pending.contains(KeychainManager.legacyService))
        XCTAssertTrue(pending.contains("com.jxrouter-g"))
    }

    func testOldFlagDoesNotSuppressAnExplicitlyRecordedSweep() {
        // Both signals present: the union is taken, not the boolean alone.
        let swept = ConfigManager.sweptLegacyServices(
            recorded: [KeychainManager.legacyService], legacyBoolMigrated: true
        )
        XCTAssertEqual(ConfigManager.pendingLegacyServices(sweptServices: swept), [])
    }

    // MARK: - What gets swept

    func testTelegramBotTokenIsIncludedInSweptKeys() {
        // Stored in the Keychain, so a service rename moves it too. It used to
        // be missing from `allChainKeys`, which would have dropped it silently.
        XCTAssertTrue(ConfigManager.KeychainKey.allChainKeys
            .contains(ConfigManager.KeychainKey.telegramBotToken))
    }

    func testAuthTokenIsNotSwept() {
        // The auth token lives in UserDefaults, not the Keychain. Sweeping it
        // would copy a stale secret into a service that nothing reads.
        XCTAssertFalse(ConfigManager.KeychainKey.allChainKeys
            .contains(ConfigManager.KeychainKey.authToken))
    }
}
