# System Subscriptions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #150 — feat: system subscriptions — admin-defined subscriptions scoping to roles/groups/all users
**Issue group:** #150

**Goal:** Add a `SubscriptionScope` discriminator (`USER` | `SYSTEM`) to the subscription model so admins can create tenant-wide notification rules.

**Architecture:** Scope discriminator on the existing `Subscription` record changes the authorisation model — USER scope enforces ownerId, SYSTEM scope enforces tenancyId only. Admin write-gate at the REST layer via `CurrentPrincipal.hasGroup()`. Store uses OR-disjunction queries to resolve scope without a pre-fetch. No changes to SubscriptionEngine, ConstraintCompiler, TargetResolver, or NotificationDispatcher.

**Tech Stack:** Java 21, Quarkus, Hibernate Reactive Panache, SmallRye Mutiny, AssertJ, RESTAssured, Mockito

## Global Constraints

- `platform-api/` must remain zero-dependency — no Quarkus, no JPA, no casehubio imports. Pure Java only.
- Pre-release — breaking changes cost nothing. Fix all call sites directly, no shims.
- Scope is immutable after creation — not in `SubscriptionUpdate`.
- `$me` constraint value rejected for SYSTEM scope at the REST boundary.
- IntelliJ MCP mandatory for all `.java` file operations.

---

### Task 1: SPI Model — SubscriptionScope enum, record changes, SPI tests

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/subscription/SubscriptionScope.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/subscription/Subscription.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/subscription/SubscriptionInput.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/subscription/SubscriptionQuery.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/subscription/SubscriptionConstants.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/subscription/SubscriptionStore.java` (javadoc)
- Modify: `platform-api/src/main/java/io/casehub/platform/api/subscription/ReactiveSubscriptionStore.java` (javadoc)
- Modify: `platform-api/src/test/java/io/casehub/platform/api/subscription/SubscriptionSpiTest.java`

**Interfaces:**
- Produces: `SubscriptionScope` enum (`USER`, `SYSTEM`), `Subscription` record with `scope` field, `SubscriptionInput` with `scope` (null→USER default), `SubscriptionQuery` with `scope` and conditionally nullable `ownerId`, `SubscriptionConstants.SYSTEM_SUBSCRIPTION_ADMIN_GROUP`

- [ ] **Step 1: Create `SubscriptionScope` enum**

```java
package io.casehub.platform.api.subscription;

public enum SubscriptionScope {
    USER,
    SYSTEM
}
```

Use `ide_create_file` to create `platform-api/src/main/java/io/casehub/platform/api/subscription/SubscriptionScope.java`.

- [ ] **Step 2: Update `Subscription` record — add `scope` between `enabled` and `createdAt`**

Use `ide_edit_member` on `Subscription` to replace the entire record declaration. The new record adds `SubscriptionScope scope` as a parameter and `Objects.requireNonNull(scope, "scope")` in the compact constructor.

```java
public record Subscription(
        String id,
        String ownerId,
        String tenancyId,
        String name,
        String eventType,
        List<Constraint> constraints,
        List<NotificationTarget> targets,
        boolean includeActor,
        NotificationTemplate template,
        boolean enabled,
        SubscriptionScope scope,
        Instant createdAt,
        Instant updatedAt
) {
    public Subscription {
        Objects.requireNonNull(id, "id");
        Objects.requireNonNull(ownerId, "ownerId");
        Objects.requireNonNull(tenancyId, "tenancyId");
        Objects.requireNonNull(name, "name");
        Objects.requireNonNull(eventType, "eventType");
        Objects.requireNonNull(constraints, "constraints");
        Objects.requireNonNull(targets, "targets");
        Objects.requireNonNull(template, "template");
        Objects.requireNonNull(scope, "scope");
        Objects.requireNonNull(createdAt, "createdAt");
        Objects.requireNonNull(updatedAt, "updatedAt");
        constraints = List.copyOf(constraints);
        targets = List.copyOf(targets);
    }
}
```

- [ ] **Step 3: Update `SubscriptionInput` record — add `scope` with null→USER default**

Use `ide_edit_member` on `SubscriptionInput`. Add `SubscriptionScope scope` as last parameter. In compact constructor: `scope = scope != null ? scope : SubscriptionScope.USER;`

```java
public record SubscriptionInput(
        String ownerId,
        String tenancyId,
        String name,
        String eventType,
        List<Constraint> constraints,
        List<NotificationTarget> targets,
        boolean includeActor,
        NotificationTemplate template,
        boolean enabled,
        SubscriptionScope scope
) {
    public SubscriptionInput {
        Objects.requireNonNull(ownerId, "ownerId");
        Objects.requireNonNull(tenancyId, "tenancyId");
        Objects.requireNonNull(name, "name");
        Objects.requireNonNull(eventType, "eventType");
        Objects.requireNonNull(constraints, "constraints");
        Objects.requireNonNull(targets, "targets");
        Objects.requireNonNull(template, "template");
        scope = scope != null ? scope : SubscriptionScope.USER;
        constraints = List.copyOf(constraints);
        targets = List.copyOf(targets);
    }
}
```

- [ ] **Step 4: Update `SubscriptionQuery` record — add `scope`, make `ownerId` conditionally nullable**

Use `ide_edit_member` on `SubscriptionQuery`. Parameter order: `(ownerId, tenancyId, scope, enabled, cursor, limit)`. `ownerId` required for USER scope, nullable for SYSTEM.

```java
public record SubscriptionQuery(
        String ownerId,
        String tenancyId,
        SubscriptionScope scope,
        Boolean enabled,
        String cursor,
        int limit
) {
    public SubscriptionQuery {
        Objects.requireNonNull(tenancyId, "tenancyId");
        var effectiveScope = scope != null ? scope : SubscriptionScope.USER;
        if (effectiveScope == SubscriptionScope.USER) {
            Objects.requireNonNull(ownerId, "ownerId required for USER scope");
        }
        if (limit <= 0) {
            throw new IllegalArgumentException("limit must be positive");
        }
    }
}
```

- [ ] **Step 5: Add `SYSTEM_SUBSCRIPTION_ADMIN_GROUP` to `SubscriptionConstants`**

Use `ide_insert_member` to add after the existing `NOTIFICATION_DATASOURCE_PATH` constant:

```java
public static final String SYSTEM_SUBSCRIPTION_ADMIN_GROUP = "subscription-admins";
```

- [ ] **Step 6: Update `SubscriptionStore` and `ReactiveSubscriptionStore` javadoc**

Use `ide_edit_member` on the interface declarations to update the class-level javadoc. Replace the "User Ownership Enforcement" paragraph with scope-dependent authorisation documentation:

> For USER scope subscriptions, ownerId is enforced at the SPI boundary. For SYSTEM scope subscriptions, only tenancyId is enforced at the SPI boundary — admin authorisation is enforced at the REST layer. Implementations use OR-disjunction queries: `(ownerId = ? OR scope = 'SYSTEM') AND tenancyId = ?`.

- [ ] **Step 7: Update `SubscriptionSpiTest` — fix all existing constructor calls**

Every `Subscription()` call needs the new `scope` parameter (use `SubscriptionScope.USER`). Every `SubscriptionInput()` call needs the new `scope` parameter (use `null` for default-to-USER). Every `SubscriptionQuery()` call needs the new `scope` parameter inserted as third argument (use `null` for backward-compat).

Use `ide_edit_member` on each test method and helper that constructs these records. Key call sites:

- `subscription_validConstruction` — add `SubscriptionScope.USER` before `createdAt`
- `subscription_rejectsNull*` — same
- `subscription_makesDefensiveCopy*` — same
- `subscriptionInput_validConstruction` — add `null` as last arg (defaults to USER)
- `subscriptionInput_rejectsNull*` — same
- `subscriptionQuery_validConstruction` — add `null` as 3rd arg
- `subscriptionQuery_acceptsNullEnabledAndCursor` — same
- `subscriptionQuery_rejectsNull*` — same
- `subscriptionPage_*` — Subscription constructor inside
- `subscriptionCreated/Updated/Deleted_*` — Subscription constructor inside
- Helper `createTemplate()` — no change (template doesn't have scope)

- [ ] **Step 8: Add new scope-specific tests in `SubscriptionSpiTest`**

Use `ide_insert_member` to add after the existing SubscriptionQuery tests:

```java
@Test
void subscription_rejectsNullScope() {
    var constraints = List.of(new Constraint("status", ConstraintOp.EQ, "active"));
    var targets = List.of(new NotificationTarget(TargetType.USER, "user-1"));
    var template = createTemplate();
    assertThatThrownBy(() -> new Subscription(
            "sub-123", "user-1", "tenant-1", "Name", "event-type",
            constraints, targets, false, template, true,
            null, Instant.now(), Instant.now()
    ))
            .isInstanceOf(NullPointerException.class)
            .hasMessageContaining("scope");
}

