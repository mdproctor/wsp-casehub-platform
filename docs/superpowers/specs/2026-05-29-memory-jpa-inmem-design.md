# memory-jpa/ + memory-inmem/ — Design Spec

**Date:** 2026-05-29
**Issue:** casehubio/platform#32
**Branch:** issue-32-memori-adapter
**Replaces:** original Memori REST client scope (see ADR-0008 amendment)

---

## 1. Context and Pivot

The original #32 scope targeted a REST client adapter for Memori (GibsonAI). Research during
brainstorming found that Memori's dedicated REST API is not yet stable, and the BYODB deployment
requires a Python sidecar — making the "zero extra infra" claim false for Java deployments.

This spec pivots to:
- `memory-jpa/` — JPA/Panache adapter, PostgreSQL, durable, zero-extra-infra for JPA deployments
- `memory-inmem/` — pure Java in-memory adapter, volatile, zero-infra for tests and ephemeral installs

Both are sibling modules in `casehub-platform`. The Memori REST adapter is tracked separately
as #40 pending API stabilisation.

---

## 2. SPI Changes (`platform-api/` + `platform/`)

These are prerequisites for both adapter modules and should be committed first.

### 2.1 `EraseRequest` — domain is now required

`domain` changes from nullable to required. The null-domain cross-domain GDPR erase is replaced
by the new `eraseEntity()` method.

```java
public record EraseRequest(
    String entityId,
    MemoryDomain domain,    // required — was nullable
    String tenantId,
    String caseId           // still nullable
) {
    public EraseRequest {
        Objects.requireNonNull(entityId, "entityId required");
        Objects.requireNonNull(domain,   "domain required");
        Objects.requireNonNull(tenantId, "tenantId required");
    }
}
```

### 2.2 `CaseMemoryStore` — add `eraseEntity()`

```java
/**
 * GDPR Art.17 full-entity wipe across ALL domains for this entity within the tenant.
 * Adapters MUST perform hard deletion.
 * Adapters MUST call {@link MemoryPermissions#assertTenant} before delegating to the backend.
 */
void eraseEntity(String entityId, String tenantId);
```

No default — abstract. `NoOpCaseMemoryStore` gets a no-op body. `eraseById()` default still
throws `UnsupportedOperationException` per `spi-deletion-default-throws.md`.

### 2.3 `ReactiveCaseMemoryStore` — mirror `eraseEntity()`

```java
/**
 * Reactive mirror of {@link CaseMemoryStore#eraseEntity}.
 */
Uni<Void> eraseEntity(String entityId, String tenantId);
```

No default — abstract. `BlockingToReactiveBridge` wraps the blocking delegate:

```java
@Override
public Uni<Void> eraseEntity(String entityId, String tenantId) {
    return Uni.createFrom().voidItem()
        .invoke(() -> delegate.eraseEntity(entityId, tenantId));
}
```

### 2.4 Affected files

| File | Change |
|------|--------|
| `platform-api/.../EraseRequest.java` | domain non-nullable |
| `platform-api/.../CaseMemoryStore.java` | add `eraseEntity()` abstract |
| `platform/.../NoOpCaseMemoryStore.java` | add `eraseEntity()` no-op |
| `platform/.../ReactiveCaseMemoryStore.java` | add `eraseEntity()` abstract |
| `platform/.../BlockingToReactiveBridge.java` | add `eraseEntity()` wrapper |
| `platform-api/test/.../CaseMemoryStoreSpiTest.java` | add `eraseEntity()` to anonymous impl; update EraseRequest usages |
| `platform/test/.../NoOpCaseMemoryStoreTest.java` | add eraseEntity tests for store + bridge |

---

## 3. Module Structure

### 3.1 `memory-inmem/` — `casehub-platform-memory-inmem`

```
memory-inmem/
  pom.xml
  src/main/java/io/casehub/platform/memory/inmem/
    InMemoryMemoryStore.java
```

**pom.xml key points:**
- parent: `casehub-platform-parent`
- compile deps: `casehub-platform-api`, `quarkus-arc`
- no `quarkus-maven-plugin build` goal — library, not application
- no Flyway, no JDBC

