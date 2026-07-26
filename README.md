# JXProxy

A lightweight, system-wide proxy and DNS redirector for macOS that transparently routes AI API requests (Anthropic, OpenAI, etc.) to your preferred LLM provider. Powered by the **JXProxy** native macOS app.

Run **Claude Code**, **Codex**, or any AI coding agent through your own provider-backed proxy with a native macOS UI — no web admin required.

## Features

- **Native macOS App** — Menu bar app with dashboard, settings, and live traffic logs (replaces FCC's web admin UI)
- **30+ Providers** — NVIDIA NIM, OpenRouter, OpenAI, DeepSeek, Gemini, Mistral, Groq, Cohere, HuggingFace, local Ollama/LM Studio/llama.cpp, and more
- **System Proxy** — Optional system-wide HTTP/HTTPS proxy
- **DNS Hijacking** — Intercepts domains like `api.anthropic.com` and routes them locally
- **Model-Tier Routing** — Route Opus, Sonnet, and Haiku to different models
- **Provider Fallback** — Chain multiple providers for reliability
- **App-Specific Routing** — Route or block AI traffic on a per-app basis
- **Provider Translation** — Transparently translate Anthropic Messages API ↔ OpenAI Chat Completions
- **Streaming** — Full SSE streaming support with real-time translation
- **CLI Launchers** — `jxclaude`, `jxcodex`, `jxpi` wrappers for one-command agent launch
- **Auth Token** — Optional token-based proxy authentication
- **Keychain Integration** — API keys stored securely in macOS Keychain

## Quick Start

### 1. Install

```bash
./install.sh
```

This builds the app, installs it to `/Applications`, creates CLI launcher scripts in `~/.local/bin/`, and configures your shell PATH.

### 2. Start JXProxy

Open **JXProxy** from your Applications folder or the desktop shortcut:

```bash
open /Applications/JXRouter.app
```

Or from the terminal:

```bash
jxserver
```

The app runs in the menu bar. Left-click the bolt icon to show the dashboard, right-click for the context menu.

Default settings:
- **Port:** 5255
- **Auth Token:** jxproxy
- **Default Provider:** OpenCode Zen

### 3. Configure a Provider

Open the app dashboard → click the gear icon → **Providers** tab.

Enter your API key for any of the supported providers and click **Apply**. Keys are stored in the macOS Keychain.

Recommended free/zero-config providers:
- **OpenCode Zen** — No API key needed, great fallback
- **NVIDIA NIM** — Free API key at build.nvidia.com
- **DeepSeek** — Free tier available
- **Groq** — Free tier with Llama models
- **Ollama** — Fully local, no key needed

### 4. Run Your Coding Agent

**Claude Code:**
```bash
jxclaude
```

**Codex:**
```bash
jxcodex
```

**Pi:**
```bash
jxpi
```

All launchers set the necessary environment variables to route through JXProxy. Normal CLI arguments work too:

```bash
jxclaude exec "explain this codebase"
jxcodex exec "hello"
```

## Provider Configuration

Open the JXProxy app → Settings → **Providers** tab to enter API keys.

| Provider | Admin Setting | API Key Required? |
|---|---|---|
| OpenCode Zen | No key needed | ❌ |
| OpenCode Go | No key needed | ❌ |
| Anthropic Direct | `ANTHROPIC_API_KEY` | ✅ |
| OpenAI / Codex | `OPENAI_API_KEY` | ✅ |
| OpenRouter | `OPENROUTER_API_KEY` | ✅ |
| NVIDIA NIM | `NVIDIA_NIM_API_KEY` | ✅ |
| DeepSeek | `DEEPSEEK_API_KEY` | ✅ |
| Google Gemini | `GEMINI_API_KEY` | ✅ |
| Mistral | `MISTRAL_API_KEY` | ✅ |
| Mistral Codestral | `CODESTRAL_API_KEY` | ✅ |
| Cohere | `COHERE_API_KEY` | ✅ |
| Groq | `GROQ_API_KEY` | ✅ |
| Fireworks AI | `FIREWORKS_API_KEY` | ✅ |
| SambaNova | `SAMBANOVA_API_KEY` | ✅ |
| Cerebras | `CEREBRAS_API_KEY` | ✅ |
| HuggingFace | `HUGGINGFACE_API_KEY` | ✅ |
| GitHub Models | `GITHUB_MODELS_TOKEN` | ✅ |
| Wafer | `WAFER_API_KEY` | ✅ |
| Kimi API | `KIMI_API_KEY` | ✅ |
| Kimi Code | `KIMI_CODE_API_KEY` | ✅ |
| MiniMax | `MINIMAX_API_KEY` | ✅ |
| xAI Grok | `XAI_API_KEY` | ✅ |
| Z.ai | `ZAI_API_KEY` | ✅ |
| Ollama Cloud | `OLLAMA_API_KEY` | ✅ |
| Vercel AI Gateway | `AI_GATEWAY_API_KEY` | ✅ |
| Ollama (Local) | No key needed | ❌ |
| LM Studio (Local) | No key needed | ❌ |
| llama.cpp (Local) | No key needed | ❌ |

### Model Routing

In the JXProxy app → Settings → **General** tab, you can set:

- **Default Model** — The model used for all requests (fallback)
- **Model Opus** — Override for opus-tier Claude requests
- **Model Sonnet** — Override for sonnet-tier requests
- **Model Haiku** — Override for haiku-tier requests

### Provider Fallback

Set comma-separated fallback providers in the **General** tab. If the primary provider returns a 5xx error, JXProxy automatically tries the next provider in the chain.

Default fallback: `deepseek,groq`

## VS Code Integration

### Claude Code in VS Code

Install the [Claude Code extension](https://marketplace.visualstudio.com/items?itemName=anthropic.claude-code). Open VS Code user settings as JSON and add:

```json
"claudeCode.disableLoginPrompt": true,
"claudeCode.environmentVariables": [
  { "name": "ANTHROPIC_BASE_URL", "value": "http://localhost:5255" },
  { "name": "ANTHROPIC_AUTH_TOKEN", "value": "jxproxy" },
  { "name": "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY", "value": "1" },
  { "name": "CLAUDE_CODE_AUTO_COMPACT_WINDOW", "value": "190000" },
  { "name": "DISABLE_AUTOUPDATER", "value": "1" },
  { "name": "DISABLE_FEEDBACK_COMMAND", "value": "1" },
  { "name": "DISABLE_ERROR_REPORTING", "value": "1" }
]
```

### Codex in VS Code

Install the [Codex extension](https://marketplace.visualstudio.com/items?itemName=OpenAI.codex). Create or edit `~/.codex/config.toml`:

```toml
model_provider = "jxproxy"
model = "opencode/big-pickle"

[model_providers.jxproxy]
name = "JXProxy"
base_url = "http://127.0.0.1:5255/v1"
http_headers = { Authorization = "Bearer jxproxy" }
wire_api = "responses"
```

### Skip Login Prompt

If Claude Code asks you to log in after configuring the proxy URL:

```bash
echo '{"hasCompletedOnboarding": true}' > ~/.claude.json
```

## Architecture

```
┌──────────────┐     ┌──────────────┐     ┌─────────────────┐
│  Coding      │────▶│  JXProxy     │────▶│  Provider API   │
│  Agent       │     │  (Port 5255) │     │  (Anthropic,    │
│ (Claude,     │     │              │     │   OpenAI,       │
│  Codex)      │     │  DNS Hijack  │     │   DeepSeek,     │
│              │     │  System Proxy│     │   etc.)         │
└──────────────┘     └──────────────┘     └─────────────────┘
                           │
                     ┌─────▼──────┐
                     │  Native    │
                     │  macOS App │
                     │ (JXProxy) │
                     └────────────┘
```

JXProxy acts as a local gateway:
1. Requests from coding agents hit JXProxy (either through system proxy, DNS redirect, or explicit base URL)
2. JXProxy translates Anthropic Messages API ↔ OpenAI Chat Completions format
3. The request is forwarded to your chosen provider
4. Streaming SSE responses are translated back in real-time

## Requirements

- macOS 14.0+
- Xcode Command Line Tools (`xcode-select --install`)
- Claude Code: `npm install -g @anthropic-ai/claude-code`
- Codex: Install from [chatgpt.com/codex](https://chatgpt.com/codex)

## Uninstall

```bash
./uninstall.sh
```

Or manually:
1. Quit JXProxy from the menu bar
2. Delete `/Applications/JXRouter.app`
3. Remove `~/.local/bin/jxproxy-*`
4. Clean up shell config

## Credits

Inspired by [Free Claude Code (FCC)](https://github.com/Alishahryar1/free-claude-code) — the original Python-based proxy that pioneered multi-provider coding agent routing. JXProxy rebuilds the concept as a native macOS application with a SwiftUI interface.
