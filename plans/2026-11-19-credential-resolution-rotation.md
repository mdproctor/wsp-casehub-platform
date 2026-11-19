# Credential Resolution + Rotation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #900 — credential resolution + rotation for StaticCredentialStore
**Issue group:** #900

**Goal:** Extend `StaticCredentialStore` with inbound credential lookup, state lifecycle (ACTIVE/GRACE_PERIOD/REVOKED), rotation with grace period, revocation, and hashed storage.

**Architecture:** Add `CredentialState` enum and new fields to `StaticCredentialRecord` (backward-compatible). Add `lookup()`/`rotate()`/`revoke()` default methods to `StaticCredentialStore`. Hashing is a store-implementation concern — JPA stores SHA-256 hashes, in-memory stores raw values. Surrogate UUID PK replaces composite PK to support multiple rows per (actor, provider, tenant).

**Tech Stack:** Java 21, Quarkus (CDI), Hibernate ORM, Flyway, Spring Data JPA, JUnit 5, AssertJ

## Global Constraints

- `platform-api/` must remain zero-dependency — pure Java only
- `CredentialState` enum goes in `io.casehub.platform.api.authn` (same package as existing types)
- Use `UUIDv7` from `io.casehub.platform.api.util.UUIDv7` for surrogate IDs
- SHA-256 via `java.security.MessageDigest` — no external crypto dependency
- Constant-time comparison via `java.security.MessageDigest.isEqual()`
- Next Flyway version for `authn-social` is V3
- Grace period TTL config key: `casehub.authn.credential.grace-period-ttl` (default `PT24H`)

---

## Batch 1: SPI Foundation — CredentialState, Record, Store interface

### Task 1: Add CredentialState enum and update StaticCredentialRecord

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/authn/CredentialState.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/authn/StaticCredentialRecord.java`
- Test: `platform-api/src/test/java/io/casehub/platform/api/authn/StaticCredentialRecordTest.java`

**Interfaces:**
- Produces: `CredentialState` enum (ACTIVE, GRACE_PERIOD, REVOKED), updated `StaticCredentialRecord` with 9-arg canonical constructor, 7-arg backward-compatible constructor, `isExpired()` method

- [ ] **Step 1: Write failing tests for the updated record**

```java
package io.casehub.platform.api.authn;

import org.junit.jupiter.api.Test;
import java.time.Instant;
import static org.assertj.core.api.Assertions.*;

class StaticCredentialRecordTest {

    @Test
    void backwardCompatibleConstructorDefaultsToActive() {
        var record = new StaticCredentialRecord(
                "actor1", "tenant1", "provider1",
                "cred", CredentialType.API_KEY,
                Instant.now(), Instant.now());
        assertThat(record.state()).isEqualTo(CredentialState.ACTIVE);
        assertThat(record.expiresAt()).isNull();
    }

    @Test
    void canonicalConstructorDefaultsNullStateToActive() {
        var record = new StaticCredentialRecord(
                "actor1", "tenant1", "provider1",
                "cred", CredentialType.API_KEY,
                Instant.now(), Instant.now(), null, null);
        assertThat(record.state()).isEqualTo(CredentialState.ACTIVE);
    }

    @Test
    void credentialIsNullable() {
        var record = new StaticCredentialRecord(
                "actor1", "tenant1", "provider1",
                null, CredentialType.API_KEY,
                Instant.now(), Instant.now(),
                CredentialState.ACTIVE, null);
        assertThat(record.credential()).isNull();
    }

    @Test
    void isExpiredReturnsFalseWhenNoExpiry() {
        var record = new StaticCredentialRecord(
                "actor1", "tenant1", "provider1",
                "cred", CredentialType.API_KEY,
                Instant.now(), Instant.now(),
                CredentialState.GRACE_PERIOD, null);
        assertThat(record.isExpired()).isFalse();
    }

    @Test
    void isExpiredReturnsTrueWhenPastExpiry() {
        var record = new StaticCredentialRecord(
                "actor1", "tenant1", "provider1",
                "cred", CredentialType.API_KEY,
                Instant.now(), Instant.now(),
                CredentialState.GRACE_PERIOD,
                Instant.now().minusSeconds(60));
        assertThat(record.isExpired()).isTrue();
    }

    @Test
    void isExpiredReturnsFalseWhenBeforeExpiry() {
        var record = new StaticCredentialRecord(
                "actor1", "tenant1", "provider1",
                "cred", CredentialType.API_KEY,
                Instant.now(), Instant.now(),
                CredentialState.GRACE_PERIOD,
                Instant.now().plusSeconds(3600));
        assertThat(record.isExpired()).isFalse();
    }

