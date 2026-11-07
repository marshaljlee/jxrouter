#!/usr/bin/env python3
"""
OpenCode Zen free-tier client fingerprint — portable reference implementation
and live gate probe.

Zero dependencies (stdlib only). Two ways to use it:

  1. Run it to re-derive and verify the gates against the live endpoint:

         python3 zen_fingerprint.py                # gate matrix + shim demo
         python3 zen_fingerprint.py --gate ua      # probe one gate only
         python3 zen_fingerprint.py --quiet        # exit 0/1 only, for CI

  2. Import it from your own code — the helpers are the whole fix:

         from zen_fingerprint import (
             applies, apply_headers, conform, aggregate_sse,
             strip_synthetic_tool_calls, tool_names_openai,
         )

         body = {"model": "big-pickle", "messages": [...], "stream": False}
         hdrs = {"Content-Type": "application/json"}
         if applies(provider_id, base_url, api_key):
             apply_headers(hdrs, base_url, has_key=bool(api_key))
             forced = conform(body)            # returns True if stream was forced
             raw = post_json(url, hdrs, body)  # upstream now answers SSE, not JSON
             data = aggregate_sse(raw, body["model"], offered=set())
             data = strip_synthetic_tool_calls(data, offered=set())

Why this exists
---------------
Zen's anonymous ("free tier") endpoint refuses any request it does not believe
came from the OpenCode client:

    HTTP 403 {"error":{"type":"FreeTierError","message":"Error from provider
      (Console): OpenCode's free tier can only be used from within OpenCode"}}

FOUR independent checks produce that same opaque error, and two of them live in
the request BODY, not the headers. Adding a header alone cannot work.

    1. User-Agent            opencode/<semver>, <semver> >= 1.18.0
                             (below the floor -> 426 UpgradeRequired, not 403)
    2. x-opencode-session    ^ses_[0-9a-f]{12}[0-9A-Za-z]{14}$   (26 chars)
    3. tools                 must declare BOTH `bash` and `read`, case-SENSITIVE
                             (Claude Code's `Bash`/`Read` do NOT count)
    4. stream                must be true ("stream": false -> 403)

Authorization is NOT a gate: both no header and `Bearer public` return 200.
GET /v1/models is public and needs none of this.

v2-compatible: re-verified live on 2026-10-07 against the OpenCode v2-era
endpoint. The four gates are UNCHANGED from v1 (same 403, same refused forms);
v2 only moved the gateway code into `authInfo`/`allowAnonymous` billing branches
and added two non-gating headers (see `fingerprint`). The v2 config permission
action rename `bash` -> `shell` is config-level only and does NOT change gate 3:
the body tool NAMES checked are still lowercase `bash` and `read`.

Measured 2026-10-07 against https://opencode.ai/zen/v1/chat/completions.
Every case in the matrix below is deterministic across repeats.

Constants recovered from the client's own source (v2 / `anomalyco/opencode`,
default branch `dev`):
  anomalyco/opencode -> packages/opencode/src/session/llm/request.ts (~180-205)
                  (what the CLI sends; v2 also stamps x-session-affinity and
                   X-Session-Id with the session id)
  anomalyco/opencode -> packages/console/app/src/routes/zen/util/handler.ts
                  (what the gateway reads; the free-tier decision now routes
                   through billing branches, but the wire gates above are the
                   enforced contract — hence the live probe)
"""

from __future__ import annotations

import argparse
import json
import random
import re
import string
import sys
import time
import urllib.error
import urllib.request

# --------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------

ENDPOINT = "https://opencode.ai/zen/v1/chat/completions"

#: The User-Agent the shim presents. Zen's floor is 1.18.0; this tracks a build
#: comfortably above it. Single edit point when Zen raises the floor.
DEFAULT_USER_AGENT = "opencode/1.18.35"

#: Zen refuses anything older with 426 UpgradeRequired.
MINIMUM_VERSION = (1, 18, 0)

#: The two names gate 3 demands, exactly as the CLI spells them.
SYNTHETIC_TOOL_NAMES = ("bash", "read")

SESSION_RE = re.compile(r"^ses_[0-9a-f]{12}[0-9A-Za-z]{14}$")
USER_AGENT_RE = re.compile(r"^opencode/(\d+)\.(\d+)(?:\.(\d+))?$", re.IGNORECASE)

_BASE62 = string.digits + string.ascii_uppercase + string.ascii_lowercase
_HEX = "0123456789abcdef"


