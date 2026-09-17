# Spring Deployment Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** casehubio/parent#478 — Spring deployment completion
**Issue group:** casehubio/parent#478, casehubio/ledger#208, casehubio/work#401, casehubio/qhorus#440

**Goal:** Complete Spring Boot deployment across all CaseHub repos — purge Panache, create missing -spring modules, wire generator plugins, build mcp-spring and callback-spring runtime modules.

**Architecture:** Apply existing patterns (Panache→EntityManager, spring-generator plugin, rest/graphql/mcp generator plugins) across remaining repos. Two new platform modules (mcp-spring, callback-spring) provide Spring runtime equivalents of Quarkus MCP and callback infrastructure.

**Tech Stack:** Java 21, Quarkus 3.x, Spring Boot 3.4+, Maven, Jandex, JavaPoet, Spring MCP SDK, Spring GraphQL

## Global Constraints

- All repos in slot 192: `/Users/mdproctor/claude/casehub/slots/192/<repo>`
- Platform parent version: `0.2-SNAPSHOT`
- Generator plugins: `casehub-platform-rest-spring-generator`, `casehub-platform-graphql-spring-generator`, `casehub-platform-mcp-spring-generator`
- Panache porting: `extends PanacheEntityBase` → remove extends; `entity.persist()` → `em.persist(entity)`; remove `quarkus-hibernate-orm-panache` dependency
- All existing tests must pass after each task

---

## Batch 1: Platform Panache Purge

### Task 1: Strip PanacheEntityBase from platform -jpa entities and stores

**Files:**
- Modify: `../../../../acl-jpa-common/src/main/java/io/casehub/platform/acl/jpa/AclEntryEntity.java`
- Modify: `../../../../acl-jpa-common/src/main/java/io/casehub/platform/acl/jpa/AclAuditLogEntity.java`
- Modify: `../../../../acl-jpa-common/src/main/java/io/casehub/platform/acl/jpa/ResourceParentEntity.java`
- Modify: `../../../../notification-settings-jpa-common/src/main/java/io/casehub/platform/notification/settings/jpa/SnoozeEntity.java`
- Modify: `../../../../notification-settings-jpa-common/src/main/java/io/casehub/platform/notification/settings/jpa/MuteRuleEntity.java`
- Modify: `../../../../notification-settings-jpa-common/src/main/java/io/casehub/platform/notification/settings/jpa/NotificationPreferencesEntity.java`
- Modify: `../../../../platform-view-jpa-common/src/main/java/io/casehub/platform/view/jpa/SubjectViewEntity.java`
- Modify: `../../../../platform-view-jpa-common/src/main/java/io/casehub/platform/view/jpa/ViewMembershipEntity.java`
- Modify: `../../../../persistence-jpa-common/src/main/java/io/casehub/platform/persistence/jpa/PreferenceEntry.java`
- Modify: `../../../../memory-jpa-common/src/main/java/io/casehub/platform/memory/jpa/MemoryEntry.java`
- Modify: `../../../../digest-jpa-common/src/main/java/io/casehub/platform/delivery/digest/jpa/DigestBufferEntity.java`
- Modify: `acl-jpa/src/main/java/io/casehub/platform/acl/jpa/JpaAccessControlProvider.java` (6 persist calls)
- Modify: `persistence-jpa/src/main/java/io/casehub/platform/persistence/jpa/JpaPreferenceStore.java` (1 persist call)
- Modify: `memory-jpa/src/main/java/io/casehub/platform/memory/jpa/JpaMemoryStore.java` (2 persist calls)
- Modify: `acl-jpa/pom.xml`, `notification-settings-jpa/pom.xml`, `platform-view-jpa/pom.xml`, `persistence-jpa/pom.xml`, `memory-jpa/pom.xml`, `digest-jpa/pom.xml` — remove panache dependency

**Interfaces:**
- Consumes: None
- Produces: Panache-free -jpa modules usable from both Quarkus and Spring

- [ ] **Step 1: Strip PanacheEntityBase from all 11 entity files**

For each entity file, use `ide_replace_text_in_file` to:
1. Remove the import: `import io.quarkus.hibernate.orm.panache.PanacheEntityBase;`
2. Remove `extends PanacheEntityBase` from the class declaration

Example for AclEntryEntity:
```
searchText: "import io.quarkus.hibernate.orm.panache.PanacheEntityBase;\n"
replaceText: ""

searchText: "extends PanacheEntityBase "
replaceText: ""
```

Apply to all 11 files listed above.

- [ ] **Step 2: Port Panache persist() calls in store implementations**

In `JpaAccessControlProvider.java`: replace 6 instances of `entity.persist()` / `log.persist()` / `rp.persist()` / `existing.persist()` / `entry.persist()` with `entityManager.persist(entity)` (the class already has an `entityManager` field).

