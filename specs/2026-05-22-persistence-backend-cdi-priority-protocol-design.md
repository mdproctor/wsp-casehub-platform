# Design: Persistence-Backend CDI Priority Protocol (parent#44)

**Date:** 2026-05-22  
**Issue:** casehubio/parent#44  
**Branch:** issue-26-batch-housekeeping

---

## What we're writing

Three artifacts:

1. **New protocol file** — `docs/protocols/universal/persistence-backend-cdi-priority.md` in the casehub garden
2. **Update** — `docs/protocols/casehub/platform-spi-contract.md` Rule 2 renamed and Rule 3 added
3. **PLATFORM.md row** — one row in the Implementation Protocols table (`casehubio/parent`)

---

## Design decisions

### Protocol scope: universal

The three-tier CDI priority ladder is not casehub-specific. Any Quarkus project that ships
multiple competing implementations of the same SPI can use this pattern. Goes in `universal/`.

### The ladder

| Tier | Annotation | CDI resolution | Use case |
|------|-----------|---------------|----------|
| 1 | `@DefaultBean` | Yielded by any non-default bean | Mock / no-op — ships with SPI |
| 2 | `@ApplicationScoped` | Beats `@DefaultBean` | JPA / SQL primary backend |
| 3 | `@Alternative @Priority(1)` | Beats `@ApplicationScoped` | NoSQL / secondary backend |

**Co-deployment guarantee:** adding a NoSQL module to the classpath silently promotes it to
active backend with no consumer code changes. This is the design intent: additive activation.

### Rule structure in platform-spi-contract.md (Option B)

Rule 2 renamed to "Primary backend: use `@ApplicationScoped`" (JPA/SQL case only).  
New Rule 3 "Secondary backend: use `@Alternative @Priority(1)`" (NoSQL case, beats JPA).  
Rationale: Option A (sub-sections) left a misleading title that callers would hit before
reading the corrective text. B is clean. No other protocol cites rule numbers.

### PLATFORM.md placement

Implementation Protocols table — same section as flyway-migration-rules, optional-module-pattern,
and submodule-folder-naming. Capability Ownership table was rejected: it describes ownership,
not wiring conventions. One new row, no structural change to PLATFORM.md.

---

## Protocol content outline

**persistence-backend-cdi-priority.md**

- Frontmatter: scope=universal, severity=important, refs=[platform-spi-contract.md]
- Rule statement: the three-tier ladder with a table
- Per-tier implementation guide (what annotation, what module tier, example class)
- Co-deployment guarantee: classpath additive, no consumer changes
- What NOT to do: @Alternative on a primary backend (breaks when a secondary is absent); 
  @DefaultBean on a real implementation (won't beat other real implementations)
- Test note: `@QuarkusTest` loads all on-classpath alternatives — test isolation requires 
  `@QuarkusTestProfile` or selective module scoping

---

## Out of scope

- Priority values above 1 — not needed yet; if a fourth tier appears, revisit
- Quarkus 3.x CDI changes — the ladder is stable across 3.x releases tested so far
