# Retire Reactive Tiers — Platform Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #384 — All repos: retire reactive tiers (platform, qhorus, ledger, eidos, work, app repos)
**Issue group:** #384

**Goal:** Delete all reactive SPI interfaces, implementations, and bridges from the platform repo. Rewrite JPA stores from Hibernate Reactive Panache to standard JPA. Convert REST resources from `Uni<T>` returns to blocking with `@RunOnVirtualThread`.

**Architecture:** The platform has two dual-stack SPI pairs (NotificationStore/ReactiveNotificationStore, SubscriptionStore/ReactiveSubscriptionStore) plus one identity bridge class. The blocking JPA stores currently delegate to the reactive JPA stores via Vert.x context wrappers — they must be rewritten to use EntityManager + `@Transactional` directly. REST resources switch from `Uni<T>` (event-loop) to plain returns (virtual-thread). The migration guide at `engine/docs/guides/virtual-thread-migration.md` is the cookbook.

**Tech Stack:** Quarkus, Hibernate ORM (replacing Hibernate Reactive Panache), Jakarta Persistence, `@RunOnVirtualThread`

## Global Constraints

- No `Reactive*` interfaces remain in `src/main/java`
- No `Uni<` in handler/endpoint return types (SSE `Multi<T>` stays per cookbook §7)
- No `.await().indefinitely()` calls remain
- No `Uni.createFrom().item()` wrapping blocking code
- No `runSubscriptionOn` calls remain
- No `quarkus-hibernate-reactive-panache` in any pom.xml
- No `quarkus-reactive-pg-client` in any pom.xml
- `@Transactional` on repository methods that do writes
- Entity classes use `@Id`, not `PanacheEntityBase`
- platform-api remains zero-dependency — no Quarkus, no JPA imports

---

### Task 1: Delete reactive SPI interfaces from platform-api

**Files:**
- Delete: `platform-api/src/main/java/io/casehub/platform/api/notification/ReactiveNotificationStore.java` (use `ide_refactor_safe_delete`)
- Delete: `platform-api/src/main/java/io/casehub/platform/api/subscription/ReactiveSubscriptionStore.java` (use `ide_refactor_safe_delete`)
- Modify: `platform-api/src/main/java/io/casehub/platform/api/notification/NotificationStore.java` — remove Javadoc references to `ReactiveNotificationStore`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/subscription/SubscriptionStore.java` — remove Javadoc references to `ReactiveSubscriptionStore`

**Interfaces:**
- Produces: `NotificationStore` and `SubscriptionStore` become the sole SPIs. All downstream tasks depend on these interfaces not having a reactive counterpart.

**Notes:** `ide_refactor_safe_delete` will report usages in platform modules (NoOp, InMemory, JPA implementations, REST resources, tests). Use `force: true` since all consumers are deleted or rewritten in later tasks. Alternatively, run Tasks 2–7 first and delete these last — but since the interfaces are the root cause and all downstream changes are in the same branch, force-delete first is cleaner.

- [ ] **Step 1: Force-delete ReactiveNotificationStore.java**

```
ide_refactor_safe_delete(file: "platform-api/src/main/java/io/casehub/platform/api/notification/ReactiveNotificationStore.java", target_type: "file", force: true)
```

- [ ] **Step 2: Force-delete ReactiveSubscriptionStore.java**

```
ide_refactor_safe_delete(file: "platform-api/src/main/java/io/casehub/platform/api/subscription/ReactiveSubscriptionStore.java", target_type: "file", force: true)
```

- [ ] **Step 3: Update NotificationStore Javadoc**

Remove the line referencing ReactiveNotificationStore from the class Javadoc:
```java
// Remove this line from NotificationStore.java:
// * and {@link ReactiveNotificationStore} natively — no bridge pattern.
// Replace with:
// * <p>Single blocking SPI — no reactive counterpart.
```

- [ ] **Step 4: Update SubscriptionStore Javadoc**

Remove the line referencing ReactiveSubscriptionStore from the class Javadoc:
```java
// Remove this line from SubscriptionStore.java:
// * and {@link ReactiveSubscriptionStore} natively — no bridge pattern.
// Replace with:
// * <p>Single blocking SPI — no reactive counterpart.
```

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/worktrees/30/platform add platform-api/
git -C /Users/mdproctor/claude/casehub/worktrees/30/platform commit -m "feat(#384): delete ReactiveNotificationStore and ReactiveSubscriptionStore SPIs"
```

