# Mem0 storeAll() — sequential batch with pre-flight tenant guard

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Override `storeAll()` in `Mem0CaseMemoryStore` with pre-flight tenant checking and sequential REST calls; fix the same partial-write bug in `InMemoryMemoryStore`; add the missing mixed-tenant contract test; update the protocol and SPI Javadoc.

**Architecture:** Pre-flight `assertTenant` for all inputs before any backend operation (REST or in-memory). JPA and SQLite already use JDBC/JTA transactions for this guarantee. REST and in-memory adapters have no transaction, so pre-flight is the only mechanism. Sequential fail-fast on first error. `List.copyOf()` for unmodifiable return, consistent with SPI default and JPA.

**Tech Stack:** Java 21, Quarkus, MicroProfile REST Client (Quarkus REST Client), WireMock (tests), JUnit 5, SmallRye Metrics (`@Timed`).

---

## File Map

| File | Action | What changes |
|------|--------|-------------|
| `casehub/garden/docs/protocols/casehub/memory-storeall-transactional-contract.md` | Modify | Add REST-adapter clause |
| `testing/src/main/java/io/casehub/platform/testing/memory/CaseMemoryStoreContractTest.java` | Modify | Add `storeAll_second_item_tenant_mismatch_no_entries_stored` test |
| `memory-inmem/src/main/java/io/casehub/platform/memory/inmem/InMemoryMemoryStore.java` | Modify | Add `storeAll()` override with pre-flight |
| `platform-api/src/main/java/io/casehub/platform/api/memory/CaseMemoryStore.java` | Modify | Clarify `storeAll()` Javadoc |
| `memory-mem0/src/test/java/io/casehub/platform/memory/mem0/Mem0CaseMemoryStoreTest.java` | Modify | Add 3 new `storeAll` tests |
| `memory-mem0/src/main/java/io/casehub/platform/memory/mem0/Mem0CaseMemoryStore.java` | Modify | Extract `sendAdd()`, add `storeAll()` override |

---

## Task 1: Update the protocol — add REST-adapter clause

**Files:**
- Modify: `/Users/mdproctor/claude/casehub/garden/docs/protocols/casehub/memory-storeall-transactional-contract.md`

- [ ] **Step 1: Read the current protocol**

  File path: `/Users/mdproctor/claude/casehub/garden/docs/protocols/casehub/memory-storeall-transactional-contract.md`

  Current body (after the frontmatter `---`) reads:
  > Any CaseMemoryStore adapter overriding `storeAll()` must wrap all N inserts in a single `@Transactional(REQUIRED)` scope, call `MemoryPermissions.assertTenant()` per item inside the batch (not just on the first item), and propagate `SecurityException` for any mismatch. This guarantees atomicity: no entries are persisted if any item fails the tenant check. The SPI default (`store() × N`) must not be used when partial-write safety is required — it issues a separate transaction per call, committing earlier items before the violation is detected. Exception type on mismatch must be `SecurityException` (from `assertTenant`), not `IllegalArgumentException`, so callers can write adapter-neutral catch clauses.

- [ ] **Step 2: Append the REST-adapter clause**

  Append two blank lines and the following paragraph to the file body (do not touch the frontmatter):

  ```
  **REST-backed adapters** (Mem0, Graphiti, and any future HTTP-delegating adapters) have no
  JPA transaction. The equivalent guarantee is: pre-flight `MemoryPermissions.assertTenant()`
  for **all** inputs before issuing any HTTP request, then fail-fast on the first HTTP error.
  A `SecurityException` from `storeAll()` is therefore always clean — nothing was sent to the
  backend. Items already persisted before a mid-batch HTTP failure cannot be rolled back — this
  is a documented REST adapter limitation and must be noted in the adapter's Javadoc or spec.
  ```

  Also update the frontmatter `applies_to` field to include REST adapters:
  ```yaml
  applies_to: "All CaseMemoryStore adapter implementations — memory-jpa, memory-sqlite, memory-inmem, memory-mem0, and any future adapters (memory-graphiti, etc.)"
  ```

- [ ] **Step 3: Commit the protocol to the garden repo**

  ```bash
  git -C /Users/mdproctor/claude/casehub/garden add docs/protocols/casehub/memory-storeall-transactional-contract.md
  git -C /Users/mdproctor/claude/casehub/garden commit -m "protocol(PP-20260605-e63850): add REST-adapter clause for storeAll() pre-flight pattern"
  ```

  Expected: one-line commit confirmation, no errors.

