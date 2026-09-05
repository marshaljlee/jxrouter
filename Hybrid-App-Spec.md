# Freebuff — Hybrid Claude Code Desktop App

> **Complete source specification for building a hybrid app that merges all features from [Clarc](https://github.com/ttnear/Clarc) (macOS native SwiftUI client) and [Opcode](https://github.com/winfunc/opcode) (Tauri cross-platform client) into a single unified Claude Code desktop GUI.**

---

## Table of Contents

1. [Overview & Philosophy](#1-overview--philosophy)
2. [Tech Stack](#2-tech-stack)
3. [Project Structure](#3-project-structure)
4. [Data Models & Types](#4-data-models--types)
5. [Services & API Layer](#5-services--api-layer)
6. [State Management](#6-state-management)
7. [UI Components — Complete Hierarchy](#7-ui-components--complete-hierarchy)
8. [Feature Modules — Detailed Specs](#8-feature-modules--detailed-specs)
9. [Styling & Themes](#9-styling--themes)
10. [Build & Configuration](#10-build--configuration)

---

## 1. Overview & Philosophy

**Freebuff** is a cross-platform desktop application that unifies the best of Clarc and Opcode into a single Claude Code GUI. It wraps the real `claude` CLI underneath so all existing CLAUDE.md files, skills, MCP servers, and slash commands work unchanged.

### Core Design Principles

- **Same engine, no terminal required** — spawns the real Claude Code CLI process
- **Cross-platform** — macOS, Windows, Linux (via Tauri 2 + Rust)
- **Feature-complete** — every feature from both apps, aligned where they overlap
- **Beautiful and native-feeling** — Tailwind CSS + shadcn/ui with macOS-native touches
- **Privacy-first** — all data local, no telemetry, no cloud sync

### Combined Feature Matrix

| Feature Area | Clarc Contribution | Opcode Contribution | Hybrid Result |
|---|---|---|---|
| **Platform** | macOS only (SwiftUI) | Cross-platform (Tauri) | Cross-platform (Tauri 2) |
| **Chat** | Streaming, markdown, diffs, thinking traces | Clean chat UI | Full-featured streaming chat with all visualizations |
| **Projects** | Multi-project workspace, GitHub OAuth | Project browser from ~/.claude | Unified project system with both approaches |
| **Sessions** | Pin, rename, complete, fork, batch actions | Session history, resume, search | Complete session lifecycle management |
| **Agents** | Per-session model/effort/permission controls | Custom AI agents with system prompts | Both — session controls + custom agents |
| **Permissions** | Risk-based approve/deny with Allow Session | Per-agent file/network access | Layered permission system |
| **Terminal** | Embedded SwiftTerm terminal | — | Embedded cross-platform terminal |
| **File Explorer** | Tree, search, hidden toggle, edit, @path | File tree sidebar | Full file explorer with Git status |
| **Git** | Status, branch switching, GitHub OAuth | — | Full Git integration with OAuth |
| **Timeline** | — | Checkpoints, branching, diff viewer | Visual timeline with checkpoints |
| **Analytics** | Rate limit display, context usage | Cost tracking, token analytics, charts | Full usage analytics dashboard |
| **MCP** | — | Server registry, testing, Claude Desktop import | MCP server management |
| **CLAUDE.md** | — | Built-in editor, live preview, scanner | CLAUDE.md editor with preview |
| **Memo/Notes** | Rich-text per-project memo pad | — | Per-project rich-text memo pad |
| **Slash Commands** | Built-in + custom with JSON import/export | — | Full slash command system |
| **Shortcuts** | Configurable prompt & terminal shortcuts | — | Quick-access shortcut buttons |
| **Messages** | Queue with cancel (ESC) | — | Message queue with cancel |
| **Skills** | Anthropic skill marketplace browser | — | Skill marketplace |
| **Themes** | 6 accent themes, font controls | shadcn/ui theming | Theme system with accent colors + font controls |
| **Notifications** | System notifications with previews | — | System notifications |
| **i18n** | English, Korean, Chinese, Japanese, Spanish | — | Full localization (6+ languages) |
| **Focus Mode** | Optional focused chat layout | — | Focus mode |
| **Auto-update** | Sparkle-based update checking | — | Auto-update system |
| **Attachments** | Drag-and-drop, smart paste (images, paths, URLs) | — | File & image attachments with smart paste |

---

## 2. Tech Stack

```yaml
# Primary Stack
Runtime:        Tauri 2 (Rust backend + WebView frontend)
Frontend:       React 18 + TypeScript + Vite 6
UI Framework:   Tailwind CSS v4 + shadcn/ui + Radix primitives
State:          Zustand (global) + React Query (server/async)
Database:       SQLite via rusqlite (Rust side)
Package:        Bun
Terminal:       xterm.js (cross-platform terminal emulation)
Markdown:       react-markdown + remark-gfm + rehype-highlight
Diff:           diff2html (visual inline diffs)
Charts:         Recharts (usage analytics)
i18n:           react-i18next
Icons:          Lucide React

# Rust Backend Crates
cli-bridge:     Custom Rust module spawning `claude` CLI child processes
fs-watcher:     notify crate (file system watching for live updates)
git:            git2 crate (libgit2 bindings for status, branches, OAuth)
keyring:        keyring crate (OS keychain for tokens/SSH keys)
sqlite:         rusqlite (local database)
http:           reqwest (API calls for updates, OAuth flows)
auth:           OAuth device flow implementation
```

---

## 3. Project Structure

```
freebuff/
├── src/                              # React frontend
│   ├── main.tsx                      # App entry point
│   ├── App.tsx                       # Root component with router
│   │
│   ├── components/
│   │   ├── layout/
│   │   │   ├── AppShell.tsx          # Main app shell (sidebar + content)
│   │   │   ├── Sidebar.tsx           # Left sidebar (projects, agents, settings)
│   │   │   ├── TopBar.tsx            # Top toolbar (project, model, permissions, effort)
│   │   │   ├── StatusBar.tsx         # Bottom status bar (path, model, limits, context)
│   │   │   └── Inspector.tsx         # Right inspector panel (file tree, git, terminal, memo)
│   │   │
│   │   ├── chat/
│   │   │   ├── ChatView.tsx          # Main chat container
│   │   │   ├── MessageList.tsx       # Scrollable message stream
│   │   │   ├── MessageBubble.tsx     # Individual message (user/assistant)
│   │   │   ├── ThinkingTrace.tsx     # Expandable thinking/reasoning block
│   │   │   ├── ToolCallView.tsx      # Tool use visualization with diff preview
│   │   │   ├── DiffViewer.tsx        # Inline red/green diff renderer
│   │   │   ├── CodeBlock.tsx         # Syntax-highlighted code with copy
│   │   │   ├── ImagePreview.tsx      # Inline image preview from attachments
│   │   │   ├── StreamingIndicator.tsx # Typing/streaming animation
│   │   │   ├── ErrorBubble.tsx       # Error messages and retry UI
│   │   │   └── StopButton.tsx        # Visible stop/cancel button while streaming
│   │   │
│   │   ├── input/
│   │   │   ├── ChatInput.tsx         # Main message input area
│   │   │   ├── FileDropZone.tsx      # Drag-and-drop attachment zone
│   │   │   ├── SmartPaste.tsx        # Paste detection (images, paths, URLs, text)
│   │   │   ├── AttachmentChips.tsx   # Preview chips for attached items
│   │   │   ├── AttachmentSettings.tsx # Toggle auto-preview for URLs, paths, images, text
│   │   │   ├── SlashCommandMenu.tsx  # Slash command autocomplete popup
│   │   │   └── MessageQueue.tsx      # Queue indicator with cancel (ESC)
│   │   │
│   │   ├── projects/
│   │   │   ├── ProjectBrowser.tsx    # Project list/grid view
│   │   │   ├── ProjectTab.tsx        # Individual project tab
│   │   │   ├── ProjectWindow.tsx     # Dedicated project window (double-click)
│   │   │   ├── GitHubCloneDialog.tsx # OAuth + SSH key setup + clone flow
│   │   │   └── ProjectSettings.tsx   # Per-project configuration
│   │   │
│   │   ├── sessions/
│   │   │   ├── SessionList.tsx       # Session sidebar with search
│   │   │   ├── SessionCard.tsx       # Individual session entry
│   │   │   ├── SessionToolbar.tsx    # Pin, rename, complete, delete, fork
│   │   │   ├── BatchActions.tsx      # Multi-select batch operations
│   │   │   └── SessionFork.tsx       # Fork conversation from any point
│   │   │
│   │   ├── agents/
│   │   │   ├── AgentLibrary.tsx      # Custom agents browser
│   │   │   ├── AgentEditor.tsx       # Create/edit agent (name, icon, prompt, model)
│   │   │   ├── AgentCard.tsx         # Agent display card
│   │   │   ├── AgentRunner.tsx       # Background execution panel
│   │   │   ├── AgentHistory.tsx      # Execution history & logs
│   │   │   └── AgentPermissions.tsx  # Per-agent file/network access config
│   │   │
│   │   ├── timeline/
│   │   │   ├── TimelineView.tsx      # Visual session timeline
│   │   │   ├── CheckpointNode.tsx    # Individual checkpoint marker
│   │   │   ├── BranchView.tsx        # Session branch/fork visualization
│   │   │   ├── CheckpointDiff.tsx    # Diff between any two checkpoints
│   │   │   └── RestoreButton.tsx     # Instant restore to checkpoint
│   │   │
│   │   ├── analytics/
│   │   │   ├── UsageDashboard.tsx    # Main analytics dashboard
│   │   │   ├── CostTracker.tsx       # Real-time cost tracking
│   │   │   ├── TokenBreakdown.tsx    # Tokens by model/project/period
│   │   │   ├── UsageCharts.tsx       # Visual charts (Recharts)
│   │   │   ├── RateLimitDisplay.tsx  # 5-hour and 7-day rate limits
│   │   │   └── ExportPanel.tsx       # Export usage data
│   │   │
│   │   ├── mcp/
│   │   │   ├── MCPManager.tsx        # MCP server management UI
│   │   │   ├── ServerCard.tsx        # Individual MCP server entry
│   │   │   ├── ServerEditor.tsx      # Add/edit MCP server config
│   │   │   ├── ConnectionTest.tsx    # Test server connectivity
│   │   │   └── ClaudeDesktopImport.tsx # Import from Claude Desktop config
│   │   │
│   │   ├── editor/
│   │   │   ├── ClaudeMDEditor.tsx     # CLAUDE.md built-in editor
│   │   │   ├── LivePreview.tsx       # Real-time markdown preview
│   │   │   ├── MarkdownEditor.tsx    # Full markdown editor with syntax highlighting
│   │   │   └── ProjectScanner.tsx    # Find all CLAUDE.md files in projects
│   │   │
│   │   ├── terminal/
│   │   │   ├── EmbeddedTerminal.tsx  # xterm.js terminal panel
│   │   │   ├── TerminalPopup.tsx     # Interactive terminal overlay (/config, /permissions, /model)
│   │   │   └── TerminalShortcut.tsx  # Terminal command shortcut launcher
│   │   │
│   │   ├── inspector/
│   │   │   ├── FileExplorer.tsx      # File tree with search, hidden toggle, edit
│   │   │   ├── GitStatus.tsx         # Git status summary, branch switcher
│   │   │   ├── MemoPad.tsx           # Rich-text per-project memo
│   │   │   └── InspectorTabs.tsx     # Tab container for inspector panels
│   │   │
│   │   ├── slash-commands/
│   │   │   ├── CommandPalette.tsx    # Command search/execution
│   │   │   ├── CommandEditor.tsx     # Add/edit/toggle custom commands
│   │   │   ├── CommandImport.tsx     # JSON import/export
│   │   │   └── ShortcutBar.tsx       # Quick-access shortcut buttons
│   │   │
│   │   ├── permissions/
│   │   │   ├── ApprovalModal.tsx     # Diff preview + Allow/Allow Session/Deny
│   │   │   ├── PermissionSettings.tsx # Ask/Accept Edits/Plan/Auto/Bypass
│   │   │   └── AutoDenyTimer.tsx     # 5-minute auto-deny countdown
│   │   │
│   │   ├── skills/
│   │   │   ├── SkillMarketplace.tsx  # Browse & install Anthropic plugins
│   │   │   └── SkillCard.tsx         # Individual skill display
│   │   │
│   │   ├── settings/
│   │   │   ├── SettingsView.tsx      # Main settings panel
│   │   │   ├── GeneralSettings.tsx   # Theme, font, locale, notifications
│   │   │   ├── ModelDefaults.tsx     # Default model, effort, permissions
│   │   │   ├── PathSettings.tsx      # CLI path, project directories
│   │   │   ├── UpdateSettings.tsx    # Auto-update preferences
│   │   │   └── KeyboardShortcuts.tsx # Keyboard shortcut configuration
│   │   │
│   │   └── shared/
│   │       ├── Button.tsx
│   │       ├── Dialog.tsx
│   │       ├── Dropdown.tsx
│   │       ├── Tooltip.tsx
│   │       ├── Toast.tsx
│   │       ├── SearchInput.tsx
│   │       ├── Badge.tsx
│   │       ├── Separator.tsx
│   │       ├── ScrollArea.tsx
│   │       ├── Tabs.tsx
│   │       ├── Toggle.tsx
│   │       ├── Select.tsx
│   │       └── CommandMenu.tsx
│   │
│   ├── stores/
│   │   ├── appStore.ts               # Global app state (theme, locale, settings)
│   │   ├── projectStore.ts           # Projects, active project, windows
│   │   ├── sessionStore.ts           # Sessions, active session, history
│   │   ├── agentStore.ts             # Custom agents, execution state
│   │   ├── chatStore.ts              # Messages, streaming state, queue
│   │   ├── permissionStore.ts        # Pending approvals, permission modes
│   │   ├── timelineStore.ts          # Checkpoints, branches
│   │   ├── mcpStore.ts               # MCP servers
│   │   └── analyticsStore.ts         # Usage data, costs
│   │
│   ├── hooks/
│   │   ├── useClaudeCLI.ts           # Spawn and manage Claude CLI processes
│   │   ├── useStreaming.ts           # Stream responses from Claude CLI
│   │   ├── useFileTree.ts            # File system browsing
│   │   ├── useGit.ts                 # Git operations
│   │   ├── useKeyboard.ts            # Keyboard shortcut handler
│   │   ├── useDragDrop.ts            # Drag-and-drop file handling
│   │   ├── useSmartPaste.ts          # Intelligent paste detection
│   │   ├── useNotifications.ts       # System notification trigger
│   │   ├── useAutoUpdate.ts          # Update checking
│   │   └── useLocalStorage.ts        # Persistent local storage
│   │
│   ├── lib/
│   │   ├── tauri.ts                  # Tauri invoke wrappers
│   │   ├── claude.ts                 # Claude CLI command builders
│   │   ├── markdown.ts               # Markdown processing utilities
│   │   ├── diff.ts                   # Diff generation and parsing
│   │   ├── git.ts                    # Git utilities
│   │   ├── oauth.ts                  # GitHub OAuth device flow
│   │   ├── keychain.ts               # OS keychain integration
│   │   ├── analytics.ts              # Usage/cost calculation
│   │   └── i18n.ts                   # i18next configuration
│   │
│   ├── i18n/
│   │   ├── en.json                   # English (default)
│   │   ├── ko.json                   # Korean
│   │   ├── zh-CN.json                # Simplified Chinese
│   │   ├── zh-TW.json                # Traditional Chinese
│   │   ├── ja.json                   # Japanese
│   │   └── es.json                   # Spanish
│   │
│   ├── styles/
│   │   ├── globals.css               # Global styles + Tailwind
│   │   ├── themes.ts                 # Theme definitions
│   │   └── fonts.ts                  # Font configuration
│   │
│   └── types/
│       ├── project.ts
│       ├── session.ts
│       ├── agent.ts
│       ├── message.ts
│       ├── tool.ts
│       ├── permission.ts
│       ├── checkpoint.ts
│       ├── mcp.ts
│       ├── analytics.ts
│       └── settings.ts
│
├── src-tauri/                        # Rust backend
│   ├── Cargo.toml
│   ├── tauri.conf.json
│   ├── build.rs
│   ├── icons/
│   │
│   └── src/
│       ├── main.rs                   # Tauri app entry point
│       ├── lib.rs                    # Library root, register commands
│       │
│       ├── commands/
│       │   ├── mod.rs
│       │   ├── claude.rs             # Spawn/manage Claude CLI processes
│       │   ├── projects.rs           # Project CRUD, discovery
│       │   ├── sessions.rs           # Session CRUD, history
│       │   ├── agents.rs             # Agent CRUD, execution
│       │   ├── files.rs              # File read/write/watch
│       │   ├── git.rs                # Git operations (status, branch, diff)
│       │   ├── mcp.rs                # MCP server management
│       │   ├── auth.rs               # GitHub OAuth, SSH key management
│       │   ├── keychain.rs           # OS keychain operations
│       │   ├── analytics.rs          # Usage data aggregation
│       │   ├── update.rs             # Auto-update checking
│       │   ├── fs.rs                 # File system operations
│       │   └── terminal.rs           # PTY terminal management
│       │
│       ├── checkpoint/
│       │   ├── mod.rs
│       │   ├── store.rs              # Checkpoint creation/restoration
│       │   └── diff.rs               # Checkpoint diff generation
│       │
│       ├── process/
│       │   ├── mod.rs
│       │   ├── manager.rs            # Child process lifecycle
│       │   ├── agent_runner.rs       # Background agent execution
│       │   └── terminal_pty.rs       # PTY process management
│       │
│       ├── db/
│       │   ├── mod.rs
│       │   ├── schema.rs             # SQLite schema definitions
│       │   ├── projects.rs           # Project queries
│       │   ├── sessions.rs           # Session queries
│       │   ├── agents.rs             # Agent queries
│       │   ├── checkpoints.rs        # Checkpoint queries
│       │   ├── analytics.rs          # Usage/cost queries
│       │   └── settings.rs           # Settings queries
│       │
│       └── utils/
│           ├── mod.rs
│           ├── paths.rs              # Path resolution (~/.claude, etc.)
│           ├── platform.rs           # Platform-specific helpers
│           └── error.rs              # Error types
│
├── package.json
├── bun.lockb
├── tsconfig.json
├── tailwind.config.ts
├── vite.config.ts
├── index.html
└── README.md
```

---

## 4. Data Models & Types

### 4.1 Project

```typescript
// src/types/project.ts

interface Project {
  id: string;
  name: string;
  path: string;                        // Local filesystem path
  remoteUrl?: string;                  // Git remote URL
  isGitHub: boolean;
  icon?: string;                       // Custom icon (lucide icon name)
  createdAt: string;                   // ISO timestamp
  lastOpenedAt: string;
  sessionCount: number;
  memoContent?: string;                // Rich-text memo (HTML/Markdown)
  memoFormat: 'markdown' | 'richtext';
  isFavorite: boolean;
  color?: string;                      // Project accent color
}
```

### 4.2 Session

```typescript
// src/types/session.ts

interface Session {
  id: string;
  projectId: string;
  title: string;
  firstMessage: string;
  model: ClaudeModel;
  effortLevel: EffortLevel;
  permissionMode: PermissionMode;
  status: SessionStatus;
  isPinned: boolean;
  isCompleted: boolean;
  isHidden: boolean;
  forkParentId?: string;               // If forked, the parent session ID
  forkParentMessageIndex?: number;     // Message index where fork occurred
  createdAt: string;
  updatedAt: string;
  messageCount: number;
  totalTokens: number;
  totalCost: number;                   // USD
}

type SessionStatus = 'active' | 'idle' | 'completed' | 'archived';

type ClaudeModel = 
  | 'claude-opus-4-20250514'
  | 'claude-sonnet-4-20250514'
  | 'claude-haiku-3-5-20241022'
  | 'claude-opus-4-20250514-1m'       // 1M context variant
  | 'plan-mode';

type EffortLevel = 'auto' | 'low' | 'medium' | 'high' | 'xhigh' | 'max';

type PermissionMode = 'ask' | 'accept-edits' | 'plan' | 'auto' | 'bypass';
```

### 4.3 Message

```typescript
// src/types/message.ts

interface Message {
  id: string;
  sessionId: string;
  role: 'user' | 'assistant';
  content: string;                     // Rendered markdown content
  rawContent: string;                  // Raw content from CLI
  thinking?: string;                   // Extended thinking trace
  toolCalls?: ToolCall[];
  attachments?: Attachment[];
  tokenCount: number;
  cost: number;                        // USD for this message
  createdAt: string;
  parentMessageId?: string;            // For forking context
}

interface Attachment {
  id: string;
  type: 'file' | 'image' | 'url' | 'text';
  name: string;
  path?: string;                       // Local file path
  url?: string;                        // URL reference
  content?: string;                    // Inline text content
  mimeType?: string;
  size?: number;                       // Bytes
  previewUrl?: string;                 // Blob URL for images
}

// Message queue
interface QueuedMessage {
  id: string;
  content: string;
  attachments: Attachment[];
  addedAt: string;
}
```

### 4.4 Tool Calls

```typescript
// src/types/tool.ts

interface ToolCall {
  id: string;
  name: string;                        // Tool name (Read, Write, Bash, etc.)
  input: Record<string, unknown>;
  output?: string;
  diff?: DiffHunk[];                   // Generated diff if applicable
  filePath?: string;                   // Target file path
  status: 'pending' | 'running' | 'completed' | 'error' | 'denied';
  error?: string;
  duration?: number;                   // Milliseconds
  riskLevel: 'low' | 'medium' | 'high'; // For permission UI
}

interface DiffHunk {
  oldStart: number;
  oldLines: number;
  newStart: number;
  newLines: number;
  content: string;                     // Unified diff text
  type: 'add' | 'remove' | 'context';
}

interface DiffFile {
  path: string;
  hunks: DiffHunk[];
  additions: number;
  deletions: number;
  status: 'added' | 'modified' | 'deleted' | 'renamed';
}
```

### 4.5 Permissions

```typescript
// src/types/permission.ts

interface PendingPermission {
  id: string;
  sessionId: string;
  toolCall: ToolCall;
  mode: PermissionMode;
  autoDenyAt?: string;                 // ISO timestamp (now + 5 min)
  autoDenyTimerMs?: number;
  isAutoDenying: boolean;
  response?: 'allow' | 'allow-session' | 'deny';
  respondedAt?: string;
}

interface PermissionRule {
  toolName: string;
  pattern?: string;                    // Glob pattern for file paths
  action: 'allow' | 'deny' | 'ask';
  scope: 'once' | 'session' | 'permanent';
}
```

### 4.6 Custom Agents

```typescript
// src/types/agent.ts

interface Agent {
  id: string;
  name: string;
  description: string;
  icon: string;                        // Lucide icon name
  color?: string;                      // Accent color
  systemPrompt: string;                // Custom system prompt
  model: ClaudeModel;
  effortLevel: EffortLevel;
  permissionMode: PermissionMode;
  permissions: AgentPermissionConfig;
  isBuiltIn: boolean;
  createdAt: string;
  updatedAt: string;
  runCount: number;
  lastRunAt?: string;
}

interface AgentPermissionConfig {
  fileRead: boolean;
  fileWrite: boolean;
  networkAccess: boolean;
  bashExecution: boolean;
  allowedPaths?: string[];             // Restrict to specific directories
  blockedPaths?: string[];             // Block specific directories
}

interface AgentExecution {
  id: string;
  agentId: string;
  projectId: string;
  sessionId: string;
  status: 'running' | 'completed' | 'failed' | 'cancelled';
  task: string;                        // The prompt/task given to the agent
  startedAt: string;
  completedAt?: string;
  duration?: number;                   // Milliseconds
  tokenCount: number;
  cost: number;
  output?: string;
  error?: string;
  logs: AgentLogEntry[];
}

interface AgentLogEntry {
  timestamp: string;
  level: 'info' | 'warn' | 'error' | 'debug';
  message: string;
  toolCalls?: ToolCall[];
}
```

### 4.7 Timeline & Checkpoints

```typescript
// src/types/checkpoint.ts

interface Checkpoint {
  id: string;
  sessionId: string;
  label: string;                       // Auto-generated or user-provided
  messageIndex: number;                // Index in message history
  messageCount: number;
  createdAt: string;
  gitCommitHash?: string;              // Associated git commit if applicable
  tokenSnapshot: number;
  costSnapshot: number;
  branchFromCheckpointId?: string;     // If this is a branch point
}

interface SessionTimeline {
  sessionId: string;
  checkpoints: Checkpoint[];
  branches: SessionBranch[];
}

interface SessionBranch {
  id: string;
  parentCheckpointId: string;
  childSessionId: string;              // Forked session ID
  label: string;
  createdAt: string;
}
```

### 4.8 MCP Servers

```typescript
// src/types/mcp.ts

interface MCPServer {
  id: string;
  name: string;
  type: 'stdio' | 'sse' | 'streamable-http';
  command?: string;                    // For stdio type
  args?: string[];                     // For stdio type
  url?: string;                        // For sse/streamable-http type
  env?: Record<string, string>;
  status: 'connected' | 'disconnected' | 'error' | 'testing';
  lastTestedAt?: string;
  importedFrom?: 'claude-desktop' | 'manual';
  isEnabled: boolean;
  error?: string;
}
```

### 4.9 Analytics

```typescript
// src/types/analytics.ts

interface UsageSummary {
  period: 'today' | '7d' | '30d' | 'all';
  totalCost: number;
  totalInputTokens: number;
  totalOutputTokens: number;
  totalMessages: number;
  totalSessions: number;
  byModel: ModelUsage[];
  byProject: ProjectUsage[];
  byDay: DailyUsage[];
  rateLimits: RateLimitInfo;
}

interface ModelUsage {
  model: ClaudeModel;
  cost: number;
  inputTokens: number;
  outputTokens: number;
  messageCount: number;
}

interface ProjectUsage {
  projectId: string;
  projectName: string;
  cost: number;
  tokens: number;
  sessionCount: number;
}

interface DailyUsage {
  date: string;
  cost: number;
  tokens: number;
  messages: number;
}

interface RateLimitInfo {
  fiveHourLimit: number;
  fiveHourUsed: number;
  fiveHourRemaining: number;
  sevenDayLimit: number;
  sevenDayUsed: number;
  sevenDayRemaining: number;
  contextWindowUsed: number;
  contextWindowMax: number;
  contextWindowPercent: number;
}
```

### 4.10 Settings

```typescript
// src/types/settings.ts

interface AppSettings {
  // General
  theme: ThemeName;
  accentColor: AccentColor;
  locale: Locale;
  fontSize: number;
  messageFontSize: number;
  focusModeEnabled: boolean;
  notificationsEnabled: boolean;
  
  // Claude CLI
  claudeCLIPath: string;               // Path to claude binary
  
  // Defaults
  defaultModel: ClaudeModel;
  defaultEffortLevel: EffortLevel;
  defaultPermissionMode: PermissionMode;
  
  // Permission
  autoDenyTimeoutMs: number;           // Default: 300000 (5 minutes)
  permissionRules: PermissionRule[];
  
  // Attachments
  autoPreviewUrls: boolean;
  autoPreviewPaths: boolean;
  autoPreviewImages: boolean;
  autoPreviewLongText: boolean;
  
  // Terminal
  terminalFontSize: number;
  terminalTheme: 'light' | 'dark' | 'system';
  terminalCursorStyle: 'block' | 'underline' | 'bar';
  
  // Update
  autoUpdateEnabled: boolean;
  checkForUpdatesOnLaunch: boolean;
  
  // Keyboard
  customShortcuts: KeyboardShortcut[];
}

type ThemeName = 'light' | 'dark' | 'system';
type AccentColor = 'blue' | 'purple' | 'green' | 'red' | 'orange' | 'teal';
type Locale = 'en' | 'ko' | 'zh-CN' | 'zh-TW' | 'ja' | 'es';

interface KeyboardShortcut {
  id: string;
  action: string;                      // Action identifier
  keys: string;                        // e.g., "Cmd+Shift+K"
  enabled: boolean;
}
```

---

## 5. Services & API Layer

### 5.1 Claude CLI Bridge (Rust Backend)

```rust
// src-tauri/src/commands/claude.rs

use tauri::command;
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;

pub struct ClaudeProcessManager {
    processes: Mutex<HashMap<String, Child>>,
}

#[command]
pub async fn spawn_claude_session(
    project_path: String,
    model: String,
    effort_level: String,
    permission_mode: String,
    system_prompt: Option<String>,
) -> Result<String, String> {
    // Spawn: claude --model <model> --effort <level> --permission-mode <mode>
    //        --output-format stream-json
    //        --project-dir <path>
    // Returns session process ID
}

#[command]
pub async fn send_message_to_session(
    session_id: String,
    message: String,
    attachments: Vec<AttachmentPayload>,
) -> Result<(), String> {
    // Send message to the running Claude CLI stdin
}

#[command]
pub async fn stop_session(session_id: String) -> Result<(), String> {
    // Kill the Claude CLI child process
}

#[command]
pub async fn resume_session(
    session_id: String,
    project_path: String,
) -> Result<String, String> {
    // claude --resume <session_id> --project-dir <path>
}

#[command]
pub async fn fork_from_message(
    session_id: String,
    message_index: usize,
    project_path: String,
) -> Result<String, String> {
    // Fork conversation from a specific message
}

#[command]
pub async fn list_sessions(
    project_path: String,
) -> Result<Vec<SessionInfo>, String> {
    // claude --output-format json --list-sessions
}
```

### 5.2 File System Service

```rust
// src-tauri/src/commands/fs.rs

#[command]
pub async fn read_file(path: String) -> Result<String, String> { }
#[command]
pub async fn write_file(path: String, content: String) -> Result<(), String> { }
#[command]
pub async fn list_directory(path: String, show_hidden: bool) -> Result<Vec<FileEntry>, String> { }
#[command]
pub async fn search_files(root: String, query: String) -> Result<Vec<SearchResult>, String> { }
#[command]
pub async fn watch_file(path: String) -> Result<(), String> { }
```

### 5.3 Git Service

```rust
// src-tauri/src/commands/git.rs

#[command]
pub async fn git_status(path: String) -> Result<GitStatus, String> { }
#[command]
pub async fn git_branches(path: String) -> Result<Vec<BranchInfo>, String> { }
#[command]
pub async fn git_checkout(path: String, branch: String) -> Result<(), String> { }
#[command]
pub async fn git_diff(path: String, staged: bool) -> Result<String, String> { }
#[command]
pub async fn git_commit(path: String, message: String) -> Result<String, String> { }
#[command]
pub async fn git_clone(url: String, dest: String, auth_token: Option<String>) -> Result<(), String> { }
#[command]
pub async fn github_oauth_device_flow() -> Result<OAuthResult, String> { }
#[command]
pub async fn github_setup_ssh_key() -> Result<(), String> { }
```

### 5.4 Terminal PTY Service

```rust
// src-tauri/src/commands/terminal.rs

#[command]
pub async fn terminal_spawn(
    project_path: String,
    shell: Option<String>,
) -> Result<String, String> {
    // Spawn a PTY process (using portable-pty or similar)
}

#[command]
pub async fn terminal_input(pty_id: String, data: String) -> Result<(), String> { }
#[command]
pub async fn terminal_resize(pty_id: String, cols: u16, rows: u16) -> Result<(), String> { }
#[command]
pub async fn terminal_kill(pty_id: String) -> Result<(), String> { }
```

### 5.5 MCP Server Service

```rust
// src-tauri/src/commands/mcp.rs

#[command]
pub async fn mcp_list_servers() -> Result<Vec<MCPServerConfig>, String> { }
#[command]
pub async fn mcp_add_server(config: MCPServerConfig) -> Result<(), String> { }
#[command]
pub async fn mcp_remove_server(id: String) -> Result<(), String> { }
#[command]
pub async fn mcp_test_connection(id: String) -> Result<MCPTestResult, String> { }
#[command]
pub async fn mcp_import_from_claude_desktop() -> Result<Vec<MCPServerConfig>, String> { }
```

### 5.6 Analytics Service

```rust
// src-tauri/src/commands/analytics.rs

#[command]
pub async fn analytics_get_summary(
    period: String,
) -> Result<UsageSummary, String> {
    // Aggregate from SQLite stored usage data
}

#[command]
pub async fn analytics_get_by_model(period: String) -> Result<Vec<ModelUsage>, String> { }
#[command]
pub async fn analytics_get_by_project(period: String) -> Result<Vec<ProjectUsage>, String> { }
#[command]
pub async fn analytics_get_daily(period: String) -> Result<Vec<DailyUsage>, String> { }
#[command]
pub async fn analytics_export_csv(period: String) -> Result<String, String> { }
```

### 5.7 Frontend Tauri Invocations

```typescript
// src/lib/tauri.ts

import { invoke } from '@tauri-apps/api/core';

// Claude CLI
export const spawnSession = (args: SpawnSessionArgs) =>
  invoke<string>('spawn_claude_session', args);

export const sendMessage = (sessionId: string, message: string, attachments: Attachment[]) =>
  invoke<void>('send_message_to_session', { sessionId, message, attachments });

export const stopSession = (sessionId: string) =>
  invoke<void>('stop_session', { sessionId });

// Files
export const readFile = (path: string) =>
  invoke<string>('read_file', { path });

export const writeFile = (path: string, content: string) =>
  invoke<void>('write_file', { path, content });

// Git
export const gitStatus = (path: string) =>
  invoke<GitStatus>('git_status', { path });

// Terminal
export const terminalSpawn = (projectPath: string) =>
  invoke<string>('terminal_spawn', { projectPath });

// MCP
export const mcpTestConnection = (serverId: string) =>
  invoke<MCPTestResult>('mcp_test_connection', { id: serverId });

// ... (all other invocations follow the same pattern)
```

---

## 6. State Management

### 6.1 App Store

```typescript
// src/stores/appStore.ts

import { create } from 'zustand';
import { persist } from 'zustand/middleware';

interface AppState {
  // Theme
  theme: ThemeName;
  accentColor: AccentColor;
  setTheme: (theme: ThemeName) => void;
  setAccentColor: (color: AccentColor) => void;
  
  // Locale
  locale: Locale;
  setLocale: (locale: Locale) => void;
  
  // Font
  fontSize: number;
  messageFontSize: number;
  setFontSize: (size: number) => void;
  setMessageFontSize: (size: number) => void;
  
  // Layout
  focusMode: boolean;
  inspectorVisible: boolean;
  inspectorTab: 'files' | 'git' | 'terminal' | 'memo';
  toggleFocusMode: () => void;
  toggleInspector: () => void;
  setInspectorTab: (tab: InspectorTab) => void;
  
  // Notifications
  notificationsEnabled: boolean;
  setNotificationsEnabled: (enabled: boolean) => void;
  
  // Settings
  settings: AppSettings;
  updateSettings: (partial: Partial<AppSettings>) => void;
}

export const useAppStore = create<AppState>()(
  persist(
    (set) => ({
      theme: 'system',
      accentColor: 'blue',
      locale: 'en',
      fontSize: 14,
      messageFontSize: 14,
      focusMode: false,
      inspectorVisible: true,
      inspectorTab: 'files',
      notificationsEnabled: true,
      settings: defaultSettings,
      
      setTheme: (theme) => set({ theme }),
      setAccentColor: (accentColor) => set({ accentColor }),
      setLocale: (locale) => set({ locale }),
      setFontSize: (fontSize) => set({ fontSize }),
      setMessageFontSize: (messageFontSize) => set({ messageFontSize }),
      toggleFocusMode: () => set((s) => ({ focusMode: !s.focusMode })),
      toggleInspector: () => set((s) => ({ inspectorVisible: !s.inspectorVisible })),
      setInspectorTab: (inspectorTab) => set({ inspectorTab }),
      setNotificationsEnabled: (notificationsEnabled) => set({ notificationsEnabled }),
      updateSettings: (partial) =>
        set((s) => ({ settings: { ...s.settings, ...partial } })),
    }),
    { name: 'freebuff-app' }
  )
);
```

### 6.2 Chat Store (Streaming)

```typescript
// src/stores/chatStore.ts

import { create } from 'zustand';

interface ChatState {
  // Messages
  messages: Message[];
  addMessage: (message: Message) => void;
  updateMessage: (id: string, update: Partial<Message>) => void;
  
  // Streaming
  isStreaming: boolean;
  streamingMessageId: string | null;
  streamingContent: string;
  setStreaming: (isStreaming: boolean, messageId?: string) => void;
  appendStreamContent: (chunk: string) => void;
  
  // Queue
  queue: QueuedMessage[];
  addToQueue: (message: string, attachments: Attachment[]) => void;
  removeFromQueue: (id: string) => void;
  dequeueNext: () => QueuedMessage | undefined;
  clearQueue: () => void;
  
  // Thinking
  expandedThinking: Set<string>;
  toggleThinking: (messageId: string) => void;
  
  // Tool calls
  expandedToolCalls: Set<string>;
  toggleToolCall: (toolCallId: string) => void;
  
  // Clear
  clearMessages: () => void;
}
```

### 6.3 Permission Store

```typescript
// src/stores/permissionStore.ts

interface PermissionState {
  pendingPermissions: PendingPermission[];
  sessionAllowList: Map<string, string[]>; // toolName -> allowed patterns
  
  addPending: (permission: PendingPermission) => void;
  respond: (id: string, response: 'allow' | 'allow-session' | 'deny') => void;
  autoDeny: (id: string) => void;
  isAutoDenying: boolean;
  
  // Check if already allowed
  isPreAllowed: (toolName: string, pattern?: string) => boolean;
}
```

### 6.4 Timeline Store

```typescript
// src/stores/timelineStore.ts

interface TimelineState {
  checkpoints: Checkpoint[];
  branches: SessionBranch[];
  
  addCheckpoint: (sessionId: string, label?: string) => Promise<Checkpoint>;
  restoreCheckpoint: (checkpointId: string) => Promise<void>;
  deleteCheckpoint: (checkpointId: string) => Promise<void>;
  
  forkFromCheckpoint: (checkpointId: string) => Promise<string>; // new session ID
  
  getDiff: (fromId: string, toId: string) => Promise<DiffFile[]>;
}
```

---

## 7. UI Components — Complete Hierarchy

### 7.1 App Shell Layout

```tsx
// src/App.tsx

function App() {
  return (
    <ThemeProvider>
      <I18nextProvider>
        <AppShell>
          <Sidebar />                    {/* Left: projects, agents, settings */}
          <main className="flex-1 flex flex-col">
            <TopBar />                   {/* Toolbar: project, model, effort, permissions */}
            <div className="flex-1 flex">
              <ChatView />               {/* Center: main chat area */}
              <Inspector />              {/* Right: file tree, git, terminal, memo */}
            </div>
            <StatusBar />                {/* Bottom: path, model, limits, context, cost */}
          </main>
        </AppShell>
        <PermissionModals />             {/* Overlay: approval dialogs */}
        <CommandPalette />               {/* Overlay: Cmd+K slash commands */}
        <TerminalPopup />                {/* Overlay: interactive terminal sheet */}
        <ProjectWindows />               {/* Separate OS windows for projects */}
      </I18nextProvider>
    </ThemeProvider>
  );
}
```

### 7.2 Chat View Component Tree

```
ChatView
├── SessionToolbar
│   ├── ModelSelect (Opus/Sonnet/Haiku/1M/Plan)
│   ├── EffortSelect (Auto/Low/Medium/High/XHigh/Max)
│   ├── PermissionSelect (Ask/Accept Edits/Plan/Auto/Bypass)
│   ├── SessionActions (Pin/Rename/Complete/Fork/Delete)
│   └── AgentSelector (Pick custom agent for this session)
├── MessageList
│   ├── MessageBubble (role="user")
│   │   ├── UserAvatar
│   │   ├── MarkdownContent
│   │   ├── AttachmentChips
│   │   └── [ForkButton on hover]
│   ├── MessageBubble (role="assistant")
│   │   ├── AssistantAvatar
│   │   ├── ThinkingTrace (collapsible)
│   │   ├── MarkdownContent (with code blocks, tables, lists)
│   │   ├── ToolCallView (for each tool use)
│   │   │   ├── ToolName + Status badge
│   │   │   ├── Expandable detail panel
│   │   │   ├── DiffViewer (if file changes)
│   │   │   │   ├── FileHeader (path, additions/deletions)
│   │   │   │   └── DiffLines (red/green inline)
│   │   │   └── [ApprovalButtons if pending]
│   │   └── [ForkButton on hover]
│   ├── StreamingIndicator (while streaming)
│   └── ErrorBubble (if response failed)
├── MessageQueue (if messages queued)
│   ├── QueueItem (content preview + cancel button)
│   └── QueueClearAll
└── ChatInput
    ├── FileDropZone (wraps the entire input)
    │   ├── AttachmentChips (current attachments with remove)
    │   ├── TextInput (textarea with auto-resize)
    │   ├── AttachmentSettings toggle
    │   ├── SlashCommandMenu (triggered by /)
    │   └── SendButton (with message count indicator)
    └── StopButton (visible when streaming)
```

### 7.3 Inspector Panel Component Tree

```
Inspector
├── InspectorTabs (Files | Git | Terminal | Memo)
│
├── [Files Tab]
│   ├── SearchInput
│   ├── ToggleHiddenFiles
│   └── FileExplorer
│       ├── FileTreeNode (recursive)
│       │   ├── FileIcon
│       │   ├── FileName
│       │   └── [click → preview/edit]
│       └── FilePreview (syntax-highlighted)
│           ├── FileHeader (path, size)
│           ├── CodeBlock (highlighted content)
│           └── EditButton (opens inline editor)
│
├── [Git Tab]
│   ├── GitStatus
│   │   ├── BranchDisplay (current branch)
│   │   ├── ChangedFilesList (with counts)
│   │   └── BranchSwitcher (local + remote branches)
│   ├── GitDiffViewer (staged/unstaged)
│   └── CommitInput
│
├── [Terminal Tab]
│   └── EmbeddedTerminal (xterm.js instance)
│       ├── TerminalDisplay
│       ├── ResetButton
│       └── ShellSelector
│
└── [Memo Tab]
    └── MemoPad
        ├── RichTextToolbar (headings, bold, italic, lists, checkboxes, links)
        └── RichTextEditor (contenteditable or CodeMirror)
```

### 7.4 Permission Approval Modal

```
ApprovalModal (overlay)
├── ToolCallHeader
│   ├── ToolIcon
│   ├── ToolName ("Read file", "Write file", "Run command")
│   └── RiskBadge (low/medium/high with color)
├── DiffPreview
│   ├── FilePath
│   └── DiffViewer (what will change)
├── ContextInfo
│   ├── ProjectPath
│   ├── SessionInfo
│   └── TimeRemaining (auto-deny countdown)
└── ActionButtons
    ├── Allow (this single action)
    ├── Allow Session (remember for session)
    ├── Deny (block this action)
    └── AutoDenyTimer (5-minute countdown bar)
```

---

## 8. Feature Modules — Detailed Specs

### 8.1 Streaming Chat Engine

```typescript
// src/hooks/useStreaming.ts

/**
 * Core streaming hook that manages Claude CLI process communication.
 * Handles stdout streaming in stream-json format, parses messages,
 * tool calls, thinking traces, and error events in real-time.
 */

function useStreaming(sessionId: string) {
  const {
    addMessage,
    updateMessage,
    setStreaming,
    appendStreamContent,
    addPending,
  } = useChatStore();
  
  // Listen for events from Rust backend via Tauri events
  useEffect(() => {
    const unlisten = listen<ClaudeEvent>('claude-event', (event) => {
      const { type, payload } = event.payload;
      
      switch (type) {
        case 'assistant-text':
          appendStreamContent(payload.text);
          break;
          
        case 'assistant-message-complete':
          addMessage({
            role: 'assistant',
            content: payload.content,
            thinking: payload.thinking,
            toolCalls: payload.toolCalls,
            tokenCount: payload.tokenCount,
            cost: payload.cost,
          });
          setStreaming(false);
          break;
          
        case 'tool-use':
          // Tool call detected — show in message
          break;
          
        case 'tool-result':
          // Tool completed — update status
          break;
          
        case 'permission-request':
          // Approval needed — show modal
          addPending(payload);
          break;
          
        case 'error':
          // Error response
          break;
          
        case 'session-complete':
          // Stream ended
          setStreaming(false);
          processQueuedMessage();
          break;
      }
    });
    
    return () => unlisten.then((fn) => fn());
  }, [sessionId]);
  
  return { sendMessage, stopGeneration, isStreaming };
}
```

### 8.2 Conversation Forking (from Clarc)

```typescript
// Conversation forking: hover any assistant message → "Fork from here"
// Creates a new session that branches from that message point.
// The original session remains untouched.

async function forkFromMessage(sessionId: string, messageIndex: number) {
  const newSessionId = await invoke('fork_from_message', {
    sessionId,
    messageIndex,
  });
  
  // Create checkpoint at fork point
  await timelineStore.addCheckpoint(
    sessionId,
    `Forked to ${newSessionId}`
  );
  
  // Navigate to new session
  navigateToSession(newSessionId);
}
```

### 8.3 Custom AI Agents (from Opcode)

```typescript
// src/components/agents/AgentEditor.tsx

// Agent creation/editing form:
// - Name, description, icon, color
// - System prompt (large textarea)
// - Model selection
// - Effort level
// - Permission mode
// - Permission config (file read/write, network, bash)
// - Allowed/blocked paths

async function createAgent(agent: Omit<Agent, 'id' | 'createdAt' | 'runCount'>) {
  await invoke('create_agent', { agent });
  agentStore.addAgent(result);
}

async function runAgent(
  agentId: string,
  projectId: string,
  task: string
) {
  // Spawns Claude CLI with the agent's system prompt,
  // model, and permission settings in a background process
  const execution = await invoke<AgentExecution>('run_agent', {
    agentId,
    projectId,
    task,
  });
  
  // Track execution status and logs in real-time
  agentStore.trackExecution(execution);
}
```

### 8.4 Timeline & Checkpoints (from Opcode)

```typescript
// src/components/timeline/TimelineView.tsx

// Visual timeline displayed alongside or below the chat.
// Shows checkpoints as nodes on a vertical line.
// Branching points show diverging lines.

function TimelineView({ sessionId }: { sessionId: string }) {
  const { checkpoints, branches } = useTimelineStore();
  
  return (
    <div className="timeline-container">
      {checkpoints.map((cp) => (
        <CheckpointNode
          key={cp.id}
          checkpoint={cp}
          isBranchPoint={branches.some(b => b.parentCheckpointId === cp.id)}
          onRestore={() => restoreCheckpoint(cp.id)}
          onDiff={() => showDiffFromCheckpoint(cp.id)}
          onFork={() => forkFromCheckpoint(cp.id)}
          onDelete={() => deleteCheckpoint(cp.id)}
        />
      ))}
    </div>
  );
}

// Diff between checkpoints
async function getCheckpointDiff(fromId: string, toId: string) {
  const diffFiles = await invoke<DiffFile[]>('checkpoint_diff', {
    fromCheckpointId: fromId,
    toCheckpointId: toId,
  });
  
  // Render with DiffViewer component showing file-by-file inline diffs
  return diffFiles;
}
```

### 8.5 Usage Analytics Dashboard (from Opcode)

```typescript
// src/components/analytics/UsageDashboard.tsx

function UsageDashboard() {
  const [period, setPeriod] = useState<'today' | '7d' | '30d' | 'all'>('7d');
  const { data: summary } = useQuery({
    queryKey: ['analytics', period],
    queryFn: () => invoke<UsageSummary>('analytics_get_summary', { period }),
  });
  
  return (
    <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
      {/* Summary Cards */}
      <CostCard cost={summary.totalCost} period={period} />
      <TokenCard tokens={summary.totalInputTokens + summary.totalOutputTokens} />
      <SessionCard sessions={summary.totalSessions} />
      <MessageCard messages={summary.totalMessages} />
      
      {/* Charts */}
      <div className="col-span-2">
        <UsageChart data={summary.byDay} />
      </div>
      <div className="col-span-2">
        <ModelBreakdown data={summary.byModel} />
      </div>
      
      {/* Project Breakdown */}
      <div className="col-span-full">
        <ProjectBreakdown data={summary.byProject} />
      </div>
      
      {/* Rate Limits */}
      <RateLimitGauge limits={summary.rateLimits} />
      
      {/* Export */}
      <ExportButton period={period} onExport={handleExport} />
    </div>
  );
}
```

### 8.6 MCP Server Management (from Opcode)

```typescript
// src/components/mcp/MCPManager.tsx

function MCPManager() {
  const { servers, addServer, removeServer, testConnection, importFromDesktop } = useMCPStore();
  
  return (
    <div>
      <div className="flex justify-between">
        <h2>MCP Servers</h2>
        <div>
          <Button onClick={() => showAddDialog()}>Add Server</Button>
          <Button onClick={importFromDesktop} variant="outline">
            Import from Claude Desktop
          </Button>
        </div>
      </div>
      
      {servers.map((server) => (
        <ServerCard
          key={server.id}
          server={server}
          onTest={() => testConnection(server.id)}
          onRemove={() => removeServer(server.id)}
          onToggle={() => toggleServer(server.id)}
        />
      ))}
    </div>
  );
}
```

### 8.7 CLAUDE.md Editor (from Opcode)

```typescript
// src/components/editor/ClaudeMDEditor.tsx

// Split-pane editor: left = markdown source, right = live preview
// Syntax highlighting for markdown
// Auto-save on change
// Project scanner to find all CLAUDE.md files

function ClaudeMDEditor({ projectPath }: { projectPath: string }) {
  const [content, setContent] = useState('');
  const [showPreview, setShowPreview] = useState(true);
  
  // Auto-load the CLAUDE.md from project root
  useEffect(() => {
    readFile(join(projectPath, 'CLAUDE.md')).then(setContent);
  }, [projectPath]);
  
  // Auto-save with debounce
  const debouncedSave = useMemo(
    () => debounce((val: string) => writeFile(join(projectPath, 'CLAUDE.md'), val), 500),
    [projectPath]
  );
  
  return (
    <div className="flex h-full">
      <div className="flex-1">
        <MarkdownEditor
          value={content}
          onChange={(val) => { setContent(val); debouncedSave(val); }}
          language="markdown"
        />
      </div>
      {showPreview && (
        <div className="flex-1 border-l">
          <LivePreview content={content} />
        </div>
      )}
    </div>
  );
}

// Project scanner: finds all CLAUDE.md files
async function scanForClaudeMD(projectPaths: string[]) {
  const results = await invoke<{ path: string; exists: boolean }[]>(
    'scan_claude_md',
    { paths: projectPaths }
  );
  return results;
}
```

### 8.8 Slash Commands & Shortcuts (from Clarc)

```typescript
// Built-in commands (editable):
// /help, /clear, /compact, /config, /cost, /doctor,
// /init, /login, /logout, /memory, /model, /permissions,
// /review, /status, /vim, /terminal

// Custom commands: user-defined with name, prompt template, description
// JSON import/export for sharing

interface SlashCommand {
  id: string;
  name: string;                        // Command name (without /)
  description: string;
  prompt: string;                      // Prompt template with {{args}} placeholders
  isBuiltIn: boolean;
  isEnabled: boolean;
  isEditable: boolean;                 // Built-in commands are toggleable, not deletable
  category: 'built-in' | 'custom';
}

// Shortcut buttons: quick-access buttons below the input bar
interface Shortcut {
  id: string;
  name: string;
  type: 'prompt' | 'terminal';
  prompt?: string;                     // For prompt type
  command?: string;                    // For terminal type (launches terminal popup)
  icon?: string;
  color?: string;
  order: number;
}
```

### 8.9 GitHub OAuth & SSH Key Setup (from Clarc)

```typescript
// Full OAuth device flow for GitHub:
// 1. Request device code via GitHub API
// 2. Show user the code + verification URL
// 3. Poll for completion
// 4. Store token in OS keychain
// 5. Auto-generate SSH key if none exists
// 6. Upload public key to GitHub

async function githubOAuthFlow() {
  // Step 1: Device code
  const { deviceCode, userCode, verificationUrl } = await invoke('github_oauth_start');
  
  // Step 2: Show UI to user
  showOAuthDialog({ userCode, verificationUrl });
  
  // Step 3: Poll (handled by Rust backend)
  const result = await invoke<OAuthResult>('github_oauth_poll', { deviceCode });
  
  // Step 4: Store token
  await invoke('keychain_store', {
    service: 'freebuff-github',
    account: 'oauth-token',
    value: result.accessToken,
  });
  
  // Step 5-6: Setup SSH key
  await invoke('github_setup_ssh_key');
}
```

### 8.10 Embedded Terminal (from Clarc, cross-platform)

```typescript
// Uses xterm.js for cross-platform terminal emulation
// The Rust backend spawns a PTY process using the portable-pty crate

function EmbeddedTerminal({ projectPath }: { projectPath: string }) {
  const terminalRef = useRef<HTMLDivElement>(null);
  const xtermRef = useRef<Terminal | null>(null);
  const ptyIdRef = useRef<string | null>(null);
  
  useEffect(() => {
    // Initialize xterm.js
    const terminal = new Terminal({
      fontSize: settings.terminalFontSize,
      theme: terminalTheme,
      cursorStyle: settings.terminalCursorStyle,
      fontFamily: 'Menlo, Monaco, "Courier New", monospace',
    });
    
    terminal.open(terminalRef.current!);
    xtermRef.current = terminal;
    
    // Spawn PTY process via Tauri
    invoke<string>('terminal_spawn', { projectPath }).then((id) => {
      ptyIdRef.current = id;
    });
    
    // Forward terminal input to PTY
    terminal.onData((data) => {
      if (ptyIdRef.current) {
        invoke('terminal_input', { ptyId: ptyIdRef.current, data });
      }
    });
    
    // Listen for PTY output
    const unlisten = listen<{ id: string; data: string }>(
      'terminal-output',
      (event) => {
        if (event.payload.id === ptyIdRef.current) {
          terminal.write(event.payload.data);
        }
      }
    );
    
    return () => {
      unlisten.then((fn) => fn());
      if (ptyIdRef.current) {
        invoke('terminal_kill', { ptyId: ptyIdRef.current });
      }
      terminal.dispose();
    };
  }, [projectPath]);
  
  return <div ref={terminalRef} className="w-full h-full" />;
}
```

### 8.11 Rich-Text Memo Pad (from Clarc)

```typescript
// Per-project memo with rich-text editing
// Supports: headings, lists, checkboxes, links, bold, italic
// Markdown copy/paste support
// Persisted to SQLite

function MemoPad({ projectPath }: { projectPath: string }) {
  const [content, setContent] = useState('');
  
  // Load from DB on mount
  useEffect(() => {
    invoke<string>('memo_load', { projectPath }).then(setContent);
  }, [projectPath]);
  
  // Auto-save on change
  const debouncedSave = useMemo(
    () => debounce((val: string) => invoke('memo_save', { projectPath, content: val }), 500),
    [projectPath]
  );
  
  return (
    <div className="memo-pad h-full flex flex-col">
      <div className="flex items-center gap-1 px-2 py-1 border-b">
        <ToolbarButton icon="heading" onClick={() => insertMarkdown('## ')} />
        <ToolbarButton icon="bold" onClick={() => wrapSelection('**')} />
        <ToolbarButton icon="italic" onClick={() => wrapSelection('*')} />
        <ToolbarButton icon="list" onClick={() => insertMarkdown('- ')} />
        <ToolbarButton icon="check-square" onClick={() => insertMarkdown('- [ ] ')} />
        <ToolbarButton icon="link" onClick={() => insertLink()} />
      </div>
      <textarea
        className="flex-1 p-3 resize-none font-mono text-sm"
        value={content}
        onChange={(e) => { setContent(e.target.value); debouncedSave(e.target.value); }}
        placeholder="Project notes..."
      />
    </div>
  );
}
```

### 8.12 Skill Marketplace (from Clarc)

```typescript
// Browse and install official Anthropic plugins
// Fetched from Anthropic's plugin registry with 5-minute cache

function SkillMarketplace() {
  const { data: skills, isLoading } = useQuery({
    queryKey: ['skills'],
    queryFn: () => invoke<Skill[]>('fetch_skill_marketplace'),
    staleTime: 5 * 60 * 1000, // 5-minute cache
  });
  
  return (
    <div className="skill-marketplace">
      <h2>Skill Marketplace</h2>
      {skills?.map((skill) => (
        <SkillCard
          key={skill.id}
          skill={skill}
          onInstall={() => installSkill(skill.id)}
          installed={isInstalled(skill.id)}
        />
      ))}
    </div>
  );
}
```

### 8.13 Message Queue (from Clarc)

```typescript
// Queue messages while Claude is responding
// Press ESC or click remove to cancel queued items
// Queued messages auto-send when current response completes

function MessageQueue({ queue, onRemove, onClearAll }) {
  if (queue.length === 0) return null;
  
  return (
    <div className="message-queue px-4 py-2 bg-muted/50 border-t">
      <div className="flex items-center justify-between mb-1">
        <span className="text-xs text-muted-foreground">
          {queue.length} queued
        </span>
        <Button variant="ghost" size="xs" onClick={onClearAll}>
          Clear all
        </Button>
      </div>
      {queue.map((msg) => (
        <div key={msg.id} className="flex items-center gap-2 text-sm">
          <span className="flex-1 truncate">{msg.content}</span>
          <Button
            variant="ghost"
            size="xs"
            onClick={() => onRemove(msg.id)}
          >
            <X size={12} />
          </Button>
        </div>
      ))}
    </div>
  );
}
```

### 8.14 Project Windows (from Clarc)

```typescript
// Double-click a project tab to open it in a separate OS window
// Each window has its own chat session, inspector, and terminal
// Background streams keep running when switching windows

async function openProjectWindow(projectId: string) {
  // Create a new Tauri window via the Rust backend
  await invoke('create_project_window', { projectId });
  
  // The new window renders the same App component
  // but scoped to the specific project via URL params
  // e.g., tauri://localhost/?project={projectId}
}
```

### 8.15 Notification System (from Clarc)

```typescript
// System notifications with response previews
// Shows when Clarc is in the background
// Click notification to bring app to focus

function useNotifications() {
  const { notificationsEnabled } = useAppStore();
  
  useEffect(() => {
    if (!notificationsEnabled) return;
    
    const unlisten = listen<{ title: string; body: string; sessionId: string }>(
      'notification-trigger',
      (event) => {
        sendNotification({
          title: event.payload.title,
          body: event.payload.body,
          onClick: () => {
            appWindow.setFocus();
            navigateToSession(event.payload.sessionId);
          },
        });
      }
    );
    
    return () => unlisten.then((fn) => fn());
  }, [notificationsEnabled]);
}
```

### 8.16 Localization (from Clarc)

```typescript
// Full UI translation for 6 languages
// Uses react-i18next

// src/i18n/en.json (excerpt)
{
  "app": {
    "title": "Freebuff",
    "sidebar": {
      "projects": "Projects",
      "agents": "Agents",
      "settings": "Settings"
    },
    "chat": {
      "placeholder": "Message Claude...",
      "send": "Send",
      "stop": "Stop",
      "queue": "{{count}} queued",
      "fork": "Fork from here"
    },
    "permissions": {
      "allow": "Allow",
      "allowSession": "Allow for Session",
      "deny": "Deny",
      "autoDenyIn": "Auto-deny in {{seconds}}s"
    },
    "sessions": {
      "pin": "Pin",
      "rename": "Rename",
      "complete": "Mark Complete",
      "delete": "Delete",
      "fork": "Fork Session"
    },
    "inspector": {
      "files": "Files",
      "git": "Git",
      "terminal": "Terminal",
      "memo": "Notes"
    },
    "analytics": {
      "cost": "Cost",
      "tokens": "Tokens",
      "sessions": "Sessions",
      "export": "Export Data"
    }
  }
}
```

### 8.17 Focus Mode (from Clarc)

```typescript
// Simplified chat layout that hides:
// - Sidebar
// - Inspector
// - Status bar
// Shows only: top bar + chat messages + input

function ChatView() {
  const { focusMode } = useAppStore();
  
  return (
    <div className={cn(
      "flex flex-col h-full",
      focusMode && "max-w-3xl mx-auto"
    )}>
      {!focusMode && <SessionToolbar />}
      <MessageList />
      <ChatInput />
    </div>
  );
}
```

### 8.18 Auto-Deny Timer (from Clarc)

```typescript
// 5-minute countdown for permission requests
// Visual progress bar that depletes
// Auto-deniwhen timer reaches zero

function AutoDenyTimer({ permission }: { permission: PendingPermission }) {
  const [remaining, setRemaining] = useState(
    new Date(permission.autoDenyAt!).getTime() - Date.now()
  );
  
  useEffect(() => {
    const interval = setInterval(() => {
      const left = new Date(permission.autoDenyAt!).getTime() - Date.now();
      if (left <= 0) {
        permissionStore.autoDeny(permission.id);
        clearInterval(interval);
      } else {
        setRemaining(left);
      }
    }, 100);
    
    return () => clearInterval(interval);
  }, [permission.autoDenyAt]);
  
  const progress = remaining / (5 * 60 * 1000);
  
  return (
    <div className="flex items-center gap-2">
      <Progress value={progress * 100} className="h-1 flex-1" />
      <span className="text-xs text-muted-foreground">
        {Math.ceil(remaining / 1000)}s
      </span>
    </div>
  );
}
```

---

## 9. Styling & Themes

### 9.1 Theme System

```typescript
// src/styles/themes.ts

const themes = {
  light: {
    background: '#ffffff',
    foreground: '#0a0a0a',
    card: '#ffffff',
    cardForeground: '#0a0a0a',
    popover: '#ffffff',
    popoverForeground: '#0a0a0a',
    primary: '#171717',
    primaryForeground: '#fafafa',
    secondary: '#f5f5f5',
    secondaryForeground: '#171717',
    muted: '#f5f5f5',
    mutedForeground: '#737373',
    accent: '#f5f5f5',
    accentForeground: '#171717',
    destructive: '#ef4444',
    destructiveForeground: '#fafafa',
    border: '#e5e5e5',
    input: '#e5e5e5',
    ring: '#0a0a0a',
    diff: {
      addition: '#dcfce7',
      additionText: '#166534',
      deletion: '#fee2e2',
      deletionText: '#991b1b',
    },
  },
  dark: {
    background: '#0a0a0a',
    foreground: '#fafafa',
    card: '#0a0a0a',
    cardForeground: '#fafafa',
    popover: '#0a0a0a',
    popoverForeground: '#fafafa',
    primary: '#fafafa',
    primaryForeground: '#171717',
    secondary: '#262626',
    secondaryForeground: '#fafafa',
    muted: '#262626',
    mutedForeground: '#a3a3a3',
    accent: '#262626',
    accentForeground: '#fafafa',
    destructive: '#7f1d1d',
    destructiveForeground: '#fafafa',
    border: '#262626',
    input: '#262626',
    ring: '#d4d4d4',
    diff: {
      addition: '#052e16',
      additionText: '#86efac',
      deletion: '#450a0a',
      deletionText: '#fca5a5',
    },
  },
};

// Accent colors override the `ring` and `accent` values
const accentColors = {
  blue:   { ring: '#3b82f6', accent: '#eff6ff' },
  purple: { ring: '#a855f7', accent: '#faf5ff' },
  green:  { ring: '#22c55e', accent: '#f0fdf4' },
  red:    { ring: '#ef4444', accent: '#fef2f2' },
  orange: { ring: '#f97316', accent: '#fff7ed' },
  teal:   { ring: '#14b8a6', accent: '#f0fdfa' },
};
```

### 9.2 Font Configuration

```typescript
// src/styles/fonts.ts

const fontSizes = {
  interface: [12, 13, 14, 15, 16, 18],     // UI elements
  messages: [12, 13, 14, 15, 16, 18, 20],   // Chat messages
  terminal: [12, 13, 14, 15, 16],           // Terminal
};

const fontFamily = {
  interface: '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif',
  messages: 'ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace',
  terminal: 'ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace',
};
```

---

## 10. Build & Configuration

### 10.1 Tauri Configuration

```json
// src-tauri/tauri.conf.json

{
  "$schema": "https://raw.githubusercontent.com/nickelpack/tauri/dev/crates/tauri-cli/schema.json",
  "productName": "Freebuff",
  "version": "1.0.0",
  "identifier": "com.freebuff.app",
  "build": {
    "frontendDist": "../dist",
    "devUrl": "http://localhost:5173",
    "beforeDevCommand": "bun run dev",
    "beforeBuildCommand": "bun run build"
  },
  "app": {
    "windows": [
      {
        "title": "Freebuff",
        "width": 1400,
        "height": 900,
        "minWidth": 800,
        "minHeight": 600,
        "decorations": true,
        "transparent": false,
        "resizable": true,
        "center": true
      }
    ],
    "security": {
      "csp": "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' blob: data: https:; connect-src 'self' https://github.com https://api.github.com; font-src 'self' data:"
    }
  },
  "bundle": {
    "active": true,
    "icon": [
      "icons/32x32.png",
      "icons/128x128.png",
      "icons/128x128@2x.png",
      "icons/icon.icns",
      "icons/icon.ico"
    ],
    "targets": "all",
    "macOS": {
      "minimumSystemVersion": "11.0"
    }
  },
  "plugins": {
    "shell": {
      "open": true,
      "scope": [
        {
          "name": "claude",
          "cmd": "claude",
          "args": true,
          "sidecar": false
        }
      ]
    },
    "notification": {
      "enabled": true
    }
  }
}
```

### 10.2 package.json

```json
{
  "name": "freebuff",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "tsc && vite build",
    "preview": "vite preview",
    "tauri": "tauri",
    "typecheck": "tsc --noEmit",
    "lint": "eslint src/ --ext .ts,.tsx"
  },
  "dependencies": {
    "@tauri-apps/api": "^2.0.0",
    "@tauri-apps/plugin-shell": "^2.0.0",
    "@tauri-apps/plugin-notification": "^2.0.0",
    "@tauri-apps/plugin-fs": "^2.0.0",
    "react": "^18.3.0",
    "react-dom": "^18.3.0",
    "react-router-dom": "^6.20.0",
    "zustand": "^4.5.0",
    "@tanstack/react-query": "^5.17.0",
    "react-i18next": "^14.0.0",
    "i18next": "^23.7.0",
    "react-markdown": "^9.0.0",
    "remark-gfm": "^4.0.0",
    "rehype-highlight": "^7.0.0",
    "rehype-raw": "^7.0.0",
    "diff2html": "^3.4.0",
    "recharts": "^2.10.0",
    "lucide-react": "^0.300.0",
    "@xterm/xterm": "^5.4.0",
    "@xterm/addon-fit": "^0.9.0",
    "@xterm/addon-web-links": "^0.11.0",
    "clsx": "^2.1.0",
    "tailwind-merge": "^2.2.0",
    "date-fns": "^3.3.0",
    "debounce": "^2.0.0",
    "highlight.js": "^11.9.0"
  },
  "devDependencies": {
    "@tauri-apps/cli": "^2.0.0",
    "@types/react": "^18.2.0",
    "@types/react-dom": "^18.2.0",
    "@types/node": "^20.11.0",
    "typescript": "^5.3.0",
    "vite": "^6.0.0",
    "@vitejs/plugin-react": "^4.2.0",
    "tailwindcss": "^4.0.0",
    "@tailwindcss/vite": "^4.0.0",
    "autoprefixer": "^10.4.0",
    "postcss": "^8.4.0",
    "eslint": "^8.56.0",
    "@typescript-eslint/eslint-plugin": "^6.19.0",
    "@typescript-eslint/parser": "^6.19.0"
  }
}
```

### 10.3 Cargo.toml (Rust Backend)

```toml
[package]
name = "freebuff"
version = "1.0.0"
edition = "2021"

[build-dependencies]
tauri-build = { version = "2", features = [] }

[dependencies]
tauri = { version = "2", features = ["shell-open"] }
tauri-plugin-shell = "2"
tauri-plugin-notification = "2"
tauri-plugin-fs = "2"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
rusqlite = { version = "0.31", features = ["bundled"] }
git2 = "0.18"
reqwest = { version = "0.12", features = ["json"] }
tokio = { version = "1", features = ["full"] }
keyring = "2"
notify = "6"
portable-pty = "0.8"
uuid = { version = "1", features = ["v4"] }
chrono = { version = "0.4", features = ["serde"] }
dirs = "5"
glob = "0.3"
thiserror = "1"
log = "0.4"
env_logger = "0.11"

[features]
default = ["custom-protocol"]
custom-protocol = ["tauri/custom-protocol"]
```

### 10.4 Vite Config

```typescript
// vite.config.ts

import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';
import path from 'path';

export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src'),
    },
  },
  // Tauri expects a fixed port
  server: {
    port: 5173,
    strictPort: true,
  },
  // Environment variables starting with TAURI_ are exposed
  envPrefix: ['VITE_', 'TAURI_'],
  build: {
    // Tauri uses Chromium on Windows and WebKit on macOS/Linux
    target: process.env.TAURI_PLATFORM === 'windows' ? 'chrome105' : 'safari13',
    minify: !process.env.TAURI_DEBUG ? 'esbuild' : false,
    sourcemap: !!process.env.TAURI_DEBUG,
  },
});
```

### 10.5 TypeScript Config

```json
// tsconfig.json

{
  "compilerOptions": {
    "target": "ES2021",
    "useDefineForClassFields": true,
    "lib": ["ES2021", "DOM", "DOM.Iterable"],
    "module": "ESNext",
    "skipLibCheck": true,
    "moduleResolution": "bundler",
    "allowImportingTsExtensions": true,
    "resolveJsonModule": true,
    "isolatedModules": true,
    "noEmit": true,
    "jsx": "react-jsx",
    "strict": true,
    "noUnusedLocals": true,
    "noUnusedParameters": true,
    "noFallthroughCasesInSwitch": true,
    "paths": {
      "@/*": ["./src/*"]
    }
  },
  "include": ["src"],
  "references": [{ "path": "./tsconfig.node.json" }]
}
```

---

## Complete Feature Checklist

> Every item below maps to a feature from Clarc, Opcode, or both. All must be implemented.

### From Both Apps (Aligned)

- [x] **Streaming Chat** — Real-time Claude CLI conversations with Markdown rendering
- [x] **Tool Call Visualization** — Show tool use in chat with expandable details
- [x] **Diff Viewer** — Inline red/green diffs for file changes
- [x] **Thinking Traces** — Expandable reasoning/thinking blocks
- [x] **Stop Button** — Visible cancel while streaming
- [x] **Error Bubbles** — Failed response display with retry
- [x] **Multi-Project Workspace** — Register local repos, switch between projects
- [x] **Session History** — View, resume, search past sessions
- [x] **Session Search** — Find sessions quickly
- [x] **File Explorer** — Browse project files in sidebar
- [x] **Git Status** — Branch display, changed file counts
- [x] **Model Selection** — Opus, Sonnet, Haiku, 1M context, Plan variants
- [x] **Permission Modes** — Ask, Accept Edits, Plan, Auto, Bypass
- [x] **Dark/Light Theme** — System-aware theme switching
- [x] **Markdown Input** — Rich message input with formatting

### From Clarc

- [x] **Approval Modals** — Diff preview before any tool runs, with Allow/Allow Session/Deny
- [x] **Per-Project Windows** — Double-click project tab → independent OS window
- [x] **Background Streams** — Sessions keep running when you switch projects/windows
- [x] **Drag-and-Drop Attachments** — Drop files and images into chat
- [x] **Smart Paste** — Detect images, file paths, URLs, long text from clipboard
- [x] **Attachment Auto-Preview** — Toggle preview chips for URLs, paths, images, text
- [x] **GitHub OAuth** — Device flow with SSH key auto-setup
- [x] **Session Management** — Pin, rename, complete (strikethrough), delete, batch multi-select
- [x] **Session Forking** — Fork conversation from any assistant message into new branch
- [x] **Per-Session Controls** — Model, permission mode, effort level per session from toolbar
- [x] **Effort Levels** — Auto, Low, Medium, High, XHigh, Max reasoning controls
- [x] **Custom Slash Commands** — Add, edit, disable, import (JSON), export
- [x] **Shortcut Buttons** — Quick-access buttons for frequent prompts and terminal commands
- [x] **Message Queue** — Queue messages while Claude responds, cancel with ESC
- [x] **Status Line** — Project path, model, rate limits (5h/7d), context usage, cost, response time
- [x] **Embedded Terminal** — Cross-platform terminal (xterm.js) with reset, interactive popup
- [x] **File Explorer Enhancements** — Search, hidden-file toggle, syntax preview, file editing, @path insertion
- [x] **Git Branch Switcher** — Switch local and remote branches from inspector
- [x] **Rich-Text Memo Pad** — Per-project notes with headings, lists, checkboxes, links
- [x] **Skill Marketplace** — Browse and install Anthropic plugins (5-min cache)
- [x] **Font Controls** — Independent font size for interface and message area
- [x] **6 Accent Themes** — Blue, purple, green, red, orange, teal
- [x] **Focus Mode** — Simplified chat-only layout
- [x] **System Notifications** — Background notifications with response previews
- [x] **Localization** — English, Korean, Simplified Chinese, Traditional Chinese, Japanese, Spanish
- [x] **User Guide** — Built-in in-app help
- [x] **Auto-Update** — Check for updates on launch and from menu

### From Opcode

- [x] **Custom AI Agents** — Create specialized agents with custom system prompts, model, permissions
- [x] **Agent Library** — Collection of purpose-built agents, browse and manage
- [x] **Background Agent Execution** — Run agents in separate processes, non-blocking
- [x] **Agent Execution History** — Detailed logs, performance metrics per run
- [x] **Agent Permissions** — Per-agent file read/write, network access, allowed/blocked paths
- [x] **Usage Analytics Dashboard** — Cost tracking, token analytics, visual charts, export
- [x] **Cost Tracking** — Real-time Claude API usage and cost monitoring
- [x] **Token Analytics** — Breakdown by model, project, and time period
- [x] **Usage Charts** — Visual charts showing usage trends (Recharts)
- [x] **Export Usage Data** — CSV export for accounting/analysis
- [x] **MCP Server Management** — Central UI for Model Context Protocol servers
- [x] **MCP Connection Testing** — Verify server connectivity before use
- [x] **Claude Desktop MCP Import** — Import server configs from Claude Desktop
- [x] **Timeline & Checkpoints** — Create checkpoints at any point in session
- [x] **Visual Timeline** — Branching timeline showing session evolution
- [x] **Instant Restore** — Jump back to any checkpoint with one click
- [x] **Checkpoint Diff** — See exactly what changed between checkpoints
- [x] **CLAUDE.md Editor** — Built-in editor with syntax highlighting
- [x] **Live Preview** — Real-time markdown rendering while editing CLAUDE.md
- [x] **CLAUDE.md Scanner** — Find all CLAUDE.md files across projects
- [x] **Session Insights** — First messages, timestamps, metadata at a glance
- [x] **SQLite Database** — Persistent local storage for all data

---

## Build Instructions

```bash
# Prerequisites
# 1. Rust (rustup)
# 2. Bun (curl -fsSL https://bun.sh/install | bash)
# 3. Claude Code CLI (npm install -g @anthropic-ai/claude-code)
# 4. Platform-specific: see Tauri prerequisites

# Clone and build
git clone <repo-url> freebuff
cd freebuff
bun install

# Development
bun run tauri dev

# Production build
bun run tauri build

# Output locations:
# macOS:   src-tauri/target/release/bundle/dmg/Freebuff.dmg
# Windows: src-tauri/target/release/bundle/msi/Freebuff.msi
# Linux:   src-tauri/target/release/bundle/deb/freebuff_1.0.0_amd64.deb
```

---

*Generated from analysis of [Clarc](https://github.com/ttnear/Clarc) v1.3.3 and [Opcode](https://github.com/winfunc/opcode) source repositories. All features from both apps are represented above.*
