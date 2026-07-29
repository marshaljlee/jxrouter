#!/usr/bin/env python3
"""
JXProxy for Android/Termux — v1.0.0
Reverse-engineered port of the macOS JXRouter/JXProxy.

Local HTTP proxy that:
  1. Intercepts Anthropic Messages API calls from any AI client
  2. Translates Anthropic → OpenAI Chat Completions format
  3. Routes through a configurable provider chain
  4. Translates OpenAI → Anthropic format on response
  5. Supports streaming SSE, fallback providers, DNS-level interception

Usage:
  jxproxy --help
  jxproxy start [--port PORT] [--daemon]
  jxproxy stop
  jxproxy status
  jxproxy config set KEY=VALUE
  jxproxy config show
  jxproxy providers list
"""

from __future__ import annotations

import argparse
import atexit
import json
import os
import re
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum, auto
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from typing import Any, Callable, Optional
from urllib.parse import urlparse

# ─── Version ─────────────────────────────────────────────────────────────────
VERSION = "1.0.0"
APP_NAME = "jxproxy"

# ─── Paths ───────────────────────────────────────────────────────────────────
CONFIG_DIR = Path.home() / ".config" / APP_NAME
CONFIG_FILE = CONFIG_DIR / "config.json"
PROVIDER_FILE = CONFIG_DIR / "providers.json"
API_KEYS_FILE = CONFIG_DIR / "api_keys.json"
PID_FILE = Path(f"/data/data/com.termux/files/usr/tmp/{APP_NAME}.pid")
CERT_DIR = CONFIG_DIR / "certs"
LOG_FILE = CONFIG_DIR / "proxy.log"

# ─── Defaults ────────────────────────────────────────────────────────────────
DEFAULT_PORT = 5255
DEFAULT_AUTH_TOKEN = "jxproxy"
DEFAULT_PROVIDER = "opencode-zen"
REQUEST_TIMEOUT = 90  # Total request timeout (seconds)
UPSTREAM_TIMEOUT = 30  # Upstream provider timeout (seconds)
MAX_FALLBACK_DURATION = 120  # Max total fallback chain (seconds)

# ─── ANSI Colors ─────────────────────────────────────────────────────────────
class Color:
    GREEN = "\033[92m"
    YELLOW = "\033[93m"
    RED = "\033[91m"
    CYAN = "\033[96m"
    BOLD = "\033[1m"
    RESET = "\033[0m"
    GRAY = "\033[90m"


# ═══════════════════════════════════════════════════════════════════════════════
# Core Data Models
# ═══════════════════════════════════════════════════════════════════════════════

class RouteAction(str, Enum):
    ROUTE_AI = "routeAI"
    PASSTHROUGH = "passthrough"
    BLOCK = "block"


@dataclass
class ProviderPreset:
    pid: str
    name: str
    default_url: str
    models: list[str] = field(default_factory=list)
    requires_key: bool = True

    @staticmethod
    def all() -> list["ProviderPreset"]:
        return [
            ProviderPreset("opencode-zen", "OpenCode Zen",
                           "https://opencode.ai/zen/v1",
                           ["big-pickle", "nemotron-3-super-free", "mimo-v2.5-free",
                            "mimo-v2-pro-free", "minimax-m2.5-free", "gpt-5-nano",
                            "laguna-s-2.1-free", "ling-3.0-flash-free", "north-mini-code-free"],
                           requires_key=False),
            ProviderPreset("opencode-go", "OpenCode Go",
                           "https://oai.opencode.ai/v1",
                           ["opencode/big-pickle", "opencode/big-pickle-reasoning"],
                           requires_key=False),
            ProviderPreset("direct", "Anthropic Direct",
                           "https://api.anthropic.com",
                           ["claude-opus-4-5", "claude-sonnet-4-6", "claude-haiku-3-5"],
                           requires_key=True),
            ProviderPreset("openrouter", "OpenRouter",
                           "https://openrouter.ai/api/v1",
                           ["openrouter/auto", "anthropic/claude-opus-4.5", "openai/gpt-4o"],
                           requires_key=True),
            ProviderPreset("openai", "OpenAI / Codex",
                           "https://api.openai.com/v1",
                           ["gpt-4o", "gpt-4o-mini", "o3"],
                           requires_key=True),
            ProviderPreset("nvidia-nim", "NVIDIA NIM",
                           "https://integrate.api.nvidia.com/v1",
                           ["nvidia/nemotron-3-super", "nvidia/minimax-m3"],
                           requires_key=True),
            ProviderPreset("deepseek", "DeepSeek",
                           "https://api.deepseek.com/v1",
                           ["deepseek/deepseek-chat", "deepseek/deepseek-reasoner"],
                           requires_key=True),
            ProviderPreset("gemini", "Google Gemini",
                           "https://generativelanguage.googleapis.com/v1beta",
                           ["gemini/gemini-3.5-flash", "gemini/gemini-3.5-pro"],
                           requires_key=True),
            ProviderPreset("mistral", "Mistral",
                           "https://api.mistral.ai/v1",
                           ["mistral/mistral-large-latest"],
                           requires_key=True),
            ProviderPreset("groq", "Groq",
                           "https://api.groq.com/openai/v1",
                           ["groq/llama-3.3-70b-versatile"],
                           requires_key=True),
            ProviderPreset("fireworks", "Fireworks AI",
                           "https://api.fireworks.ai/inference/v1",
                           ["fireworks/llama-v3p3-70b-instruct"],
                           requires_key=True),
            ProviderPreset("xai", "xAI Grok",
                           "https://api.x.ai/v1",
                           ["grok-3", "grok-3-mini", "grok-3-reasoner"],
                           requires_key=True),
            ProviderPreset("cohere", "Cohere",
                           "https://api.cohere.ai/v1",
                           ["cohere/command-a-plus-05-2026"],
                           requires_key=True),
            ProviderPreset("huggingface", "HuggingFace",
                           "https://router.huggingface.co/v1",
                           ["huggingface/Qwen3-Coder-480B-A35B"],
                           requires_key=True),
            ProviderPreset("github-models", "GitHub Models",
                           "https://models.inference.ai.azure.com/v1",
                           ["github_models/openai/gpt-4.1"],
                           requires_key=True),
            ProviderPreset("ollama", "Ollama (Local)",
                           "http://127.0.0.1:11434/v1",
                           ["qwen3:latest", "llama3.2:latest"],
                           requires_key=False),
            ProviderPreset("lmstudio", "LM Studio (Local)",
                           "http://127.0.0.1:1234/v1",
                           ["lmstudio/<model-id>"],
                           requires_key=False),
            ProviderPreset("llamacpp", "llama.cpp (Local)",
                           "http://127.0.0.1:8080/v1",
                           [],
                           requires_key=False),
        ]

    @staticmethod
    def by_id(pid: str) -> Optional["ProviderPreset"]:
        for p in ProviderPreset.all():
            if p.pid == pid:
                return p
        return None


class AIHostClassifier:
    """Classify hostnames as AI API endpoints for routing."""

    PATTERNS = {
        "api.anthropic.com", "api.openai.com", "api.openrouter.ai",
        "opencode.ai", "oai.opencode.ai", "zen.opencode.ai",
        "integrate.api.nvidia.com", "api.groq.com", "api.cohere.ai",
        "api.mistral.ai", "codestral.mistral.ai", "api.deepseek.com",
        "api.perplexity.ai", "api.together.xyz", "api.fireworks.ai",
        "api.replicate.com", "inference.ai.azure.com",
        "router.huggingface.co", "generativelanguage.googleapis.com",
        "api.x.ai", "api.sambanova.ai", "api.cerebras.ai",
        "models.inference.ai.azure.com", "api.wafer.ch",
        "api.moonshot.cn", "api.kimi-coding.com", "api.minimax.chat",
        "api.z.ai", "gateway.ai.vercel.ai", "ollama.com",
        "api.cloudflare.com",
    }

    SUFFIXES = {
        ".anthropic.com", ".openai.com", ".openrouter.ai",
        ".opencode.ai", ".nvidia.com", ".groq.com", ".cohere.ai",
        ".mistral.ai", ".deepseek.com", ".perplexity.ai",
        ".together.xyz", ".fireworks.ai", ".azure.com",
        ".huggingface.co", ".googleapis.com", ".x.ai",
        ".cerebras.ai", ".sambanova.ai", ".replicate.com",
        ".wafer.ch", ".moonshot.cn", ".kimi-coding.com",
        ".minimax.chat", ".z.ai", ".vercel.ai", ".ollama.com",
        ".cloudflare.com",
    }

    @classmethod
    def classify(cls, host: str) -> RouteAction:
        lower = host.lower().strip()
        if lower in cls.PATTERNS:
            return RouteAction.ROUTE_AI
        for suffix in cls.SUFFIXES:
            if lower.endswith(suffix):
                return RouteAction.ROUTE_AI
        if lower in ("localhost", "127.0.0.1", "0.0.0.0") or lower.startswith("127."):
            return RouteAction.PASSTHROUGH
        return RouteAction.PASSTHROUGH

    @classmethod
    def is_ai_host(cls, host: str) -> bool:
        return cls.classify(host) == RouteAction.ROUTE_AI


