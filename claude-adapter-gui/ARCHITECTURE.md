# Architecture: claude-adapter Control Center

Self-contained Trogon/Textual desktop wrapper for the `claude-adapter` npm CLI
(v2.2.1). Design governed by three hard constraints:

1. **Zero Functional Dampening** - the GUI exposes every capability of the CLI,
   including the ones that do not fit a form widget.
2. **Zero-Buried-Feature Architecture** - flat single-screen layout. Every
   option is permanently visible; no tabs, modals, or collapsible sections hide
   functionality.
3. **Faithful Schema** - no hallucinated commands. Every control maps 1:1 to a
   verified flag of the real binary.

---

## 1. Verified CLI Surface

Source: official project README (authoritative flag table). The CLI is a
**single command** with no subcommands.

| CLI element | Type | Default | Notes |
|---|---|---|---|
| `-p, --port <port>` | int | `3080` | Proxy server port |
| `-r, --reconfigure` | flag | off | Forces the reconfiguration workflow |
| `--no-claude-settings` | flag | off | Skips updating Claude Code settings files |
| `-V, --version` | flag | - | Print version |
| `-h, --help` | flag | - | Print help |
| *(bare invocation)* | wizard | - | Interactive setup: Base URL, auth/API key, model mapping across `opus` / `sonnet` / `haiku` tiers |

Environment prerequisite: Node.js >= 20. Binary installed globally via
`npm install -g claude-adapter`.

---

## 2. Topology: One Schema, Two Front Ends

```
              +------------------------------------------------+
              |   mirrored Click group   (@trogon.tui())       |
              |   commands: run / setup / version / help       |
              +-------------------+---------------+------------+
                                  |               |
        default entry point       |               |  `python claude_adapter_gui.py tui`
        (custom Textual App)      |               |  (stock Trogon-generated form)
                                  |               |
   widgets -> argv -------------->+<--------------+
                                  |
                                  v
                     subprocess bridge (argv forwarding)
                                  |
                          real `claude-adapter` binary
                          stdout PIPE | stderr PIPE
                                  |
                                  v
                    RichLog panel (live, stderr tagged ERR)
```

### Why the subprocess bridge (and not CliRunner)

Stock Trogon executes Click callbacks **in-process**. That is unacceptable for
the primary experience: it blocks the UI loop, mixes stdout/stderr, buffers
output until completion, and cannot be stopped mid-flight. The wrapper instead
forwards argv to the real binary via `asyncio.create_subprocess_exec` with
separated pipes. The wrapper never reimplements adapter logic, so behavioral
parity with the CLI is guaranteed by construction (zero dampening).

### Why a mirrored Click group at all

Both front ends consume the **same** Click group:

- The custom App reads widget state and builds argv independently (needed for
  live streaming), but the group remains the machine-readable schema contract.
- The stock `@trogon.tui()` entry point generates its form from that same
  group, and its command callbacks route through the identical
  `_forward_sync()` bridge.

Because both modes share one schema and one bridge, they **cannot drift
apart**: adding a flag means touching one decorator and (at most) one widget.

---

## 3. Layout Strategy (flat, functionally dense)

Single screen, top-to-bottom flow. Nothing hidden.

```
+------------------------------------------------------------------+
| Header                                                           |
+-----------------------------------+------------------------------+
| CONNECTION                        | ACTIONS                      |
|   --port / -p  [ 3080 ]           |   [ Run ]  [ Stop ]          |
|   [-] -r --reconfigure            |   [ Setup Wizard ]           |
|   [-] --no-claude-settings        |   [ Version ] [ Help ]       |
+-----------------------------------+------------------------------+
| raw args  [ extra CLI args appended verbatim........ ] [Run Raw] |
+------------------------------------------------------------------+
| status strip (binary presence / last outcome)                    |
+==================================================================+
| terminal output (stdout + stderr)          <- RichLog, fills rest|
+------------------------------------------------------------------+
| Footer (key hints)                                               |
+------------------------------------------------------------------+
```

### Widget-to-flag mapping (1:1, no burials)

