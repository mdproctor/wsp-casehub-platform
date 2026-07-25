# Retire Hibernate Reactive from ACL Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #202 — refactor: retire Hibernate Reactive from acl-jpa — convert AccessControlProvider SPI to blocking + virtual threads
**Issue group:** #202

**Goal:** Convert the ACL subsystem from Hibernate Reactive / CompletionStage to standard blocking Hibernate ORM, matching the pattern established by #384 across all other platform JPA modules.

**Architecture:** The `AccessControlProvider` SPI changes from `CompletionStage<T>` to blocking returns. `acl-jpa` swaps Hibernate Reactive Panache for standard Hibernate ORM Panache with `@Transactional`. `acl-inmem` drops `CompletableFuture` ceremony. All tests update to call methods directly. Zero cross-repo callers — fully self-contained.

**Tech Stack:** Quarkus, Hibernate ORM Panache (blocking), JPA, PostgreSQL (DevServices for tests)

## Global Constraints

- No Flyway migrations — schema is unchanged
- No cross-repo propagation — zero consumers reference `AccessControlProvider`
- Follow post-#384 patterns established in `persistence-jpa/`, `memory-jpa/`, etc.
- `project_path` for all IntelliJ MCP calls: `/Users/mdproctor/claude/casehub/platform`

---

### Task 1: Convert AccessControlProvider SPI to blocking

**Files:**
- Modify: `platform-api/src/main/java/io/casehub/platform/api/acl/AccessControlProvider.java`
- Modify: `platform-api/src/test/java/io/casehub/platform/api/acl/AccessControlProviderSpiTest.java`
- Modify: `platform-api/src/test/java/io/casehub/platform/api/acl/AccessControlProviderContractTest.java`

**Interfaces:**
- Produces: Blocking `AccessControlProvider` SPI — `boolean canAccess(String, String, AclAction)`, `void grant(String, String, AclAction, Instant)`, `void revoke(String, String, AclAction)`, `void revokeAll(String, String)`, `void registerParent(String, String)`, `List<String> accessibleResources(String, String, AclAction)`. All tasks consume this.

- [ ] **Step 1: Update the SPI interface**

Use `ide_edit_member` with `member=AccessControlProvider` to replace the full interface declaration. New content:

```java
public interface AccessControlProvider {

    default boolean canAccess(String actorId, String resourceId, AclAction action) {
        return true;
    }

    default void grant(String actorId, String resourceId, AclAction action, Instant expires) {
    }

    default void revoke(String actorId, String resourceId, AclAction action) {
    }

    default void revokeAll(String actorId, String resourceId) {
    }

    default void registerParent(String childResourceId, String parentResourceId) {
    }

    default List<String> accessibleResources(String actorId, String resourceType, AclAction action) {
        return List.of();
    }
}
```

Remove `CompletableFuture` and `CompletionStage` imports via `ide_optimize_imports`.

- [ ] **Step 2: Update AccessControlProviderSpiTest**

Use `ide_edit_member` on each test method. Remove all `.toCompletableFuture().join()` calls. Replace the full class body:

```java
class AccessControlProviderSpiTest {

    private final AccessControlProvider spi = new AccessControlProvider() {};

    @Test
    void canAccess_defaultReturnsTrue() {
        assertTrue(spi.canAccess("actor", "case:abc", AclAction.READ));
    }

    @Test
    void grant_defaultIsNoOp() {
        assertDoesNotThrow(() -> spi.grant("actor", "case:abc", AclAction.READ, Instant.now()));
    }

    @Test
    void revoke_defaultIsNoOp() {
        assertDoesNotThrow(() -> spi.revoke("actor", "case:abc", AclAction.READ));
    }

    @Test
    void revokeAll_defaultIsNoOp() {
        assertDoesNotThrow(() -> spi.revokeAll("actor", "case:abc"));
    }

    @Test
    void registerParent_defaultIsNoOp() {
        assertDoesNotThrow(() -> spi.registerParent("child:1", "parent:1"));
    }

    @Test
    void accessibleResources_defaultReturnsEmpty() {
        assertTrue(spi.accessibleResources("actor", AclResourceType.CASE, AclAction.READ).isEmpty());
    }
}
```