### 3.2 `memory-jpa/` — `casehub-platform-memory-jpa`

```
memory-jpa/
  pom.xml
  src/main/java/io/casehub/platform/memory/jpa/
    JpaMemoryStore.java
    MemoryEntry.java
    MemoryJpaConfig.java
  src/main/resources/db/memory/migration/
    V1__memory_entry.sql
  src/test/java/io/casehub/platform/memory/jpa/
    JpaMemoryStoreTest.java
  src/test/resources/
    application.properties
```

**pom.xml key points:**
- parent: `casehub-platform-parent`
- compile deps: `casehub-platform-api`, `quarkus-hibernate-orm-panache`, `quarkus-flyway`,
  `quarkus-jdbc-postgresql` (optional)
- test deps: `casehub-platform` (verify no-op displacement),
  `casehub-platform-memory-inmem` (displace JPA in unit tests),
  `quarkus-jdbc-h2`, `quarkus-junit`
- plugins: `quarkus-maven-plugin` with `build` goal, `jandex-maven-plugin`

### 3.3 Root pom.xml

Add `<module>memory-inmem</module>` and `<module>memory-jpa</module>`.

---

## 4. CDI Priority Ladder

| Tier | Module | CDI | Active when |
|------|--------|-----|-------------|
| 0 | `platform/` | `@DefaultBean @ApplicationScoped` | Nothing on classpath |
| 0.5 | `memory-inmem/` | `@Alternative @Priority(1)` | Added as dep |
| 1 | `memory-jpa/` | `@ApplicationScoped` | Added as dep |
| 2 | `memory-mem0/` (future) | `@Alternative @Priority(1)` | — |
| 3 | `memory-graphiti/` (future) | `@Alternative @Priority(2)` | — |

**Priority conflict note:** `memory-inmem/` and future `memory-mem0/` both use `@Priority(1)`.
Revisit when mem0 is implemented — tracked in #39.

---

## 5. Schema (`memory-jpa/`)

### `V1__memory_entry.sql`

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

CREATE INDEX memory_entry_lookup_idx
    ON memory_entry (tenant_id, entity_id, domain, created_at DESC);

CREATE INDEX memory_entry_erase_idx
    ON memory_entry (tenant_id, entity_id);
```

**Design decisions:**
- `memory_id VARCHAR(36)` not UUID type — avoids `gen_random_uuid()` H2 incompatibility;
  adapter assigns UUID explicitly before INSERT
- `attributes TEXT` not JSONB — H2 compatibility; we don't query inside attributes; serialized
  as standard JSON object (`{"key":"value"}`) by the adapter; deserialized on read
- No `tsvector` column — FTS computed at query time over the pre-filtered small corpus;
  a GIN index is not justified given the mandatory tenant/entity/domain predicates
- `memory_entry_erase_idx` covers `eraseEntity()` (`WHERE tenant_id=? AND entity_id=?`)
- Consumer Flyway config: add `classpath:db/memory/migration` to `quarkus.flyway.locations`

---

## 6. `InMemoryMemoryStore`

**Package:** `io.casehub.platform.memory.inmem`

**CDI:** `@Alternative @Priority(1) @ApplicationScoped`

**Storage:** `ConcurrentHashMap<String, CopyOnWriteArrayList<Memory>>`

**Key structure:** `tenantId + "|" + entityId + "|" + domain.name()` — structural isolation
matches the JPA adapter's query scoping. Tenant prefix enables prefix-scan in `eraseEntity()`.

**Constructor injection** (single `@Inject` constructor accepting `CurrentPrincipal`) —
enables pure JUnit 5 tests without CDI container.

**Method semantics:**

| Method | Behaviour |
|--------|-----------|
| `store()` | asserts tenant; UUID.randomUUID(); adds to bucket |
| `query()` | asserts tenant; streams bucket; filters caseId, since; filters question via `text.toLowerCase().contains(q.toLowerCase())`; sorts DESC; limits |
| `erase()` | asserts tenant; removes from bucket where caseId matches (or all if caseId null) |
| `eraseById()` | asserts tenant; scans all buckets with tenant prefix; removes matching memoryId |
| `eraseEntity()` | asserts tenant; `keySet().removeIf(k -> k.startsWith(tenantId + "\|" + entityId + "\|"))` |

**Note on question matching:** simple `contains()`, not real FTS. Callers expecting relevance
ranking should use `memory-jpa/` (PostgreSQL FTS) or higher tiers.

---

## 7. `JpaMemoryStore`

**Package:** `io.casehub.platform.memory.jpa`

**CDI:** `@ApplicationScoped`

**Injects:** `CurrentPrincipal`, `MemoryJpaConfig`

### 7.1 `MemoryJpaConfig`

```java
@ConfigMapping(prefix = "casehub.memory.jpa")
interface MemoryJpaConfig {
    @WithDefault("true")
    boolean ftsEnabled();

