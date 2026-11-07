# JXRouter (JXProxy)

A high-performance macOS menu-bar proxy and multi-agent AI gateway that transparently routes LLM traffic — Claude Code, Codex, OpenCode, and OpenAI SDK clients — through configured remote cloud providers or local inference engines (`llama.app`, Ollama, local GGUF runtimes, and bundled PrismML ternary models). Native SwiftUI/AppKit app, no web admin, no `/etc/hosts` edits, and zero pf packet-filter rules.

## Core Capabilities

- **Zero-Config Agent Routing**:
  - **Claude Code**: Configured automatically via `~/.claude/settings.json` (loopback proxy, token-authenticated).
  - **OpenCode & Codex**: Automated configuration via safe JSON updates to `~/.opencode/config.json` and `~/.codex/config.json`.
- **AMEEM v3.0 Request & Execution Engine**:
  - **Dialect Auto-Detection & Recovery**: Extracts function and tool calls across diverse template dialects (`TAG_JSON`, `TAG_TAGGED_EQ`, Markdown blocks) without losing call arguments.
  - **Response Hygiene**: Sanitizes leaked prompt control tokens (`<|im_start|>`, `<|eot_id|>`, etc.) and removes leading role headers (`system\n`, `assistant\n`) in both streaming and SSE streams.
  - **Preflight Sampling & Guardrails**: Enforces optimal sampling defaults (`temp 0.6 / minP 0.02 / topP 0.95 / topK 20 / repeatPenalty 1.05`) and provides RAM preflight checks.
- **OpenCode Zen Free-Tier Shim**:
  - Live fingerprint spoofing and conformance headers (`x-opencode-session`, exact user agent thresholds, forced streaming aggregation, and synthetic tool call filtering) allowing non-OpenCode harnesses to utilize free tier endpoints safely.
- **GGUF Chat Template In-Place Sanitizer**:
  - Neutralizes fatal Jinja `raise_exception` statements in GGUF metadata directly in-place with exact byte preservation.
- **Native Local Model Runtimes**:
  - Auto-detection and auto-starting of local models with cold-start request buffering.
  - Bundled **PrismML llama.cpp fork** with PQ2_0 ternary quantization support directly inside the app bundle.
- **Authentic Design & Vector Geometry**:
  - Menu-bar and dock icon aligned with the JX product family lightning mark on dark continuous-corner squircles in signature electric violet (`#8B5CF6` / `#A78BFA`).
  - Native vector rendering powered by [Tabler Icons](https://github.com/tabler/tabler-icons) with bounded frame metrics across all UI views.
  - Fluid ProMotion spring slide-out settings drawer (`0.16, 1.0, 0.3, 1.0`).

## How Routing Works

1. **Claude Code & Agents**: Direct connection to loopback proxy on `127.0.0.1:5255` (configurable).
2. **Model Tier Routing**: Map `Opus`, `Sonnet`, and `Haiku` tiers to distinct providers or local models with automatic fallback chains.
3. **System-Wide Routing** (optional): Settings → System → **Enable System-Wide Proxy** intercepts `api.anthropic.com` and `api.openai.com` requests while letting all other traffic pass through untouched.
4. **Per-App Routing Rules**: Selectively Route AI, Pass Through, or Block traffic on an application-by-application basis.

## Quick Start

```bash
./install.sh
```

The script builds the universal release bundle, stages dependencies, installs to `/Applications` (or custom app destination), sets up CLI launchers (`jxclaude`, `jxcodex`, `jxpi`), and verifies health on port `5255`.

To compile a universal release package without deploying:

```bash
./build-all.sh macos
```

## CLI Usage

For command-line tools that read proxy environment variables:

```bash
# Standard HTTPS proxy
export HTTPS_PROXY=http://127.0.0.1:5255

# OpenAI SDK clients
export OPENAI_BASE_URL=http://127.0.0.1:5255/v1
```

Default proxy port: **5255** (configurable).

## Testing & Quality Assurance

JXRouter maintains a comprehensive test suite covering translation matrices, AMEEM firewall gates, template sanitization, response hygiene, and streaming aggregation:

```bash
xcodebuild -project JXRouter.xcodeproj -scheme JXRouter -destination "platform=macOS" OTHER_SWIFT_FLAGS="-disable-sandbox" test
```

## Uninstallation

To cleanly revert all configuration changes and remove launchers:

```bash
./uninstall.sh
```

All credentials remain securely stored in the macOS Keychain and are never written to plaintext disk logs.
