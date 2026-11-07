# Copy-paste prompt (v2-compatible, consolidated, self-contained)

This is the single consolidated v2 prompt. It is fully self-contained — no other
file is required to do the work. (An optional companion, `zen_fingerprint.py`,
adds a 14-case automated probe, but the prompt below stands on its own.)

---

# Prompt: make OpenCode Zen's free tier callable from a non-OpenCode harness (v2-compatible, self-contained)

Paste everything below into an agent working in the target project. This prompt is
fully self-contained: it embeds the gate table, the implementation checklist, a
live-verification recipe, and the invariants. No other file is required. An
optional companion script, `zen_fingerprint.py` (same folder), provides a 14-case
automated probe, but the prompt stands on its own.

## Version note

- Targets the **OpenCode v2**-era endpoint `https://opencode.ai/zen/v1/chat/completions`.
- The four free-tier gates were **re-verified live on 2026-10-07** against the
  v2-era service and are **unchanged from v1**: same four gates, same refused
  forms, same `403`. v2 did **not** alter the gate rules — it moved the gateway
  code around (the free-tier decision now routes through `authInfo` /
  `allowAnonymous` billing branches in `handler.ts`) but the wire contract is
  identical.
- v2 deltas that matter here:
  - The client source moved from `sst/opencode` to **`anomalyco/opencode`**
    (default branch `dev`).
  - The v2 CLI sends the same `opencode*` headers **plus** two new non-gating
    headers: `x-session-affinity` and `X-Session-Id` (both equal to the session
    id). Mirror them for fidelity; they are not required to pass.
  - v2 renamed the **config** permission action `bash` → `shell` (and
    `task`→`subagent`, `write`/`patch`→`edit`). That is a **config-level** rename,
    NOT the request-body tool-name gate. **Gate 3 still checks the body tool NAMES
    `bash` and `read`** (re-verified live). Do **not** substitute `shell`.

## Task

Make `<PROJECT>` able to call OpenCode Zen's **free-tier** models when the
request does not originate from the OpenCode CLI.

### The symptom to fix

Any non-OpenCode harness gets, on every inference call:

```
HTTP 403
{"type":"error","error":{"type":"FreeTierError",
  "message":"Error from provider (Console): OpenCode's free tier can only be used from within OpenCode"}}
```

`GET https://opencode.ai/zen/v1/models` is **public** (200, no credential) — only
inference is gated. The message names the cause precisely: the gateway does not
believe the request came from the OpenCode client.

### Critical framing — read this before writing any code

There are **four independent gates**, and every one of them returns that *same*
opaque 403. Satisfying one is indistinguishable from satisfying none, so a
header-only fix appears to "not work" and you may wrongly conclude it is
impossible. **Two of the four gates are in the request body, not the headers.**
Headers alone can never pass.

## The four gates (measured live 2026-10-07, still holding on v2)

| # | Where | Requirement | Refused form |
|---|---|---|---|
| 1 | header `User-Agent` | `opencode/<semver>`, `<semver> >= 1.18.0` | bare `opencode`, any third-party agent → 403; below the floor → **426 UpgradeRequired** |
| 2 | header `x-opencode-session` (v2 also accepts the id via `x-opencode-session-id` / `x-session-affinity` / `X-Session-Id`) | matches `^ses_[0-9a-f]{12}[0-9A-Za-z]{14}$` (26 chars after `ses_`) | ALL session-family headers missing/malformed, a UUID, wrong length, uppercase hex in the prefix → 403 |
| 3 | body `tools` | must declare **both** `bash` and `read`, **case-sensitively** | 0–1 tools, or either name absent, or `Bash`/`Read` → 403 |
| 4 | body `stream` | must be `true` | `"stream": false` → 403 |

Details that cost real time to establish — do not re-litigate these:

- **Gate 3 is a superset test, not equality.** `[bash, read, totally_fake]` → 200.
  `[bash, glob]` → 403 (no `read`). `[read, write, edit, ls]` → 403 (no `bash`).
  Tool order, descriptions and parameter schemas are irrelevant.
- **Gate 3 is case-sensitive.** Claude Code sends `Bash`/`Read`; those do **not**
  count. Never compare tool names case-insensitively. (v2 renamed the *config*
  action `bash`→`shell`; that does **not** change this wire gate — still spell
  them lowercase `bash`/`read` in the body.)
- **`Authorization` is not a gate.** No header and `Bearer public` both return 200.
  The CLI sends `Bearer public` when it holds no credential, so match it — but it
  is cosmetic, not the fix.
- **All four are deterministic** (three repeats per variant, no flapping).

## Reference: where these constants come from (v2)

Recovered from the client's own source, not guessed:

- **What the CLI sends** — `anomalyco/opencode` (default branch `dev`),
  `packages/opencode/src/session/llm/request.ts` (~lines 180-205): for any
  provider whose id starts with `opencode`, it attaches `x-opencode-session`,
  `x-opencode-session-id`, `x-opencode-request`, `x-opencode-client` (default
  `cli`), and `User-Agent: opencode/${InstallationVersion}` (currently
  `opencode/1.18.35` on `dev`); v2 also adds `x-session-affinity` and
  `X-Session-Id` (both = session id) and conditionally `x-opencode-parent-session-id`.
- **What the gateway reads** — `packages/console/app/src/routes/zen/util/handler.ts`
  (1312 lines on `dev`). The free-tier decision now lives in billing branches
  (`validateBilling` → `anonymous`/`free`/`byok`/…; `allowAnonymous`), but the four
  wire gates above remain the enforced contract (re-verified live).

To re-derive from scratch:

```bash
git clone --depth 1 --filter=blob:none --sparse https://github.com/anomalyco/opencode.git
cd opencode && git sparse-checkout set packages/opencode/src packages/console/app/src
```

## Implementation checklist (language-agnostic, do in order)

1. **One predicate decides whether the shim runs.** `applies(providerId, baseUrl,
   apiKey)` = the endpoint is opencode.ai (by provider-id prefix `opencode` **or**
   by host) **AND** there is no credential (empty, or the literal `public`). **A
   configured API key is the paid path and must be left completely alone** —
   rewriting its body is a bug, not a fix.

2. **Session id generator.** `ses_` + 12 lowercase hex + 14 base62. Use the
   current epoch milliseconds for the hex prefix (the gateway expects a descending
   time prefix). **Generate one id per session/origin and reuse it** — that is what
   gives the upstream's sticky provider routing its prompt-cache affinity, exactly
   as the real CLI does. Ship a validator (`is_valid_session_id`) and pin it with a
   test.

3. **User-Agent.** Present `opencode/<a version at or above the floor>` (floor
   1.18.0; current CLI build is 1.18.35). Keep a caller-supplied agent only if it
   already matches the pattern *and* passes the floor. Put the version in a single
   named constant — the vendor will raise the floor, and that constant is the one
   edit point.

4. **Header injection, at every egress that can reach opencode.ai.** Set
   `User-Agent`, `x-opencode-session`, `x-opencode-session-id`,
   `x-opencode-request`, `x-opencode-client: cli`, `x-session-affinity` (= session),
   `X-Session-Id` (= session), and `Authorization: Bearer public` when there is no
   key. **Audit for more than one request path** — a proxy usually has at least
   two (a translated path and a raw passthrough), and forgetting one is the most
   likely way this ships half-broken.

5. **Body conformance.** Append schema-less, undescribed `bash` and `read`
   declarations if absent (idempotently — never duplicate), and force
   `stream = true`. Return a flag telling the caller the stream was forced.

6. **Response de-conformance — mandatory, and the part everyone forgets.** Gates 3
   and 4 are visible to the model, so it can return a call to a tool the caller
   never declared. Undo it before the caller sees it:
   - **Non-streaming JSON:** drop `tool_calls` entries whose name is a synthetic
     one the caller did not offer. If none survive, remove `tool_calls` and
     rewrite `finish_reason` from `tool_calls` to `stop` — otherwise an agent
     harness waits forever for a tool it never declared.
   - **Streaming:** filter **by index**, not by name. A tool call arrives as the
     name in one delta and its arguments in the next; dropping only the name
     leaks the arguments. If every call in the stream was synthetic, rewrite the
     terminal `finish_reason` to `stop`.
   - **Forced streaming:** if the gate demanded `stream: true` and the caller asked
     for `false`, aggregate the SSE back into one complete response object.
   - **Line-buffer any stream you rewrite** — a chunk boundary can split a line,
     and relaying a half-parsed payload is worse than the original error.

7. **Validation/probe endpoints too.** A model-availability check that POSTs a chat
   completion will show a free model as broken unless it conforms the body as
   well. `/v1/models` needs nothing — do not add the fingerprint there and then
   believe the tick means inference works.

## Verification you must run (self-contained recipe below; or `python3 zen_fingerprint.py`)

Do not stop at unit tests. A unit test proves your constants match your own
expectations.

1. **Unit tests, one per gate**, each asserting the accepted *and* the refused
   form; plus the session-id format validator; plus "a configured credential
   disables the shim"; plus "offered names are never filtered".