| Widget | CLI equivalent | Behavior |
|---|---|---|
| Port `Input` (`type="integer"`) | `--port/-p` | Empty = omitted (binary default 3080 applies); validated int 1-65535 |
| Reconfigure `Switch` | `--reconfigure` | On = flag appended |
| No-claude-settings `Switch` | `--no-claude-settings` | On = flag appended |
| `Run` button | full invocation | Structured controls + raw args (if any), streamed live |
| `Stop` button | SIGTERM/SIGKILL | Escalating termination of the child process |
| `Setup Wizard` button | bare `claude-adapter` | Suspends the UI and hands the real TTY to the interactive wizard |
| `Version` button | `--version` | Streams into the log panel |
| `Help` button | `--help` | Streams into the log panel |
| Raw args `Input` + `Run Raw` | escape hatch | Free-form args, `shlex`-split, forwarded verbatim (future-proofing for flags the GUI predates) |

The raw pane is deliberately a first-class citizen: it is the guarantee that a
future upstream flag can never be unreachable from the GUI.

---

## 4. Event Handling

- **Dispatch**: `@on(Button.Pressed, "#id")` handlers; global bindings
  `ctrl+q` quit, `ctrl+l` clear log, `ctrl+r` re-run current configuration.
- **Single source of truth**: `_collect_args()` translates widget state into
  argv for both `Run` and `ctrl+r`. Validation failures (non-integer port,
  out-of-range port, unparseable raw args) are reported inline in red in the
  log panel and the status strip; the run is aborted before spawn.
- **Async lifecycle**:
  1. Reentrancy guards (`_busy` / `_launching` flags plus temporary disabling
     of Run / Run Raw / Wizard) prevent double spawns from rapid clicks.
  2. `asyncio.create_subprocess_exec(binary, *args, stdout=PIPE, stderr=PIPE)`.
  3. Two pump tasks `readline()` their pipe forever and append each line to the
     `RichLog`: stdout plain, stderr prefixed with a bold-red `ERR` tag.
     Dynamic content is `rich.markup.escape`d so bracket-bearing output cannot
     corrupt markup.
  4. `asyncio.gather` on both pumps, then `await process.wait()`.
  5. Exit banner: green "finished successfully (exit code 0)" or red
     "EXIT CODE <n> - see [ERR] lines above"; status strip mirrors it.
- **Stop**: `terminate()` (SIGTERM), 5 s grace via `asyncio.wait_for`, then
  `kill()` (SIGKILL). The subsequent natural exit banner reports the signal
  code honestly rather than being suppressed.
- **Wizard**: bare invocation drives arrow-key `inquirer` prompts that cannot
  work behind piped stdin/stdout. Instead of hanging, the app calls
  `App.suspend()`, runs the wizard synchronously attached to the real
  terminal, resumes the UI, and posts a return-code banner. Feature preserved
  at full fidelity; no silent failure.

---

## 5. Error-State Matrix

| Condition | Detection | User-visible handling |
|---|---|---|
| Binary not on PATH | `shutil.which` at spawn and startup | Red status strip, install guidance block (`npm install -g claude-adapter`, Node >= 20) printed to the log; exit code 127 in Trogon mode |
| Invalid port | `_collect_args` parse/range check | Inline red INPUT ERROR, no spawn |
| Unparseable raw args | `shlex.split` ValueError | Inline red INPUT ERROR quoting the parser message |
| Already running | `_busy` guard | Yellow notice, no second spawn |
| Non-zero exit | `returncode` | Red EXIT CODE banner + status strip; stderr lines already tagged `ERR` above |
| Suspend unsupported (exotic terminal) | exception around `suspend()` | Graceful red notice instead of crash |

---

## 6. Trogon Integration Approach

- `@trogon.tui()` decorates the shared group; the generated `tui` subcommand is
  reachable via `python claude_adapter_gui.py tui`.
- Plain script execution bypasses Click dispatch and boots `ClaudeAdapterGUI`,
  keeping the streaming app as the zero-argument default experience.
- Trogon-mode callbacks call the same `_forward_sync()` subprocess bridge used
  conceptually by the GUI, so neither mode ever reimplements CLI behavior.
- Known limitation (accepted, documented): stock Trogon blocks until the child
  finishes because generated forms run callbacks synchronously. The custom App
  is therefore the recommended daily driver; Trogon mode exists as a familiar,
  low-maintenance secondary interface and as proof the schema stays Trogon-
  compatible.

## 7. Platform Notes

- Signals follow POSIX semantics (`SIGTERM` then `SIGKILL`); on Windows
  `terminate()` degrades to TerminateProcess.
- Requires Python 3.11+, `click`, `trogon`, `textual` (see
  `requirements.txt`), plus the globally installed `claude-adapter` binary.
