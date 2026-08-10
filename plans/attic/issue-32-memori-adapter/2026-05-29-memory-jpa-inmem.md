# memory-jpa/ + memory-inmem/ Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement two Tier 1 `CaseMemoryStore` adapters — `memory-jpa/` (JPA/PostgreSQL, durable) and `memory-inmem/` (ConcurrentHashMap, volatile) — preceded by SPI breaking changes to `EraseRequest` and `CaseMemoryStore`.

**Architecture:** SPI changes ship first (Tasks 1–4): `EraseRequest.domain` becomes required, `CaseMemoryStore.eraseEntity()` added as default-throw. Then `memory-inmem/` (pure Java, no CDI container needed for tests). Then `memory-jpa/` (Panache + native SQL + Flyway V1000).

**Tech Stack:** Java 21, Quarkus 3.32.2, Hibernate ORM Panache, Flyway, H2 (tests), JUnit 5, Jackson ObjectMapper

**Spec:** `docs/superpowers/specs/2026-05-29-memory-jpa-inmem-design.md`

**Working directory for all commands:** `/Users/mdproctor/claude/casehub/platform`

---

## File Map

**Modified:**
- `platform-api/src/main/java/io/casehub/platform/api/memory/EraseRequest.java`
- `platform-api/src/main/java/io/casehub/platform/api/memory/CaseMemoryStore.java`
- `platform-api/src/test/java/io/casehub/platform/api/memory/EraseRequestTest.java`
- `platform-api/src/test/java/io/casehub/platform/api/memory/CaseMemoryStoreSpiTest.java`
- `platform/src/main/java/io/casehub/platform/memory/NoOpCaseMemoryStore.java`
- `platform/src/main/java/io/casehub/platform/memory/ReactiveCaseMemoryStore.java`
- `platform/src/main/java/io/casehub/platform/memory/BlockingToReactiveBridge.java`
- `platform/src/test/java/io/casehub/platform/memory/NoOpCaseMemoryStoreTest.java`
- `pom.xml` (root — add two modules)

**Created:**
- `memory-inmem/pom.xml`
- `memory-inmem/src/main/java/io/casehub/platform/memory/inmem/BucketKey.java`
- `memory-inmem/src/main/java/io/casehub/platform/memory/inmem/InMemoryMemoryStore.java`
- `memory-inmem/src/test/java/io/casehub/platform/memory/inmem/InMemoryMemoryStoreTest.java`
- `memory-jpa/pom.xml`
- `memory-jpa/src/main/java/io/casehub/platform/memory/jpa/MemoryJpaConfig.java`
- `memory-jpa/src/main/java/io/casehub/platform/memory/jpa/MemoryEntry.java`
- `memory-jpa/src/main/java/io/casehub/platform/memory/jpa/JpaMemoryStore.java`
- `memory-jpa/src/main/resources/db/memory/migration/V1000__memory_entry.sql`
- `memory-jpa/src/test/java/io/casehub/platform/memory/jpa/JpaMemoryStoreTest.java`
- `memory-jpa/src/test/resources/application.properties`

---

## Task 1: EraseRequest — make domain required

**Files:**
- Modify: `platform-api/src/main/java/io/casehub/platform/api/memory/EraseRequest.java`
- Modify: `platform-api/src/test/java/io/casehub/platform/api/memory/EraseRequestTest.java`

- [ ] **Step 1: Write the failing test**

Add to `EraseRequestTest.java` — the `null_domain_throws` test that currently passes (null is allowed), and update `domain_and_caseId_are_nullable` to remove the null-domain assertion:

```java
package io.casehub.platform.api.memory;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class EraseRequestTest {

    static final MemoryDomain DOMAIN = new MemoryDomain("test");

    @Test
    void valid_request_constructs() {
        var r = new EraseRequest("e1", DOMAIN, "t1", null);
        assertEquals("e1", r.entityId());
        assertEquals(DOMAIN, r.domain());
        assertEquals("t1", r.tenantId());
        assertNull(r.caseId());
    }

    @Test
    void null_entityId_throws() {
        assertThrows(NullPointerException.class,
            () -> new EraseRequest(null, DOMAIN, "t1", null));
    }

    @Test
    void null_tenantId_throws() {
        assertThrows(NullPointerException.class,
            () -> new EraseRequest("e1", DOMAIN, null, null));
    }

    @Test
    void null_domain_throws() {
        assertThrows(NullPointerException.class,
            () -> new EraseRequest("e1", null, "t1", null));
    }

    @Test
    void caseId_is_nullable() {
        assertDoesNotThrow(() -> new EraseRequest("e1", DOMAIN, "t1", null));
        assertDoesNotThrow(() -> new EraseRequest("e1", DOMAIN, "t1", "case-1"));
    }
}
```

- [ ] **Step 2: Run — expect FAIL**

```bash
mvn --batch-mode -pl platform-api -am test -Dtest=EraseRequestTest
```

Expected: `null_domain_throws` FAILS — `new EraseRequest("e1", null, "t1", null)` does NOT currently throw.

- [ ] **Step 3: Update EraseRequest — make domain required**

```java
package io.casehub.platform.api.memory;

import java.util.Objects;

public record EraseRequest(
    String entityId,
    MemoryDomain domain,
    String tenantId,
    String caseId
) {
    public EraseRequest {
        Objects.requireNonNull(entityId, "entityId required");
        Objects.requireNonNull(domain,   "domain required");
        Objects.requireNonNull(tenantId, "tenantId required");
    }
}
```

- [ ] **Step 4: Run — expect PASS**

```bash
mvn --batch-mode -pl platform-api -am test -Dtest=EraseRequestTest
```

Expected: all 5 tests pass.

---

## Task 2: CaseMemoryStore — add eraseEntity() default-throw

**Files:**
- Modify: `platform-api/src/main/java/io/casehub/platform/api/memory/CaseMemoryStore.java`
- Modify: `platform-api/src/test/java/io/casehub/platform/api/memory/CaseMemoryStoreSpiTest.java`

- [ ] **Step 1: Write the failing test**