---

### Task 2: Delete NoOp and bridge reactive implementations

**Files:**
- Delete: `platform/src/main/java/io/casehub/platform/notification/NoOpReactiveNotificationStore.java`
- Delete: `platform/src/main/java/io/casehub/platform/subscription/NoOpReactiveSubscriptionStore.java`
- Delete: `identity/src/main/java/io/casehub/platform/identity/ReactiveAgentIdentityVerificationService.java`

**Interfaces:**
- Consumes: Task 1 removed the SPI interfaces these implement
- Produces: NoOp and bridge classes removed — CDI no longer offers reactive beans

- [ ] **Step 1: Delete NoOpReactiveNotificationStore.java**

```
ide_refactor_safe_delete(file: "platform/src/main/java/io/casehub/platform/notification/NoOpReactiveNotificationStore.java", target_type: "file", force: true)
```

- [ ] **Step 2: Delete NoOpReactiveSubscriptionStore.java**

```
ide_refactor_safe_delete(file: "platform/src/main/java/io/casehub/platform/subscription/NoOpReactiveSubscriptionStore.java", target_type: "file", force: true)
```

- [ ] **Step 3: Delete ReactiveAgentIdentityVerificationService.java**

Zero references found during audit — safe delete without force.

```
ide_refactor_safe_delete(file: "identity/src/main/java/io/casehub/platform/identity/ReactiveAgentIdentityVerificationService.java", target_type: "file")
```

- [ ] **Step 4: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/worktrees/30/platform add platform/ identity/
git -C /Users/mdproctor/claude/casehub/worktrees/30/platform commit -m "feat(#384): delete NoOp reactive stores and identity bridge"
```

---

### Task 3: Delete InMemory reactive implementations

**Files:**
- Delete: `notifications-inmem/src/main/java/io/casehub/platform/notification/inmem/InMemoryReactiveNotificationStore.java`
- Delete: `subscriptions-inmem/src/main/java/io/casehub/platform/subscription/inmem/InMemoryReactiveSubscriptionStore.java`

**Interfaces:**
- Consumes: Task 1 removed the SPI interfaces these implement
- Produces: InMemory modules now only provide blocking stores (`InMemoryNotificationStore`, `InMemorySubscriptionStore`)

- [ ] **Step 1: Delete InMemoryReactiveNotificationStore.java**

```
ide_refactor_safe_delete(file: "notifications-inmem/src/main/java/io/casehub/platform/notification/inmem/InMemoryReactiveNotificationStore.java", target_type: "file", force: true)
```

- [ ] **Step 2: Delete InMemoryReactiveSubscriptionStore.java**

```
ide_refactor_safe_delete(file: "subscriptions-inmem/src/main/java/io/casehub/platform/subscription/inmem/InMemoryReactiveSubscriptionStore.java", target_type: "file", force: true)
```

- [ ] **Step 3: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/worktrees/30/platform add notifications-inmem/ subscriptions-inmem/
git -C /Users/mdproctor/claude/casehub/worktrees/30/platform commit -m "feat(#384): delete InMemory reactive notification and subscription stores"
```

---

### Task 4: Rewrite notifications-jpa to standard JPA

The current `JpaNotificationStore` delegates to `JpaReactiveNotificationStore` via Vert.x context. After this task, `JpaNotificationStore` uses EntityManager + `@Transactional` directly, and the reactive store and Panache dependency are gone.

**Files:**
- Delete: `notifications-jpa/src/main/java/io/casehub/platform/notification/jpa/JpaReactiveNotificationStore.java`
- Modify: `notifications-jpa/src/main/java/io/casehub/platform/notification/jpa/JpaNotificationStore.java` — complete rewrite
- Modify: `notifications-jpa/src/main/java/io/casehub/platform/notification/jpa/NotificationEntity.java` — remove `PanacheEntityBase`
- Modify: `notifications-jpa/src/main/java/io/casehub/platform/notification/jpa/NotificationRetentionScheduler.java` — rewrite from `Mutiny.SessionFactory` to EntityManager
- Modify: `notifications-jpa/pom.xml` — swap reactive deps for standard JPA
- Modify: `notifications-jpa/src/test/java/io/casehub/platform/notification/jpa/JpaNotificationStoreTest.java` — remove reactive tests, update `clearState()`
- Test: `notifications-jpa/src/test/java/io/casehub/platform/notification/jpa/JpaNotificationStoreTest.java`

