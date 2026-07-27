# runbooks/

Repeatable operational procedures — deploys, migrations, incident response,
local setup, anything manual that recurs. One file per task:
`docs/runbooks/<task>.md` with frontmatter:

```yaml
---
title: <task name>
last-verified: YYYY-MM-DD
anchor: RB-<slug>
---
```

Anchor steps with `[N]` so a specific step is greppable / referenceable
(`RB-deploy#3`). `/document` proposes runbooks from manual ops sequences;
`/document-audit` flags any with `last-verified` older than 90 days. Bump
`last-verified` whenever you re-run and confirm a runbook still works.