    @Test
    void requiredFieldsRejectNull() {
        assertThatThrownBy(() -> new StaticCredentialRecord(
                null, "t", "p", "c", CredentialType.API_KEY,
                Instant.now(), Instant.now()))
                .isInstanceOf(NullPointerException.class);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl platform-api test -Dtest=StaticCredentialRecordTest --batch-mode -q`
Expected: Compilation failure — `CredentialState` does not exist, constructor mismatch

- [ ] **Step 3: Create CredentialState enum**

```java
package io.casehub.platform.api.authn;

public enum CredentialState {
    ACTIVE,
    GRACE_PERIOD,
    REVOKED
}
```

- [ ] **Step 4: Update StaticCredentialRecord**

Replace the entire record body with:

```java
package io.casehub.platform.api.authn;

import java.time.Instant;
import java.util.Objects;

public record StaticCredentialRecord(
    String actorId,
    String tenancyId,
    String provider,
    String credential,
    CredentialType type,
    Instant createdAt,
    Instant updatedAt,
    CredentialState state,
    Instant expiresAt
) {
    public StaticCredentialRecord {
        Objects.requireNonNull(actorId, "actorId");
        Objects.requireNonNull(tenancyId, "tenancyId");
        Objects.requireNonNull(provider, "provider");
        Objects.requireNonNull(type, "type");
        if (state == null) state = CredentialState.ACTIVE;
    }

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

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn -pl platform-api test -Dtest=StaticCredentialRecordTest --batch-mode -q`
Expected: All 7 tests PASS

- [ ] **Step 6: Verify backward compatibility — existing tests still compile and pass**

Run: `mvn -pl platform-api test --batch-mode -q`
Expected: All existing tests PASS (the 7-arg constructor preserves call-site compatibility)

- [ ] **Step 7: Commit**

```bash
git add platform-api/src/main/java/io/casehub/platform/api/authn/CredentialState.java
git add platform-api/src/main/java/io/casehub/platform/api/authn/StaticCredentialRecord.java
git add platform-api/src/test/java/io/casehub/platform/api/authn/StaticCredentialRecordTest.java
git commit -m "feat(#900): add CredentialState enum and update StaticCredentialRecord"
```

### Task 2: Add lookup/rotate/revoke default methods to StaticCredentialStore and update NoOp

**Files:**
- Modify: `platform-api/src/main/java/io/casehub/platform/api/authn/StaticCredentialStore.java`
- Modify: `platform/src/main/java/io/casehub/platform/authn/NoOpStaticCredentialStore.java`

**Interfaces:**
- Consumes: `CredentialState`, updated `StaticCredentialRecord` (from Task 1)
- Produces: `StaticCredentialStore.lookup(String)`, `.rotate(String,String,String,String)`, `.revoke(String,String,String)` default methods; `NoOpStaticCredentialStore.revoke()` override

- [ ] **Step 1: Add default methods to StaticCredentialStore**

Add after the existing `delete()` method:

```java
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
```

- [ ] **Step 2: Override revoke() in NoOpStaticCredentialStore**

Add to `NoOpStaticCredentialStore`:

```java
@Override
public void revoke(String actorId, String provider, String tenancyId) {}
```

- [ ] **Step 3: Verify compilation across dependent modules**

Run: `mvn -pl platform-api,platform,authn-inmem,authn-social-jpa,authn-social-spring-jpa compile --batch-mode -q`
Expected: All compile — existing implementations get default methods, NoOp overrides revoke

- [ ] **Step 4: Commit**

```bash
git add platform-api/src/main/java/io/casehub/platform/api/authn/StaticCredentialStore.java
git add platform/src/main/java/io/casehub/platform/authn/NoOpStaticCredentialStore.java
git commit -m "feat(#900): add lookup/rotate/revoke default methods to StaticCredentialStore"
```

## Batch 2: In-Memory Implementation

### Task 3: Implement InMemoryStaticCredentialStore with lookup, rotate, revoke

**Files:**
- Modify: `authn-inmem/src/main/java/io/casehub/platform/authn/inmem/InMemoryStaticCredentialStore.java`
- Modify: `authn-inmem/src/test/java/io/casehub/platform/authn/inmem/InMemoryStaticCredentialStoreTest.java`

**Interfaces:**
- Consumes: `StaticCredentialStore` (from Task 2), `CredentialState`, updated `StaticCredentialRecord` (from Task 1)
- Produces: Fully implemented `InMemoryStaticCredentialStore` with lookup/rotate/revoke, state-aware find/findAll

- [ ] **Step 1: Write failing tests for new functionality**

Add to `InMemoryStaticCredentialStoreTest`:

```java
@Test
void lookupFindsStoredCredential() {
    store.store(new StaticCredentialRecord(
            "actor1", "tenant1", "google-maps",
            "AIza-fake-key", CredentialType.API_KEY,
            Instant.now(), Instant.now()));

    var found = store.lookup("AIza-fake-key");
    assertThat(found).isPresent();
    assertThat(found.get().actorId()).isEqualTo("actor1");
}

@Test
void lookupReturnsEmptyForUnknown() {
    assertThat(store.lookup("nonexistent")).isEmpty();
}

@Test
void lookupDoesNotReturnRevokedCredentials() {
    store.store(new StaticCredentialRecord(
            "actor1", "tenant1", "slack",
            "token-1", CredentialType.BOT_TOKEN,
            Instant.now(), Instant.now()));
    store.revoke("actor1", "slack", "tenant1");

    assertThat(store.lookup("token-1")).isEmpty();
}

@Test
void lookupDoesNotReturnExpiredGracePeriodCredentials() {
    store.store(new StaticCredentialRecord(
            "actor1", "tenant1", "slack",
            "old-token", CredentialType.BOT_TOKEN,
            Instant.now(), Instant.now()));
    store.rotate("actor1", "slack", "tenant1", "new-token");

    // Find the grace period record and verify lookup behavior
    // The old token should still be found if within grace period
    assertThat(store.lookup("old-token")).isPresent();
    assertThat(store.lookup("new-token")).isPresent();
}

@Test
void rotateCreatesNewActiveAndMovesOldToGracePeriod() {
    store.store(new StaticCredentialRecord(
            "actor1", "tenant1", "google-maps",
            "old-key", CredentialType.API_KEY,
            Instant.now(), Instant.now()));

    var newRecord = store.rotate("actor1", "google-maps", "tenant1", "new-key");
    assertThat(newRecord.credential()).isEqualTo("new-key");
    assertThat(newRecord.state()).isEqualTo(CredentialState.ACTIVE);

    // find() returns only ACTIVE
    var active = store.find("actor1", "google-maps", "tenant1");
    assertThat(active).isPresent();
    assertThat(active.get().credential()).isEqualTo("new-key");
}

@Test
void rotateWithExistingGracePeriodRevokesIt() {
    store.store(new StaticCredentialRecord(
            "actor1", "tenant1", "slack",
            "key-v1", CredentialType.API_KEY,
            Instant.now(), Instant.now()));

    store.rotate("actor1", "slack", "tenant1", "key-v2");
    store.rotate("actor1", "slack", "tenant1", "key-v3");

    // key-v1 should now be REVOKED (was GRACE_PERIOD, then revoked on second rotation)
    assertThat(store.lookup("key-v1")).isEmpty();
    // key-v2 should be GRACE_PERIOD
    assertThat(store.lookup("key-v2")).isPresent();
    // key-v3 is ACTIVE
    assertThat(store.lookup("key-v3")).isPresent();
}

@Test
void revokeMarksAllNonRevokedAsRevoked() {
    store.store(new StaticCredentialRecord(
            "actor1", "tenant1", "slack",
            "key-v1", CredentialType.API_KEY,
            Instant.now(), Instant.now()));
    store.rotate("actor1", "slack", "tenant1", "key-v2");

    store.revoke("actor1", "slack", "tenant1");

    assertThat(store.lookup("key-v1")).isEmpty();
    assertThat(store.lookup("key-v2")).isEmpty();
    assertThat(store.find("actor1", "slack", "tenant1")).isEmpty();
}

@Test
void revokeOnNonExistentIsNoOp() {
    assertThatCode(() -> store.revoke("actor1", "slack", "tenant1"))
            .doesNotThrowException();
}

@Test
void findReturnsOnlyActiveCredential() {
    store.store(new StaticCredentialRecord(
            "actor1", "tenant1", "slack",
            "key-v1", CredentialType.API_KEY,
            Instant.now(), Instant.now()));
    store.rotate("actor1", "slack", "tenant1", "key-v2");

    var found = store.find("actor1", "slack", "tenant1");
    assertThat(found).isPresent();
    assertThat(found.get().credential()).isEqualTo("key-v2");
    assertThat(found.get().state()).isEqualTo(CredentialState.ACTIVE);
}

@Test
void findAllReturnsOnlyActiveCredentials() {
    store.store(new StaticCredentialRecord(
            "actor1", "tenant1", "google-maps",
            "key1", CredentialType.API_KEY, Instant.now(), Instant.now()));
    store.store(new StaticCredentialRecord(
            "actor1", "tenant1", "github",
            "ghp_fake", CredentialType.PERSONAL_ACCESS_TOKEN,
            Instant.now(), Instant.now()));

    // Rotate one — the old goes to GRACE_PERIOD
    store.rotate("actor1", "google-maps", "tenant1", "key2");

    var results = store.findAll("actor1", "tenant1");
    assertThat(results).hasSize(2);
    assertThat(results).allMatch(r -> r.state() == CredentialState.ACTIVE);
}

@Test
void deleteRemovesAllStatesForTuple() {
    store.store(new StaticCredentialRecord(
            "actor1", "tenant1", "slack",
            "key-v1", CredentialType.API_KEY,
            Instant.now(), Instant.now()));
    store.rotate("actor1", "slack", "tenant1", "key-v2");

    store.delete("actor1", "slack", "tenant1");

    assertThat(store.find("actor1", "slack", "tenant1")).isEmpty();
    assertThat(store.lookup("key-v1")).isEmpty();
    assertThat(store.lookup("key-v2")).isEmpty();
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl authn-inmem test -Dtest=InMemoryStaticCredentialStoreTest --batch-mode -q`
Expected: Compilation or runtime failures — new methods not yet implemented

- [ ] **Step 3: Implement InMemoryStaticCredentialStore**

Replace the full class body:

```java
package io.casehub.platform.authn.inmem;

import io.casehub.platform.api.authn.CredentialState;
import io.casehub.platform.api.authn.StaticCredentialRecord;
import io.casehub.platform.api.authn.StaticCredentialStore;

import java.security.MessageDigest;
import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;

public class InMemoryStaticCredentialStore implements StaticCredentialStore {

    private final ConcurrentHashMap<String, StaticCredentialRecord> store =
            new ConcurrentHashMap<>();
    private final Duration gracePeriodTtl;

    public InMemoryStaticCredentialStore() {
        this(Duration.ofHours(24));
    }

    public InMemoryStaticCredentialStore(Duration gracePeriodTtl) {
        this.gracePeriodTtl = gracePeriodTtl;
    }

    @Override
    public void store(StaticCredentialRecord record) {
        // Upsert by composite key — replace any existing ACTIVE for this tuple
        store.values().removeIf(r ->
                r.actorId().equals(record.actorId())
                && r.provider().equals(record.provider())
                && r.tenancyId().equals(record.tenancyId())
                && r.state() == CredentialState.ACTIVE);
        store.put(credKey(record.credential()), record);
    }

    @Override
    public Optional<StaticCredentialRecord> find(String actorId, String provider, String tenancyId) {
        return store.values().stream()
                .filter(r -> r.actorId().equals(actorId)
                        && r.provider().equals(provider)
                        && r.tenancyId().equals(tenancyId)
                        && r.state() == CredentialState.ACTIVE)
                .findFirst();
    }

    @Override
    public List<StaticCredentialRecord> findAll(String actorId, String tenancyId) {
        return store.values().stream()
                .filter(r -> r.actorId().equals(actorId)
                        && r.tenancyId().equals(tenancyId)
                        && r.state() == CredentialState.ACTIVE)
                .toList();
    }

    @Override
    public void delete(String actorId, String provider, String tenancyId) {
        store.values().removeIf(r ->
                r.actorId().equals(actorId)
                && r.provider().equals(provider)
                && r.tenancyId().equals(tenancyId));
    }

    @Override
    public Optional<StaticCredentialRecord> lookup(String credential) {
        byte[] inputBytes = credential.getBytes(java.nio.charset.StandardCharsets.UTF_8);
        return store.values().stream()
                .filter(r -> r.state() != CredentialState.REVOKED)
                .filter(r -> !r.isExpired())
                .filter(r -> MessageDigest.isEqual(
                        inputBytes,
                        r.credential().getBytes(java.nio.charset.StandardCharsets.UTF_8)))
                .findFirst();
    }

    @Override
    public StaticCredentialRecord rotate(String actorId, String provider,
            String tenancyId, String newCredential) {
        // Revoke any existing GRACE_PERIOD
        store.values().stream()
                .filter(r -> r.actorId().equals(actorId)
                        && r.provider().equals(provider)
                        && r.tenancyId().equals(tenancyId)
                        && r.state() == CredentialState.GRACE_PERIOD)
                .findFirst()
                .ifPresent(r -> store.put(credKey(r.credential()),
                        new StaticCredentialRecord(r.actorId(), r.tenancyId(), r.provider(),
                                r.credential(), r.type(), r.createdAt(), Instant.now(),
                                CredentialState.REVOKED, r.expiresAt())));

        // Move ACTIVE → GRACE_PERIOD
        var active = find(actorId, provider, tenancyId);
        if (active.isPresent()) {
            var old = active.get();
            var graced = new StaticCredentialRecord(old.actorId(), old.tenancyId(), old.provider(),
                    old.credential(), old.type(), old.createdAt(), Instant.now(),
                    CredentialState.GRACE_PERIOD, Instant.now().plus(gracePeriodTtl));
            store.put(credKey(old.credential()), graced);
        }

        // Insert new ACTIVE
        var now = Instant.now();
        var newRecord = new StaticCredentialRecord(actorId, tenancyId, provider,
                newCredential, active.map(StaticCredentialRecord::type).orElse(
                        io.casehub.platform.api.authn.CredentialType.API_KEY),
                now, now, CredentialState.ACTIVE, null);
        store.put(credKey(newCredential), newRecord);
        return newRecord;
    }

    @Override
    public void revoke(String actorId, String provider, String tenancyId) {
        store.replaceAll((key, r) -> {
            if (r.actorId().equals(actorId)
                    && r.provider().equals(provider)
                    && r.tenancyId().equals(tenancyId)
                    && r.state() != CredentialState.REVOKED) {
                return new StaticCredentialRecord(r.actorId(), r.tenancyId(), r.provider(),
                        r.credential(), r.type(), r.createdAt(), Instant.now(),
                        CredentialState.REVOKED, r.expiresAt());
            }
            return r;
        });
    }

    private static String credKey(String credential) {
        return "cred:" + credential;
    }
}
```

- [ ] **Step 4: Run all tests including existing ones**

Run: `mvn -pl authn-inmem test --batch-mode -q`
Expected: All tests PASS (existing + new)

- [ ] **Step 5: Run the E2E test in authn module to verify backward compatibility**

Run: `mvn -pl authn test -Dtest=ServiceConnectionE2ETest --batch-mode -q`
Expected: PASS — the 7-arg constructor and existing store/find/delete flows work

- [ ] **Step 6: Commit**

```bash
git add authn-inmem/src/main/java/io/casehub/platform/authn/inmem/InMemoryStaticCredentialStore.java
git add authn-inmem/src/test/java/io/casehub/platform/authn/inmem/InMemoryStaticCredentialStoreTest.java
git commit -m "feat(#900): implement lookup/rotate/revoke in InMemoryStaticCredentialStore"
```

## Batch 3: JPA Implementation — Entity, Migration, Store

### Task 4: Update JPA entity, migration, and JpaStaticCredentialStore

**Files:**
- Modify: `authn-social-jpa-common/src/main/java/io/casehub/platform/authn/social/jpa/StaticCredentialEntity.java`
- Delete: `authn-social-jpa-common/src/main/java/io/casehub/platform/authn/social/jpa/StaticCredentialId.java` (use `ide_refactor_safe_delete`)
- Create: `authn-social-jpa/src/main/resources/db/authn-social/migration/V3__credential_resolution_rotation.sql`
- Create: `authn-social-jpa/src/main/java/io/casehub/platform/authn/social/jpa/V3_1__BackfillCredentialHashes.java`
- Create: `authn-social-jpa-common/src/main/java/io/casehub/platform/authn/social/jpa/CredentialHasher.java`
- Modify: `authn-social-jpa/src/main/java/io/casehub/platform/authn/social/jpa/JpaStaticCredentialStore.java`

**Interfaces:**
- Consumes: `CredentialState`, updated `StaticCredentialRecord` (from Task 1), `StaticCredentialStore` new methods (from Task 2), `UUIDv7` from `io.casehub.platform.api.util.UUIDv7`
- Produces: Updated `StaticCredentialEntity` (surrogate UUID PK, credential_hash, status, expiresAt), `CredentialHasher` utility (in jpa-common, shared by Quarkus and Spring), V3/V3.1 migrations, fully implemented `JpaStaticCredentialStore`

- [ ] **Step 1: Create CredentialHasher utility in authn-social-jpa-common (shared by Quarkus and Spring)**

Create in `authn-social-jpa-common/src/main/java/io/casehub/platform/authn/social/jpa/CredentialHasher.java`:

```java
package io.casehub.platform.authn.social.jpa;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;

public final class CredentialHasher {

    private CredentialHasher() {}

    static String sha256Hex(String credential) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] hash = digest.digest(credential.getBytes(StandardCharsets.UTF_8));
            return HexFormat.of().formatHex(hash);
        } catch (NoSuchAlgorithmException e) {
            throw new AssertionError("SHA-256 not available", e);
        }
    }
}
```

- [ ] **Step 2: Update StaticCredentialEntity — replace composite PK with surrogate ID**

Replace the full entity class:

```java
package io.casehub.platform.authn.social.jpa;

import io.casehub.platform.api.authn.CredentialState;
import io.casehub.platform.api.authn.CredentialType;
import io.casehub.platform.api.authn.StaticCredentialRecord;
import io.casehub.platform.api.util.UUIDv7;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

import java.time.Instant;

@Entity
@Table(name = "authn_static_credential")
public class StaticCredentialEntity {

