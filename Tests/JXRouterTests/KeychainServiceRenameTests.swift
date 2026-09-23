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

    // MARK: - Custom providers added after the sweep

    /// The gap, stated in the vocabulary of the *old* latch.
    ///
    /// `pendingLegacyServices` answers "which services still need sweeping".
    /// It cannot answer "which accounts still need sweeping", because it does
    /// not know accounts exist. On a machine where every legacy service is
    /// latched — which is the real state here — it reports nothing left to do,
    /// for every account, forever.
    func testPerServiceLatchIsStructurallyBlindToLaterAccounts() {
        let allSwept: Set<String> = [KeychainManager.legacyService, "com.jxrouter-g", "com.proxyswitch"]
        XCTAssertTrue(ConfigManager.pendingLegacyServices(sweptServices: allSwept).isEmpty,
                      "Precondition: every service is latched, so the old sweep has nothing left to do.")
        // ...and yet an account added afterwards has never been looked at.
        // That asymmetry is the whole bug: the latch is coarser than the set
        // it is guarding, and that set grows as the user adds providers.
    }

    /// The property the per-service latch gets wrong: an account the sweep has
    /// never seen is pending even when its service is already latched.
    func testCustomProviderAddedAfterItsServiceWasSweptIsStillPending() {
        let account = ConfigManager.customProviderKey("custom-tokenrouter")
        let allSwept: Set<String> = [KeychainManager.legacyService, "com.jxrouter-g", "com.proxyswitch"]
        XCTAssertTrue(ConfigManager.pendingLegacyServices(sweptServices: allSwept).isEmpty,
                      "Precondition: the old sweep considers itself finished.")

        let pending = ConfigManager.pendingCustomProviderRescues(
            accounts: [account], alreadyDone: []
        )
        XCTAssertTrue(pending.contains("\(KeychainManager.legacyService)|\(account)"),
                      "A latched service must not suppress an account that was added later.")
    }

    func testRescuedCustomProviderIsNotRepeated() {
        let account = ConfigManager.customProviderKey("custom-bai")
        let token = "\(KeychainManager.legacyService)|\(account)"
        let pending = ConfigManager.pendingCustomProviderRescues(
            accounts: [account], alreadyDone: [token]
        )
        XCTAssertFalse(pending.contains(token),
                       "A rescued (service, account) pair must not be redone.")
    }

    // MARK: - A failed read must not become a deletion

    /// Reading the stored provider list is how `loadFromConfig()` decides what
    /// to show, and the save path prunes whatever it cannot see. So a decode
    /// failure must be distinguishable from "the user has no providers" —
    /// otherwise one bad byte deletes every provider AND its Keychain key.
    func testUnreadableProviderJSONIsNotTreatedAsEmpty() {
        guard case .unreadable = ConfigManager.readCustomProviders(from: "{{{ not json") else {
            return XCTFail("Stored-but-unparseable JSON must report .unreadable, not .empty — "
                         + "collapsing the two is what deletes the user's providers.")
        }
    }

    func testNothingStoredIsEmptyNotUnreadable() {
        guard case .empty = ConfigManager.readCustomProviders(from: "[]") else {
            return XCTFail("A fresh install has nothing stored, which is not an error.")
        }
        guard case .empty = ConfigManager.readCustomProviders(from: "") else {
            return XCTFail("An absent value is nothing stored.")
        }
    }

    func testProviderEntryMissingAFieldDoesNotPoisonTheWholeList() {
        // The old decoding required every field on every entry, so adding a
        // field in a later build made every previously-saved list unreadable.
        let json = #"[{"id":"custom-a","name":"A"},{"id":"custom-b","name":"B","baseUrl":"https://b.example/v1"}]"#
        guard case let .decoded(list) = ConfigManager.readCustomProviders(from: json) else {
            return XCTFail("A missing field on one entry must not make the list unreadable.")
        }
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list.first(where: { $0.id == "custom-a" })?.baseUrl, "")
        XCTAssertEqual(list.first(where: { $0.id == "custom-b" })?.baseUrl, "https://b.example/v1")
    }

    func testProviderEntryWithoutAnIDIsDroppedNotFatal() {
        // Without an id there is no Keychain account to read or write, so the
        // entry is unusable — but it must not take the readable entries with it.
        let json = #"[{"name":"nameless","baseUrl":"https://x.example/v1"},{"id":"custom-ok","name":"OK","baseUrl":"https://ok.example/v1"}]"#
        guard case let .decoded(list) = ConfigManager.readCustomProviders(from: json) else {
            return XCTFail("A single unusable entry must not make the list unreadable.")
        }
        XCTAssertEqual(list.map(\.id), ["custom-ok"])
    }

    func testCustomProviderRescueCoversEveryLegacyService() {
        // Stranded is stranded, whichever old service holds it — including the
        // older pre-rename names, not just com.jxproxy.
        let account = ConfigManager.customProviderKey("custom-xkiro")
        let pending = Set(ConfigManager.pendingCustomProviderRescues(
            accounts: [account], alreadyDone: []
        ))
        XCTAssertTrue(pending.contains("\(KeychainManager.legacyService)|\(account)"))
        XCTAssertTrue(pending.contains("com.jxrouter-g|\(account)"))
        XCTAssertTrue(pending.contains("com.proxyswitch|\(account)"))
    }

    func testRescueTokensAreNamespacedPerService() {
        // Recording the account against one service must not mark it done for
        // another — the same reason the latch went from a boolean to a set.
        let account = ConfigManager.customProviderKey("custom-bai")
        let pending = ConfigManager.pendingCustomProviderRescues(
            accounts: [account], alreadyDone: ["com.jxproxy|\(account)"]
        )
        XCTAssertFalse(pending.contains("com.jxproxy|\(account)"))
        XCTAssertTrue(pending.contains("com.jxrouter-g|\(account)"))
    }

    func testStandardChainKeysCannotCoverCustomProviders() {
        // Why a dedicated rescue exists at all: the sweep list is a fixed set
        // the app controls, so a user-created provider key is not in it.
        let account = ConfigManager.customProviderKey("custom-tokenrouter")
        XCTAssertFalse(ConfigManager.KeychainKey.allChainKeys.contains(account),
                       "If this ever becomes true the rescue is redundant — but it must be a deliberate change.")
    }
}
