---
title: Claude Code connectivity — root causes, fixes, and invariants that must not regress
date: 2026-08-13
tags: [proxy, claude-code, connectivity, fallback, nwconnection, regression-guard]
anchor: LRN-connectivity
---

## [1] The symptom

For ~6 hours Claude Code could "not connect at all": requests hung, then
failed with no useful error. `~/.claude/settings.json` correctly pointed
`ANTHROPIC_BASE_URL` at the local proxy (port 5255), the proxy WAS running, and
requests WERE reaching the router — but responses never came back, and when the
fallback chain was supposed to rescue a failing primary it didn't.

## [2] Root causes found (each independently broke Claude Code)

1. **The 15s chain-attempt cap killed the primary provider.** Real Claude Code
   requests carry the whole conversation (300-400KB). A cloud gateway must
   prefill that before streaming a single byte — measured 33-47s on
   `model.inferx.net`, up to 60s+ on NVIDIA `deepseek-v4`. The old code applied
   the same 15s "fallback" cap to the PRIMARY attempt, so every real request
   was abandoned before the provider answered, then the whole chain burned
   through and failed.

2. **The 503 was never delivered.** When the chain exhausted, the router
   returned a 503 but the proxy's two-stage send (headers, then body) could
   stall between stages, leaving the client with ZERO bytes and no close —
   curl reported `HTTP 000`, Claude Code reported "cannot connect". A watchdog
   + single atomic payload fixed this.

3. **Fallbacks received models they can't serve.** Native Claude names
   (`claude-sonnet-4-…`) were passed through unmapped to fallbacks. OpenAI-
   compatible gateways reject them: opencode-zen returns `401 Model not
   supported`, NVIDIA returns 404, llama.cpp 400. So the rescue provider always
   400/401'd and the chain died → user had to switch models manually.

4. **The listener could die and stay dead.** `NWListener` `.failed`/`.cancelled`
   set `isRunning=false`, and `scheduleAutoRestart()` was an empty stub
   (disabled to avoid old osascript prompts). Once the listener died, the app
   stayed alive but Claude Code got connection-refused until a manual restart.

## [3] Fixes applied (2026-08-13)

- **ProviderRouter.swift**
  - `primaryAttemptTimeout = 60s`, `secondaryAttemptTimeout = 45s` (first
    fallback), `chainAttemptTimeout = 15s` (deeper fallbacks),
    `localAttemptTimeout = 240s` (local prefill). See `attemptTimeout(for:index:)`.
  - curl `--max-time` now matches the attempt budget (was hardcoded 30s, which
    killed the primary at 30s before its 60s budget elapsed).
  - Model-rejection rescue: when a provider answers 400/401/404, retry that
    SAME provider once with its own guaranteed-servable default model
    (`defaultModelForProvider`: opencode-zen→`big-pickle`,
    nvidia-nim→`nvidia/deepseek-v4`, presets→first preset model). The client's
    requested model is always tried first.
- **ProxyServer.swift**
  - Non-streaming responses are sent as ONE atomic payload (headers+body), via
    `sendWithWatchdog` — a 5s watchdog force-cancels the connection if the
    send completion never fires. (The watchdog must NOT cancel a connection
    whose send already completed — streaming lives past 5s.)
  - `scheduleAutoRestart()` re-enabled, bounded (3 attempts, 2s backoff), keyed
    on `unexpectedRestarts` which `start()` does NOT reset.
  - Trace to `/tmp/jxproxy-trace.log` shows per-request status + serving
    provider (`servedBy=`).

## [4] Verified behavior after the fix

- Sonnet-tier request (`claude-sonnet-4-…`): 200 (was 503 all day).
- Haiku-tier: 200 in 0.5s served by llamaapp (local).
- 250KB Claude Code request with all cloud providers failing: 200 served by
  llamaapp after ~84s local prefill (the fallback chain rescued it).
- Chain-exhausted 503s are delivered with a parseable body naming the failing
  providers (e.g. `Rate limited (HTTP 429) on: opencode-zen`).