@Test
void subscriptionInput_nullScopeDefaultsToUser() {
    var constraints = List.of(new Constraint("status", ConstraintOp.EQ, "active"));
    var targets = List.of(new NotificationTarget(TargetType.USER, "user-1"));
    var template = createTemplate();
    var input = new SubscriptionInput(
            "user-1", "tenant-1", "Name", "event-type",
            constraints, targets, false, template, true, null
    );
    assertThat(input.scope()).isEqualTo(SubscriptionScope.USER);
}

@Test
void subscriptionInput_explicitSystemScope() {
    var constraints = List.of(new Constraint("status", ConstraintOp.EQ, "active"));
    var targets = List.of(new NotificationTarget(TargetType.USER, "user-1"));
    var template = createTemplate();
    var input = new SubscriptionInput(
            "user-1", "tenant-1", "Name", "event-type",
            constraints, targets, false, template, true,
            SubscriptionScope.SYSTEM
    );
    assertThat(input.scope()).isEqualTo(SubscriptionScope.SYSTEM);
}

@Test
void subscriptionQuery_systemScopeAllowsNullOwnerId() {
    var query = new SubscriptionQuery(
            null, "tenant-1", SubscriptionScope.SYSTEM, null, null, 10
    );
    assertThat(query.ownerId()).isNull();
    assertThat(query.scope()).isEqualTo(SubscriptionScope.SYSTEM);
}

@Test
void subscriptionQuery_userScopeRejectsNullOwnerId() {
    assertThatThrownBy(() -> new SubscriptionQuery(
            null, "tenant-1", SubscriptionScope.USER, null, null, 10
    ))
            .isInstanceOf(NullPointerException.class)
            .hasMessageContaining("ownerId required for USER scope");
}