Add `eraseEntity_default_throws` to `CaseMemoryStoreSpiTest.java`. The anonymous impl omits `eraseEntity()` — the test currently fails to compile (method doesn't exist yet):

```java
package io.casehub.platform.api.memory;

import io.casehub.platform.api.identity.CurrentPrincipal;
import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.Map;
import java.util.Set;
import static org.junit.jupiter.api.Assertions.*;

class CaseMemoryStoreSpiTest {

    // Omits all default methods — compiler error on any non-default = proves abstract.
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

    @Test
    void eraseEntity_default_throws() {
        assertThrows(UnsupportedOperationException.class,
            () -> sut.eraseEntity("entity-1", "tenant-1"));
    }

    @Test
    void assertTenant_throws_on_mismatch() {
        assertThrows(SecurityException.class,
            () -> sut.assertTenant("wrong", principal("real")));
    }

    @Test
    void assertTenant_passes_on_match() {
        assertDoesNotThrow(() -> sut.assertTenant("real", principal("real")));
    }

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

- [ ] **Step 2: Run — expect FAIL (compile error)**

```bash
mvn --batch-mode -pl platform-api -am test -Dtest=CaseMemoryStoreSpiTest
```

Expected: compilation fails — `sut.eraseEntity(...)` method does not exist on `CaseMemoryStore`.

- [ ] **Step 3: Add eraseEntity() default-throw to CaseMemoryStore**

Full updated `CaseMemoryStore.java` — add `eraseEntity()` after `eraseById()`, and update `erase()` Javadoc to remove the null-domain mention:

```java
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
     * Erase memories matching the request. Domain is required — use {@link #eraseEntity}
     * for GDPR Art.17 cross-domain full-entity wipe.
     *
     * <p>Adapters MUST perform hard deletion.
     * Adapters MUST call {@link MemoryPermissions#assertTenant} before delegating to the backend.
     */
    void erase(EraseRequest request);

    /**
     * GDPR Art.17 full-entity wipe across ALL domains for this entity within the tenant.
     *
     * <p>Adapters MUST perform hard deletion across every domain.
     * Adapters MUST call {@link MemoryPermissions#assertTenant} before delegating to the backend.
     *
     * <p>Default throws {@link UnsupportedOperationException} — consistent with
     * {@link #eraseById}. {@code NoOpCaseMemoryStore} overrides with a true no-op.
     * Real adapters must override with actual cross-domain deletion.
     */
    default void eraseEntity(String entityId, String tenantId) {
        throw new UnsupportedOperationException("eraseEntity not supported by this adapter");
    }

    /**
     * Erase a specific memory by its assigned memoryId.
     *
     * <p>Default throws {@link UnsupportedOperationException} — a silent no-op on a
     * GDPR-adjacent erasure would give a false success signal. {@code NoOpCaseMemoryStore}
     * overrides with a true no-op. Real adapters override with actual deletion.
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
     *
     * @throws SecurityException if tenantId does not match principal.tenancyId()
     */
    default void assertTenant(String tenantId, CurrentPrincipal principal) {
        MemoryPermissions.assertTenant(tenantId, principal);
    }
}
```

- [ ] **Step 4: Run — expect PASS**

```bash
mvn --batch-mode -pl platform-api -am test
```

Expected: all 7 tests pass in `CaseMemoryStoreSpiTest`, all 5 pass in `EraseRequestTest`.

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add \
  platform-api/src/main/java/io/casehub/platform/api/memory/EraseRequest.java \
  platform-api/src/main/java/io/casehub/platform/api/memory/CaseMemoryStore.java \
  platform-api/src/test/java/io/casehub/platform/api/memory/EraseRequestTest.java \
  platform-api/src/test/java/io/casehub/platform/api/memory/CaseMemoryStoreSpiTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#32): SPI — EraseRequest domain required, CaseMemoryStore eraseEntity() default-throw"
```

---

## Task 3: Platform module — NoOp, Reactive, Bridge (add eraseEntity)

**Files:**
- Modify: `platform/src/main/java/io/casehub/platform/memory/NoOpCaseMemoryStore.java`
- Modify: `platform/src/main/java/io/casehub/platform/memory/ReactiveCaseMemoryStore.java`
- Modify: `platform/src/main/java/io/casehub/platform/memory/BlockingToReactiveBridge.java`
- Modify: `platform/src/test/java/io/casehub/platform/memory/NoOpCaseMemoryStoreTest.java`

- [ ] **Step 1: Write the failing tests**

Replace `NoOpCaseMemoryStoreTest.java` fully. Remove `ERASE_ALL_DOMAINS` and its test, add `eraseEntity` tests. The test will fail to compile because `NoOpCaseMemoryStore` doesn't yet implement `eraseEntity()` (it uses the default-throw):

```java
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
        "entity-1", DOMAIN, "tenant-1", null);

    // --- blocking no-op ---
    @Test void store_returns_empty_id()      { assertTrue(store.store(SAMPLE).isEmpty()); }
    @Test void query_returns_empty()         { assertTrue(store.query(QUERY).isEmpty()); }
    @Test void erase_scoped_does_not_throw() { assertDoesNotThrow(() -> store.erase(ERASE_SCOPED)); }
    @Test void eraseById_does_not_throw()    { assertDoesNotThrow(() -> store.eraseById("mem-1", "tenant-1")); }
    @Test void eraseEntity_does_not_throw()  { assertDoesNotThrow(() -> store.eraseEntity("entity-1", "tenant-1")); }
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
    @Test void bridge_eraseEntity_does_not_throw() {
        assertDoesNotThrow(() -> reactiveStore.eraseEntity("entity-1", "tenant-1").await().indefinitely());
    }
}
```

- [ ] **Step 2: Run — expect FAIL**

```bash
mvn --batch-mode -pl platform -am test -Dtest=NoOpCaseMemoryStoreTest
```

Expected: `eraseEntity_does_not_throw` and `bridge_eraseEntity_does_not_throw` FAIL — `eraseEntity()` default-throws `UnsupportedOperationException` and the bridge doesn't yet exist.

- [ ] **Step 3: Update NoOpCaseMemoryStore — add eraseEntity() no-op**

```java
package io.casehub.platform.memory;

import io.casehub.platform.api.memory.CaseMemoryStore;
import io.casehub.platform.api.memory.EraseRequest;
import io.casehub.platform.api.memory.Memory;
import io.casehub.platform.api.memory.MemoryInput;
import io.casehub.platform.api.memory.MemoryQuery;
import io.quarkus.arc.DefaultBean;
import jakarta.enterprise.context.ApplicationScoped;
import java.util.List;

@DefaultBean
@ApplicationScoped
public class NoOpCaseMemoryStore implements CaseMemoryStore {

    @Override public String store(MemoryInput input) { return ""; }
    @Override public List<Memory> query(MemoryQuery query) { return List.of(); }
    @Override public void erase(EraseRequest request) {}
    @Override public void eraseById(String memoryId, String tenantId) {}
    @Override public void eraseEntity(String entityId, String tenantId) {}
}
```

- [ ] **Step 4: Update ReactiveCaseMemoryStore — add eraseEntity() default-fail**

```java
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
     * Reactive mirror of {@link io.casehub.platform.api.memory.CaseMemoryStore#eraseEntity}.
     * Default returns a failed Uni — consistent with the blocking default-throw contract.
     */
    default Uni<Void> eraseEntity(String entityId, String tenantId) {
        return Uni.createFrom().failure(
            new UnsupportedOperationException("eraseEntity not supported by this adapter"));
    }

    /**
     * Erase a specific memory by its assigned memoryId.
     *
     * <p>Default returns a failed Uni matching the blocking interface's contract.
     */
    default Uni<Void> eraseById(String memoryId, String tenantId) {
        return Uni.createFrom().failure(
            new UnsupportedOperationException("eraseById not supported by this adapter"));
    }
}
```

- [ ] **Step 5: Update BlockingToReactiveBridge — add eraseEntity() wrapper**

```java
package io.casehub.platform.memory;

import io.casehub.platform.api.memory.CaseMemoryStore;
import io.casehub.platform.api.memory.EraseRequest;
import io.casehub.platform.api.memory.Memory;
import io.casehub.platform.api.memory.MemoryInput;
import io.casehub.platform.api.memory.MemoryQuery;
import io.quarkus.arc.DefaultBean;
import io.smallrye.mutiny.Uni;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import java.util.List;

@DefaultBean
@ApplicationScoped
public class BlockingToReactiveBridge implements ReactiveCaseMemoryStore {

    @Inject CaseMemoryStore delegate;

    @Override
    public Uni<String> store(MemoryInput input) {
        return Uni.createFrom().item(() -> delegate.store(input));
    }

    @Override
    public Uni<List<Memory>> query(MemoryQuery query) {
        return Uni.createFrom().item(() -> delegate.query(query));
    }

    @Override
    public Uni<Void> erase(EraseRequest request) {
        return Uni.createFrom().voidItem().invoke(() -> delegate.erase(request));
    }

    @Override
    public Uni<Void> eraseById(String memoryId, String tenantId) {
        return Uni.createFrom().voidItem()
            .invoke(() -> delegate.eraseById(memoryId, tenantId));
    }

    @Override
    public Uni<Void> eraseEntity(String entityId, String tenantId) {
        return Uni.createFrom().voidItem()
            .invoke(() -> delegate.eraseEntity(entityId, tenantId));
    }
}
```

- [ ] **Step 6: Run — expect PASS**

```bash
mvn --batch-mode -pl platform -am test
```

Expected: all 11 tests in `NoOpCaseMemoryStoreTest` pass. Any other platform tests also pass.

- [ ] **Step 7: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add \
  platform/src/main/java/io/casehub/platform/memory/NoOpCaseMemoryStore.java \
  platform/src/main/java/io/casehub/platform/memory/ReactiveCaseMemoryStore.java \
  platform/src/main/java/io/casehub/platform/memory/BlockingToReactiveBridge.java \
  platform/src/test/java/io/casehub/platform/memory/NoOpCaseMemoryStoreTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#32): platform — NoOp/Reactive/Bridge eraseEntity() overrides"
```

---

## Task 4: Add modules to root pom

**Files:**
- Modify: `pom.xml`

- [ ] **Step 1: Add memory-inmem and memory-jpa to root pom**

In `pom.xml`, find the `<modules>` section and add:

```xml
<modules>
    <module>platform-api</module>
    <module>platform</module>
    <module>testing</module>
    <module>config</module>
    <module>oidc</module>
    <module>expression</module>
    <module>persistence-jpa</module>
    <module>persistence-mongodb</module>
    <module>memory-inmem</module>
    <module>memory-jpa</module>
</modules>
```

- [ ] **Step 2: Verify root pom parses**

```bash
mvn --batch-mode -pl . validate
```

Expected: `BUILD SUCCESS` — the root pom is valid. The new modules don't exist yet so this only validates pom syntax.

---

## Task 5: memory-inmem/ — scaffold, BucketKey, InMemoryMemoryStore

**Files:**
- Create: `memory-inmem/pom.xml`
- Create: `memory-inmem/src/main/java/io/casehub/platform/memory/inmem/BucketKey.java`
- Create: `memory-inmem/src/main/java/io/casehub/platform/memory/inmem/InMemoryMemoryStore.java`
- Create: `memory-inmem/src/test/java/io/casehub/platform/memory/inmem/InMemoryMemoryStoreTest.java`

- [ ] **Step 1: Create memory-inmem/pom.xml**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>

    <parent>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-platform-parent</artifactId>
        <version>0.2-SNAPSHOT</version>
    </parent>

    <artifactId>casehub-platform-memory-inmem</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform Memory In-Memory</name>
    <description>Volatile in-memory CaseMemoryStore adapter. @Alternative @Priority(1) — displaces JPA
        and no-op when on the classpath. Add as test scope for @QuarkusTest isolation; compile scope
        for ephemeral installs. Do not combine with memory-jpa in production scope.</description>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-api</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-arc</artifactId>
        </dependency>

        <!-- Test -->
        <dependency>
            <groupId>org.junit.jupiter</groupId>
            <artifactId>junit-jupiter</artifactId>
            <scope>test</scope>
        </dependency>
    </dependencies>

    <build>
        <plugins>
            <plugin>
                <groupId>io.smallrye</groupId>
                <artifactId>jandex-maven-plugin</artifactId>
                <version>${jandex-maven-plugin.version}</version>
                <executions>
                    <execution>
                        <id>make-index</id>
                        <goals><goal>jandex</goal></goals>
                    </execution>
                </executions>
            </plugin>
        </plugins>
    </build>
</project>
```

- [ ] **Step 2: Create BucketKey record**

```java
package io.casehub.platform.memory.inmem;

import io.casehub.platform.api.memory.MemoryDomain;

record BucketKey(String tenantId, String entityId, MemoryDomain domain) {}
```

- [ ] **Step 3: Write the first failing test**

Create `InMemoryMemoryStoreTest.java` — just the `store_assigns_non_empty_memory_id` test. This fails because `InMemoryMemoryStore` doesn't exist yet:

```java
package io.casehub.platform.memory.inmem;

import io.casehub.platform.api.identity.CurrentPrincipal;
import io.casehub.platform.api.memory.*;
import org.junit.jupiter.api.Test;
import java.util.Map;
import java.util.Set;
import static org.junit.jupiter.api.Assertions.*;

class InMemoryMemoryStoreTest {

    static final String TENANT       = "tenant-1";
    static final String OTHER_TENANT = "tenant-2";
    static final MemoryDomain DOMAIN       = new MemoryDomain("d");
    static final MemoryDomain OTHER_DOMAIN = new MemoryDomain("other");

    private final CurrentPrincipal principal = new CurrentPrincipal() {
        @Override public String actorId() { return "actor"; }
        @Override public Set<String> groups() { return Set.of(); }
        @Override public String tenancyId() { return TENANT; }
        @Override public boolean isCrossTenantAdmin() { return false; }
    };

    private final InMemoryMemoryStore sut = new InMemoryMemoryStore(principal);

    private MemoryInput input(String text) {
        return new MemoryInput("entity-1", DOMAIN, TENANT, null, text, Map.of());
    }

    private MemoryQuery query() {
        return new MemoryQuery("entity-1", DOMAIN, TENANT, null, null, 10, null);
    }

    @Test
    void store_assigns_non_empty_memory_id() {
        String id = sut.store(input("hello"));
        assertFalse(id.isEmpty());
    }
}
```

- [ ] **Step 4: Run — expect compile FAIL**

```bash
mvn --batch-mode -pl memory-inmem -am test -Dtest=InMemoryMemoryStoreTest
```

Expected: compilation fails — `InMemoryMemoryStore` does not exist.

- [ ] **Step 5: Create InMemoryMemoryStore**

```java
package io.casehub.platform.memory.inmem;

import io.casehub.platform.api.identity.CurrentPrincipal;
import io.casehub.platform.api.memory.*;
import io.quarkus.arc.Priority;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.inject.Alternative;
import jakarta.inject.Inject;

import java.time.Instant;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CopyOnWriteArrayList;

@Alternative
@Priority(1)
@ApplicationScoped
public class InMemoryMemoryStore implements CaseMemoryStore {

    private final ConcurrentHashMap<BucketKey, CopyOnWriteArrayList<Memory>> store
        = new ConcurrentHashMap<>();
    private final CurrentPrincipal principal;

    @Inject
    public InMemoryMemoryStore(CurrentPrincipal principal) {
        this.principal = principal;
    }

    @Override
    public String store(MemoryInput input) {
        MemoryPermissions.assertTenant(input.tenantId(), principal);
        String memoryId = UUID.randomUUID().toString();
        Memory memory = new Memory(
            memoryId, input.entityId(), input.domain(), input.tenantId(),
            input.caseId(), input.text(), input.attributes(), Instant.now()
        );
        store.computeIfAbsent(
            new BucketKey(input.tenantId(), input.entityId(), input.domain()),
            k -> new CopyOnWriteArrayList<>()
        ).add(memory);
        return memoryId;
    }

    @Override
    public List<Memory> query(MemoryQuery query) {
        MemoryPermissions.assertTenant(query.tenantId(), principal);
        var bucket = store.getOrDefault(
            new BucketKey(query.tenantId(), query.entityId(), query.domain()),
            new CopyOnWriteArrayList<>()
        );
        return bucket.stream()
            .filter(m -> query.caseId() == null || query.caseId().equals(m.caseId()))
            .filter(m -> query.since() == null || !m.createdAt().isBefore(query.since()))
            .filter(m -> query.question() == null
                || m.text().toLowerCase().contains(query.question().toLowerCase()))
            .sorted(Comparator.comparing(Memory::createdAt).reversed())
            .limit(query.limit())
            .toList();
    }

    @Override
    public void erase(EraseRequest request) {
        MemoryPermissions.assertTenant(request.tenantId(), principal);
        var key = new BucketKey(request.tenantId(), request.entityId(), request.domain());
        store.computeIfPresent(key, (k, memories) ->
            new CopyOnWriteArrayList<>(memories.stream()
                .filter(m -> request.caseId() != null && !request.caseId().equals(m.caseId()))
                .toList())
        );
    }

    @Override
    public void eraseById(String memoryId, String tenantId) {
        MemoryPermissions.assertTenant(tenantId, principal);
        store.entrySet().stream()
            .filter(e -> e.getKey().tenantId().equals(tenantId))
            .forEach(e -> e.getValue().removeIf(m -> m.memoryId().equals(memoryId)));
    }

    @Override
    public void eraseEntity(String entityId, String tenantId) {
        MemoryPermissions.assertTenant(tenantId, principal);
        store.keySet().removeIf(
            k -> k.tenantId().equals(tenantId) && k.entityId().equals(entityId)
        );
    }
}
```

- [ ] **Step 6: Run first test — expect PASS**

```bash
mvn --batch-mode -pl memory-inmem -am test -Dtest=InMemoryMemoryStoreTest#store_assigns_non_empty_memory_id
```

Expected: 1 test passes.

---

## Task 6: InMemoryMemoryStore — complete contract tests

**Files:**
- Modify: `memory-inmem/src/test/java/io/casehub/platform/memory/inmem/InMemoryMemoryStoreTest.java`

- [ ] **Step 1: Write all remaining failing tests**

Replace the test file with the full contract test suite:

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
        @Override public String actorId() { return "actor"; }
        @Override public Set<String> groups() { return Set.of(); }
        @Override public String tenancyId() { return TENANT; }
        @Override public boolean isCrossTenantAdmin() { return false; }
    };

    private InMemoryMemoryStore sut;

    @BeforeEach
    void setUp() {
        sut = new InMemoryMemoryStore(principal);
    }

    // --- helpers ---

    private MemoryInput input(String text) {
        return new MemoryInput("entity-1", DOMAIN, TENANT, null, text, Map.of());
    }

    private MemoryInput inputWithCase(String text, String caseId) {
        return new MemoryInput("entity-1", DOMAIN, TENANT, caseId, text, Map.of());
    }

    private MemoryQuery query() {
        return new MemoryQuery("entity-1", DOMAIN, TENANT, null, null, 10, null);
    }

    private EraseRequest eraseRequest() {
        return new EraseRequest("entity-1", DOMAIN, TENANT, null);
    }

    // --- store ---

    @Test
    void store_assigns_non_empty_memory_id() {
        String id = sut.store(input("hello"));
        assertFalse(id.isEmpty());
    }

    @Test
    void store_assigns_unique_ids() {
        String id1 = sut.store(input("a"));
        String id2 = sut.store(input("b"));
        assertNotEquals(id1, id2);
    }

    @Test
    void store_tenant_mismatch_throws() {
        var bad = new MemoryInput("entity-1", DOMAIN, OTHER_TENANT, null, "x", Map.of());
        assertThrows(SecurityException.class, () -> sut.store(bad));
    }

    // --- query ---

    @Test
    void query_returns_stored_memories_in_desc_order() {
        sut.store(input("first"));
        sut.store(input("second"));
        var results = sut.query(query());
        assertEquals(2, results.size());
        assertEquals("second", results.get(0).text()); // most recent first
        assertEquals("first",  results.get(1).text());
    }

    @Test
    void query_empty_when_nothing_stored() {
        assertTrue(sut.query(query()).isEmpty());
    }

    @Test
    void query_does_not_leak_across_tenants() {
        sut.store(input("secret"));
        var crossQuery = new MemoryQuery("entity-1", DOMAIN, OTHER_TENANT, null, null, 10, null);
        // assertTenant throws — principal returns TENANT, query asks for OTHER_TENANT
        assertThrows(SecurityException.class, () -> sut.query(crossQuery));
    }

    @Test
    void query_does_not_leak_across_domains() {
        sut.store(input("finance fact"));
        var otherDomainQuery = new MemoryQuery("entity-1", OTHER_DOMAIN, TENANT, null, null, 10, null);
        assertTrue(sut.query(otherDomainQuery).isEmpty());
    }

    @Test
    void query_with_caseId_filters_correctly() {
        sut.store(input("no case"));
        sut.store(inputWithCase("case A", "case-1"));
        sut.store(inputWithCase("case B", "case-2"));

        var caseQuery = new MemoryQuery("entity-1", DOMAIN, TENANT, "case-1", null, 10, null);
        var results = sut.query(caseQuery);
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

        var sinceQuery = new MemoryQuery("entity-1", DOMAIN, TENANT, null, null, 10, barrier);
        var results = sut.query(sinceQuery);
        assertEquals(1, results.size());
        assertEquals("new", results.get(0).text());
    }

    @Test
    void query_limit_is_honoured() {
        for (int i = 0; i < 5; i++) sut.store(input("item " + i));
        var limitQuery = new MemoryQuery("entity-1", DOMAIN, TENANT, null, null, 3, null);
        assertEquals(3, sut.query(limitQuery).size());
    }

    @Test
    void query_with_question_filters_by_text_containment() {
        sut.store(input("the cat sat on the mat"));
        sut.store(input("the dog barked loudly"));

        var questionQuery = new MemoryQuery("entity-1", DOMAIN, TENANT, null, "cat", 10, null);
        var results = sut.query(questionQuery);
        assertEquals(1, results.size());
        assertEquals("the cat sat on the mat", results.get(0).text());
    }

    @Test
    void query_null_question_returns_all() {
        sut.store(input("anything"));
        sut.store(input("something else"));
        assertEquals(2, sut.query(query()).size());
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
        // wrong tenant in eraseById — assertTenant throws
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
        assertTrue(sut.query(new MemoryQuery("entity-1", OTHER_DOMAIN, TENANT, null, null, 10, null)).isEmpty());
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

        var e2query = new MemoryQuery("entity-2", DOMAIN, TENANT, null, null, 10, null);
        assertEquals(1, sut.query(e2query).size());
        assertEquals("other", sut.query(e2query).get(0).text());
    }
}
```

- [ ] **Step 2: Run — expect all PASS**

```bash
mvn --batch-mode -pl memory-inmem -am test
```

Expected: all 21 tests pass.

- [ ] **Step 3: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add memory-inmem/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#32): memory-inmem/ — InMemoryMemoryStore with full contract tests"
```

