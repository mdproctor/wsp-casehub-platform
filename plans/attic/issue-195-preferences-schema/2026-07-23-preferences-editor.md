# Preferences Editor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #193 — feat: preferences-editor/ module — REST API for writing preferences to any backend
**Issue group:** #193

**Goal:** Add a write surface for preferences — `PreferenceStore` SPI in platform-api, JPA + MongoDB backends, REST API in a new `preferences-editor/` module. Also adds tenancyId to `SettingsScope` (breaking change across all callers).

**Architecture:** `PreferenceStore` is a blocking write SPI in platform-api alongside the existing read-only `PreferenceProvider`. Backend implementations (JPA, MongoDB) inject `CurrentPrincipal` and call `PreferencePermissions.assertTenant()` before every write. A new `preferences-editor/` module exposes the write surface via REST, using query parameters for hierarchical scope. Virtual threads end-to-end.

**Tech Stack:** Java 21+, Quarkus (RESTEasy Reactive, Hibernate ORM Panache, MongoDB Panache, Flyway, CDI), H2 (test), PostgreSQL (prod)

## Global Constraints

- platform-api must remain zero-dependency (no Quarkus, no JPA, no casehubio imports)
- Blocking method signatures only — no Mutiny/Uni. Virtual threads handle I/O.
- `SettingsScope` gains `tenancyId` as first parameter — breaking change, all callers must update
- No varargs `of(String tenancyId, String... segments)` factory on `SettingsScope` — forces `Path.of(...)` to avoid silent semantic ambiguity
- `PreferenceStore.set()` is an upsert — no separate create/update
- `deleteAll()` is exact scope match only — no descendant cascade
- Flyway V2 migration is multi-step (add nullable → backfill → set NOT NULL → rebuild constraint)
- Backend implementations MUST call `PreferencePermissions.assertTenant()` before every write
- Backend implementations MUST fire `Event<PreferenceChanged>.fireAsync()` after successful writes
- NoOp `@DefaultBean` MUST NOT fire `PreferenceChanged`
- `PreferenceRecord.scope` is `Path`, not `String`
- IntelliJ MCP is mandatory for all .java file operations
- IntelliJ workspace: `ide_open_workspace({"modules": ["/Users/mdproctor/claude/casehub/platform"]})`

---

### Task 1: SPI Foundation in platform-api

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/preferences/PreferenceStore.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/preferences/PreferenceRecord.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/preferences/PreferenceQuery.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/preferences/PreferencePermissions.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/preferences/PreferenceChanged.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/preferences/SettingsScope.java`
- Modify: `platform-api/src/test/java/io/casehub/platform/api/preferences/PreferenceKeyTest.java` (SettingsScope usage if any)
- Create: `platform-api/src/test/java/io/casehub/platform/api/preferences/PreferencePermissionsTest.java`
- Modify: `platform-api/src/test/java/io/casehub/platform/api/preferences/MapPreferencesTest.java` (if it uses SettingsScope)

**Interfaces:**
- Consumes: `CurrentPrincipal` (from `.identity` package — already in platform-api), `Path` (from `.path` package)
- Produces: `PreferenceStore` (SPI interface), `PreferenceRecord`, `PreferenceQuery`, `PreferencePermissions`, `PreferenceChanged` — used by Tasks 2-5

- [ ] **Step 1: Write PreferencePermissions test**

Create `platform-api/src/test/java/io/casehub/platform/api/preferences/PreferencePermissionsTest.java` via `ide_create_file`:

```java
package io.casehub.platform.api.preferences;