- Garbage/unknown model names are rescued to a real model (200).

## [5] INVARIANTS — do NOT regress these (this is the record)

- **[I1] Primary provider must get ≥60s before the chain moves on.** Real
  Claude Code requests prefill 30-60s+ upstream. Any fix that shortens this
  (or hardcodes curl `--max-time` below the attempt budget) re-breaks
  "cannot connect".
- **[I2] Fallbacks must receive a model they can actually serve.** Never send
  a native `claude-*` name to an OpenAI-compatible fallback — it 400/401/404s.
  The retry-with-provider-default must stay. If a future fix changes model
  resolution, keep "client's model first, provider default on 400/401/404".
- **[I3] Every response must reach the client, errors included.** 503/504/502
  must be delivered as a complete HTTP response (Content-Length + Connection:
  close) and the connection closed. A hung client with zero bytes is the #1
  reported symptom. Never reintroduce a two-stage send without a watchdog.
- **[I4] The proxy must not stay dead.** Listener `.failed`/`.cancelled` must
  trigger the bounded auto-restart. Never gut `scheduleAutoRestart()` to an
  empty stub again — that is what made a dead listener permanent.
- **[I5] The watchdog must not kill live streams.** `sendWithWatchdog` only
  force-cancels when the send NEVER completed; a completed send's connection
  is owned by the stream pump afterwards.
- **[I6] Deep fallbacks keep a tight cap.** The 60s/45s budgets are for the
  primary and the first rescue; burning 60s per deep fallback would make
  genuine outages take minutes to surface. The 300s total-chain cap bounds
  everything.
- **[I7] opencode-zen does NOT silently serve unknown models** (it returns
  `401 Model not supported`) — any code that assumes it "serves its default
  for anything" is wrong.
- **[I8] User config is a moving target.** The user switches
  `activeProvider`/`activeModel`/tier providers while debugging. Never
  hardcode an assumption about which provider is primary.

## [5.5] Post-fix code review (error & functionality) — 2026-08-13

All 29 existing unit tests pass. Review findings and dispositions:

- **Fixed — auto-restart cap never reset on a user-initiated Start.** After 3
  unexpected-death restarts the cap stayed locked even after the user clicked
  Start. Added `resetUnexpectedRestartCount()` called from
  `ProxyManager.startProxy()`. It must NOT reset inside `start()` (that would
  defeat scheduleAutoRestart's own counter).
- **Fixed — duplicate fallback burned chain time.** `nvidia,opencode-zen,
  nvidia-nim` resolves to nvidia-nim twice; deduped in `providerChain`.
- **Fixed — retry is now traceable** (prints when a provider rejects a model
  and retries with its default).
- **Accepted — the model-rejection retry can silently serve the default.**
  Client's model is always tried first; Logs shows the serving provider, not
  the substituted model. Rescue > transparency, deliberate.
- **Accepted — 403/429 excluded from the retry list** (auth/quota, not model
  errors). 400/401/404 covered.
- **Accepted — streaming pump has no client-disconnect cancellation**
  (pre-existing): a disconnected client's pump keeps draining the upstream
  stream until it ends, bounded by curl --max-time.
- **Known — custom providers have no curated default**, so no model-rejection
  retry on the primary for them; the chain moves to fallbacks. Future
  improvement: fetch the custom provider's /models list for a default.
- **Known — trace() appends are not lock-protected** (debug-only /tmp file).

## [6] Known outstanding issues (not regressions, upstream/account)

- opencode-zen was rate-limited (`429 FreeUsageLimitError`) — provider quota.
- NVIDIA NIM returns `404` — the app's own docs flag this as an account-level
  "Public API Endpoints" permission issue for Personal orgs.
- `model.inferx.net` (custom-inferx) was intermittently erroring/slow.
- One AppKit layout crash was seen (Settings window constraint exception,
  2026-08-13 00:05:45 +0800, `_crashOnException` in view layout). A
  fixed-window `.defaultSize` change is already in place; watch for recurrence.
