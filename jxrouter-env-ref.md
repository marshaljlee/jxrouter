# JXRouter — Complete Environment Reference v1.0.0
# ==================================================
# Source: github.com/marshaljlee/jxrouter
#
# This file is the canonical registry of every environment variable,
# configuration key, UserDefaults key, config-file path, and migration
# key used by JXProxy across all platforms (macOS native, Android/Termux).
#
# Sections:
#   1.  Core Environment Variables
#   2.  Provider API Key Env Vars (macOS Keychain / Android env)
#   3.  AI Coding Agent Tunnel Env Vars
#   4.  macOS UserDefaults Keys (Swift App)
#   5.  Android Config File Keys (Python — ~/.config/jxproxy/config.json)
#   6.  Legacy ~/.jxproxy/config.env Migration Keys
#   7.  File Paths (all platforms)
#   8.  Default Values Quick Reference
# ==================================================

# ──────────────────────────────────────────────────────────────────────────────
# SECTION 1: Core Environment Variables
# ──────────────────────────────────────────────────────────────────────────────
# These control the proxy server itself. Used by both macOS and Android builds.

JXPROXY_PORT
  Description: TCP port the proxy listens on
  Default:     5255
  Type:        integer (1024–65535)
  Set via:     shell env, install.sh, install-termux.sh, jxproxy.py --port
  Example:     export JXPROXY_PORT=8080
  macOS ref:   Sources/JXRouter/ConfigManager.swift (UDKey.port)
  Android ref: jxproxy.py (DEFAULT_PORT)

JXPROXY_AUTH_TOKEN
  Description: Bearer token required by clients to authenticate with the proxy
  Default:     jxproxy
  Type:        string
  Set via:     shell env, install.sh, install-termux.sh
  Example:     export JXPROXY_AUTH_TOKEN="my-secret-token"
  macOS ref:   Sources/JXRouter/ConfigManager.swift (UDKey.authToken)
  Android ref: jxproxy.py (DEFAULT_AUTH_TOKEN)

JXPROXY_PROVIDER
  Description: Active/primary provider identifier
  Default:     opencode-zen
  Type:        string (one of the 20+ provider IDs)
  Set via:     Legacy config.env migration only
  macOS ref:   Sources/JXRouter/ConfigManager.swift (migrate from config.env)

# ──────────────────────────────────────────────────────────────────────────────
# SECTION 2: Provider API Key Environment Variables
# ──────────────────────────────────────────────────────────────────────────────
# These are read in priority order:
#   1. Environment variable (highest)
#   2. macOS Keychain (com.jxproxy service)
#   3. UserDefaults fallback dictionary (apiKeysDict)
#   4. Android: ~/.config/jxproxy/api_keys.json
#
# macOS: stored via KeychainManager.store(key:chainKey, value:)
# Android: stored in api_keys.json, also read from env vars at runtime

ANTHROPIC_API_KEY
  Description: API key for Anthropic Direct provider
  Provider ID: direct
  Required:    Yes (for direct provider)
  macOS ref:   ConfigManager.KeychainKey.anthropic
  Android ref: jxproxy.py env_map["direct"]

OPENAI_API_KEY
  Description: API key for OpenAI / Codex provider
  Provider ID: openai
  Required:    Yes
  macOS ref:   ConfigManager.KeychainKey.openai
  Android ref: jxproxy.py env_map["openai"]

OPENROUTER_API_KEY
  Description: API key for OpenRouter provider
  Provider ID: openrouter
  Required:    Yes
  macOS ref:   ConfigManager.KeychainKey.openrouter
  Android ref: jxproxy.py env_map["openrouter"]

OPENCODE_API_KEY
  Description: API key for OpenCode Zen / OpenCode Go providers
  Provider ID: opencode-zen, opencode-go
  Required:    No (free tier available)
  macOS ref:   ConfigManager.KeychainKey.opencode
  Android ref: jxproxy.py env_map["opencode-zen"], env_map["opencode-go"]

NVIDIA_NIM_API_KEY
  Description: API key for NVIDIA NIM provider
  Provider ID: nvidia-nim
  Required:    Yes
  macOS ref:   ConfigManager.KeychainKey.nvidia
  Android ref: jxproxy.py env_map["nvidia-nim"]