    @WithName("fts.language")
    @WithDefault("english")
    String ftsLanguage();
}
```

Valid `ftsLanguage` values: any PostgreSQL text search configuration name
(`english`, `french`, `german`, `spanish`, etc.). Validated by PostgreSQL at query time —
invalid values produce a `PSQLException`, not a silent wrong result.

### 7.2 Transaction boundaries

| Method | `@Transactional` |
|--------|-----------------|
| `store()` | `TxType.REQUIRED` |
| `query()` | `TxType.SUPPORTS` |
| `erase()` | `TxType.REQUIRED` |
| `eraseById()` | `TxType.REQUIRED` |
| `eraseEntity()` | `TxType.REQUIRED` |

### 7.3 `store()`

1. `MemoryPermissions.assertTenant(input.tenantId(), principal)`
2. Assign `memoryId = UUID.randomUUID().toString()`
3. Set `createdAt = Instant.now()`
4. Serialize `attributes` as JSON string
5. `MemoryEntry.persist(entry)`
6. Return `memoryId`

### 7.4 `query()` — two paths

**Chronological** (JPQL, H2-compatible):
```
WHERE tenantId = :t AND entityId = :e AND domain = :d
  AND (:caseId IS NULL OR caseId = :caseId)
  AND (:since IS NULL OR createdAt >= :since)
ORDER BY createdAt DESC
```

**FTS** (native SQL, PostgreSQL only — when `ftsEnabled=true` AND `question != null`):
```sql
WHERE tenant_id = :t AND entity_id = :e AND domain = :d
  AND to_tsvector(CAST(:lang AS regconfig), text)
      @@ websearch_to_tsquery(CAST(:lang AS regconfig), :question)
  AND (:caseId IS NULL OR case_id = :caseId)
  AND (:since IS NULL OR created_at >= :since)
ORDER BY ts_rank(
    to_tsvector(CAST(:lang AS regconfig), text),
    websearch_to_tsquery(CAST(:lang AS regconfig), :question)
) DESC
```

`CAST(:lang AS regconfig)` — language is a named parameter, not string concatenation.
Prevents SQL injection; PostgreSQL validates the cast against known text search configs.

### 7.5 `erase()` (domain-scoped)

```sql
DELETE FROM memory_entry
WHERE tenant_id = :t AND entity_id = :e AND domain = :d
  AND (:caseId IS NULL OR case_id = :caseId)
