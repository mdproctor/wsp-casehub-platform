# Memory CDI Priority and Emission Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix InMemoryMemoryStore CDI priority to eliminate AmbiguousResolutionException in @QuarkusTest (platform#39); commit to direct injection as the canonical memory emission pattern with Javadoc update (platform#49 Part 1); add a single-transaction storeAll() override to JpaMemoryStore with batch-safe semantics (platform#49 Part 2).

**Architecture:** Three independent changes on one branch: (1) a one-line annotation change + doc updates, (2) a Javadoc rewrite + PLATFORM.md edit, (3) a new method override in JpaMemoryStore with contract test additions. No new modules, no schema changes, no cross-repo API breaks.

**Tech Stack:** Java 21, Quarkus 3.x, Panache ORM (PanacheEntityBase), CDI @Alternative/@Priority, JUnit 5, @QuarkusTest with H2 in PostgreSQL mode.

---

## File Map

| File | Change |
|---|---|
| `memory-inmem/src/main/java/io/casehub/platform/memory/inmem/InMemoryMemoryStore.java` | `@Priority(1)` → `@Priority(10)` |
| `CLAUDE.md` | memory-inmem/ row: update priority note |
| `casehub-parent/docs/protocols/universal/persistence-backend-cdi-priority.md` | Add Tier 3 band; update CaseMemoryStore reference row |
| `platform-api/src/main/java/io/casehub/platform/api/memory/CaseMemoryStore.java` | Rewrite `store()` Javadoc |
| `casehub-parent/docs/PLATFORM.md` | Add emission note to CaseMemoryStore capability entry |
| `platform/src/main/java/io/casehub/platform/memory/NoOpCaseMemoryStore.java` | Add explicit `storeAll()` override |
| `testing/src/main/java/io/casehub/platform/testing/memory/CaseMemoryStoreContractTest.java` | Add storeAll() contract tests |
| `memory-jpa/src/main/java/io/casehub/platform/memory/jpa/JpaMemoryStore.java` | Add `storeAll()` override |
| `memory-jpa/src/test/java/io/casehub/platform/memory/jpa/JpaMemoryStoreTest.java` | Add JPA-specific storeAll() test |

---

## Task 1: InMemoryMemoryStore Priority Elevation (#39)

**Files:**
- Modify: `memory-inmem/src/main/java/io/casehub/platform/memory/inmem/InMemoryMemoryStore.java`
- Modify: `CLAUDE.md`
- Modify: `casehub-parent/docs/protocols/universal/persistence-backend-cdi-priority.md`

- [ ] **Step 1: Change the priority annotation**

In `memory-inmem/src/main/java/io/casehub/platform/memory/inmem/InMemoryMemoryStore.java`, change:

```java
@Alternative
@Priority(1)
@ApplicationScoped
public class InMemoryMemoryStore implements CaseMemoryStore {
```

to:

```java
@Alternative
@Priority(10)
@ApplicationScoped
public class InMemoryMemoryStore implements CaseMemoryStore {
```

- [ ] **Step 2: Build memory-inmem to verify compilation**

```bash
mvn --batch-mode -pl memory-inmem test
```

Expected: `BUILD SUCCESS`. All existing `InMemoryMemoryStoreTest` tests pass. No output change — the priority is not observable from a unit test.

- [ ] **Step 3: Update CLAUDE.md module table**

In `CLAUDE.md`, find the `memory-inmem/` row in the Modules table. Update the priority note:

Find:
```
| `memory-inmem/` | `casehub-platform-memory-inmem` | @Alternative @Priority(1) volatile CaseMemoryStore
```

Replace `@Alternative @Priority(1)` with `@Alternative @Priority(10)` in that row. The full replacement is:

```
| `memory-inmem/` | `casehub-platform-memory-inmem` | @Alternative @Priority(10) volatile CaseMemoryStore — ConcurrentHashMap, constructor-injected CurrentPrincipal, no quarkus:build goal. Add as test scope for @QuarkusTest isolation; compile for ephemeral installs. Do NOT combine with memory-jpa or memory-sqlite in the same scope |
```