DEEPSEEK_API_KEY
  Description: API key for DeepSeek provider
  Provider ID: deepseek
  Required:    Yes
  macOS ref:   ConfigManager.KeychainKey.deepseek
  Android ref: jxproxy.py env_map["deepseek"]

GEMINI_API_KEY
  Description: API key for Google Gemini provider
  Provider ID: gemini
  Required:    Yes
  macOS ref:   ConfigManager.KeychainKey.gemini
  Android ref: jxproxy.py env_map["gemini"]

MISTRAL_API_KEY
  Description: API key for Mistral provider
  Provider ID: mistral
  Required:    Yes
  macOS ref:   ConfigManager.KeychainKey.mistral
  Android ref: jxproxy.py env_map["mistral"]

CODESTRAL_API_KEY
  Description: API key for Mistral Codestral provider
  Provider ID: codestral
  Required:    Yes
  macOS ref:   ConfigManager.KeychainKey.codestral
  Android ref: (no env_map entry — stored file-only)

COHERE_API_KEY
  Description: API key for Cohere provider
  Provider ID: cohere
  Required:    Yes
  macOS ref:   ConfigManager.KeychainKey.cohere
  Android ref: jxproxy.py env_map["cohere"]

GROQ_API_KEY
  Description: API key for Groq provider
  Provider ID: groq
  Required:    Yes
  macOS ref:   ConfigManager.KeychainKey.groq
  Android ref: jxproxy.py env_map["groq"]

FIREWORKS_API_KEY
  Description: API key for Fireworks AI provider
  Provider ID: fireworks
  Required:    Yes
  macOS ref:   ConfigManager.KeychainKey.fireworks
  Android ref: jxproxy.py env_map["fireworks"]

SAMBANOVA_API_KEY
  Description: API key for SambaNova provider
  Provider ID: sambanova
  Required:    Yes
  macOS ref:   ConfigManager.KeychainKey.sambanova
  Android ref: (no env_map — stored file-only)

CEREBRAS_API_KEY
  Description: API key for Cerebras provider
  Provider ID: cerebras
  Required:    Yes
  macOS ref:   ConfigManager.KeychainKey.cerebras
  Android ref: (no env_map — stored file-only)

HUGGINGFACE_API_KEY
  Description: API key for HuggingFace Inference provider
  Provider ID: huggingface
  Required:    Yes
  macOS ref:   ConfigManager.KeychainKey.huggingface
  Android ref: jxproxy.py env_map["huggingface"]

GITHUB_MODELS_TOKEN
  Description: Token for GitHub Models provider
  Provider ID: github-models
  Required:    Yes
  macOS ref:   ConfigManager.KeychainKey.githubModels
  Android ref: jxproxy.py env_map["github-models"]

WAFER_API_KEY
  Description: API key for Wafer provider
  Provider ID: wafer
  Required:    Yes
  macOS ref:   ConfigManager.KeychainKey.wafer
  Android ref: (no env_map — stored file-only)

KIMI_API_KEY
  Description: API key for Kimi API provider
  Provider ID: kimi
  Required:    Yes
  macOS ref:   ConfigManager.KeychainKey.kimi
  Android ref: (no env_map — stored file-only)

KIMI_CODE_API_KEY
  Description: API key for Kimi Code provider
  Provider ID: kimi-code
  Required:    Yes
  macOS ref:   ConfigManager.KeychainKey.kimiCode
  Android ref: (no env_map — stored file-only)

MINIMAX_API_KEY
  Description: API key for MiniMax provider
  Provider ID: minimax
  Required:    Yes
  macOS ref:   ConfigManager.KeychainKey.minimax
  Android ref: (no env_map — stored file-only)

XAI_API_KEY
  Description: API key for xAI Grok provider
  Provider ID: xai
  Required:    Yes
  macOS ref:   ConfigManager.KeychainKey.xai
  Android ref: jxproxy.py env_map["xai"]

ZAI_API_KEY
  Description: API key for Z.ai provider
  Provider ID: zai
  Required:    Yes
  macOS ref:   ConfigManager.KeychainKey.zai
  Android ref: (no env_map — stored file-only)

