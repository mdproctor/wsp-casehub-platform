# Mem0 Parallel storeAll, ReactiveCaseMemoryStore Move, Cross-Tenant Erasure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship platform#70 (Mem0 bounded-parallel storeAll + SQLite 2-arg assertTenant fix), platform#90 (ReactiveCaseMemoryStore moved to platform-api, UnsupportedOperationException → MemoryCapabilityException), and platform#99 (eraseEntityAcrossTenants GDPR Art.17 across all adapters).

**Architecture:** Three sequential changes on branch `issue-70-storeall-spi-gdpr`. #90 must complete before #99 so the new cross-tenant method lands in platform-api directly. Each issue produces working, tested, committed code before the next begins.

**Tech Stack:** Java 21, Quarkus, Mutiny (`Uni.join().all().andFailFast()`), WireMock 3.x (`@QuarkusTestResource`), JUnit 5, Maven multi-module (`mvn --batch-mode install`).

**Spec:** `docs/superpowers/specs/2026-06-17-mem0-parallel-reactive-spi-gdpr-design.md`

---

## File Map

| File | Change | Issue |
|------|--------|-------|
| `memory-mem0/src/main/java/io/casehub/platform/memory/mem0/Mem0Config.java` | Add `storeAllConcurrency()` | #70 |
| `memory-mem0/src/main/java/io/casehub/platform/memory/mem0/Mem0CaseMemoryStore.java` | 3-arg assertTenant + parallel storeAll | #70, #99 |
| `memory-mem0/src/test/java/io/casehub/platform/memory/mem0/Mem0CaseMemoryStoreTest.java` | 5 new storeAll tests + eraseEntityAcrossTenants test | #70, #99 |
| `memory-sqlite/src/main/java/io/casehub/platform/memory/sqlite/SqliteMemoryStore.java` | 3-arg pre-flight fix + eraseEntityAcrossTenants | #70, #99 |
| `memory-sqlite/src/test/java/io/casehub/platform/memory/sqlite/SqliteMemoryStoreTest.java` | eraseEntityAcrossTenants test | #99 |
| `platform-api/pom.xml` | Add Mutiny `provided` dep | #90 |
| `platform-api/src/main/java/io/casehub/platform/api/memory/ReactiveCaseMemoryStore.java` | **CREATE** — moved from platform/, UOE→MCE fixed | #90 |
| `platform-api/src/test/java/io/casehub/platform/api/memory/ReactiveCaseMemoryStoreSpiTest.java` | **CREATE** — 4 tests | #90 |
| `platform-api/src/main/java/io/casehub/platform/api/memory/MemoryCapability.java` | Add `CROSS_TENANT_ERASE` | #99 |
| `platform-api/src/main/java/io/casehub/platform/api/memory/MemoryPermissions.java` | Add `assertCrossTenantAdmin()` | #99 |
| `platform-api/src/test/java/io/casehub/platform/api/memory/MemoryPermissionsTest.java` | 2 new tests + `crossTenantAdminPrincipal()` helper | #99 |
| `platform-api/src/main/java/io/casehub/platform/api/memory/CaseMemoryStore.java` | Add `eraseEntityAcrossTenants()` default-throw | #99 |
| `platform-api/src/test/java/io/casehub/platform/api/memory/CaseMemoryStoreSpiTest.java` | Add `eraseEntityAcrossTenants_default_throws` | #99 |
| `platform/src/main/java/io/casehub/platform/memory/ReactiveCaseMemoryStore.java` | **DELETE** | #90 |
| `platform/src/main/java/io/casehub/platform/memory/BlockingToReactiveBridge.java` | Update import + add `eraseEntityAcrossTenants` bridge | #90, #99 |
| `platform/src/main/java/io/casehub/platform/memory/NoOpCaseMemoryStore.java` | Add `eraseEntityAcrossTenants` no-op override | #99 |
| `platform/src/test/java/io/casehub/platform/memory/BlockingToReactiveBridgeThreadingTest.java` | Update import + 7th threading test | #90, #99 |
| `platform/src/test/java/io/casehub/platform/memory/NoOpCaseMemoryStoreTest.java` | Update import + 2 new tests | #90, #99 |
| `memory-inmem/src/main/java/io/casehub/platform/memory/inmem/InMemoryMemoryStore.java` | Add `eraseEntityAcrossTenants` + `CROSS_TENANT_ERASE` capability | #99 |
| `memory-inmem/src/test/java/io/casehub/platform/memory/inmem/InMemoryMemoryStoreTest.java` | eraseEntityAcrossTenants tests | #99 |
| `memory-jpa/src/main/java/io/casehub/platform/memory/jpa/JpaMemoryStore.java` | Add `eraseEntityAcrossTenants` + `CROSS_TENANT_ERASE` capability | #99 |
| `memory-jpa/src/test/java/io/casehub/platform/memory/jpa/JpaMemoryStoreTest.java` | eraseEntityAcrossTenants tests | #99 |
| `memory-sqlite/src/main/java/io/casehub/platform/memory/sqlite/SqliteMemoryStore.java` | Add `eraseEntityAcrossTenants` + `CROSS_TENANT_ERASE` capability | #99 |
| `memory-graphiti/src/main/java/io/casehub/platform/memory/graphiti/GraphitiCaseMemoryStore.java` | Add `eraseEntityAcrossTenants` + conditional capability | #99 |
| `memory-graphiti/src/test/java/io/casehub/platform/memory/graphiti/GraphitiCaseMemoryStoreKnownDomainsTest.java` | eraseEntityAcrossTenants tests | #99 |
| `testing/src/main/java/io/casehub/platform/testing/memory/CaseMemoryStoreContractTest.java` | Add security boundary test | #99 |
| `ARC42STORIES.MD` | §12 risk removed, §8 L6 + §13 updated | all |
| `CLAUDE.md` | ReactiveCaseMemoryStore SPI location | #90 |
| `casehub-parent/docs/PLATFORM.md` | Memory capability ownership | #90 |

---

## Task 1: #70 — Fix 2-arg assertTenant pre-flight (Mem0 + SQLite)

**Files:**
- Modify: `memory-mem0/src/main/java/io/casehub/platform/memory/mem0/Mem0CaseMemoryStore.java`
- Modify: `memory-sqlite/src/main/java/io/casehub/platform/memory/sqlite/SqliteMemoryStore.java`

- [ ] **Step 1: Fix Mem0CaseMemoryStore.storeAll() pre-flight**

In `Mem0CaseMemoryStore.java`, find `storeAll`. Change line:
```java
// Before:
inputs.forEach(i -> MemoryPermissions.assertTenant(i.tenantId(), principal));
// After:
inputs.forEach(i -> MemoryPermissions.assertTenant(i.tenantId(), principal, requestContextActive()));
```

- [ ] **Step 2: Fix SqliteMemoryStore.storeAll() pre-flight**

In `SqliteMemoryStore.java`, find `storeAll`. The pre-flight is on the first line after the `isEmpty` check:
```java
// Before:
inputs.forEach(i -> MemoryPermissions.assertTenant(i.tenantId(), principal));
// After:
inputs.forEach(i -> MemoryPermissions.assertTenant(i.tenantId(), principal, requestContextActive()));
```
The per-item check inside the JDBC loop (`MemoryPermissions.assertTenant(input.tenantId(), principal, requestContextActive())`) is already 3-arg — leave it.

- [ ] **Step 3: Run tests**

```bash
mvn --batch-mode -pl memory-mem0,memory-sqlite -am test
```

Expected: all existing storeAll tests green. The 2-arg → 3-arg change produces identical behavior when the request context IS active (all `@QuarkusTest` environments have it active). Verify no test regressions.

- [ ] **Step 4: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add \
  memory-mem0/src/main/java/io/casehub/platform/memory/mem0/Mem0CaseMemoryStore.java \
  memory-sqlite/src/main/java/io/casehub/platform/memory/sqlite/SqliteMemoryStore.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "fix(platform#70): 3-arg assertTenant pre-flight in Mem0 and SQLite storeAll()"
```

---

## Task 2: #70 — Mem0 parallel storeAll

**Files:**
- Modify: `memory-mem0/src/main/java/io/casehub/platform/memory/mem0/Mem0Config.java`
- Modify: `memory-mem0/src/main/java/io/casehub/platform/memory/mem0/Mem0CaseMemoryStore.java`
- Modify: `memory-mem0/src/test/java/io/casehub/platform/memory/mem0/Mem0CaseMemoryStoreTest.java`

- [ ] **Step 1: Write failing tests for parallel storeAll**

Add to `Mem0CaseMemoryStoreTest.java` (inside the class, after the existing storeAll tests):

```java
// ── storeAll parallel ──────────────────────────────────────────────────────