# ═══════════════════════════════════════════════════════════════════════════════
# Configuration Manager
# ═══════════════════════════════════════════════════════════════════════════════

class ConfigManager:
    """JSON-file-based configuration (replaces macOS UserDefaults+Keychain)."""

    _instance: Optional["ConfigManager"] = None

    def __init__(self):
        self._dirty = False
        self._lock = threading.Lock()
        self._config: dict[str, Any] = {}
        self._api_keys: dict[str, str] = {}
        self._load()

    @classmethod
    def instance(cls) -> "ConfigManager":
        if cls._instance is None:
            cls._instance = ConfigManager()
        return cls._instance

    # ── Getters ──────────────────────────────────────────────────────────

    @property
    def port(self) -> int:
        return int(self._config.get("port", DEFAULT_PORT))

    @port.setter
    def port(self, val: int):
        self._config["port"] = val
        self._save()

    @property
    def provider(self) -> str:
        return self._config.get("provider", DEFAULT_PROVIDER)

    @provider.setter
    def provider(self, val: str):
        self._config["provider"] = val
        self._save()

    @property
    def model(self) -> str:
        return self._config.get("model", "big-pickle")

    @model.setter
    def model(self, val: str):
        self._config["model"] = val
        self._save()

    @property
    def model_opus(self) -> str:
        return self._config.get("model_opus", "opencode/big-pickle")

    @model_opus.setter
    def model_opus(self, val: str):
        self._config["model_opus"] = val
        self._save()

    @property
    def model_sonnet(self) -> str:
        return self._config.get("model_sonnet", "opencode/big-pickle-reasoning")

    @model_sonnet.setter
    def model_sonnet(self, val: str):
        self._config["model_sonnet"] = val
        self._save()

    @property
    def model_haiku(self) -> str:
        return self._config.get("model_haiku", "opencode/big-pickle-turbo")

    @model_haiku.setter
    def model_haiku(self, val: str):
        self._config["model_haiku"] = val
        self._save()

    @property
    def fallback_providers(self) -> list[str]:
        raw = self._config.get("fallback_providers", "nvidia-nim,ollama")
        if isinstance(raw, str):
            return [p.strip() for p in raw.split(",") if p.strip()]
        return raw if isinstance(raw, list) else []

    @fallback_providers.setter
    def fallback_providers(self, val: list[str] | str):
        if isinstance(val, str):
            val = [p.strip() for p in val.split(",") if p.strip()]
        self._config["fallback_providers"] = val
        self._save()

    @property
    def auth_token(self) -> str:
        return self._config.get("auth_token", DEFAULT_AUTH_TOKEN)

    @auth_token.setter
    def auth_token(self, val: str):
        self._config["auth_token"] = val
        self._save()

    @property
    def enable_thinking(self) -> bool:
        return self._config.get("enable_thinking", True)

    @enable_thinking.setter
    def enable_thinking(self, val: bool):
        self._config["enable_thinking"] = val
        self._save()

    @property
    def dns_redirect_enabled(self) -> bool:
        return self._config.get("dns_redirect_enabled", False)

    @dns_redirect_enabled.setter
    def dns_redirect_enabled(self, val: bool):
        self._config["dns_redirect_enabled"] = val
        self._save()

    @property
    def backend_urls(self) -> dict[str, str]:
        return self._config.get("backend_urls", {})

    @backend_urls.setter
    def backend_urls(self, val: dict[str, str]):
        self._config["backend_urls"] = val
        self._save()

    @property
    def mitm_hosts(self) -> set[str]:
        raw = self._config.get("mitm_hosts", "api.anthropic.com")
        if isinstance(raw, str):
            return {h.strip() for h in raw.split(",") if h.strip()}
        return set(raw) if isinstance(raw, list) else {raw}

    @mitm_hosts.setter
    def mitm_hosts(self, val: set[str] | str):
        if isinstance(val, str):
            val = {h.strip() for h in val.split(",") if h.strip()}
        self._config["mitm_hosts"] = list(val)
        self._save()

    @property
    def local_llm_base_url(self) -> str:
        return self._config.get("local_llm_base_url", "http://127.0.0.1:11434/v1")

    @local_llm_base_url.setter
    def local_llm_base_url(self, val: str):
        self._config["local_llm_base_url"] = val
        self._save()

    @property
    def local_llm_model(self) -> str:
        return self._config.get("local_llm_model", "ollama/qwen3:latest")

    @local_llm_model.setter
    def local_llm_model(self, val: str):
        self._config["local_llm_model"] = val
        self._save()

    @property
    def chat_template(self) -> str:
        """Override chat template for local GGUF models that have a broken
        baked-in template (e.g. raise_exception block). If empty, uses the
        model's built-in template."""
        val = self._config.get("chat_template", "")
        if val and val.startswith("$"):
            # Expand $ENV_VAR references
            return os.environ.get(val[1:], "")
        return val

    @chat_template.setter
    def chat_template(self, val: str):
        self._config["chat_template"] = val
        self._save()

    # ── API Key Access ───────────────────────────────────────────────────

    def get_api_key(self, provider_id: str) -> str:
        """Return the API key for a provider. Checks env vars first, then file."""
        env_map = {
            "direct": "ANTHROPIC_API_KEY",
            "openai": "OPENAI_API_KEY",
            "openrouter": "OPENROUTER_API_KEY",
            "opencode-zen": "OPENCODE_API_KEY",
            "opencode-go": "OPENCODE_API_KEY",
            "nvidia-nim": "NVIDIA_NIM_API_KEY",
            "deepseek": "DEEPSEEK_API_KEY",
            "gemini": "GEMINI_API_KEY",
            "mistral": "MISTRAL_API_KEY",
            "groq": "GROQ_API_KEY",
            "fireworks": "FIREWORKS_API_KEY",
            "xai": "XAI_API_KEY",
            "cohere": "COHERE_API_KEY",
            "huggingface": "HUGGINGFACE_API_KEY",
            "github-models": "GITHUB_MODELS_TOKEN",
        }
        env_key = env_map.get(provider_id)
        if env_key:
            val = os.environ.get(env_key, "")
            if val:
                return val
        with self._lock:
            return self._api_keys.get(provider_id, "")

    def set_api_key(self, provider_id: str, value: str):
        with self._lock:
            if value:
                self._api_keys[provider_id] = value
            else:
                self._api_keys.pop(provider_id, None)
            self._save_api_keys()

    # ── Resolved Provider Helpers ────────────────────────────────────────

    def base_url_for(self, provider_id: str) -> str:
        """Get the base URL for a provider, checking custom overrides first."""
        overrides = self.backend_urls
        if provider_id in overrides and overrides[provider_id]:
            return overrides[provider_id]

        preset = ProviderPreset.by_id(provider_id)
        if provider_id == "local":
            return self.local_llm_base_url
        if provider_id == "ollama":
            return self.local_llm_base_url
        if provider_id == "lmstudio":
            return "http://127.0.0.1:1234/v1"
        if provider_id == "llamacpp":
            return "http://127.0.0.1:8080/v1"
        if preset:
            return preset.default_url
        return ""

    def get_provider_chain(self) -> list[str]:
        """Return [primary] + fallback providers."""
        chain = [self.provider]
        for fb in self.fallback_providers:
            if fb not in chain:
                chain.append(fb)
        return chain

    # ── Persistence ──────────────────────────────────────────────────────

    def _load(self):
        CONFIG_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
        if CONFIG_FILE.exists():
            try:
                with open(CONFIG_FILE, "r") as f:
                    self._config = json.load(f)
            except (json.JSONDecodeError, OSError):
                self._config = {}
        else:
            self._config = {}
            self._save()

        if API_KEYS_FILE.exists():
            try:
                with open(API_KEYS_FILE, "r") as f:
                    self._api_keys = json.load(f)
            except (json.JSONDecodeError, OSError):
                self._api_keys = {}

    def _save(self):
        CONFIG_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
        with open(CONFIG_FILE, "w") as f:
            json.dump(self._config, f, indent=2, sort_keys=True)

    def _save_api_keys(self):
        CONFIG_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
        with open(API_KEYS_FILE, "w") as f:
            json.dump(self._api_keys, f, indent=2)
        os.chmod(API_KEYS_FILE, 0o600)

    def show(self) -> str:
        """Return a human-readable config dump."""
        lines = [
            f"{Color.BOLD}JXProxy Configuration:{Color.RESET}",
            f"  Port:              {self.port}",
            f"  Provider:          {self.provider}",
            f"  Model (default):   {self.model}",
            f"  Model (opus):      {self.model_opus}",
            f"  Model (sonnet):    {self.model_sonnet}",
            f"  Model (haiku):     {self.model_haiku}",
            f"  Fallback:          {', '.join(self.fallback_providers)}",
            f"  Auth token:        {'✓ set' if self.auth_token else '✗ empty'}",
            f"  Thinking:          {'on' if self.enable_thinking else 'off'}",
            f"  DNS redirect:      {'on' if self.dns_redirect_enabled else 'off'}",
            f"  Local LLM URL:     {self.local_llm_base_url}",
            f"  Local LLM model:   {self.local_llm_model}",
            f"  MITM hosts:        {', '.join(self.mitm_hosts)}",
            f"",
            f"{Color.BOLD}Configured API keys:{Color.RESET}",
        ]
        for pid in sorted(self._api_keys.keys()):
            val = self._api_keys[pid]
            masked = val[:8] + "…" + val[-4:] if len(val) > 16 else "****"
            lines.append(f"  {pid}: {masked}")
        # Also check env vars
        env_keys = ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "OPENROUTER_API_KEY",
                     "OPENCODE_API_KEY", "GEMINI_API_KEY", "DEEPSEEK_API_KEY"]
        for ek in env_keys:
            if os.environ.get(ek, ""):
                lines.append(f"  [{ek}]: (from environment)")
        return "\n".join(lines)


