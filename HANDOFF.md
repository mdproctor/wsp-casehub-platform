# HANDOFF — casehub-platform

**Date:** 2026-05-29
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Shipped `memory-inmem/` (volatile ConcurrentHashMap, 21 tests) and `memory-jpa/` (JPA/Panache, Flyway V1000, PostgreSQL FTS, 20 tests) as Tier 1 `CaseMemoryStore` adapters — platform#32 closed. Breaking SPI change: `EraseRequest.domain` made required; `eraseEntity()` added as `default throw` on `CaseMemoryStore` + `ReactiveCaseMemoryStore`. ADR-0008 amended and #31 closed — adapters live in-platform (not separate repo). Full build green at 268 tests.

## Immediate Next Step

`work-start` on **GroupMembership OIDC provider** — deferred three times now.

## Cross-Module

No active blockers. Consumer adoption for CaseMemoryStore tracked in devtown#43, clinical#33, aml#32 — no platform action needed. PLATFORM.md in parent is stale (parent#90) — update needed there, not here.

## What's Left

- Hook install still pending on 5 repos: `casehub/aml`, `casehub/clinical`, `hortora/garden`, `md-compare`, `casehub-poc` · XS · Low
- `md-compare` — legacy commit-msg hook in `.git/hooks/`, migrate when branch returns · XS · Low
- `casehub-parent/docs/repos/casehub-platform.md` — deep-dive needs memory module sync (parent#85) · XS · Low
- `docs/PLATFORM.md` in parent — stale (casehub-memory refs; filed parent#90) · XS · Low

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| — | GroupMembership OIDC provider | M | Med | Needs directory (Keycloak Admin/LDAP) |
| #37 | `memory-sqlite/` — SQLite adapter, durable pure-Java | M | Med | Evaluate single-writer concurrency first |
| #38 | FTS Testcontainers integration test for `memory-jpa/` | S | Low | H2 tests cover chronological only |
| #39 | CDI priority revisit when `memory-mem0/` arrives — `@Priority(1)` conflict is startup-breaking | S | Med | Block on #33 |
| #40 | `memory-memori/` REST adapter — pending Memori API stabilisation | L | Med | Pre-condition: verify DELETE entity_id without process_id |
| #8 | `preferences-editor/` — admin UI/API write path | XL | High | Parked — no UI work |

## References

- Spec: `docs/specs/2026-05-29-memory-jpa-inmem-design.md`
- ADR: `adr/0008-casememory-adapter-repository-placement.md` (amended 2026-05-29)
- Blog: `blog/2026-05-29-mdp01-the-memori-that-wasnt.md`
- Garden: GE-20260529-8e127e (@TestTransaction), GE-20260529-bc1eaa (TIMESTAMPTZ), GE-20260529-7985ba (flyway.migrate-at-start), GE-0134 revised (build goal omission)
- Protocol: PP-20260529-57cc3b (casememorystore-adapter-asserttenant-contract), PP-20260529-spi-adapter-placement (universal)
