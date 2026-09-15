# Spring Deployment Completion — Design Spec

**Parent epic:** casehubio/parent#469
**Date:** 2026-09-15

## Goal

Complete Spring Boot deployment across all CaseHub repos. Core extraction (parent#469 child issues) is done — every repo has framework-neutral core modules. Spring generators (parent#474) are built — rest, graphql, mcp generators produce Spring source from Quarkus Jandex indexes. This epic connects the two: purge remaining Panache code, wire generators into consumer repos, and build the two missing Spring runtime modules.

## Prerequisites (complete)

- **Core extraction (parent#469 child issues):** All 9 repos have -core modules. All child issues closed.
- **Spring generators (parent#474):** generator-common, spring-generator (retrofitted), rest-spring-generator, graphql-spring-generator, mcp-spring-generator — all built, tested, merged to platform main.

## Current State

| Repo | Core | -spring Module | spring-gen | rest/graphql/mcp gen | Panache | Status |
|------|:-:|:-:|:-:|:-:|:-:|---|
| platform | ✅ 34 | ✅ platform-spring, view-spring | ✅ | ❌ | 11 entities | Needs purge + plugin wiring + runtime modules |
| engine | ✅ 6 | ✅ 6 -spring | ✅ | ❌ | 0 | Needs plugin wiring |
| work | ✅ 3 | ❌ | ❌ | ❌ | ~21 | Needs everything |
| qhorus | ✅ 1 | ✅ runtime-spring | ❌ | ❌ | ~22 | Needs spring-gen + plugins + Panache |
| ledger | ✅ 1 | ❌ | ❌ | ❌ | ~2 | Needs everything |
| eidos | ✅ 1 | ❌ | ❌ | ❌ | 0 | Needs -spring + plugins |
| neocortex | ✅ 3 | ✅ 3 -spring | ❌ | ❌ | 0 | Needs spring-gen + plugins |
| blocks | ✅ 2 | ✅ 2 -spring (local) | ✅ verify | ❌ | 0 | Push to origin/main + plugins |
| connectors | ✅ | ✅ connectors-spring | ❌ | ❌ | 0 | Needs spring-gen + plugins |

## Architecture

No new architectural patterns. This epic applies existing patterns to remaining repos:

- **Panache purge:** `extends PanacheEntityBase` → plain `@Entity`. `PanacheRepository` → `EntityManager` + JPQL. Same pattern used successfully across platform modules that already completed this migration.
- **-spring modules:** `spring-generator` plugin scans Quarkus module Jandex, produces `@AutoConfiguration` + `@Bean`. Existing pattern in platform-spring, engine-spring modules.
- **Generator plugin wiring:** Add `rest-spring-generator`, `graphql-spring-generator`, `mcp-spring-generator` plugins to `-spring` pom.xml where source annotations exist. Existing pattern in platform-spring/pom.xml.
- **mcp-spring runtime:** Spring equivalent of `GraphQLModelScanner` + `DynamicToolRegistrar`. Scans `@McpDomain` beans at startup, registers as MCP tools via Spring MCP SDK.
- **callback-spring:** CDI `@Decorator` → Spring `@Bean @Primary` wrapping via `CallbackInvoker`.

## Execution Order

### Batch 1: Platform Panache Purge (platform repo)

Strip all Panache from platform's -jpa modules.

**Entities (11 files):** Remove `extends PanacheEntityBase` — each is already a standard `@Entity` class.

| Module | Files |
|--------|-------|
| acl-jpa | AclEntryEntity, AclAuditLogEntity, ResourceParentEntity |
| notification-settings-jpa | SnoozeEntity, MuteRuleEntity, NotificationPreferencesEntity |
| platform-view-jpa | SubjectViewEntity, ViewMembershipEntity |
| persistence-jpa | PreferenceEntry |
| memory-jpa | MemoryEntry |
| digest-jpa | DigestBufferEntity |

**Stores:** Port Panache query API usage in store implementations to `EntityManager` + JPQL. Remove `quarkus-hibernate-orm-panache` dependency from each module's pom.

### Batch 2: Consumer Panache Porting (work, qhorus, ledger)

Same porting pattern as Batch 1 across 3 consumer repos.

| Repo | Files | Issue |
|------|:-----:|-------|
| ledger | 2 | casehubio/ledger#208 |
| work | ~21 | casehubio/work#401 |
| qhorus | ~22 | casehubio/qhorus#440 |

Order: ledger first (smallest, validates pattern), then work, then qhorus.

### Batch 3: Create Missing -spring Modules (work, ledger, eidos)

Create Spring auto-configuration modules for repos that have core modules but no -spring module.

| Repo | Core modules | -spring to create |
|------|-------------|-------------------|
| work | runtime-core, work-support-core, progress-core | work-spring |
| ledger | ledger-core | ledger-spring |
| eidos | eidos-core | eidos-spring |

Each: pom.xml with `spring-generator` plugin, parent pom module declaration, `<quarkusModule>` pointing at the Quarkus runtime module.

### Batch 4: Targeted Generator Plugin Wiring (all repos)

Audit each source module for `@Path`, `@McpDomain`, `@Tool` annotations using IntelliJ. Add generator plugins only where annotations exist.

Also fix 3 repos with -spring modules but no `spring-generator` plugin: qhorus, neocortex, connectors.

Verify goals run after wiring to confirm no drift.

### Batch 5: mcp-spring Runtime Module (platform repo)

Spring equivalent of `GraphQLModelScanner` + `DynamicToolRegistrar`:
- `SpringModelScanner @Configuration` — discovers `@McpDomain`-annotated beans via `ApplicationContext`
- Registers discovered operations as Spring MCP SDK tools
- Fires `ModelScanComplete` equivalent event
- Config: mirrors `casehub.mcp.*` properties

### Batch 6: callback-spring Module (platform repo)

CDI `@Decorator` → Spring `@Bean @Primary`:
- `CallbackDecoratorAutoConfiguration` — for each `@CallbackEligible` SPI, produces a `@Bean @Primary` that wraps the delegate
- When `CallbackRegistry` has registrations for the SPI, routes through `CallbackInvoker`
- When no registrations exist, delegates directly
- Fan-out vs single-impl controlled by `@CallbackEligible(fanOut)`

### Batch 7: Blocks Push (blocks repo)

Push 10 local commits (core extraction + spring modules) to origin/main. Already rebased onto current origin/main. Independent of other batches.

## Testing Strategy

- **Panache porting (Batches 1-2):** Existing tests must pass after porting. Run `mvn test` per module.
- **-spring modules (Batch 3):** `mvn install` with spring-generator verifies generation. Consumer integration tests validate wiring.
- **Generator wiring (Batch 4):** `mvn verify` runs all generator verify goals — drift detection catches missing Spring equivalents.
- **mcp-spring (Batch 5):** Unit tests for scanner + registration. Integration test with a test `@McpDomain` bean.
- **callback-spring (Batch 6):** Unit tests for decorator wrapping. Integration test with `CallbackRegistry` + test SPI.

## References

- specs/issue-474-spring-boot-generators/2026-09-14-spring-boot-generators-design.md — generator design
- specs/issue-474-spring-boot-generators/decisions.md — 9 generator design decisions (D1-D9)
- specs/issue-469-dual-framework-core-extraction/2026-09-07-dual-framework-core-extraction-design.md — core extraction design
- GE-20260420-7d28fa — Panache + plain @Entity runtime failure
- GE-0138 — Panache SPI return-type conflict
- GE-20260914-248827 — Synthetic annotation stubs for Jandex scanner testing