OLLAMA_API_KEY
  Description: API key for Ollama Cloud provider
  Provider ID: ollama-cloud
  Required:    Yes
  macOS ref:   ConfigManager.KeychainKey.ollamaCloud
  Android ref: (no env_map — stored file-only)

AI_GATEWAY_API_KEY
  Description: API key for Vercel AI Gateway provider
  Provider ID: ai-gateway
  Required:    Yes
  macOS ref:   ConfigManager.KeychainKey.aiGateway
  Android ref: (no env_map — stored file-only)

CLOUDFLARE_API_TOKEN
  Description: API token for Cloudflare provider
  Provider ID: cloudflare
  Required:    Yes
  macOS ref:   ConfigManager.KeychainKey.cloudflareApiToken
  Android ref: (no env_map — stored file-only)

TELEGRAM_BOT_TOKEN
  Description: Bot token for Telegram bot integration
  Provider ID: (internal — bot service)
  Required:    Only if bot integration enabled
  macOS ref:   ConfigManager.KeychainKey.telegramBotToken
  Android ref: (not yet implemented)

ADMIN_PASSWORD
  Description: Password for admin endpoints
  Provider ID: (internal — admin auth)
  Required:    Only if admin password set
  macOS ref:   ConfigManager.KeychainKey.adminPassword
  Android ref: (not yet implemented)

# ──────────────────────────────────────────────────────────────────────────────
# SECTION 3: AI Coding Agent Tunnel Environment Variables
# ──────────────────────────────────────────────────────────────────────────────
# These are set by the launcher scripts (jxclaude, jxcodex, jxpi, jxserver)
# to redirect coding agent traffic through the JXProxy.

ANTHROPIC_BASE_URL
  Description: Base URL override for Anthropic SDK (Claude Code)
  Set by:      jxclaude launcher
  Value:       http://127.0.0.1:${JXPROXY_PORT}
  Example:     http://127.0.0.1:5255
  Ref:         install.sh, install-termux.sh, jxclaude launcher

ANTHROPIC_AUTH_TOKEN
  Description: Auth token for Anthropic SDK
  Set by:      jxclaude launcher
  Value:       ${JXPROXY_AUTH_TOKEN}
  Example:     jxproxy
  Ref:         install.sh, install-termux.sh, jxclaude launcher

OPENAI_BASE_URL
  Description: Base URL override for OpenAI SDK (Codex CLI, Pi)
  Set by:      jxcodex, jxpi launchers
  Value:       http://127.0.0.1:${JXPROXY_PORT}/v1
  Example:     http://127.0.0.1:5255/v1
  Ref:         install.sh, install-termux.sh, jxcodex, jxpi launchers

OPENAI_API_KEY
  Description: API key for OpenAI SDK (Codex CLI, Pi)
  Set by:      jxcodex, jxpi launchers
  Value:       ${JXPROXY_AUTH_TOKEN}
  Ref:         install.sh, install-termux.sh, jxcodex, jxpi launchers

CODEX_BASE_URL
  Description: Base URL override for Codex CLI
  Set by:      jxcodex launcher
  Value:       http://127.0.0.1:${JXPROXY_PORT}/v1
  Ref:         install.sh, install-termux.sh, jxcodex launcher

CODEX_API_KEY
  Description: API key for Codex CLI
  Set by:      jxcodex launcher
  Value:       ${JXPROXY_AUTH_TOKEN}
  Ref:         install.sh, install-termux.sh, jxcodex launcher

CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY
  Description: Enables Claude Code to discover models via the proxy
  Set by:      jxclaude launcher
  Value:       1
  Ref:         install.sh, install-termux.sh, jxclaude launcher

CLAUDE_CODE_AUTO_COMPACT_WINDOW
  Description: Sets auto-compact window for Claude Code
  Set by:      jxclaude launcher
  Value:       190000
  Ref:         install.sh, install-termux.sh, jxclaude launcher

DISABLE_AUTOUPDATER
  Description: Disables Claude Code auto-updater
  Set by:      jxclaude launcher (macOS only)
  Value:       1
  Ref:         install.sh, jxclaude launcher (macOS)

