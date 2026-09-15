# HANDOFF — casehub-platform

## Last Session

Validated and completed Batches 1-2 of casehubio/parent#478 (Spring deployment completion).

**1. Batch 1 test validation.** Platform Panache purge was compilation-only from the prior session. Ran tests on all 5 purged -jpa modules. Found 5 test files in persistence-jpa and acl-jpa still using Panache API calls (deleteAll, persist, count, list, find). Ported all to EntityManager + JPQL. All 5 modules pass (persistence-jpa, acl-jpa, notification-settings-jpa, digest-jpa, platform-view-jpa). Batch 1 is now fully validated.

**2. Batch 2 consumer Panache porting (complete).** Ported Panache out of all 3 consumer repos:

| Repo | Branch | Entities | Stores | Poms | Compilation |
|------|--------|----------|--------|------|-------------|
| ledger | n/a | 0 (already done prior session) | 0 | 0 | Clean |
| work | `issue-401-panache-purge` | 21 stripped | 30+ ported | 9 updated | Clean (2 pre-existing: engine-adapter missing InboundWorkItemRequest, federation missing markCompensated) |
| qhorus | `issue-440-panache-purge` | 18 stripped | 20 ported + 4 PanacheRepo classes deleted | 2 updated | All 27 modules clean |

Work repo: 3 commits (entity strip, store port, pom cleanup).
Qhorus repo: 8 commits (entity strip, store ports in batches, PanacheRepo removal, pom cleanup).

Both repos have WIP commits that need squashing before merge.

## Immediate Next Step

Batch 3: Create missing -spring modules (work-spring, ledger-spring, eidos-spring). These live in their respective repos — each needs a pom.xml with spring-generator plugin, parent pom module declaration, and `<quarkusModule>` pointing at the Quarkus runtime module. Follow existing pattern from platform-spring.

## Remaining Batches

| Batch | What | Status |
|-------|------|--------|
| 1. Platform Panache Purge | 11 entities + 3 stores + 6 poms | Done + tested |
| 2. Consumer Panache Porting | ledger, work, qhorus | Done (WIP commits need squash) |
| 3. Missing -spring Modules | work, ledger, eidos | Next |
| 4. Generator Plugin Wiring | rest/graphql gen to 5 repos | Pending |
| 5. mcp-spring Runtime | SpringModelScanner + registrar | Pending |
| 6. callback-spring | @Decorator → @Bean @Primary | Pending |
| 7. Blocks Push | 10 commits to origin/main | Pending (needs squash first) |

## Key Facts

- Work and qhorus branches have WIP commits. Squash before merging to main.
- Work repo has 2 pre-existing compilation failures (engine-adapter, federation) unrelated to Panache — cross-repo interface evolution.
- Blocks repo still has 10 unpushed core extraction commits on local main.
- graphql-generator APT processor NOT yet retrofitted to use shared types (lower priority).
- Platform branch `issue-478-spring-deployment-completion` has 2 commits ahead of origin/main.

## Garden Entries Consulted

GE-20260420-7d28fa, GE-0138, GE-20260914-248827

## References

- `specs/spring-deployment-completion/2026-09-15-spring-deployment-completion-design.md`
- `specs/spring-deployment-completion/decisions.md` (4 decisions)
- `plans/2026-09-15-spring-deployment-completion.md` (11 tasks, 7 batches)
- casehubio/parent#478 — tracking issue
- casehubio/work#401 — work Panache purge issue
- casehubio/qhorus#440 — qhorus Panache purge issue