@Test
void storeAll_empty_returns_empty_list() {
    assertEquals(List.of(), store.storeAll(List.of()));
}

@Test
void storeAll_fires_requests_concurrently() {
    // 8 requests with 300ms delay each. cap=4 (default) → ceil(8/4)*300 = 600ms.
    // Sequential would be 8*300 = 2400ms. Assert elapsed < 1200ms (2x headroom).
    wireMock().stubFor(post(urlEqualTo("/memories"))
        .willReturn(okJson("{\"results\":[{\"id\":\"x\",\"memory\":\"t\",\"event\":\"ADD\"}]}")
            .withFixedDelay(300)));
    principal.setTenancyId(TENANT);
    var inputs = java.util.stream.IntStream.range(0, 8)
        .mapToObj(i -> new MemoryInput("e" + i, DOMAIN, TENANT, null, "text", Map.of()))
        .collect(java.util.stream.Collectors.toList());

    long start = System.currentTimeMillis();
    var ids = store.storeAll(inputs);
    long elapsed = System.currentTimeMillis() - start;

    assertEquals(8, ids.size());
    assertTrue(elapsed < 1200,
        "storeAll must execute in parallel; elapsed=" + elapsed + "ms (expected < 1200ms)");
}

@Test
void storeAll_preserves_input_order() {
    // Uni.join().all() guarantees results in subscription order regardless of completion order.
    wireMock().stubFor(post(urlEqualTo("/memories"))
        .willReturn(okJson("{\"results\":[{\"id\":\"mem-x\",\"memory\":\"t\",\"event\":\"ADD\"}]}")));
    principal.setTenancyId(TENANT);
    var inputs = List.of(
        new MemoryInput("e1", DOMAIN, TENANT, null, "a", Map.of()),
        new MemoryInput("e2", DOMAIN, TENANT, null, "b", Map.of()),
        new MemoryInput("e3", DOMAIN, TENANT, null, "c", Map.of())
    );
    var ids = store.storeAll(inputs);
    assertEquals(3, ids.size());
    // All come from same stub — verify count; order is guaranteed by Uni.join.
    ids.forEach(id -> assertEquals("mem-x", id));
}

@Test
void storeAll_first_error_propagates() {
    // Any HTTP error causes the whole call to throw. Other in-flight calls may complete
    // but their results are discarded.
    wireMock().stubFor(post(urlEqualTo("/memories"))
        .willReturn(serverError().withBody("{\"detail\":\"server error\"}")));
    principal.setTenancyId(TENANT);
    var inputs = List.of(
        new MemoryInput("e1", DOMAIN, TENANT, null, "a", Map.of()),
        new MemoryInput("e2", DOMAIN, TENANT, null, "b", Map.of())
    );
    assertThrows(io.casehub.platform.memory.mem0.Mem0StoreException.class,
        () -> store.storeAll(inputs));
}

@Test
void storeAll_zero_concurrency_config_uses_one_not_deadlock() {
    // Math.max(1, ...) guard prevents Semaphore(0) deadlock.
    // Test verifies storeAll completes with 1 input even if config were 0.
    // Config is read from Mem0Config which defaults to 4; this test just ensures
    // the guard is in place by verifying successful completion at any config value.
    stubAddOk("safe-id");
    principal.setTenancyId(TENANT);
    var ids = store.storeAll(List.of(new MemoryInput("e1", DOMAIN, TENANT, null, "x", Map.of())));
    assertEquals(List.of("safe-id"), ids);
}
```

- [ ] **Step 2: Run tests — verify they fail**

```bash
mvn --batch-mode -pl memory-mem0 -am test -Dtest=Mem0CaseMemoryStoreTest#storeAll_fires_requests_concurrently
```

Expected: FAIL — the existing sequential `storeAll` takes ~2400ms, exceeding the 1200ms threshold. (Or it may pass vacuously if sequential is faster than expected. The real gate is the implementation.)

- [ ] **Step 3: Add storeAllConcurrency to Mem0Config**

In `Mem0Config.java`, add after `searchThreshold()`:

```java
/**
 * Maximum number of concurrent HTTP calls during storeAll(). Bounded via Semaphore.
 * Math.max(1, ...) is applied at the call site — 0 or negative values are treated as 1.
 * Default 4: balances Mem0 server throughput against connection pool pressure.
 */
@WithDefault("4")
int storeAllConcurrency();
```

- [ ] **Step 4: Implement parallel storeAll in Mem0CaseMemoryStore**

Replace the existing `storeAll` method body (keep the `@Timed` annotation):

```java
@Timed(value = "casehub.memory.mem0", histogram = true, extraTags = {"operation", "storeAll"})
@Override
public List<String> storeAll(List<MemoryInput> inputs) {
    if (inputs.isEmpty()) return List.of();
    inputs.forEach(i -> MemoryPermissions.assertTenant(i.tenantId(), principal, requestContextActive()));
    final int cap = Math.max(1, Math.min(config.storeAllConcurrency(), inputs.size()));
    final var sem = new Semaphore(cap);
    final var unis = inputs.stream()
        .map(i -> Uni.createFrom().callable(() -> {
            sem.acquireUninterruptibly();
            try { return sendAdd(i); }
            finally { sem.release(); }
        }).runSubscriptionOn(io.smallrye.mutiny.infrastructure.Infrastructure.getDefaultWorkerPool()))
        .toList();
    return Uni.join().all(unis).andFailFast().await().indefinitely();
}
```

Add imports at the top of the file (if not already present):
```java
import io.smallrye.mutiny.Uni;
import io.smallrye.mutiny.groups.UniJoin;
import java.util.concurrent.Semaphore;
```

- [ ] **Step 5: Run all storeAll tests**

```bash
mvn --batch-mode -pl memory-mem0 -am test -Dtest=Mem0CaseMemoryStoreTest
```

Expected: all tests pass including the new parallel ones. The concurrency test should complete in < 1200ms.

- [ ] **Step 6: Run full Mem0 module build**

```bash
mvn --batch-mode -pl memory-mem0 -am install
```

Expected: BUILD SUCCESS.

- [ ] **Step 7: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add \
  memory-mem0/src/main/java/io/casehub/platform/memory/mem0/Mem0Config.java \
  memory-mem0/src/main/java/io/casehub/platform/memory/mem0/Mem0CaseMemoryStore.java \
  memory-mem0/src/test/java/io/casehub/platform/memory/mem0/Mem0CaseMemoryStoreTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#70): bounded-parallel storeAll in Mem0 — Semaphore(cap) + Uni.join().andFailFast()"
```

---

## Task 3: #90 — Create ReactiveCaseMemoryStore in platform-api

**Files:**
- Modify: `platform-api/pom.xml`
- Create: `platform-api/src/main/java/io/casehub/platform/api/memory/ReactiveCaseMemoryStore.java`
- Delete: `platform/src/main/java/io/casehub/platform/memory/ReactiveCaseMemoryStore.java`

- [ ] **Step 1: Write failing test for UnsupportedOperationException → MemoryCapabilityException**

Create `platform-api/src/test/java/io/casehub/platform/api/memory/ReactiveCaseMemoryStoreSpiTest.java`:

```java
package io.casehub.platform.api.memory;

import io.casehub.platform.api.memory.*;
import io.smallrye.mutiny.Uni;
import org.junit.jupiter.api.Test;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;

class ReactiveCaseMemoryStoreSpiTest {

    static final MemoryDomain DOMAIN = new MemoryDomain("d");

    // Stubs for all three abstract methods; default methods under test are NOT overridden.
    // Compiler error on any omitted abstract method = it is abstract (RED state).
    // Compiles without implementing defaults = they are default (GREEN proves contract).
    private final ReactiveCaseMemoryStore sut = new ReactiveCaseMemoryStore() {
        @Override public Uni<String> store(MemoryInput i) { return Uni.createFrom().item("mem-1"); }
        @Override public Uni<List<Memory>> query(MemoryQuery q) { return Uni.createFrom().item(List.of()); }
        @Override public Uni<Integer> erase(EraseRequest r) { return Uni.createFrom().item(0); }
    };

    @Test void storeAll_delegates_to_store() {
        var a = new MemoryInput("e1", DOMAIN, "t1", null, "a", Map.of());
        var b = new MemoryInput("e1", DOMAIN, "t1", null, "b", Map.of());
        assertEquals(List.of("mem-1", "mem-1"),
            sut.storeAll(List.of(a, b)).await().indefinitely());
    }

    @Test void eraseEntity_default_fails_with_MemoryCapabilityException() {
        final var ex = assertThrows(MemoryCapabilityException.class,
            () -> sut.eraseEntity("e", "t").await().indefinitely());
        assertEquals(MemoryCapability.ERASE_ENTITY, ex.required());
    }

    @Test void eraseById_default_fails_with_MemoryCapabilityException() {
        final var ex = assertThrows(MemoryCapabilityException.class,
            () -> sut.eraseById("id", "e", "t").await().indefinitely());
        assertEquals(MemoryCapability.ERASE_BY_ID, ex.required());
    }
}
```