Remove unused `CompletionStage` import via `ide_optimize_imports`.

- [ ] **Step 3: Update AccessControlProviderContractTest**

Remove the `await()` helper method. Update every test to call provider methods directly. The full class has 25 test methods — every `await(provider().xxx(...))` becomes `provider().xxx(...)`. Every `assertTrue(await(...))` becomes `assertTrue(provider().xxx(...))`. Every `assertFalse(await(...))` becomes `assertFalse(provider().xxx(...))`.

Remove `CompletionStage` import via `ide_optimize_imports`.

- [ ] **Step 4: Run platform-api tests**

Run: `mvn --batch-mode test -pl platform-api -o`
Expected: All tests pass — SPI defaults work, contract test compiles (abstract, no runner).

- [ ] **Step 5: Commit**

```
git add platform-api/
git commit -m "refactor(#202): convert AccessControlProvider SPI to blocking returns

Drop CompletionStage from all 6 methods. Default implementations
return direct values. Zero cross-repo callers.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Convert InMemoryAccessControlProvider to blocking

**Files:**
- Modify: `acl-inmem/src/main/java/io/casehub/platform/acl/inmem/InMemoryAccessControlProvider.java`
- Modify: `acl-inmem/src/test/java/io/casehub/platform/acl/inmem/InMemoryAccessControlProviderTest.java`

**Interfaces:**
- Consumes: Blocking `AccessControlProvider` from Task 1

- [ ] **Step 1: Update InMemoryAccessControlProvider**

Strip all `CompletableFuture.completedFuture()` wrappers from every method. Change return types to match the new SPI. Use `ide_edit_member` for each method:

`canAccess`: return `canAccessWithCandidates(candidates, resourceId, action, 0)` directly (already returns `boolean`).

`grant`: return nothing — just `grants.put(...)`.

`revoke`: return nothing — just `grants.remove(...)`.

`revokeAll`: return nothing — just loop and remove.

`registerParent`: return nothing — just `parents.put(...)`.

`accessibleResources`: return `new ArrayList<>(seen)` directly.

Remove `CompletableFuture`, `CompletionStage` imports via `ide_optimize_imports`.

- [ ] **Step 2: Run acl-inmem tests**

Run: `mvn --batch-mode test -pl acl-inmem -o`
Expected: All 25 contract tests pass. `InMemoryAccessControlProviderTest` inherits from the updated contract test — no changes needed to the test class itself.

- [ ] **Step 3: Commit**

```
git add acl-inmem/
git commit -m "refactor(#202): strip CompletableFuture wrappers from InMemoryAccessControlProvider

Return values directly. No behavioral change.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Convert acl-jpa to standard Hibernate ORM

**Files:**
- Modify: `acl-jpa/pom.xml`
- Modify: `acl-jpa/src/main/java/io/casehub/platform/acl/jpa/AclEntryEntity.java`
- Modify: `acl-jpa/src/main/java/io/casehub/platform/acl/jpa/AclAuditLogEntity.java`
- Modify: `acl-jpa/src/main/java/io/casehub/platform/acl/jpa/ResourceParentEntity.java`
- Modify: `acl-jpa/src/main/java/io/casehub/platform/acl/jpa/JpaAccessControlProvider.java`
- Modify: `acl-jpa/src/test/java/io/casehub/platform/acl/jpa/JpaAccessControlProviderTest.java`
- Modify: `acl-jpa/src/test/resources/application.properties`

**Interfaces:**
- Consumes: Blocking `AccessControlProvider` from Task 1

- [ ] **Step 1: Update pom.xml dependencies**

Use the Edit tool (pom.xml is not a Java source file):

Replace `quarkus-hibernate-reactive-panache` with `quarkus-hibernate-orm-panache`.
Remove `quarkus-reactive-pg-client` dependency entirely.
Remove `quarkus-test-vertx` (test scope) dependency entirely.

- [ ] **Step 2: Update entity imports**

For each of the 3 entities (`AclEntryEntity`, `AclAuditLogEntity`, `ResourceParentEntity`):

Use `ide_replace_text_in_file` to replace `io.quarkus.hibernate.reactive.panache.PanacheEntityBase` with `io.quarkus.hibernate.orm.panache.PanacheEntityBase`.

