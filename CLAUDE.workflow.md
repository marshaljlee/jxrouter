# CLAUDE.md — <PROJECT NAME>

<!-- Project-specific guidance, loaded on top of global ~/.claude/CLAUDE.md.
     Don't restate global rules — reference as "global §N". Keep lean. -->

<One-line description.> See [`README.md`](./README.md) and
[`docs/architecture.md`](./docs/architecture.md).

**Status:** <design / building / shipped — one line on where things stand.>

## [1] Operating principles

Global §11 (production-grade always, code is cheap / maintenance is not,
don't trust your internal clock, nothing is static) applies. The loop:

```
/session-start "<goal>"   →  seed live session doc (central state)
   /ticket                →  file/triage as .TerMinal/backlog/NNNN-slug.md
   feature branch         →  off main (or off prior PR in a stack)
   implement TDD-first    →  failing test → code → green
   /pr-creation           →  push + open PR, link into ticket
   code-review agent      →  review to passing bar (background)
   <human merges>         →  merge to main is HUMAN-ONLY (global §8)
/session-end              →  document, clean up, file follow-ups, close
```

Supporting: `/test-suite`, `/security-scan`, `/check`, `/merge-sync`,
`/document` + `/document-audit`, `/notify`, `/stacked-mr`, `/factory`.

## [2] TDD gate (non-negotiable)

Test-first per global §4. Two enforcement points:

- **Review the RED test before implementing** — it's the spec; a wrong test
  locks in wrong behavior.
- **Adversarial, not green-rigging** — meaningful behavior, real I/O, edge
  cases. Tautologies and over-mocking are worse than no tests. e2e /
  integration tests are first-class.

Enforced mechanically: `/session-start` seeds "write failing test for X"
before "implement X"; `/pr-creation` refuses repos with no test suite;
The `code-review` agent runs the suite as a hard gate; `/session-end` files a
testing ticket for any new behavior without a test.

## [3] Sessions are central state

Live session doc at `.TerMinal/sessions/NNNN-slug/session.md` — goal,
context, checklist, log, decisions, outcomes, follow-ups. Exactly **one
active** at a time. Legacy v1 repos may still use `sessions/`. Schema in
[`.claude/skills/session-start/SESSION_EXAMPLE.md`](./.claude/skills/session-start/SESSION_EXAMPLE.md).

`.status.md` (gitignored) is the ephemeral at-a-glance for the developer
managing agents — regenerate with `.claude/bin/status > .status.md`.
Agents refresh it at checkpoints (session start/end, PR open/merge,
needs-you events). Feeds the TerMinal sidebar (`/terminal-widget`).

## [4] Tickets

`.TerMinal/backlog/NNNN-slug.md`, managed by `/ticket` (legacy v1:
`backlog/NNNN-slug.md`). Allocate ids with
`.claude/skills/ticket/bin/next-ticket-id` (never hand-edit `.next-id`).
List with `.claude/skills/ticket/bin/tickets [status] [priority] [horizon]`.
Prose lives **after** the closing `---`, never inside frontmatter.

Every ticket is assigned to exactly one agent via frontmatter:
`agent_id`, `agent_scope` (`repo` | `global`), and `agent_kind`
(`classic` | `persistent`). If work needs multiple agents/phases, split it
into multiple tickets and link them with `depends_on`.

For complex full-stack or high-risk tickets, add a short staged
implementation plan in the ticket body or session doc before editing. Keep it
lightweight: name each stage, its dependencies, the verification command or
check, and any human approval gate (for example before destructive migrations).
Do not build a separate orchestration system unless the written plan stops
being enough.

The end-to-end owner, knowledge-gathering, delegated-artifact, and follow-up
contract lives in [`docs/workflow/agent-process.md`](./docs/workflow/agent-process.md).

### [4.1] Status lifecycle (gap-free)

`open` → `in-progress` → `closed`, with `stuck` / `icebox` off-ramps.
Each transition has an owner:

- **`in-progress`** the moment work starts — `/session-start`,
  `/pr-creation`, `/stacked-mr` all set it; manual paths set it yourself.
- **`closed`** only when the PR/MR actually **merges** — `/merge-sync`
  closes it and scrubs the merged url from `prs:`. Never pre-close on
  "PR opened."
- **`stuck`** when blocked after real effort (note why); **`icebox`** when
  deliberately deferred. Don't leave work-in-flight rotting as `open`.

`/session-end` reconciles every touched ticket and sweeps the backlog for
drift; `/merge-sync` runs the same sweep standalone. Goal:
`bin/tickets in-progress` always matches reality.

The **`horizon`** tag (`now` | `next` | `future`) is orthogonal to
priority — the `code-review` agent and `/session-end` park out-of-scope ideas as
`future`.

### [4.2] Inboxes — reaching the human & queuing automation

Two inboxes; full contracts in
[`docs/workflow/inbox.md`](./docs/workflow/inbox.md).

- **HITL inbox** (one GLOBAL, not per-repo) — file with
  `.claude/bin/hitl "<title>" "<action needed>" "<detail>"` (helper only).
  Append-only: agents file + query; **humans resolve** (never self-resolve).
  When a blocker clears, move the related `stuck` ticket back to `open`/
  `in-progress`. Reserve for **true human-needs** (spec forks, approvals,
  creds, OAuth) — **not** review `request-changes` or test failures, which
  iterate.
- **Automation inbox** — queue a JSON event via `terminal-cli inbox enqueue`
  instead of running arbitrary shell inline; TerMinal validates, dedupes, and
  runs it. Use the `enqueue-request` skill for one-offs, `new-inbox-source`
  for a durable adapter.

## [5] Branches, PRs/MRs & the forge

**Stacked PRs/MRs:** When a ticket naturally splits into dependent review units,
prefer Graphite CLI (`gt`) for GitHub-backed stacked branches and PRs if it is
installed and the repo is initialized with `.git/.graphite_repo_config`. Use
`gt create`, `gt modify`, `gt sync`, and `gt submit --stack` to keep stack
metadata, rebases, and PR links coherent. Treat Graphite as an optional authoring
layer: fall back to `gh`/`glab` and normal branch workflows when the repo is not
GitHub-backed, Graphite is unavailable, or the work is a single independent PR/MR.
Graphite merge queue or stack merge must not bypass the human-only final merge
gate.

**Per-repo forge.** `.claude/bin/forge` prints `github` or `gitlab` (reads
`.claude/forge` override, else detects from origin). Use the matching
CLI + terminology — `gh`/"PR" or `glab`/"MR". Mapping:
[`.agents/forge.md`](./.agents/forge.md). Self-hosted GitLab requires the
`.claude/forge` override.

Always work on a feature branch; **never commit/push to `main`** (global
§8, enforced by `.claude/hooks/block-main-merge.sh`). Final merge is
human-only.

- **Commits:** Conventional Commits (`feat:`/`fix:`/…), one logical
  change, imperative subject ≤ ~70 chars.
- **One PR can close multiple tickets** — batch cohesive tickets; code
  review is the throughput bottleneck. PR body lists `Closes #<a> #<b>`;
  link the PR url into **each** ticket's `prs:`.
- **After merge, reconcile** — run `/merge-sync` (especially after
  `/stacked-mr` batches) to close merged tickets and scrub urls.

## [6] Code review & checks

The `code-review` agent writes one combined review+tests artifact at
`.TerMinal/reviews/<pr>/<sha>.md` (+ `findings.json` / `suggestions.json`;
legacy v1: `.reviews/<pr>/<sha>.md`). Contract:
[`.agents/code-review.md`](./.agents/code-review.md).

- **Merge bar:** `verdict: approve` + `test_status: pass` + zero findings
  ≥ medium. Overall score is informational.
- **Run in background** — review is ~4 min; fire async, do other work.
  Reviewer files out-of-scope items as `horizon: future` tickets.
- **`/stacked-mr` batches review** — no per-PR review while building;
  one end-of-stack pass fans out the `code-review` agent per PR in parallel
  (each in its own worktree). See the contract's "Batch stacked-MR
  review" section.

**Cadence checks** are the other half: `/check <kind>` runs a repo-level
inspection (dead-code, dep-drift) on a cadence, writing dated artifacts
to `.TerMinal/checks/<kind>/<sha>.md` (legacy v1: `.checks/<kind>/<sha>.md`).
Each kind is a contract at
`.agents/<kind>.md`. Checks are **advisory** — they report; cleanup
becomes a ticket.

## [7] Documentation & knowledge base

Sidecar `.md` under `docs/` (global §7): `decisions/` (append-only ADRs),
`architecture.md` (evergreen, edit-in-place), `runbooks/`, `learnings/`.
Capture with `/document`, rot-check with `/document-audit`. `/session-end`
is the main moment things get written. For implementation-time knowledge
gathering and delegated artifacts, follow
[`docs/workflow/agent-process.md`](./docs/workflow/agent-process.md).

## [8] Doc anchoring

Long docs (session docs, ADRs, architecture) stay **greppable**:

- Heading anchors: `## [1] Title`, `### [1.2] Title`. Numbers are
  **stable ids, not ordinals** — append new ones, never renumber.
- Doc code in frontmatter: `anchor: SES-0007` / `ADR-0003` / `ARCH`.
- Grep: `grep -n "\[3.1\]" path/to/doc.md`. Cross-doc: `SES-0007#3.1`.

Short tickets don't need it.

## [9] When picking back up

<!-- Steps to resume after a context switch — saves rediscovering tribal
     knowledge. Example: -->

1. <e.g. `docker compose up -d`>
2. <e.g. reset local DB / apply migrations>
3. <e.g. `bun test`>
4. `/session-start "<goal>"` or resume the `active` session.

## [10] Autonomous / AFK modes

`/notify` (Telegram bridge), `/stacked-mr` (build a PR stack, then one batch
review to the bar), `/factory` (perpetual loop around `/stacked-mr`:
reconcile → build → review → optionally refill → repeat). All park HITL on
blockers and **never merge to main**. Mechanics live in each skill body
(loaded on invocation); context-hygiene rules in factory §2.5/§2.6.

## [11] Conventions

- Tooling: `bun` / `bunx`; pin deps; commit lockfile (global §5, §10).
- Style/errors/types/barrels/file-org: global §6.
- Frontend: Tailwind (global §9).
- <Project-specific conventions here. Keep beyond-spec ambition in check
  against explicit spec constraints.>

## [12] Project specifics

<!-- Domain context, substrate, external services, runbooks,
     "don't re-derive" facts. Subsections [12.1], [12.2], … as needed. -->

### [12.1] Sensitive surfaces

<!-- Fill this in for regulated or security-sensitive projects. Keep it
     concrete to this repo rather than restating generic security advice. -->

For auth, billing, health/customer data, credentials, external integrations, or
migrations, record the repo-specific checks here. Examples:

- Authn/authz path matches the existing project pattern.
- Permission checks are covered by tests.
- Sensitive values are never logged, committed, or exposed in artifacts.
- Audit/event logging is preserved where the product requires traceability.
- Migrations are backward-compatible and non-destructive unless explicitly
  approved.
- External credentials use the existing secret manager/client pattern.

## [13] Activity feed

Every skill emits a feed event at each workflow milestone (so runs show live
in TerMinal): `.claude/bin/activity <kind> "<title>" ["<detail>"]`. Exit-0
safe; derives repo context from git. `kind` ∈ `ticket-filed` · `pr-verdict` ·
`session-start` · `session-end` · `agent-run` · `info` · `error`.

## [14] Vibe mode vs quality mode

Two modes with **different contracts**; the skill is never confusing them.

- **Quality mode is the default.** Everything above (§1's loop, TDD, review,
  human merge) is quality mode — correctness, clarity, ownership. Anything that
  ships lives here.
- **Vibe mode is explicit and temporary.** Fast, gates-off exploration to learn
  the shape of a problem — prototype competing approaches, generate N variants,
  vibe an end-to-end artifact to mine for references. Output is **disposable
  signal, not a shipping candidate.** Enter it with `/vibe` (or an explicit
  "vibe this, skip the gates").

Vibe to discover, switch to quality to ship. The guardrails are non-negotiable:
isolated worktree/`vibe/*` branch (never the primary checkout, never `main` —
`.claude/hooks/block-main-merge.sh` enforces the last part), no production side
effects, disposable by contract, and a clean exit that rebuilds through the
gates (`/ticket` → TDD → review) rather than promoting the vibe branch. Full
contract + techniques: [`.claude/skills/vibe/SKILL.md`](./.claude/skills/vibe/SKILL.md).

## [15] Model routing — outsource the cheap tier

**Your own top model is the default and the orchestrator.** Don't reflexively
downgrade to save money — quality is the default.

**A downgrade to the near-free model tier is permitted only when the task carries
a clear, machine-checkable acceptance criterion** — a test that goes red→green
(suite still green), an exact expected output, an idempotent regen that matches,
typecheck/lint/schema-validation — **OR the user explicitly requests a cheap
model.** No criterion and not explicitly requested → no downgrade; do it yourself. Enforce the criterion *after* the cheap model runs; on failure, discard
and redo on your own model. A wrong downgrade costs a retry, never a
silently-shipped bad diff.

When a task qualifies, hand it off via the global **`outsource` skill**: `or-exec`
(raw one-shot) or `or-agent` (Codex on a cheap model — reads/edits files). Model
menu, budget ($ daily pool + per-call cap), and spend log live in
`~/.claude/model-routing/`. Near-free *paid* models only (~1–3% of frontier cost);
free `:free` models are excluded (they 429 out of agentic loops). This tier
composes with [2]'s TDD gate — the failing test *is* the acceptance criterion.
