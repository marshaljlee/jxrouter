# learnings/

Non-obvious findings — surprising behavior, subtle invariants, gotchas, "X
didn't work because Y". The stuff that costs an hour to rediscover. One file per
topic: `docs/learnings/<topic>.md` with frontmatter:

```yaml
---
title: <short title>
date: YYYY-MM-DD
tags: [tag1, tag2]
anchor: LRN-<slug>
---
```

These are findings, **not** plans (plans → tickets) and **not** decisions
(decisions → ADRs). `/document` proposes learnings from a session's surprises;
`/session-end` captures the load-bearing ones. Anchor sections with `[N]` for
greppability.