```

Domain is now always non-null — no null-domain handling needed.

### 7.6 `eraseById()`

```sql
DELETE FROM memory_entry
WHERE memory_id = :id AND tenant_id = :t
```

`tenant_id` in the WHERE clause: structural defence-in-depth. Even if a memoryId UUID is
guessed, deletion across tenant boundaries is architecturally impossible.

### 7.7 `eraseEntity()` (GDPR full-entity wipe)

```sql
DELETE FROM memory_entry
WHERE tenant_id = :t AND entity_id = :e
```

Uses `memory_entry_erase_idx`. No domain predicate — wipes all domains atomically.

---

## 8. Permission Enforcement Contract

All adapter methods — both `JpaMemoryStore` and `InMemoryMemoryStore` — MUST call
`MemoryPermissions.assertTenant(tenantId, currentPrincipal)` as the first operation, before
any backend call. In `JpaMemoryStore`, `CurrentPrincipal` is captured before any `Uni`
pipeline (not applicable here — blocking adapter — but noted for future reactive adapters).

Tenant isolation is structural: `tenant_id` is a mandatory `NOT NULL` column and every
query includes `WHERE tenant_id = :tenantId` as a non-optional predicate. Cross-tenant
retrieval is architecturally impossible, not just policy-filtered.

---

## 9. Testing Strategy

### 9.1 SPI / NoOp tests (existing modules, updated)

- `CaseMemoryStoreSpiTest` — add `eraseEntity()` to anonymous impl (compile enforces it);
  update `EraseRequest` usages to non-null domain
- `NoOpCaseMemoryStoreTest` — add `eraseEntity_doesNotThrow` + `bridge_eraseEntity_doesNotThrow`

### 9.2 `InMemoryMemoryStoreTest` (pure JUnit 5)

No `@QuarkusTest`. Instantiate via constructor with a lambda `CurrentPrincipal`.
Covers the full contract: all methods, tenant isolation, domain isolation, caseId filter,
since filter, limit, eraseEntity cross-domain.

### 9.3 `JpaMemoryStoreTest` (`@QuarkusTest` + H2)

Test `application.properties`:
```properties
casehub.memory.jpa.fts.enabled=false
quarkus.flyway.locations=classpath:db/memory/migration
quarkus.datasource.db-kind=h2
quarkus.datasource.jdbc.url=jdbc:h2:mem:test;DB_CLOSE_DELAY=-1;MODE=PostgreSQL
```

Key test cases:

| Test | Proves |
|------|--------|
| `store_assignsNonEmptyMemoryId` | UUID assigned |
| `store_doesNotLeakAcrossTenants` | structural tenant isolation |
| `store_doesNotLeakAcrossDomains` | structural domain isolation |
| `query_returnsChronologicalDesc` | ordering |
| `query_withCaseId_filtersCorrectly` | null = any; non-null = exact match |
| `query_withSince_excludesOlderMemories` | since filter |
| `query_withLimit_honoured` | limit |
| `erase_domainScoped_removesMatchingOnly` | erase precision |
| `erase_withCaseId_leavesOtherCases` | caseId-scoped erase |
| `eraseById_removesSpecificMemory` | point delete |
| `eraseById_doesNotCrossTenantBoundary` | wrong tenantId leaves record intact |
| `eraseEntity_removesAllDomainsForEntity` | GDPR cross-domain wipe |
| `assertTenant_mismatch_throws` | security gate fires before backend |
| `store_displaces_noOp` | `@Inject CaseMemoryStore` resolves to `JpaMemoryStore` |

FTS integration tests (PostgreSQL Testcontainers) deferred — tracked in #38.

---

## 10. Consumer Integration

### Activating `memory-jpa/`

```xml
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-platform-memory-jpa</artifactId>
    <version>${casehub-platform.version}</version>
</dependency>
```

```properties
quarkus.flyway.locations=classpath:db/memory/migration,...existing locations
```

`JpaMemoryStore @ApplicationScoped` displaces `NoOpCaseMemoryStore @DefaultBean` automatically.

### Activating `memory-inmem/` (test/ephemeral)

```xml
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-platform-memory-inmem</artifactId>
    <version>${casehub-platform.version}</version>
    <scope>test</scope>   <!-- or compile for ephemeral installs -->
</dependency>
```

`InMemoryMemoryStore @Alternative @Priority(1)` displaces both `NoOpCaseMemoryStore` and
`JpaMemoryStore` when on the classpath.

---

## 11. Deferred Items

| Issue | Description |
|-------|-------------|
| #37 | `memory-sqlite/` — SQLite adapter for durable pure-Java deployments |
| #38 | FTS Testcontainers integration test for `memory-jpa/` |
| #39 | CDI priority revisit when `memory-mem0/` arrives |
| #40 | `memory-memori/` REST adapter — pending Memori API stabilisation |
| casehubio/parent#90 | PLATFORM.md update — casehub-memory now in-platform |