# ═══════════════════════════════════════════════════════════════════════════════
# Message Translation (Anthropic ↔ OpenAI)
# ═══════════════════════════════════════════════════════════════════════════════

class MessageTranslator:
    """Translate between Anthropic Messages API and OpenAI Chat Completions."""

    @staticmethod
    def to_openai(request_body: dict, model: str) -> dict:
        """Convert an Anthropic Messages API request to OpenAI Chat Completions."""
        messages: list[dict] = []
        for msg in request_body.get("messages", []):
            role = msg.get("role", "user")
            content = msg.get("content", "")

            if isinstance(content, str):
                messages.append({"role": role, "content": content})
            elif isinstance(content, list):
                parts = []
                for block in content:
                    btype = block.get("type", "")
                    if btype == "text":
                        parts.append({"type": "text", "text": block.get("text", "")})
                    elif btype == "image":
                        src = block.get("source", {})
                        if src.get("type") == "base64":
                            parts.append({
                                "type": "image_url",
                                "image_url": {
                                    "url": f"data:{src.get('media_type', 'image/png')};base64,{src.get('data', '')}"
                                }
                            })
                messages.append({"role": role, "content": parts})

        # System prompt
        system = request_body.get("system", "")
        if isinstance(system, list):
            system = "".join(b.get("text", "") for b in system if b.get("type") == "text")
        if system:
            messages.insert(0, {"role": "system", "content": system})

        body: dict[str, Any] = {
            "model": model,
            "messages": messages,
            "max_tokens": request_body.get("max_tokens", 4096),
            "stream": request_body.get("stream", False),
            "temperature": request_body.get("temperature", 0.7),
        }

        stop = request_body.get("stop_sequences")
        if stop:
            body["stop"] = stop

        tools = request_body.get("tools", [])
        if tools:
            body["tools"] = [
                {
                    "type": "function",
                    "function": {
                        "name": t.get("name", ""),
                        "description": t.get("description", ""),
                        "parameters": t.get("input_schema", {}),
                    },
                }
                for t in tools
            ]
            tc = request_body.get("tool_choice", {})
            if isinstance(tc, dict):
                tc_type = tc.get("type", "auto")
                if tc_type == "any":
                    body["tool_choice"] = "required"
                elif tc_type == "tool":
                    body["tool_choice"] = {"type": "function", "function": {"name": tc.get("name", "")}}
                else:
                    body["tool_choice"] = "auto"

        thinking = request_body.get("thinking", {})
        if isinstance(thinking, dict) and thinking.get("type") == "enabled":
            body["reasoning_effort"] = "high"

        return body

    @staticmethod
    def openai_to_anthropic_sse(chunk: dict, model: str) -> list[str]:
        """Convert one OpenAI stream chunk to multiple Anthropic SSE event strings."""
        events: list[str] = []
        choices = chunk.get("choices", [])
        for choice in choices:
            delta = choice.get("delta", {})
            idx = choice.get("index", 0)

            if delta.get("role") == "assistant":
                events.extend(SSEFormatter.assistant_message_start(model))

            content = delta.get("content", "")
            if content:
                events.append(SSEFormatter.text_delta(content))

            reasoning = delta.get("reasoning_content", "")
            if reasoning:
                events.append(SSEFormatter.text_delta(reasoning))

            tool_calls = delta.get("tool_calls", [])
            for tc in tool_calls:
                tcidx = tc.get("index", 0)
                fn = tc.get("function", {})
                name = fn.get("name", "")
                if name:
                    events.append(SSEFormatter.tool_use_start(tcidx, f"{name}_{tcidx}", name))
                args = fn.get("arguments", "")
                if args:
                    events.append(SSEFormatter.tool_use_delta(tcidx, args))

            finish = choice.get("finish_reason", "")
            if finish:
                stop_reason = {"tool_calls": "tool_use", "length": "max_tokens"}.get(finish, "end_turn")
                usage = chunk.get("usage", {})
                out_tokens = usage.get("completion_tokens", 0)
                events.extend(SSEFormatter.message_stop(idx, stop_reason, out_tokens))

        return events

    @staticmethod
    def openai_to_anthropic_nonstream(data: dict, model: str) -> dict:
        """Convert a non-streaming OpenAI response to Anthropic format."""
        choices = data.get("choices", [{}])
        choice = choices[0].get("message", {})
        content = choice.get("content", "")
        reasoning = choice.get("reasoning_content", "")
        if not content and reasoning:
            content = reasoning
        finish = choice.get("finish_reason", "")
        usage = data.get("usage", {})

        stop_reason = {"tool_calls": "tool_use", "length": "max_tokens"}.get(finish, "end_turn")

        content_blocks: list[dict] = []
        if content:
            content_blocks.append({"type": "text", "text": content})

        tool_calls = choice.get("tool_calls", [])
        for tc in tool_calls:
            fn = tc.get("function", {})
            name = fn.get("name", "")
            args_raw = fn.get("arguments", "{}")
            try:
                args = json.loads(args_raw)
            except json.JSONDecodeError:
                args = {"raw_arguments": args_raw}
            content_blocks.append({
                "type": "tool_use",
                "id": f"{name}_{int(time.time())}",
                "name": name,
                "input": args,
            })

        return {
            "id": f"msg_{int(time.time())}",
            "type": "message",
            "role": "assistant",
            "content": content_blocks,
            "model": model,
            "stop_reason": stop_reason,
            "stop_sequence": None,
            "usage": {
                "input_tokens": usage.get("prompt_tokens", 0),
                "output_tokens": usage.get("completion_tokens", 0),
            },
        }


class SSEFormatter:
    """Server-Sent Events formatting for Anthropic Messages API streams."""

    @staticmethod
    def format(event: str, data: str) -> str:
        return f"event: {event}\ndata: {data}\n\n"

    @staticmethod
    def text_delta(text: str) -> str:
        escaped = json.dumps(text)
        return SSEFormatter.format("content_block_delta",
            json.dumps({"type": "content_block_delta", "index": 0,
                        "delta": {"type": "text_delta", "text": text}}))

    @staticmethod
    def assistant_message_start(model: str) -> list[str]:
        msg_id = f"msg_{uuid_short()}"
        return [
            SSEFormatter.format("message_start",
                json.dumps({"type": "message_start",
                            "message": {"id": msg_id, "type": "message", "role": "assistant",
                                        "model": model, "content": [],
                                        "usage": {"input_tokens": 0, "output_tokens": 0}}})),
            SSEFormatter.format("content_block_start",
                json.dumps({"type": "content_block_start", "index": 0,
                            "content_block": {"type": "text", "text": ""}})),
        ]

    @staticmethod
    def tool_use_start(index: int, tid: str, name: str) -> str:
        return SSEFormatter.format("content_block_start",
            json.dumps({"type": "content_block_start", "index": index,
                        "content_block": {"type": "tool_use", "id": tid,
                                          "name": name, "input": {}}}))

    @staticmethod
    def tool_use_delta(index: int, args: str) -> str:
        return SSEFormatter.format("content_block_delta",
            json.dumps({"type": "content_block_delta", "index": index,
                        "delta": {"type": "input_json_delta", "partial_json": args}}))

    @staticmethod
    def message_stop(index: int, stop_reason: str, output_tokens: int) -> list[str]:
        return [
            SSEFormatter.format("content_block_stop",
                json.dumps({"type": "content_block_stop", "index": index})),
            SSEFormatter.format("message_delta",
                json.dumps({"type": "message_delta",
                            "delta": {"stop_reason": stop_reason, "stop_sequence": None},
                            "usage": {"output_tokens": output_tokens}})),
        ]