---

## Task 2: Write the failing contract test

**Files:**
- Modify: `testing/src/main/java/io/casehub/platform/testing/memory/CaseMemoryStoreContractTest.java`

The contract test is a shared abstract base class. Three adapter test classes extend it:
`InMemoryMemoryStoreTest`, `JpaMemoryStoreTest`, `SqliteMemoryStoreTest`. Adding a test here runs it against all three. Only `InMemoryMemoryStoreTest` will fail — InMemory uses the SPI default which has a partial-write bug.

- [ ] **Step 1: Add the new test to `CaseMemoryStoreContractTest`**

  Add the following test immediately after the existing `storeAll_all_wrong_tenant_throws_security_exception` test (last test in the file, just before the closing `}`):

  ```java
  @Test
  void storeAll_second_item_tenant_mismatch_no_entries_stored() {
      var good = input("entity-1", "fact");
      var bad  = new MemoryInput("entity-2", DOMAIN, OTHER_TENANT, null, "x", Map.of());
      assertThrows(SecurityException.class, () -> store().storeAll(List.of(good, bad)));
      assertTrue(store().query(query()).isEmpty(),
          "first item must not be persisted when second item fails tenant check");
  }
  ```

  `input()`, `DOMAIN`, `OTHER_TENANT`, `query()` are all defined in the base class — no new imports needed.

- [ ] **Step 2: Run InMemoryMemoryStore tests to confirm RED**

  ```bash
  mvn --batch-mode test -pl memory-inmem
  ```

  Expected: `BUILD FAILURE`. The test `storeAll_second_item_tenant_mismatch_no_entries_stored` fails with an assertion error because `store().query(query())` returns 1 result — the first item was persisted before the second item threw `SecurityException`.

  JPA and SQLite tests are not running here — those adapters already handle this correctly via their transactions.

---

## Task 3: Fix `InMemoryMemoryStore` — add `storeAll()` override

**Files:**
- Modify: `memory-inmem/src/main/java/io/casehub/platform/memory/inmem/InMemoryMemoryStore.java`

- [ ] **Step 1: Add the `storeAll()` override**

  Add the following method to `InMemoryMemoryStore`, after the `store()` method (around line 42):

  ```java
  @Override
  public List<String> storeAll(List<MemoryInput> inputs) {
      if (inputs.isEmpty()) return List.of();
      inputs.forEach(i -> MemoryPermissions.assertTenant(i.tenantId(), principal));
      return inputs.stream().map(this::store).toList();
  }
  ```

  Note: `store()` re-checks `assertTenant` — this is an acceptable double-check. `store()` is a public SPI method and must remain self-defending. The pre-flight here is what prevents partial writes; the per-item check in `store()` is defence-in-depth.

  No new imports needed — `MemoryPermissions` and `MemoryInput` are already imported.

- [ ] **Step 2: Run InMemoryMemoryStore tests — confirm GREEN**

  ```bash
  mvn --batch-mode test -pl memory-inmem
  ```

  Expected: `BUILD SUCCESS`. All contract tests pass, including `storeAll_second_item_tenant_mismatch_no_entries_stored`.

- [ ] **Step 3: Commit Tasks 2 and 3 together**

  ```bash
  git -C /Users/mdproctor/claude/casehub/platform add \
    testing/src/main/java/io/casehub/platform/testing/memory/CaseMemoryStoreContractTest.java \
    memory-inmem/src/main/java/io/casehub/platform/memory/inmem/InMemoryMemoryStore.java
  git -C /Users/mdproctor/claude/casehub/platform commit -m "fix(platform#69): storeAll() pre-flight tenant guard — contract test + InMemoryMemoryStore fix"
  ```

---

## Task 4: Update `CaseMemoryStore` Javadoc

**Files:**
- Modify: `platform-api/src/main/java/io/casehub/platform/api/memory/CaseMemoryStore.java`

