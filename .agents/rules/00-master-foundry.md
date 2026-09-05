# 00 — Master Foundry (JXRouter workspace template)

> Deployed by the Supreme Zero-Error Autonomous Software Engine v3.0 (FULL depth, 18 gates),
> cycle 1, 2026-08-06. This file makes the engine's results reproducible and re-runnable
> from this workspace. Do not delete; update in place on each engine cycle.

## Engine identity

- Engine spec: `/Users/joshua/Library/Mobile Documents/com~apple~CloudDocs/Agents Book/08 - Prompt Library/Part VI - The Studio/148 - The Supreme Zero-Error Autonomous Software Engine v2.1.md`
- Depth: FULL (18 gates + Gate 01.5 sentinel + endless evolving loop)
- Active cycle: 3 of 3 (max reached) · Resolution: CONDITIONAL (gate-18-release.md; cycle-3 close-out: GUI smoke + Gate 16 PASS after P0 listener fix)

## Workspace state (source of truth)

| Concern | Path |
|---|---|
| Lifecycle state (phase/verdict per gate) | `.app-lifecycle/state.json` |
| Gate board (18-gate matrix) | `.app-lifecycle/gates/gate-board.md` |
| Feature inventory (Gate 01.5) | `.agents/memory/feature-inventory.json` — MUST stay `simulated:false` |
| Reports | `.TerMinal/reports/engine-full-2026-08-06/gate-*.md` |
| Backlog tickets | `.TerMinal/backlog/0001-0031` (13 closed / 18 open; `.next-id` = 32) |
| Build log | `.TerMinal/reports/engine-full-2026-08-06/gate-12-build.log` |
| This template | `.agents/rules/00-master-foundry.md` |

## Standing constraints (engine mandate, cycle 1)

1. **Hallucination firewall (Gate 03)**: every finding MUST carry `file:line` (or symbol+line)
   evidence. `simulated: true` manifests are ILLEGAL — regenerate, never copy.
2. **Working-tree protection**: `Sources/JXRouter/ConfigManager.swift`, `ProviderRouter.swift`,
   `SettingsView.swift`, `package.json` are the user's in-flight work — audit in place, never
   revert/commit/overwrite them. This protection persists until the user says otherwise.
3. **Repair policy**: clean file + behavior-preserving + evidence-anchored → repair directly
   (verify with a full Release build afterwards); anything else → `.TerMinal/backlog/` ticket.
4. **Verification**: every engine cycle ends with `xcodebuild -project JXRouter.xcodeproj
   -scheme JXRouter -configuration Release -derivedDataPath /tmp/jxrouter-dd build` (0 errors
   always; warnings must never increase). **Build success alone is NOT verification** — cycle 3
   proved a green build can ship a P0 (NWListener EINVAL, found only at runtime): any change to
   listeners/start paths requires the consented GUI smoke (start → auth matrix → load loop →
   teardown; ~2 min, no admin side effects).
5. **GUI smoke tests need consent**: launching the app can enable the system proxy
   (admin prompts); do not auto-launch without the user's go-ahead.
6. **DNS/pf hijacking is PERMANENTLY REMOVED (user-mandated)**: this app MUST NEVER write to
   `/etc/hosts`, load `pfctl` anchors, or add any "DNS redirection" feature again — every
   version that did broke the user's whole system connection (stale system proxy on a dead
   port, leftover pf anchors after crashes, legacy `ProxySwitch DNS Hijack` blocks in
   `/etc/hosts`). `DNSRedirectionManager` is **cleanup-only**: it strips legacy hosts blocks
   (both the JXProxy and pre-rebrand ProxySwitch markers) and flushes the old anchor, and
   never installs anything. Route AI traffic via `~/.claude/settings.json`, the launcher
   scripts, and the optional system-wide proxy. Re-adding the hijack is a P0.

## Re-run protocol (post cycle 3 — engine max cycles reached)

1. Read `.app-lifecycle/state.json` + `gate-board.md`. Engine loop is at max cycles; further runs
   are manual and ticket-driven: land 0007 + stubs 0010/0011/0022 + 0028-0031, then re-run
   gates 10/17/18 with the same scout+repair+build+smoke protocol below.
2. For each gate, dispatch read-only scouts (evidence-tagged output, ≤250 lines, `[GATE RESULT:]`
   verdict block). Cross-corroborate P0/P1s across ≥2 agents before acting.
3. Write findings to `.TerMinal/reports/engine-full-2026-08-06/gate-<n>-*.md`; update board + state.
4. Apply the repair-vs-ticket split (constraint 3); rebuild; **runtime-smoke any listener/start
   change** (consented); re-verify.
5. File the gate board + this file's updates; render the close-out panel.
6. GUI smoke test and any run of the app itself require explicit user consent (system proxy +
   pf rules side effects). Baseline snapshot (networksetup/hosts/ports) before every run;
   teardown must restore it exactly.

## Agents used in cycle 1 (reusable)

ScoutManifest, ScoutStack, SecAudit, ArchAudit, EdgePerf, PersonaA11y (read-only audits) ·
ManifestWriter (Gate 01.5) · RepairProxyCore, RepairWiring, RepairTranslator, RepairHygiene
(surgical fixes) · TicketWriter (backlog). Contracts: evidence tags, P0=stop-work scale,
reports ≤250 lines.
