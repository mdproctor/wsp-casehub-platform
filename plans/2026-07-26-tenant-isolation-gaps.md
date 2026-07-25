# Tenant Isolation Gaps Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #203 — GroupMembershipProvider SPI has no tenancyId
**Issue group:** #203, #204, #205, #206

**Goal:** Close 4 tenant isolation gaps — add tenancyId to GroupMembershipProvider and DeliveryAttemptStore SPIs, add tenant filtering to AccessControlProvider queries, add authentication to webhook endpoints.

**Architecture:** #203 changes the GroupMembershipProvider SPI (breaking, zero cross-repo callers). #204 adds tenant predicates to ACL queries using the already-injected CurrentPrincipal — reads bypass for cross-tenant admins, mutations always scoped. #205 adds tenant-scoped overloads to DeliveryAttemptStore. #206 passes HTTP headers to EngagementCallbackHandler.translate() and adds bearer token validation to WebhookResource.

**Tech Stack:** Quarkus, Hibernate ORM Panache, JPA, Flyway, CDI

## Global Constraints

- `project_path` for all IntelliJ MCP calls: `/Users/mdproctor/claude/casehub/platform`
- No cross-repo impact — all 4 SPIs have zero cross-repo callers
- Flyway V2 for acl-jpa (`classpath:db/acl/migration`) — V1 exists
- Mutations always scoped to `principal.tenancyId()` — cross-tenant admin bypass on reads only
- `SecurityException` catch MUST precede `catch (Exception)` in EngagementCallbackResource

---

### Task 1: GroupMembershipProvider tenancyId (#203)

**Files:**
- Modify: `platform-api/src/main/java/io/casehub/platform/api/identity/GroupMembershipProvider.java`
- Modify: `platform/src/main/java/io/casehub/platform/mock/MockGroupMembershipProvider.java`
- Modify: `testing/src/main/java/io/casehub/platform/testing/InMemoryGroupMembershipProvider.java`
- Modify: `scim/src/main/java/io/casehub/platform/scim/ScimGroupMembershipProvider.java`
- Modify: `acl-jpa/src/test/java/io/casehub/platform/acl/jpa/TestGroupMembershipProvider.java`
- Modify: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/TargetResolver.java`
- Modify: `acl-jpa/src/main/java/io/casehub/platform/acl/jpa/JpaAccessControlProvider.java`
- Modify: `acl-inmem/src/main/java/io/casehub/platform/acl/inmem/InMemoryAccessControlProvider.java`
- Modify: `platform-api/src/test/java/io/casehub/platform/api/identity/GroupMembershipProviderSpiTest.java`
- Modify: `platform-api/src/test/java/io/casehub/platform/api/acl/AccessControlProviderContractTest.java`
- Modify: `testing/src/test/java/io/casehub/platform/testing/InMemoryGroupMembershipProviderTest.java`
- Modify: `scim/src/test/java/io/casehub/platform/scim/ScimGroupMembershipProviderTest.java`
- Modify: `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/TargetResolverTest.java`
- Modify: `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/NotificationDispatcherTest.java`
- Modify: `acl-inmem/src/test/java/io/casehub/platform/acl/inmem/InMemoryAccessControlProviderTest.java`
- Modify: `platform/src/test/java/io/casehub/platform/mock/MockBeansTest.java`

**Interfaces:**
- Produces: `GroupMembershipProvider.membersOf(String groupName, String tenancyId)`, `GroupMembershipProvider.groupsOf(String actorId, String tenancyId)` — all downstream tasks and callers consume these signatures.

- [ ] **Step 1: Update GroupMembershipProvider SPI**

Use `ide_edit_member` with `member=GroupMembershipProvider`:

```java
public interface GroupMembershipProvider {
    Set<GroupMember> membersOf(String groupName, String tenancyId);

