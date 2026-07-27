---
id: 0001
title: Record architecture decisions as ADRs
anchor: ADR-0001
status: accepted
date: 2026-01-01
supersedes:
superseded-by:
---

This is both the first decision **and** the canonical template — copy its shape
for new ADRs. Allocate the next `NNNN` by listing `docs/decisions/`. Headings
carry `[N]` / `[N.M]` anchors so any part is greppable (`grep -n "\[2\]" file`)
and cross-referenceable as `ADR-0001#2`.

## [1] Context

We make non-obvious design decisions (libraries, architecture, data models,
tradeoffs) that future maintainers — human or agent — need the *why* for, not
just the *what*. Code shows the what; commit messages are too granular; chat
history is lost. We need a durable, append-only record.

## [2] Decision

Record each non-obvious decision as a numbered ADR in `docs/decisions/NNNN-slug.md`
with the frontmatter above (`status`: `proposed` | `accepted` | `superseded` |
`deprecated`). ADRs are **append-only**: don't rewrite an accepted ADR — supersede
it with a new one and link both via `supersedes:` / `superseded-by:`.

`/document` proposes ADR candidates from a session's decisions; `/session-end`
promotes the load-bearing ones. `/document-audit` flags contradictions between
two `accepted` ADRs with no supersede link.

## [3] Consequences

Decisions are traceable and survive context loss. The append-only rule means
the file count grows, and readers must follow `superseded-by:` chains to find
current truth — `/document-audit` mitigates drift.

## [4] Conflicts resolved (optional)

For ADRs that resolve competing options, label each conflict `C1`, `C2`, … so
later docs and code comments can cite it by name (e.g. "handles C2"):

- **C1 — sidecar files vs in-file docs:** chose sidecar `docs/` (global §7).
- **C2 — per-decision file vs one big doc:** chose per-decision files for
  greppability + append-only safety.

Omit this section when an ADR records a single straightforward decision.

## [5] Unchanged and still binding (optional)

When an ADR revises an earlier design, state explicitly what did **not** change,
so a future rewrite doesn't accidentally erode intent:

- The human-only merge gate (global §8) is unaffected.
- TDD-first remains the gate for all behavior changes.

## [6] Superseded decisions (optional)

A table mapping prior decisions to their disposition, for ADRs that replace
earlier ones:

| Prior | Was | Now | Why |
|---|---|---|---|
| (none yet) | | | |
