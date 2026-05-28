# CaseMemoryStore Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the `CaseMemoryStore` SPI, value types, `MemoryPermissions` utility, no-op default, reactive interface, and `BlockingToReactiveBridge` to `casehub-platform`.

**Architecture:** Pure-Java SPI and value types live in `platform-api/` (zero dependencies). The reactive interface, no-op `@DefaultBean`, and `BlockingToReactiveBridge` live in `platform/` (Quarkus/Mutiny). No adapter code is written here — adapters live in the separate `casehub-memory` repo (tracked in deferred GitHub issues).

**Tech Stack:** Java 21 records, JUnit 5 (platform-api tests), Quarkus ARC + Smallrye Mutiny (platform tests via `@QuarkusTest`), Maven.

---

## File Map

**Create in `platform-api/src/main/java/io/casehub/platform/api/memory/`:**
- `MemoryDomain.java` — value record, strict-equality domain isolation tag
- `MemoryPermissions.java` — static tenant assertion utility
- `MemoryInput.java` — store input record (entityId, domain, tenantId, caseId, text, attributes)
- `Memory.java` — query output record (adds memoryId, createdAt)
- `MemoryQuery.java` — query parameters record
- `EraseRequest.java` — erasure parameters record
- `CaseMemoryStore.java` — blocking SPI interface

**Create in `platform-api/src/test/java/io/casehub/platform/api/memory/`:**
- `MemoryDomainTest.java` — compact constructor validation
- `MemoryPermissionsTest.java` — tenant assertion correctness
- `MemoryInputTest.java` — compact constructor null-checks and defensive copy
- `MemoryTest.java` — compact constructor defensive copy
- `MemoryQueryTest.java` — compact constructor null-checks and limit validation
- `EraseRequestTest.java` — compact constructor null-checks
- `CaseMemoryStoreSpiTest.java` — proves default methods are default; contract tests

**Modify `platform/pom.xml`:** add `quarkus-mutiny` dependency

**Create in `platform/src/main/java/io/casehub/platform/memory/`:**
- `ReactiveCaseMemoryStore.java` — reactive SPI interface (`Uni<>` return types)
- `NoOpCaseMemoryStore.java` — `@DefaultBean @ApplicationScoped` blocking no-op
- `BlockingToReactiveBridge.java` — `@DefaultBean @ApplicationScoped` reactive bridge

**Create in `platform/src/test/java/io/casehub/platform/memory/`:**
- `NoOpCaseMemoryStoreTest.java` — `@QuarkusTest` verifying no-op and bridge behaviour

**Modify (later tasks):**
- `casehub-parent/docs/PLATFORM.md` — capability ownership, repo map, build order, dep map

---

## Task 1: MemoryDomain record

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/memory/MemoryDomain.java`
- Create: `platform-api/src/test/java/io/casehub/platform/api/memory/MemoryDomainTest.java`

- [ ] **Step 1: Write the failing test**

```java
// platform-api/src/test/java/io/casehub/platform/api/memory/MemoryDomainTest.java
package io.casehub.platform.api.memory;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class MemoryDomainTest {

    @Test
    void name_is_returned() {
        assertEquals("health", new MemoryDomain("health").name());
    }

    @Test
    void null_name_throws() {
        assertThrows(NullPointerException.class, () -> new MemoryDomain(null));
    }

    @Test
    void blank_name_throws() {
        assertThrows(IllegalArgumentException.class, () -> new MemoryDomain("  "));
    }

    @Test
    void empty_name_throws() {
        assertThrows(IllegalArgumentException.class, () -> new MemoryDomain(""));
    }

    @Test
    void equality_by_name() {
        assertEquals(new MemoryDomain("health"), new MemoryDomain("health"));
        assertNotEquals(new MemoryDomain("health"), new MemoryDomain("finance"));
    }
}
```

- [ ] **Step 2: Run — expect compilation failure**

```bash
mvn --batch-mode test -pl platform-api -Dtest=MemoryDomainTest
```
Expected: `COMPILATION ERROR — cannot find symbol MemoryDomain`

- [ ] **Step 3: Create MemoryDomain**

```java
// platform-api/src/main/java/io/casehub/platform/api/memory/MemoryDomain.java
package io.casehub.platform.api.memory;

import java.util.Objects;

public record MemoryDomain(String name) {
    public MemoryDomain {
        Objects.requireNonNull(name, "domain name must not be null");
        if (name.isBlank()) throw new IllegalArgumentException("domain name must not be blank");
    }
}
```

- [ ] **Step 4: Run — expect green**

```bash
mvn --batch-mode test -pl platform-api -Dtest=MemoryDomainTest
```
Expected: `BUILD SUCCESS`, 5 tests passing

---

## Task 2: MemoryPermissions static utility

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/memory/MemoryPermissions.java`
- Create: `platform-api/src/test/java/io/casehub/platform/api/memory/MemoryPermissionsTest.java`

- [ ] **Step 1: Write the failing test**

```java
// platform-api/src/test/java/io/casehub/platform/api/memory/MemoryPermissionsTest.java
package io.casehub.platform.api.memory;

import io.casehub.platform.api.identity.CurrentPrincipal;
import org.junit.jupiter.api.Test;
import java.util.Set;
import static org.junit.jupiter.api.Assertions.*;

class MemoryPermissionsTest {

    private static CurrentPrincipal principal(String tenancyId) {
        return new CurrentPrincipal() {
            @Override public String actorId()  { return "actor"; }
            @Override public Set<String> groups() { return Set.of(); }
            @Override public String tenancyId()   { return tenancyId; }
            @Override public boolean isCrossTenantAdmin() { return false; }
        };
    }

    @Test
    void matching_tenant_does_not_throw() {
        assertDoesNotThrow(() ->
            MemoryPermissions.assertTenant("tenant-a", principal("tenant-a")));
    }

    @Test
    void mismatched_tenant_throws_security_exception() {
        SecurityException ex = assertThrows(SecurityException.class, () ->
            MemoryPermissions.assertTenant("tenant-b", principal("tenant-a")));
        assertTrue(ex.getMessage().contains("tenant-b"));
        assertTrue(ex.getMessage().contains("tenant-a"));
    }
}
```