    @Id
    @Column(nullable = false, length = 36)
    public String id;

    @Column(name = "actor_id", nullable = false)
    public String actorId;

    @Column(nullable = false, length = 255)
    public String provider;

    @Column(name = "tenancy_id", nullable = false)
    public String tenancyId;

    @Column(name = "credential_hash", nullable = false, length = 64)
    public String credentialHash;

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

    public static StaticCredentialEntity fromRecord(StaticCredentialRecord record) {
        StaticCredentialEntity entity = new StaticCredentialEntity();
        entity.id = UUIDv7.randomUUID().toString();
        entity.actorId = record.actorId();
        entity.provider = record.provider();
        entity.tenancyId = record.tenancyId();
        entity.credentialHash = CredentialHasher.sha256Hex(record.credential());
        entity.type = record.type();
        entity.status = record.state();
        entity.createdAt = record.createdAt() != null ? record.createdAt() : Instant.now();
        entity.updatedAt = record.updatedAt() != null ? record.updatedAt() : Instant.now();
        entity.expiresAt = record.expiresAt();
        return entity;
    }

    public StaticCredentialRecord toRecord() {
        return new StaticCredentialRecord(
                actorId, tenancyId, provider,
                null, type, createdAt, updatedAt,
                status, expiresAt);
    }
}
```

- [ ] **Step 3: Delete StaticCredentialId (no longer needed)**

Use `ide_refactor_safe_delete` on `StaticCredentialId.java`. If references remain, update them first (JpaStaticCredentialStore.find() will use JPQL instead of `em.find()` with composite key).

- [ ] **Step 4: Create V3 SQL migration**

```sql
-- V3__credential_resolution_rotation.sql

ALTER TABLE authn_static_credential
    ADD COLUMN id VARCHAR(36),
    ADD COLUMN credential_hash VARCHAR(64),
    ADD COLUMN status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
    ADD COLUMN expires_at TIMESTAMP;
```

- [ ] **Step 5: Create V3.1 Java-based Flyway migration for data backfill**

```java
package io.casehub.platform.authn.social.jpa;

import io.casehub.platform.api.util.UUIDv7;
import org.flywaydb.core.api.migration.BaseJavaMigration;
import org.flywaydb.core.api.migration.Context;

import java.sql.PreparedStatement;
import java.sql.ResultSet;

public class V3_1__BackfillCredentialHashes extends BaseJavaMigration {