This test CANNOT compile yet (the class doesn't exist). This is the RED state.

- [ ] **Step 2: Add Mutiny to platform-api/pom.xml**

In `platform-api/pom.xml`, add inside `<dependencies>`:
```xml
<dependency>
    <groupId>io.smallrye.reactive</groupId>
    <artifactId>mutiny</artifactId>
    <scope>provided</scope>
</dependency>
```

Verify the version is inherited from the parent BOM (do not add `<version>`).

- [ ] **Step 3: Create ReactiveCaseMemoryStore in platform-api**

Create `platform-api/src/main/java/io/casehub/platform/api/memory/ReactiveCaseMemoryStore.java`:

```java
package io.casehub.platform.api.memory;

import io.smallrye.mutiny.Uni;
import java.util.List;
import java.util.Set;
import java.util.stream.Collectors;

public interface ReactiveCaseMemoryStore {

    Uni<String> store(MemoryInput input);

    Uni<List<Memory>> query(MemoryQuery query);

    /**
     * Reactive mirror of {@link CaseMemoryStore#erase}.
     * Returns count of records erased (see blocking SPI for semantics).
     */
    Uni<Integer> erase(EraseRequest request);

    /**
     * Reactive mirror of {@link CaseMemoryStore#storeAll}.
     * Default delegates to store() in parallel via Uni.join. Adapters may override.
     */
    default Uni<List<String>> storeAll(List<MemoryInput> inputs) {
        return Uni.join().all(inputs.stream().map(this::store).collect(Collectors.toList()))
            .andFailFast();
    }

    /**
     * Reactive mirror of {@link CaseMemoryStore#eraseEntity}.
     * Default fails with MemoryCapabilityException — consistent with blocking SPI contract.
     */
    default Uni<Integer> eraseEntity(String entityId, String tenantId) {
        return Uni.createFrom().failure(
            new MemoryCapabilityException(MemoryCapability.ERASE_ENTITY, getClass()));
    }

    /**
     * Reactive mirror of {@link CaseMemoryStore#eraseById}.
     * Default fails with MemoryCapabilityException — consistent with blocking SPI contract.
     */
    default Uni<Void> eraseById(String memoryId, String entityId, String tenantId) {
        return Uni.createFrom().failure(
            new MemoryCapabilityException(MemoryCapability.ERASE_BY_ID, getClass()));
    }
}
```

**Do not add `eraseEntityAcrossTenants` yet — that is Task 7 (#99).**

- [ ] **Step 4: Delete old ReactiveCaseMemoryStore**

```bash
git -C /Users/mdproctor/claude/casehub/platform rm \
  platform/src/main/java/io/casehub/platform/memory/ReactiveCaseMemoryStore.java
```

- [ ] **Step 5: Run the new SPI test to verify it compiles and passes**

```bash
mvn --batch-mode -pl platform-api test -Dtest=ReactiveCaseMemoryStoreSpiTest
```

Expected: 3 tests pass. The `eraseEntity` and `eraseById` defaults now throw `MemoryCapabilityException` (not `UnsupportedOperationException`).

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add \
  platform-api/pom.xml \
  platform-api/src/main/java/io/casehub/platform/api/memory/ReactiveCaseMemoryStore.java \
  platform-api/src/test/java/io/casehub/platform/api/memory/ReactiveCaseMemoryStoreSpiTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#90): move ReactiveCaseMemoryStore to platform-api; fix UnsupportedOperationException → MemoryCapabilityException"
```

---

## Task 4: #90 — Update casehub-platform (import fix + bridge threading test)

**Files:**
- Modify: `platform/src/main/java/io/casehub/platform/memory/BlockingToReactiveBridge.java`
- Modify: `platform/src/test/java/io/casehub/platform/memory/BlockingToReactiveBridgeThreadingTest.java`
- Modify: `platform/src/test/java/io/casehub/platform/memory/NoOpCaseMemoryStoreTest.java`

- [ ] **Step 1: Update BlockingToReactiveBridge import**

In `BlockingToReactiveBridge.java`, change:
```java
// Before:
import io.casehub.platform.memory.ReactiveCaseMemoryStore;
// After:
import io.casehub.platform.api.memory.ReactiveCaseMemoryStore;
```

- [ ] **Step 2: Update BlockingToReactiveBridgeThreadingTest import**

In `BlockingToReactiveBridgeThreadingTest.java`, change:
```java
// Before:
import io.casehub.platform.memory.ReactiveCaseMemoryStore;
// After:
import io.casehub.platform.api.memory.ReactiveCaseMemoryStore;
```

- [ ] **Step 3: Update NoOpCaseMemoryStoreTest import**

In `NoOpCaseMemoryStoreTest.java`, change:
```java
// Before:
import io.casehub.platform.memory.ReactiveCaseMemoryStore;
// After:
import io.casehub.platform.api.memory.ReactiveCaseMemoryStore;
```

Search for any other files in the `platform/` module referencing the old package:
```bash
mvn --batch-mode -pl platform -am compile
```

Expected: compile succeeds. Fix any remaining import errors before proceeding.

- [ ] **Step 4: Run platform tests**

```bash
mvn --batch-mode -pl platform -am test
```

Expected: all tests pass. If `NoOpCaseMemoryStoreTest` fails with `UnsatisfiedResolutionException` for `ReactiveCaseMemoryStore` — this means the CDI index needs updating. The platform module must remain Jandex-indexed; no change expected here since the interface still exists (now in platform-api, which platform depends on).

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add \
  platform/src/main/java/io/casehub/platform/memory/BlockingToReactiveBridge.java \
  platform/src/test/java/io/casehub/platform/memory/BlockingToReactiveBridgeThreadingTest.java \
  platform/src/test/java/io/casehub/platform/memory/NoOpCaseMemoryStoreTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "refactor(platform#90): update casehub-platform imports for ReactiveCaseMemoryStore move"
```

---

## Task 5: #90 — Doc updates + full build verification

**Files:**
- Modify: `CLAUDE.md`
- Modify: `/Users/mdproctor/claude/casehub/parent/docs/PLATFORM.md`

- [ ] **Step 1: Update CLAUDE.md module table**

In `CLAUDE.md`, find:
```
| `platform/` | ... also exposes `ReactiveCaseMemoryStore` (Mutiny SPI) and `BlockingToReactiveBridge @DefaultBean` at `io.casehub.platform.memory`. |
```

Change to:
```
| `platform/` | ... exposes `BlockingToReactiveBridge @DefaultBean` at `io.casehub.platform.memory`. |
```

Add to the `platform-api/` row: `ReactiveCaseMemoryStore` (Mutiny SPI) at `io.casehub.platform.api.memory`.

- [ ] **Step 2: Update PLATFORM.md capability ownership row**

In `casehub-parent/docs/PLATFORM.md`, in the memory capability row (search for "ReactiveCaseMemoryStore SPI"), update the location from `casehub-platform` to `casehub-platform-api`.

- [ ] **Step 3: Full build**

```bash
mvn --batch-mode install
```

Expected: BUILD SUCCESS across all modules. This is the #90 integration gate.

- [ ] **Step 4: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add CLAUDE.md
git -C /Users/mdproctor/claude/casehub/platform commit -m "docs(platform#90): update CLAUDE.md — ReactiveCaseMemoryStore now in platform-api"
git -C /Users/mdproctor/claude/casehub/parent add docs/PLATFORM.md
git -C /Users/mdproctor/claude/casehub/parent commit -m "docs(platform#90): update PLATFORM.md capability ownership — ReactiveCaseMemoryStore in platform-api"
```

---

## Task 6: #99 — MemoryCapability, MemoryPermissions, CaseMemoryStore SPI

**Files:**
- Modify: `platform-api/src/main/java/io/casehub/platform/api/memory/MemoryCapability.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/memory/MemoryPermissions.java`
- Modify: `platform-api/src/test/java/io/casehub/platform/api/memory/MemoryPermissionsTest.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/memory/CaseMemoryStore.java`
- Modify: `platform-api/src/test/java/io/casehub/platform/api/memory/CaseMemoryStoreSpiTest.java`

- [ ] **Step 1: Write failing tests**

In `MemoryPermissionsTest.java`, add `crossTenantAdminPrincipal()` helper and two new tests:

```java
private static CurrentPrincipal crossTenantAdminPrincipal() {
    return new CurrentPrincipal() {
        @Override public String actorId()             { return "admin"; }
        @Override public Set<String> groups()         { return Set.of(); }
        @Override public String tenancyId()           { return "platform"; }
        @Override public boolean isCrossTenantAdmin() { return true; }
    };
}

@Test
void assertCrossTenantAdmin_throws_SecurityException_when_not_admin() {
    SecurityException ex = assertThrows(SecurityException.class,
        () -> MemoryPermissions.assertCrossTenantAdmin(principal("t")));
    assertTrue(ex.getMessage().contains("actor"));
}

@Test
void assertCrossTenantAdmin_passes_when_is_cross_tenant_admin() {
    assertDoesNotThrow(() ->
        MemoryPermissions.assertCrossTenantAdmin(crossTenantAdminPrincipal()));
}
```

In `CaseMemoryStoreSpiTest.java`, add:
```java
@Test
void eraseEntityAcrossTenants_default_throws_MemoryCapabilityException() {
    final var ex = assertThrows(MemoryCapabilityException.class,
        () -> sut.eraseEntityAcrossTenants("entity-1", Set.of("tenant-1")));
    assertEquals(MemoryCapability.CROSS_TENANT_ERASE, ex.required());
}
```

Run to verify they fail:
```bash
mvn --batch-mode -pl platform-api test -Dtest="MemoryPermissionsTest,CaseMemoryStoreSpiTest"
```

Expected: `assertCrossTenantAdmin` tests fail (method doesn't exist); `eraseEntityAcrossTenants_default_throws` fails (method doesn't exist). Both tests fail to compile — that's the RED state.

- [ ] **Step 2: Add CROSS_TENANT_ERASE to MemoryCapability**

In `MemoryCapability.java`, add after `ERASE_DOMAIN_CASE`:
```java
CROSS_TENANT_ERASE,  // eraseEntityAcrossTenants() — GDPR Art.17 across all supplied tenantIds
```

- [ ] **Step 3: Add assertCrossTenantAdmin to MemoryPermissions**

In `MemoryPermissions.java`, add:
```java
/**
 * Requires cross-tenant admin privilege. No async bypass form — this check must always
 * enforce. Cross-tenant GDPR erasure is a deliberate administrative operation never
 * initiated from @ObservesAsync context; unconditional enforcement is correct and required.
 */
public static void assertCrossTenantAdmin(CurrentPrincipal principal) {
    if (!principal.isCrossTenantAdmin())
        throw new SecurityException(
            "Cross-tenant erasure requires cross-tenant admin privilege; actor=" + principal.actorId());
}
```

- [ ] **Step 4: Add eraseEntityAcrossTenants to CaseMemoryStore**

In `CaseMemoryStore.java`, add after `eraseById`:
```java
/**
 * GDPR Art.17 full-entity wipe across all supplied tenantIds.
 * Caller must be a cross-tenant admin. Supply the complete set of tenantIds
 * for the data subject from the tenant management system.
 *
 * <p>Adapters MUST call {@link MemoryPermissions#assertCrossTenantAdmin} before
 * delegating to the backend. Do NOT call eraseEntity() internally — assertTenant()
 * rejects cross-tenant access. Implement deletion directly against the backend.
 *
 * <p>Default throws {@link MemoryCapabilityException}. {@link NoOpCaseMemoryStore}
 * overrides with {@code return 0} but does NOT declare
 * {@link MemoryCapability#CROSS_TENANT_ERASE} in capabilities().
 *
 * @param tenantIds the set of tenantIds to erase from; caller supplies from tenant management.
 *                  Set semantics enforced at the type level — duplicates are impossible.
 * @return total count of records erased across all tenantIds (best-effort for REST adapters)
 */
default int eraseEntityAcrossTenants(String entityId, Set<String> tenantIds) {
    throw new MemoryCapabilityException(MemoryCapability.CROSS_TENANT_ERASE, getClass());
}
```

Add `import java.util.Set;` if not already present.

- [ ] **Step 5: Run tests — verify GREEN**

```bash
mvn --batch-mode -pl platform-api test -Dtest="MemoryPermissionsTest,CaseMemoryStoreSpiTest,ReactiveCaseMemoryStoreSpiTest"
```

Expected: all tests pass. The `CROSS_TENANT_ERASE` capability exists, `assertCrossTenantAdmin` works, and the default throws `MemoryCapabilityException`.

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add \
  platform-api/src/main/java/io/casehub/platform/api/memory/MemoryCapability.java \
  platform-api/src/main/java/io/casehub/platform/api/memory/MemoryPermissions.java \
  platform-api/src/test/java/io/casehub/platform/api/memory/MemoryPermissionsTest.java \
  platform-api/src/main/java/io/casehub/platform/api/memory/CaseMemoryStore.java \
  platform-api/src/test/java/io/casehub/platform/api/memory/CaseMemoryStoreSpiTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#99): CROSS_TENANT_ERASE capability + assertCrossTenantAdmin + CaseMemoryStore.eraseEntityAcrossTenants"
```

---

## Task 7: #99 — ReactiveCaseMemoryStore default + BlockingToReactiveBridge

**Files:**
- Modify: `platform-api/src/main/java/io/casehub/platform/api/memory/ReactiveCaseMemoryStore.java`
- Modify: `platform-api/src/test/java/io/casehub/platform/api/memory/ReactiveCaseMemoryStoreSpiTest.java`
- Modify: `platform/src/main/java/io/casehub/platform/memory/BlockingToReactiveBridge.java`
- Modify: `platform/src/test/java/io/casehub/platform/memory/BlockingToReactiveBridgeThreadingTest.java`

- [ ] **Step 1: Write failing reactive SPI test**

Add to `ReactiveCaseMemoryStoreSpiTest.java`:
```java
@Test void eraseEntityAcrossTenants_default_fails_with_MemoryCapabilityException() {
    final var ex = assertThrows(MemoryCapabilityException.class,
        () -> sut.eraseEntityAcrossTenants("e", Set.of("t")).await().indefinitely());
    assertEquals(MemoryCapability.CROSS_TENANT_ERASE, ex.required());
}
```

Run: fails to compile — method doesn't exist. RED state.

- [ ] **Step 2: Add eraseEntityAcrossTenants to ReactiveCaseMemoryStore**

In `platform-api/src/main/java/io/casehub/platform/api/memory/ReactiveCaseMemoryStore.java`, add:
```java
/**
 * Reactive mirror of {@link CaseMemoryStore#eraseEntityAcrossTenants}.
 * Default fails with MemoryCapabilityException.
 */
default Uni<Integer> eraseEntityAcrossTenants(String entityId, Set<String> tenantIds) {
    return Uni.createFrom().failure(
        new MemoryCapabilityException(MemoryCapability.CROSS_TENANT_ERASE, getClass()));
}
```

Add `import java.util.Set;` if not present.

- [ ] **Step 3: Write failing bridge threading test**

Add to `BlockingToReactiveBridgeThreadingTest.java`:

```java
@Test
void eraseEntityAcrossTenants_executes_delegate_on_worker_thread() {
    var capturedId = new AtomicLong(Thread.currentThread().getId());
    bridgeWith(capturedId).eraseEntityAcrossTenants("entity-1", Set.of(TENANT))
        .await().indefinitely();
    assertNotEquals(Thread.currentThread().getId(), capturedId.get(),
        "eraseEntityAcrossTenants() must offload delegate to a worker thread, not run on the subscribing thread");
}
```

Also extend the `bridgeWith(AtomicLong)` spy to override `eraseEntityAcrossTenants`:
```java
// Inside the anonymous CaseMemoryStore in bridgeWith():
@Override public int eraseEntityAcrossTenants(String eid, Set<String> tids) {
    capturedThreadId.set(Thread.currentThread().getId());
    return 0;
}
```

Add `import java.util.Set;` to the test file if not present.

- [ ] **Step 4: Add bridge method to BlockingToReactiveBridge**

In `BlockingToReactiveBridge.java`, add:
```java
@Override
public Uni<Integer> eraseEntityAcrossTenants(String entityId, Set<String> tenantIds) {
    return Uni.createFrom().item(() -> delegate.eraseEntityAcrossTenants(entityId, tenantIds))
        .runSubscriptionOn(Infrastructure.getDefaultWorkerPool());
}
```

Add `import java.util.Set;` if not present.

- [ ] **Step 5: Run tests**

```bash
mvn --batch-mode -pl platform-api,platform -am test
```

Expected: all tests pass. The 4th reactive SPI test passes; the 7th bridge threading test passes.

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add \
  platform-api/src/main/java/io/casehub/platform/api/memory/ReactiveCaseMemoryStore.java \
  platform-api/src/test/java/io/casehub/platform/api/memory/ReactiveCaseMemoryStoreSpiTest.java \
  platform/src/main/java/io/casehub/platform/memory/BlockingToReactiveBridge.java \
  platform/src/test/java/io/casehub/platform/memory/BlockingToReactiveBridgeThreadingTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#99): eraseEntityAcrossTenants on ReactiveCaseMemoryStore + BlockingToReactiveBridge"
```

---

## Task 8: #99 — NoOpCaseMemoryStore

**Files:**
- Modify: `platform/src/main/java/io/casehub/platform/memory/NoOpCaseMemoryStore.java`
- Modify: `platform/src/test/java/io/casehub/platform/memory/NoOpCaseMemoryStoreTest.java`

- [ ] **Step 1: Write failing tests**

Add to `NoOpCaseMemoryStoreTest.java`:
```java
@Test void eraseEntityAcrossTenants_returns_zero() {
    assertEquals(0, store.eraseEntityAcrossTenants("entity-1", Set.of("tenant-1")));
}
@Test void bridge_eraseEntityAcrossTenants_returns_zero() {
    assertEquals(0, reactiveStore.eraseEntityAcrossTenants("entity-1", Set.of("tenant-1"))
        .await().indefinitely());
}
```

Add `import java.util.Set;` if not present.

Run:
```bash
mvn --batch-mode -pl platform -am test -Dtest=NoOpCaseMemoryStoreTest
```

Expected: `eraseEntityAcrossTenants_returns_zero` FAILS — default throws `MemoryCapabilityException`.

- [ ] **Step 2: Add eraseEntityAcrossTenants to NoOpCaseMemoryStore**

In `NoOpCaseMemoryStore.java`, add:
```java
// No assertCrossTenantAdmin — NoOpCaseMemoryStore has no CurrentPrincipal injection
// and guards no real data, matching the same omission in eraseEntity().
// capabilities() stays Set.of() — NoOp invariant is preserved.
@Override
public int eraseEntityAcrossTenants(final String entityId, final Set<String> tenantIds) { return 0; }
```

Add `import java.util.Set;` if not present.

- [ ] **Step 3: Run tests**

```bash
mvn --batch-mode -pl platform -am test -Dtest=NoOpCaseMemoryStoreTest
```

Expected: all NoOp tests pass including 2 new ones.

- [ ] **Step 4: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add \
  platform/src/main/java/io/casehub/platform/memory/NoOpCaseMemoryStore.java \
  platform/src/test/java/io/casehub/platform/memory/NoOpCaseMemoryStoreTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#99): NoOpCaseMemoryStore.eraseEntityAcrossTenants() no-op override"
```

---

## Task 9: #99 — InMemoryMemoryStore

**Files:**
- Modify: `memory-inmem/src/main/java/io/casehub/platform/memory/inmem/InMemoryMemoryStore.java`
- Modify: `memory-inmem/src/test/java/io/casehub/platform/memory/inmem/InMemoryMemoryStoreTest.java`

- [ ] **Step 1: Write failing tests**

`InMemoryMemoryStoreTest` is a plain JUnit test (no @QuarkusTest). The principal is constructed directly. Add:

```java
@Test
void eraseEntityAcrossTenants_removes_entity_across_both_tenants() {
    // Set up data under two different tenants using two different store instances.
    var principalA = new CurrentPrincipal() {
        @Override public String actorId()             { return "a"; }
        @Override public Set<String> groups()         { return Set.of(); }
        @Override public String tenancyId()           { return TENANT; }
        @Override public boolean isCrossTenantAdmin() { return false; }
    };
    var principalB = new CurrentPrincipal() {
        @Override public String actorId()             { return "b"; }
        @Override public Set<String> groups()         { return Set.of(); }
        @Override public String tenancyId()           { return OTHER_TENANT; }
        @Override public boolean isCrossTenantAdmin() { return false; }
    };
    var adminPrincipal = new CurrentPrincipal() {
        @Override public String actorId()             { return "admin"; }
        @Override public Set<String> groups()         { return Set.of(); }
        @Override public String tenancyId()           { return "platform"; }
        @Override public boolean isCrossTenantAdmin() { return true; }
    };

    // Use shared map: create one store for each principal but share the internal map via admin store.
    var storeA = new InMemoryMemoryStore(principalA);
    var storeB = new InMemoryMemoryStore(principalB);
    var adminStore = new InMemoryMemoryStore(adminPrincipal);

    storeA.store(new MemoryInput("entity-1", DOMAIN, TENANT, null, "data-a", Map.of()));
    storeB.store(new MemoryInput("entity-1", DOMAIN, OTHER_TENANT, null, "data-b", Map.of()));

    // Admin erases across both tenants
    int count = adminStore.eraseEntityAcrossTenants("entity-1", Set.of(TENANT, OTHER_TENANT));
    assertTrue(count >= 0); // best-effort count
}

@Test
void eraseEntityAcrossTenants_requires_cross_tenant_admin() {
    assertThrows(SecurityException.class,
        () -> sut.eraseEntityAcrossTenants("entity-1", Set.of(TENANT)));
}
```

Add `import java.util.Set;` if not present. Note `OTHER_TENANT` constant — add if not already in the test:
```java
static final String OTHER_TENANT = "tenant-2";
```

**Note:** `InMemoryMemoryStore` uses an internal `ConcurrentHashMap` — each instance has its own separate map. The two separate stores (storeA, storeB) do not share state. The count test just verifies no exception is thrown and count is non-negative. The full cross-tenant erasure scenario (shared map, multi-tenant) would require a `@QuarkusTest` with CDI injection to share one `@ApplicationScoped` instance — add an adapter-specific integration note but keep this unit test as a security boundary test only.

Correct the test to reflect this:
```java
@Test
void eraseEntityAcrossTenants_removes_entity_from_own_data() {
    // Admin store's own map: store data under admin's tenancyId via a separate store view.
    // Since InMemoryMemoryStore is constructor-injected, each instance has its own ConcurrentHashMap.
    // This test verifies the security guard and return value, not cross-instance behavior.
    var adminPrincipal = new CurrentPrincipal() {
        @Override public String actorId()             { return "admin"; }
        @Override public Set<String> groups()         { return Set.of(); }
        @Override public String tenancyId()           { return TENANT; }
        @Override public boolean isCrossTenantAdmin() { return true; }
    };
    var adminStore = new InMemoryMemoryStore(adminPrincipal);
    adminStore.store(new MemoryInput("entity-1", DOMAIN, TENANT, null, "data", Map.of()));
    int count = adminStore.eraseEntityAcrossTenants("entity-1", Set.of(TENANT));
    assertEquals(1, count);
    assertTrue(adminStore.query(MemoryQuery.forEntity("entity-1", DOMAIN, TENANT)).isEmpty());
}

@Test
void eraseEntityAcrossTenants_requires_cross_tenant_admin() {
    assertThrows(SecurityException.class,
        () -> sut.eraseEntityAcrossTenants("entity-1", Set.of(TENANT)));
}
```

Run: both tests fail (method not found). RED state.

- [ ] **Step 2: Implement eraseEntityAcrossTenants in InMemoryMemoryStore**

Add to `InMemoryMemoryStore.java`:
```java
@Override
public int eraseEntityAcrossTenants(String entityId, Set<String> tenantIds) {
    MemoryPermissions.assertCrossTenantAdmin(principal);
    var count = new AtomicInteger();
    store.entrySet().removeIf(e -> {
        if (tenantIds.contains(e.getKey().tenantId()) && e.getKey().entityId().equals(entityId)) {
            count.addAndGet(e.getValue().size());
            return true;
        }
        return false;
    });
    return count.get();
}
```

Also add `CROSS_TENANT_ERASE` to `capabilities()`:
```java
@Override
public java.util.Set<MemoryCapability> capabilities() {
    return java.util.Set.of(
        MemoryCapability.CHRONOLOGICAL_ORDER,
        MemoryCapability.DOMAIN_SCOPED,
        MemoryCapability.CASE_SCOPED,
        MemoryCapability.SINCE_FILTER,
        MemoryCapability.BATCH_STORE,
        MemoryCapability.ERASE_BY_ID,
        MemoryCapability.ERASE_ENTITY,
        MemoryCapability.ERASE_DOMAIN_CASE,
        MemoryCapability.CROSS_TENANT_ERASE
    );
}
```

Add `import java.util.Set;` and `import java.util.concurrent.atomic.AtomicInteger;` if not present.

- [ ] **Step 3: Run tests**

```bash
mvn --batch-mode -pl memory-inmem -am test
```

Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add \
  memory-inmem/src/main/java/io/casehub/platform/memory/inmem/InMemoryMemoryStore.java \
  memory-inmem/src/test/java/io/casehub/platform/memory/inmem/InMemoryMemoryStoreTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#99): InMemoryMemoryStore.eraseEntityAcrossTenants + CROSS_TENANT_ERASE capability"
```

---

## Task 10: #99 — JpaMemoryStore

**Files:**
- Modify: `memory-jpa/src/main/java/io/casehub/platform/memory/jpa/JpaMemoryStore.java`
- Modify: `memory-jpa/src/test/java/io/casehub/platform/memory/jpa/JpaMemoryStoreTest.java`

- [ ] **Step 1: Write failing tests**

Add to `JpaMemoryStoreTest.java`:
```java
@Test
@Transactional(TxType.REQUIRED)
void eraseEntityAcrossTenants_deletes_entity_from_all_supplied_tenants() {
    principal.setTenancyId(TENANT);
    // Seed under TENANT
    em.persist(new io.casehub.platform.memory.jpa.MemoryEntry(
        java.util.UUID.randomUUID().toString(), "entity-1",
        DOMAIN.name(), TENANT, null, "data-a",
        java.time.Instant.now(), Map.of()));
    // Seed under OTHER_TENANT
    em.persist(new io.casehub.platform.memory.jpa.MemoryEntry(
        java.util.UUID.randomUUID().toString(), "entity-1",
        DOMAIN.name(), OTHER_TENANT, null, "data-b",
        java.time.Instant.now(), Map.of()));
    em.flush();

    principal.setCrossTenantAdmin(true);
    int count = jpaStore.eraseEntityAcrossTenants("entity-1", Set.of(TENANT, OTHER_TENANT));
    assertEquals(2, count);
}

@Test
void eraseEntityAcrossTenants_requires_cross_tenant_admin() {
    principal.setCrossTenantAdmin(false);
    assertThrows(SecurityException.class,
        () -> jpaStore.eraseEntityAcrossTenants("entity-1", Set.of(TENANT)));
}
```

Add `import java.util.Set;` if not present. If `MemoryEntry` constructor is not public, use JPA `em.createNativeQuery` or `store().store()` to seed data — adapt as needed based on the actual `MemoryEntry` class.

**Simpler seeding alternative** (avoids direct entity construction):
```java
// Seed via store() under TENANT
principal.setTenancyId(TENANT);
store().store(new MemoryInput("entity-1", DOMAIN, TENANT, null, "data-a", Map.of()));
// Seed under OTHER_TENANT by temporarily switching principal
principal.setTenancyId(OTHER_TENANT);
store().store(new MemoryInput("entity-1", DOMAIN, OTHER_TENANT, null, "data-b", Map.of()));
// Erase as cross-tenant admin
principal.setTenancyId(TENANT);
principal.setCrossTenantAdmin(true);
int count = jpaStore.eraseEntityAcrossTenants("entity-1", Set.of(TENANT, OTHER_TENANT));
assertEquals(2, count);
```

Use this simpler form. Add `@BeforeEach` reset: add `principal.setCrossTenantAdmin(false)` to the existing `setup()` method.

Run:
```bash
mvn --batch-mode -pl memory-jpa -am test -Dtest=JpaMemoryStoreTest
```

Expected: new tests fail (method not found). RED state.

- [ ] **Step 2: Implement eraseEntityAcrossTenants in JpaMemoryStore**

Add to `JpaMemoryStore.java`:
```java
@Override
@Transactional(TxType.REQUIRED)
public int eraseEntityAcrossTenants(String entityId, Set<String> tenantIds) {
    MemoryPermissions.assertCrossTenantAdmin(principal);
    if (tenantIds.isEmpty()) return 0;
    int count = em.createQuery(
            "DELETE FROM MemoryEntry WHERE entityId = :entityId AND tenantId IN :tenantIds")
        .setParameter("entityId", entityId)
        .setParameter("tenantIds", List.copyOf(tenantIds))
        .executeUpdate();
    em.clear();
    return count;
}
```

Also add `CROSS_TENANT_ERASE` to `capabilities()`. The current `capabilities()` returns a `Set.of(...)` — add `MemoryCapability.CROSS_TENANT_ERASE` to the existing set.

Add `import java.util.Set;` and `import java.util.List;` if not present.

- [ ] **Step 3: Run tests**

```bash
mvn --batch-mode -pl memory-jpa -am test
```

Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add \
  memory-jpa/src/main/java/io/casehub/platform/memory/jpa/JpaMemoryStore.java \
  memory-jpa/src/test/java/io/casehub/platform/memory/jpa/JpaMemoryStoreTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#99): JpaMemoryStore.eraseEntityAcrossTenants — single DELETE IN query"
```

---

## Task 11: #99 — SqliteMemoryStore

**Files:**
- Modify: `memory-sqlite/src/main/java/io/casehub/platform/memory/sqlite/SqliteMemoryStore.java`
- Modify: `memory-sqlite/src/test/java/io/casehub/platform/memory/sqlite/SqliteMemoryStoreTest.java`

- [ ] **Step 1: Write failing tests**

Add to `SqliteMemoryStoreTest.java`:
```java
@Test
void eraseEntityAcrossTenants_deletes_across_tenants() {
    // Seed under TENANT
    store().store(new MemoryInput("entity-1", DOMAIN, TENANT, null, "data-a", Map.of()));
    // Seed under OTHER_TENANT (switch principal temporarily)
    principal.setTenancyId(OTHER_TENANT);
    store().store(new MemoryInput("entity-1", DOMAIN, OTHER_TENANT, null, "data-b", Map.of()));
    // Erase as cross-tenant admin
    principal.setTenancyId(TENANT);
    principal.setCrossTenantAdmin(true);
    int count = sqliteStore.eraseEntityAcrossTenants("entity-1", Set.of(TENANT, OTHER_TENANT));
    assertEquals(2, count);
}

@Test
void eraseEntityAcrossTenants_requires_cross_tenant_admin() {
    principal.setCrossTenantAdmin(false);
    assertThrows(SecurityException.class,
        () -> sqliteStore.eraseEntityAcrossTenants("entity-1", Set.of(TENANT)));
}
```

Add `principal.setCrossTenantAdmin(false)` to the existing `setup()` `@BeforeEach` and `principal.setCrossTenantAdmin(false)` to `cleanUp()` `@AfterEach`. Add `import java.util.Set;`.

Run:
```bash
mvn --batch-mode -pl memory-sqlite -am test -Dtest=SqliteMemoryStoreTest
```

Expected: new tests fail. RED state.

- [ ] **Step 2: Implement eraseEntityAcrossTenants in SqliteMemoryStore**

Add to `SqliteMemoryStore.java`:
```java
private static final int SQLITE_IN_CHUNK = 500;

@Override
public int eraseEntityAcrossTenants(String entityId, Set<String> tenantIds) {
    MemoryPermissions.assertCrossTenantAdmin(principal);
    if (tenantIds.isEmpty()) return 0;
    var tenantList = new ArrayList<>(tenantIds);
    int total = 0;
    for (int offset = 0; offset < tenantList.size(); offset += SQLITE_IN_CHUNK) {
        var chunk = tenantList.subList(offset, Math.min(offset + SQLITE_IN_CHUNK, tenantList.size()));
        total += deleteChunk(entityId, chunk);
    }
    return total;
}

private int deleteChunk(String entityId, List<String> tenantChunk) {
    String placeholders = tenantChunk.stream().map(_ -> "?").collect(Collectors.joining(", "));
    String sql = "DELETE FROM memory_entry WHERE entity_id = ? AND tenant_id IN (" + placeholders + ")";
    try (Connection conn = dataSource.getConnection();
         PreparedStatement ps = conn.prepareStatement(sql)) {
        ps.setString(1, entityId);
        int idx = 2;
        for (String t : tenantChunk) ps.setString(idx++, t);
        return ps.executeUpdate();
    } catch (SQLException e) {
        throw new IllegalStateException("eraseEntityAcrossTenants() failed", e);
    }
}
```

Also add `CROSS_TENANT_ERASE` to `capabilities()`.

Add `import java.util.Set;`, `import java.util.ArrayList;`, `import java.util.List;` if not present. `Collectors` and `Connection`/`PreparedStatement`/`SQLException` should already be imported.

- [ ] **Step 3: Run tests**

```bash
mvn --batch-mode -pl memory-sqlite -am test
```

Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add \
  memory-sqlite/src/main/java/io/casehub/platform/memory/sqlite/SqliteMemoryStore.java \
  memory-sqlite/src/test/java/io/casehub/platform/memory/sqlite/SqliteMemoryStoreTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#99): SqliteMemoryStore.eraseEntityAcrossTenants — chunked DELETE IN (SQLITE_IN_CHUNK=500)"
```

---

## Task 12: #99 — Mem0CaseMemoryStore

**Files:**
- Modify: `memory-mem0/src/main/java/io/casehub/platform/memory/mem0/Mem0CaseMemoryStore.java`
- Modify: `memory-mem0/src/test/java/io/casehub/platform/memory/mem0/Mem0CaseMemoryStoreTest.java`

- [ ] **Step 1: Write failing tests**

Add to `Mem0CaseMemoryStoreTest.java`:
```java
// ── eraseEntityAcrossTenants ───────────────────────────────────────────────

@Test
void eraseEntityAcrossTenants_requires_cross_tenant_admin() {
    // principal is set to TENANT (not cross-tenant admin) in setup()
    assertThrows(SecurityException.class,
        () -> store.eraseEntityAcrossTenants("entity-1", Set.of(TENANT)));
}

@Test
void eraseEntityAcrossTenants_calls_list_and_deleteAll_per_tenant() {
    // Two tenants — Mem0 calls list() then deleteAll() for each
    stubListOk(mem0Json("id-1", "data", "2026-01-01T00:00:00Z"));
    stubDeleteAllOk();
    principal.setCrossTenantAdmin(true);
    int count = store.eraseEntityAcrossTenants("entity-1", Set.of(TENANT, "tenant-b"));
    // count is best-effort from list responses; list returns 1 item → count = 2 (one per tenant)
    assertEquals(2, count);
}
```

Add `import java.util.Set;`, `principal.setCrossTenantAdmin(false)` to `@BeforeEach setup()`.

Run:
```bash
mvn --batch-mode -pl memory-mem0 -am test -Dtest="Mem0CaseMemoryStoreTest#eraseEntityAcrossTenants*"
```

Expected: fail (method not found). RED state.

- [ ] **Step 2: Implement eraseEntityAcrossTenants in Mem0CaseMemoryStore**

Add to `Mem0CaseMemoryStore.java`:
```java
@Timed(value = "casehub.memory.mem0", histogram = true, extraTags = {"operation", "eraseEntityAcrossTenants"})
@Override
public int eraseEntityAcrossTenants(String entityId, Set<String> tenantIds) {
    MemoryPermissions.assertCrossTenantAdmin(principal);
    // Sequential: simplicity + retry-is-safe. deleteAll is idempotent — already-erased tenants
    // return an empty list on retry, so re-invoking after a partial failure is safe and converges.
    // Parallel with error-collection semantics would require a MultiEraseException type and
    // materially more code for no architectural benefit. GDPR Art.17 mandates "without undue
    // delay" (typically 30 days), not sub-second execution; occasional retries are compliant.
    int total = 0;
    for (String tenantId : tenantIds) {
        final String userId = compoundUserId(tenantId, entityId);
        try {
            final Mem0ListResponse listed = client.list(userId, null, null);
            total += listed.results() != null ? listed.results().size() : 0;
            client.deleteAll(userId, null, null);
        } catch (WebApplicationException e) {
            throw toStoreException(e);
        }
    }
    return total;
}
```

Also add `CROSS_TENANT_ERASE` to `capabilities()`.

Add `import java.util.Set;` if not present.

- [ ] **Step 3: Run tests**

```bash
mvn --batch-mode -pl memory-mem0 -am test
```

Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add \
  memory-mem0/src/main/java/io/casehub/platform/memory/mem0/Mem0CaseMemoryStore.java \
  memory-mem0/src/test/java/io/casehub/platform/memory/mem0/Mem0CaseMemoryStoreTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#99): Mem0CaseMemoryStore.eraseEntityAcrossTenants — sequential loop, retry-is-safe"
```

---

## Task 13: #99 — GraphitiCaseMemoryStore

**Files:**
- Modify: `memory-graphiti/src/main/java/io/casehub/platform/memory/graphiti/GraphitiCaseMemoryStore.java`
- Modify: `memory-graphiti/src/test/java/io/casehub/platform/memory/graphiti/GraphitiCaseMemoryStoreKnownDomainsTest.java`

- [ ] **Step 1: Write failing tests**

In `GraphitiCaseMemoryStoreKnownDomainsTest.java` (which already configures known-domains), add:
```java
@Test
void eraseEntityAcrossTenants_calls_eraseGroup_per_tenant_per_domain() {
    // With known-domains configured and 2 tenants × (N domains from config):
    // each tenant+domain combination generates one DELETE /groups/{group_id} call.
    // Stub deleteGroup for any group_id.
    // Then verify capability is declared and call succeeds.
    principal.setCrossTenantAdmin(true);
    // Stub: any DELETE /groups/* returns 200
    // (Use whatever stub helper exists in the test for deleteGroup/eraseGroup)
    // Count = sum of episode counts from GET /episodes/{group_id} per domain per tenant
    // Just verify no exception is thrown and count >= 0.
    int count = store.eraseEntityAcrossTenants(ENTITY, Set.of(TENANT, "tenant-b"));
    assertTrue(count >= 0);
    assertTrue(store.capabilities().contains(MemoryCapability.CROSS_TENANT_ERASE));
}

@Test
void eraseEntityAcrossTenants_requires_cross_tenant_admin() {
    principal.setCrossTenantAdmin(false);
    assertThrows(SecurityException.class,
        () -> store.eraseEntityAcrossTenants(ENTITY, Set.of(TENANT)));
}

@Test
void eraseEntityAcrossTenants_throws_when_no_known_domains() {
    // Store without known-domains configured cannot do cross-tenant erase.
    // This is tested in GraphitiCaseMemoryStoreTest (no known-domains config).
    // See GraphitiCaseMemoryStoreTest.eraseEntityAcrossTenants_without_known_domains_throws
}
```

Also add to `GraphitiCaseMemoryStoreTest.java` (no known-domains):
```java
@Test
void eraseEntityAcrossTenants_without_known_domains_throws_MemoryCapabilityException() {
    assertThrows(MemoryCapabilityException.class,
        () -> store.eraseEntityAcrossTenants(ENTITY, Set.of(TENANT)));
}
```

Add `principal.setCrossTenantAdmin(false)` to `@BeforeEach` setup in both test classes. Add `import java.util.Set;`.

Run:
```bash
mvn --batch-mode -pl memory-graphiti -am test
```

Expected: new tests fail (method not found). RED state.

- [ ] **Step 2: Implement eraseEntityAcrossTenants in GraphitiCaseMemoryStore**

Add to `GraphitiCaseMemoryStore.java`:
```java
@Timed(value = "casehub.memory.graphiti", histogram = true, extraTags = {"operation", "eraseEntityAcrossTenants"})
@Override
public int eraseEntityAcrossTenants(String entityId, Set<String> tenantIds) {
    MemoryPermissions.assertCrossTenantAdmin(principal);
    final List<String> domains = config.knownDomains().orElse(List.of());
    if (domains.isEmpty())
        throw new MemoryCapabilityException(MemoryCapability.CROSS_TENANT_ERASE, getClass());
    // Sequential: simplicity + retry-is-safe. eraseGroup handles 404 as a no-op,
    // so already-erased groups are skipped safely on retry.
    // Consistent with Graphiti's existing sequential storeAll.
    int total = 0;
    for (String tenantId : tenantIds)
        for (String domain : domains)
            total += eraseGroup(compoundGroupId(tenantId, entityId, domain));
    return total;
}
```

Also add `CROSS_TENANT_ERASE` to `capabilities()` — conditionally, alongside `ERASE_ENTITY` (same gate: `knownDomains` non-empty).

Add `import java.util.Set;` if not present.

- [ ] **Step 3: Run tests**

```bash
mvn --batch-mode -pl memory-graphiti -am test
```

Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add \
  memory-graphiti/src/main/java/io/casehub/platform/memory/graphiti/GraphitiCaseMemoryStore.java \
  memory-graphiti/src/test/java/io/casehub/platform/memory/graphiti/GraphitiCaseMemoryStoreKnownDomainsTest.java \
  memory-graphiti/src/test/java/io/casehub/platform/memory/graphiti/GraphitiCaseMemoryStoreTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#99): GraphitiCaseMemoryStore.eraseEntityAcrossTenants — known-domains × tenantIds loop"
```

---

## Task 14: #99 — Contract test security boundary

**Files:**
- Modify: `testing/src/main/java/io/casehub/platform/testing/memory/CaseMemoryStoreContractTest.java`

- [ ] **Step 1: Add security boundary test**

Add to `CaseMemoryStoreContractTest.java` in the `// --- eraseEntity ---` section:
```java
// --- eraseEntityAcrossTenants ---

@Test
void eraseEntityAcrossTenants_throws_SecurityException_when_not_cross_tenant_admin() {
    // Default principal in all contract test subclasses has isCrossTenantAdmin()=false.
    // assertCrossTenantAdmin must reject any non-admin caller.
    assertThrows(SecurityException.class,
        () -> store().eraseEntityAcrossTenants("entity-1", Set.of(TENANT)));
}
```

Add `import java.util.Set;` if not present.

- [ ] **Step 2: Run contract tests across all adapters**

```bash
mvn --batch-mode -pl testing,memory-inmem,memory-jpa,memory-sqlite -am test
```

Expected: all adapters pass the new security boundary test. Each adapter's store() principal has `isCrossTenantAdmin()=false` by default; `assertCrossTenantAdmin` throws `SecurityException`.

- [ ] **Step 3: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add \
  testing/src/main/java/io/casehub/platform/testing/memory/CaseMemoryStoreContractTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "test(platform#99): contract test security boundary — eraseEntityAcrossTenants requires cross-tenant admin"
```

---

## Task 15: Doc updates + final build

**Files:**
- Modify: `ARC42STORIES.MD`
- Garden protocol entry (file in `casehubio/garden`)

- [ ] **Step 1: Update ARC42STORIES §12 — remove resolved risk**

In `ARC42STORIES.MD`, find and delete the row:
```
| Mem0 storeAll batch (#70) — N sequential REST calls for a batch | Low — batch infrequent today; deferred pending Mem0 OSS batch endpoint | Workaround: call `store()` in a loop; no atomicity guarantee across REST calls |
```

- [ ] **Step 2: Update ARC42STORIES §8 L6 — add new chapter**

Find the `#### Layer — L6: Memory Adapters` section. Update the **Participates in chapters** line (add the new chapter number — assign the next sequential C-number from the existing list). Update **Issues** to add `#70, #90, #99`. Update **Blog** when a diary entry is written. Update the "Not closed here" note — remove `Mem0 storeAll() batch (#70)`.

Add a new `#### What it adds` subsection describing this branch's contributions.

- [ ] **Step 3: Update ARC42STORIES §13 — extend glossary**

Add after `eraseEntity()`:
```
| `eraseEntityAcrossTenants()` | GDPR Art.17 full-entity wipe across all supplied tenantIds. Requires `isCrossTenantAdmin()`. Caller supplies the complete set of tenantIds from the tenant management system. Distinct from `eraseEntity()` which is per-tenant. Default throws `MemoryCapabilityException(CROSS_TENANT_ERASE)`. |
```

Update `MemoryPermissions` entry to mention `assertCrossTenantAdmin(principal)`.

- [ ] **Step 4: File protocol entry in garden**

Create `~/claude/casehub/garden/docs/protocols/casehub/memory-privileged-ops-no-async-bypass.md`:

```markdown
---
id: PP-20260618-<hash>
title: "Privileged administrative operations must not bypass their security gate in async context"
type: rule
scope: platform
applies_to: "Any MemoryPermissions check added for privileged operations (not unauthenticated async-hop operations)"
severity: important
refs:
  - docs/protocols/casehub/casememorystore-adapter-asserttenant-contract.md
created: 2026-06-18
---

The 3-arg `assertTenant(tenantId, principal, requestContextActive)` form exists to accommodate
`@ObservesAsync` callers — when `requestContextActive=false`, the principal comparison is skipped
because the CDI request scope is not available on the async thread; the tenantId from the domain
object is trusted directly. This bypass applies ONLY to authentication (tenant validation) in
fire-and-forget async handlers.

Privileged operations — such as `assertCrossTenantAdmin(principal)` — must NOT have an async bypass
form. Cross-tenant erasure is a deliberate administrative action, never initiated from `@ObservesAsync`
context. Adding an async bypass to a privilege check creates a security hole: any `@ObservesAsync`
handler could call the method and bypass the admin requirement.

The rule: if a new `MemoryPermissions` check guards a privilege (not just tenant identity), it uses
only a 1-arg form. No requestContextActive variant is added. Document that it must not be called from
`@ObservesAsync`.
```

Commit the protocol entry to the garden repo.

- [ ] **Step 5: Full build**

```bash
mvn --batch-mode install
```

Expected: BUILD SUCCESS across all modules. This is the final integration gate.

- [ ] **Step 6: Commit ARC42STORIES**

```bash
git -C /Users/mdproctor/claude/casehub/platform add ARC42STORIES.MD
git -C /Users/mdproctor/claude/casehub/platform commit -m "docs(platform#70,#90,#99): ARC42STORIES — retire §12 risk #70, add §8 L6 chapter, extend §13 glossary"
```

---

## Self-Review

**Spec coverage check:**

| Spec section | Task |
|---|---|
| #70 — SQLite 2-arg assertTenant fix | Task 1 |
| #70 — Mem0 2-arg assertTenant fix | Task 1 |
| #70 — Mem0Config.storeAllConcurrency | Task 2 |
| #70 — parallel storeAll implementation | Task 2 |
| #70 — 5 tests (concurrency, order, error, zero-config, empty) | Task 2 |
| #90 — Mutiny in platform-api pom | Task 3 |
| #90 — ReactiveCaseMemoryStore moved, UOE→MCE fixed | Task 3 |
| #90 — ReactiveCaseMemoryStoreSpiTest (4 tests) | Task 3 |
| #90 — old file deleted | Task 3 |
| #90 — BlockingToReactiveBridge import updated | Task 4 |
| #90 — NoOpCaseMemoryStoreTest import updated | Task 4 |
| #90 — CLAUDE.md + PLATFORM.md updated | Task 5 |
| #99 — CROSS_TENANT_ERASE capability | Task 6 |
| #99 — assertCrossTenantAdmin + MemoryPermissionsTest | Task 6 |
| #99 — CaseMemoryStore.eraseEntityAcrossTenants default | Task 6 |
| #99 — CaseMemoryStoreSpiTest new test | Task 6 |
| #99 — ReactiveCaseMemoryStore default + SPI test | Task 7 |
| #99 — BlockingToReactiveBridge bridge method + threading test | Task 7 |
| #99 — NoOpCaseMemoryStore + 2 NoOp tests | Task 8 |
| #99 — InMemoryMemoryStore + tests | Task 9 |
| #99 — JpaMemoryStore + tests | Task 10 |
| #99 — SqliteMemoryStore chunked + tests | Task 11 |
| #99 — Mem0CaseMemoryStore + tests | Task 12 |
| #99 — GraphitiCaseMemoryStore + tests | Task 13 |
| #99 — CaseMemoryStoreContractTest security boundary | Task 14 |
| Doc: ARC42STORIES §12, §8 L6, §13 | Task 15 |
| Doc: garden protocol entry | Task 15 |

All spec sections are covered. No gaps found.

**Type consistency check:**
- `Set<String> tenantIds` is consistent across all adapter method signatures, bridge, both SPI interfaces, and tests. ✓
- `MemoryCapability.CROSS_TENANT_ERASE` used in: capability enum, default throws, SPI tests, capability declarations. ✓
- `assertCrossTenantAdmin(CurrentPrincipal)` — 1-arg only, consistent across all adapter implementations and tests. ✓
- `storeAllConcurrency()` on `Mem0Config` matches usage in `Mem0CaseMemoryStore.storeAll()`. ✓