- [ ] **Step 2: Run — expect compilation failure**

```bash
mvn --batch-mode test -pl platform-api -Dtest=MemoryPermissionsTest
```
Expected: `COMPILATION ERROR — cannot find symbol MemoryPermissions`

- [ ] **Step 3: Create MemoryPermissions**

```java
// platform-api/src/main/java/io/casehub/platform/api/memory/MemoryPermissions.java
package io.casehub.platform.api.memory;

import io.casehub.platform.api.identity.CurrentPrincipal;

public final class MemoryPermissions {
    private MemoryPermissions() {}

    public static void assertTenant(String tenantId, CurrentPrincipal principal) {
        if (!principal.tenancyId().equals(tenantId))
            throw new SecurityException(
                "Tenant ID mismatch: claimed=" + tenantId
                + ", authenticated=" + principal.tenancyId());
    }
}
```

- [ ] **Step 4: Run — expect green**

```bash
mvn --batch-mode test -pl platform-api -Dtest=MemoryPermissionsTest
```
Expected: `BUILD SUCCESS`, 2 tests passing

---

## Task 3: MemoryInput and Memory records

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/memory/MemoryInput.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/memory/Memory.java`
- Create: `platform-api/src/test/java/io/casehub/platform/api/memory/MemoryInputTest.java`
- Create: `platform-api/src/test/java/io/casehub/platform/api/memory/MemoryTest.java`

- [ ] **Step 1: Write the failing tests**

```java
// platform-api/src/test/java/io/casehub/platform/api/memory/MemoryInputTest.java
package io.casehub.platform.api.memory;

import org.junit.jupiter.api.Test;
import java.util.HashMap;
import java.util.Map;
import static org.junit.jupiter.api.Assertions.*;

class MemoryInputTest {

    static final MemoryDomain DOMAIN = new MemoryDomain("test");

    @Test
    void valid_input_constructs() {
        var input = new MemoryInput("e1", DOMAIN, "t1", null, "text", Map.of());
        assertEquals("e1", input.entityId());
        assertEquals(DOMAIN, input.domain());
        assertEquals("t1", input.tenantId());
        assertNull(input.caseId());
        assertEquals("text", input.text());
        assertTrue(input.attributes().isEmpty());
    }

    @Test
    void null_entityId_throws() {
        assertThrows(NullPointerException.class,
            () -> new MemoryInput(null, DOMAIN, "t1", null, "text", Map.of()));
    }

    @Test
    void null_domain_throws() {
        assertThrows(NullPointerException.class,
            () -> new MemoryInput("e1", null, "t1", null, "text", Map.of()));
    }

    @Test
    void null_tenantId_throws() {
        assertThrows(NullPointerException.class,
            () -> new MemoryInput("e1", DOMAIN, null, null, "text", Map.of()));
    }

    @Test
    void null_text_throws() {
        assertThrows(NullPointerException.class,
            () -> new MemoryInput("e1", DOMAIN, "t1", null, null, Map.of()));
    }

    @Test
    void attributes_are_defensively_copied() {
        var mutable = new HashMap<String, String>();
        mutable.put("k", "v");
        var input = new MemoryInput("e1", DOMAIN, "t1", null, "text", mutable);
        mutable.put("k2", "v2");
        assertFalse(input.attributes().containsKey("k2"));
    }

    @Test
    void attributes_map_is_unmodifiable() {
        var input = new MemoryInput("e1", DOMAIN, "t1", null, "text", Map.of("k", "v"));
        assertThrows(UnsupportedOperationException.class,
            () -> input.attributes().put("x", "y"));
    }

    @Test
    void caseId_is_nullable() {
        assertDoesNotThrow(() -> new MemoryInput("e1", DOMAIN, "t1", "case-1", "text", Map.of()));
    }
}
```

```java
// platform-api/src/test/java/io/casehub/platform/api/memory/MemoryTest.java
package io.casehub.platform.api.memory;

import org.junit.jupiter.api.Test;
import java.time.Instant;
import java.util.HashMap;
import java.util.Map;
import static org.junit.jupiter.api.Assertions.*;

class MemoryTest {

    static final MemoryDomain DOMAIN = new MemoryDomain("test");

    @Test
    void valid_memory_constructs() {
        var now = Instant.now();
        var m = new Memory("mem-1", "e1", DOMAIN, "t1", null, "text", Map.of(), now);
        assertEquals("mem-1", m.memoryId());
        assertEquals("e1", m.entityId());
        assertEquals(now, m.createdAt());
    }

    @Test
    void attributes_are_defensively_copied() {
        var mutable = new HashMap<String, String>();
        mutable.put("k", "v");
        var m = new Memory("id", "e1", DOMAIN, "t1", null, "text", mutable, Instant.now());
        mutable.put("k2", "v2");
        assertFalse(m.attributes().containsKey("k2"));
    }