# --------------------------------------------------------------------------
# Session identity (gate 2)
# --------------------------------------------------------------------------

def make_session_id(now: float | None = None) -> str:
    """`ses_` + 12 lowercase hex + 14 base62.

    The 12 hex characters are epoch milliseconds — the "descending" time prefix
    the gateway expects. 26 characters after the prefix; the old `ses_` + 24-hex
    (UUID-derived) form is REFUSED.
    """
    millis = int((now if now is not None else time.time()) * 1000) & 0xFFFF_FFFF_FFFF
    return "ses_" + format(millis, "012x") + "".join(random.choice(_BASE62) for _ in range(14))


def is_valid_session_id(value: str) -> bool:
    """The exact shape the gateway accepts. Kept as an explicit regex so the
    rule is auditable in one place."""
    return bool(SESSION_RE.match(value))


def user_agent(existing: str | None = None) -> str:
    """Keep a caller-supplied agent only when it already passes the floor —
    presenting the newest identity available is the point of the shim."""
    if existing:
        match = USER_AGENT_RE.match(existing)
        if match:
            version = tuple(int(g) if g else 0 for g in match.groups())
            if version >= MINIMUM_VERSION:
                return existing
    return DEFAULT_USER_AGENT


def request_id() -> str:
    """Not gated, but the CLI sends one and the gateway logs it."""
    return "msg_" + "".join(random.choice(_HEX) for _ in range(24))


# --------------------------------------------------------------------------
# Applicability
# --------------------------------------------------------------------------

def is_zen_endpoint(provider_id: str, base_url: str) -> bool:
    return provider_id.startswith("opencode") or "opencode.ai" in base_url


def is_anonymous(api_key: str) -> bool:
    """Empty and the literal `public` are the same thing to the gateway — the
    CLI sends `apiKey: "public"` when it holds no credential."""
    return api_key.strip() in ("", "public")


def applies(provider_id: str, base_url: str, api_key: str) -> bool:
    """The single predicate every call site should use.

    A configured API key is the PAID path, which enforces none of these gates —
    rewriting its body would be a bug, not a fix.
    """
    return is_zen_endpoint(provider_id, base_url) and is_anonymous(api_key)


# --------------------------------------------------------------------------
# Headers (gate 1, plus the client identity)
# --------------------------------------------------------------------------

def fingerprint(origin: str, has_key: bool, existing_user_agent: str | None = None) -> dict:
    session = make_session_id()
    headers = {
        "User-Agent": user_agent(existing_user_agent),
        "x-opencode-session": session,
        "x-opencode-session-id": session,
        "x-opencode-request": request_id(),
        "x-opencode-client": "cli",
        # v2-era CLI also stamps these two with the session id. They are not
        # gating (the gateway passes without them), but mirroring the client we
        # imitate keeps the fingerprint faithful to OpenCode v2.
        "x-session-affinity": session,
        "X-Session-Id": session,
    }
    if not has_key:
        headers["Authorization"] = "Bearer public"
    return headers


def apply_headers(headers: dict, origin: str, has_key: bool) -> dict:
    """Mutates `headers` in place and returns it."""
    headers.update(fingerprint(origin, has_key, headers.get("User-Agent")))
    return headers


# --------------------------------------------------------------------------
# Body conformance (gates 3 and 4)
# --------------------------------------------------------------------------

def synthetic_declaration(name: str) -> dict:
    """Deliberately schema-less and undescribed: the gateway matches the NAME
    only, and a tool with no description and no parameters is the least likely
    thing for a model to call — which matters, because the model DOES see this."""
    return {"type": "function", "function": {"name": name, "parameters": {"type": "object", "properties": {}}}}


def tool_names_openai(tools) -> set:
    names = set()
    for tool in tools or []:
        name = (tool.get("function") or {}).get("name")
        if name:
            names.add(name)
    return names


def conform(body: dict) -> bool:
    """Satisfies gates 3 and 4. Mutates `body`.

    Returns True when `stream` had to be forced on — i.e. the caller asked for a
    non-streaming answer and must now fold the SSE reply back with
    `aggregate_sse`. Idempotent.
    """
    tools = list(body.get("tools") or [])
    present = tool_names_openai(tools)
    for name in sorted(SYNTHETIC_TOOL_NAMES):
        if name not in present:
            tools.append(synthetic_declaration(name))
    body["tools"] = tools

    was_streaming = bool(body.get("stream"))
    body["stream"] = True
    return not was_streaming


