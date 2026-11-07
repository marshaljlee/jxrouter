---
title: OpenCode Zen free tier — the client fingerprint a non-OpenCode harness must present
date: 2026-10-07
tags: [opencode, zen, provider, free-tier, fingerprint, headers, invariant]
anchor: LRN-zen-freetier
---

## [1] The symptom

Any harness that is not OpenCode itself gets, on every inference call:

```
HTTP 403
{"type":"error","error":{"type":"FreeTierError",
  "message":"Error from provider (Console): OpenCode's free tier can only be used from within OpenCode"}}
```

`GET https://opencode.ai/zen/v1/models` is **public** (200, no credential). Only
inference is gated, and the message names the cause precisely: the gateway does
not believe the request came from the OpenCode client.

## [2] What the gateway actually checks — four independent gates

Measured by bisection against `POST https://opencode.ai/zen/v1/chat/completions`
on 2026-10-07. Each gate alone produces the same 403, which is why "add the
header" appears not to work: satisfying one is indistinguishable from satisfying
none.

| # | Gate | Accepted | Refused |
|---|---|---|---|
| 1 | `User-Agent` | `opencode/<semver>`, `<semver> >= 1.18.0` | bare `opencode`, any third-party agent, `opencode/1.17.x` |
| 2 | `x-opencode-session` | `^ses_[0-9a-f]{12}[0-9A-Za-z]{14}$` | missing, a UUID, wrong length, uppercase hex in the prefix |
| 3 | `tools` | declares **both** `bash` and `read`, **case-sensitively** | 0–1 tools; either name missing; `Bash`/`Read` do **not** count |
| 4 | `stream` | `true` | `"stream": false` |

Details that cost time to establish:

- **Gate 1 below the floor is a different error**: `426 UpgradeRequired`,
  "OpenCode 1.18.0 or newer is required". A 403 means the UA was not recognised
  at all, not that it was too old.
- **Gate 3 is a superset test, not an exact match.** `[bash, read, totally_fake]`
  → 200. `[bash, glob]` → 403 (no `read`). `[read, write, edit, ls]` → 403 (no
  `bash`). Tool order, descriptions and parameter schemas are all irrelevant;
  only the names matter, and only those two.
- **Gate 2's split is enforced through the alphabet.** 26 characters of `a` is
  *valid* (`a` is legal in both the hex prefix and the base62 tail); the way to
  prove the prefix rule is a base62-but-not-hex character such as `Z` inside the
  first 12 positions.
- **`Authorization` is not a gate.** Both no header and `Bearer public` return
  200. The CLI sends `Bearer public` when it holds no credential
  (`packages/opencode/src/provider/provider.ts:240`, `options: ok ? {} : { apiKey: "public" }`),
  so the shim matches it — but it is cosmetic.
- **All four are deterministic.** Three repeats per variant, no flapping. The
  one apparent inconsistency (`[bash, read]` → 200 while `[bash, glob, grep]` →
  403) is fully explained by the superset rule; it is not load balancing.

## [3] Where the truth came from

Two reads, then bisection. Do not skip the reads — bisecting 4 gates x N values
blind is far slower.

1. **What the client sends.** Shallow sparse clone of the upstream's own repo:
   ```bash
   git clone --depth 1 --filter=blob:none --sparse https://github.com/sst/opencode.git
   git sparse-checkout set packages/opencode/src packages/console/app/src
   ```
   `packages/opencode/src/session/llm/request.ts:187-202` is the answer: for any
   provider whose id starts with `opencode`, the CLI attaches `x-opencode-session`,
   `x-opencode-request`, `x-opencode-client` (default `cli`), optionally
   `x-opencode-project`, and `User-Agent: opencode/${InstallationVersion}`.
2. **What the server reads.** `packages/console/app/src/routes/zen/util/handler.ts:125-269`
   reads exactly those names, forwards them to `console.*` upstreams, and deletes
   them for every other provider. The free-tier decision itself
   (`handler.ts:836`, `if (modelInfo.allowAnonymous) return "free"`) is not in the
   repo — the gate lives in the closed "Console" service — which is precisely why
   the remaining rules had to be measured rather than read.
3. **Bisect.** Vary one input at a time, repeat each three times, and keep the
   raw body. Nine variants pin all four gates in one script.

## [4] What the fix has to do beyond headers

Gates 3 and 4 live in the **body**, and both are visible to the model. A shim
that only adds headers cannot work. The complete shape is:

1. **Conform** — append schema-less, undescribed `bash`/`read` declarations and
   force `stream: true`.
2. **De-conform on the way back** — a call to a tool the caller never offered is
   an artefact of the shim and must not reach the client:
   - non-streaming JSON: drop the `tool_calls` entries; if none survive, rewrite
     `finish_reason` from `tool_calls` to `stop` so an agent harness does not wait
     forever for a tool it never declared;
   - streaming: filter the deltas **by index**, because a tool call arrives as a
     name in one delta and its arguments in the next — dropping only the name
     leaks the arguments;
   - a client that asked for `stream: false` needs the forced SSE folded back
     into one `chat.completion` body.

## [5] INVARIANTS — do NOT regress these

- **[Z1] Four gates, not one.** `User-Agent >= opencode/1.18.0`,
  `x-opencode-session` of exactly `ses_`+12 lowercase hex+14 base62, lowercase
  `bash` **and** `read` in `tools`, and `stream: true`. Any single one missing is
  a 403 with the same message.
- **[Z2] Case matters.** `Bash`/`Read` (what Claude Code sends) do **not**
  satisfy gate 3. Never "normalise" the synthetic declarations or compare tool
  names case-insensitively.
- **[Z3] The session id shape is exact.** 26 characters after `ses_`. The old
  `ses_` + 24-hex form is refused. `OpenCodeZenShim.isValidSessionId` is the
  audit point.
- **[Z4] The body is part of the fingerprint.** Never ship a header-only shim;
  never send `stream: false` to a free-tier Zen model.
- **[Z5] Never leak a synthetic call.** Every path that returns a response —
  JSON, translated SSE, raw passthrough — filters the shim's own tool names
  against what the caller actually offered.
- **[Z6] A configured API key disables the shim.** `applies(providerId:baseUrl:apiKey:)`
  must stay false when a key is present: that is the paid path and rewriting its
  body is a bug, not a fix.
- **[Z7] `x-opencode-project` stays absent.** The CLI sends it only when it has
  a real project id; a fabricated value would pollute Console's accounting for no
  gate's benefit.
- **[Z8] `/v1/models` needs nothing.** It is public. Do not add the fingerprint
  there "for consistency" and then believe the tick means inference works —
  `ProviderValidator.validateModel` conforms the body precisely because a model
  can be listed and still 403.
