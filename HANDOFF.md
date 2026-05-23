# HANDOFF — casehub-platform

**Date:** 2026-05-23
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Blog publishing housekeeping: confirmed all 12 casehub-platform blog entries were already published to `mdproctor.github.io/_notes/`. Added `blog-routing.yaml` to workspace root so `publish-blog` can detect the source path when run standalone. Parked issue #8 (no UI work).

## Immediate Next Step

Verify engine#329 status (user wasn't sure if it was already fixed). If closed, remove from What's Left. Then `work-start` on GroupMembership OIDC provider.

## Cross-Module

*Unchanged — `git show HEAD~1:HANDOFF.md`*

## What's Left

*Nothing outstanding.*

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| — | GroupMembership OIDC provider | M | Med | Needs directory (Keycloak Admin/LDAP) |
| #8 | `preferences-editor/` — admin UI/API write path | XL | High | Parked — no UI work |

## References

- ADRs: `adr/0005` (ActorType), `adr/0006` (JPA current-only), `adr/0007` (SlaBreachPolicy in work-api)
- Blog: `blog/2026-05-23-mdp01-blogs-already-there.md` (latest)
- Garden: GE-20260522-409183 (GIT_SEQUENCE_EDITOR SHA typo), GE-20260522-b9a6d4 (force-with-lease fresh fork)
- Squash backup: `backup/pre-squash-main-20260522` (local only)