    @Override
    public void migrate(Context context) throws Exception {
        try (var select = context.getConnection().prepareStatement(
                "SELECT actor_id, provider, tenancy_id, credential FROM authn_static_credential WHERE id IS NULL");
             var update = context.getConnection().prepareStatement(
                "UPDATE authn_static_credential SET id = ?, credential_hash = ? " +
                "WHERE actor_id = ? AND provider = ? AND tenancy_id = ? AND id IS NULL")) {

            ResultSet rs = select.executeQuery();
            while (rs.next()) {
                String actorId = rs.getString("actor_id");
                String provider = rs.getString("provider");
                String tenancyId = rs.getString("tenancy_id");
                String credential = rs.getString("credential");

                update.setString(1, UUIDv7.randomUUID().toString());
                update.setString(2, CredentialHasher.sha256Hex(credential));
                update.setString(3, actorId);
                update.setString(4, provider);
                update.setString(5, tenancyId);
                update.addBatch();
            }
            update.executeBatch();
        }
    }
}
```

- [ ] **Step 6: Create V3.2 SQL migration for PK change and indexes**

```sql
-- V3_2__credential_pk_and_indexes.sql

ALTER TABLE authn_static_credential ALTER COLUMN id SET NOT NULL;
ALTER TABLE authn_static_credential ALTER COLUMN credential_hash SET NOT NULL;
ALTER TABLE authn_static_credential DROP CONSTRAINT authn_static_credential_pkey;
ALTER TABLE authn_static_credential ADD PRIMARY KEY (id);

ALTER TABLE authn_static_credential DROP COLUMN credential;

CREATE INDEX idx_static_cred_hash ON authn_static_credential(credential_hash);
CREATE INDEX idx_static_cred_actor ON authn_static_credential(actor_id, provider, tenancy_id);
```

Note: Partial unique indexes are PostgreSQL-only. Add them in a separate PostgreSQL-specific migration or as a manual production step. H2 tests rely on application-level enforcement.

- [ ] **Step 7: Implement JpaStaticCredentialStore with all new methods**

Replace the full class body:

```java
package io.casehub.platform.authn.social.jpa;

import io.casehub.platform.api.authn.CredentialState;
import io.casehub.platform.api.authn.StaticCredentialRecord;
import io.casehub.platform.api.authn.StaticCredentialStore;
import io.casehub.platform.api.util.UUIDv7;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import jakarta.transaction.Transactional;
import org.eclipse.microprofile.config.inject.ConfigProperty;

import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Optional;

@ApplicationScoped
public class JpaStaticCredentialStore implements StaticCredentialStore {