DISABLE_FEEDBACK_COMMAND
  Description: Disables Claude Code feedback prompts
  Set by:      jxclaude launcher (macOS only)
  Value:       1
  Ref:         install.sh, jxclaude launcher (macOS)

DISABLE_ERROR_REPORTING
  Description: Disables Claude Code error reporting
  Set by:      jxclaude launcher (macOS only)
  Value:       1
  Ref:         install.sh, jxclaude launcher (macOS)

# ──────────────────────────────────────────────────────────────────────────────
# SECTION 4: macOS UserDefaults Keys (Swift App)
# ──────────────────────────────────────────────────────────────────────────────
# These are stored in NSUserDefaults (com.apple.preferences) by the SwiftUI app.
# Accessible via `defaults read com.marshaljlee.jxproxy` on macOS.

proxyPort
  Type:    integer
  Default: 5255
  Config:  ConfigManager.port
  Plist:   com.marshaljlee.jxproxy proxyPort

activeProvider
  Type:    string
  Default: "opencode-zen"
  Config:  ConfigManager.provider
  Plist:   com.marshaljlee.jxproxy activeProvider

activeModel
  Type:    string
  Default: "big-pickle"
  Config:  ConfigManager.model

modelOpus
  Type:    string
  Default: "opencode/big-pickle"
  Config:  ConfigManager.modelOpus

modelSonnet
  Type:    string
  Default: "opencode/big-pickle-reasoning"
  Config:  ConfigManager.modelSonnet

modelHaiku
  Type:    string
  Default: "opencode/big-pickle-turbo"
  Config:  ConfigManager.modelHaiku

enableThinking
  Type:    bool
  Default: true
  Config:  ConfigManager.enableThinking

fallbackProviders
  Type:    string (comma-separated provider IDs)
  Default: "nvidia,local"
  Config:  ConfigManager.fallbackProviders

openaiBaseUrl
  Type:    string (URL)
  Default: "https://api.openai.com/v1"
  Config:  ConfigManager.openaiBaseUrl

localLlmBaseUrl
  Type:    string (URL)
  Default: "http://127.0.0.1:11434/v1"
  Config:  ConfigManager.localLlmBaseUrl

localLlmModel
  Type:    string
  Default: "ollama/qwen3:latest"
  Config:  ConfigManager.localLlmModel

authToken
  Type:    string
  Default: "jxproxy"
  Config:  ConfigManager.authToken

appRoutesJSON
  Type:    string (JSON array of AppRouteRule)
  Default: ""
  Config:  ConfigManager.appRoutesJSON

hasMigratedFromConfigEnv
  Type:    bool
  Default: false
  Config:  ConfigManager.hasMigrated
  Note:    Set to true once legacy ~/.jxproxy/config.env is migrated

enabledProviders
  Type:    string (comma-separated provider IDs)
  Default: ""
  Config:  ConfigManager.enabledProviders

visibleModels
  Type:    string (semicolon-separated provider=models)
  Default: ""
  Config:  ConfigManager.visibleModelsRaw

providerBackendUrls
  Type:    string (JSON dict: {provider_id: url, ...})
  Default: "{}"
  Config:  ConfigManager.providerBackendUrls

mitmHosts
  Type:    string (comma-separated hostnames)
  Default: "api.anthropic.com"
  Config:  ConfigManager.mitmHosts

dnsRedirectEnabled
  Type:    bool
  Default: true
  Config:  ConfigManager.dnsRedirectEnabled

botIntegrationEnabled
  Type:    bool
  Default: false
  Config:  ConfigManager.botIntegrationEnabled

apiKeysDict
  Type:    string (JSON dict — UserDefaults fallback for API keys)
  Default: "{}"
  Config:  ConfigManager.loadApiKeysDict()
  Note:    Used only when Keychain is unavailable (macOS). Treated as
           secondary storage — keys are migrated to Keychain on read.

autoStartProxy
  Type:    bool
  Default: false
  Config:  JXRouterApp.swift (app delegate)
  Note:    Whether to auto-start proxy on app launch

# ──────────────────────────────────────────────────────────────────────────────
# SECTION 5: Android Config File Keys (Python — ~/.config/jxproxy/config.json)
# ──────────────────────────────────────────────────────────────────────────────
# The Android/Termux port stores configuration in a JSON file instead of
# UserDefaults. Keys match the macOS equivalents but use underscore_case.

