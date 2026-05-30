# HANDOFF — casehub-platform

**Date:** 2026-05-30
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Shipped `casehub-platform-scim` — first real `GroupMembershipProvider` implementation (platform#45, closed). Breaking SPI change: `membersOf()` now returns `Set<GroupMember>` (actorId = OIDC sub = SCIM value UUID; displayName = human label). SCIM 2.0 two-step fetch, `@CacheResult`, static token or OIDC client-credentials auth. All 12 modules green. Pushed to origin and mdproctor fork.

## Immediate Next Step

`work-start` on **#37 memory-sqlite/** or jump to casehub-work to update `WorkBroker`/`ExclusionPolicy` callers from `Set<String>` → `Set<GroupMember>` (issues filed there; mechanical update).

## Cross-Module

**We're blocking:**
- `casehub-work` — WorkBroker and ExclusionPolicy call `membersOf()` treating result as `Set<String>`. Mechanical update; issues filed on casehub-work. · S · Low

## What's Left

- Hook install still pending on 5 repos: `casehub/aml`, `casehub/clinical`, `hortora/garden`, `md-compare`, `casehub-poc` · XS · Low
- `md-compare` — legacy commit-msg hook in `.git/hooks/`, migrate when branch returns · XS · Low
- `docs/PLATFORM.md` + `docs/repos/casehub-platform.md` in parent — stale for GroupMember SPI + scim/ module (parent#113 filed) · XS · Low

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #37 | `memory-sqlite/` — SQLite adapter, durable pure-Java | M | Med | Evaluate single-writer concurrency first |
| #47 | SCIM pagination — groups >1000 members | S | Med | Deferred from #45 |
| #39 | CDI priority revisit when `memory-mem0/` arrives — `@Priority(1)` conflict | S | Med | Block on #33 |
| #40 | `memory-memori/` REST adapter — pending Memori API stabilisation | L | Med | Pre-condition: verify DELETE entity_id without process_id |
| #8 | `preferences-editor/` — admin UI/API write path | XL | High | Parked |

## References

- Spec: `specs/2026-05-30-scim-group-membership-provider-review.md` (workspace)
- Blog: `blog/2026-05-30-mdp01-asking-directories-whos-in-the-group.md`
- Garden: GE-20260530-29545c (Quarkiverse WireMock 1.4.1 + Quarkus 3.32.2 incompatible), GE-20260530-385dbb (@Provider bypasses CDI in REST client filters)
- Protocol: PP-20260530-88cdf9 (SPI sig change — all in-repo impls same commit, universal)
