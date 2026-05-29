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

These are prerequisites for both adapter modules and must be committed first.

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
 *
 * <p>Default throws {@link UnsupportedOperationException} — consistent with
 * {@link #eraseById}. {@code NoOpCaseMemoryStore} overrides with a true no-op
 * (nothing stored). Real adapters must override with actual cross-domain deletion.
 */
default void eraseEntity(String entityId, String tenantId) {
    throw new UnsupportedOperationException("eraseEntity not supported by this adapter");
}
```

Default-throw rather than abstract — consistent with `eraseById()` and `spi-deletion-default-throws.md`.
Gives a clear runtime signal rather than a compile-time break for any future external implementor.

### 2.3 `ReactiveCaseMemoryStore` — mirror `eraseEntity()`

```java
/**
 * Reactive mirror of {@link CaseMemoryStore#eraseEntity}.
 * Default returns a failed Uni matching the blocking interface's contract.
 */
default Uni<Void> eraseEntity(String entityId, String tenantId) {
    return Uni.createFrom().failure(
        new UnsupportedOperationException("eraseEntity not supported by this adapter"));
}
```

`BlockingToReactiveBridge` overrides to wrap the blocking delegate:

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
| `platform-api/.../CaseMemoryStore.java` | add `eraseEntity()` default-throw; update `erase()` Javadoc — remove "null domain erases across ALL domains" (now handled by `eraseEntity()`) |
| `platform/.../NoOpCaseMemoryStore.java` | add `eraseEntity()` no-op override |
| `platform/.../ReactiveCaseMemoryStore.java` | add `eraseEntity()` default-fail |
| `platform/.../BlockingToReactiveBridge.java` | add `eraseEntity()` blocking wrapper |
| `platform-api/test/.../CaseMemoryStoreSpiTest.java` | add `eraseEntity()` test (default-throw path); update all `EraseRequest` usages to non-null domain |
| `platform/test/.../NoOpCaseMemoryStoreTest.java` | **Remove** `ERASE_ALL_DOMAINS` static fixture and the tests that use it (`erase_allDomains_doesNotThrow`, `bridge_erase_allDomains_doesNotThrow`) — these tested null-domain erase which is now `eraseEntity()`. Add `eraseEntity_doesNotThrow` and `bridge_eraseEntity_doesNotThrow` in their place. |

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
- `jandex-maven-plugin` — required for CDI bean discovery when consumed as a JAR by another module
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
- compile deps: `casehub-platform-api`, `quarkus-hibernate-orm-panache`, `quarkus-flyway`
- `quarkus-jdbc-postgresql` — declared with `<optional>true</optional>`; consumers must add
  their own JDBC driver (postgresql or h2); the optional flag means it does not transitively
  propagate to consumers
- test deps: `casehub-platform` (verify no-op displacement), `quarkus-jdbc-h2`, `quarkus-junit`
- **`casehub-platform-memory-inmem` is NOT in test deps** — see §9.3
- plugins: `quarkus-maven-plugin` with `build` goal, `jandex-maven-plugin`

### 3.3 Root pom.xml

Add `<module>memory-inmem</module>` and `<module>memory-jpa</module>`.

---

## 4. CDI Resolution — Precedence and Priority

**CDI resolution order (highest wins):**

| Module | CDI annotation | Beats |
|--------|---------------|-------|
| `memory-inmem/` | `@Alternative @Priority(1) @ApplicationScoped` | JPA, no-op |
| `memory-jpa/` | `@ApplicationScoped` | no-op only |
| `platform/` | `@DefaultBean @ApplicationScoped` | nothing |

`@Alternative @Priority(1)` (InMem) wins over plain `@ApplicationScoped` (JPA). When both are
on the classpath, InMem is active. **Tier numbers below refer to capability level, not CDI
precedence.** A lower tier number means simpler capability, not lower CDI priority.

| Capability tier | Module | Use case |
|----------------|--------|---------|
| 0 (no-op) | `platform/` | Nothing installed |
| 0.5 (ephemeral) | `memory-inmem/` | Tests, demos — always add as test/provided scope |
| 1 (durable, non-semantic) | `memory-jpa/` | Standard production deployment |
| 2 (semantic) | `memory-mem0/` (future) | Vector recall quality matters |
| 3 (temporal) | `memory-graphiti/` (future) | Temporal reasoning required |

**Priority conflict — startup-breaking:** `memory-inmem/` and future `memory-mem0/` cannot both
be `@Alternative @Priority(1)` for the same type — Quarkus ARC throws
`AmbiguousResolutionException` at startup. Resolution must be chosen before implementing mem0:
either demote `memory-inmem/` to test-scope-only convention (documented, enforced by policy
rather than priority), or assign it a separate lower priority that is always dominated by real
adapters. Tracked in #39.

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
  as standard JSON object (`{"key":"value"}`) using Jackson `ObjectMapper` (available
  transitively via Quarkus); deserialized on read via `ObjectMapper.readValue()`
- No `tsvector` column — FTS computed at query time over the pre-filtered small corpus;
  a GIN index is not justified given the mandatory tenant/entity/domain predicates
- `memory_entry_erase_idx` covers `eraseEntity()` (`WHERE tenant_id=? AND entity_id=?`)

**Consumer Flyway config:**
```properties
# Add db/memory/migration alongside all existing locations — do not replace them
quarkus.flyway.locations=classpath:db/memory/migration,classpath:db/your-existing/migration,...
```

---

## 6. `MemoryEntry` Entity

**Package:** `io.casehub.platform.memory.jpa`

```java
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
    public String domain;      // MemoryDomain.name() — stored as plain string

    @Column(name = "case_id")
    public String caseId;      // nullable

    @Column(name = "text", nullable = false, columnDefinition = "TEXT")
    public String text;

    @Column(name = "attributes", nullable = false, columnDefinition = "TEXT")
    public String attributes;  // JSON string — serialized Map<String,String>

    @Column(name = "created_at", nullable = false)
    public Instant createdAt;
}
```

`domain` is stored as `String` (the `MemoryDomain` name), not as an embedded value type —
avoids JPA embeddable complexity for a single-field wrapper. Reconstructed as
`new MemoryDomain(entry.domain)` when building `Memory` return values.

---

## 7. `InMemoryMemoryStore`

**Package:** `io.casehub.platform.memory.inmem`

**CDI:** `@Alternative @Priority(1) @ApplicationScoped`

**Storage:** `ConcurrentHashMap<BucketKey, CopyOnWriteArrayList<Memory>>`

### 7.1 `BucketKey` record

```java
record BucketKey(String tenantId, String entityId, MemoryDomain domain) {}
```

Typed record key — no string manipulation, no separator-collision risk from values containing
`|`. Equality and hashing are structural. `eraseEntity()` filters by:

```java
store.keySet().removeIf(k -> k.tenantId().equals(tenantId) && k.entityId().equals(entityId));
```

### 7.2 Constructor injection

Single `@Inject` constructor accepting `CurrentPrincipal` — enables pure JUnit 5 tests without
a CDI container.

### 7.3 Method semantics

| Method | Behaviour |
|--------|-----------|
| `store()` | asserts tenant; UUID.randomUUID(); adds to bucket |
| `query()` | asserts tenant; streams bucket; filters caseId; filters since; **if question non-null**, filters via `text.toLowerCase().contains(question.toLowerCase())` — explicit null-guard: skip filter when question is null; sorts DESC; limits |
| `erase()` | asserts tenant; removes from bucket where caseId matches (or all entries if caseId null) |
| `eraseById()` | asserts tenant; scans all buckets where `key.tenantId().equals(tenantId)`; removes matching memoryId |
| `eraseEntity()` | asserts tenant; `keySet().removeIf(k -> k.tenantId().equals(tenantId) && k.entityId().equals(entityId))` |

**Note on question matching:** simple `contains()`, not real FTS. Callers expecting relevance
ranking should use `memory-jpa/` (PostgreSQL FTS) or higher tiers.

---

## 8. `JpaMemoryStore`

**Package:** `io.casehub.platform.memory.jpa`

**CDI:** `@ApplicationScoped`

**Injects:** `CurrentPrincipal`, `MemoryJpaConfig`

### 8.1 `MemoryJpaConfig` — nested interface

```java
@ConfigMapping(prefix = "casehub.memory.jpa")
interface MemoryJpaConfig {
    Fts fts();