- [ ] **Step 1: Replace the existing `storeAll()` Javadoc**

  Current Javadoc:
  ```java
  /**
   * Convenience bulk store. Returns assigned memoryIds in input order.
   * Adapters may override for efficiency.
   */
  default List<String> storeAll(List<MemoryInput> inputs) {
  ```

  Replace with:
  ```java
  /**
   * Convenience bulk store. Returns assigned memoryIds in input order.
   *
   * <p>Adapters that override this method must: (1) call
   * {@link MemoryPermissions#assertTenant} for every input; (2) return IDs in input
   * order; (3) ensure no items are durably written if any tenant check fails — via
   * pre-flight for REST-backed adapters, or single-transaction rollback for
   * JDBC-backed adapters. See {@code memory-storeall-transactional-contract.md}
   * for the full contract.
   *
   * <p>The default implementation is not safe for mixed-tenant batches where partial-write
   * prevention is required — override in production adapters.
   */
  default List<String> storeAll(List<MemoryInput> inputs) {
  ```

- [ ] **Step 2: Compile to confirm no errors**

  ```bash
  mvn --batch-mode compile -pl platform-api
  ```

  Expected: `BUILD SUCCESS`. Javadoc change only — no logic change.

- [ ] **Step 3: Commit**

  ```bash
  git -C /Users/mdproctor/claude/casehub/platform add \
    platform-api/src/main/java/io/casehub/platform/api/memory/CaseMemoryStore.java
  git -C /Users/mdproctor/claude/casehub/platform commit -m "docs(platform#69): CaseMemoryStore.storeAll() — document override contract (outcome-based)"
  ```

---

## Task 5: Write failing Mem0 tests

**Files:**
- Modify: `memory-mem0/src/test/java/io/casehub/platform/memory/mem0/Mem0CaseMemoryStoreTest.java`

These tests exercise Mem0-specific behaviour via WireMock. The test class is a `@QuarkusTest` using `Mem0WireMockResource`. `wireMock().resetAll()` runs before each test — no stub setup carries over.

Key context:
- `TENANT = "tenant-1"`, `OTHER_TENANT = "tenant-2"`, `DOMAIN = new MemoryDomain("d")`
- `principal.setTenancyId(TENANT)` is set in `@BeforeEach`
- WireMock returns 404 by default for unmapped requests

- [ ] **Step 1: Add three tests to the `// ── storeAll ──` section**

  The existing section ends at line 474 (just before the closing `}`). Add the three new tests after the existing `storeAll_returns_all_memory_ids_in_order` test:

  ```java
  @Test
  void storeAll_empty_returns_empty_no_http() {
      assertEquals(List.of(), store.storeAll(List.of()));
      wireMock().verify(0, postRequestedFor(urlEqualTo("/memories")));
  }

  @Test
  void storeAll_any_tenant_mismatch_fires_zero_http_calls() {
      assertThrows(SecurityException.class, () ->
          store.storeAll(List.of(
              new MemoryInput("entity-1", DOMAIN, TENANT,       null, "ok",  Map.of()),
              new MemoryInput("entity-2", DOMAIN, OTHER_TENANT, null, "bad", Map.of())
          )));
      wireMock().verify(0, postRequestedFor(urlEqualTo("/memories")));
  }

  @Test
  void storeAll_http_failure_stops_remaining_items() {
      wireMock().stubFor(post(urlEqualTo("/memories")).willReturn(serverError()));
      assertThrows(Mem0StoreException.class, () ->
          store.storeAll(List.of(
              new MemoryInput("entity-1", DOMAIN, TENANT, null, "a", Map.of()),
              new MemoryInput("entity-1", DOMAIN, TENANT, null, "b", Map.of())
          )));
      wireMock().verify(1, postRequestedFor(urlEqualTo("/memories")));
  }
  ```

  No new imports needed — `MemoryInput`, `Mem0StoreException`, `TENANT`, `OTHER_TENANT`, `DOMAIN`, and all WireMock matchers are already in scope.

- [ ] **Step 2: Run Mem0 tests — confirm RED state for the pre-flight test**

  ```bash
  mvn --batch-mode test -pl memory-mem0
  ```

  Expected: `BUILD FAILURE`. The test `storeAll_any_tenant_mismatch_fires_zero_http_calls` fails — with the SPI default, `store(item-0)` fires a POST (WireMock returns 404 which becomes `Mem0StoreException`, not `SecurityException`), so the wrong exception type is thrown AND 1 HTTP call was made.

  The other two new tests pass with the SPI default: `storeAll_empty_returns_empty_no_http` passes (empty stream = no calls), `storeAll_http_failure_stops_remaining_items` passes (first call throws, stream terminates before second).

---

## Task 6: Implement `Mem0CaseMemoryStore.storeAll()`

