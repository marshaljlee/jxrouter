# JXRouter

JXRouter is a lightweight, system-wide proxy and DNS redirector for macOS that transparently routes AI API requests (OpenAI, Anthropic, etc.) to your preferred LLM provider or local models. 

## Features
- **DNS Hijacking**: Intercepts domains like `api.anthropic.com` and routes them locally.
- **System Proxy**: Optional system-wide HTTP/HTTPS proxy.
- **App-Specific Routing**: Route or block AI traffic on a per-app basis.
- **Provider Translation**: Transparently translate requests to OpenCode, OpenRouter, OpenAI, Anthropic, or Local Ollama.

## Installation

Run the included install script to build the app, clean up extended attributes, and move it to your Applications folder:

```bash
./install.sh
```

## Requirements
- macOS 14.0+
- Xcode Command Line Tools (`xcode-select --install`)
