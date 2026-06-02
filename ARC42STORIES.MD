# casehub-platform — ARC42STORIES.MD

**Spec:** Arc42Stories v0.1
**Profile:** CaseHub — Foundation tier
**Profile ref:** `../parent/docs/arc42stories-casehub-profile.md` · fallback: `https://raw.githubusercontent.com/casehubio/parent/main/docs/arc42stories-casehub-profile.md`
**Build position:** First in the foundation stack — no casehubio dependencies. Must publish before ledger, connectors, work, qhorus, eidos, engine.
**Consumed by:** casehub-ledger, casehub-connectors, casehub-work (api), casehub-qhorus, casehub-eidos, casehub-engine, all application-tier harness apps
**Depends on:** None — zero casehubio dependencies. Pure Java APIs + Quarkus extension modules with no upstream casehub deps.

---

## §1 Introduction and Goals

### Description

`casehub-platform` is the zero-dependency foundational SPI layer for the CasHub ecosystem. It defines shared interfaces and default implementations that all other foundation modules and application-tier repos depend on without creating circular dependencies.

Core capabilities: `Path` (hierarchical scope keys for preferences), `PreferenceKey` / `PreferenceProvider` (scoped configuration SPIs), `CurrentPrincipal` (identity context), `ActorType` / `ActorTypeResolver` (actor classification), `CaseMemoryStore` (semantic memory SPI), `GroupMembershipProvider` (SCIM-based group membership).

Module structure: `platform-api` (SPIs, zero heavy deps), `platform` (default @DefaultBean mocks, ReactiveCaseMemoryStore SPI, BlockingToReactiveBridge), `testing` (@Alternative identity fixtures), `config/` (YAML preference provider), `oidc/` (OIDC CurrentPrincipal), `expression/` (JQEvaluator), `persistence-jpa/` (JPA PreferenceProvider), `persistence-mongodb/` (MongoDB PreferenceProvider), `memory-inmem/` (volatile CaseMemoryStore), `memory-jpa/` (JPA CaseMemoryStore with FTS), `memory-sqlite/` (SQLite CaseMemoryStore with FTS5), `scim/` (SCIM 2.0 GroupMembershipProvider). Memory adapters are mutually exclusive — do not combine inmem+jpa or inmem+sqlite in the same scope.

### Stakeholders

| Stakeholder | Interest |
|---|---|
| Application-tier harness apps | Consume this module's foundation primitives |
| Platform team | Maintain correctness and backward compatibility |
| LLM sessions (Claude) | Navigate architecture and implement extensions confidently |

### Quality Goals

| Goal | Scenario |
|---|---|
| Zero circular deps | casehub-platform must never depend on casehub-ledger, casehub-work, or any other foundation module |
| SPI isolation | platform-api must not expose heavy external SDK types in method signatures |
| Adapter exclusivity | memory adapter implementations are mutually exclusive — exactly one active per deployment scope |

---

## §2 Constraints

### Platform
Java 21 (on Java 26 JVM), Quarkus 3.32.2. Published to GitHub Packages as `io.casehub:casehub-platform:0.2-SNAPSHOT`.

```bash
JAVA_HOME=$(/usr/libexec/java_home -v 26) mvn clean install
```

### Dependencies
Resolved from GitHub Packages: `https://maven.pkg.github.com/casehubio/*`. CI authentication via `GITHUB_TOKEN`.

---

## §3 Context and Scope

🔲 C4Context diagram — add in dedicated session.

**Boundary rules:** casehub-platform owns only the concerns described in §1. Domain logic (business rules, application-specific workflows) belongs in application-tier repos (devtown, aml, clinical, life, drafthouse, quarkmind).

See `../parent/docs/PLATFORM.md` Capability Ownership table for the full boundary map.

---

## §4 Solution Strategy

🔲 Core architectural patterns and module structure — complete in dedicated session from DESIGN.md and repo architecture.

---

## §5 Building Block View

🔲 C4Container diagram and module structure — complete in dedicated session.

---

## §6 Runtime View

🔲 Key runtime scenarios — complete in dedicated session.

---

## §7 Deployment View

Published to GitHub Packages. CI: GitHub Actions. No GraalVM native target (foundation modules).

---

## §8 Crosscutting Concepts

References to governing protocols:

| Concern | Protocol / Reference |
|---|---|
| Module structure | `docs/protocols/universal/module-tier-structure.md` |
| Flyway migrations | `docs/protocols/universal/flyway-migration-rules.md` |
| CDI displacement (`@DefaultBean`) | `docs/protocols/casehub/alternative-extension-patterns.md` |
| Capability ownership | `../parent/docs/PLATFORM.md` Capability Ownership table |
| Architectural patterns | `../parent/docs/ARCHITECTURE.md` |

🔲 Anti-patterns inline (Symptom → Cause → Fix) — complete in dedicated session. Must be present per profile rules; do not defer to AGENTIC-HARNESS-GUIDE.md reference alone.

---

## §9 Journeys and Chapters

🔲 **Bootstrap — full Journeys and Chapters pending dedicated session.**

Foundation modules use Chapters to track delivery milestones of the foundation capability itself (transport types, SPI increments, new adapters) rather than integrating external foundation modules.

Read `../parent/docs/arc42stories-spec.md §4 Solution Strategy` — "Foundation: Chapters = delivery milestones of the foundation capability itself."

The full §9 entry requires:
- Reading DESIGN.md (or equivalent) for the delivery arc
- Mapping milestones to Chapters
- Writing §9.4 Layer/Chapter entries with all 18 required subsections

---

## §10 Architectural Decisions

Per the Arc42Stories spec: only decisions not captured inline elsewhere. Should be sparse.

🔲 Cross-cutting decisions — complete in dedicated session.

---

## §11 Quality Requirements

See §1 Quality Goals for the primary scenarios.

🔲 Full quality requirements table — complete in dedicated session.

---

## §12 Risks and Technical Debt

🔲 Active risks and technical debt — complete in dedicated session.

---

## §13 Glossary

| Term | Definition |
|---|---|
| `PreferenceKey` | Typed key for a scoped configuration value — namespace, name, default, and parser. |
| `PreferenceProvider` | SPI for resolving preferences by scope Path. Default implementation reads from YAML; JPA and MongoDB adapters available. |
| `Path` | Hierarchical scope key (e.g. devtown/security-review/threshold). Used for preference scoping and capability routing. |
| `CaseMemoryStore` | SPI for semantic memory — store and recall facts about entities across case boundaries. |
| `ActorType` | Enum: AI_AGENT | HUMAN | SYSTEM. Central identity classification used across qhorus, ledger, engine. |
| `CurrentPrincipal` | CDI-injectable identity context for the current request actor. |

---

*Bootstrap document — generated 2026-06-02. §3–§9 require a dedicated session to complete from repository source material.*