    default List<String> groupsOf(String actorId, String tenancyId) {
        return List.of();
    }
}
```

- [ ] **Step 2: Update MockGroupMembershipProvider**

Use `ide_edit_member` on `membersOf`:

```java
@Override
public Set<GroupMember> membersOf(String groupName, String tenancyId) {
    return Set.of();
}
```

- [ ] **Step 3: Update InMemoryGroupMembershipProvider**

Use `ide_edit_member` on `membersOf`. The internal map currently stores `Map<String, Set<GroupMember>>` keyed by groupName. Add tenancyId to the key. Change field type to `Map<String, Map<String, Set<GroupMember>>>` (outer key = tenancyId, inner key = groupName), or simpler: use a composite key `tenancyId + "::" + groupName`.

Use the composite key approach — minimal change:

```java
@Override
public Set<GroupMember> membersOf(String groupName, String tenancyId) {
    String key = tenancyId + "::" + groupName;
    return Collections.unmodifiableSet(members.getOrDefault(key, Set.of()));
}
```

Update `addMember` methods to accept tenancyId:
```java
public void addMember(String groupName, String tenancyId, String actorId) {
    addMember(groupName, tenancyId, new GroupMember(actorId, actorId));
}

public void addMember(String groupName, String tenancyId, GroupMember member) {
    String key = tenancyId + "::" + groupName;
    members.computeIfAbsent(key, k -> ConcurrentHashMap.newKeySet()).add(member);
}
```

Update `removeMember` and `clear` accordingly. Update `groupsOf`:
```java
@Override
public List<String> groupsOf(String actorId, String tenancyId) {
    List<String> result = new ArrayList<>();
    String prefix = tenancyId + "::";
    for (var entry : members.entrySet()) {
        if (entry.getKey().startsWith(prefix) && entry.getValue().stream().anyMatch(m -> m.actorId().equals(actorId))) {
            result.add(entry.getKey().substring(prefix.length()));
        }
    }
    return result;
}
```

- [ ] **Step 4: Update ScimGroupMembershipProvider**

Use `ide_edit_member` on `membersOf` — add `String tenancyId` parameter. The SCIM backend is single-tenant per deployment, so tenancyId is accepted but not used in the SCIM query (future: scope SCIM queries per tenant).

```java
@Override
public Set<GroupMember> membersOf(String groupName, String tenancyId) {
    // existing SCIM logic unchanged — tenancyId reserved for future multi-tenant SCIM
    ...
}
```

- [ ] **Step 5: Update TestGroupMembershipProvider (acl-jpa test)**

Use `ide_edit_member` on `membersOf` and `groupsOf`:

```java
@Override
public Set<GroupMember> membersOf(String groupName, String tenancyId) {
    return Set.of();
}

@Override
public List<String> groupsOf(String actorId, String tenancyId) {
    if ("actor1".equals(actorId)) return List.of("managers");
    return List.of();
}
```

- [ ] **Step 6: Update callers — TargetResolver**

Use `ide_replace_member` on `resolve`. Change line 58:
```java
final Set<GroupMember> members = groupMembershipProvider.membersOf(target.id(), subscription.tenancyId());
```

- [ ] **Step 7: Update callers — JpaAccessControlProvider.buildCandidateSet**

Use `ide_replace_member` on `buildCandidateSet`:
```java
private Set<String> buildCandidateSet(String actorId) {
    Set<String> candidates = new HashSet<>();
    candidates.add(actorId);
    for (String group : groupMembership.groupsOf(actorId, principal.tenancyId())) {
        candidates.add("group:" + group);
    }
    return candidates;
}
```

- [ ] **Step 8: Update callers — InMemoryAccessControlProvider.buildCandidateSet**

This requires injecting `CurrentPrincipal`. Use `ide_edit_member` on the full class to add the field and update the constructor:

Add field: `private final CurrentPrincipal principal;`
Update constructor to accept `CurrentPrincipal principal` alongside `GroupMembershipProvider`.
Update `buildCandidateSet`:
```java
private Set<String> buildCandidateSet(String actorId) {
    Set<String> candidates = new HashSet<>();
    candidates.add(actorId);
    for (String group : groupMembership.groupsOf(actorId, principal.tenancyId())) {
        candidates.add("group:" + group);
    }
    return candidates;
}
```

Also update `grant()` to store `principal.tenancyId()` instead of `""`:
```java
grants.put(key, new AclEntry(actorId, resourceId, action, Instant.now(), expires, principal.tenancyId()));
```

- [ ] **Step 9: Update all tests**

Update `GroupMembershipProviderSpiTest` — add tenancyId to all `membersOf`/`groupsOf` calls.

Update `InMemoryGroupMembershipProviderTest` — update `addMember` calls to include tenancyId, update `membersOf`/`groupsOf` calls, add cross-tenant isolation test.

Update `ScimGroupMembershipProviderTest` — add tenancyId parameter to all calls.

Update `AccessControlProviderContractTest` — add `protected String tenancyId()` abstract method returning `"test-tenant"`. Update the `groupsOf` lambda in `InMemoryAccessControlProviderTest` to accept tenancyId.

Update `InMemoryAccessControlProviderTest` — construct `InMemoryAccessControlProvider` with a mock `CurrentPrincipal`.

Update `TargetResolverTest` — update the `groupProvider` lambda to accept tenancyId.

Update `NotificationDispatcherTest` — update the `groupProvider` lambda to accept tenancyId.

Update `MockBeansTest` — update `membersOf` calls to include a tenancyId parameter.

- [ ] **Step 10: Install platform-api and run all affected module tests**

```bash
mvn --batch-mode install -pl platform-api -DskipTests -o
mvn --batch-mode test -pl platform-api,platform,testing,scim,acl-inmem,acl-jpa,notification-dispatch -o
```

Expected: All tests pass.

- [ ] **Step 11: Commit**

```
git add platform-api/ platform/ testing/ scim/ acl-inmem/ acl-jpa/ notification-dispatch/
git commit -m "security(#203): add tenancyId to GroupMembershipProvider SPI