def uuid_short() -> str:
    """Short 8-char hex ID."""
    return f"{int(time.time() * 1000000) % 0x100000000:08x}"


# ═══════════════════════════════════════════════════════════════════════════════
# DNS Resolution
# ═══════════════════════════════════════════════════════════════════════════════

class DirectDNSResolver:
    """Resolve hostnames via Cloudflare DoH, fallback to system resolver."""

    _cache: dict[str, str] = {}

    @classmethod
    def resolve(cls, hostname: str) -> str | None:
        if hostname in cls._cache:
            return cls._cache[hostname]

        if hostname in ("127.0.0.1", "localhost", "0.0.0.0"):
            cls._cache[hostname] = hostname
            return hostname

        # Check if already an IP
        if re.match(r'^\d+\.\d+\.\d+\.\d+$', hostname):
            cls._cache[hostname] = hostname
            return hostname

        # Try DoH
        ip = cls._resolve_doh(hostname)
        if ip:
            cls._cache[hostname] = ip
            return ip

        # Fallback: system resolver via socket
        try:
            ip = socket.gethostbyname(hostname)
            cls._cache[hostname] = ip
            return ip
        except (socket.gaierror, OSError):
            return None

    @classmethod
    def _resolve_doh(cls, hostname: str) -> str | None:
        try:
            url = f"https://cloudflare-dns.com/dns-query?name={hostname}&type=A"
            req = urllib.request.Request(url, headers={"Accept": "application/dns-json"})
            with urllib.request.urlopen(req, timeout=5) as resp:
                data = json.loads(resp.read())
                answers = data.get("Answer", [])
                for a in answers:
                    if a.get("type") == 1:  # A record
                        return a.get("data")
        except Exception:
            pass
        return None


# ═══════════════════════════════════════════════════════════════════════════════
# Upstream Provider Router
# ═══════════════════════════════════════════════════════════════════════════════