---

## Task 7: memory-jpa/ — scaffold (pom, MemoryJpaConfig, MemoryEntry, migration)

**Files:**
- Create: `memory-jpa/pom.xml`
- Create: `memory-jpa/src/main/java/io/casehub/platform/memory/jpa/MemoryJpaConfig.java`
- Create: `memory-jpa/src/main/java/io/casehub/platform/memory/jpa/MemoryEntry.java`
- Create: `memory-jpa/src/main/resources/db/memory/migration/V1000__memory_entry.sql`
- Create: `memory-jpa/src/test/resources/application.properties`
- Create: `memory-jpa/src/test/java/io/casehub/platform/memory/jpa/JpaMemoryStoreTest.java` (skeleton only)

- [ ] **Step 1: Create memory-jpa/pom.xml**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>

    <parent>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-platform-parent</artifactId>
        <version>0.2-SNAPSHOT</version>
    </parent>

    <artifactId>casehub-platform-memory-jpa</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform Memory JPA</name>
    <description>JPA-backed CaseMemoryStore. @ApplicationScoped — displaces @DefaultBean no-op.
        Add as compile dep; add classpath:db/memory/migration to quarkus.flyway.locations.
        Do NOT add casehub-platform-memory-inmem alongside this in test scope — @Priority(1)
        InMemoryMemoryStore displaces JpaMemoryStore, making JPA tests run against in-memory.</description>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-api</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-hibernate-orm-panache</artifactId>
        </dependency>
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-flyway</artifactId>
        </dependency>
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-jdbc-postgresql</artifactId>
            <optional>true</optional>
        </dependency>
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-jackson</artifactId>
        </dependency>

        <!-- Test -->
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform</artifactId>
            <version>${project.version}</version>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-jdbc-h2</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-junit</artifactId>
            <scope>test</scope>
        </dependency>
    </dependencies>

    <build>
        <plugins>
            <plugin>
                <groupId>io.quarkus</groupId>
                <artifactId>quarkus-maven-plugin</artifactId>
                <version>${quarkus.platform.version}</version>
                <extensions>true</extensions>
                <executions>
                    <execution>
                        <goals>
                            <goal>build</goal>
                            <goal>generate-code</goal>
                            <goal>generate-code-tests</goal>
                        </goals>
                    </execution>
                </executions>
            </plugin>
            <plugin>
                <groupId>io.smallrye</groupId>
                <artifactId>jandex-maven-plugin</artifactId>
                <version>${jandex-maven-plugin.version}</version>
                <executions>
                    <execution>
                        <id>make-index</id>
                        <goals><goal>jandex</goal></goals>
                    </execution>
                </executions>
            </plugin>
        </plugins>
    </build>
