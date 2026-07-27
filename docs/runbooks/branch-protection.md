---
title: Configure forge branch protection
last-verified: 2026-01-01
anchor: RB-branch-protection
---

The `.claude/hooks/block-main-merge.sh` hook stops *agents* from merging/pushing
to `main`. Forge-side **branch protection** is the complement: it stops a
*human* (or a stray force-push from the web UI) from bypassing review. Set it up
once per repo. ~2 minutes; costs nothing.

## [1] GitHub

Settings → Branches → add a ruleset / protection rule for `main`:

- [ ] Require a pull request before merging (≥ 1 approval)
- [ ] Require status checks to pass — select the CI `quality` job
- [ ] Require branches to be up to date before merging
- [ ] Block force pushes
- [ ] Restrict deletions

CLI:

```bash
gh api -X PUT repos/<owner>/<repo>/branches/main/protection \
  -f required_pull_request_reviews.required_approving_review_count=1 \
  -F enforce_admins=true \
  -F 'required_status_checks.strict=true' \
  -f 'required_status_checks.contexts[]=quality' \
  -F restrictions=
```

## [2] GitLab

Settings → Repository → Protected branches (and Merge request approvals):

- [ ] Protect `main`: Allowed to merge = Maintainers; Allowed to push = No one
- [ ] Allowed to force push = off
- [ ] Require approvals ≥ 1 (Settings → Merge requests → Approvals)
- [ ] Pipelines must succeed (Settings → Merge requests → "Pipelines must succeed")

## [3] Why both layers

The hook is local + agent-scoped (it can be bypassed by running git in a
non-Claude terminal — by design, that's the human gate). Branch protection is
server-side and unconditional. Together: agents never merge; humans merge only
through a reviewed, green PR/MR.