class ProviderRouter:
    """Routes Anthropic Messages API calls through the configured provider chain."""

    def __init__(self, config: ConfigManager):
        self.config = config
        self.last_latency_ms: float = 0.0

    def resolve_model(self, incoming_model: str, provider_id: str | None = None) -> str:
        """Resolve incoming Anthropic model name to the actual upstream model."""
        local_providers = {"llamacpp", "lmstudio", "local", "ollama"}
        if provider_id in local_providers:
            return self.config.model

        if "/" in incoming_model:
            return incoming_model

        lower = incoming_model.lower()
        # Pass through well-known names
        for prefix in ("claude-", "gpt-", "gemini-", "grok-"):
            if lower.startswith(prefix):
                return incoming_model

        # Tier mapping
        if lower == "opus" and self.config.model_opus:
            return self.config.model_opus
        if lower == "sonnet" and self.config.model_sonnet:
            return self.config.model_sonnet
        if lower == "haiku" and self.config.model_haiku:
            return self.config.model_haiku

        return incoming_model

    def strip_known_prefix(self, model: str) -> str:
        """Strip known provider prefixes from model name."""
        prefixes = [
            "opencode/", "openrouter/", "openai/", "ollama/",
            "deepseek/", "xai/", "gemini/", "mistral/", "codestral/",
            "cohere/", "groq/", "fireworks/", "sambanova/", "cerebras/",
            "huggingface/", "github_models/", "wafer/", "kimi/",
            "kimi_code/", "minimax/", "zai/", "ollama_cloud/",
            "vercel/", "nvidia_nim/", "lmstudio/", "llamacpp/",
        ]
        for p in prefixes:
            if model.startswith(p):
                return model[len(p):]
        return model

    def route(self, method: str, path: str, headers: dict[str, str],
              body: bytes) -> dict:
        """Route a request through the provider chain. Returns response dict.

        Response format:
          {"status": int, "headers": dict, "body": bytes,
           "stream": callable|None}
        """
        if path in ("/v1/messages", "/v1/v1/messages", "/messages"):
            return self._handle_messages(body)
        if path in ("/v1/messages/count_tokens",):
            return self._handle_token_count(body)
        if path in ("/v1/models",):
            return self._handle_models()
        if path in ("/health", "/", "/api/hello"):
            return self._handle_health()
        if path == "/stop":
            return {"status": 200, "headers": {"Content-Type": "application/json"},
                    "body": json.dumps({"status": "stopped"}).encode()}
        return {"status": 200, "headers": {"Content-Length": "0", "Connection": "close"},
                "body": b""}

    def _handle_messages(self, body: bytes) -> dict:
        try:
            request_json = json.loads(body)
        except json.JSONDecodeError:
            return self._error(400, "invalid_request_error", "Invalid JSON body")

        messages_req = MessagesRequest(request_json)
        chain = self.config.get_provider_chain()
        last_error: str | None = None
        chain_start = time.time()

        for idx, provider_id in enumerate(chain):
            elapsed = time.time() - chain_start
            if elapsed >= MAX_FALLBACK_DURATION:
                last_error = f"Fallback chain exceeded {MAX_FALLBACK_DURATION}s"
                break

            if idx > 0:
                time.sleep(0.5)
                if time.time() - chain_start >= MAX_FALLBACK_DURATION:
                    break

            try:
                start = time.time()
                result = self._route_to_provider(provider_id, messages_req)
                self.last_latency_ms = (time.time() - start) * 1000
                if result.get("status", 0) >= 500:
                    last_error = f"Provider {provider_id} returned HTTP {result['status']}"
                    log(f"Provider {provider_id} failed with status {result['status']}, trying next…", "warn")
                    continue
                return result
            except Exception as e:
                last_error = str(e)
                log(f"Provider {provider_id} error: {e}, trying next…", "warn")
                continue

        return self._error(503, "api_error", last_error or "No providers available")

    def _route_to_provider(self, provider_id: str, req: "MessagesRequest") -> dict:
        """Route a single request to one provider."""
        config = self.config
        resolved_model = self.resolve_model(req.model, provider_id)
        api_key = config.get_api_key(provider_id)
        base_url = config.base_url_for(provider_id)
        model = self.strip_known_prefix(resolved_model)

        if provider_id == "direct":
            return self._route_anthropic(model, api_key, base_url, req)
        elif provider_id in ("opencode-zen", "opencode-go", "openai", "openrouter",
                             "nvidia-nim", "deepseek", "gemini", "mistral",
                             "codestral", "cohere", "groq", "fireworks",
                             "sambanova", "cerebras", "huggingface",
                             "github-models", "wafer", "kimi", "kimi-code",
                             "minimax", "xai", "zai", "ollama-cloud", "ai-gateway"):
            is_or = provider_id == "openrouter"
            return self._route_openai_compat(provider_id, model, api_key, base_url, req, is_or)
        elif provider_id in ("local", "ollama"):
            return self._route_openai_compat(provider_id, config.local_llm_model,
                                              api_key, config.local_llm_base_url,
                                              req, False)
        elif provider_id in ("lmstudio", "llamacpp"):
            return self._route_openai_compat(provider_id, model, "", base_url, req, False)
        else:
            return self._error(400, "invalid_request_error", f"Unknown provider: {provider_id}")

    def _route_anthropic(self, model: str, api_key: str, base_url: str,
                         req: "MessagesRequest") -> dict:
        if not api_key:
            return self._error(401, "authentication_error", "ANTHROPIC_API_KEY not configured")

        body_dict = dict(req.json)
        body_dict["model"] = model

        url = f"{base_url}/v1/messages"
        host = urlparse(url).hostname or "api.anthropic.com"
        ip = DirectDNSResolver.resolve(host) or host

        headers = {
            "Content-Type": "application/json",
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "Host": host,
        }

        body_bytes = json.dumps(body_dict).encode()
        return self._upstream_request(url, "POST", headers, body_bytes,
                                       req.stream, resolve_ip=ip, host_override=host)

    def _route_openai_compat(self, provider_id: str, model: str, api_key: str,
                              base_url: str, req: "MessagesRequest",
                              is_openrouter: bool) -> dict:
        openai_body = MessageTranslator.to_openai(req.json, model)

        # Inject chat_template override for local GGUF models with broken
        # baked-in templates (e.g. raise_exception blocks).
        local_providers = {"local", "ollama", "lmstudio", "llamacpp"}
        if provider_id in local_providers:
            ct = self.config.chat_template
            if ct:
                openai_body["chat_template"] = ct
                log(f"Using chat_template override for {provider_id}", "debug")

        url = f"{base_url}/chat/completions"
        host = urlparse(url).hostname or "api.openai.com"
        ip = DirectDNSResolver.resolve(host) or host

        headers: dict[str, str] = {
            "Content-Type": "application/json",
            "Host": host,
        }
        if api_key:
            headers["Authorization"] = f"Bearer {api_key}"
        if is_openrouter:
            headers["HTTP-Referer"] = "https://github.com/marshaljlee/jxproxy"
            headers["X-Title"] = "JXProxy (Android)"

        body_bytes = json.dumps(openai_body).encode()
        return self._upstream_request(url, "POST", headers, body_bytes,
                                       req.stream, resolve_ip=ip, host_override=host)

    def _upstream_request(self, url: str, method: str, headers: dict[str, str],
                           body: bytes, stream: bool, *,
                           resolve_ip: str | None = None,
                           host_override: str | None = None) -> dict:
        """Make an HTTP request to the upstream provider with optional IP resolution."""
        parsed = urlparse(url)
        port = parsed.port or (443 if parsed.scheme == "https" else 80)

        if resolve_ip and resolve_ip != parsed.hostname:
            # Direct connection: resolve IP ourselves, bypass system DNS
            log(f"Resolved {parsed.hostname} → {resolve_ip}")
            target_host = resolve_ip
        else:
            target_host = parsed.hostname or ""

        if stream:
            # Streaming: return a generator for SSE chunks
            def stream_generator():
                try:
                    response_data = self._http_request_raw(
                        url, method, headers, body, resolve_ip, host_override
                    )
                    # response_data is (status, resp_headers, body_data)
                    status, resp_headers, body_data = response_data
                    # If non-200, return full body as headers
                    if status != 200:
                        yield json.dumps({
                            "error": {"type": "api_error", "message": body_data.decode(errors='replace')}
                        }).encode()
                        return

                    # Parse SSE from body (curl already gave us the full response)
                    buffer = body_data.decode(errors='replace')
                    for line in buffer.split("\n"):
                        if line.startswith("data: "):
                            chunk = line[6:]
                            events = MessageTranslator.openai_to_anthropic_sse(
                                json.loads(chunk), "")
                            for evt in events:
                                yield evt.encode()

                    # Ensure stream termination
                    yield SSEFormatter.format("message_stop",
                        json.dumps({"type": "message_stop"})).encode()
                except Exception as e:
                    yield json.dumps({
                        "error": {"type": "api_error", "message": str(e)}
                    }).encode()

            return {
                "status": 200,
                "headers": {
                    "Content-Type": "text/event-stream",
                    "Cache-Control": "no-cache",
                    "Connection": "keep-alive",
                },
                "body": b"",
                "stream": stream_generator,
            }
        else:
            # Non-streaming
            status, resp_headers, body_data = self._http_request_raw(
                url, method, headers, body, resolve_ip, host_override
            )
            if status == 200:
                # Convert OpenAI response to Anthropic
                try:
                    openai_data = json.loads(body_data)
                    anthropic = MessageTranslator.openai_to_anthropic_nonstream(openai_data, "")
                    return {
                        "status": 200,
                        "headers": {"Content-Type": "application/json"},
                        "body": json.dumps(anthropic).encode(),
                    }
                except json.JSONDecodeError:
                    return {
                        "status": status,
                        "headers": dict(resp_headers),
                        "body": body_data,
                    }
            else:
                return {
                    "status": status,
                    "headers": dict(resp_headers),
                    "body": body_data,
                }

    def _http_request_raw(self, url: str, method: str, headers: dict[str, str],
                           body: bytes, resolve_ip: str | None = None,
                           host_override: str | None = None) -> tuple[int, dict[str, str], bytes]:
        """Raw HTTP request. Returns (status_code, response_headers, response_body)."""
        parsed = urlparse(url)
        scheme = parsed.scheme
        host = parsed.hostname or ""
        port = parsed.port or (443 if scheme == "https" else 80)
        path = parsed.path or "/"
        if parsed.query:
            path += "?" + parsed.query

        # Use socket-level request with optional IP resolution
        import http.client

        if resolve_ip and resolve_ip != host:
            log(f"Direct connection to {resolve_ip}:{port} (host: {host})", "debug")
            conn: http.client.HTTPSConnection | http.client.HTTPConnection
            if scheme == "https":
                conn = http.client.HTTPSConnection(resolve_ip, port, timeout=UPSTREAM_TIMEOUT)
            else:
                conn = http.client.HTTPConnection(resolve_ip, port, timeout=UPSTREAM_TIMEOUT)
            conn.set_tunnel(host, port)
        else:
            log(f"Standard connection to {host}:{port}", "debug")
            if scheme == "https":
                conn = http.client.HTTPSConnection(host, port, timeout=UPSTREAM_TIMEOUT)
            else:
                conn = http.client.HTTPConnection(host, port, timeout=UPSTREAM_TIMEOUT)

        try:
            conn.request(method, path, body=body, headers=headers)
            resp = conn.getresponse()
            status = resp.status
            resp_headers = dict(resp.getheaders())
            resp_body = resp.read()
            return status, resp_headers, resp_body
        except Exception as e:
            log(f"HTTP request error: {e}", "error")
            raise
        finally:
            conn.close()

    def _handle_token_count(self, body: bytes) -> dict:
        try:
            data = json.loads(body)
        except json.JSONDecodeError:
            return self._error(400, "invalid_request_error", "Invalid JSON")
        total_chars = 0
        for msg in data.get("messages", []):
            content = msg.get("content", "")
            if isinstance(content, str):
                total_chars += len(content)
            elif isinstance(content, list):
                for block in content:
                    if isinstance(block, dict):
                        total_chars += len(block.get("text", ""))
        tokens = max(1, int(total_chars / 4))
        return {"status": 200, "headers": {"Content-Type": "application/json"},
                "body": json.dumps({"input_tokens": tokens, "estimated": True}).encode()}

    def _handle_models(self) -> dict:
        now = int(time.time())
        cfg = self.config
        models: list[dict] = [
            {"id": cfg.model_opus, "object": "model", "created": now, "owned_by": "jxproxy"},
            {"id": cfg.model_sonnet, "object": "model", "created": now, "owned_by": "jxproxy"},
            {"id": cfg.model_haiku, "object": "model", "created": now, "owned_by": "jxproxy"},
        ]
        for preset in ProviderPreset.all():
            for mid in preset.models:
                models.append({"id": mid, "object": "model", "created": now, "owned_by": preset.pid})
        return {"status": 200, "headers": {"Content-Type": "application/json"},
                "body": json.dumps({"data": models}).encode()}

    def _handle_health(self) -> dict:
        cfg = self.config
        return {"status": 200, "headers": {"Content-Type": "application/json"},
                "body": json.dumps({
                    "status": "ok",
                    "provider": cfg.provider,
                    "version": VERSION,
                    "proxy": "jxproxy-android",
                }).encode()}

    def _error(self, code: int, errtype: str, msg: str) -> dict:
        return {"status": code, "headers": {"Content-Type": "application/json"},
                "body": json.dumps({
                    "type": "error",
                    "error": {"type": errtype, "message": msg},
                }).encode()}


class MessagesRequest:
    """Parsed Anthropic Messages API request."""
    def __init__(self, json_data: dict):
        self.json = json_data
        self.model = json_data.get("model", "claude-sonnet-4-20250514")
        self.messages = json_data.get("messages", [])
        self.stream = json_data.get("stream", False)


# ═══════════════════════════════════════════════════════════════════════════════
# Proxy Server (HTTP)
# ═══════════════════════════════════════════════════════════════════════════════

