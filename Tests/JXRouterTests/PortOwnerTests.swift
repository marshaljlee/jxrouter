import XCTest

/// Tests for `PortOwner`, which turns the bare PIDs from the pre-flight `lsof`
/// check into "Claude Code (PID 4821)". The parsing is the fragile part: `lsof
/// -ti` output is newline-separated and can be empty or unexpected, and a bad
/// parse must never crash the proxy startup path that throws the error.
final class PortOwnerTests: XCTestCase {

    func testEmptyInputYieldsNoOwners() {
        XCTAssertTrue(PortOwner.names(for: "").isEmpty)
    }

    func testNonNumericInputIsIgnored() {
        XCTAssertTrue(PortOwner.names(for: "abc").isEmpty)
        XCTAssertTrue(PortOwner.names(for: "not-a-pid\n12x").isEmpty)
    }

    func testUnknownPIDFallsBackToPID() {
        // A PID that certainly isn't running: NSRunningApplication returns nil,
        // so the message still has something to show.
        let names = PortOwner.names(for: "999999")
        XCTAssertEqual(names, ["PID 999999"])
    }

    func testZeroPIDIsSkipped() {
        XCTAssertTrue(PortOwner.names(for: "0").isEmpty)
    }

    func testLimitCapsTheList() {
        let names = PortOwner.names(for: "1\n2\n3\n4\n5", limit: 2)
        XCTAssertEqual(names.count, 2)
    }

    func testEveryEntryCarriesItsPID() {
        // Whatever the resolution outcome, the PID must survive in the string —
        // it is the only actionable part when the name can't be resolved.
        let names = PortOwner.names(for: "999998\n999999")
        XCTAssertEqual(names.count, 2)
        for name in names {
            XCTAssertTrue(name.contains("PID"), "expected a PID in \(name)")
        }
    }

    func testOwnProcessResolves() {
        // Sanity check on the real API path: our own process is visible.
        let pid = ProcessInfo.processInfo.processIdentifier
        let names = PortOwner.names(for: String(pid))
        XCTAssertEqual(names.count, 1)
        XCTAssertTrue(names[0].contains(String(pid)))
    }

    func testConflictMessageNamesTheOwner() {
        // The user-visible sentence must carry both the port and the program.
        let msg = PortOwner.conflictMessage(port: 5255, pids: "4821")
        XCTAssertTrue(msg.contains("5255"), msg)
        XCTAssertTrue(msg.contains("4821"), msg)
        XCTAssertTrue(msg.contains("Quit it"), msg)
    }

    func testConflictMessageIsStableForEmptyOwners() {
        // No PIDs at all: must still produce a sentence, not crash or blank out.
        let msg = PortOwner.conflictMessage(port: 5255, pids: "")
        XCTAssertTrue(msg.contains("5255"), msg)
    }

    // MARK: - Signal targeting

    /// `pkill` must match the process NAME, not the whole command line.
    ///
    /// `-f` matches the full argument list as a substring, so `pkill -f ollama`
    /// also signals anything that merely mentions it — an editor with
    /// `ollama.md` open, a `grep`, a test script. Verified with a decoy process
    /// named `sleep` whose argv contained "ollama": `pgrep -f ollama` matched
    /// it, `pgrep -x ollama` did not.
    func testOllamaSweepMatchesTheProcessNameNotTheCommandLine() {
        let args = LocalModelManager.ollamaSweepArguments(serverName: "ollama")
        XCTAssertEqual(args.first, "-x")
        XCTAssertFalse(args.contains("-f"),
                       "`-f` would signal unrelated processes that merely mention the name in their arguments.")
        XCTAssertEqual(args.last, "ollama")
    }

    func testOllamaSweepCarriesTheServerNameThrough() {
        // The pattern must be the caller's server name, not a hardcoded one.
        XCTAssertEqual(LocalModelManager.ollamaSweepArguments(serverName: "llama-server").last,
                       "llama-server")
    }
}