- [ ] **Step 4: Update persistence-backend-cdi-priority.md**

File: `casehub-parent/docs/protocols/universal/persistence-backend-cdi-priority.md`

After the "Tier 2 — Override" section and its code block, add a new section:

```markdown
---

## Tier 3 — Test Override (`@Alternative @Priority(10+)`)

A higher-priority alternative that beats Tier-2 production overrides when both are on
the **test** classpath. Used exclusively for test-isolation adapters that must win over
any production adapter in `@QuarkusTest`, while remaining invisible in production
augmentation (test scope is excluded from production CDI scanning).

```java
// Tier 3 — beats all production adapters in test scope
@Alternative @Priority(10)
@ApplicationScoped
public class InMemoryMemoryStore implements CaseMemoryStore {
    // volatile ConcurrentHashMap — no external dependencies
}
```

**Priority reserved bands:**

| CDI Mechanism | Tier | Purpose |
|---|---|---|
| `@DefaultBean` | 0 — no-op | Active when no adapter on classpath |
| `@ApplicationScoped` (no qualifier) | 1 — production SQL | Standard JPA/SQL impl; beats Tier 0 by CDI rules |
| `@Alternative @Priority(1–9)` | 2 — production override | Specialised backend (MongoDB, SQLite, REST); beats Tier 1 |
| `@Alternative @Priority(10+)` | 3 — test override | In-memory or stub; beats Tier 2 in test classpath only |

Tiers 0 and 1 use CDI mechanism (not `@Priority`). Only Tiers 2 and 3 use `@Alternative @Priority(N)`.
```

Also update the Reference Implementations table — find the `CaseMemoryStore` row and change:

```
| `CaseMemoryStore` | `NoOpCaseMemoryStore @DefaultBean` (casehub-platform) | — | Memori/Mem0/Graphiti adapters `@Alternative @Priority(N)` (casehub-platform submodules) |
```

to:

```
| `CaseMemoryStore` | `NoOpCaseMemoryStore @DefaultBean` (casehub-platform) | `JpaMemoryStore @ApplicationScoped` (casehub-platform-memory-jpa) | `SqliteMemoryStore`, `Mem0CaseMemoryStore` `@Alternative @Priority(1)` (Tier 2); `InMemoryMemoryStore` `@Alternative @Priority(10)` (Tier 3 — test override) |
```

- [ ] **Step 5: Commit project repo changes**

```bash
git -C /Users/mdproctor/claude/casehub/platform add \
  memory-inmem/src/main/java/io/casehub/platform/memory/inmem/InMemoryMemoryStore.java \
  CLAUDE.md
git -C /Users/mdproctor/claude/casehub/platform commit -m "fix(platform#39): elevate InMemoryMemoryStore to @Priority(10) — test-override tier"
```

- [ ] **Step 6: Commit parent repo changes**

```bash
git -C /Users/mdproctor/claude/casehub/parent add \
  docs/protocols/universal/persistence-backend-cdi-priority.md
git -C /Users/mdproctor/claude/casehub/parent commit -m "docs(platform#39): add Tier 3 test-override band to persistence-backend-cdi-priority"
```

---

## Task 2: CaseMemoryStore Javadoc + PLATFORM.md (#49 Part 1)

**Files:**
- Modify: `platform-api/src/main/java/io/casehub/platform/api/memory/CaseMemoryStore.java`
- Modify: `casehub-parent/docs/PLATFORM.md`

- [ ] **Step 1: Rewrite store() Javadoc**

In `platform-api/src/main/java/io/casehub/platform/api/memory/CaseMemoryStore.java`, replace the `store()` Javadoc block entirely:

```java
    /**
     * Store a memory about an entity. Returns the assigned memoryId.
     *
     * <p>Append-only at the SPI level. The no-op returns {@code ""}.
     * Adapters MUST call {@link MemoryPermissions#assertTenant} before delegating to the backend.
     *
     * <p><b>Emission pattern:</b> inject {@code CaseMemoryStore} directly and call
     * {@code store()} from your domain event handler. This is the canonical pattern —
     * direct injection keeps exception propagation intact ({@link SecurityException} from
     * {@code assertTenant()} reaches the caller), keeps request context active for
     * {@code @RequestScoped} implementations, and is consistent with the read API
     * ({@link #query}).
     *
     * <p>This analysis assumes an active request scope. Callers in non-request contexts
     * (batch jobs, startup) must activate request scope explicitly before calling any
     * {@code @RequestScoped} SPI implementation.
     *
     * <p><b>{@code @ObservesAsync} is not safe for memory writes.</b> Async observers
     * run on a thread pool where the request scope is not propagated by default — a
     * {@code @RequestScoped CurrentPrincipal} is unavailable, causing
     * {@link jakarta.enterprise.context.ContextNotActiveException} before
     * {@code assertTenant()} fires. Exceptions are also invisible to the original caller,
     * so compliance failures are swallowed silently.
     *
     * <p><b>{@code @Observes} (synchronous) is acceptable</b> — it preserves request
     * context and propagates exceptions normally. A synchronous CDI observer that calls
     * {@code store()} directly is a valid consumption pattern equivalent to Option A
     * with an intervening domain event. The tradeoff is that it couples the store call
     * to the event publisher's transaction, which is correct for compliance-adjacent
     * writes.
     *
     * <p><b>Text field guidance:</b> {@link MemoryInput#text()} must be human-readable
     * natural language when using semantic adapters (Mem0, Graphiti) — it is the field
     * embedded for vector search. Use {@link MemoryInput#attributes()} for structured
     * metadata. See {@link MemoryAttributeKeys} for reserved cross-domain attribute keys.
     */
    String store(MemoryInput input);
```

- [ ] **Step 2: Build platform-api to verify compilation**

```bash
mvn --batch-mode -pl platform-api test
```

Expected: `BUILD SUCCESS`. (No code change, only Javadoc — compiler still validates it.)

- [ ] **Step 3: Update PLATFORM.md capability ownership**

In `casehub-parent/docs/PLATFORM.md`, find the CaseMemoryStore capability row in the "Capability Ownership" table. It currently ends with a reference to adapters and `BlockingToReactiveBridge`. Append to the end of that cell:

Find the row starting with `| Agent memory (queryable, permission-aware, persistent)` and add to the end of the row description (before the trailing `|`):

```
Emission: direct injection is canonical — inject `CaseMemoryStore` and call `store()` from the domain event handler. See SPI Javadoc for thread-context and transaction atomicity guidance.
```

- [ ] **Step 4: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add \
  platform-api/src/main/java/io/casehub/platform/api/memory/CaseMemoryStore.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "docs(platform#49): rewrite CaseMemoryStore.store() Javadoc — direct injection is canonical emission pattern"

git -C /Users/mdproctor/claude/casehub/parent add docs/PLATFORM.md
git -C /Users/mdproctor/claude/casehub/parent commit -m "docs(platform#49): add emission guidance to CaseMemoryStore capability entry"
```

---

## Task 3: NoOpCaseMemoryStore Explicit storeAll() Override

**Files:**
- Modify: `platform/src/main/java/io/casehub/platform/memory/NoOpCaseMemoryStore.java`
- Test (existing): `platform/src/test/java/io/casehub/platform/memory/NoOpCaseMemoryStoreTest.java`

The test `storeAll_returns_empty_ids()` already exists in `NoOpCaseMemoryStoreTest` and asserts `List.of("", "")`. It currently passes via the SPI default. Adding the explicit override makes the contract unambiguous without changing the observable behavior.

- [ ] **Step 1: Verify the existing test passes before the change**

```bash
mvn --batch-mode -pl platform test -Dtest=NoOpCaseMemoryStoreTest
```

Expected: `BUILD SUCCESS`. All tests pass.

- [ ] **Step 2: Add the explicit storeAll() override**

In `platform/src/main/java/io/casehub/platform/memory/NoOpCaseMemoryStore.java`, add:

```java
package io.casehub.platform.memory;