class JXProxyHandler(BaseHTTPRequestHandler):
    """HTTP forward proxy handler with AI routing."""

    # Class-level references set by the server
    router: ProviderRouter = None  # type: ignore
    config: ConfigManager = None  # type: ignore
    server_instance: "ProxyServer" = None  # type: ignore

    def do_GET(self):
        self._handle_request("GET")

    def do_POST(self):
        self._handle_request("POST")

    def do_PUT(self):
        self._handle_request("PUT")

    def do_DELETE(self):
        self._handle_request("DELETE")

    def do_PATCH(self):
        self._handle_request("PATCH")

    def do_HEAD(self):
        self._handle_request("HEAD")

    def do_OPTIONS(self):
        self._handle_request("OPTIONS")

    def do_CONNECT(self):
        """Handle CONNECT tunnels for HTTPS."""
        host, port = self.path.split(":")
        port = int(port)

        log(f"CONNECT {host}:{port}", "debug")

        # For AI hosts, we route through our provider
        if AIHostClassifier.is_ai_host(host) or self._is_mitm_host(host):
            log(f"AI CONNECT tunnel: {host}:{port}", "info")
            self._handle_ai_connect(host, port)
        else:
            self._handle_passthrough_connect(host, port)

    def _is_mitm_host(self, host: str) -> bool:
        hosts = JXProxyHandler.config.mitm_hosts
        for h in hosts:
            if h == host:
                return True
            if h.startswith("*.") and host.endswith(h[1:]):
                return True
        return False

    def _handle_ai_connect(self, host: str, port: int):
        """For AI CONNECT tunnels: send 200, then read tunneled HTTP and route."""
        self.send_response(200, "Connection Established")
        self.send_header("Proxy-Agent", "JXProxy")
        self.end_headers()

        # Read the tunneled plaintext HTTP request
        content_length = int(self.headers.get("Content-Length", 0))
        raw_data = b""
        if content_length > 0:
            raw_data = self.rfile.read(content_length)
        else:
            # Read until we have the full HTTP header+body
            while True:
                chunk = self.rfile.read(65536)
                if not chunk:
                    break
                raw_data += chunk
                if b"\r\n\r\n" in raw_data:
                    # Check if we have the full body
                    header_end = raw_data.find(b"\r\n\r\n")
                    header_part = raw_data[:header_end].decode(errors="replace")
                    body_part = raw_data[header_end + 4:]

                    # Parse Content-Length from headers
                    cl = None
                    for line in header_part.split("\r\n"):
                        if line.lower().startswith("content-length:"):
                            cl = int(line.split(":")[1].strip())
                            break
                    if cl is not None and len(body_part) >= cl:
                        break
                    elif cl is None:
                        break

        if raw_data:
            # Parse and route as HTTP
            raw_str = raw_data.decode(errors="replace")
            first_line = raw_str.split("\r\n")[0] if raw_str else ""
            parts = first_line.split(" ") if first_line else []
            method = parts[0] if len(parts) > 0 else "GET"
            path = parts[1] if len(parts) > 1 else "/"

            log(f"Tunneled HTTP: {method} {path}", "debug")

            # Extract body
            body = b""
            if b"\r\n\r\n" in raw_data:
                body = raw_data[raw_data.find(b"\r\n\r\n") + 4:]

            headers = self._parse_headers(raw_str)
            resp = JXProxyHandler.router.route(method, path, headers, body)

            # Write response back through tunnel
            try:
                status_line = f"HTTP/1.1 {resp['status']} {status_text(resp['status'])}\r\n"
                self.wfile.write(status_line.encode())
                for k, v in resp.get("headers", {}).items():
                    self.wfile.write(f"{k}: {v}\r\n".encode())
                stream_fn = resp.get("stream")
                if stream_fn:
                    self.wfile.write(b"Transfer-Encoding: chunked\r\n\r\n")
                    for chunk in stream_fn():
                        if chunk:
                            self.wfile.write(f"{len(chunk):x}\r\n".encode())
                            self.wfile.write(chunk)
                            self.wfile.write(b"\r\n")
                        self.wfile.flush()
                    self.wfile.write(b"0\r\n\r\n")
                else:
                    body_bytes = resp.get("body", b"")
                    self.wfile.write(f"Content-Length: {len(body_bytes)}\r\n\r\n".encode())
                    self.wfile.write(body_bytes)
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass

        self.close_connection = True

    def _handle_passthrough_connect(self, host: str, port: int):
        """Standard CONNECT passthrough."""
        try:
            # Connect to the remote host
            remote = socket.create_connection((host, port), timeout=30)
            self.send_response(200, "Connection Established")
            self.send_header("Proxy-Agent", "JXProxy")
            self.end_headers()

            # Bidirectional relay
            self._relay(self.connection, remote)
        except Exception as e:
            log(f"CONNECT passthrough failed for {host}:{port}: {e}", "error")
            try:
                self.send_error(502, f"Connection failed: {e}")
            except (BrokenPipeError, ConnectionResetError):
                pass
        self.close_connection = True

    def _relay(self, src: socket.socket, dst: socket.socket):
        """Bidirectional TCP relay with background threads."""
        stop = threading.Event()

        def forward(s: socket.socket, d: socket.socket):
            try:
                while not stop.is_set():
                    data = s.recv(65536)
                    if not data:
                        break
                    d.sendall(data)
            except (OSError, BrokenPipeError, ConnectionResetError):
                pass
            finally:
                stop.set()

        t1 = threading.Thread(target=forward, args=(src, dst), daemon=True)
        t2 = threading.Thread(target=forward, args=(dst, src), daemon=True)
        t1.start()
        t2.start()
        t1.join()
        t2.join()
        try:
            dst.close()
        except OSError:
            pass

    def _handle_request(self, method: str):
        """Handle standard HTTP requests."""
        path = self.path
        parsed = urlparse(path)
        host = parsed.hostname or self.headers.get("Host", "127.0.0.1")
        port = parsed.port or (443 if parsed.scheme == "https" else 80)

        # Strip port from host if present
        if ":" in host:
            host = host.split(":")[0]

        # Check auth
        config = JXProxyHandler.config
        if config.auth_token:
            token = self.headers.get("x-api-key", "")
            auth_header = self.headers.get("authorization", "")
            if auth_header.startswith("Bearer "):
                token = auth_header[7:]
            if not token or token != config.auth_token:
                if path not in ("/api/hello", "/health", "/"):
                    self._send_json(401, {"error": {"type": "authentication_error",
                                                     "message": "Invalid auth token"}})
                    return

        # Classify and route
        action = AIHostClassifier.classify(host)

        # Internal endpoints
        if host in ("127.0.0.1", "localhost", "0.0.0.0"):
            if path == "/admin" or path == "/admin/":
                self._handle_admin()
                return
            if path in ("/health", "/"):
                self._handle_health()
                return
            if path == "/api/hello":
                self._handle_hello()
                return
            if path == "/v1/models":
                self._handle_models_list()
                return
            if path.startswith("/v1/models/"):
                self._handle_model_detail(path)
                return
            if path in ("/v1/messages", "/v1/v1/messages", "/messages"):
                body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
                self._route_messages(method, body)
                return

        # For AI hosts: route through provider
        if action == RouteAction.ROUTE_AI:
            body = b""
            cl = int(self.headers.get("Content-Length", 0))
            if cl > 0:
                body = self.rfile.read(cl)
            headers = {k.lower(): v for k, v in self.headers.items()}
            self._route_messages(method, body)
        else:
            # Passthrough: forward to destination
            body = b""
            cl = int(self.headers.get("Content-Length", 0))
            if cl > 0:
                body = self.rfile.read(cl)
            self._passthrough(method, host, port, path, body)

    def _parse_headers(self, raw: str) -> dict[str, str]:
        headers: dict[str, str] = {}
        lines = raw.split("\r\n")
        for line in lines[1:]:
            if not line or line.startswith("HTTP/"):
                continue
            if ":" in line:
                k, v = line.split(":", 1)
                headers[k.strip().lower()] = v.strip()
        return headers

    def _route_messages(self, method: str, body: bytes):
        """Route /v1/messages calls through the provider router."""
        path = self.path
        parsed = urlparse(path)
        clean_path = parsed.path

        headers = {k.lower(): v for k, v in self.headers.items()}
        resp = JXProxyHandler.router.route(method, clean_path, headers, body)

        stream_fn = resp.get("stream")
        if stream_fn:
            self.send_response(200)
            for k, v in resp.get("headers", {}).items():
                self.send_header(k, v)
            self.end_headers()

            try:
                for chunk in stream_fn():
                    if chunk:
                        self.wfile.write(chunk)
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
        else:
            self.send_response(resp["status"])
            for k, v in resp.get("headers", {}).items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(resp.get("body", b""))

    def _passthrough(self, method: str, host: str, port: int, path: str, body: bytes):
        """Forward a request directly to the destination."""
        try:
            conn: http.client.HTTPSConnection | http.client.HTTPConnection
            scheme = "https" if port == 443 else "http"
            if scheme == "https":
                conn = http.client.HTTPSConnection(host, port, timeout=UPSTREAM_TIMEOUT)
            else:
                conn = http.client.HTTPConnection(host, port, timeout=UPSTREAM_TIMEOUT)

            # Forward relevant headers
            fwd_headers = {}
            for k, v in self.headers.items():
                if k.lower() not in ("proxy-connection", "proxy-authorization",
                                     "proxy-authenticate", "x-api-key"):
                    fwd_headers[k] = v

            conn.request(method, path, body=body, headers=fwd_headers)
            resp = conn.getresponse()
            status = resp.status

            # Forward response
            self.send_response(status)
            for k, v in resp.getheaders():
                if k.lower() not in ("transfer-encoding", "content-encoding"):
                    self.send_header(k, v)
            self.end_headers()

            # Stream response body
            while True:
                chunk = resp.read(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
            self.wfile.flush()
            conn.close()
        except Exception as e:
            log(f"Passthrough failed: {e}", "error")
            try:
                self.send_error(502, f"Passthrough error: {e}")
            except (BrokenPipeError, ConnectionResetError):
                pass

    def _handle_admin(self):
        cfg = JXProxyHandler.config
        body = f"""<!DOCTYPE html>
<html><body style="background:#131517;color:#F3F4F6;font-family:system-ui;padding:2rem">
<h1>JXProxy (Android)</h1>
<p>Status: ✅ Running</p>
<p>Provider: {cfg.provider}</p>
<p>Port: {cfg.port}</p>
<p>Uptime: {int(time.time() - ProxyServer.start_time)}s</p>
<p>Requests: {ProxyServer.request_count}</p>
<p><a href="/health" style="color:#1A73E8">/health</a></p>
</body></html>"""  # noqa: E501
        self._send_html(200, body)

    def _handle_health(self):
        self._send_json(200, {
            "status": "ok",
            "provider": JXProxyHandler.config.provider,
            "version": VERSION,
            "proxy": "jxproxy-android",
        })

    def _handle_hello(self):
        self._send_json(200, {
            "status": "ok",
            "provider": JXProxyHandler.config.provider,
            "version": VERSION,
        })

    def _handle_models_list(self):
        now = int(time.time())
        cfg = JXProxyHandler.config
        models: list[dict] = [
            {"id": cfg.model_opus, "object": "model", "created": now, "owned_by": "jxproxy"},
            {"id": cfg.model_sonnet, "object": "model", "created": now, "owned_by": "jxproxy"},
            {"id": cfg.model_haiku, "object": "model", "created": now, "owned_by": "jxproxy"},
        ]
        for preset in ProviderPreset.all():
            for mid in preset.models:
                models.append({"id": mid, "object": "model", "created": now, "owned_by": preset.pid})
        self._send_json(200, {"data": models})

    def _handle_model_detail(self, path: str):
        model_id = path.replace("/v1/models/", "").split("/")[0]
        now = int(time.time())
        self._send_json(200, {
            "id": model_id,
            "object": "model",
            "created": now,
            "owned_by": "jxproxy",
            "capabilities": {
                "context_window": 200000,
                "max_output_tokens": 4096,
                "supports_vision": True,
                "supports_streaming": True,
            },
        })

    def _send_json(self, status: int, data: dict):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.send_header("Proxy-Agent", "JXProxy")
        self.end_headers()
        self.wfile.write(body)

    def _send_html(self, status: int, html: str):
        body = html.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args):
        log(f"HTTP: {format % args}", "debug")