File: ~/.config/jxproxy/config.json
  Type:   JSON object
  Mode:   0700 (directory), 0600 (file)
  Reader: jxproxy.py ConfigManager._load()
  Writer: jxproxy.py ConfigManager._save()

{
  "port":                 5255,
  "provider":             "opencode-zen",
  "model":                "big-pickle",
  "model_opus":           "opencode/big-pickle",
  "model_sonnet":         "opencode/big-pickle-reasoning",
  "model_haiku":          "opencode/big-pickle-turbo",
  "enable_thinking":      true,
  "fallback_providers":   ["nvidia-nim", "ollama"],
  "auth_token":           "jxproxy",
  "dns_redirect_enabled": false,
  "backend_urls":         {},
  "mitm_hosts":           ["api.anthropic.com"],
  "local_llm_base_url":   "http://127.0.0.1:11434/v1",
  "local_llm_model":      "ollama/qwen3:latest"
}

File: ~/.config/jxproxy/api_keys.json
  Type:   JSON object {provider_id: api_key, ...}
  Mode:   0600
  Reader: jxproxy.py ConfigManager._load()
  Writer: jxproxy.py ConfigManager._save_api_keys()
  Note:   Provider IDs match SECTION 2. Environment variables take
          precedence over this file at runtime.

# ──────────────────────────────────────────────────────────────────────────────
# SECTION 6: Legacy ~/.jxproxy/config.env Migration Keys
# ──────────────────────────────────────────────────────────────────────────────
# The macOS app auto-migrates from this file on first launch. These keys
# are parsed by ConfigManager.parseEnv() and migrated to Keychain + UserDefaults.

File: ~/.jxproxy/config.env
  Format: KEY=VALUE lines (shell-parseable)

JXPROXY_PORT
JXPROXY_PROVIDER
JXPROXY_AUTH_TOKEN
MODEL
MODEL_OPUS
MODEL_SONNET
MODEL_HAIKU
ENABLE_MODEL_THINKING
FALLBACK_PROVIDERS
OPENAI_BASE_URL
LOCAL_LLM_BASE_URL
LOCAL_LLM_MODEL
ENABLED_PROVIDERS
VISIBLE_MODELS

# API keys in legacy config.env (all migrated to macOS Keychain):
ANTHROPIC_API_KEY
OPENAI_API_KEY
OPENROUTER_API_KEY
OPENCODE_API_KEY
NVIDIA_NIM_API_KEY
DEEPSEEK_API_KEY
GEMINI_API_KEY
MISTRAL_API_KEY
CODESTRAL_API_KEY
COHERE_API_KEY
GROQ_API_KEY
FIREWORKS_API_KEY
SAMBANOVA_API_KEY
CEREBRAS_API_KEY
HUGGINGFACE_API_KEY
GITHUB_MODELS_TOKEN
WAFER_API_KEY
KIMI_API_KEY
KIMI_CODE_API_KEY
MINIMAX_API_KEY
XAI_API_KEY
CLOUDFLARE_API_TOKEN
ZAI_API_KEY
OLLAMA_API_KEY
AI_GATEWAY_API_KEY

# macOS Keychain service names for the migrated keys:
# Service: "com.jxproxy"
# Account: <chainKey> (e.g. "ANTHROPIC_API_KEY", "OPENAI_API_KEY")
# Ref:     ConfigManager.KeychainKey.* constants

# ──────────────────────────────────────────────────────────────────────────────
# SECTION 7: File Paths
# ──────────────────────────────────────────────────────────────────────────────

# macOS App Bundle
/Applications/JXRouter.app
  Type:    macOS .app bundle
  Creator: install.sh → xcodebuild → cp -R

~/Desktop/JXProxy.app
  Type:   Symlink to /Applications/JXRouter.app
  Maker:  install.sh

# macOS CLI Launchers (install.sh writes these)
~/.local/bin/jxserver
~/.local/bin/jxclaude
~/.local/bin/jxcodex
~/.local/bin/jxpi