import io.casehub.platform.api.memory.CaseMemoryStore;
import io.casehub.platform.api.memory.EraseRequest;
import io.casehub.platform.api.memory.Memory;
import io.casehub.platform.api.memory.MemoryInput;
import io.casehub.platform.api.memory.MemoryQuery;
import io.quarkus.arc.DefaultBean;
import jakarta.enterprise.context.ApplicationScoped;
import java.util.Collections;
import java.util.List;

@DefaultBean
@ApplicationScoped
public class NoOpCaseMemoryStore implements CaseMemoryStore {

    @Override public String store(MemoryInput input) { return ""; }
    @Override public List<Memory> query(MemoryQuery query) { return List.of(); }
    @Override public void erase(EraseRequest request) {}
    @Override public void eraseById(String memoryId, String tenantId) {}
    @Override public void eraseEntity(String entityId, String tenantId) {}

    @Override
    public List<String> storeAll(List<MemoryInput> inputs) {
        return Collections.nCopies(inputs.size(), "");
    }
}
```

- [ ] **Step 3: Run the test to verify it still passes**

```bash
mvn --batch-mode -pl platform test -Dtest=NoOpCaseMemoryStoreTest
```

Expected: `BUILD SUCCESS`. `storeAll_returns_empty_ids` passes — `Collections.nCopies(2, "")` equals `List.of("", "")`.

- [ ] **Step 4: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add \
  platform/src/main/java/io/casehub/platform/memory/NoOpCaseMemoryStore.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#49): NoOpCaseMemoryStore — explicit storeAll() returning N × empty string"
```

---

## Task 4: storeAll() Contract Tests

**Files:**
- Modify: `testing/src/main/java/io/casehub/platform/testing/memory/CaseMemoryStoreContractTest.java`

These tests go in the shared contract suite so they exercise every adapter that extends it (currently `InMemoryMemoryStoreTest` and `JpaMemoryStoreTest`). They will pass immediately for `InMemoryMemoryStore` (which inherits the SPI default). They will also pass immediately for `JpaMemoryStore` (which also uses the default before Task 5). Task 5 adds the JPA-specific failing test that distinguishes the override from the default.

- [ ] **Step 1: Add storeAll() contract tests**

In `testing/src/main/java/io/casehub/platform/testing/memory/CaseMemoryStoreContractTest.java`, add the following tests after the `// --- eraseEntity ---` block (before the closing `}`):

```java
    // --- storeAll ---

    @Test
    void storeAll_empty_returns_empty_list() {
        assertEquals(List.of(), store().storeAll(List.of()));
    }

    @Test
    void storeAll_returns_non_empty_ids_in_input_order() {
        var a = input("fact-a");
        var b = input("entity-2", "fact-b");
        var c = input("fact-c");

        List<String> ids = store().storeAll(List.of(a, b, c));

        assertEquals(3, ids.size());
        ids.forEach(id -> assertFalse(id.isEmpty(), "each returned ID must be non-empty"));
        assertNotEquals(ids.get(0), ids.get(1));
        assertNotEquals(ids.get(1), ids.get(2));
    }

    @Test
    void storeAll_all_entries_queryable_after_call() {
        var a = input("entity-1", "fact-a");
        var b = input("entity-2", "fact-b");

        store().storeAll(List.of(a, b));

        var e1 = store().query(MemoryQuery.forEntity("entity-1", DOMAIN, TENANT));
        var e2 = store().query(MemoryQuery.forEntity("entity-2", DOMAIN, TENANT));
        assertEquals(1, e1.size());
        assertEquals("fact-a", e1.get(0).text());
        assertEquals(1, e2.size());
        assertEquals("fact-b", e2.get(0).text());
    }

    @Test
    void storeAll_all_wrong_tenant_throws_security_exception() {
        var bad = new MemoryInput("entity-1", DOMAIN, OTHER_TENANT, null, "x", Map.of());
        assertThrows(SecurityException.class, () -> store().storeAll(List.of(bad)));
    }
```

Make sure `Map` and `List` imports are present (they already are from the existing contract test).

- [ ] **Step 2: Build the testing module**

```bash
mvn --batch-mode -pl testing install
```

Expected: `BUILD SUCCESS`.

- [ ] **Step 3: Run InMemoryMemoryStoreTest to verify contract tests pass for inmem**