class ThreadedHTTPServer(HTTPServer):
    """HTTP server that handles each request in a new thread."""
    allow_reuse_address = True
    daemon_threads = True

    def process_request(self, request: socket.socket, client_address: tuple):
        t = threading.Thread(target=self.process_request_thread,
                             args=(request, client_address),
                             daemon=True)
        t.start()

    def process_request_thread(self, request: socket.socket, client_address: tuple):
        try:
            self.finish_request(request, client_address)
        except Exception:
            self.handle_error(request, client_address)
        finally:
            self.shutdown_request(request)


class ProxyServer:
    """Main proxy server controller."""

    start_time: float = 0.0
    request_count: int = 0

    # Local provider IDs that need keepalive pings to stay loaded.
    _LOCAL_PROVIDERS = {"local", "ollama", "lmstudio", "llamacpp"}

    def __init__(self, config: ConfigManager):
        self.config = config
        self.router = ProviderRouter(config)
        self.httpd: ThreadedHTTPServer | None = None
        self._running = False
        self._thread: threading.Thread | None = None
        self._keepalive_thread: threading.Thread | None = None
        self._keepalive_stop = threading.Event()

    def start(self, port: int | None = None) -> bool:
        if self._running:
            log("Proxy already running", "warn")
            return True

        p = port or self.config.port

        # Pre-flight: check port availability
        if not self._port_available(p):
            log(f"Port {p} is already in use", "error")
            return False

        # Configure handler
        JXProxyHandler.router = self.router
        JXProxyHandler.config = self.config
        JXProxyHandler.server_instance = self

        try:
            self.httpd = ThreadedHTTPServer(("127.0.0.1", p), JXProxyHandler)
            ProxyServer.start_time = time.time()
            ProxyServer.request_count = 0
            self._running = True

            log(f"JXProxy listening on 127.0.0.1:{p}", "info")
            log(f"Provider: {self.config.provider}", "info")
            log(f"Auth token: {'✓ set' if self.config.auth_token else '✗ empty (no auth)'}", "info")

            self._thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
            self._thread.start()

            # Start keepalive for local models (Ollama, llama.cpp, LM Studio)
            self._start_keepalive()

            return True
        except OSError as e:
            log(f"Failed to start server: {e}", "error")
            self._running = False
            return False

    def _start_keepalive(self):
        """Start a background thread that pings local model endpoints periodically
        to prevent Ollama/llama.cpp from unloading the model from GPU memory."""
        # Check if any local provider is in the active chain
        chain = self.config.get_provider_chain()
        local_in_chain = any(p in self._LOCAL_PROVIDERS for p in chain)
        if not local_in_chain:
            log("No local provider in chain — keepalive not needed", "debug")
            return

        # Determine which local endpoints to ping
        local_endpoints = []
        for pid in self._LOCAL_PROVIDERS:
            if pid in chain:
                base = self.config.base_url_for(pid)
                if base:
                    # Strip /v1 suffix if present for health endpoint
                    health = base.rstrip('/')
                    if health.endswith('/v1'):
                        health = health[:-3]
                    local_endpoints.append((pid, health))

        if not local_endpoints:
            return

        self._keepalive_stop.clear()

        def _keepalive_worker():
            log(f"Keepalive started for local models: {[e[0] for e in local_endpoints]}", "info")
            while not self._keepalive_stop.is_set():
                for pid, base in local_endpoints:
                    if self._keepalive_stop.is_set():
                        break
                    # Ping /v1/models or /api/tags (Ollama) to keep model alive
                    for path in ("/v1/models", "/api/tags", "/health"):
                        url = f"{base}{path}"
                        try:
                            req = urllib.request.Request(url)
                            with urllib.request.urlopen(req, timeout=5) as resp:
                                if resp.status == 200:
                                    log(f"Keepalive OK — {pid}{path}", "debug")
                                    break
                        except Exception:
                            continue

                # Wait 30 seconds between keepalive cycles
                # Ollama default keepalive is 5min; 30s is well within that.
                self._keepalive_stop.wait(timeout=30)

            log("Keepalive stopped", "info")

        self._keepalive_thread = threading.Thread(
            target=_keepalive_worker, daemon=True, name="jxproxy-keepalive"
        )
        self._keepalive_thread.start()

    def stop(self):
        log("Shutting down keepalive…", "debug")
        self._keepalive_stop.set()
        self._keepalive_thread = None

        if self.httpd and self._running:
            log("Shutting down proxy…", "info")
            self.httpd.shutdown()
            self.httpd.server_close()
            self._running = False
            log("Proxy stopped", "info")

    @property
    def is_running(self) -> bool:
        return self._running

    @staticmethod
    def _port_available(port: int) -> bool:
        """Check if a port is available for listening."""
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind(("127.0.0.1", port))
            s.close()
            return True
        except OSError:
            return False


# ═══════════════════════════════════════════════════════════════════════════════
# Logging
# ═══════════════════════════════════════════════════════════════════════════════

LOG_LEVELS = {"debug": 0, "info": 1, "warn": 2, "error": 3}
_current_level = 1  # info

def set_log_level(level: str):
    global _current_level
    _current_level = LOG_LEVELS.get(level, 1)

def log(msg: str, level: str = "info"):
    """Log a message with timestamp and level."""
    lvl = LOG_LEVELS.get(level, 1)
    if lvl < _current_level:
        return

    ts = datetime.now().strftime("%H:%M:%S")
    prefix = {
        "debug": f"{Color.GRAY}[DEBUG]{Color.RESET}",
        "info": f"{Color.GREEN}[INFO]{Color.RESET}",
        "warn": f"{Color.YELLOW}[WARN]{Color.RESET}",
        "error": f"{Color.RED}[ERROR]{Color.RESET}",
    }.get(level, f"[{level.upper()}]")

    line = f"{Color.GRAY}{ts}{Color.RESET} {prefix} {msg}"
    print(line, file=sys.stderr)

    # Also write to log file
    try:
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        with open(LOG_FILE, "a") as f:
            f.write(f"{ts} [{level.upper()}] {msg}\n")
    except OSError:
        pass


def status_text(code: int) -> str:
    return {
        200: "OK", 201: "Created", 204: "No Content",
        400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
        404: "Not Found", 408: "Request Timeout", 429: "Too Many Requests",
        500: "Internal Server Error", 502: "Bad Gateway", 503: "Service Unavailable",
    }.get(code, "Unknown")


