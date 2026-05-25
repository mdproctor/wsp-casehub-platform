# HANDOFF — casehub-platform

**Date:** 2026-05-25
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Full hook infrastructure audit and bulk install across all active repos. Both hooks (pre-push squash detection, commit-msg issue ref enforcement) are now committed to `.githooks/` in 20+ repos. Three cc-praxis skills fixed (issue-workflow, workspace-init, work-start). check_project_setup.sh packaged as a proper plugin component in install-skills.

## Immediate Next Step

`work-start` on the **GroupMembership OIDC provider** — the actual planned work that got deferred by the hook session.

## Cross-Module

*Unchanged — `git show HEAD~1:HANDOFF.md`*

## What's Left

- Hook install still pending on 5 repos (branches open): `casehub/aml`, `casehub/clinical`, `hortora/garden`, `md-compare`, `casehub-poc` · XS · Low
- `md-compare` has an issue-workflow `commit-msg` hook in `.git/hooks/` (old way) — migrate when branch returns · XS · Low

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| — | GroupMembership OIDC provider | M | Med | Needs directory (Keycloak Admin/LDAP) |
| #8 | `preferences-editor/` — admin UI/API write path | XL | High | Parked — no UI work |

## References

- Blog: `blog/2026-05-25-mdp01-hooks-everywhere.md` (latest)
- Protocols: `casehub/garden/docs/protocols/universal/committed-git-hooks.md`, `casehub/garden/docs/protocols/casehub/repo-hook-requirements.md`
- Garden: GE-20260525-8e5b29 (stale branch pointer post-rebase), GE-20260525-06327c (hook blocks own install), GE-20260525-c0b5a4 (Python /tmp/ bulk git), GE-20260525-db848c (CLAUDE_PLUGIN_ROOT)
- cc-praxis issues: #101 (plugin hook packaging), #102 (workspace-init hook install)
