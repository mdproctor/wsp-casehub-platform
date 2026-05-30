# CaseMemoryStore Consumer Feedback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve the SPI gaps from platform#48 — multi-entity query, `MemoryOrder` enum, `MemoryAttributeKeys` constants, `MemoryInput` blank validation, and Javadoc for `text` field and emission pattern — before any new adapter work begins.

**Architecture:** All changes land in a single sequential changeset: `platform-api` first (new types + evolved records), then `memory-inmem` and `memory-jpa` adapters updated to compile and pass against the new API. The breaking change to `MemoryQuery` (entityId→entityIds, recentFirst→MemoryOrder) is intentional — no backwards-compatibility shims.

**Tech Stack:** Java 21 records, JUnit 5, Hibernate/JPA (native SQL IN-clause with List parameter), Quarkus @QuarkusTest + @TestTransaction for JPA tests, Maven multi-module build.

---

## File Map

| File | Action |
|------|--------|
| `platform-api/src/main/java/io/casehub/platform/api/memory/MemoryOrder.java` | Create |
| `platform-api/src/main/java/io/casehub/platform/api/memory/MemoryAttributeKeys.java` | Create |
| `platform-api/src/test/java/io/casehub/platform/api/memory/MemoryAttributeKeysTest.java` | Create |
| `platform-api/src/main/java/io/casehub/platform/api/memory/MemoryInput.java` | Modify — add blank check |
| `platform-api/src/test/java/io/casehub/platform/api/memory/MemoryInputTest.java` | Modify — add blank text test |
| `platform-api/src/main/java/io/casehub/platform/api/memory/MemoryQuery.java` | Replace — entityIds, MemoryOrder, factory methods, with* fluent |
| `platform-api/src/test/java/io/casehub/platform/api/memory/MemoryQueryTest.java` | Replace — new API |
| `platform-api/src/main/java/io/casehub/platform/api/memory/CaseMemoryStore.java` | Modify — Javadoc only |
| `memory-inmem/src/main/java/io/casehub/platform/memory/inmem/InMemoryMemoryStore.java` | Modify — entityIds fan-out, MemoryOrder ignored |
| `memory-inmem/src/test/java/io/casehub/platform/memory/inmem/InMemoryMemoryStoreTest.java` | Modify — new API + contract tests |
| `memory-jpa/src/main/java/io/casehub/platform/memory/jpa/JpaMemoryStore.java` | Modify — IN clause, MemoryOrder routing |
| `memory-jpa/src/test/java/io/casehub/platform/memory/jpa/JpaMemoryStoreTest.java` | Modify — new API + contract tests |

---

### Task 1: `MemoryOrder` enum

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/memory/MemoryOrder.java`

- [ ] **Step 1: Create `MemoryOrder.java`**

```java
package io.casehub.platform.api.memory;

/**
 * Controls how {@link CaseMemoryStore#query} ranks results.
 *
 * <p>Non-semantic adapters (in-memory, JPA without FTS) always use
 * {@link #CHRONOLOGICAL} regardless of this field.
 */
public enum MemoryOrder {

    /**
     * Results ordered by creation time, newest first.
     * All adapters honour this mode.
     */
    CHRONOLOGICAL,

    /**
     * Results ordered by relevance to {@link MemoryQuery#question()}.
     * Adapters with relevance ranking (JPA FTS via ts_rank, Mem0 vector search,
     * Graphiti temporal graph) honour this; others silently fall back to
     * {@link #CHRONOLOGICAL}.
     * If {@code question} is {@code null}, all adapters fall back to
     * {@link #CHRONOLOGICAL}.
     */
    RELEVANCE
}
```

- [ ] **Step 2: Build platform-api**

```bash
mvn --batch-mode test -pl platform-api
```

Expected: BUILD SUCCESS (no existing tests reference this new type yet).

- [ ] **Step 3: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform-api/src/main/java/io/casehub/platform/api/memory/MemoryOrder.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(memory-api): add MemoryOrder enum — CHRONOLOGICAL / RELEVANCE (#48)"
```

---

### Task 2: `MemoryAttributeKeys`

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/memory/MemoryAttributeKeys.java`
- Create: `platform-api/src/test/java/io/casehub/platform/api/memory/MemoryAttributeKeysTest.java`

- [ ] **Step 1: Write the failing tests**

```java
package io.casehub.platform.api.memory;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class MemoryAttributeKeysTest {

    @Test
    void format_confidence_produces_four_decimal_places() {
        assertEquals("0.8500", MemoryAttributeKeys.formatConfidence(0.85));
        assertEquals("1.0000", MemoryAttributeKeys.formatConfidence(1.0));
        assertEquals("0.0000", MemoryAttributeKeys.formatConfidence(0.0));
    }

    @Test
    void format_confidence_rejects_out_of_range() {
        assertThrows(IllegalArgumentException.class, () -> MemoryAttributeKeys.formatConfidence(-0.01));
        assertThrows(IllegalArgumentException.class, () -> MemoryAttributeKeys.formatConfidence(1.01));
    }

    @Test
    void parse_confidence_round_trips() {
        double original = 0.8234;
        String formatted = MemoryAttributeKeys.formatConfidence(original);
        assertEquals(original, MemoryAttributeKeys.parseConfidence(formatted), 0.00001);
    }

    @Test
    void key_constants_use_kebab_case() {
        assertTrue(MemoryAttributeKeys.ACTOR_ID.contains("-"));
        assertTrue(MemoryAttributeKeys.ACTOR_ROLE.contains("-"));
        assertTrue(MemoryAttributeKeys.OUTCOME.equals("outcome") || !MemoryAttributeKeys.OUTCOME.contains("_"));
        assertTrue(MemoryAttributeKeys.CONFIDENCE.equals("confidence") || !MemoryAttributeKeys.CONFIDENCE.contains("_"));
    }
}
```

- [ ] **Step 2: Run to verify compile failure**

```bash
mvn --batch-mode test -pl platform-api -Dtest=MemoryAttributeKeysTest
```

Expected: COMPILATION ERROR — `MemoryAttributeKeys` not found.

- [ ] **Step 3: Create `MemoryAttributeKeys.java`**

```java
package io.casehub.platform.api.memory;

/**
 * Reserved cross-domain attribute keys for {@link MemoryInput#attributes()}.
 *
 * <p>Platform-reserved keys use <b>kebab-case</b>. Consumer applications should
 * follow the same convention for domain-specific keys to avoid collisions.
 *
 * <p>These keys are conventions, not enforced constraints. Their purpose is to
 * allow tooling (GDPR sweeps, audit dashboards) to locate specific fact types
 * across domains without requiring domain knowledge. The <em>values</em> are
 * domain-specific and defined by each consumer application.
 */
public final class MemoryAttributeKeys {

    /**
     * Identity of the actor who produced this memory fact.
     * Use the OIDC subject (same as {@code CurrentPrincipal.actorId()}) when available.
     * This is the primary key for audit; {@link #ACTOR_ROLE} is supplementary.
     */
    public static final String ACTOR_ID = "actor-id";