# ═══════════════════════════════════════════════════════════════════════════════
# CLI
# ═══════════════════════════════════════════════════════════════════════════════

def cmd_start(args: list[str]) -> int:
    """Start the proxy server."""
    import shlex

    parser = argparse.ArgumentParser(prog=f"{APP_NAME} start")
    parser.add_argument("--port", type=int, default=os.environ.get("JXPROXY_PORT", DEFAULT_PORT))
    parser.add_argument("--daemon", action="store_true", help="Run in background")
    parser.add_argument("--verbose", "-v", action="store_true")
    parsed = parser.parse_args(args)

    if parsed.verbose:
        set_log_level("debug")

    # Check if already running
    if PID_FILE.exists():
        try:
            with open(PID_FILE) as f:
                old_pid = int(f.read().strip())
            # Check if process is still alive
            os.kill(old_pid, 0)
            log(f"JXProxy is already running (PID {old_pid})", "error")
            return 1
        except (OSError, ValueError, ProcessLookupError):
            PID_FILE.unlink(missing_ok=True)

    if parsed.daemon:
        # Fork into background
        pid = os.fork()
        if pid > 0:
            # Parent: write PID and exit
            with open(PID_FILE, "w") as f:
                f.write(str(pid))
            log(f"JXProxy started in background (PID {pid})", "info")
            return 0
        # Child continues
        os.setsid()
        # Redirect stdout/stderr to log
        sys.stdout = open(os.devnull, "w")
        sys.stderr = open(os.devnull, "w")

    config = ConfigManager.instance()
    server = ProxyServer(config)

    # Write PID
    with open(PID_FILE, "w") as f:
        f.write(str(os.getpid()))

    def cleanup():
        server.stop()
        PID_FILE.unlink(missing_ok=True)
    atexit.register(cleanup)

    def sig_handler(signum, frame):
        log(f"Received signal {signum}, shutting down…", "info")
        server.stop()
        sys.exit(0)

    signal.signal(signal.SIGTERM, sig_handler)
    signal.signal(signal.SIGINT, sig_handler)

    ok = server.start(port=parsed.port)
    if not ok:
        PID_FILE.unlink(missing_ok=True)
        return 1

    # Block forever
    try:
        while server.is_running:
            time.sleep(1)
    except KeyboardInterrupt:
        pass

    return 0


def cmd_stop(args: list[str]) -> int:
    """Stop the proxy server."""
    if not PID_FILE.exists():
        log("JXProxy is not running", "warn")
        return 0

    try:
        with open(PID_FILE) as f:
            pid = int(f.read().strip())
        os.kill(pid, signal.SIGTERM)
        # Wait for it to exit
        for _ in range(50):
            try:
                os.kill(pid, 0)
                time.sleep(0.1)
            except ProcessLookupError:
                break
        PID_FILE.unlink(missing_ok=True)
        log(f"JXProxy (PID {pid}) stopped", "info")
        return 0
    except (OSError, ValueError) as e:
        log(f"Failed to stop: {e}", "error")
        PID_FILE.unlink(missing_ok=True)
        return 1


def cmd_status(args: list[str]) -> int:
    """Show proxy status."""
    running = False
    pid = None
    if PID_FILE.exists():
        try:
            with open(PID_FILE) as f:
                pid = int(f.read().strip())
            os.kill(pid, 0)
            running = True
        except (OSError, ProcessLookupError):
            PID_FILE.unlink(missing_ok=True)

    if running:
        print(f"{Color.GREEN}●{Color.RESET} JXProxy is running (PID {pid})")
    else:
        print(f"{Color.RED}●{Color.RESET} JXProxy is stopped")

    print(f"  Port:     {ConfigManager.instance().port}")
    print(f"  Provider: {ConfigManager.instance().provider}")
    print(f"  Config:   {CONFIG_FILE}")
    print(f"  Log:      {LOG_FILE}")
    return 0


def cmd_config(args: list[str]) -> int:
    """Manage configuration."""
    cfg = ConfigManager.instance()

    if not args or args[0] == "show":
        print(cfg.show())
        return 0

    sub = args[0]
    if sub == "set":
        for kv in args[1:]:
            if "=" not in kv:
                log(f"Invalid KEY=VALUE: {kv}", "error")
                continue
            k, v = kv.split("=", 1)
            k = k.lower().replace("-", "_")

            # Delegate to setter
            attrs = {
                "port": ("port", int),
                "provider": ("provider", str),
                "model": ("model", str),
                "model_opus": ("model_opus", str),
                "model_sonnet": ("model_sonnet", str),
                "model_haiku": ("model_haiku", str),
                "auth_token": ("auth_token", str),
                "fallback_providers": ("fallback_providers", str),
                "enable_thinking": ("enable_thinking", lambda x: x.lower() in ("true", "1", "yes")),
                "dns_redirect_enabled": ("dns_redirect_enabled", lambda x: x.lower() in ("true", "1", "yes")),
                "local_llm_base_url": ("local_llm_base_url", str),
                "local_llm_model": ("local_llm_model", str),
            }
            if k in attrs:
                attr, converter = attrs[k]
                try:
                    setattr(cfg, attr, converter(v))
                    log(f"Set {attr} = {v}", "info")
                except (ValueError, TypeError) as e:
                    log(f"Failed to set {k}: {e}", "error")
            elif k.startswith("api_key_"):
                provider = k[8:]
                cfg.set_api_key(provider, v)
                log(f"Set API key for {provider}", "info")
            else:
                log(f"Unknown config key: {k}", "error")
        return 0

    log(f"Unknown config subcommand: {sub}", "error")
    return 1


def cmd_providers(args: list[str]) -> int:
    """List available providers."""
    print(f"{Color.BOLD}Available Providers:{Color.RESET}\n")
    for preset in ProviderPreset.all():
        has_key = ConfigManager.instance().get_api_key(preset.pid)
        key_dot = f"{Color.GREEN}✓{Color.RESET}" if has_key else f"{Color.GRAY}✗{Color.RESET}"
        requires = f" {Color.YELLOW}(key required){Color.RESET}" if preset.requires_key else ""
        print(f"  {key_dot} {Color.CYAN}{preset.pid:<20}{Color.RESET} {preset.name}{requires}")
        if preset.models:
            print(f"     Models: {', '.join(preset.models[:5])}{'…' if len(preset.models) > 5 else ''}")
        print()
    return 0


def cmd_help(args: list[str]) -> int:
    """Show help."""
    print(f"""{Color.BOLD}JXProxy v{VERSION} — AI API Proxy for Android/Termux{Color.RESET}

{Color.CYAN}Usage:{Color.RESET}
  {APP_NAME} <command> [options]

{Color.CYAN}Commands:{Color.RESET}
  start           Start the proxy server
    --port PORT     Port to listen on (default: {DEFAULT_PORT})
    --daemon        Run in background
    -v, --verbose   Verbose (debug) logging
  stop            Stop the proxy server
  status          Show proxy status
  config          Manage configuration
    show            Show current config
    set KEY=VALUE   Set a config value
                     (e.g., provider=openrouter, port=5255)
  providers       List available AI providers
  help            Show this help

{Color.CYAN}Environment Variables:{Color.RESET}
  JXPROXY_PORT          Port to listen on (default: {DEFAULT_PORT})
  JXPROXY_AUTH_TOKEN    Auth token for proxy (default: {DEFAULT_AUTH_TOKEN})
  ANTHROPIC_API_KEY     API key for Anthropic Direct
  OPENAI_API_KEY        API key for OpenAI
  OPENROUTER_API_KEY    API key for OpenRouter
  OPENCODE_API_KEY      API key for OpenCode

{Color.CYAN}Examples:{Color.RESET}
  {APP_NAME} start                        Start on default port 5255
  {APP_NAME} start --port 8080 --daemon   Start on port 8080 in background
  {APP_NAME} config set provider=openai
  {APP_NAME} config set api_key_openai=sk-...
  {APP_NAME} config show
  {APP_NAME} providers list
  {APP_NAME} stop
""")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        prog=APP_NAME,
        description="AI API Proxy — reverse-engineered from JXRouter",
        add_help=False,
    )
    parser.add_argument("command", nargs="?",
                        choices=["start", "stop", "status", "config", "providers", "help"],
                        default="help")
    parsed, extra = parser.parse_known_args()

    # Ensure config dir exists
    CONFIG_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)

    commands = {
        "start": cmd_start,
        "stop": cmd_stop,
        "status": cmd_status,
        "config": cmd_config,
        "providers": cmd_providers,
        "help": cmd_help,
    }

    cmd = commands.get(parsed.command, cmd_help)
    return cmd(extra)


if __name__ == "__main__":
    sys.exit(main())