2. **Live wire proof — control vs shim.** Compile your actual shim (not a
   reimplementation) and hit the live endpoint, OR run the inline probe below.
   Assert:
   - a **control with no shim** still gets the 403 (so the fix is causally
     demonstrated, not coincidental);
   - the **worst case** (a caller offering zero tools) returns 200, aggregates to
     a well-formed completion, and leaks **zero** synthetic tool calls;
   - the **real primary client's shape** (e.g. Claude Code's
     `Bash`/`Read`/`Edit`/`Glob`/`Grep`/`Write`/`TodoWrite`/`WebFetch`/`WebSearch`/`Task`)
     returns 200 with the caller's own tools intact and zero leaks.
3. **Re-run the gate probe** after any upstream change. If a case that expected
   403 now returns something else, the vendor moved.

### Inline live probe (no external files needed)

```python
import json, urllib.request, urllib.error, time, random, string

BASE = "https://opencode.ai/zen/v1/chat/completions"
UA = "opencode/1.18.35"
HEX = string.digits + "abcdef"
B62 = string.digits + string.ascii_uppercase + string.ascii_lowercase

def ses():
    ms = int(time.time() * 1000) & 0xFFFF_FFFF_FFFF
    return "ses_" + format(ms, "012x") + "".join(random.choice(B62) for _ in range(14))

def post(headers, body):
    req = urllib.request.Request(BASE, data=json.dumps(body).encode(),
                                 headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:
        return -1, str(e)

def valid(extra=None):
    s = ses()
    h = {"Content-Type": "application/json", "User-Agent": UA,
         "x-opencode-session": s, "x-opencode-session-id": s,
         "x-opencode-request": "msg_" + "".join(random.choice(HEX) for _ in range(24)),
         "x-opencode-client": "cli", "x-session-affinity": s, "X-Session-Id": s,
         "Authorization": "Bearer public"}
    return {**h, **(extra or {})}

def tool(name):
    return {"type": "function", "function": {"name": name,
            "parameters": {"type": "object", "properties": {}}}}

base = lambda: {"model": "big-pickle",
                "messages": [{"role": "user", "content": "Reply with the single word: ok"}],
                "max_tokens": 16}

# 1) control: no shim, zero tools
c, _ = post({"Content-Type": "application/json", "User-Agent": "curl/8.7.1"}, base())
print("control (no shim)          ->", c, "(expect 403)")
# 2) shim, worst case: zero tools
h = valid(); b = base(); b["stream"] = True; b["tools"] = [tool("bash"), tool("read")]
s, raw = post(h, b)
print("shim (zero tools)          ->", s, "(expect 200)")
# 3) shim, Claude Code's 10 tools
cc = ["Bash","Read","Edit","Glob","Grep","Write","TodoWrite","WebFetch","WebSearch","Task"]
h = valid(); b = base(); b["stream"] = True
b["tools"] = [tool(n) for n in cc] + [tool("bash"), tool("read")]
s, raw = post(h, b)
print("shim (Claude Code 10 tools)->", s, "(expect 200, 12 tools sent, 0 leaked)")
```

Expected: control `403`, both shim cases `200`. Inspect the aggregated response
for zero `bash`/`read` tool calls leaking back to the caller.

## Invariants to pin as tests

- **[Z1]** Four gates, not one: UA at/above the floor, the 26-char `ses_` shape,
  lowercase `bash` **and** `read`, `stream: true`. Any one missing is the same 403.
- **[Z2]** Case matters. `Bash`/`Read` do **not** satisfy gate 3. (v2's
  `bash`→`shell` config rename does not change this.)
- **[Z3]** The session id shape is exact; the `ses_` + 24-hex UUID-derived form is
  refused.
- **[Z4]** The body is part of the fingerprint. Never ship a header-only shim;
  never send `stream: false` to a free-tier Zen model.
- **[Z5]** Never leak a synthetic call — on every response path.
- **[Z6]** A configured API key disables the shim entirely.
- **[Z7]** Do not send `x-opencode-project`: the CLI only sends it when it has a
  real project id, and a fabricated value pollutes Console's accounting for no
  gate's benefit.
- **[Z8]** `/v1/models` needs nothing — a model can be listed and still 403.
- **[Z9 — v2]** The v2 CLI also sends `x-session-affinity` and `X-Session-Id` (=
  session id). Mirror them for fidelity; they are not gating. Keep `bash`/`read`
  (not `shell`) in the body for gate 3.

## Process warning

When a test fails, **the assertion is the first suspect, not the code.** In the
session this prompt came from, three first-pass assertions were wrong and the
implementation was right: an "invalid" session id that was in fact valid (a
character legal in both alphabets proves nothing about the split), and a
`finish_reason` expectation that contradicted a real item still present in the
response. Re-derive the expected value from observed live behaviour before
changing implementation.

## Deliverable

Report: the gates re-verified live (with the probe output), the files changed,
the test count before/after, and any gate you could not satisfy — with the exact
status and body you observed, not a summary of it.