@Test
void subscriptionQuery_nullScopeRequiresOwnerId() {
    assertThatThrownBy(() -> new SubscriptionQuery(
            null, "tenant-1", null, null, null, 10
    ))
            .isInstanceOf(NullPointerException.class)
            .hasMessageContaining("ownerId required for USER scope");
}
```

- [ ] **Step 9: Build platform-api module**

Run: `mvn --batch-mode -pl platform-api install -DskipTests`
Expected: COMPILE SUCCESS (tests may fail due to downstream module changes — verify compilation only)

Run: `mvn --batch-mode -pl platform-api test`
Expected: SubscriptionSpiTest passes. SubscriptionStoreContractTest compiles (abstract, not run alone).

- [ ] **Step 10: Commit**

```
feat(platform#150): add SubscriptionScope enum and scope field to subscription SPI

Adds USER/SYSTEM scope discriminator to Subscription, SubscriptionInput,
and SubscriptionQuery records. SubscriptionQuery.ownerId is now conditionally
nullable (not required for SYSTEM scope). Scope is immutable — not in
SubscriptionUpdate. Adds SYSTEM_SUBSCRIPTION_ADMIN_GROUP constant.
```

---

### Task 2: Store Contract Tests + InMemory Implementation

**Files:**
- Modify: `platform-api/src/test/java/io/casehub/platform/api/subscription/SubscriptionStoreContractTest.java`
- Modify: `platform/src/main/java/io/casehub/platform/subscription/NoOpSubscriptionStore.java`
- Modify: `platform/src/main/java/io/casehub/platform/subscription/NoOpReactiveSubscriptionStore.java` (if delegation breaks)
- Modify: `subscriptions-inmem/src/main/java/io/casehub/platform/subscription/inmem/InMemorySubscriptionStore.java`
- Modify: `subscriptions-inmem/src/main/java/io/casehub/platform/subscription/inmem/InMemoryReactiveSubscriptionStore.java` (delegation — should compile)

**Interfaces:**
- Consumes: `SubscriptionScope`, `Subscription(... scope ...)`, `SubscriptionInput(... scope)`, `SubscriptionQuery(... scope ...)`
- Produces: Working `InMemorySubscriptionStore` with scope-aware authorization, passing all contract tests

- [ ] **Step 1: Fix `SubscriptionStoreContractTest` — update existing `createInput` helper and constructor calls**

The `createInput()` helper adds `null` as last arg to `SubscriptionInput()` (defaults to USER). The `find_filtersByEnabled` test's inline `SubscriptionInput` constructor also gets `null` as last arg. Same for `findAllEnabled_returnsOnlyEnabled`.

The `find_returnsPaginatedResults`, `find_filtersByEnabled`, etc. tests that construct `SubscriptionQuery` — add `null` as 3rd arg (scope).

- [ ] **Step 2: Add SYSTEM scope contract tests**

Use `ide_insert_member` to add new test methods after the existing FindAllEnabled section:

```java
// SYSTEM Scope Tests

@Test
void store_systemScope_persistsScope() {
    var input = createSystemInput("admin-1", "tenant-1", "System Alert", "alert.triggered");
    var subscription = store().store(input);

    assertThat(subscription.scope()).isEqualTo(SubscriptionScope.SYSTEM);
}

@Test
void findById_systemScope_anyTenantUserCanRead() {
    var input = createSystemInput("admin-1", "tenant-1", "System Alert", "alert.triggered");
    var subscription = store().store(input);

    // Different user, same tenant — should find SYSTEM subscription
    var found = store().findById(subscription.id(), "user-2", "tenant-1");
    assertThat(found).isPresent();
    assertThat(found.get().scope()).isEqualTo(SubscriptionScope.SYSTEM);
}

@Test
void findById_systemScope_crossTenantBlocked() {
    var input = createSystemInput("admin-1", "tenant-1", "System Alert", "alert.triggered");
    var subscription = store().store(input);

    var found = store().findById(subscription.id(), "user-1", "tenant-2");
    assertThat(found).isEmpty();
}

@Test
void findById_userScope_otherUserBlocked() {
    var input = createInput("user-1", "tenant-1", "My Sub", "event");
    var subscription = store().store(input);

    // Verify USER scope still enforces ownerId
    var found = store().findById(subscription.id(), "user-2", "tenant-1");
    assertThat(found).isEmpty();
}

@Test
void find_systemScope_returnsTenantWide() {
    store().store(createSystemInput("admin-1", "tenant-1", "Alert 1", "alert.a"));
    store().store(createSystemInput("admin-2", "tenant-1", "Alert 2", "alert.b"));
    store().store(createInput("user-1", "tenant-1", "My Sub", "event"));

    var query = new SubscriptionQuery(null, "tenant-1", SubscriptionScope.SYSTEM, null, null, 10);
    var page = store().find(query);

    assertThat(page.subscriptions()).hasSize(2);
    assertThat(page.subscriptions()).allMatch(s -> s.scope() == SubscriptionScope.SYSTEM);
}

@Test
void find_systemScope_respectsTenantIsolation() {
    store().store(createSystemInput("admin-1", "tenant-1", "Alert T1", "alert"));
    store().store(createSystemInput("admin-2", "tenant-2", "Alert T2", "alert"));

    var query = new SubscriptionQuery(null, "tenant-1", SubscriptionScope.SYSTEM, null, null, 10);
    var page = store().find(query);

    assertThat(page.subscriptions()).hasSize(1);
    assertThat(page.subscriptions().get(0).tenancyId()).isEqualTo("tenant-1");
}

@Test
void update_systemScope_anyTenantUserCanUpdate() {
    var input = createSystemInput("admin-1", "tenant-1", "Alert", "alert");
    var subscription = store().store(input);

    var update = new SubscriptionUpdate("Updated Alert", null, null, null, null, null, null);
    var updated = store().update(subscription.id(), "user-2", "tenant-1", update);

    assertThat(updated).isPresent();
    assertThat(updated.get().name()).isEqualTo("Updated Alert");
}

@Test
void update_systemScope_crossTenantBlocked() {
    var input = createSystemInput("admin-1", "tenant-1", "Alert", "alert");
    var subscription = store().store(input);

    var update = new SubscriptionUpdate("Hacked", null, null, null, null, null, null);
    var updated = store().update(subscription.id(), "user-1", "tenant-2", update);

    assertThat(updated).isEmpty();
}

@Test
void delete_systemScope_anyTenantUserCanDelete() {
    var input = createSystemInput("admin-1", "tenant-1", "Alert", "alert");
    var subscription = store().store(input);

    var deleted = store().delete(subscription.id(), "user-2", "tenant-1");
    assertThat(deleted).isTrue();
}

@Test
void delete_systemScope_crossTenantBlocked() {
    var input = createSystemInput("admin-1", "tenant-1", "Alert", "alert");
    var subscription = store().store(input);

    var deleted = store().delete(subscription.id(), "user-1", "tenant-2");
    assertThat(deleted).isFalse();
}

@Test
void findAllEnabled_includesSystemScope() {
    store().store(createInput("user-1", "tenant-1", "User Sub", "event"));
    store().store(createSystemInput("admin-1", "tenant-1", "System Sub", "alert"));

    try (var stream = store().findAllEnabled()) {
        var subscriptions = stream.toList();
        assertThat(subscriptions).hasSize(2);
        assertThat(subscriptions).extracting(Subscription::scope)
                .containsExactlyInAnyOrder(SubscriptionScope.USER, SubscriptionScope.SYSTEM);
    }
}
```

Add helper method:

```java
private SubscriptionInput createSystemInput(String ownerId, String tenancyId, String name, String eventType) {
    return new SubscriptionInput(
            ownerId, tenancyId, name, eventType,
            List.of(),
            List.of(new NotificationTarget(TargetType.GROUP, "all-users")),
            false, createTemplate(), true,
            SubscriptionScope.SYSTEM
    );
}
```

- [ ] **Step 3: Fix `NoOpSubscriptionStore.toSubscription()` — add `input.scope()`**

Use `ide_replace_member` on the `toSubscription` method to add `input.scope()` between `input.enabled()` and `now`.

```java
private Subscription toSubscription(final SubscriptionInput input) {
    final var now = Instant.now();
    return new Subscription(
            UUIDv7.generate(),
            input.ownerId(),
            input.tenancyId(),
            input.name(),
            input.eventType(),
            input.constraints(),
            input.targets(),
            input.includeActor(),
            input.template(),
            input.enabled(),
            input.scope(),
            now,
            now
    );
}
```

- [ ] **Step 4: Fix `InMemorySubscriptionStore` — update `toSubscription`, `applyUpdate`, scope-aware auth**

Use `ide_replace_member` on `toSubscription`:

```java
private Subscription toSubscription(SubscriptionInput input) {
    var now = Instant.now();
    return new Subscription(
            UUIDv7.generate(),
            input.ownerId(),
            input.tenancyId(),
            input.name(),
            input.eventType(),
            input.constraints(),
            input.targets(),
            input.includeActor(),
            input.template(),
            input.enabled(),
            input.scope(),
            now,
            now
    );
}
```

Use `ide_replace_member` on `applyUpdate`:

```java
private Subscription applyUpdate(Subscription subscription, SubscriptionUpdate update) {
    return new Subscription(
            subscription.id(),
            subscription.ownerId(),
            subscription.tenancyId(),
            update.name() != null ? update.name() : subscription.name(),
            update.eventType() != null ? update.eventType() : subscription.eventType(),
            update.constraints() != null ? update.constraints() : subscription.constraints(),
            update.targets() != null ? update.targets() : subscription.targets(),
            update.includeActor() != null ? update.includeActor() : subscription.includeActor(),
            update.template() != null ? update.template() : subscription.template(),
            update.enabled() != null ? update.enabled() : subscription.enabled(),
            subscription.scope(),
            subscription.createdAt(),
            Instant.now()
    );
}
```

Use `ide_replace_member` on `findById` — OR-disjunction:

```java
@Override
public Optional<Subscription> findById(String id, String ownerId, String tenancyId) {
    return Optional.ofNullable(store.get(id))
            .filter(s -> s.tenancyId().equals(tenancyId))
            .filter(s -> s.ownerId().equals(ownerId) || s.scope() == SubscriptionScope.SYSTEM);
}
```

Use `ide_replace_member` on `find` — scope-aware query:

```java
@Override
public SubscriptionPage find(SubscriptionQuery query) {
    var comparator = Comparator.comparing(Subscription::createdAt)
            .thenComparing(Subscription::id)
            .reversed();

    var effectiveScope = query.scope() != null ? query.scope() : SubscriptionScope.USER;

    var filtered = store.values().stream()
            .filter(s -> s.tenancyId().equals(query.tenancyId()))
            .filter(s -> effectiveScope == SubscriptionScope.SYSTEM
                    ? s.scope() == SubscriptionScope.SYSTEM
                    : s.ownerId().equals(query.ownerId()))
            .filter(s -> query.enabled() == null || s.enabled() == query.enabled())
            .filter(s -> matchesCursor(s, query.cursor()))
            .sorted(comparator)
            .limit(query.limit() + 1)
            .toList();

    boolean hasMore = filtered.size() > query.limit();
    var subscriptions = hasMore ? filtered.subList(0, query.limit()) : filtered;
    String nextCursor = hasMore ? encodeCursor(subscriptions.get(subscriptions.size() - 1)) : null;

    return new SubscriptionPage(subscriptions, nextCursor);
}
```

Use `ide_replace_member` on `update` — OR-disjunction in the ownership check:

```java
@Override
public Optional<Subscription> update(String id, String ownerId, String tenancyId, SubscriptionUpdate update) {
    var result = new Object() {
        Subscription updated = null;
        Subscription previous = null;
    };

    store.compute(id, (key, subscription) -> {
        if (subscription == null
                || !subscription.tenancyId().equals(tenancyId)
                || (!subscription.ownerId().equals(ownerId) && subscription.scope() != SubscriptionScope.SYSTEM)) {
            return subscription;
        }

        result.previous = subscription;
        result.updated = applyUpdate(subscription, update);
        return result.updated;
    });

    if (result.updated != null) {
        fireSubscriptionUpdated(result.updated, result.previous);
    }
    return Optional.ofNullable(result.updated);
}
```

Use `ide_replace_member` on `delete` — same OR-disjunction:

```java
@Override
public boolean delete(String id, String ownerId, String tenancyId) {
    var result = new Object() {
        Subscription deleted = null;
    };

    store.compute(id, (key, subscription) -> {
        if (subscription != null
                && subscription.tenancyId().equals(tenancyId)
                && (subscription.ownerId().equals(ownerId) || subscription.scope() == SubscriptionScope.SYSTEM)) {
            result.deleted = subscription;
            return null;
        }
        return subscription;
    });

    if (result.deleted != null) {
        fireSubscriptionDeleted(result.deleted);
        return true;
    }
    return false;
}
```

- [ ] **Step 5: Build and run contract tests**

Run: `mvn --batch-mode -pl platform-api,platform,subscriptions-inmem install`
Expected: All compile. InMemorySubscriptionStoreTest (which extends SubscriptionStoreContractTest) passes all existing + new SYSTEM scope tests.

- [ ] **Step 6: Commit**

```
feat(platform#150): scope-aware InMemory subscription store + contract tests

Adds SYSTEM scope contract tests to SubscriptionStoreContractTest.
InMemorySubscriptionStore uses OR-disjunction for scope-aware auth:
findById/update/delete pass if ownerId matches OR scope is SYSTEM.
find() filters by scope — SYSTEM returns tenant-wide, USER filters
by ownerId. NoOp stores pass scope through.
```

---

### Task 3: JPA Migration + Store

**Files:**
- Create: `subscriptions-jpa/src/main/resources/db/subscription/migration/V3__subscription_scope.sql`
- Modify: `subscriptions-jpa/src/main/java/io/casehub/platform/subscription/jpa/SubscriptionEntity.java`
- Modify: `subscriptions-jpa/src/main/java/io/casehub/platform/subscription/jpa/JpaReactiveSubscriptionStore.java`

**Interfaces:**
- Consumes: `SubscriptionScope`, `Subscription(... scope ...)`, `SubscriptionInput(... scope)`, `SubscriptionQuery(... scope ...)`
- Produces: JPA subscription store with scope column, scope-aware HQL queries, OR-disjunction authorization

- [ ] **Step 1: Create Flyway migration V3**

Write `subscriptions-jpa/src/main/resources/db/subscription/migration/V3__subscription_scope.sql`:

```sql
ALTER TABLE subscription ADD COLUMN scope VARCHAR(10) NOT NULL DEFAULT 'USER';

CREATE INDEX idx_subscription_scope_tenant
    ON subscription (tenancy_id) WHERE scope = 'SYSTEM';
```

- [ ] **Step 2: Update `SubscriptionEntity` — add scope field**

Use `ide_insert_member` to add after the `enabled` field:

```java
@Column(nullable = false, length = 10)
public String scope;
```

- [ ] **Step 3: Update `SubscriptionEntity.fromInput()` — include scope**

Use `ide_replace_member` on `fromInput`. Add `entity.scope = input.scope().name();` after `entity.enabled = input.enabled();`.

- [ ] **Step 4: Update `SubscriptionEntity.toSubscription()` — include scope**

Use `ide_replace_member` on `toSubscription`. Add `SubscriptionScope.valueOf(scope)` between `enabled` and `createdAt` in the Subscription constructor call.

- [ ] **Step 5: Update `JpaReactiveSubscriptionStore.findById` — OR-disjunction**

Use `ide_replace_member` on `findById`:

```java
@Override
public Uni<Optional<Subscription>> findById(String id, String ownerId, String tenancyId) {
    return Panache.withSession(() ->
            SubscriptionEntity.<SubscriptionEntity>find(
                            "id = ?1 AND tenancyId = ?2 AND (ownerId = ?3 OR scope = 'SYSTEM')",
                            id, tenancyId, ownerId)
                    .firstResult()
                    .map(entity -> entity == null
                            ? Optional.empty()
                            : Optional.of(entity.toSubscription(mapper))));
}
```

- [ ] **Step 6: Update `JpaReactiveSubscriptionStore.find` — scope-aware query**

Use `ide_replace_member` on `find`. The HQL must branch on scope: for SYSTEM, filter by `tenancyId` and `scope = 'SYSTEM'`; for USER (or null), filter by `ownerId` and `tenancyId`.

```java
@Override
public Uni<SubscriptionPage> find(SubscriptionQuery query) {
    return Panache.withSession(() -> {
        var effectiveScope = query.scope() != null ? query.scope() : SubscriptionScope.USER;

        StringBuilder hql = new StringBuilder("FROM SubscriptionEntity WHERE tenancyId = ?1");
        List<Object> params = new ArrayList<>();
        params.add(query.tenancyId());
        int paramIndex = 2;

        if (effectiveScope == SubscriptionScope.SYSTEM) {
            hql.append(" AND scope = 'SYSTEM'");
        } else {
            hql.append(" AND ownerId = ?").append(paramIndex);
            params.add(query.ownerId());
            paramIndex++;
        }

        if (query.enabled() != null) {
            hql.append(" AND enabled = ?").append(paramIndex);
            params.add(query.enabled());
            paramIndex++;
        }

        if (query.cursor() != null) {
            CursorValue cursor = decodeCursor(query.cursor());
            if (cursor != null) {
                hql.append(" AND (createdAt < ?").append(paramIndex);
                params.add(cursor.createdAt);
                paramIndex++;
                hql.append(" OR (createdAt = ?").append(paramIndex);
                params.add(cursor.createdAt);
                paramIndex++;
                hql.append(" AND id < ?").append(paramIndex).append("))");
                params.add(cursor.id);
                paramIndex++;
            }
        }

        hql.append(" ORDER BY createdAt DESC, id DESC");

        int fetchLimit = query.limit() + 1;

        return SubscriptionEntity.<SubscriptionEntity>find(hql.toString(), params.toArray())
                .range(0, fetchLimit - 1)
                .list()
                .map(entities -> {
                    boolean hasMore = entities.size() > query.limit();
                    List<SubscriptionEntity> pageEntities = hasMore
                            ? entities.subList(0, query.limit())
                            : entities;

                    List<Subscription> subscriptions = new ArrayList<>(pageEntities.size());
                    for (SubscriptionEntity entity : pageEntities) {
                        subscriptions.add(entity.toSubscription(mapper));
                    }

                    String nextCursor = null;
                    if (hasMore && !pageEntities.isEmpty()) {
                        SubscriptionEntity last = pageEntities.getLast();
                        nextCursor = encodeCursor(last.createdAt, last.id);
                    }
                    return new SubscriptionPage(subscriptions, nextCursor);
                });
    });
}
```

- [ ] **Step 7: Update `JpaReactiveSubscriptionStore.update` — OR-disjunction**

Use `ide_replace_member` on `update`. Change the HQL from `"id = ?1 AND ownerId = ?2 AND tenancyId = ?3"` to `"id = ?1 AND tenancyId = ?2 AND (ownerId = ?3 OR scope = 'SYSTEM')"` and swap parameter order accordingly.

- [ ] **Step 8: Update `JpaReactiveSubscriptionStore.delete` — OR-disjunction**

Same pattern as update. Change the find HQL to use `"id = ?1 AND tenancyId = ?2 AND (ownerId = ?3 OR scope = 'SYSTEM')"`.

- [ ] **Step 9: Build subscriptions-jpa**

Run: `mvn --batch-mode -pl subscriptions-jpa install`
Expected: Compiles. JpaSubscriptionStoreTest extends contract test — all tests pass including new SYSTEM scope tests.

- [ ] **Step 10: Commit**

```
feat(platform#150): JPA subscription store scope support + V3 migration

Adds scope column (VARCHAR(10), default 'USER') with partial index
on (tenancy_id) WHERE scope = 'SYSTEM'. SubscriptionEntity maps
scope to/from SubscriptionScope enum. JpaReactiveSubscriptionStore
uses OR-disjunction HQL for scope-aware authorization.
```

---

### Task 4: REST Layer — Admin Auth, Scope Param, Validation + Engine Regression

**Files:**
- Modify: `subscriptions/src/main/java/io/casehub/platform/subscription/rest/SubscriptionResource.java`
- Modify: `subscriptions/src/test/java/io/casehub/platform/subscription/rest/SubscriptionResourceTest.java`
- Modify: `subscriptions/src/test/java/io/casehub/platform/subscription/engine/SubscriptionEngineTest.java`

**Interfaces:**
- Consumes: `SubscriptionScope`, `SubscriptionConstants.SYSTEM_SUBSCRIPTION_ADMIN_GROUP`, `CurrentPrincipal.hasGroup()`, `SubscriptionQuery(... scope ...)`
- Produces: REST endpoints with admin authorization for SYSTEM scope, creation validation, scope query parameter

- [ ] **Step 1: Write failing REST tests for SYSTEM scope**

Use `ide_insert_member` to add test methods to `SubscriptionResourceTest`. First fix existing helper method/test constructor calls to include scope parameter (add `null` as last arg to `SubscriptionInput` calls, add `null` as 3rd arg to `SubscriptionQuery` if any).

Then add SYSTEM scope tests:

```java
@Test
void create_systemScope_adminSucceeds() {
    principal.setActorId("admin-1");
    principal.addGroup("subscription-admins");

    var template = createTestTemplate();
    var input = new SubscriptionInput(
            "admin-1", TenancyConstants.DEFAULT_TENANT_ID, "System Alert",
            "io.casehub.alert.triggered", List.of(),
            List.of(new NotificationTarget(TargetType.GROUP, "case-managers")),
            false, template, true, SubscriptionScope.SYSTEM
    );

    given()
        .contentType(ContentType.JSON)
        .body(input)
        .when().post("/subscriptions")
        .then()
        .statusCode(201)
        .body("scope", equalTo("SYSTEM"))
        .body("ownerId", equalTo("admin-1"));
}

@Test
void create_systemScope_nonAdminForbidden() {
    var template = createTestTemplate();
    var input = new SubscriptionInput(
            "user-1", TenancyConstants.DEFAULT_TENANT_ID, "System Alert",
            "io.casehub.alert.triggered", List.of(),
            List.of(new NotificationTarget(TargetType.GROUP, "case-managers")),
            false, template, true, SubscriptionScope.SYSTEM
    );

    given()
        .contentType(ContentType.JSON)
        .body(input)
        .when().post("/subscriptions")
        .then()
        .statusCode(403);
}

@Test
void create_systemScope_emptyTargetsRejected() {
    principal.addGroup("subscription-admins");

    var template = createTestTemplate();
    var input = new SubscriptionInput(
            "user-1", TenancyConstants.DEFAULT_TENANT_ID, "System Alert",
            "io.casehub.alert.triggered", List.of(),
            List.of(), false, template, true, SubscriptionScope.SYSTEM
    );

    given()
        .contentType(ContentType.JSON)
        .body(input)
        .when().post("/subscriptions")
        .then()
        .statusCode(400);
}

@Test
void create_systemScope_dollarMeConstraintRejected() {
    principal.addGroup("subscription-admins");

    var template = createTestTemplate();
    var input = new SubscriptionInput(
            "user-1", TenancyConstants.DEFAULT_TENANT_ID, "System Alert",
            "io.casehub.alert.triggered",
            List.of(new Constraint("assigneeId", ConstraintOp.EQ, "$me")),
            List.of(new NotificationTarget(TargetType.GROUP, "case-managers")),
            false, template, true, SubscriptionScope.SYSTEM
    );

    given()
        .contentType(ContentType.JSON)
        .body(input)
        .when().post("/subscriptions")
        .then()
        .statusCode(400);
}

@Test
void list_systemScope_returnsTenantWide() {
    principal.setActorId("admin-1");
    principal.addGroup("subscription-admins");

    var template = createTestTemplate();
    var sysInput = new SubscriptionInput(
            "admin-1", TenancyConstants.DEFAULT_TENANT_ID, "System Alert",
            "io.casehub.alert.triggered", List.of(),
            List.of(new NotificationTarget(TargetType.GROUP, "all")),
            false, template, true, SubscriptionScope.SYSTEM
    );
    store.store(sysInput).await().indefinitely();

    // Switch to a regular user — should still see SYSTEM subscriptions
    principal.setActorId("user-1");
    principal.setGroups(Set.of());

    given()
        .queryParam("scope", "SYSTEM")
        .when().get("/subscriptions")
        .then()
        .statusCode(200)
        .body("subscriptions", hasSize(1))
        .body("subscriptions[0].scope", equalTo("SYSTEM"));
}

@Test
void getById_systemScope_anyTenantUserCanRead() {
    principal.setActorId("admin-1");
    principal.addGroup("subscription-admins");

    var template = createTestTemplate();
    var sysInput = new SubscriptionInput(
            "admin-1", TenancyConstants.DEFAULT_TENANT_ID, "System Alert",
            "io.casehub.alert.triggered", List.of(),
            List.of(new NotificationTarget(TargetType.GROUP, "all")),
            false, template, true, SubscriptionScope.SYSTEM
    );
    var sub = store.store(sysInput).await().indefinitely();

    // Regular user reads it
    principal.setActorId("user-1");
    principal.setGroups(Set.of());

    given()
        .when().get("/subscriptions/{id}", sub.id())
        .then()
        .statusCode(200)
        .body("scope", equalTo("SYSTEM"));
}

@Test
void update_systemScope_nonAdminForbidden() {
    principal.setActorId("admin-1");
    principal.addGroup("subscription-admins");

    var template = createTestTemplate();
    var sysInput = new SubscriptionInput(
            "admin-1", TenancyConstants.DEFAULT_TENANT_ID, "System Alert",
            "io.casehub.alert.triggered", List.of(),
            List.of(new NotificationTarget(TargetType.GROUP, "all")),
            false, template, true, SubscriptionScope.SYSTEM
    );
    var sub = store.store(sysInput).await().indefinitely();

    // Regular user tries to update
    principal.setActorId("user-1");
    principal.setGroups(Set.of());

    given()
        .contentType(ContentType.JSON)
        .body(new SubscriptionUpdate("Hacked", null, null, null, null, null, null))
        .when().patch("/subscriptions/{id}", sub.id())
        .then()
        .statusCode(403);
}

@Test
void update_systemScope_adminSucceeds() {
    principal.setActorId("admin-1");
    principal.addGroup("subscription-admins");

    var template = createTestTemplate();
    var sysInput = new SubscriptionInput(
            "admin-1", TenancyConstants.DEFAULT_TENANT_ID, "System Alert",
            "io.casehub.alert.triggered", List.of(),
            List.of(new NotificationTarget(TargetType.GROUP, "all")),
            false, template, true, SubscriptionScope.SYSTEM
    );
    var sub = store.store(sysInput).await().indefinitely();

    given()
        .contentType(ContentType.JSON)
        .body(new SubscriptionUpdate("Updated Alert", null, null, null, null, null, null))
        .when().patch("/subscriptions/{id}", sub.id())
        .then()
        .statusCode(200)
        .body("name", equalTo("Updated Alert"));
}

@Test
void delete_systemScope_nonAdminForbidden() {
    principal.setActorId("admin-1");
    principal.addGroup("subscription-admins");

    var template = createTestTemplate();
    var sysInput = new SubscriptionInput(
            "admin-1", TenancyConstants.DEFAULT_TENANT_ID, "System Alert",
            "io.casehub.alert.triggered", List.of(),
            List.of(new NotificationTarget(TargetType.GROUP, "all")),
            false, template, true, SubscriptionScope.SYSTEM
    );
    var sub = store.store(sysInput).await().indefinitely();

    principal.setActorId("user-1");
    principal.setGroups(Set.of());

    given()
        .when().delete("/subscriptions/{id}", sub.id())
        .then()
        .statusCode(403);
}

@Test
void delete_systemScope_adminSucceeds() {
    principal.setActorId("admin-1");
    principal.addGroup("subscription-admins");

    var template = createTestTemplate();
    var sysInput = new SubscriptionInput(
            "admin-1", TenancyConstants.DEFAULT_TENANT_ID, "System Alert",
            "io.casehub.alert.triggered", List.of(),
            List.of(new NotificationTarget(TargetType.GROUP, "all")),
            false, template, true, SubscriptionScope.SYSTEM
    );
    var sub = store.store(sysInput).await().indefinitely();

    given()
        .when().delete("/subscriptions/{id}", sub.id())
        .then()
        .statusCode(204);
}

@Test
void enable_systemScope_nonAdminForbidden() {
    principal.setActorId("admin-1");
    principal.addGroup("subscription-admins");

    var template = createTestTemplate();
    var sysInput = new SubscriptionInput(
            "admin-1", TenancyConstants.DEFAULT_TENANT_ID, "System Alert",
            "io.casehub.alert.triggered", List.of(),
            List.of(new NotificationTarget(TargetType.GROUP, "all")),
            false, template, true, SubscriptionScope.SYSTEM
    );
    var sub = store.store(sysInput).await().indefinitely();

    principal.setActorId("user-1");
    principal.setGroups(Set.of());

    given()
        .when().patch("/subscriptions/{id}/enable", sub.id())
        .then()
        .statusCode(403);
}

@Test
void create_userScope_backwardCompat() {
    var template = createTestTemplate();
    var input = new SubscriptionInput(
            "user-1", TenancyConstants.DEFAULT_TENANT_ID, "My Sub",
            "io.casehub.work.item.created", List.of(),
            List.of(new NotificationTarget(TargetType.USER, "user-1")),
            false, template, true, null
    );

    given()
        .contentType(ContentType.JSON)
        .body(input)
        .when().post("/subscriptions")
        .then()
        .statusCode(201)
        .body("scope", equalTo("USER"));
}
```

Add a `createTestTemplate()` helper if not already present (extract from existing tests).

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode -pl subscriptions test`
Expected: New tests fail (SubscriptionResource doesn't have scope logic yet). Existing tests may fail due to SubscriptionInput constructor changes.

- [ ] **Step 3: Update `SubscriptionResource` — admin auth, scope param, validation**

Use `ide_edit_member` on `SubscriptionResource` for the class declaration — no new dependencies needed (`CurrentPrincipal` is already injected).

Update `create` method: check `input.scope() == SYSTEM` → verify admin, validate targets non-empty, reject `$me` constraints. Use `ide_replace_member`.

Update `list` method: accept `@QueryParam("scope") SubscriptionScope scope` and pass to query. Use `ide_replace_member`.

Update `update`, `delete`, `enable`, `disable` methods: two-phase pattern — lookup first to check scope, gate to admin for SYSTEM scope. Use `ide_replace_member` on each.

Key implementation for `create`:

```java
@POST
public Uni<Response> create(final SubscriptionInput input) {
    var effectiveScope = input.scope();

    if (effectiveScope == SubscriptionScope.SYSTEM) {
        if (!principal.hasGroup(SubscriptionConstants.SYSTEM_SUBSCRIPTION_ADMIN_GROUP)) {
            return Uni.createFrom().item(Response.status(403).build());
        }
        if (input.targets() == null || input.targets().isEmpty()) {
            return Uni.createFrom().item(Response.status(400)
                    .entity("SYSTEM scope requires explicit targets").build());
        }
        for (var constraint : input.constraints()) {
            if ("$me".equals(String.valueOf(constraint.value()))) {
                return Uni.createFrom().item(Response.status(400)
                        .entity("$me constraint not allowed for SYSTEM scope").build());
            }
        }
    }

    final var targets = (effectiveScope != SubscriptionScope.SYSTEM
            && (input.targets() == null || input.targets().isEmpty()))
        ? List.of(new NotificationTarget(TargetType.USER, principal.actorId()))
        : input.targets();

    final var securedInput = new SubscriptionInput(
        principal.actorId(),
        principal.tenancyId(),
        input.name(),
        input.eventType(),
        input.constraints(),
        targets,
        input.includeActor(),
        input.template(),
        input.enabled(),
        effectiveScope
    );
    return store.store(securedInput)
        .map(s -> Response.status(201).entity(s).build());
}
```

Key implementation for mutation endpoints (update example):

```java
@PATCH
@Path("/{id}")
public Uni<Response> update(@PathParam("id") final String id, final SubscriptionUpdate update) {
    return store.findById(id, principal.actorId(), principal.tenancyId())
        .chain(opt -> {
            if (opt.isEmpty()) {
                return Uni.createFrom().item(Response.status(404).build());
            }
            var sub = opt.get();
            if (sub.scope() == SubscriptionScope.SYSTEM
                    && !principal.hasGroup(SubscriptionConstants.SYSTEM_SUBSCRIPTION_ADMIN_GROUP)) {
                return Uni.createFrom().item(Response.status(403).build());
            }
            return store.update(id, principal.actorId(), principal.tenancyId(), update)
                .map(result -> result.map(s -> Response.ok(s).build())
                    .orElse(Response.status(404).build()));
        });
}
```

Same two-phase pattern for `delete`, `enable`, `disable`.

Updated `list`:

```java
@GET
public Uni<SubscriptionPage> list(
        @QueryParam("enabled") final Boolean enabled,
        @QueryParam("scope") final SubscriptionScope scope,
        @QueryParam("cursor") final String cursor,
        @QueryParam("limit") @DefaultValue("25") final int limit) {
    final var query = new SubscriptionQuery(
        scope == SubscriptionScope.SYSTEM ? null : principal.actorId(),
        principal.tenancyId(),
        scope,
        enabled,
        cursor,
        limit
    );
    return store.find(query);
}
```

Updated `getById` — no admin gate (any tenant user can read):

```java
@GET
@Path("/{id}")
public Uni<Response> getById(@PathParam("id") final String id) {
    return store.findById(id, principal.actorId(), principal.tenancyId())
        .map(opt -> opt.map(s -> Response.ok(s).build())
            .orElse(Response.status(404).build()));
}
```

(No change — OR-disjunction in store handles it.)

- [ ] **Step 4: Fix `SubscriptionEngineTest` constructor calls + add SYSTEM scope regression test**

Fix all `Subscription()` constructor calls — add `SubscriptionScope.USER` before `createdAt`. Fix all `SubscriptionInput()` calls — add `null` as last arg.

Add regression test:

```java
@Test
void systemSubscription_wiresAndMatchesIdentically() {
    var template = defaultTemplate();
    var input = new SubscriptionInput("admin-1", "tenant-1", "System sub",
            "io.casehub.work.workitem.completed",
            List.of(), List.of(new NotificationTarget(TargetType.GROUP, "case-managers")),
            false, template, true, SubscriptionScope.SYSTEM);
    var storedSub = subStore.store(input);

    engine.onStartup(null);

    pushEvent("io.casehub.work.workitem.completed", "tenant-1",
            UUID.randomUUID(), "actor-1");

    assertThat(firedEvents).hasSize(1);
    assertThat(firedEvents.get(0).subscription().scope()).isEqualTo(SubscriptionScope.SYSTEM);
}
```

- [ ] **Step 5: Run all tests**

Run: `mvn --batch-mode -pl subscriptions test`
Expected: All existing tests pass. All new SYSTEM scope REST tests pass. Engine regression test passes.

- [ ] **Step 6: Full build**

Run: `mvn --batch-mode install`
Expected: Full project compiles and all tests pass across all modules.

- [ ] **Step 7: Commit**

```
feat(platform#150): REST admin authorization for system subscriptions

SubscriptionResource enforces admin gate for SYSTEM scope: create
requires subscription-admins group, empty targets rejected, $me
constraint rejected. Mutation endpoints use two-phase lookup-then-gate
pattern. List accepts scope query parameter. Engine regression test
confirms SYSTEM subscriptions wire identically.
```