Add tenancyId parameter to membersOf() and groupsOf(). Update all
implementations and callers. InMemoryAccessControlProvider now injects
CurrentPrincipal for tenant-aware group expansion.

Closes #203

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: AccessControlProvider tenancy filtering + Flyway (#204)

**Files:**
- Create: `acl-jpa/src/main/resources/db/acl/migration/V2__acl_tenant_isolation.sql`
- Create: `acl-jpa/src/main/java/io/casehub/platform/acl/jpa/ResourceParentKey.java`
- Modify: `acl-jpa/src/main/java/io/casehub/platform/acl/jpa/AclEntryEntity.java`
- Modify: `acl-jpa/src/main/java/io/casehub/platform/acl/jpa/ResourceParentEntity.java`
- Modify: `acl-jpa/src/main/java/io/casehub/platform/acl/jpa/JpaAccessControlProvider.java`
- Modify: `acl-inmem/src/main/java/io/casehub/platform/acl/inmem/InMemoryAccessControlProvider.java`
- Modify: `platform-api/src/test/java/io/casehub/platform/api/acl/AccessControlProviderContractTest.java`
- Modify: `acl-inmem/src/test/java/io/casehub/platform/acl/inmem/InMemoryAccessControlProviderTest.java`
- Modify: `acl-jpa/src/test/java/io/casehub/platform/acl/jpa/JpaAccessControlProviderTest.java`

**Interfaces:**
- Consumes: `GroupMembershipProvider.groupsOf(actorId, tenancyId)` from Task 1
- Produces: Tenant-filtered ACL queries — no SPI change, internal implementation detail

- [ ] **Step 1: Create Flyway V2 migration**

Create `acl-jpa/src/main/resources/db/acl/migration/V2__acl_tenant_isolation.sql`:

```sql
-- Include tenancy_id in unique constraint so the same (actor, resource, action)
-- tuple can exist in different tenants.
ALTER TABLE acl_entry DROP CONSTRAINT uq_acl_entry;
ALTER TABLE acl_entry ADD CONSTRAINT uq_acl_entry
    UNIQUE (actor_id, resource_id, action, tenancy_id);

-- Include tenancy_id in primary key so different tenants can register
-- parent mappings for the same child resource.
ALTER TABLE resource_parent DROP CONSTRAINT resource_parent_pkey;
ALTER TABLE resource_parent ADD CONSTRAINT resource_parent_pkey
    PRIMARY KEY (child_resource_id, tenancy_id);
```

- [ ] **Step 2: Update AclEntryEntity unique constraint annotation**

Use `ide_edit_member` on `AclEntryEntity` to update the `@UniqueConstraint`:

```java
@UniqueConstraint(
    name = "uq_acl_entry",
    columnNames = {"actor_id", "resource_id", "action", "tenancy_id"})
```

- [ ] **Step 3: Create ResourceParentKey and update ResourceParentEntity**

Create `acl-jpa/src/main/java/io/casehub/platform/acl/jpa/ResourceParentKey.java` via `ide_create_file`:

```java
package io.casehub.platform.acl.jpa;

import java.io.Serializable;

public record ResourceParentKey(String childResourceId, String tenancyId) implements Serializable {}
```

Update `ResourceParentEntity` via `ide_edit_member` — add `@IdClass` and make `tenancyId` an `@Id`:

```java
@IdClass(ResourceParentKey.class)
@Entity
@Table(name = "resource_parent",
        indexes = @Index(name = "idx_rp_parent", columnList = "parent_resource_id"))
public class ResourceParentEntity extends PanacheEntityBase {

    @Id
    @Column(name = "child_resource_id")
    public String childResourceId;

    @Id
    @Column(name = "tenancy_id", nullable = false)
    public String tenancyId;

    @Column(name = "parent_resource_id", nullable = false)
    public String parentResourceId;
}
```

- [ ] **Step 4: Add cross-tenant isolation tests to contract test**

Use `ide_insert_member` to add to `AccessControlProviderContractTest`:

Add abstract method: `protected void setTenancyId(String tenancyId);`

Add tests:
```java
@Test
void canAccess_differentTenant_returnsFalse() {
    provider().grant("actor1", "case:abc", AclAction.READ, null);
    setTenancyId("other-tenant");
    assertFalse(provider().canAccess("actor1", "case:abc", AclAction.READ));
}

@Test
void revoke_differentTenant_doesNotDelete() {
    provider().grant("actor1", "case:abc", AclAction.READ, null);
    setTenancyId("other-tenant");
    provider().revoke("actor1", "case:abc", AclAction.READ);
    setTenancyId(tenancyId());
    assertTrue(provider().canAccess("actor1", "case:abc", AclAction.READ));
}

@Test
void accessibleResources_filteredByTenant() {
    provider().grant("actor1", "case:abc", AclAction.READ, null);
    setTenancyId("other-tenant");
    provider().grant("actor1", "case:def", AclAction.READ, null);
    List<String> result = provider().accessibleResources("actor1", AclResourceType.CASE, AclAction.READ);
    assertEquals(1, result.size());
    assertTrue(result.contains("case:def"));
    setTenancyId(tenancyId());
    result = provider().accessibleResources("actor1", AclResourceType.CASE, AclAction.READ);
    assertEquals(1, result.size());
    assertTrue(result.contains("case:abc"));
}

@Test
void grant_sameTupleDifferentTenant_bothStored() {
    provider().grant("actor1", "case:abc", AclAction.READ, null);
    setTenancyId("other-tenant");
    provider().grant("actor1", "case:abc", AclAction.READ, null);
    assertTrue(provider().canAccess("actor1", "case:abc", AclAction.READ));
    setTenancyId(tenancyId());
    assertTrue(provider().canAccess("actor1", "case:abc", AclAction.READ));
}
```

- [ ] **Step 5: Implement setTenancyId in InMemoryAccessControlProviderTest**

Update the test to use a mutable `CurrentPrincipal` that allows tenant switching:

```java
private String currentTenancyId = "test-tenant";

@Override
protected void setTenancyId(String tenancyId) {
    this.currentTenancyId = tenancyId;
}

@Override
protected String tenancyId() {
    return "test-tenant";
}
```

The `CurrentPrincipal` mock used to construct `InMemoryAccessControlProvider` must delegate `tenancyId()` to `currentTenancyId`.

- [ ] **Step 6: Update JpaAccessControlProvider — add shouldFilterByTenant and tenant predicates**

Use `ide_insert_member` for the helper:
```java
private boolean shouldFilterByTenant() {
    return !principal.isCrossTenantAdmin();
}
```

Use `ide_replace_member` on each method to add tenant predicates:

**`canAccessWithCandidates`**: Add `AND tenancyId = ?` to count query, skip when `!shouldFilterByTenant()`. Parent lookup changes to composite key: `ResourceParentEntity.findById(new ResourceParentKey(resourceId, principal.tenancyId()))`.

**`grant`**: Add `AND tenancyId = ?` to existence check.

**`revoke`**: Add `AND tenancyId = ?` — always scoped (no bypass).

**`revokeAll`**: Add `AND tenancyId = ?` to both list and delete — always scoped.

**`registerParent`**: Use `ResourceParentEntity.findById(new ResourceParentKey(childResourceId, principal.tenancyId()))` — always scoped.

**`accessibleResources`**: Add `AND e.tenancyId = ?` — skip when `!shouldFilterByTenant()`.

- [ ] **Step 7: Update InMemoryAccessControlProvider — tenant-aware GrantKey + filtering**

Change GrantKey to include tenancyId:
```java
private record GrantKey(String actorId, String resourceId, AclAction action, String tenancyId) {}
```

Change parents map to use tenancy-aware key:
```java
private record ParentKey(String childResourceId, String tenancyId) {}
private final ConcurrentHashMap<ParentKey, String> parents = new ConcurrentHashMap<>();
```

Update `grant()` to construct GrantKey with `principal.tenancyId()`.
Update `revoke()`, `revokeAll()` — always use `principal.tenancyId()` in GrantKey.
Update `registerParent()` — use ParentKey with `principal.tenancyId()`.
Update `canAccessWithCandidates()` — filter by tenancyId unless `!shouldFilterByTenant()`.
Update `accessibleResources()` — filter by tenancyId unless `!shouldFilterByTenant()`.

Add `shouldFilterByTenant()` helper.

- [ ] **Step 8: Implement setTenancyId in JpaAccessControlProviderTest**

The `FixedCurrentPrincipal` from `casehub-platform-testing` is `@Priority(200)` and its tenancyId comes from `application.properties`. Override with a test-local `@Alternative` that supports mutable tenancyId, or use `@InjectMock` if available.

Simplest approach: add a `TestCurrentPrincipal` in the test package with a mutable `tenancyId` field, `@Alternative @Priority(300)`.

- [ ] **Step 9: Run tests**

```bash
mvn --batch-mode install -pl platform-api -DskipTests -o
mvn --batch-mode test -pl acl-inmem,acl-jpa
```

Expected: All contract tests pass (including new cross-tenant isolation tests) + JPA-specific tests pass.

- [ ] **Step 10: Commit**

```
git add acl-jpa/ acl-inmem/ platform-api/
git commit -m "security(#204): add tenancy filtering to AccessControlProvider queries

Add tenant predicates to all JPA queries. Reads bypass for
isCrossTenantAdmin; mutations always scoped. Flyway V2 adds tenancy_id
to acl_entry unique constraint and resource_parent composite PK.
InMemoryAccessControlProvider adds tenancy-aware GrantKey and ParentKey.

Closes #204

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: DeliveryAttemptStore tenancyId (#205)

**Files:**
- Modify: `platform-api/src/main/java/io/casehub/platform/api/delivery/DeliveryAttemptStore.java`
- Modify: `delivery-tracking-jpa/src/main/java/io/casehub/platform/delivery/tracking/jpa/JpaDeliveryAttemptStore.java`
- Modify: `delivery-tracking-inmem/src/main/java/io/casehub/platform/delivery/tracking/inmem/InMemoryDeliveryAttemptStore.java`
- Modify: `platform/src/main/java/io/casehub/platform/delivery/NoOpDeliveryAttemptStore.java`
- Modify: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/EngagementCallbackResource.java`
- Modify: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/InAppEngagementBridge.java`
- Modify: `delivery-tracking-jpa/src/test/java/io/casehub/platform/delivery/tracking/jpa/JpaDeliveryAttemptStoreTest.java`
- Modify: `delivery-tracking-inmem/src/test/java/io/casehub/platform/delivery/tracking/inmem/InMemoryDeliveryAttemptStoreTest.java`
- Modify: `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/EngagementCallbackResourceTest.java`
- Modify: `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/InAppEngagementBridgeTest.java`

**Interfaces:**
- Produces: `DeliveryAttemptStore.findById(String id, String tenancyId)`, `findBySource(..., String tenancyId)`, `findEngagementsByAttemptId(String, String)`, `findEngagementsBySource(String, DeliverySourceType, String)`

- [ ] **Step 1: Update DeliveryAttemptStore SPI**

Use `ide_edit_member` on `DeliveryAttemptStore`. Add tenant-scoped overload for `findById` and add tenancyId to the 3 other methods:

```java
public interface DeliveryAttemptStore {
    void store(DeliveryAttempt attempt);
    void update(DeliveryAttempt attempt);

    DeliveryAttempt findById(String id);
    DeliveryAttempt findById(String id, String tenancyId);

    List<DeliveryAttempt> claimRetryable(Instant now, int batchSize);
    DeliveryAttemptPage find(DeliveryAttemptQuery query);

    List<DeliveryAttempt> findBySource(String sourceId, DeliverySourceType sourceType, String tenancyId);

    void recordEngagement(EngagementEvent event);

    List<EngagementEvent> findEngagementsByAttemptId(String attemptId, String tenancyId);

    List<EngagementEvent> findEngagementsBySource(String sourceId, DeliverySourceType sourceType, String tenancyId);
}
```

- [ ] **Step 2: Update all 3 implementations**

**JpaDeliveryAttemptStore**: Add `findById(id, tenancyId)` with `AND tenancyId = ?` in WHERE. Add `AND tenancyId = ?` to `findBySource`, `findEngagementsByAttemptId`, `findEngagementsBySource`.

**InMemoryDeliveryAttemptStore**: Add `findById(id, tenancyId)` that filters by tenancyId after PK lookup. Add tenancyId filter to the other 3 methods.

**NoOpDeliveryAttemptStore**: Add `findById(id, tenancyId)` returning null. Add tenancyId parameter to other methods, returning empty lists.

- [ ] **Step 3: Update callers**

**EngagementCallbackResource.recordDirect()**: Change `store.findById(attemptId)` to `store.findById(attemptId, principal.tenancyId())`. Remove the manual tenancyId check on line 106 — the scoped `findById` enforces it (returns null if wrong tenant → 404, same as the current 403).

**InAppEngagementBridge.onStatusChanged()**: Change `store.findBySource(notification.id(), DeliverySourceType.NOTIFICATION)` to `store.findBySource(notification.id(), DeliverySourceType.NOTIFICATION, notification.tenancyId())`.

**EngagementCallbackResource.handleCallback()**: Keeps using unscoped `store.findById(raw.attemptId())` — the callback path authenticates via handler signature verification.

- [ ] **Step 4: Update tests**

Update all test files to pass tenancyId where the method signature changed. Add cross-tenant isolation tests for the scoped `findById` overload.

- [ ] **Step 5: Run tests**

```bash
mvn --batch-mode install -pl platform-api -DskipTests -o
mvn --batch-mode test -pl delivery-tracking-jpa,delivery-tracking-inmem,notification-dispatch
```

Expected: All tests pass.

- [ ] **Step 6: Commit**

```
git add platform-api/ delivery-tracking-jpa/ delivery-tracking-inmem/ platform/ notification-dispatch/
git commit -m "security(#205): add tenancyId to DeliveryAttemptStore query methods

Add tenant-scoped findById overload. Add tenancyId to findBySource,
findEngagementsByAttemptId, findEngagementsBySource. Unscoped findById
retained for privileged paths. claimRetryable unchanged (system op).

Closes #205

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Webhook authentication (#206)

**Files:**
- Modify: `platform-api/src/main/java/io/casehub/platform/api/delivery/EngagementCallbackHandler.java`
- Modify: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/EngagementCallbackResource.java`
- Modify: `streams-webhook/src/main/java/io/casehub/platform/streams/webhook/WebhookResource.java`
- Modify: `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/EngagementCallbackResourceTest.java`
- Modify: `streams-webhook/src/test/java/io/casehub/platform/streams/webhook/WebhookResourceTest.java`

**Interfaces:**
- Consumes: `EngagementCallbackHandler` SPI (existing)
- Produces: `EngagementCallbackHandler.translate(String rawPayload, Map<String, String> headers)` — breaking change, zero callers outside platform

- [ ] **Step 1: Update EngagementCallbackHandler SPI**

Use `ide_edit_member` on `EngagementCallbackHandler`:

```java
public interface EngagementCallbackHandler {

    String channelId();

    /**
     * Translates a provider-specific webhook payload into platform engagement events.
     *
     * <p>Implementations MUST verify the request signature using provider-specific
     * headers (e.g. {@code X-Hub-Signature-256}) before processing the payload.
     * Implementations MUST throw {@link SecurityException} on verification failure —
     * not a generic {@code RuntimeException} or a swallowed internal check.
     *
     * @param rawPayload the raw webhook body
     * @param headers    complete HTTP request headers from the incoming request;
     *                   implementations extract the relevant verification header
     * @return translated engagement events
     * @throws SecurityException if signature verification fails
     */
    List<RawEngagement> translate(String rawPayload, Map<String, String> headers);
}
```

- [ ] **Step 2: Update EngagementCallbackResource**

Inject `@Context HttpHeaders httpHeaders` — add to constructor.

Add `extractHeaders` helper:
```java
private Map<String, String> extractHeaders(HttpHeaders httpHeaders) {
    Map<String, String> result = new java.util.HashMap<>();
    for (var key : httpHeaders.getRequestHeaders().keySet()) {
        result.put(key, httpHeaders.getHeaderString(key));
    }
    return result;
}
```

Update `handleCallback()`:
- Call `handler.translate(rawPayload, extractHeaders(httpHeaders))`
- Add `catch (SecurityException e)` BEFORE the existing `catch (Exception e)`:

```java
try {
    var rawEvents = handler.translate(rawPayload, extractHeaders(httpHeaders));
    if (rawEvents != null) {
        for (var raw : rawEvents) {
            DeliveryAttempt attempt = store.findById(raw.attemptId());
            if (attempt == null) {
                LOG.debugf("Engagement callback for nonexistent attempt '%s' — skipping", raw.attemptId());
                continue;
            }
            recorder.record(attempt, raw.type(), raw.metadata());
        }
    }
} catch (SecurityException e) {
    LOG.warnf("Engagement callback handler '%s' rejected payload: %s", channelId, e.getMessage());
    return Response.status(401).build();
} catch (Exception e) {
    LOG.warnf(e, "Engagement callback handler '%s' failed to translate payload", channelId);
}
return Response.ok().build();
```

- [ ] **Step 3: Update WebhookResource — add bearer token validation**

Inject `CredentialResolver credentialResolver` and `@Context HttpHeaders httpHeaders`.

Add config property: `@ConfigProperty(name = "casehub.streams.webhook.require-auth", defaultValue = "true") boolean requireAuth`

In `receive()`, after resolving the EndpointDescriptor, add credential validation:

```java
if (descriptor.get().credentialRef() != null) {
    Map<String, String> creds = credentialResolver.resolve(descriptor.get().credentialRef());
    String expectedToken = creds.get(CredentialPropertyKeys.BEARER_TOKEN);
    if (expectedToken != null) {
        String authHeader = httpHeaders.getHeaderString("Authorization");
        if (authHeader == null || !authHeader.equals("Bearer " + expectedToken)) {
            return Response.status(401).build();
        }
    }
} else if (requireAuth) {
    LOG.warnf("Webhook endpoint streams/%s has no credentialRef — rejected (require-auth=true). " +
              "Set credentialRef on the EndpointDescriptor or set casehub.streams.webhook.require-auth=false", streamId);
    return Response.status(401).build();
}
```

- [ ] **Step 4: Update tests**

**EngagementCallbackResourceTest**: Update `translate()` calls in test handlers to accept `Map<String, String> headers`. Add test: handler throws `SecurityException` → 401 response. Update constructor calls to include `HttpHeaders`.

**WebhookResourceTest**: Add test: bearer token present and valid → 202. Bearer token missing → 401. `credentialRef` null + `require-auth=true` → 401. `credentialRef` null + `require-auth=false` → 202.

- [ ] **Step 5: Run tests**

```bash
mvn --batch-mode install -pl platform-api -DskipTests -o
mvn --batch-mode test -pl notification-dispatch,streams-webhook
```

Expected: All tests pass.

- [ ] **Step 6: Commit**

```
git add platform-api/ notification-dispatch/ streams-webhook/
git commit -m "security(#206): add authentication to webhook endpoints

Pass HTTP headers to EngagementCallbackHandler.translate() enabling
HMAC signature verification. SecurityException catch before catch-all.
WebhookResource validates bearer token from credentialRef; rejects
unauthenticated when require-auth=true (default).

Closes #206

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: CLAUDE.md + cleanup

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update CLAUDE.md**

Update `acl-inmem/` module description — add "constructor-injected CurrentPrincipal" to match the new dependency.

Update `.identity` package structure — update `GroupMembershipProvider` description to note tenancyId parameter.

- [ ] **Step 2: Full build verification**

```bash
mvn --batch-mode install -T1C -DskipTests -o
```

Expected: BUILD SUCCESS.

- [ ] **Step 3: Commit**

```
git add CLAUDE.md
git commit -m "docs(#203): update CLAUDE.md for tenant isolation changes

Update acl-inmem and GroupMembershipProvider descriptions.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```