    @Inject
    EntityManager em;

    @ConfigProperty(name = "casehub.authn.credential.grace-period-ttl", defaultValue = "PT24H")
    Duration gracePeriodTtl;

    @Override
    @Transactional
    public void store(StaticCredentialRecord record) {
        // Upsert: remove existing ACTIVE for this tuple, then insert
        em.createQuery(
                "DELETE FROM StaticCredentialEntity WHERE actorId = :actorId " +
                "AND provider = :provider AND tenancyId = :tenancyId AND status = :status")
                .setParameter("actorId", record.actorId())
                .setParameter("provider", record.provider())
                .setParameter("tenancyId", record.tenancyId())
                .setParameter("status", CredentialState.ACTIVE)
                .executeUpdate();
        em.persist(StaticCredentialEntity.fromRecord(record));
    }

    @Override
    public Optional<StaticCredentialRecord> find(String actorId, String provider, String tenancyId) {
        return em.createQuery(
                "FROM StaticCredentialEntity WHERE actorId = :actorId " +
                "AND provider = :provider AND tenancyId = :tenancyId AND status = :status",
                        StaticCredentialEntity.class)
                .setParameter("actorId", actorId)
                .setParameter("provider", provider)
                .setParameter("tenancyId", tenancyId)
                .setParameter("status", CredentialState.ACTIVE)
                .getResultStream()
                .findFirst()
                .map(StaticCredentialEntity::toRecord);
    }