    @Test
    void attributes_map_is_unmodifiable() {
        var m = new Memory("id", "e1", DOMAIN, "t1", null, "text",
            Map.of("k", "v"), Instant.now());
        assertThrows(UnsupportedOperationException.class,
            () -> m.attributes().put("x", "y"));
    }
}
```

- [ ] **Step 2: Run — expect compilation failure**

```bash
mvn --batch-mode test -pl platform-api -Dtest="MemoryInputTest,MemoryTest"
```
Expected: `COMPILATION ERROR — cannot find symbol MemoryInput, Memory`

- [ ] **Step 3: Create MemoryInput and Memory**

```java
// platform-api/src/main/java/io/casehub/platform/api/memory/MemoryInput.java
package io.casehub.platform.api.memory;

import java.util.Map;
import java.util.Objects;

public record MemoryInput(
    String entityId,
    MemoryDomain domain,
    String tenantId,
    String caseId,
    String text,
    Map<String, String> attributes
) {
    public MemoryInput {
        Objects.requireNonNull(entityId,  "entityId required");
        Objects.requireNonNull(domain,    "domain required");
        Objects.requireNonNull(tenantId,  "tenantId required");
        Objects.requireNonNull(text,      "text required");
        attributes = Map.copyOf(attributes);
    }
}
```

```java
// platform-api/src/main/java/io/casehub/platform/api/memory/Memory.java
package io.casehub.platform.api.memory;

import java.time.Instant;
import java.util.Map;

public record Memory(
    String memoryId,
    String entityId,
    MemoryDomain domain,
    String tenantId,
    String caseId,
    String text,
    Map<String, String> attributes,
    Instant createdAt
) {
    public Memory {
        attributes = Map.copyOf(attributes);
    }
}
```

- [ ] **Step 4: Run — expect green**

```bash
mvn --batch-mode test -pl platform-api -Dtest="MemoryInputTest,MemoryTest"
```
Expected: `BUILD SUCCESS`, 10 tests passing

---

## Task 4: MemoryQuery and EraseRequest records

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/memory/MemoryQuery.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/memory/EraseRequest.java`
- Create: `platform-api/src/test/java/io/casehub/platform/api/memory/MemoryQueryTest.java`
- Create: `platform-api/src/test/java/io/casehub/platform/api/memory/EraseRequestTest.java`

- [ ] **Step 1: Write the failing tests**

```java
// platform-api/src/test/java/io/casehub/platform/api/memory/MemoryQueryTest.java
package io.casehub.platform.api.memory;

import org.junit.jupiter.api.Test;
import java.time.Instant;
import static org.junit.jupiter.api.Assertions.*;

class MemoryQueryTest {

    static final MemoryDomain DOMAIN = new MemoryDomain("test");

    @Test
    void valid_query_constructs() {
        var q = new MemoryQuery("e1", DOMAIN, "t1", null, null, 10, null);
        assertEquals("e1", q.entityId());
        assertEquals(10, q.limit());
        assertNull(q.question());
        assertNull(q.since());
    }

    @Test
    void null_entityId_throws() {
        assertThrows(NullPointerException.class,
            () -> new MemoryQuery(null, DOMAIN, "t1", null, null, 10, null));
    }

    @Test
    void null_domain_throws() {
        assertThrows(NullPointerException.class,
            () -> new MemoryQuery("e1", null, "t1", null, null, 10, null));
    }

    @Test
    void null_tenantId_throws() {
        assertThrows(NullPointerException.class,
            () -> new MemoryQuery("e1", DOMAIN, null, null, null, 10, null));
    }

    @Test
    void zero_limit_throws() {
        assertThrows(IllegalArgumentException.class,
            () -> new MemoryQuery("e1", DOMAIN, "t1", null, null, 0, null));
    }

    @Test
    void negative_limit_throws() {
        assertThrows(IllegalArgumentException.class,
            () -> new MemoryQuery("e1", DOMAIN, "t1", null, null, -1, null));
    }

    @Test
    void limit_of_one_is_valid() {
        assertDoesNotThrow(() -> new MemoryQuery("e1", DOMAIN, "t1", null, null, 1, null));
    }

    @Test
    void caseId_and_question_are_nullable() {
        assertDoesNotThrow(() ->
            new MemoryQuery("e1", DOMAIN, "t1", "case-1", "what do we know?", 5, Instant.now()));
    }
}
```

```java
// platform-api/src/test/java/io/casehub/platform/api/memory/EraseRequestTest.java
package io.casehub.platform.api.memory;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class EraseRequestTest {

    static final MemoryDomain DOMAIN = new MemoryDomain("test");

    @Test
    void valid_request_constructs() {
        var r = new EraseRequest("e1", DOMAIN, null, "t1");
        assertEquals("e1", r.entityId());
        assertEquals(DOMAIN, r.domain());
        assertNull(r.caseId());
        assertEquals("t1", r.tenantId());
    }

    @Test
    void null_entityId_throws() {
        assertThrows(NullPointerException.class,
            () -> new EraseRequest(null, DOMAIN, null, "t1"));
    }

    @Test
    void null_tenantId_throws() {
        assertThrows(NullPointerException.class,
            () -> new EraseRequest("e1", DOMAIN, null, null));
    }

    @Test
    void domain_and_caseId_are_nullable() {
        // null domain = GDPR full-wipe across all domains
        assertDoesNotThrow(() -> new EraseRequest("e1", null, null, "t1"));
        assertDoesNotThrow(() -> new EraseRequest("e1", DOMAIN, "case-1", "t1"));
    }
}
```

- [ ] **Step 2: Run — expect compilation failure**

