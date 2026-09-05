# jxrouter — Project Journal

Persistence anchor for this workspace's agent memory. The agent maintains this file:
append notable decisions, changes, and session notes so they survive across chats and
sessions. Newest entries on top. `get_project_briefing` reads the sections below.

## About

JXRouter (JXProxy) — a macOS menu-bar proxy app that routes AI API traffic (Claude Code, Codex, OpenAI SDK clients) through configured LLM providers. Native SwiftUI/AppKit, no web admin, no /etc/hosts edits.

## Recent Changes

- 2026-09-06: Upgraded built-in GGUF model loader to fully support multimodal projectors (`mmproj` files for vision models like Ornith, MiniCPM-V, LLaVA, Qwen-VL). Implemented deep scanner for `mmproj` files across `~/Models`, `/Volumes`, and snapshot folders with heuristic token matching to companion base models. Updated `LocalModelManager` to launch `llama-server` with `--mmproj <path>` and `--mmproj-offload`. Added Settings UI controls for mmproj selection (auto-detect, discovered files, file picker, disable vision) with live "Vision Active" pill indicator and persistent config storage.
- 2026-08-31: Session 2 — comprehensive feature completion pass. Fixed MITMHandler @MainActor isolation (removed unused providerRouter reference). Added save-generation counter to Settings auto-save (prevents stale writes). Created DataStore.swift for persistent vault/agent/timeline/session storage. Wired VaultIsolationView, AgentLibraryView, TimelineView, VaultSettingsView to real persisted data. Connected SessionSidebar to real DataStore sessions. Wired agent Run button to real ClaudeChatView with system prompt injection. Added accessibility labels to vault sidebar. Updated VaultCard/VaultActionButton with action closures. Removed hardcoded sample data. Clean build: zero errors, zero warnings. Universal binary (arm64 + x86_64).
- 2026-08-23: Localized the Trae IDE "Repo to Markdown" extension (`~/.trae/extensions/vestjin.repo2md-0.0.2-universal`) to English only: rewrote all UI strings/alerts/generated-Markdown labels in `out/extension.js`, trimmed `readme.md` to English, pinned the extension in `extensions.json`, and write-locked the folder so auto-updates can't revert it.

## Session Memory

- 2026-08-31 (Session 2): Score 8.8 → 9.2/10. Completed: T2.2 MITMHandler fix, T3.2 auto-save race fix, T4.3 data persistence (DataStore), T5.1 session sidebar, T5.2 agent run button, T5.3 vault actions (Snapshot/Restore/Destroy), T5.6 vault settings (real data). T7.1 accessibility labels. T8.1 clean build verified. Deferred: T4.1 SettingsView split (3265 lines, high-risk refactor), T6.x unit tests. Task list at `.TerMinal/backlog/0032-next-session-comprehensive-task-list.md`.