</project>
```

- [ ] **Step 2: Create MemoryJpaConfig**

```java
package io.casehub.platform.memory.jpa;

import io.smallrye.config.ConfigMapping;
import io.smallrye.config.WithDefault;

/** Configuration for the JPA-backed CaseMemoryStore adapter. */
@ConfigMapping(prefix = "casehub.memory.jpa")
public interface MemoryJpaConfig {

    /** Full-text search settings for memory queries. */
    Fts fts();

    interface Fts {
        /** Whether to use PostgreSQL FTS when a question is provided. Default: true. */
        @WithDefault("true")
        boolean enabled();

        /** PostgreSQL text search configuration name (e.g. english, french). Default: english. */
        @WithDefault("english")
        String language();
    }
}
```

- [ ] **Step 3: Create MemoryEntry entity**

```java
package io.casehub.platform.memory.jpa;

import io.quarkus.hibernate.orm.panache.PanacheEntityBase;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import java.time.Instant;

/** JPA entity for a stored memory. domain stored as String (MemoryDomain.name()). */
@Entity
@Table(name = "memory_entry")
public class MemoryEntry extends PanacheEntityBase {

    @Id
    @Column(name = "memory_id", length = 36, nullable = false)
    public String memoryId;

    @Column(name = "tenant_id", nullable = false)
    public String tenantId;