    @Override
    public List<StaticCredentialRecord> findAll(String actorId, String tenancyId) {
        return em.createQuery(
                "FROM StaticCredentialEntity WHERE actorId = :actorId " +
                "AND tenancyId = :tenancyId AND status = :status",
                        StaticCredentialEntity.class)
                .setParameter("actorId", actorId)
                .setParameter("tenancyId", tenancyId)
                .setParameter("status", CredentialState.ACTIVE)
                .getResultList()
                .stream()
                .map(StaticCredentialEntity::toRecord)
                .toList();
    }

    @Override
    @Transactional
    public void delete(String actorId, String provider, String tenancyId) {
        em.createQuery(
                "DELETE FROM StaticCredentialEntity WHERE actorId = :actorId " +
                "AND provider = :provider AND tenancyId = :tenancyId")
                .setParameter("actorId", actorId)
                .setParameter("provider", provider)
                .setParameter("tenancyId", tenancyId)
                .executeUpdate();
    }

    @Override
    public Optional<StaticCredentialRecord> lookup(String credential) {
        String hash = CredentialHasher.sha256Hex(credential);
        return em.createQuery(
                "FROM StaticCredentialEntity WHERE credentialHash = :hash " +
                "AND status IN (:active, :grace) " +
                "AND (expiresAt IS NULL OR expiresAt > :now)",
                        StaticCredentialEntity.class)
                .setParameter("hash", hash)
                .setParameter("active", CredentialState.ACTIVE)
                .setParameter("grace", CredentialState.GRACE_PERIOD)
                .setParameter("now", Instant.now())
                .getResultStream()
                .findFirst()
                .map(StaticCredentialEntity::toRecord);
    }

    @Override
    @Transactional
    public StaticCredentialRecord rotate(String actorId, String provider,
            String tenancyId, String newCredential) {
        // Lock existing credentials for this tuple
        var existing = em.createQuery(
                "FROM StaticCredentialEntity WHERE actorId = :actorId " +
                "AND provider = :provider AND tenancyId = :tenancyId " +
                "AND status != :revoked",
                        StaticCredentialEntity.class)
                .setParameter("actorId", actorId)
                .setParameter("provider", provider)
                .setParameter("tenancyId", tenancyId)
                .setParameter("revoked", CredentialState.REVOKED)
                .setLockMode(LockModeType.PESSIMISTIC_WRITE)
                .getResultList();

        var now = Instant.now();

        for (var entity : existing) {
            if (entity.status == CredentialState.GRACE_PERIOD) {
                entity.status = CredentialState.REVOKED;
                entity.updatedAt = now;
            } else if (entity.status == CredentialState.ACTIVE) {
                entity.status = CredentialState.GRACE_PERIOD;
                entity.expiresAt = now.plus(gracePeriodTtl);
                entity.updatedAt = now;
            }
        }

        // Insert new ACTIVE
        var activeType = existing.stream()
                .filter(e -> e.type != null)
                .findFirst()
                .map(e -> e.type)
                .orElse(io.casehub.platform.api.authn.CredentialType.API_KEY);

        var newEntity = new StaticCredentialEntity();
        newEntity.id = UUIDv7.randomUUID().toString();
        newEntity.actorId = actorId;
        newEntity.provider = provider;
        newEntity.tenancyId = tenancyId;
        newEntity.credentialHash = CredentialHasher.sha256Hex(newCredential);
        newEntity.type = activeType;
        newEntity.status = CredentialState.ACTIVE;
        newEntity.createdAt = now;
        newEntity.updatedAt = now;
        em.persist(newEntity);

        return new StaticCredentialRecord(actorId, tenancyId, provider,
                newCredential, activeType, now, now,
                CredentialState.ACTIVE, null);
    }

