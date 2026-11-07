# Functional Journey Map: JXRouter

## Core User Journeys

### 1. Proxy Daemon Lifecycle & Traffic Observation
- **Entry**: Menu Bar Status Item / Main Popover (`JXRouterView`)
- **Actions**:
  - One-click Start / Stop proxy server
  - Toggle Remote Web Control server (LAN access)
  - View real-time traffic statistics (Active connections, Total requests, Token throughput)
  - Inspect live request logs with status pills, timestamps, and model identification
  - One-click memory purge & stray worker cleanup ("Free Memory")

### 2. Provider & Model Routing Configuration
- **Entry**: Settings Window (`SettingsView` -> Providers Tab)
- **Actions**:
  - Configure upstream providers (Anthropic, OpenAI, OpenRouter, Groq, Ollama, DeepSeek, Google Gemini, OpenCode Zen, Custom OpenAI-compatible)
  - Set Tier Routing mappings (`opus`, `sonnet`, `haiku`)
  - Test provider connectivity with live probe and latency reporting
  - Import API keys from shell configs (`.zshrc`, `.zshenv`)

### 3. Local Model Discovery & Execution
- **Entry**: Settings Window (`SettingsView` -> Local Models Tab)
- **Actions**:
  - Scan local GGUF models across configured library folders
  - Auto-configure context size, GPU offload layers, and hybrid KV allocations
  - Detect & pair multimodal vision projectors (`mmproj`)
  - Automatic PrismML ternary model detection & dedicated fork routing
  - In-place GGUF Jinja chat template sanitation & validation
  - Start/Stop local model server with RAM preflight guardrails

### 4. Direct Chat Interaction
- **Entry**: Menu Bar -> Chat Window (`ClaudeChatView`)
- **Actions**:
  - Send messages directly through the proxy to active model
  - Real-time streaming response with reasoning block disclosure (`<think>` and `reasoning_content`)
  - Tool call execution preview and result formatting

### 5. Multi-Agent Vault Management
- **Entry**: Menu Bar -> Vault Window (`VaultViews` / `VaultWorkspaceView`)
- **Actions**:
  - View connected agent workspaces and project journals
  - Manage agent configurations (Claude Code, OpenCode, Codex)