def synthetic_names_not_offered(offered) -> set:
    return set(SYNTHETIC_TOOL_NAMES) - set(offered or ())


# --------------------------------------------------------------------------
# Response de-conformance — the part that is easy to forget
# --------------------------------------------------------------------------

def strip_synthetic_tool_calls(root: dict, offered) -> dict:
    """Removes calls to the shim's own tools from a complete `chat.completion`
    object. A turn whose only calls were synthetic is not a tool turn, so its
    `finish_reason` drops back to `stop` — otherwise an agent harness waits
    forever for a tool it never declared."""
    blocked = synthetic_names_not_offered(offered)
    if not blocked:
        return root
    for choice in root.get("choices") or []:
        message = choice.get("message") or {}
        calls = message.get("tool_calls")
        if not calls:
            continue
        kept = [c for c in calls if (c.get("function") or {}).get("name") not in blocked]
        if len(kept) == len(calls):
            continue
        if kept:
            message["tool_calls"] = kept
        else:
            message.pop("tool_calls", None)
            if not message.get("content"):
                message["content"] = ""
            choice["finish_reason"] = "stop"
        choice["message"] = message
    return root


class StreamFilter:
    """Drops synthetic tool-call deltas out of an OpenAI SSE chunk.

    Stateful, because a tool call arrives spread across many chunks — the name
    in the first delta, the arguments after it. Filtering BY NAME only would
    leak the arguments; filter by INDEX.
    """

    def __init__(self, offered):
        self.blocked = synthetic_names_not_offered(offered)
        self._dropped: set[int] = set()
        self._seen: set[int] = set()

    @property
    def active(self) -> bool:
        return bool(self.blocked)

    def filter(self, chunk: dict) -> dict:
        if not self.blocked:
            return chunk
        for choice in chunk.get("choices") or []:
            delta = choice.get("delta") or {}
            calls = delta.get("tool_calls")
            if calls:
                kept = []
                for call in calls:
                    index = call.get("index", 0)
                    self._seen.add(index)
                    if index in self._dropped:
                        continue
                    name = (call.get("function") or {}).get("name") or ""
                    if name and name in self.blocked:
                        self._dropped.add(index)
                        continue
                    kept.append(call)
                if len(kept) != len(calls):
                    if kept:
                        delta["tool_calls"] = kept
                    else:
                        delta.pop("tool_calls", None)
                    choice["delta"] = delta
            # The terminal chunk carries finish_reason with an empty delta.
            if (
                choice.get("finish_reason") == "tool_calls"
                and self._seen
                and not (self._seen - self._dropped)
            ):
                choice["finish_reason"] = "stop"
        return chunk


def aggregate_sse(text: str, model: str, offered) -> dict:
    """Folds an OpenAI SSE stream into a single `chat.completion` object.

    Gate 4 forces every free-tier request to stream, so a client that asked for
    `stream: false` would otherwise receive a body it cannot parse. Synthetic
    calls are filtered on the way through.
    """
    stream_filter = StreamFilter(offered)
    content, reasoning = "", ""
    calls: dict[int, dict] = {}
    order: list[int] = []
    finish_reason = "stop"
    ident = "chatcmpl-jxproxy"
    created = int(time.time())
    usage = None
    role = "assistant"

    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("data:"):
            continue
        payload = line[len("data:"):].lstrip()
        if payload == "[DONE]":
            break
        try:
            chunk = json.loads(payload)
        except ValueError:
            continue
        chunk = stream_filter.filter(chunk)

        ident = chunk.get("id") or ident
        created = chunk.get("created") or created
        usage = chunk.get("usage") or usage
        choices = chunk.get("choices") or []
        if not choices:
            continue
        first = choices[0]
        delta = first.get("delta") or {}
        role = delta.get("role") or role
        content += delta.get("content") or ""
        reasoning += delta.get("reasoning_content") or ""
        for call in delta.get("tool_calls") or []:
            index = call.get("index", 0)
            if index not in calls:
                calls[index] = {"id": call.get("id") or f"call_{index}", "type": "function",
                                "function": {"name": "", "arguments": ""}}
                order.append(index)
            function = call.get("function") or {}
            if function.get("name"):
                calls[index]["function"]["name"] = function["name"]
            if function.get("arguments"):
                calls[index]["function"]["arguments"] += function["arguments"]
        if first.get("finish_reason"):
            finish_reason = first["finish_reason"]

    message: dict = {"role": role}
    message["content"] = None if (not content and calls) else content
    if reasoning:
        message["reasoning_content"] = reasoning
    if calls:
        message["tool_calls"] = [calls[i] for i in sorted(order)]
        if finish_reason == "stop":
            finish_reason = "tool_calls"

    root = {
        "id": ident,
        "object": "chat.completion",
        "created": created,
        "model": model,
        "choices": [{"index": 0, "message": message, "finish_reason": finish_reason}],
    }
    if usage:
        root["usage"] = usage
    return root