    @Override
    @Transactional
    public void revoke(String actorId, String provider, String tenancyId) {
        em.createQuery(
                "UPDATE StaticCredentialEntity SET status = :revoked, updatedAt = :now " +
                "WHERE actorId = :actorId AND provider = :provider " +
                "AND tenancyId = :tenancyId AND status != :revoked")
                .setParameter("revoked", CredentialState.REVOKED)
                .setParameter("now", Instant.now())
                .setParameter("actorId", actorId)
                .setParameter("provider", provider)
                .setParameter("tenancyId", tenancyId)
                .executeUpdate();
    }
}
```

- [ ] **Step 8: Verify compilation**

Run: `mvn -pl authn-social-jpa-common,authn-social-jpa compile --batch-mode -q`
Expected: Compiles successfully

- [ ] **Step 9: Commit**

```bash
git add authn-social-jpa-common/src/main/java/io/casehub/platform/authn/social/jpa/StaticCredentialEntity.java
git add authn-social-jpa-common/src/main/java/io/casehub/platform/authn/social/jpa/CredentialHasher.java
git add authn-social-jpa/src/main/java/io/casehub/platform/authn/social/jpa/JpaStaticCredentialStore.java
git add authn-social-jpa/src/main/java/io/casehub/platform/authn/social/jpa/V3_1__BackfillCredentialHashes.java
git add authn-social-jpa/src/main/resources/db/authn-social/migration/V3__credential_resolution_rotation.sql
git add authn-social-jpa/src/main/resources/db/authn-social/migration/V3_2__credential_pk_and_indexes.sql
git commit -m "feat(#900): JPA entity, migration, and store implementation for credential rotation"
```

## Batch 4: Spring JPA Implementation

### Task 5: Update Spring JPA store and repository

**Files:**
- Modify: `authn-social-spring-jpa/src/main/java/io/casehub/platform/authn/social/spring/jpa/StaticCredentialRepository.java`
- Modify: `authn-social-spring-jpa/src/main/java/io/casehub/platform/authn/social/spring/jpa/SpringStaticCredentialStore.java`
- Modify: `authn-social-spring-jpa/src/main/java/io/casehub/platform/authn/social/spring/jpa/SocialJpaAutoConfiguration.java` (if needed)

**Interfaces:**
- Consumes: Updated `StaticCredentialEntity` (from Task 4), `CredentialHasher` (from Task 4), `CredentialState` (from Task 1)
- Produces: Fully implemented `SpringStaticCredentialStore` with all 7 methods

- [ ] **Step 1: Update StaticCredentialRepository**

Replace the full interface:

```java
package io.casehub.platform.authn.social.spring.jpa;

import io.casehub.platform.api.authn.CredentialState;
import io.casehub.platform.authn.social.jpa.StaticCredentialEntity;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;

import java.time.Instant;
import java.util.List;
import java.util.Optional;

public interface StaticCredentialRepository extends JpaRepository<StaticCredentialEntity, String> {

    List<StaticCredentialEntity> findByActorIdAndTenancyIdAndStatus(
            String actorId, String tenancyId, CredentialState status);

    Optional<StaticCredentialEntity> findByActorIdAndProviderAndTenancyIdAndStatus(
            String actorId, String provider, String tenancyId, CredentialState status);

    Optional<StaticCredentialEntity> findByCredentialHashAndStatusIn(
            String credentialHash, List<CredentialState> statuses);

    @Query("SELECT e FROM StaticCredentialEntity e WHERE e.credentialHash = :hash " +
           "AND e.status IN :statuses AND (e.expiresAt IS NULL OR e.expiresAt > :now)")
    Optional<StaticCredentialEntity> findByCredentialHashAndStatusInAndNotExpired(
            String hash, List<CredentialState> statuses, Instant now);

    List<StaticCredentialEntity> findByActorIdAndProviderAndTenancyIdAndStatusNot(
            String actorId, String provider, String tenancyId, CredentialState status);

    @Modifying
    @Query("UPDATE StaticCredentialEntity SET status = :newStatus, updatedAt = :now " +
           "WHERE actorId = :actorId AND provider = :provider " +
           "AND tenancyId = :tenancyId AND status != :newStatus")
    int revokeByActorIdAndProviderAndTenancyId(
            String actorId, String provider, String tenancyId,
            CredentialState newStatus, Instant now);

    @Modifying
    void deleteByActorIdAndProviderAndTenancyId(
            String actorId, String provider, String tenancyId);
}
```

- [ ] **Step 2: Update SpringStaticCredentialStore**

Replace the full class:

```java
package io.casehub.platform.authn.social.spring.jpa;

import io.casehub.platform.api.authn.CredentialState;
import io.casehub.platform.api.authn.CredentialType;
import io.casehub.platform.api.authn.StaticCredentialRecord;
import io.casehub.platform.api.authn.StaticCredentialStore;
import io.casehub.platform.api.util.UUIDv7;
import io.casehub.platform.authn.social.jpa.CredentialHasher;
import io.casehub.platform.authn.social.jpa.StaticCredentialEntity;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.transaction.annotation.Transactional;

import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Optional;

public class SpringStaticCredentialStore implements StaticCredentialStore {

    private final StaticCredentialRepository repo;
    private final Duration gracePeriodTtl;

    public SpringStaticCredentialStore(StaticCredentialRepository repo,
            @Value("${casehub.authn.credential.grace-period-ttl:PT24H}") Duration gracePeriodTtl) {
        this.repo = repo;
        this.gracePeriodTtl = gracePeriodTtl;
    }

    @Override
    @Transactional
    public void store(StaticCredentialRecord record) {
        repo.findByActorIdAndProviderAndTenancyIdAndStatus(
                record.actorId(), record.provider(), record.tenancyId(), CredentialState.ACTIVE)
                .ifPresent(repo::delete);
        repo.save(StaticCredentialEntity.fromRecord(record));
    }

    @Override
    @Transactional(readOnly = true)
    public Optional<StaticCredentialRecord> find(String actorId, String provider, String tenancyId) {
        return repo.findByActorIdAndProviderAndTenancyIdAndStatus(
                actorId, provider, tenancyId, CredentialState.ACTIVE)
                .map(StaticCredentialEntity::toRecord);
    }