# Android/Termux CLI Launchers (install-termux.sh writes these)
~/.local/bin/jxproxy      # Python wrapper (shell)
~/.local/bin/jxproxy.py   # Python implementation
~/.local/bin/jxserver
~/.local/bin/jxclaude
~/.local/bin/jxcodex
~/.local/bin/jxpi

# Android/Termux Config
~/.config/jxproxy/config.json
~/.config/jxproxy/api_keys.json
~/.config/jxproxy/providers.json
~/.config/jxproxy/proxy.log
~/.config/jxproxy/certs/          (directory)

# Termux:Boot Auto-Start
~/.termux/boot/jxproxy

# Android PID File
/data/data/com.termux/files/usr/tmp/jxproxy.pid

# macOS Legacy Config (migrated on first launch of Swift app)
~/.jxproxy/config.env

# macOS Build Artifacts
/tmp/JXRouterBuild/
Build/
DerivedData/

# macOS Application Support (CA certs, host certs)
~/Library/Application Support/JXProxy/

# macOS Logs
~/Library/Logs/jxproxy-error.log

# macOS Stale State Cleanup
/tmp/jxproxy-hosts.tmp
/tmp/jxproxy-pf.conf
/tmp/jxproxy-hosts-clean.tmp
~/.jxproxy_bot_commands
~/.jxproxy/

# ──────────────────────────────────────────────────────────────────────────────
# SECTION 8: Default Values Quick Reference
# ──────────────────────────────────────────────────────────────────────────────
# All defaults in one place for quick lookup.

Setting                    macOS Default              Android Default
─────────────────────────────────────────────────────────────────────────
Proxy Port                 5255                       5255
Auth Token                 jxproxy                    jxproxy
Primary Provider           opencode-zen               opencode-zen
Default Model              big-pickle                 big-pickle
Model Opus                 opencode/big-pickle        opencode/big-pickle
Model Sonnet               opencode/big-pickle-reasoning  opencode/big-pickle-reasoning
Model Haiku                opencode/big-pickle-turbo  opencode/big-pickle-turbo
Enable Thinking            true                       true
Fallback Providers         nvidia,local               nvidia-nim,ollama
Local LLM Base URL         http://127.0.0.1:11434/v1  http://127.0.0.1:11434/v1
Local LLM Model            ollama/qwen3:latest        ollama/qwen3:latest
DNS Redirect Enabled       true                       false
MITM Hosts                 api.anthropic.com           api.anthropic.com
OpenAI Base URL override   https://api.openai.com/v1  (N/A — uses provider presets)
Bot Integration Enabled    false                      false
Auto-Start Proxy           false                      false

# ──────────────────────────────────────────────────────────────────────────────
# SECTION 9: macOS Keychain Services
# ──────────────────────────────────────────────────────────────────────────────

Service: com.jxproxy
Accounts:
  OPENAI_API_KEY
  OPENROUTER_API_KEY
  OPENCODE_API_KEY
  ANTHROPIC_API_KEY
  NVIDIA_NIM_API_KEY
  DEEPSEEK_API_KEY
  GEMINI_API_KEY
  MISTRAL_API_KEY
  CODESTRAL_API_KEY
  COHERE_API_KEY
  GROQ_API_KEY
  FIREWORKS_API_KEY
  SAMBANOVA_API_KEY
  CEREBRAS_API_KEY
  HUGGINGFACE_API_KEY
  GITHUB_MODELS_TOKEN
  WAFER_API_KEY
  KIMI_API_KEY
  KIMI_CODE_API_KEY
  MINIMAX_API_KEY
  XAI_API_KEY
  CLOUDFLARE_API_TOKEN
  ZAI_API_KEY
  OLLAMA_API_KEY
  AI_GATEWAY_API_KEY
  TELEGRAM_BOT_TOKEN
  ADMIN_PASSWORD

Query example:
  security find-generic-password -s "com.jxproxy" -a "ANTHROPIC_API_KEY"

Delete example:
  security delete-generic-password -s "com.jxproxy" -a "ANTHROPIC_API_KEY"

Service: com.jxrouter (legacy — cleaned during migration)

# ──────────────────────────────────────────────────────────────────────────────
# END OF ENVIRONMENT REFERENCE
# ──────────────────────────────────────────────────────────────────────────────
