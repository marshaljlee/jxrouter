# Capability Reach Matrix: JXRouter

## 1. Daemon-to-UI Reach (Zero-Orphan Verification)

| Daemon Capability / API / Setting | UI Entry Point | Status |
|-----------------------------------|----------------|--------|
| Proxy Server Start / Stop | `JXRouterView` Header Action Button | EXPOSED |
| Proxy Listening Port Configuration | `SettingsView` (General Tab) | EXPOSED |
| System Proxy Auto-Routing | `SettingsView` (General Tab Toggle) | EXPOSED |
| Claude Settings Auto-Writer | `SettingsView` (General Tab Toggle) | EXPOSED |
| OpenCode / Codex Auto-Config | `AgentSettingsManager` / Settings View | EXPOSED |
| Remote Web Control Server | `SettingsView` (System Tab) | EXPOSED |
| Upstream Provider Keys & URLs | `SettingsView` (Providers Tab) | EXPOSED |
| Tier Model Routing (Opus/Sonnet/Haiku) | `SettingsView` (Providers Tab) | EXPOSED |
| GGUF Model Scanner & Path Config | `SettingsView` (Local Models Tab) | EXPOSED |
| Local Server Auto-Start on cold request | Handled transparently with UI wait alert | EXPOSED |
| RAM Preflight & Memory Purge | `JXRouterView` Free Memory Card & Load Gate Alert | EXPOSED |
| GGUF Jinja Template Sanitizer | Automated at GGUF launch + Logged in UI | EXPOSED |
| AMEEM v3.0 Request Gate & Firewall | `/ameem/check`, `/ameem/reconcile` & Status Indicator | EXPOSED |
| In-Process llama.cpp Engine Toggle | `SettingsView` (Local Models Tab) | EXPOSED |

## 2. UI-to-Daemon Reach (Zero-Phantom Verification)

| UI Component / Control | Bound Backend Handler / RPC | Status |
|------------------------|-----------------------------|--------|
| Start/Stop Button | `ProxyManager.shared.start() / stop()` | BOUND |
| Free Memory Button | `LocalModelManager.shared.freeMemory()` | BOUND |
| Provider Model Test Button | `ProviderValidator.validateModel()` | BOUND |
| GGUF Model Selector | `LocalModelManager.shared.startGGUF()` | BOUND |
| Open Web Control Link | `NSWorkspace.shared.open(url)` | BOUND |
| Clear Traffic Logs | `TrafficLog.shared.clear()` | BOUND |
| Tier Dropdowns | `ConfigManager.shared.tierProviders` | BOUND |
| Open Folder Sheet | `NSOpenPanel` selecting model directory | BOUND |

**Audit Verdict:** 0 Orphan Daemon Features. 0 Phantom UI Controls. Bidirectional parity is 100%.