**Interfaces:**
- Consumes: `NotificationStore` (blocking SPI from platform-api), `NotificationInput`, `Notification`, `NotificationPage`, `NotificationQuery`, `NotificationStatus`, `NotificationSeverity`, `NotificationSource`, `UUIDv7`
- Produces: `JpaNotificationStore @ApplicationScoped implements NotificationStore` — the sole JPA notification store

- [ ] **Step 1: Update pom.xml — swap reactive for standard JPA**

Replace in `notifications-jpa/pom.xml`:
```xml
<!-- Remove -->
<artifactId>quarkus-hibernate-reactive-panache</artifactId>
<!-- Remove -->
<artifactId>quarkus-reactive-pg-client</artifactId>

<!-- Add -->
<artifactId>quarkus-hibernate-orm</artifactId>
```

Also remove test dependency `quarkus-test-vertx` (no longer needed — no `@RunOnVertxContext`).

Update `<description>` to remove "ReactiveNotificationStore" and "Hibernate Reactive Panache" references.

- [ ] **Step 2: Remove PanacheEntityBase from NotificationEntity**

Change `NotificationEntity` from:
```java
public class NotificationEntity extends PanacheEntityBase {
```
To:
```java
public class NotificationEntity {
```

Remove the `PanacheEntityBase` import. All other fields and methods stay — `@Id`, `@Entity`, `@Table`, `fromInput()`, `toNotification()` are already standard JPA.

- [ ] **Step 3: Delete JpaReactiveNotificationStore.java**

```
ide_refactor_safe_delete(file: "notifications-jpa/src/main/java/io/casehub/platform/notification/jpa/JpaReactiveNotificationStore.java", target_type: "file", force: true)
```

- [ ] **Step 4: Rewrite JpaNotificationStore to use EntityManager + @Transactional**

Replace the entire class body. The store must:
- Inject `EntityManager` and CDI `Event<>` instances (same as the deleted reactive store)
- Use `@Transactional` on mutating methods
- Use JPQL queries directly via `em.createQuery()`
- Fire CDI events via `fireAsync()` (same as reactive store did)
- Implement keyset cursor pagination (same Base64-encoded `createdAt|id` scheme)

