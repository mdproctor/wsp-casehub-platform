# HANDOFF — Slot 198

## Current Work

**Branch:** `issue-403-work-spring-panache` (platform + work repos)
**Queue:** work#403 → work#409 → work#410

### work#403 — Rest module tests broken after APT migration
- 289 of 348 tests fail after commit e05ae639 (#400) deleted hand-written REST endpoints and switched to APT-generated code
- Tests reference deleted classes (WorkItemMapper, CreateWorkItemRequest) and hit 404s on removed endpoint paths
- **Unblocks:** work#410 (ai/queues modules commented out due to compilation failures)

### work#409 — 21 entities still extend PanacheEntityBase
- All 21 files still have PanacheEntityBase (confirmed via git grep)
- work#401 (Panache purge) was closed prematurely — entities not actually ported
- Affects: runtime/ (14), federation/ (2), progress-runtime/ (2), queues/ (2), ai/ (2), issue-tracker/ (1)

### work#410 — ai and queues missing from rest-spring-generator
- S/Low but **blocked by #403** — ai/ and queues/ modules commented out in root pom
- work-rest-spring module was deleted in commit e093a40b
- Once #403 lands: add ai/queues to rest-spring-generator quarkusModules, restore work-rest-spring

## Previous Session (2026-09-30, session 2)

Worked parent#518 (Spring completeness audit epic) — swept all S/Low items across slot repos.

### Completed

| Issue | Repo | What |
|-------|------|------|
| platform#492 | platform | Closed as stale — memory modules migrated to neocortex, Spring path already done there |
| platform#490 | platform | ConfigVariableSource added to yaml-step-runtime. Also fixed Maven reactor cycle (yaml-step-runtime ↔ yaml-step-testing). Landed on main |
| engine#1200 | engine | AutoConfiguration.imports added to 5 Spring modules (4 existing @AutoConfiguration + new LedgerAutoConfiguration with @ComponentScan). Branch: issue-1200-spring-autoconfig-imports |
| workers#29 | workers | ScriptWorkerAutoConfiguration added (resolver + execution manager + runtime). Camel deferred — needs CDI→constructor refactoring. Branch: issue-29-script-camel-spring-autoconfig |

### Blocked / Re-scoped (comments added to each issue)

| Issue | Repo | Blocker |
|-------|------|---------|
| work#410 | work | ai/queues commented out in root pom (#403 compilation failures), work-rest-spring deleted |
| qhorus#461 | qhorus | runtime-spring commented out — DeliveryConfig type-mapping bug (#458) |
| workers#30 | workers | Generator wiring needs dedicated build-system work, not a quick fix |
| qhorus#463 | qhorus | Re-scoped to M/Med: runtime-core has CDI leakage, compliance-core extraction needed |
| desiredstate#155 | desiredstate | Re-scoped to M/Med: uses SmartInitializingSingleton + dynamic registerBean(), generator can't handle |

### Open branches (not yet work-ended)

- engine: `issue-1200-spring-autoconfig-imports` — committed, needs work-end
- workers: `issue-29-script-camel-spring-autoconfig` — committed, needs work-end

## Remaining parent#518 items (14 open, by actionability)

### Actionable now (M/Med)

| Repo | Issue | Title | Scale |
|------|-------|-------|-------|
| engine | #1201 | No spring-integration-test for engine | M / Med |
| engine | #1202 | No mcp-spring module | M / Med |
| work | #411 | No spring-integration-test for work | M / Med |
| desiredstate | #154 | No spring-integration-test despite 5 auto-configs | M / Med |
| blocks | #322 | 608-line monolithic auto-config — candidate for spring-generator | M / Med |
| work | #409 | 21 entities still extend PanacheEntityBase | M / Med |

### Blocked by upstream

| Repo | Issue | Title | Blocked by |
|------|-------|-------|------------|
| work | #410 | ai/queues missing from rest-spring-generator | work#403 |
| qhorus | #461 | No graphql-spring-generator for 7 services | qhorus#458 |
| workers | #29 | Camel auto-config (script done) | workers-camel CDI refactoring |
| workers | #30 | No generators — 288 lines hand-written | Build-system work |

### Large / needs design

| Repo | Issue | Title | Scale |
|------|-------|-------|-------|
| engine | #1199 | No rest-spring module — 5 REST resources | L / Med |
| qhorus | #460 | ~12 CDI modules without core extraction | XL / High |
| qhorus | #463 | Partial core extraction in CDI modules | M / Med (re-scoped) |
| desiredstate | #155 | Spring modules could use generators | M / Med (re-scoped) |

## Previous Session (2026-09-30, session 1)

Worked parent#518. Platform-specific items:

| Issue | Status | What |
|-------|--------|------|
| platform#493 | CLOSED | Added agent + streams starters to spring-integration-test |
| platform#494 | CLOSED | Added @ConditionalOnMissingBean to 9 beans |

Landed as `3e7aaf0f` on main. Branch `issue-518-spring-completeness` stamped and closed.

## Earlier

- Closed platform#473 (K8s Spring fabric8 integration)
- Workers branch `issue-24-spring-boot-deployment` squash-merged (170 files, ~3990/~4400 lines)
- Triaged and closed 6 items from parent#515
