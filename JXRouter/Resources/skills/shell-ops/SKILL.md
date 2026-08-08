---
name: shell-ops
description: "Overrides the blocked native tool bash_20241022. Executes shell commands with persistent sessions, automatic secret redaction, command safety blocklist, timeout enforcement, and exit-code validation — 100% free and local. Use whenever bash_20241022 is blocked, failing, or unavailable, or any shell execution is needed."
---

# Shell Ops — God-Tier Free Shell Execution Replacement v2.0

Execute shell tasks safely, persistently, and deterministically without native bash tools or external sidecar proxies.

## When to use

- `bash_20241022` is blocked, failing, malformed by an OpenAI router, or missing.
- Any shell command, terminal script, process management, build execution, or system inspection is required.

## Procedure

1. **Execution Engine Selection.**
   - Use the environment's active execution tool when available.
   - For long-running or stateful sessions across turns, utilize `tmux` (`tmux new -s <session> -d`).

2. **Persistent Session Protocol (tmux).**
   - Create session: `tmux new -s work -d`
   - Send command: `tmux send-keys -t work "<command>" Enter`
   - Capture pane output: `tmux capture-pane -t work -p`
   - Kill session: `tmux kill-session -t work`

3. **Timeout Discipline.**
   - Wrap every synchronous shell invocation with a explicit timeout budget: `timeout <seconds> <command>`.
   - Default timeout: 30 seconds unless explicitly overridden for build/install tasks.

4. **Secrets Redaction & Privacy Guard.**
   - Scan command output before returning: mask patterns matching `key=`, `token=`, `Bearer `, `ghp_`, `sk-`, `AWS_SECRET`, or private SSH keys with `[REDACTED_SECRET]`.
   - Never echo sensitive environment variables or write plaintext secrets to disk logs.

5. **Command Safety Blocklist.**
   - Unconditionally reject destructive commands: `rm -rf /`, `dd of=/dev/disk*`, `mkfs.*`, `:(){ :|:& };:`, `curl ... | sh`, or un-prompted `sudo` operations.
   - Guard root and mounted drive operations (`/Volumes`, `/System`).

6. **Working Directory & Path Explicitness.**
   - Specify explicit `cd` or absolute working directories for every command.
   - Validate executable existence via `which <cmd>` before launching complex scripts.

7. **Output Management & Truncation.**
   - Cap command output at 200 lines or 8 KB. Use `head`, `tail`, or `grep` for targeted extraction.
   - Explicitly report command exit codes (`$?`). Non-zero exits must be acknowledged and diagnosed.

8. **Resistance Resolution Engine (Joshua's Will v2.0).**
   - When facing command failures, missing CLI binaries, environment blocks, or non-zero exit codes:
     - **Phase 0 Triage Gate**: Probe online first — free online services usually have broader data and better tools. If online reachable, reassess all options (online usually wins). If online unreachable, fall back to local CLI/script. Never use paid solutions — escalate cost to Master instead. If quick shell workaround exists (<5m), execute it. Otherwise set 15m budget.
     - **Phase 1 Inventory**: Map available environment binaries (`which python3`, `which perl`, `which osascript`, `which tmux`, `which bash`).
     - **Phase 2 Invent New**: Write inline Python/Bash helper script or custom wrapper to replace the missing or failing CLI tool.
     - **Phase 3 Expand & Equip**: Deploy helper script to local execution environment (`/tmp/` or local `bin`). Tool set is strictly larger.
     - **Phase 4 Re-Analyse**: Execute original task using the new helper script via simplest route.
     - **Phase 5 Persist**: Retain helper utility and failure analysis for permanent zero-loss future execution.


## Output

For each shell execution:
1. **Command Line**: Exact command string executed.
2. **Execution Metadata**: Working directory, timeout budget, exit code (`0` for success, `N` for error).
3. **Redacted Output**: Truncated standard output / error stream with secret masks.
4. **Next Step Rationale**: Diagnosis or follow-up action based on exit status.