```java
@ApplicationScoped
public class JpaNotificationStore implements NotificationStore {

    @Inject EntityManager em;
    @Inject Event<NotificationCreated> createdEvent;
    @Inject Event<NotificationStatusChanged> statusChangedEvent;
    @Inject Event<AllNotificationsRead> allReadEvent;

    @Override
    @Transactional
    public Notification store(NotificationInput input) {
        NotificationEntity entity = NotificationEntity.fromInput(input);
        em.persist(entity);
        em.flush();
        Notification notification = entity.toNotification();
        createdEvent.fireAsync(new NotificationCreated(notification));
        return notification;
    }

    @Override
    @Transactional
    public List<Notification> storeAll(List<NotificationInput> inputs) {
        List<Notification> notifications = new ArrayList<>(inputs.size());
        for (NotificationInput input : inputs) {
            NotificationEntity entity = NotificationEntity.fromInput(input);
            em.persist(entity);
            em.flush();
            Notification notification = entity.toNotification();
            notifications.add(notification);
            createdEvent.fireAsync(new NotificationCreated(notification));
        }
        return notifications;
    }

    @Override
    public NotificationPage find(NotificationQuery query) {
        // Build JPQL with keyset cursor pagination
        // Same logic as the deleted JpaReactiveNotificationStore.find()
        // but using em.createQuery() instead of Panache statics
        StringBuilder hql = new StringBuilder(
                "FROM NotificationEntity WHERE userId = :userId AND tenancyId = :tenancyId");
        var params = new java.util.HashMap<String, Object>();
        params.put("userId", query.userId());
        params.put("tenancyId", query.tenancyId());

        if (query.status() != null) {
            hql.append(" AND status = :status");
            params.put("status", query.status());
        }
        if (query.category() != null) {
            hql.append(" AND category = :category");
            params.put("category", query.category());
        }
        if (query.cursor() != null) {
            CursorValue cursor = decodeCursor(query.cursor());
            if (cursor != null) {
                hql.append(" AND (createdAt < :cursorCreatedAt")
                   .append(" OR (createdAt = :cursorCreatedAt AND id < :cursorId))");
                params.put("cursorCreatedAt", cursor.createdAt);
                params.put("cursorId", cursor.id);
            }
        }
        hql.append(" ORDER BY createdAt DESC, id DESC");

        int fetchLimit = query.limit() + 1;
        var jpaQuery = em.createQuery(hql.toString(), NotificationEntity.class);
        params.forEach(jpaQuery::setParameter);
        jpaQuery.setMaxResults(fetchLimit);

        List<NotificationEntity> entities = jpaQuery.getResultList();
        boolean hasMore = entities.size() > query.limit();
        List<NotificationEntity> pageEntities = hasMore
                ? entities.subList(0, query.limit())
                : entities;

        List<Notification> notifications = new ArrayList<>(pageEntities.size());
        for (NotificationEntity entity : pageEntities) {
            notifications.add(entity.toNotification());
        }

        String nextCursor = null;
        if (hasMore && !pageEntities.isEmpty()) {
            NotificationEntity last = pageEntities.getLast();
            nextCursor = encodeCursor(last.createdAt, last.id);
        }
        return new NotificationPage(notifications, nextCursor);
    }

    @Override
    public long unreadCount(String userId, String tenancyId) {
        return em.createQuery(
                "SELECT COUNT(n) FROM NotificationEntity n " +
                "WHERE n.userId = :userId AND n.tenancyId = :tenancyId AND n.status = :status",
                Long.class)
            .setParameter("userId", userId)
            .setParameter("tenancyId", tenancyId)
            .setParameter("status", NotificationStatus.UNREAD)
            .getSingleResult();
    }

    @Override
    @Transactional
    public Optional<Notification> markRead(String id, String userId, String tenancyId) {
        NotificationEntity entity = em.createQuery(
                "FROM NotificationEntity WHERE id = :id AND userId = :userId " +
                "AND tenancyId = :tenancyId AND status != :dismissed",
                NotificationEntity.class)
            .setParameter("id", id)
            .setParameter("userId", userId)
            .setParameter("tenancyId", tenancyId)
            .setParameter("dismissed", NotificationStatus.DISMISSED)
            .getResultStream().findFirst().orElse(null);

        if (entity == null) return Optional.empty();

        NotificationStatus previousStatus = entity.status;
        entity.status = NotificationStatus.READ;
        entity.readAt = Instant.now();
        Notification notification = entity.toNotification();
        statusChangedEvent.fireAsync(new NotificationStatusChanged(notification, previousStatus));
        return Optional.of(notification);
    }

    @Override
    @Transactional
    public Optional<Notification> dismiss(String id, String userId, String tenancyId) {
        NotificationEntity entity = em.createQuery(
                "FROM NotificationEntity WHERE id = :id AND userId = :userId " +
                "AND tenancyId = :tenancyId AND status != :dismissed",
                NotificationEntity.class)
            .setParameter("id", id)
            .setParameter("userId", userId)
            .setParameter("tenancyId", tenancyId)
            .setParameter("dismissed", NotificationStatus.DISMISSED)
            .getResultStream().findFirst().orElse(null);

        if (entity == null) return Optional.empty();

        NotificationStatus previousStatus = entity.status;
        entity.status = NotificationStatus.DISMISSED;
        entity.dismissedAt = Instant.now();
        Notification notification = entity.toNotification();
        statusChangedEvent.fireAsync(new NotificationStatusChanged(notification, previousStatus));
        return Optional.of(notification);
    }

    @Override
    @Transactional
    public int markAllRead(String userId, String tenancyId) {
        Instant now = Instant.now();
        int count = em.createQuery(
                "UPDATE NotificationEntity SET status = :readStatus, readAt = :now " +
                "WHERE userId = :userId AND tenancyId = :tenancyId AND status = :unread")
            .setParameter("readStatus", NotificationStatus.READ)
            .setParameter("now", now)
            .setParameter("userId", userId)
            .setParameter("tenancyId", tenancyId)
            .setParameter("unread", NotificationStatus.UNREAD)
            .executeUpdate();

        if (count > 0) {
            allReadEvent.fireAsync(new AllNotificationsRead(userId, tenancyId, count));
        }
        return count;
    }

    // Cursor encoding: same scheme as deleted reactive store
    private static String encodeCursor(Instant createdAt, String id) { /* same */ }
    private static CursorValue decodeCursor(String cursor) { /* same */ }
    private record CursorValue(Instant createdAt, String id) {}
}
```