```bash
mvn --batch-mode -pl memory-inmem test
```

Expected: `BUILD SUCCESS`. The four new contract tests pass on `InMemoryMemoryStore` via the SPI default implementation.

- [ ] **Step 4: Run JpaMemoryStoreTest to verify contract tests pass for JPA before the override**

```bash
mvn --batch-mode -pl memory-jpa test -Dtest=JpaMemoryStoreTest
```

Expected: `BUILD SUCCESS`. The four new contract tests pass on `JpaMemoryStore` via the SPI default (each store() call uses its own transaction; all entries ARE committed, all IDs non-empty, wrong-tenant throws SecurityException on item 0 before any commit).

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add \
  testing/src/main/java/io/casehub/platform/testing/memory/CaseMemoryStoreContractTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "test(platform#49): add storeAll() contract tests to CaseMemoryStoreContractTest"
```

---

## Task 5: JpaMemoryStore.storeAll() — TDD

**Files:**
- Modify: `memory-jpa/src/test/java/io/casehub/platform/memory/jpa/JpaMemoryStoreTest.java`
- Modify: `memory-jpa/src/main/java/io/casehub/platform/memory/jpa/JpaMemoryStore.java`

**Background:** With the SPI default, `storeAll([{tenantA}, {tenantB}])` with `principal=tenantA`:
- `store({tenantA})` → REQUIRED creates its own transaction → item 0 committed
- `store({tenantB})` → REQUIRED creates its own transaction → SecurityException → this tx rolls back, item 0 stays committed

The override changes this: a single transaction wraps all items; any SecurityException during stream evaluation aborts before `persist()` is called → 0 rows inserted.

- [ ] **Step 1: Write the failing test**

In `memory-jpa/src/test/java/io/casehub/platform/memory/jpa/JpaMemoryStoreTest.java`, add after the existing `assertTenant_mismatch_throws_before_backend_call` test:

```java
    @Test
    void storeAll_mixed_tenant_does_not_persist_any_entry() {
        var good = new MemoryInput("entity-1", DOMAIN, TENANT,       null, "good", Map.of());
        var bad  = new MemoryInput("entity-1", DOMAIN, OTHER_TENANT, null, "bad",  Map.of());

        assertThrows(SecurityException.class,
            () -> store().storeAll(List.of(good, bad)));

        // With the single-transaction override: item 0 was never persisted (exception
        // fired during stream.toList(), before MemoryEntry.persist() was reached).
        // Without the override (SPI default): item 0 WAS committed in its own transaction.
        assertEquals(0, store().query(query()).size(),
            "Mixed-tenant storeAll must not persist any entries");
    }
```

You also need `OTHER_TENANT` — this constant is defined on the parent class `CaseMemoryStoreContractTest`:
```java
protected static final String OTHER_TENANT = "tenant-2";
```

It is already available in `JpaMemoryStoreTest` via inheritance.

- [ ] **Step 2: Run the failing test to confirm it fails**

```bash
mvn --batch-mode -pl memory-jpa test -Dtest=JpaMemoryStoreTest#storeAll_mixed_tenant_does_not_persist_any_entry
```

Expected: **FAIL** — `AssertionError: Mixed-tenant storeAll must not persist any entries ==> expected: <0> but was: <1>`. This confirms the test correctly detects the partial-write behavior of the SPI default.

- [ ] **Step 3: Add the storeAll() override to JpaMemoryStore**

In `memory-jpa/src/main/java/io/casehub/platform/memory/jpa/JpaMemoryStore.java`, add this method after the `store()` method:

```java
    @Override
    @Transactional(TxType.REQUIRED)
    public List<String> storeAll(List<MemoryInput> inputs) {
        if (inputs.isEmpty()) return List.of();
        var entries = inputs.stream().map(input -> {
            MemoryPermissions.assertTenant(input.tenantId(), principal);
            MemoryEntry e = new MemoryEntry();
            e.memoryId   = UUID.randomUUID().toString();
            e.tenantId   = input.tenantId();
            e.entityId   = input.entityId();
            e.domain     = input.domain().name();
            e.caseId     = input.caseId();
            e.text       = input.text();
            e.attributes = serializeAttributes(input.attributes());
            e.createdAt  = Instant.now();
            return e;
        }).toList();
        MemoryEntry.persist(entries);
        return entries.stream().map(e -> e.memoryId).toList();
    }