```bash
mvn --batch-mode test -pl platform-api -Dtest="MemoryQueryTest,EraseRequestTest"
```
Expected: `COMPILATION ERROR — cannot find symbol MemoryQuery, EraseRequest`

- [ ] **Step 3: Create MemoryQuery and EraseRequest**

```java
// platform-api/src/main/java/io/casehub/platform/api/memory/MemoryQuery.java
package io.casehub.platform.api.memory;

import java.time.Instant;
import java.util.Objects;

public record MemoryQuery(
    String entityId,
    MemoryDomain domain,
    String tenantId,
    String caseId,
    String question,
    int limit,
    Instant since
) {
    public MemoryQuery {
        Objects.requireNonNull(entityId, "entityId required");
        Objects.requireNonNull(domain,   "domain required");
        Objects.requireNonNull(tenantId, "tenantId required");
        if (limit < 1) throw new IllegalArgumentException("limit must be >= 1");
    }
}
```

```java
// platform-api/src/main/java/io/casehub/platform/api/memory/EraseRequest.java
package io.casehub.platform.api.memory;

import java.util.Objects;

public record EraseRequest(
    String entityId,
    MemoryDomain domain,
    String caseId,
    String tenantId
) {
    public EraseRequest {
        Objects.requireNonNull(entityId, "entityId required");
        Objects.requireNonNull(tenantId, "tenantId required");
    }
}
```

- [ ] **Step 4: Run — expect green**

```bash
mvn --batch-mode test -pl platform-api -Dtest="MemoryQueryTest,EraseRequestTest"
```
Expected: `BUILD SUCCESS`, 12 tests passing

---

## Task 5: CaseMemoryStore interface and SPI contract tests

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/memory/CaseMemoryStore.java`
- Create: `platform-api/src/test/java/io/casehub/platform/api/memory/CaseMemoryStoreSpiTest.java`

- [ ] **Step 1: Write the failing SPI contract tests**

```java
// platform-api/src/test/java/io/casehub/platform/api/memory/CaseMemoryStoreSpiTest.java
package io.casehub.platform.api.memory;

import io.casehub.platform.api.identity.CurrentPrincipal;
import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.Map;
import java.util.Set;
import static org.junit.jupiter.api.Assertions.*;

class CaseMemoryStoreSpiTest {

    // Anonymous impl omitting all default methods.
    // If any omitted method were abstract, this would fail to compile — that is the RED state.
    final CaseMemoryStore sut = new CaseMemoryStore() {
        @Override public String store(MemoryInput i) { return "mem-1"; }
        @Override public List<Memory> query(MemoryQuery q) { return List.of(); }
        @Override public void erase(EraseRequest r) {}
    };

    static final MemoryDomain DOMAIN = new MemoryDomain("d");

    @Test
    void storeAll_delegates_to_store() {
        var a = new MemoryInput("e1", DOMAIN, "t1", null, "a", Map.of());
        var b = new MemoryInput("e1", DOMAIN, "t1", null, "b", Map.of());
        assertEquals(List.of("mem-1", "mem-1"), sut.storeAll(List.of(a, b)));
    }

    @Test
    void eraseById_default_throws() {
        assertThrows(UnsupportedOperationException.class,
            () -> sut.eraseById("mem-1", "tenant-1"));
    }

    // --- assertTenant via interface default (proves delegation to MemoryPermissions) ---

    @Test
    void assertTenant_throws_on_mismatch() {
        assertThrows(SecurityException.class,
            () -> sut.assertTenant("wrong", principal("real")));
    }

    @Test
    void assertTenant_passes_on_match() {
        assertDoesNotThrow(() -> sut.assertTenant("real", principal("real")));
    }

    // --- MemoryPermissions static utility directly (callable by native reactive adapters) ---

    @Test
    void memoryPermissions_throws_on_mismatch() {
        assertThrows(SecurityException.class,
            () -> MemoryPermissions.assertTenant("wrong", principal("real")));
    }

    @Test
    void memoryPermissions_passes_on_match() {
        assertDoesNotThrow(() -> MemoryPermissions.assertTenant("real", principal("real")));
    }

    private static CurrentPrincipal principal(String tenancyId) {
        return new CurrentPrincipal() {
            @Override public String actorId() { return "actor"; }
            @Override public Set<String> groups() { return Set.of(); }
            @Override public String tenancyId() { return tenancyId; }
            @Override public boolean isCrossTenantAdmin() { return false; }
        };
    }
}
```

- [ ] **Step 2: Run — expect compilation failure**

```bash
mvn --batch-mode test -pl platform-api -Dtest=CaseMemoryStoreSpiTest
```
Expected: `COMPILATION ERROR — cannot find symbol CaseMemoryStore`

- [ ] **Step 3: Create CaseMemoryStore interface**

```java
// platform-api/src/main/java/io/casehub/platform/api/memory/CaseMemoryStore.java
package io.casehub.platform.api.memory;

import io.casehub.platform.api.identity.CurrentPrincipal;
import java.util.List;

public interface CaseMemoryStore {

    /**
     * Store a memory about an entity. Returns the assigned memoryId.
     *
     * <p>Append-only at the SPI level. The no-op returns {@code ""}.
     * Adapters MUST call {@link MemoryPermissions#assertTenant} before delegating to the backend.
     */
    String store(MemoryInput input);

    /**
     * Recall memories relevant to a query context.
     *
     * <p>Domain isolation is strict equality — only memories tagged with {@code query.domain()}
     * are returned. Non-semantic adapters ignore {@code question} and return
     * entity+domain+tenant+caseId-scoped results ordered by {@code createdAt} descending.
     * Returns an empty list when no adapter is installed.
     */
    List<Memory> query(MemoryQuery query);