import io.casehub.platform.api.identity.CurrentPrincipal;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class PreferencePermissionsTest {

    @Test
    void assertTenant_passes_when_tenancy_matches() {
        CurrentPrincipal principal = stubPrincipal("tenant-1");
        assertDoesNotThrow(() -> PreferencePermissions.assertTenant("tenant-1", principal));
    }

    @Test
    void assertTenant_throws_when_tenancy_mismatches() {
        CurrentPrincipal principal = stubPrincipal("tenant-1");
        SecurityException ex = assertThrows(SecurityException.class,
                () -> PreferencePermissions.assertTenant("tenant-2", principal));
        assertTrue(ex.getMessage().contains("tenant-2"));
        assertTrue(ex.getMessage().contains("tenant-1"));
    }

    private static CurrentPrincipal stubPrincipal(String tenancyId) {
        return new CurrentPrincipal() {
            @Override public String actorId() { return "test-actor"; }
            @Override public String tenancyId() { return tenancyId; }
            @Override public boolean hasGroup(String group) { return false; }
        };
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl platform-api -Dtest=PreferencePermissionsTest -DfailIfNoTests=false`
Expected: Compilation failure — `PreferencePermissions` does not exist

- [ ] **Step 3: Create SPI types and PreferencePermissions**

Create `PreferencePermissions.java` via `ide_create_file`:

```java
package io.casehub.platform.api.preferences;

import io.casehub.platform.api.identity.CurrentPrincipal;

public final class PreferencePermissions {
    private PreferencePermissions() {}

    public static void assertTenant(String tenancyId, CurrentPrincipal principal) {
        if (!principal.tenancyId().equals(tenancyId))
            throw new SecurityException(
                "Tenant ID mismatch: claimed=" + tenancyId
                + ", authenticated=" + principal.tenancyId());
    }
}
```

Create `PreferenceRecord.java` via `ide_create_file`:

```java
package io.casehub.platform.api.preferences;

import io.casehub.platform.api.path.Path;
import java.util.Objects;

public record PreferenceRecord(String tenancyId, Path scope, String namespace,
                                String name, String subKey, String value) {
    public PreferenceRecord {
        Objects.requireNonNull(tenancyId, "tenancyId must not be null");
        Objects.requireNonNull(scope, "scope must not be null");
        Objects.requireNonNull(namespace, "namespace must not be null");
        Objects.requireNonNull(name, "name must not be null");
        Objects.requireNonNull(subKey, "subKey must not be null");
        Objects.requireNonNull(value, "value must not be null");
    }
}
```

Create `PreferenceQuery.java` via `ide_create_file`:

```java
package io.casehub.platform.api.preferences;

import io.casehub.platform.api.path.Path;
import java.util.Objects;

public record PreferenceQuery(String tenancyId, Path scope, String namespace) {
    public PreferenceQuery {
        Objects.requireNonNull(tenancyId, "tenancyId must not be null");
    }
}
```

Create `PreferenceChanged.java` via `ide_create_file`:

```java
package io.casehub.platform.api.preferences;

import io.casehub.platform.api.path.Path;
import java.util.Objects;

public record PreferenceChanged(String tenancyId, Path scope, String namespace) {
    public PreferenceChanged {
        Objects.requireNonNull(tenancyId, "tenancyId must not be null");
    }
}
```

Create `PreferenceStore.java` via `ide_create_file`:

```java
package io.casehub.platform.api.preferences;

import io.casehub.platform.api.path.Path;
import java.util.List;

public interface PreferenceStore {
    void set(String tenancyId, Path scope, String namespace, String name, String subKey, String value);
    void delete(String tenancyId, Path scope, String namespace, String name, String subKey);
    List<PreferenceRecord> list(PreferenceQuery query);
    void deleteAll(String tenancyId, Path scope, String namespace);
}
```

- [ ] **Step 4: Modify SettingsScope to add tenancyId**

Use `ide_edit_member` with `member=SettingsScope` on `platform-api/src/main/java/io/casehub/platform/api/preferences/SettingsScope.java` to replace the record declaration:

```java
public record SettingsScope(String tenancyId, Path scope, Instant effectiveAt) {

    public SettingsScope {
        Objects.requireNonNull(tenancyId, "tenancyId must not be null");
        Objects.requireNonNull(scope, "scope must not be null");
        Objects.requireNonNull(effectiveAt, "effectiveAt must not be null");
    }

    public static SettingsScope of(String tenancyId, Path scope) {
        Objects.requireNonNull(tenancyId, "tenancyId must not be null");
        return new SettingsScope(tenancyId, scope, Instant.now());
    }

    public static SettingsScope root(String tenancyId) {
        return new SettingsScope(tenancyId, Path.root(), Instant.now());
    }
}
```

This removes the old `of(String... segments)` and `of(Path scope)` factories. Every caller now must pass tenancyId explicitly and construct Path via `Path.of(...)`.

- [ ] **Step 5: Run tests to verify PreferencePermissions passes and SettingsScope breaks callers**

Run: `mvn --batch-mode test -pl platform-api`
Expected: `PreferencePermissionsTest` passes. Some existing tests may fail if they use `SettingsScope.of(...)` with old signatures. Fix any platform-api internal test failures (e.g. in `MapPreferencesTest`) by adding `TenancyConstants.DEFAULT_TENANT_ID` as the first argument.

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform-api/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#193): add PreferenceStore SPI + tenancyId on SettingsScope"
```

---

### Task 2: Platform Defaults + Read-Side Fixes

**Files:**
- Create: `platform/src/main/java/io/casehub/platform/mock/NoOpPreferenceStore.java`
- Modify: `platform/src/main/java/io/casehub/platform/mock/MockPreferenceProvider.java`
- Modify: `platform/src/test/java/io/casehub/platform/mock/MockBeansTest.java`
- Modify: `config/src/main/java/io/casehub/platform/config/ConfigFilePreferenceProvider.java`
- Modify: `config/src/test/java/io/casehub/platform/config/ConfigFilePreferenceProviderTest.java`
- Modify: `config/src/test/java/io/casehub/platform/config/ChainingTest.java`

**Interfaces:**
- Consumes: `PreferenceStore` (from Task 1)
- Produces: `NoOpPreferenceStore @DefaultBean` — default when no persistence backend is on classpath

- [ ] **Step 1: Create NoOpPreferenceStore**

Create `platform/src/main/java/io/casehub/platform/mock/NoOpPreferenceStore.java` via `ide_create_file`:

```java
package io.casehub.platform.mock;

import io.casehub.platform.api.path.Path;
import io.casehub.platform.api.preferences.PreferenceQuery;
import io.casehub.platform.api.preferences.PreferenceRecord;
import io.casehub.platform.api.preferences.PreferenceStore;
import io.quarkus.arc.DefaultBean;
import jakarta.enterprise.context.ApplicationScoped;

import java.util.List;

@ApplicationScoped
@DefaultBean
public class NoOpPreferenceStore implements PreferenceStore {

    @Override
    public void set(String tenancyId, Path scope, String namespace, String name, String subKey, String value) {}

    @Override
    public void delete(String tenancyId, Path scope, String namespace, String name, String subKey) {}

    @Override
    public List<PreferenceRecord> list(PreferenceQuery query) {
        return List.of();
    }

    @Override
    public void deleteAll(String tenancyId, Path scope, String namespace) {}
}
```

- [ ] **Step 2: Fix MockPreferenceProvider for new SettingsScope**

`MockPreferenceProvider.resolve(SettingsScope scope)` — no change needed to the method body (it ignores `scope` entirely and returns flat config). The signature is compatible because `SettingsScope` is still a record passed as parameter.

However, the method does reference `SettingsScope` in its import. Verify compilation by running:

Run: `mvn --batch-mode compile -pl platform`
Expected: Compiles clean — `MockPreferenceProvider` still implements `PreferenceProvider.resolve(SettingsScope)` correctly.

- [ ] **Step 3: Fix MockBeansTest for new SettingsScope factories**

Every `SettingsScope.of("acme/backend")` call in `MockBeansTest.java` must become `SettingsScope.of(TenancyConstants.DEFAULT_TENANT_ID, Path.of("acme", "backend"))`.

Use `ide_replace_text_in_file` to replace all occurrences:
- `SettingsScope.of("acme/backend")` → `SettingsScope.of(TenancyConstants.DEFAULT_TENANT_ID, Path.of("acme", "backend"))`

Add imports for `TenancyConstants` and `Path` if not present.

- [ ] **Step 4: Fix ConfigFilePreferenceProvider for tenancyId**

`ConfigFilePreferenceProvider.resolve(SettingsScope scope)` — no body change needed. It receives the SettingsScope and only reads `scope.scope()` (the Path). The tenancyId is ignored for file-based config (all config values are deployment-wide). This is correct: file-based preferences seed the system with `DEFAULT_TENANT_ID`; tenant-specific overrides live in the database.

Verify compilation:

Run: `mvn --batch-mode compile -pl config`

- [ ] **Step 5: Fix config tests for new SettingsScope factories**

In `ConfigFilePreferenceProviderTest.java` and `ChainingTest.java`, every `SettingsScope.of("casehubio", "devtown")` must become `SettingsScope.of(TenancyConstants.DEFAULT_TENANT_ID, Path.of("casehubio", "devtown"))`. Same for `SettingsScope.of("casehubio", "aml", "investigation")` → `SettingsScope.of(TenancyConstants.DEFAULT_TENANT_ID, Path.of("casehubio", "aml", "investigation"))`. And `SettingsScope.of("casehubio")` → `SettingsScope.of(TenancyConstants.DEFAULT_TENANT_ID, Path.of("casehubio"))`.

Use `ide_replace_text_in_file` with regex on each test file:
- Pattern: `SettingsScope\.of\(` needs manual replacement per call site since each has different arguments.

- [ ] **Step 6: Run all tests in platform/ and config/**

Run: `mvn --batch-mode test -pl platform,config`
Expected: All tests pass.

- [ ] **Step 7: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform/ config/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#193): NoOpPreferenceStore + fix read-side callers for tenancyId"
```

---

### Task 3: JPA Backend — Store + Read-Side tenancyId

**Files:**
- Create: `persistence-jpa/src/main/resources/db/platform/migration/V2__add_tenancy_id_to_platform_preference.sql`
- Modify: `persistence-jpa/src/main/java/io/casehub/platform/persistence/jpa/PreferenceEntry.java`
- Modify: `persistence-jpa/src/main/java/io/casehub/platform/persistence/jpa/JpaPreferenceProvider.java`
- Create: `persistence-jpa/src/main/java/io/casehub/platform/persistence/jpa/JpaPreferenceStore.java`
- Modify: `persistence-jpa/src/test/java/io/casehub/platform/persistence/jpa/JpaPreferenceProviderTest.java`
- Create: `persistence-jpa/src/test/java/io/casehub/platform/persistence/jpa/JpaPreferenceStoreTest.java`

**Interfaces:**
- Consumes: `PreferenceStore`, `PreferenceRecord`, `PreferenceQuery`, `PreferencePermissions`, `PreferenceChanged` (from Task 1)
- Produces: `JpaPreferenceStore @ApplicationScoped` — JPA-backed write implementation

- [ ] **Step 1: Create Flyway V2 migration**

Create `persistence-jpa/src/main/resources/db/platform/migration/V2__add_tenancy_id_to_platform_preference.sql`:

```sql
ALTER TABLE platform_preference ADD COLUMN tenancy_id VARCHAR(100);

UPDATE platform_preference SET tenancy_id = '278776f9-e1b0-46fb-9032-8bddebdcf9ce';

ALTER TABLE platform_preference ALTER COLUMN tenancy_id SET NOT NULL;

ALTER TABLE platform_preference DROP CONSTRAINT uq_platform_preference;

ALTER TABLE platform_preference ADD CONSTRAINT uq_platform_preference
    UNIQUE (tenancy_id, scope, namespace, pref_name, sub_key);
```

- [ ] **Step 2: Add tenancyId to PreferenceEntry entity**

Use `ide_edit_member` on `PreferenceEntry` in `persistence-jpa/src/main/java/io/casehub/platform/persistence/jpa/PreferenceEntry.java`:

Add field via `ide_insert_member` after `id`:

```java
@Column(name = "tenancy_id", nullable = false, length = 100)
public String tenancyId;
```

Update `@Table` annotation on the class declaration to include `tenancy_id` in the unique constraint:

```java
@Entity
@Table(
    name = "platform_preference",
    uniqueConstraints = @UniqueConstraint(
        name = "uq_platform_preference",
        columnNames = {"tenancy_id", "scope", "namespace", "pref_name", "sub_key"}),
    indexes = @Index(name = "idx_platform_preference_scope", columnList = "scope")
)
```

Update `findByScopes` to also filter by tenancyId:

```java
static List<PreferenceEntry> findByScopes(final String tenancyId, final List<String> scopes) {
    if (scopes.isEmpty()) return Collections.emptyList();
    return list("tenancyId = ?1 and scope in ?2", tenancyId, scopes);
}
```

- [ ] **Step 3: Update JpaPreferenceProvider to filter by tenancyId**

Use `ide_replace_member` on `resolve` in `JpaPreferenceProvider.java` — change the first line of the body to pass `scope.tenancyId()`:

```java
final List<String> ancestors = ancestors(scope.scope());
final List<PreferenceEntry> rows = PreferenceEntry.findByScopes(scope.tenancyId(), ancestors);

final Map<String, Integer> scopeOrder = new HashMap<>();
for (int i = 0; i < ancestors.size(); i++) {
    scopeOrder.put(ancestors.get(i), i);
}
rows.sort((a, b) -> Integer.compare(
        scopeOrder.getOrDefault(a.scope, -1),
        scopeOrder.getOrDefault(b.scope, -1)));

final Map<String, Object> merged = new HashMap<>();
for (final PreferenceEntry row : rows) {
    final String mapKey = row.subKey.isEmpty()
            ? row.namespace + "." + row.name
            : row.namespace + "." + row.name + "." + row.subKey;
    merged.put(mapKey, row.value);
}

return new MapPreferences(merged);
```

- [ ] **Step 4: Write JpaPreferenceStoreTest**

Create `persistence-jpa/src/test/java/io/casehub/platform/persistence/jpa/JpaPreferenceStoreTest.java` via `ide_create_file`:

```java
package io.casehub.platform.persistence.jpa;

import io.casehub.platform.api.identity.TenancyConstants;
import io.casehub.platform.api.path.Path;
import io.casehub.platform.api.preferences.PreferenceQuery;
import io.casehub.platform.api.preferences.PreferenceRecord;
import io.casehub.platform.api.preferences.PreferenceStore;
import io.quarkus.test.junit.QuarkusTest;
import jakarta.inject.Inject;
import jakarta.transaction.Transactional;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

@QuarkusTest
class JpaPreferenceStoreTest {

    private static final String TENANT = TenancyConstants.DEFAULT_TENANT_ID;

    @Inject PreferenceStore store;

    @BeforeEach
    @Transactional
    void clear() {
        PreferenceEntry.deleteAll();
    }

    @Test
    @Transactional
    void set_inserts_new_preference() {
        store.set(TENANT, Path.of("casehubio"), "test", "count", "", "42");

        List<PreferenceRecord> records = store.list(new PreferenceQuery(TENANT, Path.of("casehubio"), "test"));
        assertEquals(1, records.size());
        assertEquals("42", records.get(0).value());
        assertEquals("count", records.get(0).name());
    }

    @Test
    @Transactional
    void set_upserts_existing_preference() {
        store.set(TENANT, Path.of("casehubio"), "test", "count", "", "42");
        store.set(TENANT, Path.of("casehubio"), "test", "count", "", "99");

        List<PreferenceRecord> records = store.list(new PreferenceQuery(TENANT, Path.of("casehubio"), "test"));
        assertEquals(1, records.size());
        assertEquals("99", records.get(0).value());
    }

    @Test
    @Transactional
    void delete_removes_specific_preference() {
        store.set(TENANT, Path.of("casehubio"), "test", "count", "", "42");
        store.set(TENANT, Path.of("casehubio"), "test", "other", "", "7");

        store.delete(TENANT, Path.of("casehubio"), "test", "count", "");

        List<PreferenceRecord> records = store.list(new PreferenceQuery(TENANT, Path.of("casehubio"), "test"));
        assertEquals(1, records.size());
        assertEquals("other", records.get(0).name());
    }

    @Test
    @Transactional
    void deleteAll_removes_all_in_namespace_at_scope() {
        store.set(TENANT, Path.of("casehubio"), "test", "a", "", "1");
        store.set(TENANT, Path.of("casehubio"), "test", "b", "", "2");
        store.set(TENANT, Path.of("casehubio"), "other", "c", "", "3");

        store.deleteAll(TENANT, Path.of("casehubio"), "test");

        assertEquals(0, store.list(new PreferenceQuery(TENANT, Path.of("casehubio"), "test")).size());
        assertEquals(1, store.list(new PreferenceQuery(TENANT, Path.of("casehubio"), "other")).size());
    }

    @Test
    @Transactional
    void deleteAll_does_not_cascade_to_child_scopes() {
        store.set(TENANT, Path.of("casehubio"), "test", "a", "", "1");
        store.set(TENANT, Path.of("casehubio", "devtown"), "test", "a", "", "2");

        store.deleteAll(TENANT, Path.of("casehubio"), "test");

        assertEquals(0, store.list(new PreferenceQuery(TENANT, Path.of("casehubio"), "test")).size());
        assertEquals(1, store.list(new PreferenceQuery(TENANT, Path.of("casehubio", "devtown"), "test")).size());
    }

    @Test
    @Transactional
    void list_returns_empty_for_unknown_scope() {
        List<PreferenceRecord> records = store.list(new PreferenceQuery(TENANT, Path.of("nonexistent"), "test"));
        assertTrue(records.isEmpty());
    }

    @Test
    @Transactional
    void tenant_isolation_prevents_cross_tenant_reads() {
        store.set("tenant-a", Path.of("casehubio"), "test", "count", "", "42");

        List<PreferenceRecord> records = store.list(new PreferenceQuery("tenant-b", Path.of("casehubio"), "test"));
        assertTrue(records.isEmpty());
    }

    @Test
    @Transactional
    void set_with_subkey_for_multi_value_preferences() {
        store.set(TENANT, Path.of("casehubio"), "test", "multi", "key1", "val1");
        store.set(TENANT, Path.of("casehubio"), "test", "multi", "key2", "val2");

        List<PreferenceRecord> records = store.list(new PreferenceQuery(TENANT, Path.of("casehubio"), "test"));
        assertEquals(2, records.size());
    }
}
```

- [ ] **Step 5: Run test to verify it fails**

Run: `mvn --batch-mode test -pl persistence-jpa -Dtest=JpaPreferenceStoreTest`
Expected: Compilation failure — `JpaPreferenceStore` does not exist

- [ ] **Step 6: Implement JpaPreferenceStore**

Create `persistence-jpa/src/main/java/io/casehub/platform/persistence/jpa/JpaPreferenceStore.java` via `ide_create_file`:

```java
package io.casehub.platform.persistence.jpa;

import io.casehub.platform.api.identity.CurrentPrincipal;
import io.casehub.platform.api.path.Path;
import io.casehub.platform.api.preferences.PreferenceChanged;
import io.casehub.platform.api.preferences.PreferencePermissions;
import io.casehub.platform.api.preferences.PreferenceQuery;
import io.casehub.platform.api.preferences.PreferenceRecord;
import io.casehub.platform.api.preferences.PreferenceStore;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.event.Event;
import jakarta.inject.Inject;
import jakarta.transaction.Transactional;

import java.util.List;

@ApplicationScoped
public class JpaPreferenceStore implements PreferenceStore {

    @Inject CurrentPrincipal principal;
    @Inject Event<PreferenceChanged> changedEvent;

    @Override
    @Transactional
    public void set(String tenancyId, Path scope, String namespace, String name, String subKey, String value) {
        PreferencePermissions.assertTenant(tenancyId, principal);
        String scopeValue = scope.value();
        PreferenceEntry existing = PreferenceEntry.find(
                "tenancyId = ?1 and scope = ?2 and namespace = ?3 and name = ?4 and subKey = ?5",
                tenancyId, scopeValue, namespace, name, subKey).firstResult();
        if (existing != null) {
            existing.value = value;
        } else {
            PreferenceEntry entry = new PreferenceEntry();
            entry.tenancyId = tenancyId;
            entry.scope = scopeValue;
            entry.namespace = namespace;
            entry.name = name;
            entry.subKey = subKey;
            entry.value = value;
            entry.persist();
        }
        changedEvent.fireAsync(new PreferenceChanged(tenancyId, scope, namespace));
    }

    @Override
    @Transactional
    public void delete(String tenancyId, Path scope, String namespace, String name, String subKey) {
        PreferencePermissions.assertTenant(tenancyId, principal);
        PreferenceEntry.delete(
                "tenancyId = ?1 and scope = ?2 and namespace = ?3 and name = ?4 and subKey = ?5",
                tenancyId, scope.value(), namespace, name, subKey);
        changedEvent.fireAsync(new PreferenceChanged(tenancyId, scope, namespace));
    }

    @Override
    public List<PreferenceRecord> list(PreferenceQuery query) {
        String scopeValue = query.scope() != null ? query.scope().value() : null;
        List<PreferenceEntry> entries;
        if (scopeValue != null && query.namespace() != null) {
            entries = PreferenceEntry.list("tenancyId = ?1 and scope = ?2 and namespace = ?3",
                    query.tenancyId(), scopeValue, query.namespace());
        } else if (scopeValue != null) {
            entries = PreferenceEntry.list("tenancyId = ?1 and scope = ?2",
                    query.tenancyId(), scopeValue);
        } else if (query.namespace() != null) {
            entries = PreferenceEntry.list("tenancyId = ?1 and namespace = ?2",
                    query.tenancyId(), query.namespace());
        } else {
            entries = PreferenceEntry.list("tenancyId = ?1", query.tenancyId());
        }
        return entries.stream()
                .map(e -> new PreferenceRecord(e.tenancyId, Path.parse(e.scope), e.namespace, e.name, e.subKey, e.value))
                .toList();
    }

    @Override
    @Transactional
    public void deleteAll(String tenancyId, Path scope, String namespace) {
        PreferencePermissions.assertTenant(tenancyId, principal);
        PreferenceEntry.delete("tenancyId = ?1 and scope = ?2 and namespace = ?3",
                tenancyId, scope.value(), namespace);
        changedEvent.fireAsync(new PreferenceChanged(tenancyId, scope, namespace));
    }
}
```

**Note:** `Path.parse(e.scope)` — verify that `Path` has a factory that reconstructs from the stored string value. If `Path.of(...)` takes segments, the store value `"casehubio/devtown"` needs `Path.parse("casehubio/devtown")` or equivalent. Check `Path` API and adjust. If no `parse` method exists, use `Path.of(e.scope.split("/"))` or add `Path.parse()`.

- [ ] **Step 7: Fix JpaPreferenceProviderTest for tenancyId**

Update every `SettingsScope.of(...)` call and every `insert(...)` call to include tenancyId.

Add a constant: `private static final String TENANT = TenancyConstants.DEFAULT_TENANT_ID;`

Update the `insert` helper:
```java
private void insert(String tenancyId, String scope, String namespace, String name, String subKey, String value) {
    PreferenceEntry e = new PreferenceEntry();
    e.tenancyId = tenancyId;
    e.scope = scope;
    e.namespace = namespace;
    e.name = name;
    e.subKey = subKey;
    e.value = value;
    e.persist();
}
```

Update every call site:
- `insert("casehubio/devtown", "test", "count", "", "42")` → `insert(TENANT, "casehubio/devtown", "test", "count", "", "42")`
- `SettingsScope.of("casehubio", "devtown")` → `SettingsScope.of(TENANT, Path.of("casehubio", "devtown"))`
- `SettingsScope.root()` → `SettingsScope.root(TENANT)`

- [ ] **Step 8: Run all tests in persistence-jpa/**

Run: `mvn --batch-mode test -pl persistence-jpa`
Expected: All tests pass — both `JpaPreferenceProviderTest` and `JpaPreferenceStoreTest`.

- [ ] **Step 9: Verify with ide_diagnostics**

Run `ide_diagnostics` on `JpaPreferenceStore.java` and `JpaPreferenceProvider.java` to check for errors.

- [ ] **Step 10: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add persistence-jpa/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#193): JpaPreferenceStore + tenancyId on JPA read path"
```

---

### Task 4: MongoDB Backend — Store + Read-Side tenancyId

**Files:**
- Modify: `persistence-mongodb/src/main/java/io/casehub/platform/persistence/mongodb/MongoPreferenceDocument.java`
- Modify: `persistence-mongodb/src/main/java/io/casehub/platform/persistence/mongodb/MongoPreferenceProvider.java`
- Create: `persistence-mongodb/src/main/java/io/casehub/platform/persistence/mongodb/MongoPreferenceStore.java`
- Modify: `persistence-mongodb/src/test/java/io/casehub/platform/persistence/mongodb/MongoPreferenceProviderTest.java`
- Create: `persistence-mongodb/src/test/java/io/casehub/platform/persistence/mongodb/MongoPreferenceStoreTest.java`

**Interfaces:**
- Consumes: `PreferenceStore`, `PreferenceRecord`, `PreferenceQuery`, `PreferencePermissions`, `PreferenceChanged` (from Task 1)
- Produces: `MongoPreferenceStore @Alternative @Priority(1)` — MongoDB-backed write implementation

- [ ] **Step 1: Update MongoPreferenceDocument for tenancyId**

Add `tenancyId` field via `ide_insert_member`:

```java
public String tenancyId;
```

Update `compoundId` to include tenancyId as leading segment via `ide_replace_member`:

```java
public static String compoundId(final String tenancyId, final String scope, final String namespace,
                                final String name, final String subKey) {
    return tenancyId + "|" + scope + "|" + namespace + "|" + name + "|" + subKey;
}
```

Update `findByScopes` to filter by tenancyId via `ide_replace_member`:

```java
static List<MongoPreferenceDocument> findByScopes(final String tenancyId, final List<String> scopes) {
    if (scopes.isEmpty()) return Collections.emptyList();
    return list(Filters.and(Filters.eq("tenancyId", tenancyId), Filters.in("scope", scopes)));
}
```

- [ ] **Step 2: Update MongoPreferenceProvider to pass tenancyId**

Use `ide_replace_member` on `resolve` in `MongoPreferenceProvider.java`:

```java
final List<String> ancestors = ancestors(scope.scope());
final List<MongoPreferenceDocument> docs = new ArrayList<>(MongoPreferenceDocument.findByScopes(scope.tenancyId(), ancestors));

final Map<String, Integer> scopeOrder = new HashMap<>();
for (int i = 0; i < ancestors.size(); i++) {
    scopeOrder.put(ancestors.get(i), i);
}
docs.sort((a, b) -> Integer.compare(
        scopeOrder.getOrDefault(a.scope, -1),
        scopeOrder.getOrDefault(b.scope, -1)));

final Map<String, Object> merged = new HashMap<>();
for (final MongoPreferenceDocument doc : docs) {
    final String mapKey = doc.subKey.isEmpty()
            ? doc.namespace + "." + doc.name
            : doc.namespace + "." + doc.name + "." + doc.subKey;
    merged.put(mapKey, doc.value);
}

return new MapPreferences(merged);
```

- [ ] **Step 3: Write MongoPreferenceStoreTest**

Create via `ide_create_file`. Same test structure as `JpaPreferenceStoreTest` but for MongoDB context. The test class uses `@QuarkusTest` with MongoDB test profile. Match the existing `MongoPreferenceProviderTest` pattern for test infrastructure setup.

- [ ] **Step 4: Implement MongoPreferenceStore**

Create `persistence-mongodb/src/main/java/io/casehub/platform/persistence/mongodb/MongoPreferenceStore.java` via `ide_create_file`:

```java
package io.casehub.platform.persistence.mongodb;

import io.casehub.platform.api.identity.CurrentPrincipal;
import io.casehub.platform.api.path.Path;
import io.casehub.platform.api.preferences.PreferenceChanged;
import io.casehub.platform.api.preferences.PreferencePermissions;
import io.casehub.platform.api.preferences.PreferenceQuery;
import io.casehub.platform.api.preferences.PreferenceRecord;
import io.casehub.platform.api.preferences.PreferenceStore;
import jakarta.annotation.Priority;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.event.Event;
import jakarta.enterprise.inject.Alternative;
import jakarta.inject.Inject;

import java.util.List;

@ApplicationScoped
@Alternative
@Priority(1)
public class MongoPreferenceStore implements PreferenceStore {

    @Inject CurrentPrincipal principal;
    @Inject Event<PreferenceChanged> changedEvent;

    @Override
    public void set(String tenancyId, Path scope, String namespace, String name, String subKey, String value) {
        PreferencePermissions.assertTenant(tenancyId, principal);
        String id = MongoPreferenceDocument.compoundId(tenancyId, scope.value(), namespace, name, subKey);
        MongoPreferenceDocument existing = MongoPreferenceDocument.findById(id);
        if (existing != null) {
            existing.value = value;
            existing.update();
        } else {
            MongoPreferenceDocument doc = new MongoPreferenceDocument();
            doc.id = id;
            doc.tenancyId = tenancyId;
            doc.scope = scope.value();
            doc.namespace = namespace;
            doc.name = name;
            doc.subKey = subKey;
            doc.value = value;
            doc.persist();
        }
        changedEvent.fireAsync(new PreferenceChanged(tenancyId, scope, namespace));
    }

    @Override
    public void delete(String tenancyId, Path scope, String namespace, String name, String subKey) {
        PreferencePermissions.assertTenant(tenancyId, principal);
        String id = MongoPreferenceDocument.compoundId(tenancyId, scope.value(), namespace, name, subKey);
        MongoPreferenceDocument.deleteById(id);
        changedEvent.fireAsync(new PreferenceChanged(tenancyId, scope, namespace));
    }

    @Override
    public List<PreferenceRecord> list(PreferenceQuery query) {
        List<MongoPreferenceDocument> docs;
        if (query.scope() != null && query.namespace() != null) {
            docs = MongoPreferenceDocument.list("tenancyId = ?1 and scope = ?2 and namespace = ?3",
                    query.tenancyId(), query.scope().value(), query.namespace());
        } else if (query.scope() != null) {
            docs = MongoPreferenceDocument.list("tenancyId = ?1 and scope = ?2",
                    query.tenancyId(), query.scope().value());
        } else {
            docs = MongoPreferenceDocument.list("tenancyId = ?1", query.tenancyId());
        }
        return docs.stream()
                .map(d -> new PreferenceRecord(d.tenancyId, Path.parse(d.scope), d.namespace, d.name, d.subKey, d.value))
                .toList();
    }

    @Override
    public void deleteAll(String tenancyId, Path scope, String namespace) {
        PreferencePermissions.assertTenant(tenancyId, principal);
        MongoPreferenceDocument.delete("tenancyId = ?1 and scope = ?2 and namespace = ?3",
                tenancyId, scope.value(), namespace);
        changedEvent.fireAsync(new PreferenceChanged(tenancyId, scope, namespace));
    }
}
```

- [ ] **Step 5: Fix MongoPreferenceProviderTest for tenancyId**

Same pattern as JPA test fixes in Task 3, Step 7. Add tenancyId to all `insert()` calls and update all `SettingsScope.of(...)` calls.

- [ ] **Step 6: Run all tests in persistence-mongodb/**

Run: `mvn --batch-mode test -pl persistence-mongodb`
Expected: All tests pass.

- [ ] **Step 7: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add persistence-mongodb/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#193): MongoPreferenceStore + tenancyId on MongoDB read path"
```

---

### Task 5: REST Module (preferences-editor/)

**Files:**
- Create: `preferences-editor/pom.xml`
- Modify: `pom.xml` (parent — add `<module>preferences-editor</module>`)
- Create: `preferences-editor/src/main/java/io/casehub/platform/preferences/editor/PreferenceResource.java`
- Create: `preferences-editor/src/main/java/io/casehub/platform/preferences/editor/PreferenceInput.java`
- Create: `preferences-editor/src/main/java/io/casehub/platform/preferences/editor/ResolvedPreferencesResponse.java`
- Create: `preferences-editor/src/test/java/io/casehub/platform/preferences/editor/PreferenceResourceTest.java`
- Create: `preferences-editor/src/test/resources/application.properties`

**Interfaces:**
- Consumes: `PreferenceStore`, `PreferenceRecord`, `PreferenceQuery`, `PreferenceProvider`, `CurrentPrincipal`, `SettingsScope` (from Tasks 1-2)
- Produces: REST API at `/preferences` — consumed by blocks-ui#92

- [ ] **Step 1: Create module pom.xml**

Create `preferences-editor/pom.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0
                             http://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>

    <parent>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-platform-parent</artifactId>
        <version>0.2-SNAPSHOT</version>
    </parent>

    <artifactId>casehub-platform-preferences-editor</artifactId>
    <name>CaseHub Platform :: Preferences Editor REST</name>
    <description>REST API for writing preferences to any backend</description>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-api</artifactId>
            <version>${project.version}</version>
        </dependency>

        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-rest</artifactId>
        </dependency>
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-rest-jackson</artifactId>
        </dependency>
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-arc</artifactId>
        </dependency>

        <!-- Test -->
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform</artifactId>
            <version>${project.version}</version>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-testing</artifactId>
            <version>${project.version}</version>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-junit</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>io.rest-assured</groupId>
            <artifactId>rest-assured</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.assertj</groupId>
            <artifactId>assertj-core</artifactId>
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

- [ ] **Step 2: Add module to parent pom**

Add `<module>preferences-editor</module>` after `platform-view-jpa` in the parent `pom.xml`.

- [ ] **Step 3: Create DTOs**

Create `preferences-editor/src/main/java/io/casehub/platform/preferences/editor/PreferenceInput.java` via `ide_create_file`:

```java
package io.casehub.platform.preferences.editor;

public record PreferenceInput(String namespace, String name, String subKey, String value) {
    public PreferenceInput {
        if (namespace == null || namespace.isBlank()) throw new IllegalArgumentException("namespace is required");
        if (name == null || name.isBlank()) throw new IllegalArgumentException("name is required");
        if (value == null) throw new IllegalArgumentException("value is required");
        if (subKey == null) subKey = "";
    }
}
```

Create `preferences-editor/src/main/java/io/casehub/platform/preferences/editor/ResolvedPreferencesResponse.java` via `ide_create_file`:

```java
package io.casehub.platform.preferences.editor;

import java.util.Map;

public record ResolvedPreferencesResponse(String scope, Map<String, String> values) {}
```

- [ ] **Step 4: Write PreferenceResourceTest**

Create `preferences-editor/src/test/java/io/casehub/platform/preferences/editor/PreferenceResourceTest.java` via `ide_create_file`:

```java
package io.casehub.platform.preferences.editor;

import io.quarkus.test.junit.QuarkusTest;
import io.restassured.http.ContentType;
import org.junit.jupiter.api.Test;

import static io.restassured.RestAssured.given;
import static org.hamcrest.Matchers.*;

@QuarkusTest
class PreferenceResourceTest {

    @Test
    void set_and_list_preference() {
        given()
            .contentType(ContentType.JSON)
            .body("""
                {"namespace": "test", "name": "count", "subKey": "", "value": "42"}
                """)
            .queryParam("scope", "casehubio/devtown")
        .when()
            .put("/preferences")
        .then()
            .statusCode(204);

        given()
            .queryParam("scope", "casehubio/devtown")
        .when()
            .get("/preferences")
        .then()
            .statusCode(200)
            .body("size()", is(1))
            .body("[0].name", is("count"))
            .body("[0].value", is("42"));
    }

    @Test
    void delete_single_preference() {
        given()
            .contentType(ContentType.JSON)
            .body("""
                {"namespace": "test", "name": "deleteMe", "subKey": "", "value": "x"}
                """)
            .queryParam("scope", "casehubio")
        .when()
            .put("/preferences")
        .then()
            .statusCode(204);

        given()
            .queryParam("scope", "casehubio")
            .queryParam("namespace", "test")
            .queryParam("name", "deleteMe")
        .when()
            .delete("/preferences")
        .then()
            .statusCode(204);

        given()
            .queryParam("scope", "casehubio")
        .when()
            .get("/preferences")
        .then()
            .statusCode(200)
            .body("size()", is(0));
    }

    @Test
    void delete_without_name_returns_400() {
        given()
            .queryParam("scope", "casehubio")
            .queryParam("namespace", "test")
        .when()
            .delete("/preferences")
        .then()
            .statusCode(400);
    }

    @Test
    void delete_namespace() {
        given()
            .contentType(ContentType.JSON)
            .body("""
                {"namespace": "bulk", "name": "a", "subKey": "", "value": "1"}
                """)
            .queryParam("scope", "casehubio")
        .when()
            .put("/preferences")
        .then()
            .statusCode(204);

        given()
            .queryParam("scope", "casehubio")
            .queryParam("namespace", "bulk")
        .when()
            .delete("/preferences/by-namespace")
        .then()
            .statusCode(204);

        given()
            .queryParam("scope", "casehubio")
        .when()
            .get("/preferences")
        .then()
            .statusCode(200)
            .body("size()", is(0));
    }

    @Test
    void resolved_returns_inherited_values() {
        given()
            .contentType(ContentType.JSON)
            .body("""
                {"namespace": "test", "name": "base", "subKey": "", "value": "root"}
                """)
            .queryParam("scope", "")
        .when()
            .put("/preferences")
        .then()
            .statusCode(204);

        given()
            .queryParam("scope", "casehubio/devtown")
        .when()
            .get("/preferences/resolved")
        .then()
            .statusCode(200)
            .body("scope", is("casehubio/devtown"))
            .body("values", hasKey("test.base"));
    }
}
```

Create `preferences-editor/src/test/resources/application.properties`:

```properties
quarkus.arc.remove-unused-beans=false
```

- [ ] **Step 5: Run test to verify it fails**

Run: `mvn --batch-mode test -pl preferences-editor -Dtest=PreferenceResourceTest`
Expected: Compilation failure — `PreferenceResource` does not exist

- [ ] **Step 6: Implement PreferenceResource**

Create `preferences-editor/src/main/java/io/casehub/platform/preferences/editor/PreferenceResource.java` via `ide_create_file`:

```java
package io.casehub.platform.preferences.editor;

import io.casehub.platform.api.identity.CurrentPrincipal;
import io.casehub.platform.api.path.Path;
import io.casehub.platform.api.preferences.PreferenceProvider;
import io.casehub.platform.api.preferences.PreferenceQuery;
import io.casehub.platform.api.preferences.PreferenceRecord;
import io.casehub.platform.api.preferences.PreferenceStore;
import io.casehub.platform.api.preferences.Preferences;
import io.casehub.platform.api.preferences.SettingsScope;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import jakarta.ws.rs.DELETE;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.PUT;
import jakarta.ws.rs.QueryParam;
import jakarta.ws.rs.core.Response;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

@ApplicationScoped
@jakarta.ws.rs.Path("/preferences")
public class PreferenceResource {

    @Inject PreferenceStore store;
    @Inject PreferenceProvider provider;
    @Inject CurrentPrincipal principal;

    @PUT
    public Response set(@QueryParam("scope") String scopeParam, PreferenceInput input) {
        Path scope = parseScopePath(scopeParam);
        store.set(principal.tenancyId(), scope, input.namespace(), input.name(), input.subKey(), input.value());
        return Response.noContent().build();
    }

    @DELETE
    public Response delete(@QueryParam("scope") String scopeParam,
                           @QueryParam("namespace") String namespace,
                           @QueryParam("name") String name,
                           @QueryParam("subKey") String subKey) {
        if (name == null || name.isBlank()) {
            return Response.status(400).entity("name is required for single-delete").build();
        }
        Path scope = parseScopePath(scopeParam);
        store.delete(principal.tenancyId(), scope, namespace, name, subKey != null ? subKey : "");
        return Response.noContent().build();
    }

    @DELETE
    @jakarta.ws.rs.Path("/by-namespace")
    public Response deleteNamespace(@QueryParam("scope") String scopeParam,
                                    @QueryParam("namespace") String namespace) {
        Path scope = parseScopePath(scopeParam);
        store.deleteAll(principal.tenancyId(), scope, namespace);
        return Response.noContent().build();
    }

    @GET
    public List<PreferenceRecord> list(@QueryParam("scope") String scopeParam) {
        Path scope = parseScopePath(scopeParam);
        return store.list(new PreferenceQuery(principal.tenancyId(), scope, null));
    }

    @GET
    @jakarta.ws.rs.Path("/resolved")
    public ResolvedPreferencesResponse resolved(@QueryParam("scope") String scopeParam) {
        Path scope = parseScopePath(scopeParam);
        Preferences resolved = provider.resolve(SettingsScope.of(principal.tenancyId(), scope));
        Map<String, String> values = new HashMap<>();
        resolved.asMap().forEach((k, v) -> values.put(k, String.valueOf(v)));
        return new ResolvedPreferencesResponse(scopeParam != null ? scopeParam : "", values);
    }

    private static Path parseScopePath(String scopeParam) {
        if (scopeParam == null || scopeParam.isBlank()) return Path.root();
        String[] segments = scopeParam.split("/");
        return Path.of(segments);
    }
}
```

- [ ] **Step 7: Run tests**

Run: `mvn --batch-mode test -pl preferences-editor`
Expected: All tests pass.

- [ ] **Step 8: Run full build**

Run: `mvn --batch-mode install`
Expected: Full reactor builds clean. All modules pass.

- [ ] **Step 9: Verify with ide_diagnostics**

Run `ide_diagnostics` on `PreferenceResource.java` to check for errors.

- [ ] **Step 10: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add preferences-editor/ pom.xml
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#193): preferences-editor REST module"
```

---

## Implementation Notes

**Path.parse() vs Path.of():** The `JpaPreferenceStore` and `MongoPreferenceStore` need to reconstruct a `Path` from the stored string value (e.g. `"casehubio/devtown"`). Verify at implementation time whether `Path` has a `parse(String)` factory. If not, use `Path.of(storedValue.split("/"))` or add `Path.parse()` to platform-api.

**H2 PostgreSQL mode for upsert:** The JPA test uses H2 in PostgreSQL mode. `INSERT ... ON CONFLICT ... DO UPDATE` may need to be implemented as a find-then-persist pattern in `JpaPreferenceStore` rather than native SQL upsert, since H2's PostgreSQL compatibility doesn't cover all ON CONFLICT syntax. The plan already uses the find-then-persist approach.

**MongoDB test infrastructure:** Check how `MongoPreferenceProviderTest` bootstraps its test environment (e.g. Flapdoodle embedded MongoDB, Testcontainers, or de.flapdoodle). Match that pattern for `MongoPreferenceStoreTest`.

**`testing/` module:** The testing module's `FixedCurrentPrincipal` may not use `SettingsScope` directly. Verify at implementation time — if no `SettingsScope` references exist in `testing/`, no changes are needed there.
