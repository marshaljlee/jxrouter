<!-- Keep it short — this front-loads the review checklist before /code-review runs. -->

Closes #<ticket-id>  <!-- one or more: Closes #12 #13 -->

## Summary
<what changed and why, 2-3 sentences>

## Checklist
- [ ] Tests added and **meaningful** (adversarial, not rigged to pass)
- [ ] Feature is **wired** to a real entry point (e2e/integration proves it) — tests passing ≠ shipped
- [ ] Docs updated if a decision/structure/ops step changed (ADR / architecture.md / runbook)
- [ ] Acceptance criteria in the linked ticket(s) are met