    /**
     * Erase memories matching the request.
     *
     * <p>GDPR Art.17: {@code request.domain() == null} erases across ALL domains for the entity
     * within the tenant. Adapters MUST perform hard deletion.
     * Adapters MUST call {@link MemoryPermissions#assertTenant} before delegating to the backend.
     */
    void erase(EraseRequest request);

    /**
     * Erase a specific memory by its assigned memoryId.
     *
     * <p>The default throws {@link UnsupportedOperationException} — a silent no-op on a
     * GDPR-adjacent erasure would give a false success signal. {@code NoOpCaseMemoryStore}
     * overrides with a true no-op (nothing stored). Real adapters override with actual deletion.
     * Adapters MUST call {@link MemoryPermissions#assertTenant} before delegating to the backend.
     */
    default void eraseById(String memoryId, String tenantId) {
        throw new UnsupportedOperationException("eraseById not supported by this adapter");
    }

    /**
     * Convenience bulk store. Returns assigned memoryIds in input order.
     * Adapters may override for efficiency.
     */
    default List<String> storeAll(List<MemoryInput> inputs) {
        return inputs.stream().map(this::store).toList();
    }

    /**
     * Security guard. Delegates to {@link MemoryPermissions#assertTenant}.
     * Adapters MUST call {@link MemoryPermissions#assertTenant} directly — not this method —
     * to ensure reachability from native reactive adapter implementations.
     *
     * @throws SecurityException if tenantId does not match principal.tenancyId()
     */
    default void assertTenant(String tenantId, CurrentPrincipal principal) {
        MemoryPermissions.assertTenant(tenantId, principal);
    }
}
```

- [ ] **Step 4: Run — expect green**

```bash
mvn --batch-mode test -pl platform-api -Dtest=CaseMemoryStoreSpiTest
```
Expected: `BUILD SUCCESS`, 6 tests passing

- [ ] **Step 5: Run full platform-api test suite**

```bash
mvn --batch-mode test -pl platform-api
```
Expected: `BUILD SUCCESS`, all tests passing (including existing PathTest, PreferenceKeyTest, etc.)

- [ ] **Step 6: Commit value types and SPI**

```bash
git -C /Users/mdproctor/claude/casehub/platform add \
  platform-api/src/main/java/io/casehub/platform/api/memory/ \
  platform-api/src/test/java/io/casehub/platform/api/memory/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#27): CaseMemoryStore SPI — value types, MemoryPermissions, blocking interface"
```

---

## Task 6: Add quarkus-mutiny and ReactiveCaseMemoryStore interface

**Files:**
- Modify: `platform/pom.xml`
- Create: `platform/src/main/java/io/casehub/platform/memory/ReactiveCaseMemoryStore.java`

- [ ] **Step 1: Add quarkus-mutiny to platform/pom.xml**

Open `platform/pom.xml`. After the existing `quarkus-arc` dependency, add:

```xml
<dependency>
    <groupId>io.quarkus</groupId>
    <artifactId>quarkus-mutiny</artifactId>
</dependency>
```

The version is managed by `quarkus-bom` already imported in the parent POM — no `<version>` needed.

- [ ] **Step 2: Create ReactiveCaseMemoryStore**

```java
// platform/src/main/java/io/casehub/platform/memory/ReactiveCaseMemoryStore.java
package io.casehub.platform.memory;

import io.casehub.platform.api.memory.EraseRequest;
import io.casehub.platform.api.memory.Memory;
import io.casehub.platform.api.memory.MemoryInput;
import io.casehub.platform.api.memory.MemoryQuery;
import io.smallrye.mutiny.Uni;
import java.util.List;

public interface ReactiveCaseMemoryStore {

    Uni<String> store(MemoryInput input);

    Uni<List<Memory>> query(MemoryQuery query);

    Uni<Void> erase(EraseRequest request);

    /**
     * Erase a specific memory by its assigned memoryId.
     *
     * <p>Default returns a failed Uni matching the blocking interface's
     * {@link io.casehub.platform.api.memory.CaseMemoryStore#eraseById} default contract.
     */
    default Uni<Void> eraseById(String memoryId, String tenantId) {
        return Uni.createFrom().failure(
            new UnsupportedOperationException("eraseById not supported by this adapter"));
    }
}
```

- [ ] **Step 3: Verify compilation**

```bash
mvn --batch-mode compile -pl platform
```
Expected: `BUILD SUCCESS`

---

## Task 7: NoOpCaseMemoryStore and BlockingToReactiveBridge

**Files:**
- Create: `platform/src/main/java/io/casehub/platform/memory/NoOpCaseMemoryStore.java`
- Create: `platform/src/main/java/io/casehub/platform/memory/BlockingToReactiveBridge.java`

- [ ] **Step 1: Write the failing @QuarkusTest**

```java
// platform/src/test/java/io/casehub/platform/memory/NoOpCaseMemoryStoreTest.java
package io.casehub.platform.memory;

import io.casehub.platform.api.memory.*;
import io.quarkus.test.junit.QuarkusTest;
import jakarta.inject.Inject;
import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.Map;
import static org.junit.jupiter.api.Assertions.*;

@QuarkusTest
class NoOpCaseMemoryStoreTest {

    @Inject CaseMemoryStore store;
    @Inject ReactiveCaseMemoryStore reactiveStore;