In `JpaPreferenceStore.java`: replace `entry.persist()` with `entityManager.persist(entry)`.

In `JpaMemoryStore.java`: replace `MemoryEntry.persist(entry)` with `entityManager.persist(entry)` and `MemoryEntry.persist(entries)` with a loop: `entries.forEach(entityManager::persist)`.

- [ ] **Step 3: Remove quarkus-hibernate-orm-panache dependency from 6 pom.xml files**

Use `ide_replace_text_in_file` to remove the Panache dependency block from each module's pom.xml:
```xml
<dependency>
    <groupId>io.quarkus</groupId>
    <artifactId>quarkus-hibernate-orm-panache</artifactId>
</dependency>
```

Modules: acl-jpa, notification-settings-jpa, platform-view-jpa, persistence-jpa, memory-jpa, digest-jpa.

- [ ] **Step 4: Run tests for all modified modules**

Run: `mvn --batch-mode -pl acl-jpa,notification-settings-jpa,platform-view-jpa,persistence-jpa,memory-jpa,digest-jpa test`
Expected: PASS — all tests green

- [ ] **Step 5: Commit**

```
refactor: strip PanacheEntityBase from platform -jpa modules

Remove extends PanacheEntityBase from 11 entity files.
Port 9 Panache persist() calls to entityManager.persist().
Remove quarkus-hibernate-orm-panache dependency from 6 modules.

Closes casehubio/parent#478 (partial)
```

---

## Batch 2: Consumer Panache Porting

### Task 2: Port Panache to plain JPA in ledger (2 files)

**Files:**
- Modify: 2 files in `/Users/mdproctor/claude/casehub/slots/192/ledger/` using Panache APIs
- Test: Existing tests must pass

**Interfaces:**
- Consumes: Panache porting pattern from Task 1
- Produces: Framework-neutral JPA persistence in ledger

- [ ] **Step 1: Find Panache files**

Use `ide_search_text` with query `PanacheRepository` and `PanacheEntityBase` in the ledger project.

- [ ] **Step 2: Port each file**

Apply porting rules:
- `PanacheRepository<E>` → inject `EntityManager`, use JPQL
- `entity.persist()` → `em.persist(entity)`
- `entity.find("field", value)` → `em.createQuery(...)`
- `PanacheEntityBase` → remove extends
- Remove Panache imports and dependency

- [ ] **Step 3: Run tests**

Run: `mvn --batch-mode -f /Users/mdproctor/claude/casehub/slots/192/ledger/pom.xml test`
Expected: PASS

- [ ] **Step 4: Commit in ledger repo**

```
refactor: port Panache to plain JPA

Replace PanacheRepository with EntityManager + JPQL.
Framework-neutral persistence for Spring Boot compatibility.

Closes casehubio/ledger#208
```

### Task 3: Port Panache to plain JPA in work (21 files)

Same pattern as Task 2 applied to `/Users/mdproctor/claude/casehub/slots/192/work/`.

- [ ] **Step 1: Find all Panache files in work**
- [ ] **Step 2: Port each file, grouped by submodule**
- [ ] **Step 3: Run tests after each submodule group**

Run: `mvn --batch-mode -f /Users/mdproctor/claude/casehub/slots/192/work/pom.xml test`

- [ ] **Step 4: Commit**

```
refactor: port Panache to plain JPA (21 files)

Closes casehubio/work#401
```

### Task 4: Port Panache to plain JPA in qhorus (22 files)

Same pattern applied to `/Users/mdproctor/claude/casehub/slots/192/qhorus/`.

- [ ] **Step 1: Find all Panache files in qhorus**
- [ ] **Step 2: Port each file**
- [ ] **Step 3: Run tests**

Run: `mvn --batch-mode -f /Users/mdproctor/claude/casehub/slots/192/qhorus/pom.xml test`

- [ ] **Step 4: Commit**

```
refactor: port Panache to plain JPA (22 files)

Closes casehubio/qhorus#440
```

---

## Batch 3: Create Missing -spring Modules

### Task 5: Create work-spring auto-configuration module

**Files:**
- Create: `work-spring/pom.xml` in work repo
- Modify: `pom.xml` (parent — add module)
- Generated: `work-spring/target/generated-sources/spring-generator/` (by spring-generator plugin)

**Interfaces:**
- Consumes: work/runtime-core module (the core POJOs)
- Produces: Spring @AutoConfiguration beans for work runtime

- [ ] **Step 1: Create work-spring/pom.xml**

Follow the pattern from engine/runtime-spring/pom.xml:
- Parent: work parent pom
- Packaging: jar
- Dependencies: work runtime-core, spring-boot-autoconfigure, spring-boot-starter
- Plugin: casehub-platform-spring-generator with `<quarkusModule>` pointing at runtime module