- [ ] **Step 5: Rewrite NotificationRetentionScheduler to use EntityManager**

Replace `Mutiny.SessionFactory sf` + Vert.x context wrapper with:
```java
@Inject EntityManager em;

@Scheduled(every = "${casehub.notification.jpa.retention-check-interval:24h}")
@Transactional
void purge() {
    Instant readDismissedCutoff = Instant.now().minus(retentionDays, ChronoUnit.DAYS);
    Instant unreadCutoff = Instant.now().minus(unreadRetentionDays, ChronoUnit.DAYS);

    LOG.infof("Starting notification retention purge: READ/DISMISSED < %s, UNREAD < %s",
            readDismissedCutoff, unreadCutoff);

    int readDismissed = em.createQuery(
            "DELETE FROM NotificationEntity WHERE status IN (:read, :dismissed) AND createdAt < :cutoff")
        .setParameter("read", NotificationStatus.READ)
        .setParameter("dismissed", NotificationStatus.DISMISSED)
        .setParameter("cutoff", readDismissedCutoff)
        .executeUpdate();

    int unread = em.createQuery(
            "DELETE FROM NotificationEntity WHERE status = :unread AND createdAt < :cutoff")
        .setParameter("unread", NotificationStatus.UNREAD)
        .setParameter("cutoff", unreadCutoff)
        .executeUpdate();

    LOG.infof("Notification retention purge completed: %d notifications deleted",
            readDismissed + unread);
}
```

Remove `Vertx`, `VertxContext`, `VertxContextSafetyToggle`, `Mutiny`, `Uni`, `CompletionStage` imports and the `execute()` method.

- [ ] **Step 6: Update JpaNotificationStoreTest**

1. Remove `@Inject ReactiveNotificationStore reactiveStore` field
2. Remove all `reactive_*` test methods (7 methods with `@RunOnVertxContext`)
3. Rewrite `clearState()` from Vert.x context + Panache to:
```java
@Override
protected void clearState() {
    em.createQuery("DELETE FROM NotificationEntity").executeUpdate();
}
```
This requires adding `@Inject EntityManager em` and wrapping with `@Transactional` (or using `@TestTransaction` on the test class). Check how the contract test base class handles transactions.

4. Remove imports: `ReactiveNotificationStore`, `Panache`, `RunOnVertxContext`, `UniAsserter`, `VertxContext`, `VertxContextSafetyToggle`, `Uni`, `Vertx`

- [ ] **Step 7: Run tests**

```bash
mvn --batch-mode -pl notifications-jpa test
```

Expected: all remaining tests pass (contract tests via blocking store + entity mapping tests). Reactive-specific tests are deleted.