    static final MemoryDomain DOMAIN  = new MemoryDomain("test");
    static final MemoryInput  SAMPLE  = new MemoryInput(
        "entity-1", DOMAIN, "tenant-1", null, "sample", Map.of());
    static final MemoryInput  SAMPLE_WITH_CASE = new MemoryInput(
        "entity-1", DOMAIN, "tenant-1", "case-99", "sample", Map.of());
    static final MemoryQuery  QUERY   = new MemoryQuery(
        "entity-1", DOMAIN, "tenant-1", null, null, 10, null);
    static final EraseRequest ERASE_SCOPED = new EraseRequest(
        "entity-1", DOMAIN, null, "tenant-1");
    static final EraseRequest ERASE_ALL_DOMAINS = new EraseRequest(
        "entity-1", null, null, "tenant-1");

    // --- blocking no-op ---
    @Test void store_returns_empty_id()      { assertTrue(store.store(SAMPLE).isEmpty()); }
    @Test void query_returns_empty()         { assertTrue(store.query(QUERY).isEmpty()); }
    @Test void erase_scoped_does_not_throw() { assertDoesNotThrow(() -> store.erase(ERASE_SCOPED)); }
    @Test void erase_all_domains_does_not_throw() { assertDoesNotThrow(() -> store.erase(ERASE_ALL_DOMAINS)); }
    @Test void eraseById_does_not_throw()   { assertDoesNotThrow(() -> store.eraseById("mem-1", "tenant-1")); }
    @Test void storeAll_returns_empty_ids() {
        assertEquals(List.of("", ""), store.storeAll(List.of(SAMPLE, SAMPLE_WITH_CASE)));
    }

    // --- reactive bridge (delegates to blocking no-op) ---
    @Test void bridge_store_returns_empty_id() {
        assertTrue(reactiveStore.store(SAMPLE).await().indefinitely().isEmpty());
    }
    @Test void bridge_query_returns_empty() {
        assertTrue(reactiveStore.query(QUERY).await().indefinitely().isEmpty());
    }
    @Test void bridge_erase_does_not_throw() {
        assertDoesNotThrow(() -> reactiveStore.erase(ERASE_SCOPED).await().indefinitely());
    }
    @Test void bridge_eraseById_does_not_throw() {
        assertDoesNotThrow(() -> reactiveStore.eraseById("mem-1", "tenant-1").await().indefinitely());
    }
}
```

- [ ] **Step 2: Run — expect compilation failure**

```bash
mvn --batch-mode test -pl platform -Dtest=NoOpCaseMemoryStoreTest
```
Expected: `COMPILATION ERROR — cannot find symbol NoOpCaseMemoryStore` (or CDI injection failure at runtime)

- [ ] **Step 3: Create NoOpCaseMemoryStore**

```java
// platform/src/main/java/io/casehub/platform/memory/NoOpCaseMemoryStore.java
package io.casehub.platform.memory;

import io.casehub.platform.api.memory.*;
import io.quarkus.arc.DefaultBean;
import jakarta.enterprise.context.ApplicationScoped;
import java.util.List;

@DefaultBean
@ApplicationScoped
public class NoOpCaseMemoryStore implements CaseMemoryStore {

    @Override
    public String store(MemoryInput input) { return ""; }

    @Override
    public List<Memory> query(MemoryQuery query) { return List.of(); }

    @Override
    public void erase(EraseRequest request) {}

    @Override
    public void eraseById(String memoryId, String tenantId) {}
}
```

- [ ] **Step 4: Create BlockingToReactiveBridge**

```java
// platform/src/main/java/io/casehub/platform/memory/BlockingToReactiveBridge.java
package io.casehub.platform.memory;

import io.casehub.platform.api.memory.*;
import io.quarkus.arc.DefaultBean;
import io.smallrye.common.annotation.Blocking;
import io.smallrye.mutiny.Uni;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import java.util.List;

@DefaultBean
@ApplicationScoped
public class BlockingToReactiveBridge implements ReactiveCaseMemoryStore {

    @Inject
    CaseMemoryStore delegate;

    @Override @Blocking
    public Uni<String> store(MemoryInput input) {
        return Uni.createFrom().item(() -> delegate.store(input));
    }

    @Override @Blocking
    public Uni<List<Memory>> query(MemoryQuery query) {
        return Uni.createFrom().item(() -> delegate.query(query));
    }

    @Override @Blocking
    public Uni<Void> erase(EraseRequest request) {
        return Uni.createFrom().voidItem().invoke(() -> delegate.erase(request));
    }

    @Override @Blocking
    public Uni<Void> eraseById(String memoryId, String tenantId) {
        return Uni.createFrom().voidItem()
            .invoke(() -> delegate.eraseById(memoryId, tenantId));
    }
}
```

- [ ] **Step 5: Run — expect green**

```bash
mvn --batch-mode test -pl platform -Dtest=NoOpCaseMemoryStoreTest
```
Expected: `BUILD SUCCESS`, 11 tests passing

- [ ] **Step 6: Run full platform test suite**

```bash
mvn --batch-mode test -pl platform
```
Expected: `BUILD SUCCESS`, all tests passing (including existing MockBeansTest, PathParamConverterTest, etc.)

- [ ] **Step 7: Commit no-op and bridge**

```bash
git -C /Users/mdproctor/claude/casehub/platform add \
  platform/pom.xml \
  platform/src/main/java/io/casehub/platform/memory/ \
  platform/src/test/java/io/casehub/platform/memory/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#27): ReactiveCaseMemoryStore interface, NoOpCaseMemoryStore @DefaultBean, BlockingToReactiveBridge"