    @Override
    @Transactional(readOnly = true)
    public List<StaticCredentialRecord> findAll(String actorId, String tenancyId) {
        return repo.findByActorIdAndTenancyIdAndStatus(actorId, tenancyId, CredentialState.ACTIVE)
                .stream()
                .map(StaticCredentialEntity::toRecord)
                .toList();
    }

    @Override
    @Transactional
    public void delete(String actorId, String provider, String tenancyId) {
        repo.deleteByActorIdAndProviderAndTenancyId(actorId, provider, tenancyId);
    }

    @Override
    @Transactional(readOnly = true)
    public Optional<StaticCredentialRecord> lookup(String credential) {
        String hash = CredentialHasher.sha256Hex(credential);
        return repo.findByCredentialHashAndStatusInAndNotExpired(
                hash,
                List.of(CredentialState.ACTIVE, CredentialState.GRACE_PERIOD),
                Instant.now())
                .map(StaticCredentialEntity::toRecord);
    }

    @Override
    @Transactional
    public StaticCredentialRecord rotate(String actorId, String provider,
            String tenancyId, String newCredential) {
        var now = Instant.now();
        var existing = repo.findByActorIdAndProviderAndTenancyIdAndStatusNot(
                actorId, provider, tenancyId, CredentialState.REVOKED);

        CredentialType activeType = CredentialType.API_KEY;
        for (var entity : existing) {
            if (entity.status == CredentialState.GRACE_PERIOD) {
                entity.status = CredentialState.REVOKED;
                entity.updatedAt = now;
                repo.save(entity);
            } else if (entity.status == CredentialState.ACTIVE) {
                activeType = entity.type;
                entity.status = CredentialState.GRACE_PERIOD;
                entity.expiresAt = now.plus(gracePeriodTtl);
                entity.updatedAt = now;
                repo.save(entity);
            }
        }

        var newEntity = new StaticCredentialEntity();
        newEntity.id = UUIDv7.randomUUID().toString();
        newEntity.actorId = actorId;
        newEntity.provider = provider;
        newEntity.tenancyId = tenancyId;
        newEntity.credentialHash = CredentialHasher.sha256Hex(newCredential);
        newEntity.type = activeType;
        newEntity.status = CredentialState.ACTIVE;
        newEntity.createdAt = now;
        newEntity.updatedAt = now;
        repo.save(newEntity);

        return new StaticCredentialRecord(actorId, tenancyId, provider,
                newCredential, activeType, now, now,
                CredentialState.ACTIVE, null);
    }

    @Override
    @Transactional
    public void revoke(String actorId, String provider, String tenancyId) {
        repo.revokeByActorIdAndProviderAndTenancyId(
                actorId, provider, tenancyId,
                CredentialState.REVOKED, Instant.now());
    }
}
```

- [ ] **Step 3: Update SocialJpaAutoConfiguration if constructor changed**

The `SpringStaticCredentialStore` constructor now takes `Duration gracePeriodTtl`. Check the auto-configuration bean registration and update the `@Bean` method to include the config property injection.

- [ ] **Step 4: Verify compilation**

Run: `mvn -pl authn-social-spring-jpa compile --batch-mode -q`
Expected: Compiles successfully

- [ ] **Step 5: Commit**

```bash
git add authn-social-spring-jpa/src/main/java/io/casehub/platform/authn/social/spring/jpa/StaticCredentialRepository.java
git add authn-social-spring-jpa/src/main/java/io/casehub/platform/authn/social/spring/jpa/SpringStaticCredentialStore.java
git add authn-social-spring-jpa/src/main/java/io/casehub/platform/authn/social/spring/jpa/SocialJpaAutoConfiguration.java
git commit -m "feat(#900): Spring JPA implementation for credential rotation"
```

## Batch 5: Full Build Verification

### Task 6: Full build, verify all tests, update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md` (module descriptions for authn-social-jpa-common, authn-social-jpa)

**Interfaces:**
- Consumes: All changes from Tasks 1-5

- [ ] **Step 1: Run full build**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS — all modules compile and pass tests

- [ ] **Step 2: Fix any compilation failures in downstream modules**

If any module that depends on `StaticCredentialId` or the old `StaticCredentialRecord` constructor fails, fix the compilation errors:
- Modules using `StaticCredentialId` → update to use JPQL or the entity directly
- Modules using old record fields → the 7-arg constructor is backward compatible, so these should work

- [ ] **Step 3: Update CLAUDE.md module descriptions**

Add credential hashing and rotation info to the relevant module entries in CLAUDE.md.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(#900): update CLAUDE.md module descriptions for credential rotation"
```

## References

- [2026-11-19-credential-resolution-rotation-design.md] — design spec this plan implements
- `platform-api/src/main/java/io/casehub/platform/api/authn/StaticCredentialStore.java` — SPI to extend
- `platform-api/src/main/java/io/casehub/platform/api/authn/StaticCredentialRecord.java` — record to evolve
- `platform-api/src/main/java/io/casehub/platform/api/util/UUIDv7.java` — surrogate ID generator
- `authn-social-jpa-common/src/main/java/io/casehub/platform/authn/social/jpa/StaticCredentialEntity.java` — entity to modify
- `authn-social-jpa/src/main/resources/db/authn-social/migration/V2__add_static_credentials.sql` — existing schema
- `platform-api/src/main/java/io/casehub/platform/api/acl/WorkerCredentialStore.java` — `lookup()` pattern
- PP-20260528-557f5c — spi-deletion-default-throws protocol
- PP-20260601-81b9e5 — spi-evolution-default-methods protocol
- GitHub #900 — focal issue