    @Column(name = "entity_id", nullable = false)
    public String entityId;

    @Column(name = "domain", nullable = false)
    public String domain;

    @Column(name = "case_id")
    public String caseId;

    @Column(name = "text", nullable = false, columnDefinition = "TEXT")
    public String text;

    /** JSON string serialized from Map<String,String> using Jackson ObjectMapper. */
    @Column(name = "attributes", nullable = false, columnDefinition = "TEXT")
    public String attributes;

    @Column(name = "created_at", nullable = false)
    public Instant createdAt;
}
```

- [ ] **Step 4: Create Flyway migration V1000__memory_entry.sql**

```sql
CREATE TABLE memory_entry (
    memory_id  VARCHAR(36)  NOT NULL,
    tenant_id  VARCHAR(255) NOT NULL,
    entity_id  VARCHAR(255) NOT NULL,
    domain     VARCHAR(255) NOT NULL,
    case_id    VARCHAR(255),
    text       TEXT         NOT NULL,
    attributes TEXT         NOT NULL DEFAULT '{}',
    created_at TIMESTAMPTZ  NOT NULL,
    CONSTRAINT memory_entry_pk PRIMARY KEY (memory_id)
);

-- Primary query index: tenant/entity/domain scoping + chronological ordering
CREATE INDEX memory_entry_lookup_idx
    ON memory_entry (tenant_id, entity_id, domain, created_at DESC);