- [ ] **Step 2: Add module to parent pom**
- [ ] **Step 3: Build and verify generation**

Run: `mvn --batch-mode -pl work-spring install`

- [ ] **Step 4: Commit**

### Task 6: Create ledger-spring auto-configuration module

Same pattern as Task 5 for the ledger repo. Follow engine/ledger-spring/pom.xml as template.

- [ ] **Step 1: Create ledger-spring/pom.xml**
- [ ] **Step 2: Add module to parent pom**
- [ ] **Step 3: Build and verify**
- [ ] **Step 4: Commit**

### Task 7: Create eidos-spring auto-configuration module

Same pattern for the eidos repo.

- [ ] **Step 1: Create eidos-spring/pom.xml**
- [ ] **Step 2: Add module to parent pom**
- [ ] **Step 3: Build and verify**
- [ ] **Step 4: Commit**

---

## Batch 4: Targeted Generator Plugin Wiring

### Task 8: Wire generator plugins based on annotation audit

Annotation audit results:

| Repo | @Path | @McpDomain | @Tool | Generators to wire |
|------|:-:|:-:|:-:|---|
| platform | 5 | 11 | 0 | rest + graphql |
| engine | ~8 | 2 | 0 | rest + graphql |
| work | ~25 | 4 | 0 | rest + graphql |
| qhorus | ~3 | ~8 | 0 | spring-gen + rest + graphql |
| ledger | 2 | 4 | 0 | rest + graphql |
| eidos | 0 | 0 | 0 | spring-gen only |
| neocortex | 0 | 1 | 0 | spring-gen + graphql |
| blocks | 0 | 0 | 0 | none (spring-gen already present) |
| connectors | 0 | 0 | 0 | spring-gen only |

No @Tool in any core repo — mcp-spring-generator only needed for connector repos (out of scope).

**Files:**
- Modify: -spring pom.xml files per table above

**Interfaces:**
- Consumes: Existing -spring modules from Batches 1-3
- Produces: Generator plugins wired, verify goals passing

- [ ] **Step 1: Fix repos with missing spring-generator**