```

---

## Task 8: Full build verification

- [ ] **Step 1: Run the complete multi-module build**

```bash
mvn --batch-mode install -C /Users/mdproctor/claude/casehub/platform
```

Run from `platform/` root (not a submodule). Expected: `BUILD SUCCESS`, all modules green.

If the build fails: read the error output carefully. Common causes:
- Missing import in a new file
- Jandex not discovering a new CDI bean — the `platform/` module already has the Jandex plugin; no action needed unless a new module is added
- `@Blocking` not found — verify `quarkus-mutiny` was added to `platform/pom.xml`

---

## Task 9: Create deferred GitHub issues

All seven items from the spec's deferred table must be filed before this branch is merged.

- [ ] **Step 1: Create casehub-memory repo tracking issue**

```bash
gh issue create --repo casehubio/platform \
  --title "Create casehub-memory repo — SPI adapter repository for CaseMemoryStore backends" \
  --body "$(cat <<'EOF'
## What

Create the `casehub-memory` repo (casehubio/memory) with parent POM, CI pipeline, and initial module structure for CaseMemoryStore adapter implementations.

## Why

The `CaseMemoryStore` SPI and no-op now live in `casehub-platform`. Adapters are independently useful (any Quarkus multi-agent system needs agent memory) and operationally substantial enough to warrant their own repo — the same decision that gave `casehub-work` and `casehub-ledger` their own repos.

## Module structure

\`\`\`
casehub-memory/
  pom.xml          ← parent
  memory-memori/   ← Tier 1 adapter (Memori REST client)
  memory-mem0/     ← Tier 2 adapter (Mem0 REST client)
  memory-graphiti/ ← Tier 3 adapter (Graphiti REST client)
\`\`\`

## Blocks

- Memori adapter
- Mem0 adapter
- Graphiti adapter
- Adapter contract tests
EOF
)"
```

- [ ] **Step 2: Create Memori adapter issue**

```bash
gh issue create --repo casehubio/platform \
  --title "Memori adapter (memory-memori/) — Tier 1 CaseMemoryStore backend" \
  --body "$(cat <<'EOF'
Implement the Memori REST client adapter for `CaseMemoryStore` in `casehub-memory/memory-memori/`.

**CDI annotation:** `@ApplicationScoped` (Tier 1 — beats `@DefaultBean` no-op automatically)

**Adapter responsibilities:**
- Call `MemoryPermissions.assertTenant()` at the top of store(), query(), erase(), eraseById()
- Enforce domain isolation (strict equality on domain tag)
- Map `MemoryInput`/`MemoryQuery`/`EraseRequest` to Memori's REST API
- Assign `memoryId` and `createdAt` on store, populate `Memory` records on query

**Infrastructure:** Postgres only — zero extra infra for deployments already using JPA backend.

**Blocked by:** casehub-memory repo creation
EOF
)"
```

- [ ] **Step 3: Create Mem0 adapter issue**

```bash
gh issue create --repo casehubio/platform \
  --title "Mem0 adapter (memory-mem0/) — Tier 2 CaseMemoryStore backend" \
  --body "$(cat <<'EOF'
Implement the Mem0 REST client adapter for `CaseMemoryStore` in `casehub-memory/memory-mem0/`.

**CDI annotation:** `@Alternative @Priority(1)` (Tier 2 — beats Memori when co-deployed)

**Infrastructure:** Docker + pgvector. Best for vector retrieval on unstructured queries.

**Blocked by:** casehub-memory repo creation
EOF
)"
```

- [ ] **Step 4: Create Graphiti adapter issue**

```bash
gh issue create --repo casehubio/platform \
  --title "Graphiti adapter (memory-graphiti/) — Tier 3 CaseMemoryStore backend" \
  --body "$(cat <<'EOF'
Implement the Graphiti REST client adapter for `CaseMemoryStore` in `casehub-memory/memory-graphiti/`.

**CDI annotation:** `@Alternative @Priority(2)` on `CaseMemoryStore`, or optionally `@Alternative @Priority(2)` on `ReactiveCaseMemoryStore` directly (bypasses the BlockingToReactiveBridge for true async graph traversal).

**Infrastructure:** Neo4j, FalkorDB, or Kuzu. Best for temporal reasoning and regulated domains.

**Note:** If implementing `ReactiveCaseMemoryStore` directly, call `MemoryPermissions.assertTenant()` (static utility) — not `CaseMemoryStore.assertTenant()` which is unreachable from a reactive-only impl.

**Blocked by:** casehub-memory repo creation
EOF
)"
```

- [ ] **Step 5: Create CDI observer emission issue**

```bash
gh issue create --repo casehubio/engine \
  --title "CaseMemoryStore — CDI observer emission from case completion events" \
  --body "$(cat <<'EOF'
## What

Add a CDI observer in casehub-engine that automatically captures structured memories from case lifecycle events and stores them via `CaseMemoryStore`.

## Why

Consumers should not need to call `CaseMemoryStore.store()` explicitly for system-observed facts. Case completions, decisions, and entity observations should populate CaseMemoryStore automatically.

## Depends on

`casehub-platform-api` `CaseMemoryStore` SPI (casehubio/platform#27, now merged).

## Approach options

1. CDI observer on existing case lifecycle events — automatic, decoupled
2. Explicit API calls from consumer code — more control, more boilerplate
3. OpenClaw MCP tool — agent-driven, appropriate for agent-derived insights

Likely: a combination. This issue covers option 1 (CDI observer for system-observed facts).
EOF
)"
```

- [ ] **Step 6: Create reactive storeAll issue**

