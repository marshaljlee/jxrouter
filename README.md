# JXProxy (JXRouter)

A lightweight macOS menu-bar proxy that routes AI API traffic — Claude Code, Codex, OpenAI SDK clients — through **your** choice of LLM providers: remote (InferX, NVIDIA NIM, DeepSeek, OpenRouter, Groq, …) or local (Ollama, `llama.app`). Native SwiftUI/AppKit app, no web admin, no `/etc/hosts` edits, no pf rules.

> **Opt-in and additive.** Nothing on your system is modified until you press **Start** or enable system-wide routing, and everything the app writes is removed by `./uninstall.sh`.

## How routing works

- **Claude Code** is routed automatically via `~/.claude/settings.json` (loopback connection to the local proxy, token-authenticated) — no system changes required.
- **System-wide routing** (optional): Settings → System → **Enable System-Wide Proxy** routes other apps' HTTP/HTTPS traffic through JXProxy. `api.anthropic.com` and `api.openai.com` requests are intercepted and sent to your configured providers; **every other connection passes through unmodified** (raw relay, no TLS termination).
- HTTPS interception of those two AI hosts requires trusting the bundled CA certificate: menu-bar icon → **Security → Install CA Certificate**.
- **Model-tier routing**: map Opus / Sonnet / Haiku (and OpenAI equivalents) to different models or providers, with automatic provider fallback chains.
- **Local providers** are auto-detected — Ollama, and the Llama desktop app (`llama.app`), whose built-in OpenAI-compatible server serves on port 8080.

## Quick start

```bash
./install.sh   # builds the app, installs to /Applications, creates jxclaude / jxcodex launchers in ~/.local/bin, configures shell PATH
open /Applications/JXRouter.app
```

Click the **JXProxy** menu-bar icon → **Start**.

## Setup

1. **Settings → Providers** — pick your provider(s), paste API keys, hit **Verify** (green tick). Keys are stored in the macOS Keychain, never in plaintext files.
   - On launch the app also imports keys it finds in `~/.zshrc`, `~/.zshenv`, `~/.bash_profile`, `~/.bashrc`, and legacy `~/.jxproxy/config.env` — **only into empty slots**, never overwriting keys you entered yourself.
2. **Settings → General** — choose the active provider and routing mode. The model tiers auto-populate from each provider's live model list; **Test All Models** validates the whole chain and surfaces full server error messages.
3. **Settings → Routing** — per-app routing rules (route or block AI traffic per application).
4. **Settings → System** — system-wide proxy toggle, CA install, and uninstall options.

### Shell CLI tools (curl, Codex CLI, Python)

CLI tools launched from a terminal don't always honor the macOS system proxy — they read env vars instead:

```bash
export HTTPS_PROXY=http://127.0.0.1:5255
# or for OpenAI-compatible clients:
export OPENAI_BASE_URL=http://127.0.0.1:5255/v1
```

Default proxy port: **5255** (configurable).

## What the app writes (and cleans up)

| Path | Purpose | Removed on uninstall |
|---|---|---|
| `~/.claude/settings.json` | Claude Code routing config | restored to original |
| `~/.local/bin/jxclaude`, `~/.local/bin/jxcodex` | CLI launchers | deleted |
| `~/.claude/CLAUDE.md` | managed "constitution" block | block removed |
| `~/.zshrc` / `~/.zshenv` | launcher PATH lines | lines removed |
| macOS Keychain | your provider API keys | entries removed |

`./uninstall.sh` removes all of the above **and** strips any legacy DNS-hijack entries (old pre-2026 app versions wrote `JXProxy` / `ProxySwitch` marker blocks into `/etc/hosts`) plus any leftover pf anchor — so it can fully clean a machine that previously ran an old build.

## Remote Web Control (iOS / Android web-wrapper apps)

The app ships a small remote-control web panel — a JSON API + single-page app
served on your LAN — so you can monitor and control JXProxy from your phone.

1. **Settings → System → Remote Web Control** → enable it (off by default; the
   port is reachable on your network, so only enable on trusted Wi-Fi).
2. Note the port (default **5355**) and the proxy auth token (Settings → General).
3. Open the web panel in any browser on the LAN, or use the bundled wrapper apps:
   - **iOS** — open `ios/JXProxyMobile.xcodeproj` in Xcode, set your signing
     team, run. In the Simulator the default URL `http://127.0.0.1:5355` reaches
     the Mac directly; on a device enter the Mac's LAN IP.
   - **Android** — open `android/` in Android Studio (or `gradle assembleDebug`)
     and point it at `http://<mac-ip>:5355`.

The panel shows live status, lets you start/stop the proxy, switch providers,
and browse recent traffic with the serving provider + fallback badges.

## Development

```bash
xcodebuild -project JXRouter.xcodeproj -scheme JXRouter -configuration Release build
```

### macOS Intel / universal build

The app is a universal binary (arm64 + x86_64) — one build runs on Apple
Silicon and Intel Macs:

```bash
xcodebuild -project JXRouter.xcodeproj -scheme JXRouter -configuration Release \
  -derivedDataPath build build ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO
# signed universal .app: build/Build/Products/Release/JXRouter.app
```

Pure SwiftUI/AppKit, no third-party dependencies. Source lives in `Sources/JXRouter/`.

## Notes

- DNS/pf hijacking is **permanently removed** — the current app never writes `/etc/hosts` or pf rules. Any re-introduction is a bug.
- Auth token: the local proxy authenticates Claude Code via an auto-generated token; an optional token can also gate external clients.