- [ ] **Step 3: Rewrite JpaAccessControlProvider**

Use `ide_edit_member` with `member=JpaAccessControlProvider` to replace the full class. The new implementation:

- `@ApplicationScoped`, implements `AccessControlProvider`
- Injects `GroupMembershipProvider`, `CurrentPrincipal` (no `Vertx`)
- `canAccess`: calls `buildCandidateSet`, then blocking `canAccessWithCandidates`
- `grant`: `@Transactional`, uses blocking `AclEntryEntity.list(...)`, `.persist()`, audit log
- `revoke`: `@Transactional`, uses blocking `AclEntryEntity.delete(...)`, audit log
- `revokeAll`: `@Transactional`, uses blocking `AclEntryEntity.list(...)`, loop with audit, then delete
- `registerParent`: `@Transactional`, uses blocking `ResourceParentEntity.findById(...)`, `.persist()`
- `accessibleResources`: uses blocking `AclEntryEntity.find(...).project(String.class).list()`
- `buildCandidateSet`: unchanged (already blocking)
- `canAccessWithCandidates`: plain recursive `boolean` method — `AclEntryEntity.count(...)`, `ResourceParentEntity.findById(...)`, recurse
- No `execute()` helper, no Uni, no Vertx context

Full implementation:

```java
@ApplicationScoped
public class JpaAccessControlProvider implements AccessControlProvider {

    @Inject
    GroupMembershipProvider groupMembership;

    @Inject
    CurrentPrincipal principal;

    @Override
    public boolean canAccess(String actorId, String resourceId, AclAction action) {
        Set<String> candidates = buildCandidateSet(actorId);
        return canAccessWithCandidates(candidates, resourceId, action, 0);
    }

    @Override
    @Transactional
    public void grant(String actorId, String resourceId, AclAction action, Instant expires) {
        Instant now = Instant.now();

        List<AclEntryEntity> existing = AclEntryEntity.list(
                "actorId = ?1 and resourceId = ?2 and action = ?3",
                actorId, resourceId, action.name());
        if (!existing.isEmpty()) {
            AclEntryEntity entry = existing.getFirst();
            entry.expiresAt = expires;
            entry.grantedAt = now;
            entry.persist();
        } else {
            AclEntryEntity entry = new AclEntryEntity();
            entry.actorId = actorId;
            entry.resourceId = resourceId;
            entry.action = action.name();
            entry.grantedAt = now;
            entry.expiresAt = expires;
            entry.tenancyId = principal.tenancyId();
            entry.persist();
        }

        AclAuditLogEntity log = new AclAuditLogEntity();
        log.actorId = actorId;
        log.resourceId = resourceId;
        log.action = action.name();
        log.operation = "GRANT";
        log.performedBy = principal.actorId();
        log.performedAt = now;
        log.expiresAt = expires;
        log.tenancyId = principal.tenancyId();
        log.persist();
    }

    @Override
    @Transactional
    public void revoke(String actorId, String resourceId, AclAction action) {
        long count = AclEntryEntity.delete(
                "actorId = ?1 and resourceId = ?2 and action = ?3",
                actorId, resourceId, action.name());
        if (count > 0) {
            AclAuditLogEntity log = new AclAuditLogEntity();
            log.actorId = actorId;
            log.resourceId = resourceId;
            log.action = action.name();
            log.operation = "REVOKE";
            log.performedBy = principal.actorId();
            log.performedAt = Instant.now();
            log.tenancyId = principal.tenancyId();
            log.persist();
        }
    }

    @Override
    @Transactional
    public void revokeAll(String actorId, String resourceId) {
        Instant now = Instant.now();
        List<AclEntryEntity> entries = AclEntryEntity.list(
                "actorId = ?1 and resourceId = ?2", actorId, resourceId);
        for (AclEntryEntity entry : entries) {
            AclAuditLogEntity log = new AclAuditLogEntity();
            log.actorId = actorId;
            log.resourceId = resourceId;
            log.action = entry.action;
            log.operation = "REVOKE";
            log.performedBy = principal.actorId();
            log.performedAt = now;
            log.tenancyId = principal.tenancyId();
            log.persist();
        }
        AclEntryEntity.delete("actorId = ?1 and resourceId = ?2", actorId, resourceId);
    }

    @Override
    @Transactional
    public void registerParent(String childResourceId, String parentResourceId) {
        ResourceParentEntity existing = ResourceParentEntity.findById(childResourceId);
        if (existing == null) {
            ResourceParentEntity rp = new ResourceParentEntity();
            rp.childResourceId = childResourceId;
            rp.parentResourceId = parentResourceId;
            rp.tenancyId = principal.tenancyId();
            rp.persist();
        } else {
            existing.parentResourceId = parentResourceId;
            existing.persist();
        }
    }

    @Override
    public List<String> accessibleResources(String actorId, String resourceType, AclAction action) {
        Set<String> candidates = buildCandidateSet(actorId);
        String escaped = resourceType.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_");
        String prefix = escaped + ":%";
        return AclEntryEntity.find(
                        "select distinct e.resourceId from AclEntryEntity e " +
                                "where e.action = ?1 " +
                                "and (e.expiresAt is null or e.expiresAt > ?2) " +
                                "and e.actorId in ?3 " +
                                "and e.resourceId like ?4 escape '\\'",
                        action.name(), Instant.now(), candidates, prefix)
                .project(String.class)
                .list();
    }

    private Set<String> buildCandidateSet(String actorId) {
        Set<String> candidates = new HashSet<>();
        candidates.add(actorId);
        for (String group : groupMembership.groupsOf(actorId)) {
            candidates.add("group:" + group);
        }
        return candidates;
    }

    private boolean canAccessWithCandidates(Set<String> candidates, String resourceId,
                                            AclAction action, int depth) {
        if (depth > 20) return false;

        long count = AclEntryEntity.count(
                "actorId in ?1 and resourceId = ?2 and action = ?3 " +
                        "and (expiresAt is null or expiresAt > ?4)",
                candidates, resourceId, action.name(), Instant.now());
        if (count > 0) return true;

        ResourceParentEntity parent = ResourceParentEntity.findById(resourceId);
        if (parent != null) {
            return canAccessWithCandidates(candidates, parent.parentResourceId, action, depth + 1);
        }
        return false;
    }
}
```

