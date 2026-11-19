# Credential Resolution + Rotation for StaticCredentialStore — Design Spec

**Issue:** casehubio/platform#900
**Date:** 2026-11-19
**Status:** Draft

## Problem

`StaticCredentialStore` (shipped platform#548) stores credentials by `(actorId, provider, tenancyId)` for outbound credential management. The auth path needs to go the other direction: given an API key presented in an HTTP request, resolve it to the identity that owns it. The current SPI has no `lookup(credential)`, no credential state, no rotation with grace period, and stores credentials in plaintext.

## Scope

Add to `StaticCredentialStore`:

1. **`lookup(credential)`** — resolve an inbound credential to its owner identity
2. **`CredentialState`** — ACTIVE / GRACE_PERIOD / REVOKED lifecycle
3. **`rotate()`** — create a new credential while the old one remains valid for a configurable TTL
4. **`revoke()`** — immediate credential invalidation for security incidents
5. **Hashed storage** — SHA-256 in JPA, constant-time comparison
6. **Concurrency safety** — partial unique indexes + row-level locking for rotation

## SPI Changes — `StaticCredentialStore`

Three new default methods added to the existing interface:

```java
public interface StaticCredentialStore {
    // existing methods unchanged
    void store(StaticCredentialRecord record);
    Optional<StaticCredentialRecord> find(String actorId, String provider, String tenancyId);
    List<StaticCredentialRecord> findAll(String actorId, String tenancyId);
    void delete(String actorId, String provider, String tenancyId);

    // new methods
    default Optional<StaticCredentialRecord> lookup(String credential) {
        return Optional.empty();
    }

    default StaticCredentialRecord rotate(String actorId, String provider,
            String tenancyId, String newCredential) {
        throw new UnsupportedOperationException("rotate not supported");
    }

    default void revoke(String actorId, String provider, String tenancyId) {
        throw new UnsupportedOperationException("revoke not supported");
    }
}
```

**Naming:** `lookup` (not `resolve`) to avoid collision with `CredentialResolver.resolve(String credentialRef)` in the same module. Matches `WorkerCredentialStore.lookup(String token)`.

**Default behaviors:** `lookup()` returns empty (safe no-op). `rotate()` and `revoke()` throw `UnsupportedOperationException` per protocol PP-20260528-557f5c — revocation invalidates credential validity, same risk class as data erasure; silent no-op during a security incident is dangerous.

**Composite-key signatures:** Work because D6's invariant guarantees exactly one ACTIVE credential per `(actor, provider, tenant)`. `rotate()` targets the ACTIVE credential, marks it GRACE_PERIOD, inserts a new ACTIVE, and returns the new record. `revoke()` targets all non-REVOKED credentials for the tuple.

**Behavioral changes to existing methods:** `find()` returns only the ACTIVE credential. `findAll()` returns only ACTIVE credentials. This preserves backward compatibility — existing callers expect live credentials.

**`store()` semantics in the multi-row model:** `store()` performs upsert-by-composite-key with ACTIVE status. If an ACTIVE credential already exists for `(actorId, provider, tenancyId)`, it is replaced (same as current behavior). `store()` does NOT create GRACE_PERIOD or REVOKED rows — that is `rotate()`'s and `revoke()`'s job. Callers migrating from the old `store()`-to-rotate pattern get identical behavior.

**`delete()` semantics:** `delete()` removes ALL rows for the `(actorId, provider, tenancyId)` tuple — ACTIVE, GRACE_PERIOD, and REVOKED. This is a hard delete, not a state change. Use `revoke()` for security-incident invalidation with audit trail retention; use `delete()` only for complete credential removal (e.g., actor deprovisioning).

## `CredentialState` Enum

```java
package io.casehub.platform.api.authn;

public enum CredentialState {
    ACTIVE,
    GRACE_PERIOD,
    REVOKED
}
```

- **ACTIVE:** Current valid credential. At most one per `(actor, provider, tenant)`.
- **GRACE_PERIOD:** Old credential still accepted during rotation window. `expiresAt` is set. Transitions to effectively-expired when `expiresAt < now()` (no explicit state change needed — expiry is temporal).
- **REVOKED:** Explicitly invalidated. Terminal state. Retained for audit trail — never deleted.

## `StaticCredentialRecord` Evolution

```java
public record StaticCredentialRecord(
    String actorId,
    String tenancyId,
    String provider,
    String credential,      // nullable on read (raw credential not persisted after hashing)
    CredentialType type,
    Instant createdAt,
    Instant updatedAt,
    CredentialState state,   // new — defaults to ACTIVE
    Instant expiresAt        // new — nullable (null = no expiry)
) {
    public StaticCredentialRecord {
        Objects.requireNonNull(actorId, "actorId");
        Objects.requireNonNull(tenancyId, "tenancyId");
        Objects.requireNonNull(provider, "provider");
        Objects.requireNonNull(type, "type");
        if (state == null) state = CredentialState.ACTIVE;
    }

    // backward-compatible constructor — existing call sites compile unchanged
    public StaticCredentialRecord(String actorId, String tenancyId, String provider,
            String credential, CredentialType type, Instant createdAt, Instant updatedAt) {
        this(actorId, tenancyId, provider, credential, type, createdAt, updatedAt,
                CredentialState.ACTIVE, null);
    }

    public boolean isExpired() {
        return expiresAt != null && Instant.now().isAfter(expiresAt);
    }
}
```

**Key changes:**
- `credential` is no longer `requireNonNull` — it is write-only: populated on `store()`, null on read from JPA (raw credential not persisted after hashing). Validation moves to `store()` implementations.
- No surrogate `id` on the domain record — `id` is a persistence concern internal to the JPA entity; composite-key signatures (D2) plus the ACTIVE invariant (D6) unambiguously identify targets.
- `isExpired()` convenience method matches `WorkerCredential.isExpired()` pattern.

## Data Model — JPA Entity

```java
@Entity
@Table(name = "authn_static_credential")
public class StaticCredentialEntity {

    @Id
    @Column(nullable = false, length = 36)
    public String id;           // UUIDv7

    @Column(name = "actor_id", nullable = false)
    public String actorId;

    @Column(nullable = false, length = 255)
    public String provider;

    @Column(name = "tenancy_id", nullable = false)
    public String tenancyId;

    @Column(name = "credential_hash", nullable = false, length = 64)
    public String credentialHash;   // SHA-256 hex

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 50)
    public CredentialType type;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 20)
    public CredentialState status;

    @Column(name = "created_at", nullable = false)
    public Instant createdAt;

    @Column(name = "updated_at", nullable = false)
    public Instant updatedAt;

    @Column(name = "expires_at")
    public Instant expiresAt;
}
```

**Dropped:** The `credential` TEXT column is removed — only the hash is stored. The old composite PK `(actor_id, provider, tenancy_id)` is replaced by a surrogate `id` column.

**`@IdClass` removed:** `StaticCredentialId` is no longer needed. Direct `em.find()` by `String id`. Existing find-by-composite uses JPQL queries.

## Flyway Migration — V3

```sql
-- V3__credential_resolution_rotation.sql

-- Step 1: Add new columns
ALTER TABLE authn_static_credential
    ADD COLUMN id VARCHAR(36),
    ADD COLUMN credential_hash VARCHAR(64),
    ADD COLUMN status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
    ADD COLUMN expires_at TIMESTAMP;

-- Step 2: Backfill id (UUIDv7 via application-level migration, not gen_random_uuid())
-- and credential_hash. The backfill runs as a Java-based Flyway migration (V3.1)
-- to use UUIDv7 and to avoid logging raw credential values in SQL statement logs.
-- V3 handles DDL only; V3.1 handles data backfill in Java.

-- Step 3: Make id non-null and primary key (runs after V3.1 backfill)
ALTER TABLE authn_static_credential ALTER COLUMN id SET NOT NULL;
ALTER TABLE authn_static_credential ALTER COLUMN credential_hash SET NOT NULL;
ALTER TABLE authn_static_credential DROP CONSTRAINT authn_static_credential_pkey;
ALTER TABLE authn_static_credential ADD PRIMARY KEY (id);

-- Step 4: Drop raw credential column
ALTER TABLE authn_static_credential DROP COLUMN credential;

-- Step 5: Indexes
CREATE INDEX idx_static_cred_hash ON authn_static_credential(credential_hash);
CREATE INDEX idx_static_cred_actor ON authn_static_credential(actor_id, provider, tenancy_id);
CREATE UNIQUE INDEX idx_static_cred_active
    ON authn_static_credential(actor_id, provider, tenancy_id) WHERE status = 'ACTIVE';
CREATE UNIQUE INDEX idx_static_cred_grace
    ON authn_static_credential(actor_id, provider, tenancy_id) WHERE status = 'GRACE_PERIOD';
```

**Migration is split:** V3 (SQL) handles DDL — column additions, PK change, indexes. V3.1 (Java-based Flyway migration) handles data backfill — generates UUIDv7 IDs and computes SHA-256 hashes in Java, avoiding both `gen_random_uuid()` (which produces v4, not v7) and raw credential exposure in PostgreSQL statement logs.

**H2 test compatibility:** Partial unique indexes (`WHERE status = ...`) are PostgreSQL-specific. For H2 tests, the application-level enforcement via `SELECT FOR UPDATE` within `@Transactional rotate()` provides the same invariant. This is consistent with existing Flyway conventions in the codebase (PostgreSQL-specific features are allowed with H2 compatibility noted).

**Partial unique indexes** enforce at-most-one ACTIVE and at-most-one GRACE_PERIOD credential per `(actor, provider, tenant)` at the database level.

## Hashing Strategy

Hashing is a store implementation concern, not an SPI concern.

**JPA implementation:**
- `store()` computes `SHA-256(record.credential())` → hex string → `credential_hash` column
- `lookup(rawCredential)` computes `SHA-256(rawCredential)` → queries `WHERE credential_hash = ? AND status IN ('ACTIVE', 'GRACE_PERIOD') AND (expires_at IS NULL OR expires_at > NOW())`
- No additional constant-time comparison needed in JPA — the DB query is an equality check on the hash, and SHA-256 collision probability is negligible (2^-128). The DB query timing is dominated by I/O, not comparison.
- `find()`/`findAll()` return records with `credential = null` — the raw credential cannot be reconstructed

**In-memory implementation:**
- Stores raw credentials (test/ephemeral use only)
- `lookup()` iterates values, uses `MessageDigest.isEqual()` for constant-time comparison on raw credential bytes
- `find()`/`findAll()` return records with the raw credential (test convenience)

**Entropy assumption:** All credential types (API_KEY, BOT_TOKEN, PERSONAL_ACCESS_TOKEN) have 128+ bits of entropy. SHA-256 is appropriate — brute-force is infeasible. If low-entropy types are added, the hashing boundary allows algorithm changes without SPI impact.

## Rotation Flow

```
rotate("actor1", "google-maps", "tenant1", "new-key-xyz")
  1. Find ACTIVE credential for (actor1, google-maps, tenant1)
  2. SELECT ... FOR UPDATE (row-level lock prevents concurrent rotation)
  3. Mark existing ACTIVE → GRACE_PERIOD, set expiresAt = now() + gracePeriodTtl
  4. Insert new ACTIVE credential with new-key-xyz
  5. Return new StaticCredentialRecord
```

**Grace period TTL:** Configured via `@ConfigProperty(name = "casehub.authn.credential.grace-period-ttl", defaultValue = "PT24H")` on JPA store implementations. In-memory store accepts TTL via constructor.

**Rotation during grace period:** If a GRACE_PERIOD credential already exists when rotation occurs, it is immediately revoked (marked REVOKED) before the current ACTIVE is moved to GRACE_PERIOD. Only one GRACE_PERIOD credential exists at any time (enforced by partial unique index).

## Revocation Flow

```
revoke("actor1", "google-maps", "tenant1")
  1. Find all non-REVOKED credentials for (actor1, google-maps, tenant1)
  2. Mark all as REVOKED, set updatedAt = now()
  3. Credentials retained for audit trail
```

Both ACTIVE and GRACE_PERIOD credentials are revoked — this is a security operation.

## Implementation Changes by Module

| Module | Changes |
|--------|---------|
| `platform-api` | Add `CredentialState` enum, update `StaticCredentialRecord` (new fields, nullable credential, backward-compat constructor, `isExpired()`), add `lookup()`/`rotate()`/`revoke()` default methods to `StaticCredentialStore` |
| `platform` | Update `NoOpStaticCredentialStore` — override `revoke()` with empty body (no-op is safe for NoOp since there's nothing to revoke) |
| `authn-inmem` | Update `InMemoryStaticCredentialStore` — implement `lookup()` with constant-time comparison, `rotate()` with configurable TTL, `revoke()`. Add secondary index (credential → record) for O(1) lookup |
| `authn-social-jpa-common` | Update `StaticCredentialEntity` — add `id`, `credentialHash`, `status`, `expiresAt` fields. Remove `@IdClass`. Update `fromRecord()`/`toRecord()` mappers. Remove `StaticCredentialId` class |
| `authn-social-jpa` | Update `JpaStaticCredentialStore` — implement `lookup()` with SHA-256 hash query + constant-time comparison, `rotate()` with `SELECT FOR UPDATE` + grace period TTL config, `revoke()`. Update `find()`/`findAll()` to filter by ACTIVE status. Add V3 Flyway migration |
| `authn-social-spring-jpa` | Update `SpringStaticCredentialStore` — implement all new methods. Update `StaticCredentialRepository` — add new query methods. Update `SocialJpaAutoConfiguration` if needed |

## NoOpStaticCredentialStore

```java
@DefaultBean
@ApplicationScoped
public class NoOpStaticCredentialStore implements StaticCredentialStore {
    // existing no-op methods unchanged

    @Override
    public void revoke(String actorId, String provider, String tenancyId) {
        // no-op — nothing to revoke in a no-op store
    }
}
```

`lookup()` inherits the default `Optional.empty()`. `rotate()` inherits the default throw — this is correct for NoOp since rotation without storage is meaningless.

## Test Plan

**Unit tests for `InMemoryStaticCredentialStore` (new methods):**
- `lookup` finds stored credential by raw value
- `lookup` returns empty for unknown credential
- `lookup` uses constant-time comparison (not directly testable, but code review)
- `lookup` does not return REVOKED credentials
- `lookup` does not return expired GRACE_PERIOD credentials
- `rotate` creates new ACTIVE, moves old to GRACE_PERIOD
- `rotate` with existing GRACE_PERIOD revokes it first
- `rotate` returns new credential record
- `revoke` marks all non-REVOKED credentials as REVOKED
- `revoke` on non-existent credential is no-op (nothing to revoke)
- `find` returns only ACTIVE credential
- `findAll` returns only ACTIVE credentials
- Backward compatibility: existing tests pass unchanged (7-arg constructor, store/find/delete flows)

**Unit tests for JPA store (integration):**
- Same behavioral tests as in-memory, against real DB
- `credential()` returns null on records retrieved via `find()`/`findAll()`
- Partial unique index violation on duplicate ACTIVE (expect constraint exception)
- Concurrent rotation safety (two threads rotating same credential)

**Contract tests (per PP-20260601-81b9e5):**
- Shared test interface exercising all 7 methods across all implementations

## Out of Scope

- **Grace period cleanup scheduler** — expired GRACE_PERIOD credentials remain in GRACE_PERIOD state; `lookup()` checks `expiresAt` at query time. A background purge can be added later but is not required for correctness.
- **Admin/audit API** — querying non-ACTIVE credentials (REVOKED, expired GRACE_PERIOD) is not part of this issue. A dedicated method can be added when that need arises.
- **Credential generation** — the caller provides the new credential value to `rotate()`. Platform doesn't generate credentials.
- **Spring generator** — the Spring JPA implementation is updated manually (hand-written, not generated).
- **Simulation decorator** — `StaticCredentialStore` is not currently `@SimulationEligible`. Adding simulation support is a separate concern.

## CLAUDE.md Updates

After implementation, update the `authn-social-jpa-common` and `authn-social-jpa` module descriptions to mention credential hashing, rotation, and the V3 migration.

## References

- `platform-api/.../authn/StaticCredentialStore.java` — existing SPI
- `platform-api/.../authn/StaticCredentialRecord.java` — existing record
- `platform-api/.../authn/CredentialType.java` — existing enum
- `platform-api/.../acl/WorkerCredentialStore.java` — `lookup()` naming, default method pattern
- `platform-api/.../acl/WorkerCredential.java` — `isExpired()` pattern
- `platform-api/.../credentials/CredentialResolver.java` — naming collision avoided (`resolve` → `lookup`)
- `authn-social-jpa-common/.../StaticCredentialEntity.java` — entity to modify
- `authn-social-jpa/.../V2__add_static_credentials.sql` — existing schema
- `specs/issue-103-credential-resolution/` — complementary outbound credential resolution spec
- PP-20260528-557f5c — spi-deletion-default-throws protocol
- PP-20260601-81b9e5 — spi-evolution-default-methods protocol
- casehubio/platform#548 — original StaticCredentialStore delivery