```bash
gh issue create --repo casehubio/platform \
  --title "ReactiveCaseMemoryStore — add reactive storeAll() default method" \
  --body "Add \`Uni<List<String>> storeAll(List<MemoryInput>)\` as a default method on \`ReactiveCaseMemoryStore\` if an adapter needs bulk reactive store. Currently omitted — chaining Uni<Void> in a loop adds complexity for marginal benefit. Add when a concrete adapter demonstrates the need."
```

- [ ] **Step 7: Create adapter contract tests issue**

```bash
gh issue create --repo casehubio/platform \
  --title "casehub-memory: adapter contract tests — verify assertTenant() called on all mutating paths" \
  --body "$(cat <<'EOF'
Each adapter in casehub-memory must include a test that verifies `MemoryPermissions.assertTenant()` is called on every mutating path (store, query, erase, eraseById). This cannot be enforced at compile time.

**Pattern:** mock `CurrentPrincipal` to return a known tenancyId, pass a mismatched tenantId to each method, assert `SecurityException` is thrown before any backend call is made.

**Applies to:** memory-memori, memory-mem0, memory-graphiti (for any path it implements).
EOF
)"
```

---

## Task 10: PLATFORM.md updates

**Files:**
- Modify: `/Users/mdproctor/claude/casehub/parent/docs/PLATFORM.md`

- [ ] **Step 1: Add CaseMemoryStore to Capability Ownership table**

Find the table row for `Group membership lookup` and insert after it:

```markdown
| Agent memory (queryable, permission-aware, persistent) | `casehub-platform-api` (SPI + types) / `casehub-memory` (adapters) | `CaseMemoryStore` SPI + `MemoryPermissions`; `NoOpCaseMemoryStore @DefaultBean` in `casehub-platform`; adapters in `casehub-memory` repo. `BlockingToReactiveBridge @DefaultBean` provides `ReactiveCaseMemoryStore` for all blocking adapters; native async adapters may override. |
```

- [ ] **Step 2: Add casehub-memory to Repository Map**

In the Repository Map table, after the `casehub-platform` row, add:

```markdown
| `casehub-memory` | [casehubio/memory](https://github.com/casehubio/memory) | CaseMemoryStore adapter implementations — Memori (Tier 1, SQL-native), Mem0 (Tier 2, vector+BM25), Graphiti (Tier 3, temporal knowledge graph). SPI lives in casehub-platform-api. | Foundation |
```

- [ ] **Step 3: Add casehub-memory to Build / Dependency Order**

After the `casehub-platform` line in the build order block, add:

```
  casehub-memory            (depends on casehub-platform-api; adapters only — no casehub-platform runtime dep)
```

- [ ] **Step 4: Add casehub-memory to Cross-Repo Dependency Map**

After the existing `casehub-platform-api` rows, add:

```markdown
| `casehub-platform-api` | `casehub-memory` | all modules | `CaseMemoryStore` SPI + value types |
```

- [ ] **Step 5: Commit PLATFORM.md update**

```bash
git -C /Users/mdproctor/claude/casehub/parent add docs/PLATFORM.md
git -C /Users/mdproctor/claude/casehub/parent commit -m "docs(platform#27): add CaseMemoryStore to capability table, casehub-memory to repo map and build order"
```

---

## Task 11: Final commit — full build + code review gate

- [ ] **Step 1: Full build**

```bash
mvn --batch-mode install
```
Run from `/Users/mdproctor/claude/casehub/platform`. Expected: `BUILD SUCCESS`.

- [ ] **Step 2: Invoke code review before committing**

Invoke `superpowers:requesting-code-review` on the staged changes. Any finding Minor or above that cannot be fixed this session must be filed as a GitHub issue before sign-off.

- [ ] **Step 3: Invoke implementation-doc-sync**

Invoke `implementation-doc-sync` to check for any documentation gaps revealed by implementation.

- [ ] **Step 4: Push branch**

```bash
git -C /Users/mdproctor/claude/casehub/platform push -u mdproctor issue-27-case-memory-store
```

---

## Self-Review Checklist

**Spec coverage:**
- [x] `MemoryDomain` with compact constructor validation — Task 1
- [x] `MemoryPermissions` static utility — Task 2
- [x] `MemoryInput` with null-checks and defensive copy — Task 3
- [x] `Memory` with defensive copy — Task 3
- [x] `MemoryQuery` with null-checks and limit validation — Task 4
- [x] `EraseRequest` with null-checks — Task 4
- [x] `CaseMemoryStore` blocking SPI with all default methods — Task 5
- [x] `CaseMemoryStoreSpiTest` — anonymous impl, proves defaults — Task 5
- [x] `ReactiveCaseMemoryStore` reactive interface — Task 6
- [x] `NoOpCaseMemoryStore @DefaultBean` — Task 7
- [x] `BlockingToReactiveBridge @DefaultBean` with `@Blocking` — Task 7
- [x] `NoOpCaseMemoryStoreTest @QuarkusTest` — Task 7
- [x] All 7 deferred GitHub issues — Task 9
- [x] PLATFORM.md capability table, repo map, build order, dep map — Task 10

**Type consistency check:**
- `MemoryInput` is the store input everywhere (Tasks 3, 5, 7)
- `Memory` is the query output everywhere (Tasks 3, 5, 7)
- `MemoryQuery` has 7 fields: entityId, domain, tenantId, caseId, question, limit, since — consistent across Tasks 4 and 7
- `EraseRequest` has 4 fields: entityId, domain, caseId, tenantId — consistent across Tasks 4 and 7
- `store()` returns `String` everywhere (Tasks 5, 7)
- `storeAll()` returns `List<String>` everywhere (Tasks 5, 7)