-- eraseEntity() index: delete all memories for an entity across all domains
CREATE INDEX memory_entry_erase_idx
    ON memory_entry (tenant_id, entity_id);
```

- [ ] **Step 5: Create test application.properties**

```properties
# H2 in-memory with unique database name (avoid cross-module data leaks)
quarkus.datasource.db-kind=h2
quarkus.datasource.jdbc.url=jdbc:h2:mem:memorytest;DB_CLOSE_DELAY=-1;MODE=PostgreSQL

# Only scan memory migrations — don't require platform preference migrations in this module's tests
quarkus.flyway.locations=classpath:db/memory/migration

# Disable FTS: H2 has no to_tsvector/websearch_to_tsquery. FTS tested via Testcontainers (#38).
casehub.memory.jpa.fts.enabled=false

# MockCurrentPrincipal tenancyId — all test inputs must use this value
casehub.tenancy.default-id=tenant-1

# CDI index — discover JpaMemoryStore beans from the library JAR
quarkus.index-dependency.memory-jpa.group-id=io.casehub
quarkus.index-dependency.memory-jpa.artifact-id=casehub-platform-memory-jpa
```

- [ ] **Step 6: Create JpaMemoryStoreTest skeleton with first failing test**

```java
package io.casehub.platform.memory.jpa;

import io.casehub.platform.api.memory.*;
import io.quarkus.test.junit.QuarkusTest;
import jakarta.inject.Inject;
import jakarta.transaction.Transactional;
import org.junit.jupiter.api.Test;
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

    private MemoryInput inputWithCase(String text, String caseId) {
        return new MemoryInput("entity-1", DOMAIN, TENANT, caseId, text, Map.of());
    }

    private MemoryQuery query() {
        return new MemoryQuery("entity-1", DOMAIN, TENANT, null, null, 10, null);
    }

    private EraseRequest eraseRequest() {
        return new EraseRequest("entity-1", DOMAIN, TENANT, null);
    }

    @Test
    @Transactional
    void store_assigns_non_empty_memory_id() {
        String id = store.store(input("hello"));
        assertFalse(id.isEmpty());
    }
}
```

- [ ] **Step 7: Run — expect compile FAIL**

```bash
mvn --batch-mode -pl memory-jpa -am test -Dtest=JpaMemoryStoreTest#store_assigns_non_empty_memory_id
```

Expected: compilation fails — `JpaMemoryStore` does not exist.

---

## Task 8: JpaMemoryStore — store() + chronological query()

**Files:**
- Create: `memory-jpa/src/main/java/io/casehub/platform/memory/jpa/JpaMemoryStore.java`

- [ ] **Step 1: Create JpaMemoryStore with store() and chronological query()**

```java
package io.casehub.platform.memory.jpa;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.casehub.platform.api.identity.CurrentPrincipal;
import io.casehub.platform.api.memory.*;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import jakarta.persistence.EntityManager;
import jakarta.transaction.Transactional;
import jakarta.transaction.Transactional.TxType;

import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.UUID;

@ApplicationScoped
public class JpaMemoryStore implements CaseMemoryStore {

    @Inject CurrentPrincipal principal;
    @Inject MemoryJpaConfig config;
    @Inject EntityManager em;
    @Inject ObjectMapper objectMapper;

    @Override
    @Transactional(TxType.REQUIRED)
    public String store(MemoryInput input) {
        MemoryPermissions.assertTenant(input.tenantId(), principal);

        MemoryEntry entry = new MemoryEntry();
        entry.memoryId   = UUID.randomUUID().toString();
        entry.tenantId   = input.tenantId();
        entry.entityId   = input.entityId();
        entry.domain     = input.domain().name();
        entry.caseId     = input.caseId();
        entry.text       = input.text();
        entry.attributes = serializeAttributes(input.attributes());
        entry.createdAt  = Instant.now();

        MemoryEntry.persist(entry);
        return entry.memoryId;
    }

    @Override
    @Transactional(TxType.SUPPORTS)
    public List<Memory> query(MemoryQuery query) {
        MemoryPermissions.assertTenant(query.tenantId(), principal);

        if (config.fts().enabled() && query.question() != null) {
            return queryFts(query);
        }
        return queryChronological(query);
    }

    private List<Memory> queryChronological(MemoryQuery query) {
        var jpql = new StringBuilder(
            "FROM MemoryEntry WHERE tenantId = :tenantId AND entityId = :entityId AND domain = :domain");
        if (query.caseId() != null) jpql.append(" AND caseId = :caseId");
        if (query.since()  != null) jpql.append(" AND createdAt >= :since");
        jpql.append(" ORDER BY createdAt DESC");

        var jq = em.createQuery(jpql.toString(), MemoryEntry.class)
            .setParameter("tenantId", query.tenantId())
            .setParameter("entityId", query.entityId())
            .setParameter("domain",   query.domain().name())
            .setMaxResults(query.limit());

        if (query.caseId() != null) jq.setParameter("caseId", query.caseId());
        if (query.since()  != null) jq.setParameter("since",  query.since());

        return jq.getResultList().stream().map(this::toMemory).toList();
    }