- [ ] **Step 8: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/worktrees/30/platform add notifications-jpa/
git -C /Users/mdproctor/claude/casehub/worktrees/30/platform commit -m "feat(#384): rewrite notifications-jpa from Hibernate Reactive to standard JPA"
```

---

### Task 5: Rewrite subscriptions-jpa to standard JPA

Same pattern as Task 4 but for subscriptions.

**Files:**
- Delete: `subscriptions-jpa/src/main/java/io/casehub/platform/subscription/jpa/JpaReactiveSubscriptionStore.java`
- Modify: `subscriptions-jpa/src/main/java/io/casehub/platform/subscription/jpa/JpaSubscriptionStore.java` — complete rewrite
- Modify: `subscriptions-jpa/src/main/java/io/casehub/platform/subscription/jpa/SubscriptionEntity.java` — remove `PanacheEntityBase`
- Modify: `subscriptions-jpa/pom.xml` — swap reactive deps for standard JPA
- Modify: `subscriptions-jpa/src/test/java/io/casehub/platform/subscription/jpa/JpaSubscriptionStoreTest.java` — remove reactive tests, update `clearState()`
- Test: `subscriptions-jpa/src/test/java/io/casehub/platform/subscription/jpa/JpaSubscriptionStoreTest.java`

**Interfaces:**
- Consumes: `SubscriptionStore` (blocking SPI), `SubscriptionInput`, `Subscription`, `SubscriptionPage`, `SubscriptionQuery`, `SubscriptionUpdate`, `SubscriptionScope`, `UUIDv7`, `ObjectMapper`
- Produces: `JpaSubscriptionStore @ApplicationScoped implements SubscriptionStore` — the sole JPA subscription store

- [ ] **Step 1: Update pom.xml — swap reactive for standard JPA**

Same pattern as Task 4 Step 1. Replace `quarkus-hibernate-reactive-panache` with `quarkus-hibernate-orm`. Remove `quarkus-reactive-pg-client`. Remove test dep `quarkus-test-vertx`. Update `<description>`.

- [ ] **Step 2: Remove PanacheEntityBase from SubscriptionEntity**

Change `extends PanacheEntityBase` to plain class. Remove import.

- [ ] **Step 3: Delete JpaReactiveSubscriptionStore.java**

```
ide_refactor_safe_delete(file: "subscriptions-jpa/src/main/java/io/casehub/platform/subscription/jpa/JpaReactiveSubscriptionStore.java", target_type: "file", force: true)
```

- [ ] **Step 4: Rewrite JpaSubscriptionStore to use EntityManager + @Transactional**

Same approach as Task 4 Step 4. The store must:
- Inject `EntityManager`, `ObjectMapper`, CDI `Event<>` instances
- Use `@Transactional` on mutating methods
- Port cursor pagination, filter/target/template JSON serialization (already in entity statics)
- `findAllEnabled()` returns `Stream<Subscription>` — use `em.createQuery().getResultStream().map()`

Key method: `findAllEnabled()`:
```java
@Override
public Stream<Subscription> findAllEnabled() {
    return em.createQuery("FROM SubscriptionEntity WHERE enabled = true", SubscriptionEntity.class)
        .getResultStream()
        .map(entity -> entity.toSubscription(mapper));
}
```

- [ ] **Step 5: Update JpaSubscriptionStoreTest**

Same pattern as Task 4 Step 6:
1. Remove `@Inject ReactiveSubscriptionStore reactiveStore`
2. Delete all `reactive_*` test methods (8 methods with `@RunOnVertxContext`)
3. Rewrite `clearState()` to use EntityManager
4. Remove reactive imports

- [ ] **Step 6: Run tests**

```bash
mvn --batch-mode -pl subscriptions-jpa test
```

- [ ] **Step 7: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/worktrees/30/platform add subscriptions-jpa/
git -C /Users/mdproctor/claude/casehub/worktrees/30/platform commit -m "feat(#384): rewrite subscriptions-jpa from Hibernate Reactive to standard JPA"
```

---

### Task 6: Convert notification REST resources to blocking

**Files:**
- Modify: `notifications/src/main/java/io/casehub/platform/notification/rest/NotificationResource.java`
- Modify: `notifications/src/main/java/io/casehub/platform/notification/rest/NotificationSseResource.java`
- Modify: `notifications/src/test/java/io/casehub/platform/notification/rest/NotificationResourceTest.java`
- Test: `notifications/src/test/java/io/casehub/platform/notification/rest/NotificationResourceTest.java`

**Interfaces:**
- Consumes: `NotificationStore` (blocking SPI), `CurrentPrincipal`
- Produces: `NotificationResource` returns plain types + `@RunOnVirtualThread`. `NotificationSseResource` uses blocking store for unread counts.

- [ ] **Step 1: Rewrite NotificationResource**

Replace `ReactiveNotificationStore` → `NotificationStore`. Add `@RunOnVirtualThread` at class level. Change all return types from `Uni<T>` to `T`:

```java
@ApplicationScoped
@Path("/notifications")
@RunOnVirtualThread
public class NotificationResource {

    private final NotificationStore store;
    private final CurrentPrincipal principal;

    @Inject
    public NotificationResource(NotificationStore store, CurrentPrincipal principal) {
        this.store = store;
        this.principal = principal;
    }

    @GET
    public NotificationPage list(
            @QueryParam("status") NotificationStatus status,
            @QueryParam("category") String category,
            @QueryParam("cursor") String cursor,
            @QueryParam("limit") Integer limit) {
        return store.find(new NotificationQuery(
            principal.actorId(), principal.tenancyId(),
            status, category, cursor, limit != null ? limit : 25));
    }

    @GET @Path("/unread-count")
    public Map<String, Long> unreadCount() {
        return Map.of("count", store.unreadCount(principal.actorId(), principal.tenancyId()));
    }

    @PATCH @Path("/{id}/read")
    public Response markRead(@PathParam("id") String id) {
        return store.markRead(id, principal.actorId(), principal.tenancyId())
            .map(n -> Response.ok(n).build())
            .orElse(Response.status(404).build());
    }

    @PATCH @Path("/{id}/dismiss")
    public Response dismiss(@PathParam("id") String id) {
        return store.dismiss(id, principal.actorId(), principal.tenancyId())
            .map(n -> Response.ok(n).build())
            .orElse(Response.status(404).build());
    }

    @POST @Path("/mark-all-read")
    public Map<String, Integer> markAllRead() {
        return Map.of("count", store.markAllRead(principal.actorId(), principal.tenancyId()));
    }
}
```