```

All required imports are already present in `JpaMemoryStore.java`:
- `MemoryPermissions` — imported as `io.casehub.platform.api.memory.MemoryPermissions` (via wildcard `io.casehub.platform.api.memory.*`)
- `UUID` — `java.util.UUID`
- `Instant` — `java.time.Instant`
- `List` — `java.util.List`
- `Transactional`, `TxType` — `jakarta.transaction.Transactional`, `jakarta.transaction.Transactional.TxType`
- `MemoryEntry` — in same package

- [ ] **Step 4: Run the failing test — confirm it now passes**

```bash
mvn --batch-mode -pl memory-jpa test -Dtest=JpaMemoryStoreTest#storeAll_mixed_tenant_does_not_persist_any_entry
```

Expected: **PASS**.

- [ ] **Step 5: Run the full JpaMemoryStoreTest suite**

```bash
mvn --batch-mode -pl memory-jpa test -Dtest=JpaMemoryStoreTest
```

Expected: `BUILD SUCCESS`. All contract tests and JPA-specific tests pass, including the four new storeAll() contract tests.

- [ ] **Step 6: Run the full memory-jpa module build**

```bash
mvn --batch-mode -pl memory-jpa test
```

Expected: `BUILD SUCCESS`. All tests in the module pass (JpaMemoryStoreTest, PostgresDialectFtsTest, PostgresDialectFtsFrenchTest).

- [ ] **Step 7: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add \
  memory-jpa/src/main/java/io/casehub/platform/memory/jpa/JpaMemoryStore.java \
  memory-jpa/src/test/java/io/casehub/platform/memory/jpa/JpaMemoryStoreTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#49): JpaMemoryStore.storeAll() — single-transaction batch, per-item assertTenant closes #49"
```

---

## Task 6: Full Build Verification

- [ ] **Step 1: Run the full project build**

```bash
mvn --batch-mode install
```

Expected: `BUILD SUCCESS`. All modules compile and all tests pass.

- [ ] **Step 2: Push branch**

```bash
git -C /Users/mdproctor/claude/casehub/platform push -u origin issue-39-memory-cdi-and-priority
```

---

## Self-Review Against Spec

**Spec coverage check:**

| Spec requirement | Covered by |
|---|---|
| `InMemoryMemoryStore` → `@Priority(10)` | Task 1 Step 1 |
| Priority reserved bands documented | Task 1 Step 4 |
| `persistence-backend-cdi-priority.md` updated | Task 1 Step 4 |
| CLAUDE.md `memory-inmem/` row updated | Task 1 Step 3 |
| `CaseMemoryStore.store()` Javadoc rewritten | Task 2 Step 1 |
| PLATFORM.md emission note added | Task 2 Step 3 |
| `NoOpCaseMemoryStore.storeAll()` explicit override | Task 3 Step 2 |
| storeAll() contract tests (empty, happy, wrong-tenant) | Task 4 Step 1 |
| JpaMemoryStore.storeAll() override — single transaction | Task 5 Step 3 |
| Per-item assertTenant → SecurityException on mismatch | Task 5 Step 3 |
| Mixed-tenant no partial write test | Task 5 Step 1 |
| Full build verification | Task 6 Step 1 |
| Mem0 deferred → platform#69 | No implementation needed |
| ReactiveCaseMemoryStore: bridge delegates to blocking storeAll() (pre-existing) | No change needed |

**Placeholder scan:** No TBDs, TODOs, or "similar to Task N" references. All code blocks complete.

**Type consistency:** `MemoryPermissions.assertTenant(input.tenantId(), principal)` — consistent with `store()` signature. `MemoryEntry.persist(entries)` where `entries: List<MemoryEntry>` — Panache `PanacheEntityBase.persist(Iterable)` signature matches. `List<String>` return type on `storeAll()` — matches SPI default.