Add `casehub-platform-spring-generator` plugin to -spring poms that are missing it: qhorus/runtime-spring, neocortex/*-spring, connectors/connectors-spring, eidos/eidos-spring (new from Batch 3).

- [ ] **Step 2: Add rest-spring-generator to platform, engine, work, qhorus, ledger**

Add plugin declaration to each repo's -spring pom.xml, pointing `<quarkusModule>` at the runtime module containing @Path resources.

- [ ] **Step 3: Add graphql-spring-generator to platform, engine, work, qhorus, ledger, neocortex**

Add plugin declaration where @McpDomain interfaces exist.

- [ ] **Step 4: Run verify goals across all repos**

For each repo with -spring modules:
```
mvn --batch-mode verify -pl <spring-module>
```

- [ ] **Step 5: Commit per repo**

---

## Batch 5: mcp-spring Runtime Module

### Task 9: Create mcp-spring module with SpringModelScanner

**Files:**
- Create: `mcp-spring/pom.xml` in platform
- Create: `mcp-spring/src/main/java/io/casehub/platform/mcp/spring/SpringModelScanner.java`
- Create: `mcp-spring/src/main/java/io/casehub/platform/mcp/spring/SpringDynamicToolRegistrar.java`
- Create: `mcp-spring/src/test/java/io/casehub/platform/mcp/spring/SpringModelScannerTest.java`
- Modify: platform `pom.xml` (add module)

**Interfaces:**
- Consumes: `@McpDomain` annotation from platform-api, `ModelEnricher` SPI, `McpResourceRegistry` SPI
- Produces: Spring runtime MCP tool registration equivalent to Quarkus GraphQLModelScanner + DynamicToolRegistrar

- [ ] **Step 1: Study Quarkus implementation**

Read `mcp/src/main/java/io/casehub/platform/mcp/GraphQLModelScanner.java` and `DynamicToolRegistrar.java` to understand the runtime scanning and registration flow.

- [ ] **Step 2: Write failing test for SpringModelScanner**

Test that the scanner discovers @McpDomain-annotated beans from a Spring ApplicationContext and produces domain operation metadata.

- [ ] **Step 3: Implement SpringModelScanner**

`@Configuration` class that:
- Scans `ApplicationContext` for beans with `@McpDomain` annotation
- Extracts `@PlatformQuery` and `@PlatformMutation` methods
- Registers them with Spring MCP SDK as tools
- Fires a Spring event equivalent to `ModelScanComplete`

- [ ] **Step 4: Write failing test for SpringDynamicToolRegistrar**

Test that the registrar builds JSON Schema input from method parameters and registers tools.

- [ ] **Step 5: Implement SpringDynamicToolRegistrar**

Mirrors `DynamicToolRegistrar` behavior: builds tool schema, registers with Spring MCP SDK's `ToolManager` or equivalent registration API.

- [ ] **Step 6: Run all tests**

Run: `mvn --batch-mode -pl mcp-spring test`

- [ ] **Step 7: Commit**

```
feat: add mcp-spring runtime module — Spring MCP tool registration

Spring equivalent of GraphQLModelScanner + DynamicToolRegistrar.
Discovers @McpDomain beans at startup, registers as MCP tools
via Spring MCP SDK.

Refs casehubio/parent#478
```

---

## Batch 6: callback-spring Module

### Task 10: Create callback-spring module with decorator wrapping

**Files:**
- Create: `callback-spring/pom.xml` in platform
- Create: `callback-spring/src/main/java/io/casehub/platform/callback/spring/CallbackDecoratorAutoConfiguration.java`
- Create: `callback-spring/src/test/java/io/casehub/platform/callback/spring/CallbackDecoratorTest.java`
- Modify: platform `pom.xml` (add module)

**Interfaces:**
- Consumes: `@CallbackEligible` annotation from platform-api, `CallbackRegistry` SPI, `CallbackInvoker`
- Produces: Spring @Bean @Primary wrappers that route SPI calls through CallbackInvoker when registrations exist

- [ ] **Step 1: Study Quarkus callback-generator output**

Read `callback-generator/` to understand the CDI @Decorator pattern. Read existing generated decorators to understand the wrapping pattern.

- [ ] **Step 2: Write failing test**

Test that a @CallbackEligible SPI gets wrapped by a @Primary bean that checks CallbackRegistry and routes through CallbackInvoker when registrations exist, delegates directly otherwise.

- [ ] **Step 3: Implement CallbackDecoratorAutoConfiguration**

For each `@CallbackEligible` SPI discovered via `ApplicationContext`:
- Create a `@Bean @Primary` that wraps the delegate
- On invocation: check `CallbackRegistry.findBySpi(spiName)` for registrations
- If registrations exist: route through `CallbackInvoker` (fan-out or first-wins per `@CallbackEligible(fanOut)`)
- If no registrations: delegate directly

- [ ] **Step 4: Run tests**

Run: `mvn --batch-mode -pl callback-spring test`

- [ ] **Step 5: Commit**

```
feat: add callback-spring module — @Decorator → @Bean @Primary

Spring equivalent of CDI @Decorator callback interception.
Wraps @CallbackEligible SPIs with @Primary beans that route
through CallbackInvoker when registrations exist.

Refs casehubio/parent#478
```

---

## Batch 7: Blocks Push

### Task 11: Push blocks core extraction to origin/main

**Files:**
- No file changes — push only

- [ ] **Step 1: Verify local main is clean and ahead of origin**

```bash
git -C /Users/mdproctor/claude/casehub/slots/192/blocks status --short
git -C /Users/mdproctor/claude/casehub/slots/192/blocks rev-list --count origin/main..main
```
Expected: clean, 10 commits ahead

- [ ] **Step 2: Run full build**

```bash
mvn --batch-mode -f /Users/mdproctor/claude/casehub/slots/192/blocks/pom.xml install
```
Expected: BUILD SUCCESS

- [ ] **Step 3: Push**

```bash
git -C /Users/mdproctor/claude/casehub/slots/192/blocks push origin main
```

- [ ] **Step 4: Verify**

```bash
git -C /Users/mdproctor/claude/casehub/slots/192/blocks rev-list --count origin/main..main
```
Expected: 0

---

## References

- [specs/spring-deployment-completion/2026-09-15-spring-deployment-completion-design.md] — design spec
- [specs/spring-deployment-completion/decisions.md] — 4 design decisions (D1-D4)
- [specs/issue-474-spring-boot-generators/2026-09-14-spring-boot-generators-design.md] — generator design
- [specs/issue-469-dual-framework-core-extraction/2026-09-07-dual-framework-core-extraction-design.md] — core extraction design
- [mcp/src/main/java/io/casehub/platform/mcp/GraphQLModelScanner.java] — Quarkus MCP scanner
- [mcp/src/main/java/io/casehub/platform/mcp/DynamicToolRegistrar.java] — Quarkus MCP registrar
- [callback-generator/] — CDI @Decorator generation pattern
- [GE-20260420-7d28fa] — Panache + plain @Entity runtime failure
- [GE-0138] — Panache SPI return-type conflict
- [casehubio/parent#478] — tracking issue
- [casehubio/parent#469] — parent epic
- [casehubio/ledger#208, casehubio/work#401, casehubio/qhorus#440] — Panache porting issues