    interface Fts {
        @WithDefault("true")
        boolean enabled();

        @WithDefault("english")
        String language();
    }
}
```

Config keys: `casehub.memory.jpa.fts.enabled` (default `true`),
`casehub.memory.jpa.fts.language` (default `english`). Nested interface — no `@WithName`
annotations required; SmallRye maps `fts().enabled()` to `casehub.memory.jpa.fts.enabled`
naturally.

Valid `language` values: any PostgreSQL text search configuration name (`english`, `french`,
`german`, `spanish`, etc.). Validated by PostgreSQL at query time — invalid values produce
a `PSQLException`, not a silent wrong result.

### 8.2 Transaction boundaries

All annotations are `jakarta.transaction.Transactional` applied at method level.

| Method | `@Transactional` |
|--------|-----------------|
| `store()` | `TxType.REQUIRED` |
| `query()` | `TxType.SUPPORTS` |
| `erase()` | `TxType.REQUIRED` |
| `eraseById()` | `TxType.REQUIRED` |
| `eraseEntity()` | `TxType.REQUIRED` |

### 8.3 `store()`

1. `MemoryPermissions.assertTenant(input.tenantId(), principal)`
2. Assign `memoryId = UUID.randomUUID().toString()`
3. Set `createdAt = Instant.now()`
4. Serialize `attributes` as JSON: `objectMapper.writeValueAsString(input.attributes())`
5. `MemoryEntry.persist(entry)`
6. Return `memoryId`

`ObjectMapper` is injected as a CDI bean (available via `quarkus-jackson`; add as compile dep
if not already transitive).

### 8.4 `query()` — two paths

**Chronological** (JPQL, H2-compatible):
```
WHERE tenantId = :t AND entityId = :e AND domain = :d
  AND (:caseId IS NULL OR caseId = :caseId)
  AND (:since IS NULL OR createdAt >= :since)