    @SuppressWarnings("unchecked")
    private List<Memory> queryFts(MemoryQuery query) {
        var sql = new StringBuilder("""
            SELECT * FROM memory_entry
            WHERE tenant_id = :tenantId AND entity_id = :entityId AND domain = :domain
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
            .setParameter("tenantId", query.tenantId())
            .setParameter("entityId", query.entityId())
            .setParameter("domain",   query.domain().name())
            .setParameter("lang",     config.fts().language())
            .setParameter("question", query.question())
            .setMaxResults(query.limit());

        if (query.caseId() != null) nq.setParameter("caseId", query.caseId());
        if (query.since()  != null) nq.setParameter("since",  query.since());

        return ((List<MemoryEntry>) nq.getResultList()).stream().map(this::toMemory).toList();
    }

    @Override
    @Transactional(TxType.REQUIRED)
    public void erase(EraseRequest request) {
        MemoryPermissions.assertTenant(request.tenantId(), principal);

        var jpql = new StringBuilder(
            "DELETE FROM MemoryEntry WHERE tenantId = :tenantId AND entityId = :entityId AND domain = :domain");
        if (request.caseId() != null) jpql.append(" AND caseId = :caseId");

        var q = em.createQuery(jpql.toString())
            .setParameter("tenantId", request.tenantId())
            .setParameter("entityId", request.entityId())
            .setParameter("domain",   request.domain().name());
        if (request.caseId() != null) q.setParameter("caseId", request.caseId());

        q.executeUpdate();
        em.clear();
    }

    @Override
    @Transactional(TxType.REQUIRED)
    public void eraseById(String memoryId, String tenantId) {
        MemoryPermissions.assertTenant(tenantId, principal);
        em.createQuery("DELETE FROM MemoryEntry WHERE memoryId = :id AND tenantId = :tenantId")
            .setParameter("id",       memoryId)
            .setParameter("tenantId", tenantId)
            .executeUpdate();
        em.clear();
    }

    @Override
    @Transactional(TxType.REQUIRED)
    public void eraseEntity(String entityId, String tenantId) {
        MemoryPermissions.assertTenant(tenantId, principal);
        em.createQuery("DELETE FROM MemoryEntry WHERE tenantId = :tenantId AND entityId = :entityId")
            .setParameter("tenantId", tenantId)
            .setParameter("entityId", entityId)
            .executeUpdate();
        em.clear();
    }

    private Memory toMemory(MemoryEntry e) {
        return new Memory(
            e.memoryId,
            e.entityId,
            new MemoryDomain(e.domain),
            e.tenantId,
            e.caseId,
            e.text,
            deserializeAttributes(e.attributes),
            e.createdAt
        );
    }

    private String serializeAttributes(Map<String, String> attrs) {
        try {
            return objectMapper.writeValueAsString(attrs);
        } catch (JsonProcessingException e) {
            throw new IllegalStateException("Failed to serialize attributes", e);
        }
    }

    @SuppressWarnings("unchecked")
    private Map<String, String> deserializeAttributes(String json) {
        try {
            return objectMapper.readValue(json, Map.class);
        } catch (JsonProcessingException e) {
            throw new IllegalStateException("Failed to deserialize attributes: " + json, e);
        }
    }
}
```

- [ ] **Step 2: Run first test — expect PASS**

```bash
mvn --batch-mode -pl memory-jpa -am test -Dtest=JpaMemoryStoreTest#store_assigns_non_empty_memory_id
```

Expected: 1 test passes. Flyway runs V1000__memory_entry.sql, JpaMemoryStore stores a memory and returns a UUID.

---

## Task 9: JpaMemoryStoreTest — complete contract tests

**Files:**
- Modify: `memory-jpa/src/test/java/io/casehub/platform/memory/jpa/JpaMemoryStoreTest.java`

- [ ] **Step 1: Replace with full test suite**

```java
package io.casehub.platform.memory.jpa;

import io.casehub.platform.api.memory.*;
import io.quarkus.test.junit.QuarkusTest;
import jakarta.inject.Inject;
import jakarta.transaction.Transactional;
import org.junit.jupiter.api.Test;
import java.time.Instant;
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

    private MemoryInput inputWithCase(String text, String caseId) {
        return new MemoryInput("entity-1", DOMAIN, TENANT, caseId, text, Map.of());
    }

    private MemoryQuery query() {
        return new MemoryQuery("entity-1", DOMAIN, TENANT, null, null, 10, null);
    }

    private EraseRequest eraseRequest() {
        return new EraseRequest("entity-1", DOMAIN, TENANT, null);
    }

    // --- store ---

    @Test @Transactional
    void store_assigns_non_empty_memory_id() {
        assertFalse(store.store(input("hello")).isEmpty());
    }

    @Test @Transactional
    void store_assigns_unique_ids() {
        assertNotEquals(store.store(input("a")), store.store(input("b")));
    }

    @Test
    void store_tenant_mismatch_throws() {
        var bad = new MemoryInput("entity-1", DOMAIN, OTHER_TENANT, null, "x", Map.of());
        assertThrows(SecurityException.class, () -> store.store(bad));
    }

    @Test @Transactional
    void store_does_not_leak_across_tenants() {
        store.store(input("secret"));
        var crossQuery = new MemoryQuery("entity-1", DOMAIN, OTHER_TENANT, null, null, 10, null);
        assertThrows(SecurityException.class, () -> store.query(crossQuery));
    }

    @Test @Transactional
    void store_does_not_leak_across_domains() {
        store.store(input("finance fact"));
        var otherQuery = new MemoryQuery("entity-1", OTHER_DOMAIN, TENANT, null, null, 10, null);
        assertTrue(store.query(otherQuery).isEmpty());
    }

    // --- query ---

    @Test @Transactional
    void query_returns_stored_memories_in_desc_order() {
        store.store(input("first"));
        store.store(input("second"));
        var results = store.query(query());
        assertEquals(2, results.size());
        assertEquals("second", results.get(0).text());
        assertEquals("first",  results.get(1).text());
    }

    @Test @Transactional
    void query_empty_when_nothing_stored() {
        assertTrue(store.query(query()).isEmpty());
    }

    @Test @Transactional
    void query_with_caseId_filters_correctly() {
        store.store(input("no case"));
        store.store(inputWithCase("case A", "case-1"));
        store.store(inputWithCase("case B", "case-2"));

        var caseQuery = new MemoryQuery("entity-1", DOMAIN, TENANT, "case-1", null, 10, null);
        var results = store.query(caseQuery);
        assertEquals(1, results.size());
        assertEquals("case A", results.get(0).text());
    }

    @Test @Transactional
    void query_null_caseId_returns_all() {
        store.store(input("no case"));
        store.store(inputWithCase("with case", "case-1"));
        assertEquals(2, store.query(query()).size());
    }

    @Test @Transactional
    void query_with_since_excludes_older_memories() throws InterruptedException {
        store.store(input("old"));
        Instant barrier = Instant.now();
        Thread.sleep(5);
        store.store(input("new"));

        var sinceQuery = new MemoryQuery("entity-1", DOMAIN, TENANT, null, null, 10, barrier);
        var results = store.query(sinceQuery);
        assertEquals(1, results.size());
        assertEquals("new", results.get(0).text());
    }

    @Test @Transactional
    void query_limit_is_honoured() {
        for (int i = 0; i < 5; i++) store.store(input("item " + i));
        var limitQuery = new MemoryQuery("entity-1", DOMAIN, TENANT, null, null, 3, null);
        assertEquals(3, store.query(limitQuery).size());
    }

    // --- erase ---

    @Test @Transactional
    void erase_domain_scoped_removes_matching_only() {
        store.store(input("to erase"));
        store.erase(eraseRequest());
        assertTrue(store.query(query()).isEmpty());
    }

    @Test @Transactional
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

    @Test @Transactional
    void eraseById_removes_specific_memory() {
        String id = store.store(input("to delete"));
        store.store(input("to keep"));
        store.eraseById(id, TENANT);
        var remaining = store.query(query());
        assertEquals(1, remaining.size());
        assertEquals("to keep", remaining.get(0).text());
    }

    @Test @Transactional
    void eraseById_does_not_cross_tenant_boundary() {
        store.store(input("protected"));
        // assertTenant throws when tenantId != principal.tenancyId()
        assertThrows(SecurityException.class, () -> store.eraseById("any-id", OTHER_TENANT));
        assertEquals(1, store.query(query()).size());
    }

    // --- eraseEntity ---

    @Test @Transactional
    void eraseEntity_removes_all_domains_for_entity() {
        store.store(new MemoryInput("entity-1", DOMAIN,       TENANT, null, "finance", Map.of()));
        store.store(new MemoryInput("entity-1", OTHER_DOMAIN, TENANT, null, "health",  Map.of()));

        store.eraseEntity("entity-1", TENANT);

        assertTrue(store.query(query()).isEmpty());
        var otherDomainQuery = new MemoryQuery("entity-1", OTHER_DOMAIN, TENANT, null, null, 10, null);
        assertTrue(store.query(otherDomainQuery).isEmpty());
    }

    @Test @Transactional
    void eraseEntity_does_not_cross_tenant_boundary() {
        assertThrows(SecurityException.class, () -> store.eraseEntity("entity-1", OTHER_TENANT));
    }

    @Test @Transactional
    void eraseEntity_leaves_other_entities_intact() {
        store.store(new MemoryInput("entity-1", DOMAIN, TENANT, null, "mine",  Map.of()));
        store.store(new MemoryInput("entity-2", DOMAIN, TENANT, null, "other", Map.of()));

        store.eraseEntity("entity-1", TENANT);

        var e2query = new MemoryQuery("entity-2", DOMAIN, TENANT, null, null, 10, null);
        assertEquals(1, store.query(e2query).size());
        assertEquals("other", store.query(e2query).get(0).text());
    }

    // --- tenant assertion ---

    @Test
    void assertTenant_mismatch_throws_before_any_backend_call() {
        // store() with wrong tenant should throw SecurityException before touching the DB
        var bad = new MemoryInput("entity-1", DOMAIN, OTHER_TENANT, null, "x", Map.of());
        assertThrows(SecurityException.class, () -> store.store(bad));
    }
}
```

- [ ] **Step 2: Run — expect all PASS**

```bash
mvn --batch-mode -pl memory-jpa -am test
```

Expected: all 20 tests pass.

- [ ] **Step 3: Run full build**

```bash
mvn --batch-mode install
```

Expected: `BUILD SUCCESS` — all modules compile and all tests pass.

- [ ] **Step 4: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add \
  pom.xml \
  memory-jpa/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#32): memory-jpa/ — JpaMemoryStore with full contract tests, V1000 migration"
```

---

## Self-Review

**Spec coverage check:**

| Spec requirement | Task |
|---|---|
| EraseRequest.domain required | Task 1 |
| CaseMemoryStore.eraseEntity() default-throw | Task 2 |
| ReactiveCaseMemoryStore.eraseEntity() default-fail | Task 3 |
| BlockingToReactiveBridge eraseEntity() wrapper | Task 3 |
| NoOpCaseMemoryStore eraseEntity() no-op | Task 3 |
| ERASE_ALL_DOMAINS removed from NoOpCaseMemoryStoreTest | Task 3 |
| memory-inmem/ pom with Jandex, quarkus-arc | Task 5 |
| BucketKey record (typed, no separator collision) | Task 5 |
| InMemoryMemoryStore @Alternative @Priority(1) | Task 5 |
| Constructor injection (plain JUnit tests) | Task 5–6 |
| Full in-memory contract: all 21 tests | Task 6 |
| memory-jpa/ pom with quarkus-jackson, Jandex, no memory-inmem in test deps | Task 7 |
| MemoryJpaConfig nested Fts interface with Javadoc | Task 7 |
| MemoryEntry entity (PanacheEntityBase, all fields) | Task 7 |
| V1000__memory_entry.sql (two indexes) | Task 7 |
| Test application.properties: fts.enabled=false, mem:memorytest, quarkus.index-dependency | Task 7 |
| JpaMemoryStore store() with UUID assignment and attribute serialization | Task 8 |
| JpaMemoryStore chronological query() with optional caseId/since | Task 8 |
| JpaMemoryStore FTS query path (disabled in H2 tests) | Task 8 |
| JpaMemoryStore erase/eraseById/eraseEntity with em.clear() | Task 8 |
| Full JPA contract: all 20 tests | Task 9 |
| Full build passes | Task 9 |

**Gaps:** None detected. FTS Testcontainers integration testing is deliberately deferred to #38.

**Type consistency:** `MemoryEntry`, `BucketKey`, `MemoryJpaConfig.Fts` names used consistently across tasks. `toMemory()` helper defined in Task 8 and used only within `JpaMemoryStore`.