# --------------------------------------------------------------------------
# Live probe
# --------------------------------------------------------------------------

def post(headers: dict, body: dict, endpoint: str = ENDPOINT, timeout: int = 90):
    request = urllib.request.Request(
        endpoint,
        data=json.dumps(body).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode("utf-8", "replace")
    except Exception as exc:  # noqa: BLE001 - probe reports anything
        return -1, str(exc)


def _tools(*names):
    return [synthetic_declaration(n) for n in names]


def _base_body():
    return {
        "model": "big-pickle",
        "messages": [{"role": "user", "content": "Reply with the single word: ok"}],
        "max_tokens": 16,
    }


def _valid_headers(**overrides):
    headers = {"Content-Type": "application/json", **fingerprint("https://opencode.ai/zen/v1", False)}
    headers.update(overrides)
    return {k: v for k, v in headers.items() if v is not None}


def gate_cases():
    """(label, expected_status, headers, body) — one input varied per case."""
    body_with_tools = {**_base_body(), "stream": True, "tools": _tools("bash", "read")}

    def case(label, expect, headers=None, body=None):
        return (label, expect, headers if headers is not None else _valid_headers(),
                body if body is not None else body_with_tools)

    return [
        # The positive control: everything present.
        case("ALL GATES SATISFIED", 200),
        # Gate 1
        case("gate1  UA='opencode' (no version)", 403, _valid_headers(**{"User-Agent": "opencode"})),
        case("gate1  UA='9router/1.0' (third party)", 403, _valid_headers(**{"User-Agent": "9router/1.0"})),
        case("gate1  UA='opencode/1.16.0' (below floor)", 426, _valid_headers(**{"User-Agent": "opencode/1.16.0"})),
        # Gate 2 — strip the ENTIRE session-header family, since v2 accepts the
        # id via x-opencode-session OR (when that is absent) x-opencode-session-id
        # / x-session-affinity / X-Session-Id. Removing only one is no longer a
        # violation, so the negative case must remove all of them.
        case("gate2  no session headers (all)", 403,
             _valid_headers(**{"x-opencode-session": None, "x-opencode-session-id": None,
                               "x-session-affinity": None, "X-Session-Id": None})),
        case("gate2  ses_ + 24 hex (UUID-derived)", 403,
             _valid_headers(**{"x-opencode-session": "ses_" + "a" * 24})),
        case("gate2  prefix not lowercase hex", 403,
             _valid_headers(**{"x-opencode-session": "ses_" + "A" * 12 + "b" * 14})),
        # Gate 3
        case("gate3  tools=[] (none)", 403, None, {**_base_body(), "stream": True, "tools": []}),
        case("gate3  ['bash'] only", 403, None, {**_base_body(), "stream": True, "tools": _tools("bash")}),
        case("gate3  ['bash','glob'] (no read)", 403,
             None, {**_base_body(), "stream": True, "tools": _tools("bash", "glob")}),
        case("gate3  ['Bash','Read'] (wrong case)", 403,
             None, {**_base_body(), "stream": True, "tools": _tools("Bash", "Read")}),
        case("gate3  ['bash','read','fake'] (superset ok)", 200,
             None, {**_base_body(), "stream": True, "tools": _tools("bash", "read", "totally_fake_tool")}),
        # Gate 4
        case("gate4  stream=false", 403, None, {**_base_body(), "stream": False, "tools": _tools("bash", "read")}),
        # Authorization is NOT a gate.
        case("auth   no Authorization header", 200,
             {k: v for k, v in _valid_headers().items() if k != "Authorization"}),
    ]


def run_probe(only: str | None, quiet: bool) -> int:
    if not quiet:
        print(f"OpenCode Zen free-tier gate probe\n  endpoint: {ENDPOINT}\n")
    failures = 0
    ran = 0
    for label, expect, headers, body in gate_cases():
        if only and not label.startswith(only):
            continue
        ran += 1
        status, raw = post(headers, body)
        ok = status == expect
        failures += 0 if ok else 1
        if not quiet:
            verdict = "ok " if ok else "FAIL"
            print(f"  [{verdict}] {label:44s} -> {status:>4} (expected {expect})")
            if not ok:
                print(f"          {raw[:150]}")
        time.sleep(0.3)

    if not quiet:
        print(f"\n{ran} cases, {failures} unexpected.")
        if failures:
            print("Zen has changed a gate. Re-derive it before trusting any shim.")
        print("NOTE: gate 1 is satisfied by any UA at or above the floor; gate 3 by a")
        print("      SUPERSET containing lowercase bash AND read; gate 2 by the 26-char")
        print("      ses_ shape only. Authorization is not checked at all.")
    return 1 if failures else 0


def run_shim_demo(quiet: bool = False) -> int:
    """Worst case (a caller with zero tools) and the primary harness shape
    (Claude Code, whose capitalised Bash/Read do NOT satisfy gate 3)."""
    def say(*args):
        if not quiet:
            print(*args)

    say("Shim demo — shipping shape, not a paraphrase\n")
    ok = True

    # --- control: what a harness that only adds headers would send -------------
    # A neutral UA (not urllib's default, which Cloudflare answers with its own
    # 1010 block page before Zen ever sees the request) so the body below is
    # Zen's real refusal.
    control_status, control_raw = post(
        {"Content-Type": "application/json", "User-Agent": "curl/8.7.1"}, _base_body())
    say(f"  control (no shim, zero tools)        -> {control_status}")
    say(f"    {control_raw[:130]}")
    ok = ok and control_status == 403

    # --- worst case: zero tools ----------------------------------------------
    headers = apply_headers({"Content-Type": "application/json"},
                            "https://opencode.ai/zen/v1", has_key=False)
    body = _base_body()
    forced = conform(body)
    status, raw = post(headers, body)
    offered: set = set()
    result = strip_synthetic_tool_calls(aggregate_sse(raw, body["model"], offered), offered)
    choice = (result.get("choices") or [{}])[0]
    message = choice.get("message") or {}
    leaked = [c for c in (message.get("tool_calls") or [])
              if (c.get("function") or {}).get("name") in SYNTHETIC_TOOL_NAMES]
    say(f"  shim (zero tools)                    -> {status}, forced_stream={forced}")
    say(f"    object={result.get('object')} finish={choice.get('finish_reason')} "
          f"content={(message.get('content') or '')[:40]!r} leaked={len(leaked)}")
    ok = ok and status == 200 and not leaked and bool(message.get("content"))

    # --- primary harness: Claude Code's tool suite ----------------------------
    claude_tools = ["Bash", "Read", "Edit", "Glob", "Grep", "Write", "TodoWrite",
                    "WebFetch", "WebSearch", "Task"]
    headers = apply_headers({"Content-Type": "application/json"},
                            "https://opencode.ai/zen/v1", has_key=False)
    body = _base_body()
    body["tools"] = [{"type": "function",
                      "function": {"name": n, "parameters": {"type": "object", "properties": {}}}}
                     for n in claude_tools]
    conform(body)
    status, raw = post(headers, body)
    sent = tool_names_openai(body["tools"])
    result = strip_synthetic_tool_calls(aggregate_sse(raw, body["model"], set(claude_tools)),
                                        set(claude_tools))
    choice = (result.get("choices") or [{}])[0]
    message = choice.get("message") or {}
    leaked = [c for c in (message.get("tool_calls") or [])
              if (c.get("function") or {}).get("name") in SYNTHETIC_TOOL_NAMES]
    say(f"  shim (Claude Code's 10 tools)        -> {status}, tools sent={len(sent)} "
          f"(caller 10 + shim 2)")
    say(f"    caller tools intact={set(claude_tools) <= sent} leaked={len(leaked)}")
    ok = ok and status == 200 and set(claude_tools) <= sent and not leaked

    say(f"\nRESULT: {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--gate", help="only probe cases whose label starts with this (e.g. gate3)")
    parser.add_argument("--quiet", action="store_true", help="no output, exit status only")
    parser.add_argument("--no-demo", action="store_true", help="skip the shim demo")
    args = parser.parse_args()

    failures = run_probe(args.gate, args.quiet)
    if not args.no_demo and not args.gate:
        if not args.quiet:
            print()
        failures |= run_shim_demo(args.quiet)
    return failures


if __name__ == "__main__":
    sys.exit(main())
