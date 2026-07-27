# Architecture

> Evergreen system overview — **edit in place** (unlike append-only ADRs). Keep
> it matching the shipped code; `/session-end`'s consistency check and
> `/document-audit` flag drift. Headings carry `[N]` / `[N.M]` anchors so any
> part is greppable (`grep -n "\[2\]" docs/architecture.md`) and referenceable
> as `ARCH#2`. Replace the placeholder content below with this project's reality.

anchor: ARCH

## [1] Overview

<2–4 sentences: what this system is, who uses it, the core value it delivers.>

## [2] Components

<The top-level pieces and what each owns. For a monorepo, give each app its own
subsection so context stays oriented when jumping between them.>

### [2.1] <component / app>
<responsibility, key entry points, the folder it lives in>

### [2.2] <component / app>
<...>

## [3] Data flow

<How a request / job moves through the system end to end. A short numbered
walkthrough beats a diagram for greppability.>

## [4] Key decisions

<Pointers to the load-bearing ADRs (by anchor, e.g. ADR-0002) rather than
restating them. This section is the index into docs/decisions/.>

## [5] External dependencies & services

<Datastores, third-party APIs, infra. What each is for and where its config /
runbook lives.>

## [6] Conventions

<Project-specific conventions beyond global + project CLAUDE.md that a newcomer
needs: naming, module boundaries, error model, etc.>