ORDER BY createdAt DESC
```

**FTS** (native SQL, PostgreSQL only — when `fts().enabled()=true` AND `question != null`):
```sql
SELECT * FROM memory_entry
WHERE tenant_id = :t AND entity_id = :e AND domain = :d
  AND to_tsvector(CAST(:lang AS regconfig), text)
      @@ websearch_to_tsquery(CAST(:lang AS regconfig), :question)
  AND (:caseId IS NULL OR case_id = :caseId)
  AND (:since IS NULL OR created_at >= :since)
ORDER BY ts_rank(
    to_tsvector(CAST(:lang AS regconfig), text),
    websearch_to_tsquery(CAST(:lang AS regconfig), :question)
) DESC
LIMIT :limit
```

`CAST(:lang AS regconfig)` — named parameter, not concatenation. PostgreSQL validates
the cast against known text search configs.

**Result mapping:** `entityManager.createNativeQuery(sql, MemoryEntry.class)` with named
parameters — Hibernate maps result columns to `MemoryEntry` fields by column name. `MemoryEntry`
is then mapped to `Memory` records in the adapter (deserializing attributes, reconstructing
`MemoryDomain`).

### 8.5 `erase()` (domain-scoped)

```sql
DELETE FROM memory_entry
WHERE tenant_id = :t AND entity_id = :e AND domain = :d
  AND (:caseId IS NULL OR case_id = :caseId)