Imports needed: `io.casehub.platform.api.acl.AccessControlProvider`, `io.casehub.platform.api.acl.AclAction`, `io.casehub.platform.api.identity.CurrentPrincipal`, `io.casehub.platform.api.identity.GroupMembershipProvider`, `jakarta.enterprise.context.ApplicationScoped`, `jakarta.inject.Inject`, `jakarta.transaction.Transactional`, `java.time.Instant`, `java.util.HashSet`, `java.util.List`, `java.util.Set`.

No Vertx, no Uni, no Panache (session/transaction), no VertxContextSafetyToggle, no VertxContext, no CompletionStage, no Supplier.

- [ ] **Step 4: Update application.properties**

Use the Edit tool to update the stale comment:

Replace `# Flyway creates schema via JDBC; reactive Hibernate validates mapping` with `# Flyway creates schema; Hibernate ORM validates mapping`.

- [ ] **Step 5: Rewrite JpaAccessControlProviderTest**

Remove the `reactive()` helper, all Vertx/Uni imports, and `quarkus-test-vertx` usage. The test becomes:

- `clearState()`: uses `@Transactional` on a helper or calls entity deletes in a transaction
- Audit log assertion tests: use direct Panache entity queries (blocking)
- Contract tests: inherited from the updated contract test — work automatically

The `clearState()` method needs to run inside a transaction. Since `AccessControlProviderContractTest.clearState()` is called from `@BeforeEach`, and the contract test is not a CDI bean, use a `@Transactional` helper injected into the test.

Full test class:

```java
@QuarkusTest
class JpaAccessControlProviderTest extends AccessControlProviderContractTest {

    @Inject
    JpaAccessControlProvider jpaProvider;

    @Inject
    TestGroupMembershipProvider testGroupMembership;

    @Inject
    TestDataCleaner cleaner;

    @Override
    protected AccessControlProvider provider() {
        return jpaProvider;
    }

    @Override
    protected GroupMembershipProvider groupMembership() {
        return testGroupMembership;
    }

    @Override
    protected void clearState() {
        cleaner.deleteAll();
    }

    @Test
    void grant_createsAuditLogEntry() {
        jpaProvider.grant("actor1", "case:abc", AclAction.READ, null);

        List<AclAuditLogEntity> logs = AclAuditLogEntity.list("actorId", "actor1");

        assertEquals(1, logs.size());
        AclAuditLogEntity log = logs.getFirst();
        assertEquals("actor1", log.actorId);
        assertEquals("case:abc", log.resourceId);
        assertEquals("READ", log.action);
        assertEquals("GRANT", log.operation);
        assertEquals("system", log.performedBy);
        assertNotNull(log.performedAt);
        assertNull(log.expiresAt);
    }

    @Test
    void grant_withExpiry_recordsExpiresAtInAuditLog() {
        Instant expires = Instant.now().plus(1, ChronoUnit.HOURS);
        jpaProvider.grant("actor1", "case:abc", AclAction.WRITE, expires);

        List<AclAuditLogEntity> logs = AclAuditLogEntity.list("actorId", "actor1");

        assertEquals(1, logs.size());
        assertNotNull(logs.getFirst().expiresAt);
    }

    @Test
    void revoke_createsAuditLogEntry() {
        jpaProvider.grant("actor1", "case:abc", AclAction.READ, null);
        jpaProvider.revoke("actor1", "case:abc", AclAction.READ);

        List<AclAuditLogEntity> logs = AclAuditLogEntity.list(
                "actorId = ?1 and operation = ?2", "actor1", "REVOKE");

        assertEquals(1, logs.size());
        AclAuditLogEntity log = logs.getFirst();
        assertEquals("REVOKE", log.operation);
        assertEquals("case:abc", log.resourceId);
        assertEquals("READ", log.action);
        assertEquals("system", log.performedBy);
    }

    @Test
    void grant_andRevoke_createsTwoAuditLogEntries() {
        jpaProvider.grant("actor1", "case:abc", AclAction.READ, null);
        jpaProvider.revoke("actor1", "case:abc", AclAction.READ);

        long total = AclAuditLogEntity.count("actorId", "actor1");

        assertEquals(2, total);
    }

    @Test
    void revokeAll_createsAuditLogEntryPerAction() {
        jpaProvider.grant("actor1", "case:abc", AclAction.READ, null);
        jpaProvider.grant("actor1", "case:abc", AclAction.WRITE, null);
        jpaProvider.revokeAll("actor1", "case:abc");

        List<AclAuditLogEntity> revokeLogs = AclAuditLogEntity.list(
                "actorId = ?1 and operation = ?2", "actor1", "REVOKE");

        assertEquals(2, revokeLogs.size());
        List<String> actions = revokeLogs.stream().map(l -> l.action).sorted().toList();
        assertEquals(List.of("READ", "WRITE"), actions);
    }

    @Test
    void revokeAll_noGrants_createsNoAuditLog() {
        jpaProvider.revokeAll("actor1", "case:abc");

        long count = AclAuditLogEntity.count("actorId", "actor1");

        assertEquals(0, count);
    }

    @Test
    void grant_duplicate_createsTwoAuditLogEntries() {
        jpaProvider.grant("actor1", "case:abc", AclAction.READ, null);
        jpaProvider.grant("actor1", "case:abc", AclAction.READ, null);

        long grantCount = AclAuditLogEntity.count(
                "actorId = ?1 and operation = ?2", "actor1", "GRANT");

        assertEquals(2, grantCount);
    }

    @Test
    @Transactional
    void condition_persistedOnEntry() {
        AclEntryEntity entry = new AclEntryEntity();
        entry.actorId = "actor1";
        entry.resourceId = "case:abc";
        entry.action = "READ";
        entry.condition = "status == 'RUNNING'";
        entry.grantedAt = Instant.now();
        entry.tenancyId = "";
        entry.persist();

        AclEntryEntity found = AclEntryEntity.<AclEntryEntity>find(
                        "actorId = ?1 and resourceId = ?2", "actor1", "case:abc")
                .firstResult();

        assertNotNull(found);
        assertEquals("status == 'RUNNING'", found.condition);
    }

    @Test
    void condition_nullByDefault() {
        jpaProvider.grant("actor1", "case:abc", AclAction.READ, null);

        AclEntryEntity found = AclEntryEntity.<AclEntryEntity>find(
                        "actorId = ?1 and resourceId = ?2", "actor1", "case:abc")
                .firstResult();

        assertNotNull(found);
        assertNull(found.condition);
    }

    @Test
    void auditLog_tenancyIdFromPrincipal() {
        jpaProvider.grant("actor1", "case:abc", AclAction.READ, null);

        AclAuditLogEntity log = AclAuditLogEntity.<AclAuditLogEntity>find("actorId", "actor1")
                .firstResult();

        assertNotNull(log);
        assertNotNull(log.tenancyId);
        assertFalse(log.tenancyId.isEmpty());
    }
}
```