    /**
     * Role of the actor within the domain (e.g. {@code "reviewer"}, {@code "investigator"},
     * {@code "clinician"}). Supplementary to {@link #ACTOR_ID}.
     */
    public static final String ACTOR_ROLE = "actor-role";

    /**
     * Outcome of the action or case from which this memory was emitted.
     * The key is reserved so tooling can locate outcome facts across domains;
     * values are domain-specific (e.g. {@code "DONE"}/{@code "DECLINE"} in devtown).
     */
    public static final String OUTCOME = "outcome";

    /**
     * Confidence score as a decimal string formatted to 4 decimal places.
     * Always use {@link #formatConfidence} to write and {@link #parseConfidence}
     * to read — do not format manually to avoid encoding variance.
     */
    public static final String CONFIDENCE = "confidence";

    private MemoryAttributeKeys() {}

    /**
     * Formats a confidence value in [0.0, 1.0] to the canonical 4-decimal-place string.
     *
     * @throws IllegalArgumentException if {@code v} is outside [0, 1]
     */
    public static String formatConfidence(double v) {
        if (v < 0 || v > 1)
            throw new IllegalArgumentException("confidence must be in [0,1], got: " + v);
        return String.format("%.4f", v);
    }

    /**
     * Parses a confidence string previously written by {@link #formatConfidence}.
     */
    public static double parseConfidence(String s) {
        return Double.parseDouble(s);
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mvn --batch-mode test -pl platform-api -Dtest=MemoryAttributeKeysTest
```

Expected: BUILD SUCCESS, 4 tests passed.

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform-api/src/main/java/io/casehub/platform/api/memory/MemoryAttributeKeys.java platform-api/src/test/java/io/casehub/platform/api/memory/MemoryAttributeKeysTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(memory-api): MemoryAttributeKeys — reserved cross-domain attribute keys + confidence helpers (#48)"
```

---

### Task 3: `MemoryInput` blank text validation

**Files:**
- Modify: `platform-api/src/main/java/io/casehub/platform/api/memory/MemoryInput.java`
- Modify: `platform-api/src/test/java/io/casehub/platform/api/memory/MemoryInputTest.java`

- [ ] **Step 1: Write the failing test**

Add to `MemoryInputTest.java` after the existing `null_text_throws` test:

```java
    @Test
    void blank_text_throws() {
        assertThrows(IllegalArgumentException.class,
            () -> new MemoryInput("e1", DOMAIN, "t1", null, "   ", Map.of()));
    }

    @Test
    void empty_text_throws() {
        assertThrows(IllegalArgumentException.class,
            () -> new MemoryInput("e1", DOMAIN, "t1", null, "", Map.of()));
    }
```

- [ ] **Step 2: Run to verify they fail**

```bash
mvn --batch-mode test -pl platform-api -Dtest=MemoryInputTest
```

Expected: 2 failures — blank and empty text currently pass the constructor without error.

- [ ] **Step 3: Add blank check to `MemoryInput.java`**

Replace the compact constructor in `MemoryInput.java`:

```java
    public MemoryInput {
        Objects.requireNonNull(entityId,  "entityId required");
        Objects.requireNonNull(domain,    "domain required");
        Objects.requireNonNull(tenantId,  "tenantId required");
        Objects.requireNonNull(text,      "text required");
        if (text.isBlank()) throw new IllegalArgumentException("text must not be blank");
        Objects.requireNonNull(attributes, "attributes required");
        attributes = Map.copyOf(attributes);
    }
```

- [ ] **Step 4: Run all `MemoryInput` tests**

```bash
mvn --batch-mode test -pl platform-api -Dtest=MemoryInputTest
```

Expected: BUILD SUCCESS, all tests pass.

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform-api/src/main/java/io/casehub/platform/api/memory/MemoryInput.java platform-api/src/test/java/io/casehub/platform/api/memory/MemoryInputTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "fix(memory-api): reject blank text in MemoryInput — degenerate embedding guard (#48)"
```

---

### Task 4: `MemoryQuery` evolution

**Files:**
- Replace: `platform-api/src/main/java/io/casehub/platform/api/memory/MemoryQuery.java`
- Replace: `platform-api/src/test/java/io/casehub/platform/api/memory/MemoryQueryTest.java`

Note: this is a breaking change. After this task the `memory-inmem` and `memory-jpa` modules will fail to compile until Tasks 6 and 7 are complete.

- [ ] **Step 1: Replace `MemoryQueryTest.java` with new API tests**

```java
package io.casehub.platform.api.memory;

import org.junit.jupiter.api.Test;
import java.time.Instant;
import java.util.List;
import static org.junit.jupiter.api.Assertions.*;

class MemoryQueryTest {

    static final MemoryDomain DOMAIN = new MemoryDomain("test");

    // --- forEntity factory ---

    @Test
    void forEntity_sets_defaults() {
        var q = MemoryQuery.forEntity("e1", DOMAIN, "t1");
        assertEquals(List.of("e1"), q.entityIds());
        assertEquals(DOMAIN, q.domain());
        assertEquals("t1", q.tenantId());
        assertNull(q.caseId());
        assertNull(q.question());
        assertEquals(20, q.limit());
        assertNull(q.since());
        assertEquals(MemoryOrder.CHRONOLOGICAL, q.order());
    }

    @Test
    void forEntities_accepts_multiple_entities() {
        var q = MemoryQuery.forEntities(List.of("e1", "e2"), DOMAIN, "t1");
        assertEquals(List.of("e1", "e2"), q.entityIds());
    }

    // --- with* fluent modifiers ---

    @Test
    void withCaseId_returns_new_query() {
        var q = MemoryQuery.forEntity("e1", DOMAIN, "t1").withCaseId("case-1");
        assertEquals("case-1", q.caseId());
        assertEquals(List.of("e1"), q.entityIds()); // unchanged
    }

    @Test
    void withQuestion_returns_new_query() {
        var q = MemoryQuery.forEntity("e1", DOMAIN, "t1").withQuestion("what happened?");
        assertEquals("what happened?", q.question());
    }

    @Test
    void withLimit_returns_new_query() {
        var q = MemoryQuery.forEntity("e1", DOMAIN, "t1").withLimit(5);
        assertEquals(5, q.limit());
    }

    @Test
    void withSince_returns_new_query() {
        Instant now = Instant.now();
        var q = MemoryQuery.forEntity("e1", DOMAIN, "t1").withSince(now);
        assertEquals(now, q.since());
    }

    @Test
    void withOrder_returns_new_query() {
        var q = MemoryQuery.forEntity("e1", DOMAIN, "t1").withOrder(MemoryOrder.RELEVANCE);
        assertEquals(MemoryOrder.RELEVANCE, q.order());
    }

    // --- validation ---

    @Test
    void null_entityIds_throws() {
        assertThrows(NullPointerException.class,
            () -> new MemoryQuery(null, DOMAIN, "t1", null, null, 10, null, MemoryOrder.CHRONOLOGICAL));
    }

    @Test
    void empty_entityIds_throws() {
        assertThrows(IllegalArgumentException.class,
            () -> new MemoryQuery(List.of(), DOMAIN, "t1", null, null, 10, null, MemoryOrder.CHRONOLOGICAL));
    }

    @Test
    void too_many_entityIds_throws() {
        var ids = java.util.stream.IntStream.range(0, 26).mapToObj(i -> "e" + i).toList();
        assertThrows(IllegalArgumentException.class,
            () -> new MemoryQuery(ids, DOMAIN, "t1", null, null, 10, null, MemoryOrder.CHRONOLOGICAL));
    }

    @Test
    void exactly_max_entityIds_is_valid() {
        var ids = java.util.stream.IntStream.range(0, 25).mapToObj(i -> "e" + i).toList();
        assertDoesNotThrow(
            () -> new MemoryQuery(ids, DOMAIN, "t1", null, null, 10, null, MemoryOrder.CHRONOLOGICAL));
    }

    @Test
    void null_domain_throws() {
        assertThrows(NullPointerException.class,
            () -> new MemoryQuery(List.of("e1"), null, "t1", null, null, 10, null, MemoryOrder.CHRONOLOGICAL));
    }

    @Test
    void null_tenantId_throws() {
        assertThrows(NullPointerException.class,
            () -> new MemoryQuery(List.of("e1"), DOMAIN, null, null, null, 10, null, MemoryOrder.CHRONOLOGICAL));
    }

    @Test
    void null_order_throws() {
        assertThrows(NullPointerException.class,
            () -> new MemoryQuery(List.of("e1"), DOMAIN, "t1", null, null, 10, null, null));
    }

    @Test
    void zero_limit_throws() {
        assertThrows(IllegalArgumentException.class,
            () -> new MemoryQuery(List.of("e1"), DOMAIN, "t1", null, null, 0, null, MemoryOrder.CHRONOLOGICAL));
    }

    @Test
    void negative_limit_throws() {
        assertThrows(IllegalArgumentException.class,
            () -> new MemoryQuery(List.of("e1"), DOMAIN, "t1", null, null, -1, null, MemoryOrder.CHRONOLOGICAL));
    }

    @Test
    void entityIds_list_is_defensively_copied() {
        var mutable = new java.util.ArrayList<>(List.of("e1"));
        var q = new MemoryQuery(mutable, DOMAIN, "t1", null, null, 10, null, MemoryOrder.CHRONOLOGICAL);
        mutable.add("e2");
        assertEquals(1, q.entityIds().size());
    }

    @Test
    void chained_with_modifiers_compose_correctly() {
        var q = MemoryQuery.forEntity("e1", DOMAIN, "t1")
            .withCaseId("case-1")
            .withQuestion("any question")
            .withLimit(5)
            .withOrder(MemoryOrder.RELEVANCE);
        assertEquals("case-1", q.caseId());
        assertEquals("any question", q.question());
        assertEquals(5, q.limit());
        assertEquals(MemoryOrder.RELEVANCE, q.order());
        assertEquals(List.of("e1"), q.entityIds()); // required fields unchanged
    }
}
```

- [ ] **Step 2: Run to verify compile failure**

```bash
mvn --batch-mode test -pl platform-api -Dtest=MemoryQueryTest 2>&1 | head -20
```

Expected: COMPILATION ERROR — `MemoryQuery` constructor signature mismatch.

- [ ] **Step 3: Replace `MemoryQuery.java`**

```java
package io.casehub.platform.api.memory;

import java.time.Instant;
import java.util.List;
import java.util.Objects;

public record MemoryQuery(
    List<String> entityIds,
    MemoryDomain domain,
    String tenantId,
    String caseId,
    String question,
    int limit,
    Instant since,
    MemoryOrder order
) {
    /** Maximum entities per query. Covers realistic case party counts (2–15) with headroom. */
    public static final int MAX_ENTITY_IDS = 25;

    public MemoryQuery {
        Objects.requireNonNull(entityIds, "entityIds required");
        Objects.requireNonNull(domain,    "domain required");
        Objects.requireNonNull(tenantId,  "tenantId required");
        Objects.requireNonNull(order,     "order required");
        if (entityIds.isEmpty())
            throw new IllegalArgumentException("entityIds must not be empty");
        if (entityIds.size() > MAX_ENTITY_IDS)
            throw new IllegalArgumentException("entityIds must not exceed " + MAX_ENTITY_IDS + ", got: " + entityIds.size());
        if (limit < 1)
            throw new IllegalArgumentException("limit must be >= 1, got: " + limit);
        entityIds = List.copyOf(entityIds);
    }

    /**
     * Construct a query for a single entity.
     *
     * <p>Defaults: {@code limit=20}, {@code order=}{@link MemoryOrder#CHRONOLOGICAL}.
     * Use {@code with*} methods to override optional fields.
     */
    public static MemoryQuery forEntity(String entityId, MemoryDomain domain, String tenantId) {
        return new MemoryQuery(List.of(entityId), domain, tenantId, null, null, 20, null, MemoryOrder.CHRONOLOGICAL);
    }

    /**
     * Construct a query for multiple entities (max {@value #MAX_ENTITY_IDS}).
     *
     * <p>Defaults: {@code limit=20}, {@code order=}{@link MemoryOrder#CHRONOLOGICAL}.
     * {@code limit} applies to the combined result set, not per-entity.
     * Use {@code with*} methods to override optional fields.
     */
    public static MemoryQuery forEntities(List<String> entityIds, MemoryDomain domain, String tenantId) {
        return new MemoryQuery(entityIds, domain, tenantId, null, null, 20, null, MemoryOrder.CHRONOLOGICAL);
    }

    public MemoryQuery withCaseId(String caseId) {
        return new MemoryQuery(entityIds, domain, tenantId, caseId, question, limit, since, order);
    }

    public MemoryQuery withQuestion(String question) {
        return new MemoryQuery(entityIds, domain, tenantId, caseId, question, limit, since, order);
    }

    public MemoryQuery withLimit(int limit) {
        return new MemoryQuery(entityIds, domain, tenantId, caseId, question, limit, since, order);
    }

    public MemoryQuery withSince(Instant since) {
        return new MemoryQuery(entityIds, domain, tenantId, caseId, question, limit, since, order);
    }

    public MemoryQuery withOrder(MemoryOrder order) {
        return new MemoryQuery(entityIds, domain, tenantId, caseId, question, limit, since, order);
    }
}
```

- [ ] **Step 4: Run `MemoryQueryTest` only**

```bash
mvn --batch-mode test -pl platform-api -Dtest=MemoryQueryTest
```

Expected: BUILD SUCCESS, all tests pass.

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform-api/src/main/java/io/casehub/platform/api/memory/MemoryQuery.java platform-api/src/test/java/io/casehub/platform/api/memory/MemoryQueryTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(memory-api)!: MemoryQuery — entityIds List, MemoryOrder, forEntity/forEntities factory, with* fluent API (#48)"
```

---

### Task 5: `CaseMemoryStore` Javadoc

**Files:**
- Modify: `platform-api/src/main/java/io/casehub/platform/api/memory/CaseMemoryStore.java`

This task is documentation only — no test changes.

- [ ] **Step 1: Update Javadoc on `store()` in `CaseMemoryStore.java`**

Replace the existing `store()` Javadoc block:

```java
    /**
     * Store a memory about an entity. Returns the assigned memoryId.
     *
     * <p>Append-only at the SPI level. The no-op returns {@code ""}.
     * Adapters MUST call {@link MemoryPermissions#assertTenant} before delegating to the backend.
     *
     * <p><b>Emission pattern — under investigation:</b> consumer apps should evaluate which
     * approach fits their architecture and feed back via platform#48:
     * <ul>
     *   <li><b>Option A — Application-layer CDI observer:</b> application emits a domain event
     *       from its case outcome handler; an observer calls {@code store()}. Keeps messaging
     *       and memory decoupled at the cost of per-application boilerplate.</li>
     *   <li><b>Option B — Optional {@code memory-cdi/} platform module:</b> platform provides CDI
     *       infrastructure wiring domain events to {@code store()}. Reduces boilerplate at the
     *       cost of coupling domain event types to the platform.</li>
     *   <li><b>Option C — Platform-defined narrow event type:</b> platform defines a
     *       {@code MemoryStoreRequest} event type that applications emit; a thin platform CDI
     *       module listens and calls {@code store()}. Applications map domain events to
     *       {@code MemoryStoreRequest} (preserving separation); platform handles wire-up.</li>
     * </ul>
     *
     * <p><b>Text field guidance:</b> {@link MemoryInput#text()} must be human-readable natural
     * language when using semantic adapters (Mem0, Graphiti) — it is the field embedded for
     * vector search. Both accuracy and completeness matter; truncating or abbreviating degrades
     * retrieval quality. Use {@link MemoryInput#attributes()} for structured metadata.
     * See {@link MemoryAttributeKeys} for reserved cross-domain attribute keys.
     */
    String store(MemoryInput input);
```

- [ ] **Step 2: Build platform-api**

```bash
mvn --batch-mode test -pl platform-api
```

Expected: BUILD SUCCESS (Javadoc-only change).

- [ ] **Step 3: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform-api/src/main/java/io/casehub/platform/api/memory/CaseMemoryStore.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "docs(memory-api): emission pattern options and text field guidance on CaseMemoryStore.store() (#48)"
```

---

### Task 6: Update `InMemoryMemoryStore`

**Files:**
- Modify: `memory-inmem/src/main/java/io/casehub/platform/memory/inmem/InMemoryMemoryStore.java`
- Modify: `memory-inmem/src/test/java/io/casehub/platform/memory/inmem/InMemoryMemoryStoreTest.java`

- [ ] **Step 1: Replace `InMemoryMemoryStoreTest.java`**

Replace the entire test file. Helper factory methods change; new contract tests are added.

```java
package io.casehub.platform.memory.inmem;

import io.casehub.platform.api.identity.CurrentPrincipal;
import io.casehub.platform.api.memory.*;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.Set;
import static org.junit.jupiter.api.Assertions.*;

class InMemoryMemoryStoreTest {

    static final String TENANT       = "tenant-1";
    static final String OTHER_TENANT = "tenant-2";
    static final MemoryDomain DOMAIN       = new MemoryDomain("d");
    static final MemoryDomain OTHER_DOMAIN = new MemoryDomain("other");

    private final CurrentPrincipal principal = new CurrentPrincipal() {
        @Override public String actorId()           { return "actor"; }
        @Override public Set<String> groups()       { return Set.of(); }
        @Override public String tenancyId()         { return TENANT; }
        @Override public boolean isCrossTenantAdmin() { return false; }
    };

    private InMemoryMemoryStore sut;

    @BeforeEach
    void setUp() {
        sut = new InMemoryMemoryStore(principal);
    }

    private MemoryInput input(String text) {
        return new MemoryInput("entity-1", DOMAIN, TENANT, null, text, Map.of());
    }

    private MemoryInput input(String entityId, String text) {
        return new MemoryInput(entityId, DOMAIN, TENANT, null, text, Map.of());
    }

    private MemoryInput inputWithCase(String text, String caseId) {
        return new MemoryInput("entity-1", DOMAIN, TENANT, caseId, text, Map.of());
    }

    private MemoryQuery query() {
        return MemoryQuery.forEntity("entity-1", DOMAIN, TENANT);
    }

    private EraseRequest eraseRequest() {
        return new EraseRequest("entity-1", DOMAIN, TENANT, null);
    }

    // --- store ---

    @Test
    void store_assigns_non_empty_memory_id() {
        assertFalse(sut.store(input("hello")).isEmpty());
    }

    @Test
    void store_assigns_unique_ids() {
        assertNotEquals(sut.store(input("a")), sut.store(input("b")));
    }

    @Test
    void store_tenant_mismatch_throws() {
        var bad = new MemoryInput("entity-1", DOMAIN, OTHER_TENANT, null, "x", Map.of());
        assertThrows(SecurityException.class, () -> sut.store(bad));
    }

    // --- query single entity ---

    @Test
    void query_returns_stored_memories_in_desc_order() {
        sut.store(input("first"));
        sut.store(input("second"));
        var results = sut.query(query());
        assertEquals(2, results.size());
        assertEquals("second", results.get(0).text());
        assertEquals("first",  results.get(1).text());
    }

    @Test
    void query_empty_when_nothing_stored() {
        assertTrue(sut.query(query()).isEmpty());
    }

    @Test
    void query_does_not_leak_across_tenants() {
        sut.store(input("secret"));
        var crossQuery = MemoryQuery.forEntity("entity-1", DOMAIN, OTHER_TENANT);
        assertThrows(SecurityException.class, () -> sut.query(crossQuery));
    }

    @Test
    void query_does_not_leak_across_domains() {
        sut.store(input("finance fact"));
        var otherDomainQuery = MemoryQuery.forEntity("entity-1", OTHER_DOMAIN, TENANT);
        assertTrue(sut.query(otherDomainQuery).isEmpty());
    }

    @Test
    void query_with_caseId_filters_correctly() {
        sut.store(input("no case"));
        sut.store(inputWithCase("case A", "case-1"));
        sut.store(inputWithCase("case B", "case-2"));

        var results = sut.query(query().withCaseId("case-1"));
        assertEquals(1, results.size());
        assertEquals("case A", results.get(0).text());
    }

    @Test
    void query_null_caseId_returns_all() {
        sut.store(input("no case"));
        sut.store(inputWithCase("with case", "case-1"));
        assertEquals(2, sut.query(query()).size());
    }

    @Test
    void query_with_since_excludes_older_memories() throws InterruptedException {
        sut.store(input("old"));
        Instant barrier = Instant.now();
        Thread.sleep(5);
        sut.store(input("new"));

        var results = sut.query(query().withSince(barrier));
        assertEquals(1, results.size());
        assertEquals("new", results.get(0).text());
    }

    @Test
    void query_limit_is_honoured() {
        for (int i = 0; i < 5; i++) sut.store(input("item " + i));
        assertEquals(3, sut.query(query().withLimit(3)).size());
    }

    @Test
    void query_with_question_filters_by_text_containment() {
        sut.store(input("the cat sat on the mat"));
        sut.store(input("the dog barked loudly"));

        var results = sut.query(query().withQuestion("cat"));
        assertEquals(1, results.size());
        assertEquals("the cat sat on the mat", results.get(0).text());
    }

    @Test
    void query_null_question_returns_all() {
        sut.store(input("anything"));
        sut.store(input("something else"));
        assertEquals(2, sut.query(query()).size());
    }

    // --- multi-entity query ---

    @Test
    void multi_entity_query_returns_facts_from_all_entities() {
        sut.store(input("entity-1", "fact about e1"));
        sut.store(input("entity-2", "fact about e2"));

        var results = sut.query(
            MemoryQuery.forEntities(List.of("entity-1", "entity-2"), DOMAIN, TENANT));
        assertEquals(2, results.size());
        assertTrue(results.stream().anyMatch(m -> "fact about e1".equals(m.text())));
        assertTrue(results.stream().anyMatch(m -> "fact about e2".equals(m.text())));
    }

    @Test
    void multi_entity_query_limit_applies_to_combined_result_set() {
        for (int i = 0; i < 5; i++) sut.store(input("entity-1", "e1-" + i));
        for (int i = 0; i < 5; i++) sut.store(input("entity-2", "e2-" + i));

        var results = sut.query(
            MemoryQuery.forEntities(List.of("entity-1", "entity-2"), DOMAIN, TENANT)
                .withLimit(6));
        assertEquals(6, results.size());
    }

    @Test
    void multi_entity_result_carries_entityId_per_memory() {
        sut.store(input("entity-1", "fact about e1"));
        sut.store(input("entity-2", "fact about e2"));

        var results = sut.query(
            MemoryQuery.forEntities(List.of("entity-1", "entity-2"), DOMAIN, TENANT));
        assertTrue(results.stream().anyMatch(m -> "entity-1".equals(m.entityId())));
        assertTrue(results.stream().anyMatch(m -> "entity-2".equals(m.entityId())));
    }

    // --- MemoryOrder ---

    @Test
    void relevance_order_accepted_without_error() {
        sut.store(input("some text"));
        assertDoesNotThrow(() ->
            sut.query(query().withOrder(MemoryOrder.RELEVANCE).withQuestion("some")));
    }

    // --- MemoryAttributeKeys round-trip ---

    @Test
    void attribute_keys_round_trip_correctly() {
        var attrs = Map.of(
            MemoryAttributeKeys.ACTOR_ID, "actor-123",
            MemoryAttributeKeys.OUTCOME,  "DONE",
            MemoryAttributeKeys.CONFIDENCE, MemoryAttributeKeys.formatConfidence(0.87)
        );
        sut.store(new MemoryInput("entity-1", DOMAIN, TENANT, null, "reviewer completed task", attrs));

        var results = sut.query(query());
        assertEquals(1, results.size());
        var stored = results.get(0).attributes();
        assertEquals("actor-123", stored.get(MemoryAttributeKeys.ACTOR_ID));
        assertEquals("DONE", stored.get(MemoryAttributeKeys.OUTCOME));
        assertEquals(0.87, MemoryAttributeKeys.parseConfidence(stored.get(MemoryAttributeKeys.CONFIDENCE)), 0.0001);
    }

    // --- erase ---

    @Test
    void erase_removes_domain_scoped_memories() {
        sut.store(input("to erase"));
        sut.erase(eraseRequest());
        assertTrue(sut.query(query()).isEmpty());
    }

    @Test
    void erase_with_caseId_leaves_other_cases() {
        sut.store(input("no case"));
        sut.store(inputWithCase("case A", "case-1"));
        sut.store(inputWithCase("case B", "case-2"));

        sut.erase(new EraseRequest("entity-1", DOMAIN, TENANT, "case-1"));

        var remaining = sut.query(query());
        assertEquals(2, remaining.size());
        assertTrue(remaining.stream().anyMatch(m -> "no case".equals(m.text())));
        assertTrue(remaining.stream().anyMatch(m -> "case B".equals(m.text())));
    }

    @Test
    void erase_tenant_mismatch_throws() {
        assertThrows(SecurityException.class,
            () -> sut.erase(new EraseRequest("entity-1", DOMAIN, OTHER_TENANT, null)));
    }

    // --- eraseById ---

    @Test
    void eraseById_removes_specific_memory() {
        String id = sut.store(input("to delete"));
        sut.store(input("to keep"));
        sut.eraseById(id, TENANT);
        var remaining = sut.query(query());
        assertEquals(1, remaining.size());
        assertEquals("to keep", remaining.get(0).text());
    }

    @Test
    void eraseById_does_not_cross_tenant_boundary() {
        sut.store(input("protected"));
        assertThrows(SecurityException.class, () -> sut.eraseById("any-id", OTHER_TENANT));
        assertEquals(1, sut.query(query()).size());
    }

    // --- eraseEntity ---

    @Test
    void eraseEntity_removes_all_domains_for_entity() {
        sut.store(new MemoryInput("entity-1", DOMAIN,       TENANT, null, "finance", Map.of()));
        sut.store(new MemoryInput("entity-1", OTHER_DOMAIN, TENANT, null, "health",  Map.of()));

        sut.eraseEntity("entity-1", TENANT);

        assertTrue(sut.query(query()).isEmpty());
        assertTrue(sut.query(MemoryQuery.forEntity("entity-1", OTHER_DOMAIN, TENANT)).isEmpty());
    }

    @Test
    void eraseEntity_does_not_cross_tenant_boundary() {
        assertThrows(SecurityException.class, () -> sut.eraseEntity("entity-1", OTHER_TENANT));
    }

    @Test
    void eraseEntity_leaves_other_entities_intact() {
        sut.store(new MemoryInput("entity-1", DOMAIN, TENANT, null, "mine",  Map.of()));
        sut.store(new MemoryInput("entity-2", DOMAIN, TENANT, null, "other", Map.of()));

        sut.eraseEntity("entity-1", TENANT);

        var e2results = sut.query(MemoryQuery.forEntity("entity-2", DOMAIN, TENANT));
        assertEquals(1, e2results.size());
        assertEquals("other", e2results.get(0).text());
    }
}
```

- [ ] **Step 2: Run to verify compile failure**

```bash
mvn --batch-mode test -pl memory-inmem -Dtest=InMemoryMemoryStoreTest 2>&1 | head -20
```

Expected: COMPILATION ERROR — `InMemoryMemoryStore.query()` references old `entityId()` accessor.

- [ ] **Step 3: Update `InMemoryMemoryStore.java` `query()` method**

Replace the `query()` method only (store, erase, eraseById, eraseEntity are unchanged):

```java
    @Override
    public List<Memory> query(MemoryQuery query) {
        MemoryPermissions.assertTenant(query.tenantId(), principal);
        return query.entityIds().stream()
            .flatMap(entityId -> store.getOrDefault(
                    new BucketKey(query.tenantId(), entityId, query.domain()),
                    new CopyOnWriteArrayList<>()
                ).stream()
            )
            .filter(m -> query.caseId() == null || query.caseId().equals(m.caseId()))
            .filter(m -> query.since() == null || !m.createdAt().isBefore(query.since()))
            .filter(m -> query.question() == null
                || m.text().toLowerCase().contains(query.question().toLowerCase()))
            .sorted(Comparator.comparing(Memory::createdAt).reversed())
            .limit(query.limit())
            .toList();
        // MemoryOrder is ignored — in-mem always sorts chronologically (createdAt DESC).
    }
```

- [ ] **Step 4: Run all in-mem tests**

```bash
mvn --batch-mode test -pl memory-inmem
```

Expected: BUILD SUCCESS, all tests pass.

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add memory-inmem/src/main/java/io/casehub/platform/memory/inmem/InMemoryMemoryStore.java memory-inmem/src/test/java/io/casehub/platform/memory/inmem/InMemoryMemoryStoreTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(memory-inmem): multi-entity fan-out query; contract tests for #36 and #48"
```

---

### Task 7: Update `JpaMemoryStore`

**Files:**
- Modify: `memory-jpa/src/main/java/io/casehub/platform/memory/jpa/JpaMemoryStore.java`
- Modify: `memory-jpa/src/test/java/io/casehub/platform/memory/jpa/JpaMemoryStoreTest.java`

- [ ] **Step 1: Replace `JpaMemoryStoreTest.java`**

```java
package io.casehub.platform.memory.jpa;

import io.casehub.platform.api.memory.*;
import io.quarkus.test.TestTransaction;
import io.quarkus.test.junit.QuarkusTest;
import jakarta.inject.Inject;
import org.junit.jupiter.api.Test;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import static org.junit.jupiter.api.Assertions.*;

@QuarkusTest
class JpaMemoryStoreTest {

    static final String TENANT       = "tenant-1";    // matches casehub.tenancy.default-id
    static final String OTHER_TENANT = "tenant-2";
    static final MemoryDomain DOMAIN       = new MemoryDomain("d");
    static final MemoryDomain OTHER_DOMAIN = new MemoryDomain("other");

    @Inject JpaMemoryStore store;

    private MemoryInput input(String text) {
        return new MemoryInput("entity-1", DOMAIN, TENANT, null, text, Map.of());
    }

    private MemoryInput input(String entityId, String text) {
        return new MemoryInput(entityId, DOMAIN, TENANT, null, text, Map.of());
    }

    private MemoryInput inputWithCase(String text, String caseId) {
        return new MemoryInput("entity-1", DOMAIN, TENANT, caseId, text, Map.of());
    }

    private MemoryQuery query() {
        return MemoryQuery.forEntity("entity-1", DOMAIN, TENANT);
    }

    private EraseRequest eraseRequest() {
        return new EraseRequest("entity-1", DOMAIN, TENANT, null);
    }

    // --- store ---

    @Test @TestTransaction
    void store_assigns_non_empty_memory_id() {
        assertFalse(store.store(input("hello")).isEmpty());
    }

    @Test @TestTransaction
    void store_assigns_unique_ids() {
        assertNotEquals(store.store(input("a")), store.store(input("b")));
    }

    @Test
    void store_tenant_mismatch_throws() {
        var bad = new MemoryInput("entity-1", DOMAIN, OTHER_TENANT, null, "x", Map.of());
        assertThrows(SecurityException.class, () -> store.store(bad));
    }

    @Test @TestTransaction
    void store_does_not_leak_across_tenants() {
        store.store(input("secret"));
        var crossQuery = MemoryQuery.forEntity("entity-1", DOMAIN, OTHER_TENANT);
        assertThrows(SecurityException.class, () -> store.query(crossQuery));
    }

    @Test @TestTransaction
    void store_does_not_leak_across_domains() {
        store.store(input("finance fact"));
        assertTrue(store.query(MemoryQuery.forEntity("entity-1", OTHER_DOMAIN, TENANT)).isEmpty());
    }

    // --- query single entity ---

    @Test @TestTransaction
    void query_returns_stored_memories_in_desc_order() {
        store.store(input("first"));
        store.store(input("second"));
        var results = store.query(query());
        assertEquals(2, results.size());
        assertEquals("second", results.get(0).text());
        assertEquals("first",  results.get(1).text());
    }

    @Test @TestTransaction
    void query_empty_when_nothing_stored() {
        assertTrue(store.query(query()).isEmpty());
    }

    @Test @TestTransaction
    void query_with_caseId_filters_correctly() {
        store.store(input("no case"));
        store.store(inputWithCase("case A", "case-1"));
        store.store(inputWithCase("case B", "case-2"));

        var results = store.query(query().withCaseId("case-1"));
        assertEquals(1, results.size());
        assertEquals("case A", results.get(0).text());
    }

    @Test @TestTransaction
    void query_null_caseId_returns_all() {
        store.store(input("no case"));
        store.store(inputWithCase("with case", "case-1"));
        assertEquals(2, store.query(query()).size());
    }

    @Test @TestTransaction
    void query_with_since_excludes_older_memories() throws InterruptedException {
        store.store(input("old"));
        Instant barrier = Instant.now();
        Thread.sleep(5);
        store.store(input("new"));

        var results = store.query(query().withSince(barrier));
        assertEquals(1, results.size());
        assertEquals("new", results.get(0).text());
    }

    @Test @TestTransaction
    void query_limit_is_honoured() {
        for (int i = 0; i < 5; i++) store.store(input("item " + i));
        assertEquals(3, store.query(query().withLimit(3)).size());
    }

    // --- multi-entity query ---

    @Test @TestTransaction
    void multi_entity_query_returns_facts_from_all_entities() {
        store.store(input("entity-1", "fact about e1"));
        store.store(input("entity-2", "fact about e2"));

        var results = store.query(
            MemoryQuery.forEntities(List.of("entity-1", "entity-2"), DOMAIN, TENANT));
        assertEquals(2, results.size());
        assertTrue(results.stream().anyMatch(m -> "fact about e1".equals(m.text())));
        assertTrue(results.stream().anyMatch(m -> "fact about e2".equals(m.text())));
    }

    @Test @TestTransaction
    void multi_entity_query_limit_applies_to_combined_result_set() {
        for (int i = 0; i < 5; i++) store.store(input("entity-1", "e1-" + i));
        for (int i = 0; i < 5; i++) store.store(input("entity-2", "e2-" + i));

        var results = store.query(
            MemoryQuery.forEntities(List.of("entity-1", "entity-2"), DOMAIN, TENANT)
                .withLimit(6));
        assertEquals(6, results.size());
    }

    @Test @TestTransaction
    void multi_entity_result_carries_entityId_per_memory() {
        store.store(input("entity-1", "fact about e1"));
        store.store(input("entity-2", "fact about e2"));

        var results = store.query(
            MemoryQuery.forEntities(List.of("entity-1", "entity-2"), DOMAIN, TENANT));
        assertTrue(results.stream().anyMatch(m -> "entity-1".equals(m.entityId())));
        assertTrue(results.stream().anyMatch(m -> "entity-2".equals(m.entityId())));
    }

    // --- MemoryOrder ---

    @Test @TestTransaction
    void chronological_order_is_default() {
        store.store(input("first"));
        store.store(input("second"));
        var results = store.query(query());
        assertEquals("second", results.get(0).text());
        assertEquals("first",  results.get(1).text());
    }

    @Test @TestTransaction
    void relevance_order_without_question_falls_back_to_chronological() {
        store.store(input("first"));
        store.store(input("second"));
        // RELEVANCE with no question → chronological fallback
        var results = store.query(query().withOrder(MemoryOrder.RELEVANCE));
        assertEquals("second", results.get(0).text());
    }

    // --- MemoryAttributeKeys round-trip ---

    @Test @TestTransaction
    void attribute_keys_round_trip_correctly() {
        var attrs = Map.of(
            MemoryAttributeKeys.ACTOR_ID, "actor-123",
            MemoryAttributeKeys.OUTCOME,  "DONE",
            MemoryAttributeKeys.CONFIDENCE, MemoryAttributeKeys.formatConfidence(0.87)
        );
        store.store(new MemoryInput("entity-1", DOMAIN, TENANT, null, "reviewer completed task", attrs));

        var results = store.query(query());
        assertEquals(1, results.size());
        var stored = results.get(0).attributes();
        assertEquals("actor-123", stored.get(MemoryAttributeKeys.ACTOR_ID));
        assertEquals("DONE", stored.get(MemoryAttributeKeys.OUTCOME));
        assertEquals(0.87, MemoryAttributeKeys.parseConfidence(stored.get(MemoryAttributeKeys.CONFIDENCE)), 0.0001);
    }

    // --- erase ---

    @Test @TestTransaction
    void erase_domain_scoped_removes_matching_only() {
        store.store(input("to erase"));
        store.erase(eraseRequest());
        assertTrue(store.query(query()).isEmpty());
    }

    @Test @TestTransaction
    void erase_with_caseId_leaves_other_cases() {
        store.store(input("no case"));
        store.store(inputWithCase("case A", "case-1"));
        store.store(inputWithCase("case B", "case-2"));

        store.erase(new EraseRequest("entity-1", DOMAIN, TENANT, "case-1"));

        var remaining = store.query(query());
        assertEquals(2, remaining.size());
        assertTrue(remaining.stream().anyMatch(m -> "no case".equals(m.text())));
        assertTrue(remaining.stream().anyMatch(m -> "case B".equals(m.text())));
    }

    @Test
    void erase_tenant_mismatch_throws() {
        assertThrows(SecurityException.class,
            () -> store.erase(new EraseRequest("entity-1", DOMAIN, OTHER_TENANT, null)));
    }

    // --- eraseById ---

    @Test @TestTransaction
    void eraseById_removes_specific_memory() {
        String id = store.store(input("to delete"));
        store.store(input("to keep"));
        store.eraseById(id, TENANT);
        var remaining = store.query(query());
        assertEquals(1, remaining.size());
        assertEquals("to keep", remaining.get(0).text());
    }

    @Test
    void eraseById_does_not_cross_tenant_boundary() {
        assertThrows(SecurityException.class, () -> store.eraseById("any-id", OTHER_TENANT));
    }

    // --- eraseEntity ---

    @Test @TestTransaction
    void eraseEntity_removes_all_domains_for_entity() {
        store.store(new MemoryInput("entity-1", DOMAIN,       TENANT, null, "finance", Map.of()));
        store.store(new MemoryInput("entity-1", OTHER_DOMAIN, TENANT, null, "health",  Map.of()));

        store.eraseEntity("entity-1", TENANT);

        assertTrue(store.query(query()).isEmpty());
        assertTrue(store.query(MemoryQuery.forEntity("entity-1", OTHER_DOMAIN, TENANT)).isEmpty());
    }

    @Test @TestTransaction
    void eraseEntity_does_not_cross_tenant_boundary() {
        assertThrows(SecurityException.class, () -> store.eraseEntity("entity-1", OTHER_TENANT));
    }

    @Test @TestTransaction
    void eraseEntity_leaves_other_entities_intact() {
        store.store(new MemoryInput("entity-1", DOMAIN, TENANT, null, "mine",  Map.of()));
        store.store(new MemoryInput("entity-2", DOMAIN, TENANT, null, "other", Map.of()));

        store.eraseEntity("entity-1", TENANT);

        var e2results = store.query(MemoryQuery.forEntity("entity-2", DOMAIN, TENANT));
        assertEquals(1, e2results.size());
        assertEquals("other", e2results.get(0).text());
    }

    // --- security ---

    @Test
    void assertTenant_mismatch_throws_before_backend_call() {
        var bad = new MemoryInput("entity-1", DOMAIN, OTHER_TENANT, null, "x", Map.of());
        assertThrows(SecurityException.class, () -> store.store(bad));
    }
}
```

- [ ] **Step 2: Run to verify compile failure**

```bash
mvn --batch-mode test -pl memory-jpa -Dtest=JpaMemoryStoreTest 2>&1 | head -20
```

Expected: COMPILATION ERROR — `JpaMemoryStore` references old `entityId()` accessor.

- [ ] **Step 3: Update `JpaMemoryStore.java`**

Replace the `query()`, `queryChronological()`, and `queryFts()` methods. The `store()`, `erase()`, `eraseById()`, `eraseEntity()` methods are unchanged — they operate on single-entity `MemoryInput` and `EraseRequest`.

```java
    @Override
    @Transactional(TxType.REQUIRED)
    public List<Memory> query(MemoryQuery query) {
        MemoryPermissions.assertTenant(query.tenantId(), principal);

        if (config.fts().enabled()
                && query.order() == MemoryOrder.RELEVANCE
                && query.question() != null) {
            return queryFts(query);
        }
        return queryChronological(query);
    }

    private List<Memory> queryChronological(MemoryQuery query) {
        var jpql = new StringBuilder(
            "FROM MemoryEntry WHERE tenantId = :tenantId AND entityId IN (:entityIds) AND domain = :domain");
        if (query.caseId() != null) jpql.append(" AND caseId = :caseId");
        if (query.since()  != null) jpql.append(" AND createdAt >= :since");
        jpql.append(" ORDER BY createdAt DESC");

        var jq = em.createQuery(jpql.toString(), MemoryEntry.class)
            .setParameter("tenantId",  query.tenantId())
            .setParameter("entityIds", query.entityIds())
            .setParameter("domain",    query.domain().name())
            .setMaxResults(query.limit());

        if (query.caseId() != null) jq.setParameter("caseId", query.caseId());
        if (query.since()  != null) jq.setParameter("since",  query.since());

        return jq.getResultList().stream().map(this::toMemory).toList();
    }

    @SuppressWarnings("unchecked")
    private List<Memory> queryFts(MemoryQuery query) {
        var sql = new StringBuilder("""
            SELECT * FROM memory_entry
            WHERE tenant_id = :tenantId AND entity_id IN (:entityIds) AND domain = :domain
              AND to_tsvector(CAST(:lang AS regconfig), text)
                  @@ websearch_to_tsquery(CAST(:lang AS regconfig), :question)
            """);
        if (query.caseId() != null) sql.append("  AND case_id = :caseId\n");
        if (query.since()  != null) sql.append("  AND created_at >= :since\n");
        sql.append("""
            ORDER BY ts_rank(
                to_tsvector(CAST(:lang AS regconfig), text),
                websearch_to_tsquery(CAST(:lang AS regconfig), :question)
            ) DESC
            """);

        var nq = em.createNativeQuery(sql.toString(), MemoryEntry.class)
            .setParameter("tenantId",  query.tenantId())
            .setParameter("entityIds", query.entityIds())
            .setParameter("domain",    query.domain().name())
            .setParameter("lang",      config.fts().language())
            .setParameter("question",  query.question())
            .setMaxResults(query.limit());

        if (query.caseId() != null) nq.setParameter("caseId", query.caseId());
        if (query.since()  != null) nq.setParameter("since",  query.since());

        return ((List<MemoryEntry>) nq.getResultList()).stream().map(this::toMemory).toList();
    }
```

- [ ] **Step 4: Run all JPA tests**

```bash
mvn --batch-mode test -pl memory-jpa
```

Expected: BUILD SUCCESS, all tests pass (Testcontainers starts PostgreSQL automatically).

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add memory-jpa/src/main/java/io/casehub/platform/memory/jpa/JpaMemoryStore.java memory-jpa/src/test/java/io/casehub/platform/memory/jpa/JpaMemoryStoreTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(memory-jpa): multi-entity IN-clause query; MemoryOrder routing; contract tests for #36 and #48"
```

---

### Task 8: Full build, GitHub issues, push

**Files:** none (verification + admin)

- [ ] **Step 1: Full build across all modules**

```bash
mvn --batch-mode install -C /Users/mdproctor/claude/casehub/platform
```

Wait — use the correct invocation:

```bash
mvn -f /Users/mdproctor/claude/casehub/platform/pom.xml --batch-mode install
```

Expected: BUILD SUCCESS, all modules green.

- [ ] **Step 2: Commit the spec document to the project repo**

```bash
git -C /Users/mdproctor/claude/casehub/platform add docs/superpowers/specs/2026-05-30-casememorystore-consumer-feedback-design.md
git -C /Users/mdproctor/claude/casehub/platform commit -m "docs: CaseMemoryStore consumer feedback design spec (platform#48)"
```

- [ ] **Step 3: Create child issue off #48 for CDI emission**

```bash
gh issue create --repo casehubio/platform \
  --title "memory-cdi/: investigate CDI emission pattern for CaseMemoryStore — Options A, B, C" \
  --body "$(cat <<'EOF'
## Context

Spawned from platform#48 Gap 1.

Three emission patterns to evaluate across consumer apps (devtown, clinical, aml):

**Option A — Application-layer CDI observer**
Application emits a domain event from its case outcome handler; an observer calls \`store()\`. Keeps messaging and memory decoupled at the cost of per-application boilerplate.

**Option B — Optional \`memory-cdi/\` platform module**
Platform provides CDI infrastructure wiring domain events to \`store()\`. Reduces per-app boilerplate at the cost of coupling domain event types to the platform.

**Option C — Platform-defined narrow event type**
Platform defines a \`MemoryStoreRequest\` event type that applications emit; a thin platform CDI module listens and calls \`store()\`. Apps map domain events → \`MemoryStoreRequest\` (preserving separation); platform handles wire-up.

## Also in scope

\`JpaMemoryStore\` does not override \`storeAll()\`, so the default issues N individual \`@Transactional(REQUIRED)\` calls. Bulk emission paths will pay N DB round-trips. A batch-insert override for JPA should be part of whichever emission pattern lands.

## Next step

Each consumer app should implement and evaluate at least two options and report back. Platform will not commit to an approach until there is real feedback from at least two consumers.
EOF
)"
```

- [ ] **Step 4: Close #36 with a reference**

```bash
gh issue close 36 --repo casehubio/platform \
  --comment "Closed by the platform#48 changeset. Contract tests added in Tasks 6 and 7: multi-entity query, combined-limit, MemoryOrder acceptance, MemoryAttributeKeys round-trip, and blank text validation."
```

- [ ] **Step 5: Comment on #48 with summary**

```bash
gh issue comment 48 --repo casehubio/platform \
  --body "$(cat <<'EOF'
SPI changes shipped. All five gaps resolved:

- **Gap 1 (emission):** Three options documented in \`CaseMemoryStore.store()\` Javadoc. Child issue created for investigation.
- **Gap 2 (attribute keys):** \`MemoryAttributeKeys\` added — \`ACTOR_ID\`, \`ACTOR_ROLE\`, \`OUTCOME\`, \`CONFIDENCE\` with \`formatConfidence\`/\`parseConfidence\` helpers. Kebab-case convention established.
- **Gap 3 (multi-entity):** \`MemoryQuery.entityIds: List<String>\` (max 25), factory methods \`forEntity\`/\`forEntities\`, fluent \`with*\` API. Limit applies to combined result set.
- **Gap 4 (recency):** \`MemoryOrder\` enum (\`CHRONOLOGICAL\`/\`RELEVANCE\`). JPA FTS honours \`RELEVANCE\` via ts_rank; non-semantic adapters fall back silently.
- **Gap 5 (text Javadoc):** \`MemoryInput\` now rejects blank text. Javadoc documents NL requirement, embedding quality guidance, and attribute key convention.

Closes #36. All adapter work (#37, #33, #34, #40) should build against the updated SPI.
EOF
)"
```

- [ ] **Step 6: Push to both remotes**

```bash
git -C /Users/mdproctor/claude/casehub/platform push origin main
git -C /Users/mdproctor/claude/casehub/platform push mdproctor main
```

Expected: both pushes succeed, no conflicts (no one else is on main).