```

Domain is always non-null — no null-domain handling.

### 8.6 `eraseById()`

```sql
DELETE FROM memory_entry
WHERE memory_id = :id AND tenant_id = :t
```

`tenant_id` in the WHERE clause: structural defence-in-depth alongside the `assertTenant`
check. Cross-tenant deletion is architecturally impossible even if a UUID is guessed.

### 8.7 `eraseEntity()` (GDPR full-entity wipe)

```sql
DELETE FROM memory_entry
WHERE tenant_id = :t AND entity_id = :e
```

Uses `memory_entry_erase_idx`. No domain predicate — wipes all domains atomically.

---

## 9. Permission Enforcement Contract

All adapter methods — both `JpaMemoryStore` and `InMemoryMemoryStore` — MUST call
`MemoryPermissions.assertTenant(tenantId, currentPrincipal)` as the first operation, before
any backend call.

Tenant isolation is structural: `tenant_id` is a mandatory `NOT NULL` column and every
query includes `WHERE tenant_id = :tenantId` as a non-optional predicate. Cross-tenant
retrieval is architecturally impossible, not just policy-filtered.

---

## 10. Testing Strategy

### 10.1 SPI / NoOp tests (existing modules, updated)

- `CaseMemoryStoreSpiTest` — add test for `eraseEntity()` default-throw path (same pattern as
  `eraseById_defaultThrows`); update all `EraseRequest` usages to non-null domain
- `NoOpCaseMemoryStoreTest` — **remove** `ERASE_ALL_DOMAINS` static fixture and tests
  `erase_allDomains_doesNotThrow` / `bridge_erase_allDomains_doesNotThrow` (null domain no
  longer exists); **add** `eraseEntity_doesNotThrow` and `bridge_eraseEntity_doesNotThrow`

### 10.2 `InMemoryMemoryStoreTest` (pure JUnit 5)

No `@QuarkusTest`. Instantiate via constructor with an anonymous `CurrentPrincipal`:

```java
CurrentPrincipal principal = new CurrentPrincipal() {
    @Override public String tenancyId() { return "tenant-1"; }
    // ... remaining methods
};
InMemoryMemoryStore sut = new InMemoryMemoryStore(principal);
```

Covers the full contract: all methods, tenant isolation, domain isolation, caseId filter,
since filter, limit, eraseEntity cross-domain, eraseEntity tenant boundary.

### 10.3 `JpaMemoryStoreTest` (`@QuarkusTest` + H2)

**`memory-inmem/` is NOT in `memory-jpa/` test deps.** Adding it would cause
`InMemoryMemoryStore @Alternative @Priority(1)` to displace `JpaMemoryStore @ApplicationScoped`
in every `@QuarkusTest`, meaning all tests would run against the wrong implementation.

Instead: where `CaseMemoryStore` injection is needed, inject `JpaMemoryStore` directly as the
concrete type to avoid CDI ambiguity.

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
| `eraseEntity_doesNotCrossTenantBoundary` | most destructive op cannot cross tenant lines |
| `assertTenant_mismatch_throws` | security gate fires before backend |
| `store_displaces_noOp` | inject `JpaMemoryStore` directly — confirms `NoOpCaseMemoryStore @DefaultBean` is not active when JPA is on classpath |

FTS integration tests (PostgreSQL Testcontainers) deferred — tracked in #38.

---

## 11. Consumer Integration

### Activating `memory-jpa/`

```xml
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-platform-memory-jpa</artifactId>
    <version>${casehub-platform.version}</version>
</dependency>
<!-- Add your JDBC driver — memory-jpa declares postgresql as optional -->
<dependency>
    <groupId>io.quarkus</groupId>
    <artifactId>quarkus-jdbc-postgresql</artifactId>
</dependency>
```

```properties
# Add to existing locations — do not replace them
quarkus.flyway.locations=classpath:db/memory/migration,<existing locations>
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
`JpaMemoryStore` when on the classpath. **Do not add alongside `memory-jpa/` in production
scope** — `@Priority(1)` wins and the JPA adapter will be inactive.

---

## 12. Deferred Items

| Issue | Description |
|-------|-------------|
| #37 | `memory-sqlite/` — SQLite adapter for durable pure-Java deployments |
| #38 | FTS Testcontainers integration test for `memory-jpa/` |
| #39 | CDI priority revisit when `memory-mem0/` arrives — `@Priority(1)` conflict is startup-breaking |
| #40 | `memory-memori/` REST adapter — pending Memori API stabilisation |
| casehubio/parent#90 | PLATFORM.md update — memory adapters now in-platform |