- [ ] **Step 6: Create TestDataCleaner**

Create `acl-jpa/src/test/java/io/casehub/platform/acl/jpa/TestDataCleaner.java` via `ide_create_file`:

```java
package io.casehub.platform.acl.jpa;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.transaction.Transactional;

@ApplicationScoped
public class TestDataCleaner {

    @Transactional
    public void deleteAll() {
        AclAuditLogEntity.deleteAll();
        AclEntryEntity.deleteAll();
        ResourceParentEntity.deleteAll();
    }
}
```

- [ ] **Step 7: Run acl-jpa tests**

Run: `mvn --batch-mode test -pl acl-jpa`
Expected: All 25 contract tests + 11 JPA-specific tests pass.

Note: cannot use `-o` here — the POM changed, Maven needs to resolve the new `quarkus-hibernate-orm-panache` dependency.

- [ ] **Step 8: Commit**

```
git add acl-jpa/
git commit -m "refactor(#202): convert acl-jpa from Hibernate Reactive to standard Hibernate ORM

Swap quarkus-hibernate-reactive-panache for quarkus-hibernate-orm-panache.
Rewrite JpaAccessControlProvider to blocking Panache + @Transactional.
Remove Vertx context plumbing. No schema changes.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Update MockBeansTest and clean up CLAUDE.md

**Files:**
- Modify: `platform/src/test/java/io/casehub/platform/mock/MockBeansTest.java`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: Blocking `AccessControlProvider` from Task 1

- [ ] **Step 1: Update MockBeansTest**

Two test methods need updating:

`accessControl_noOp_allows_all` (line 133): change
`assertTrue(accessControl.canAccess("any-actor", "case:any", AclAction.READ).toCompletableFuture().join())`
to `assertTrue(accessControl.canAccess("any-actor", "case:any", AclAction.READ))`.

`accessControl_noOp_accessibleResources_returns_empty` (line 138): change
`assertTrue(accessControl.accessibleResources("any-actor", "case", AclAction.READ).toCompletableFuture().join().isEmpty())`
to `assertTrue(accessControl.accessibleResources("any-actor", "case", AclAction.READ).isEmpty())`.

Use `ide_replace_member` for each test method.

- [ ] **Step 2: Run platform tests**

Run: `mvn --batch-mode test -pl platform -o`
Expected: All MockBeansTest tests pass.

- [ ] **Step 3: Clean up CLAUDE.md**

Use the Edit tool to remove `ReactiveCaseMemoryStore (Mutiny SPI),` from the `.memory` line in the Package Structure section. The line should read:

```
  .memory        — CaseMemoryStore (blocking SPI) + GraphCaseMemoryStore (graph-native extension: graphQuery(GraphMemoryQuery)),
```

Also update the `acl-jpa/` module description to reflect the conversion: change `Hibernate Reactive Panache` to `Hibernate ORM Panache (blocking-only)`.

- [ ] **Step 4: Full build**

Run: `mvn --batch-mode install -T1C -DskipTests -o`
Expected: BUILD SUCCESS across all modules.

Run: `mvn --batch-mode test -pl platform-api,acl-inmem,acl-jpa,platform -o`
Expected: All tests pass across all affected modules.

- [ ] **Step 5: Commit**

```
git add platform/ CLAUDE.md
git commit -m "refactor(#202): update MockBeansTest, clean stale CLAUDE.md references

Remove .toCompletableFuture().join() from ACL assertions.
Remove ReactiveCaseMemoryStore from package structure (deleted by #384).
Update acl-jpa module description to reflect blocking conversion.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```