Remove all `Uni` and `io.smallrye.mutiny` imports.

- [ ] **Step 2: Rewrite NotificationSseResource**

Replace `ReactiveNotificationStore` → `NotificationStore`.

**IMPORTANT: Do NOT add `@RunOnVirtualThread` to the SSE endpoint.** Per protocol `sse-endpoint-no-virtual-thread`, SSE `SseEventSink` endpoints are long-lived streaming connections. The interaction with `@RunOnVirtualThread` is undocumented and risks virtual thread monopolisation. SSE endpoints stay on the event loop; blocking calls are offloaded explicitly.

Key changes:

1. Add a `static final ExecutorService VIRTUAL_EXECUTOR = Executors.newVirtualThreadPerTaskExecutor()` field for offloading blocking calls from the event loop.

2. `stream()` method: stays on event loop. Offload the blocking `store.unreadCount()` to a virtual thread:
```java
@GET
@Produces(MediaType.SERVER_SENT_EVENTS)
public void stream(@Context SseEventSink eventSink, @Context Sse sse) {
    String userId = principal.actorId();
    String tenancyId = principal.tenancyId();
    String key = tenancyId + "::" + userId;

    var emitterWithContext = new EmitterWithContext(eventSink, sse, userId, tenancyId);
    connections.computeIfAbsent(key, k ->
        Collections.newSetFromMap(new ConcurrentHashMap<>())).add(emitterWithContext);

    // Offload blocking store call to virtual thread (SSE must not use @RunOnVirtualThread)
    VIRTUAL_EXECUTOR.execute(() -> {
        try {
            long count = store.unreadCount(userId, tenancyId);
            sendUnreadCount(eventSink, sse, count);
        } catch (Exception e) {
            LOG.errorf(e, "Failed to fetch initial unread count for user %s", userId);
        }
    });
}
```

3. `@ObservesAsync` CDI handlers: these run on managed executor threads (not event loop). Blocking store calls are safe. Replace `store.unreadCount().subscribe().with(callback, error)` with try/catch around blocking call:
```java
void onNotificationCreated(@ObservesAsync NotificationCreated event) {
    // ... existing emitter logic stays ...

    try {
        long count = store.unreadCount(notification.userId(), notification.tenancyId());
        sendUnreadCountToUser(notification.userId(), notification.tenancyId(), count);
    } catch (Exception e) {
        LOG.errorf(e, "Failed to fetch unread count for user %s", notification.userId());
    }
}
```

Apply same pattern to `onNotificationStatusChanged()` and `onAllNotificationsRead()`.

Remove all `Uni`, `io.smallrye.mutiny` imports.

- [ ] **Step 3: Update NotificationResourceTest**

Replace `@Inject ReactiveNotificationStore store` with `@Inject NotificationStore store`.
Replace all `store.xxx().await().indefinitely()` calls with direct blocking calls:
```java
// Before:
store.store(input).await().indefinitely();
// After:
store.store(input);
```

Remove `ReactiveNotificationStore` import, add `NotificationStore` import.

- [ ] **Step 4: Run tests**