**Files:**
- Modify: `memory-mem0/src/main/java/io/casehub/platform/memory/mem0/Mem0CaseMemoryStore.java`

- [ ] **Step 1: Extract `sendAdd()` from `store()`**

  Current `store()` method (lines ~37–58):
  ```java
  @Timed(value = "casehub.memory.mem0", histogram = true, extraTags = {"operation", "store"})
  @Override
  public String store(MemoryInput input) {
      MemoryPermissions.assertTenant(input.tenantId(), principal);

      final var request = new Mem0AddRequest(
          List.of(new Mem0AddRequest.Mem0Message("user", input.text())),
          compoundUserId(input.tenantId(), input.entityId()),
          input.domain().name(),
          input.caseId(),
          config.infer(),
          new HashMap<>(input.attributes())
      );

      final Mem0AddResponse response;
      try {
          response = client.add(request);
      } catch (WebApplicationException e) {
          throw toStoreException(e);
      }

      if (response.results() == null || response.results().isEmpty()) {
          throw new Mem0StoreException("store produced no result for: " + input.entityId());
      }
      return response.results().get(0).id();
  }
  ```

  Replace with:
  ```java
  @Timed(value = "casehub.memory.mem0", histogram = true, extraTags = {"operation", "store"})
  @Override
  public String store(MemoryInput input) {
      MemoryPermissions.assertTenant(input.tenantId(), principal);
      return sendAdd(input);
  }

  @Timed(value = "casehub.memory.mem0", histogram = true, extraTags = {"operation", "storeAll"})
  @Override
  public List<String> storeAll(List<MemoryInput> inputs) {
      if (inputs.isEmpty()) return List.of();
      inputs.forEach(i -> MemoryPermissions.assertTenant(i.tenantId(), principal));
      final var ids = new ArrayList<String>(inputs.size());
      for (final var input : inputs) {
          ids.add(sendAdd(input));
      }
      return List.copyOf(ids);
  }

  private String sendAdd(MemoryInput input) {
      final var request = new Mem0AddRequest(
          List.of(new Mem0AddRequest.Mem0Message("user", input.text())),
          compoundUserId(input.tenantId(), input.entityId()),
          input.domain().name(),
          input.caseId(),
          config.infer(),
          new HashMap<>(input.attributes())
      );
      final Mem0AddResponse response;
      try {
          response = client.add(request);
      } catch (WebApplicationException e) {
          throw toStoreException(e);
      }
      if (response.results() == null || response.results().isEmpty()) {
          throw new Mem0StoreException("store produced no result for: " + input.entityId());
      }
      return response.results().get(0).id();
  }
  ```

  Add `import java.util.ArrayList;` if not already present. `List` is already imported. No other new imports needed.

- [ ] **Step 2: Run all Mem0 tests — confirm GREEN**

  ```bash
  mvn --batch-mode test -pl memory-mem0
  ```

  Expected: `BUILD SUCCESS`. All tests pass including:
  - `storeAll_returns_all_memory_ids_in_order` (existing, sequential ordering)
  - `storeAll_empty_returns_empty_no_http` (new)
  - `storeAll_any_tenant_mismatch_fires_zero_http_calls` (new — was failing)
  - `storeAll_http_failure_stops_remaining_items` (new)

- [ ] **Step 3: Commit Tasks 5 and 6 together**

  ```bash
  git -C /Users/mdproctor/claude/casehub/platform add \
    memory-mem0/src/test/java/io/casehub/platform/memory/mem0/Mem0CaseMemoryStoreTest.java \
    memory-mem0/src/main/java/io/casehub/platform/memory/mem0/Mem0CaseMemoryStore.java
  git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#69): Mem0CaseMemoryStore.storeAll() — pre-flight tenant guard, sequential batch, List.copyOf"
  ```

---

## Task 7: Full build verification

- [ ] **Step 1: Build all modules**

  ```bash
  mvn --batch-mode install
  ```

  Expected: `BUILD SUCCESS`. All modules compile and all tests pass. If JPA or SQLite tests require Docker (Testcontainers/Dev Services), they will start automatically.

- [ ] **Step 2: Confirm Mem0 and InMemory modules specifically**

  If the full build above passed, this is already confirmed. If you want to spot-check:

  ```bash
  mvn --batch-mode test -pl memory-inmem,memory-mem0
  ```

  Expected: `BUILD SUCCESS` for both.