```bash
mvn --batch-mode -pl notifications test
```

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/worktrees/30/platform add notifications/
git -C /Users/mdproctor/claude/casehub/worktrees/30/platform commit -m "feat(#384): convert notification REST resources from Uni to blocking + @RunOnVirtualThread"
```

---

### Task 7: Convert subscription REST resource to blocking

**Files:**
- Modify: `subscriptions/src/main/java/io/casehub/platform/subscription/rest/SubscriptionResource.java`
- Modify: `subscriptions/src/test/java/io/casehub/platform/subscription/rest/SubscriptionResourceTest.java`
- Test: `subscriptions/src/test/java/io/casehub/platform/subscription/rest/SubscriptionResourceTest.java`

**Interfaces:**
- Consumes: `SubscriptionStore` (blocking SPI), `CurrentPrincipal`, `ExpressionEngineRegistry`
- Produces: `SubscriptionResource` returns plain types + `@RunOnVirtualThread`

- [ ] **Step 1: Rewrite SubscriptionResource**

Replace `ReactiveSubscriptionStore` → `SubscriptionStore`. Add `@RunOnVirtualThread` at class level. Key conversions:

- `Uni.createFrom().item(Response.status(403).build())` → `return Response.status(403).build()`
- `.chain(opt -> { ... })` → sequential blocking code with early returns
- `store.store(input).map(s -> Response.status(201).entity(s).build())` → `return Response.status(201).entity(store.store(input)).build()`

The `update()`, `delete()`, `enable()`, `disable()` methods have a pattern of findById-then-modify. Convert from Uni chain to sequential blocking:

```java
@PATCH @Path("/{id}")
public Response update(@PathParam("id") String id, SubscriptionUpdate update) {
    var opt = store.findById(id, principal.actorId(), principal.tenancyId());
    if (opt.isEmpty()) return Response.status(404).build();
    if (isUnauthorizedSystemAccess(opt.get().scope()))
        return Response.status(403).build();
    return store.update(id, principal.actorId(), principal.tenancyId(), update)
        .map(s -> Response.ok(s).build())
        .orElse(Response.status(404).build());
}
```

Remove all `Uni`, `io.smallrye.mutiny` imports.

- [ ] **Step 2: Update SubscriptionResourceTest**

Replace `@Inject ReactiveSubscriptionStore store` with `@Inject SubscriptionStore store`.
Replace all `store.xxx().await().indefinitely()` with direct blocking calls.
Remove `ReactiveSubscriptionStore` import, add `SubscriptionStore` import.

- [ ] **Step 3: Run tests**

```bash
mvn --batch-mode -pl subscriptions test
```

- [ ] **Step 4: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/worktrees/30/platform add subscriptions/
git -C /Users/mdproctor/claude/casehub/worktrees/30/platform commit -m "feat(#384): convert subscription REST resource from Uni to blocking + @RunOnVirtualThread"
```

---

### Task 8: Full build + CLAUDE.md update

**Files:**
- Modify: `CLAUDE.md` — remove dual-stack documentation, BlockingToReactiveBridge reference

- [ ] **Step 1: Full build**

```bash
mvn --batch-mode install
```

All modules must compile and all tests must pass.

- [ ] **Step 2: Update CLAUDE.md**

Changes required:
1. Remove `BlockingToReactiveBridge` from `platform/` module description
2. Remove `ReactiveNotificationStore` and `ReactiveSubscriptionStore` from package structure
3. Update `notifications-jpa/`, `subscriptions-jpa/` descriptions — remove "Hibernate Reactive Panache", "reactive SPI" references
4. Update `notifications-inmem/`, `subscriptions-inmem/` descriptions to remove reactive mentions
5. Update `notifications/`, `subscriptions/` descriptions — "RESTEasy Reactive" stays (it's the framework), but remove "ReactiveNotificationStore" / "ReactiveSubscriptionStore" references
6. Remove `ReactiveAgentIdentityVerificationService` from `identity/` description if mentioned
7. Update package structure: remove `ReactiveNotificationStore`, `ReactiveSubscriptionStore` entries

- [ ] **Step 3: Validation checklist** (from migration guide §8)

Verify within the platform project:
- No `Reactive*` SPI interfaces in `src/main/java`
- No `Uni<` in REST endpoint return types
- No `.await().indefinitely()` calls
- No `Uni.createFrom().item()` wrapping blocking code
- No `runSubscriptionOn` calls
- No `*Bridge` classes connecting blocking↔reactive (platform-specific)
- No `quarkus-hibernate-reactive-panache` in any pom.xml
- No `quarkus-reactive-pg-client` in any pom.xml
- `@Transactional` on JPA repository write methods
- Entity classes do not extend `PanacheEntityBase`

- [ ] **Step 4: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/worktrees/30/platform add CLAUDE.md
git -C /Users/mdproctor/claude/casehub/worktrees/30/platform commit -m "docs(#384): update CLAUDE.md — remove dual-stack reactive documentation"
```
