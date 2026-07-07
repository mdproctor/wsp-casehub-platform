# Notification S/XS Batch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #157 — notification pipeline minor findings from code review
**Issue group:** #157, #163, #159, #161, #162, #156

**Goal:** Fix code review findings, add digest groupBy preference, digest status endpoint, quiet hours → digest integration, and channel subscriber target type across the notification pipeline.

**Architecture:** Foundation-up: platform-api types first, then store implementations, then pipeline components (SuppressionEvaluator → ChannelRouter → DigestFlushScheduler → NotificationDispatcher → TargetResolver), then REST endpoints. Each task is independently testable after its predecessor.

**Tech Stack:** Java 21, Quarkus, JUnit 5, AssertJ, Maven

## Global Constraints

- `platform-api/` must remain zero-dependency — no Quarkus, no JPA, no casehubio imports. Pure Java + jackson-annotations (provided) + CDI annotations (provided) + Mutiny (provided) only.
- Every `@DefaultBean` no-op implementation goes in `platform/`.
- All working in-memory implementations are `@Alternative @Priority(N)` in their own module, never `@DefaultBean`.
- TDD: write failing test → verify failure → implement → verify pass → commit.
- Use IntelliJ MCP (`ide_find_class`, `ide_find_references`, `ide_file_structure`) for all code navigation. Never bash grep/find for class lookups.
- Breaking API changes are preferred over backward-compatibility shims. No default methods on SPI interfaces.
- Build command: `mvn --batch-mode install` from project root.

## Dependency Graph

```
Task 1 (platform-api types)
  ├── Task 2 (store layer) ──► Task 3 (SuppressionEvaluator)
  │                                    │
  │                            Task 4 (TemplateResolver) [parallel]
  │                                    │
  │                            Task 5 (ChannelRouter + Dispatcher)
  │                                    │
  │                            Task 6 (DigestFlushScheduler)
  │
  ├── Task 7 (TargetResolver + EntityWatcherProvider) [parallel after Task 1]
  │
  └── Task 8 (REST + Flyway + PLATFORM.md) [after Task 2]
```

---

### Task 1: Platform-API Foundation Types

All new enums, SPI method additions, and record field changes in `platform-api/`. This is the foundation everything else builds on.

**Files:**
- Modify: `platform-api/src/main/java/io/casehub/platform/api/notification/NotificationSeverity.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/notification/settings/NotificationPreferenceUpdate.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/delivery/DigestGroupBy.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/notification/settings/QuietHoursAction.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/notification/settings/ChannelPreference.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/notification/settings/QuietHours.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/delivery/DigestSummary.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/delivery/DigestBuffer.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/subscription/TargetType.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/subscription/EntityWatcherProvider.java`

**Interfaces:**
- Consumes: nothing — this is the foundation
- Produces: `NotificationSeverity.isAtLeast(NotificationSeverity)`, `DigestGroupBy` enum, `QuietHoursAction` enum, `ChannelPreference(boolean, NotificationSeverity, DigestSchedule, DigestGroupBy)`, `QuietHours(LocalTime, LocalTime, ZoneId, QuietHoursAction)`, `DigestSummary(String, String, String, List, Instant, Instant, DigestGroupBy)`, `DigestBuffer.pendingCount(DigestBufferKey)`, `DigestBuffer.pendingKeysForUser(String, String)`, `TargetType.ENTITY_WATCHERS`, `EntityWatcherProvider.watchersOf(String, String, String)`

- [ ] **Step 1: Add `isAtLeast` to NotificationSeverity (#157-F3)**

Add Javadoc and `isAtLeast` method:

```java
public enum NotificationSeverity {
    /** Ordinal order encodes priority: INFO < WARNING < URGENT. */
    INFO,
    WARNING,
    URGENT;

    public boolean isAtLeast(NotificationSeverity threshold) {
        return this.ordinal() >= threshold.ordinal();
    }
}
```

- [ ] **Step 2: Remove redundant requireNonNull in NotificationPreferenceUpdate (#157-F1)**

In the compact constructor, remove `Objects.requireNonNull(channelDefaults, "channelDefaults");` inside the `if (channelDefaults != null)` guard. Keep `channelDefaults = Map.copyOf(channelDefaults);`.

- [ ] **Step 3: Create DigestGroupBy enum (#159)**

```java
package io.casehub.platform.api.delivery;

public enum DigestGroupBy {
    FLAT,
    CATEGORY,
    ENTITY
}
```

- [ ] **Step 4: Create QuietHoursAction enum (#162)**

```java
package io.casehub.platform.api.notification.settings;

public enum QuietHoursAction {
    SUPPRESS,
    BUFFER_FOR_DIGEST
}
```

- [ ] **Step 5: Add groupBy field to ChannelPreference (#159)**

```java
public record ChannelPreference(
        boolean enabled,
        NotificationSeverity minSeverity,
        DigestSchedule digestSchedule,
        DigestGroupBy groupBy
) {
    public ChannelPreference {
        Objects.requireNonNull(minSeverity, "minSeverity");
    }

    @JsonIgnore
    public boolean isDigested() {
        return digestSchedule != null;
    }
}
```

- [ ] **Step 6: Add action field to QuietHours (#162)**

```java
public record QuietHours(
        LocalTime start,
        LocalTime end,
        ZoneId timezone,
        QuietHoursAction action
) {
    public QuietHours {
        Objects.requireNonNull(start, "start");
        Objects.requireNonNull(end, "end");
        Objects.requireNonNull(timezone, "timezone");
    }
}
```

- [ ] **Step 7: Add groupBy field to DigestSummary (#159)**

```java
public record DigestSummary(
        String userId, String tenancyId, String channelId,
        List<NotificationInput> notifications,
        Instant periodStart, Instant periodEnd,
        DigestGroupBy groupBy
) {
    public DigestSummary {
        Objects.requireNonNull(userId, "userId");
        Objects.requireNonNull(tenancyId, "tenancyId");
        Objects.requireNonNull(channelId, "channelId");
        Objects.requireNonNull(notifications, "notifications");
        Objects.requireNonNull(periodStart, "periodStart");
        Objects.requireNonNull(periodEnd, "periodEnd");
        if (notifications.isEmpty())
            throw new IllegalArgumentException("notifications must not be empty");
        notifications = List.copyOf(notifications);
    }
}
```

`groupBy` is nullable — `null` means `FLAT`.

- [ ] **Step 8: Add pendingCount, pendingKeysForUser, and Javadoc to DigestBuffer SPI (#163-F7, #161)**

```java
package io.casehub.platform.api.delivery;

import io.casehub.platform.api.notification.NotificationInput;
import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.Set;

public interface DigestBuffer {
    /** Add a notification to the buffer. Thread-safe. */
    void add(DigestBufferKey key, NotificationInput notification);

    /**
     * Atomically drain all buffered notifications for the key.
     * Returns an immutable list; the buffer for this key is empty after the call.
     * Concurrent adds during drain must not lose items — implementations must
     * use atomic swap (e.g. ConcurrentHashMap.remove()) not clear().
     */
    List<NotificationInput> drain(DigestBufferKey key);

    /** Returns a snapshot of keys with pending items. Thread-safe. */
    Set<DigestBufferKey> pendingKeys();

    /** Timestamp of the oldest buffered item for the key, or empty if no items. */
    Optional<Instant> oldestPendingTimestamp(DigestBufferKey key);

    /** Count of pending items for the key without draining. */
    int pendingCount(DigestBufferKey key);

    /** Pending keys for a specific user. Avoids full-scan in per-user REST endpoints. */
    Set<DigestBufferKey> pendingKeysForUser(String userId, String tenancyId);
}
```

- [ ] **Step 9: Add ENTITY_WATCHERS to TargetType (#156)**

```java
public enum TargetType {
    USER,
    GROUP,
    EVENT_FIELD,
    ENTITY_WATCHERS
}
```

- [ ] **Step 10: Create EntityWatcherProvider SPI (#156)**

```java
package io.casehub.platform.api.subscription;

import java.util.Set;

/**
 * Resolves users watching a specific entity. Application-tier implementations
 * provide the actual watch/follow tracking.
 */
public interface EntityWatcherProvider {
    Set<String> watchersOf(String entityType, String entityId, String tenancyId);
}
```

- [ ] **Step 11: Fix all compilation errors in tests**

The record field additions (ChannelPreference, QuietHours, DigestSummary) will break existing test call sites. Fix all compilation errors by adding the new nullable fields (pass `null` for groupBy, `null` for action, `null` for groupBy in DigestSummary). Use `ide_find_references` on each modified record to find all call sites.

Run: `mvn --batch-mode install -pl platform-api`
Expected: BUILD SUCCESS

- [ ] **Step 12: Commit**

```
feat(platform-api): foundation types for notification S/XS batch (#157,#163,#159,#161,#162,#156)
```

---

### Task 2: Store-Layer Fixes

InMemorySuppressionStore eviction, JPA server-side filtering, InMemoryDigestBuffer thread-safety + new SPI methods, NoOpDigestBuffer.

**Files:**
- Modify: `notification-settings-inmem/src/main/java/io/casehub/platform/notification/settings/inmem/InMemorySuppressionStore.java`
- Modify: `notification-settings-inmem/src/test/java/io/casehub/platform/notification/settings/inmem/InMemorySuppressionStoreTest.java`
- Modify: `notification-settings-jpa/src/main/java/io/casehub/platform/notification/settings/jpa/JpaSuppressionStore.java`
- Modify: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/InMemoryDigestBuffer.java`
- Modify: `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/InMemoryDigestBufferTest.java`
- Modify: `platform/src/main/java/io/casehub/platform/delivery/NoOpDigestBuffer.java`

**Interfaces:**
- Consumes: `DigestBuffer.pendingCount()`, `DigestBuffer.pendingKeysForUser()` from Task 1
- Produces: Working implementations of the new SPI methods; store-authoritative expiry filtering

- [ ] **Step 1: Write failing test for InMemorySuppressionStore eviction (#157-F5)**

In `InMemorySuppressionStoreTest`, add a test that verifies expired rules are evicted from the backing store on read:

```java
@Test
void activeMutes_evictsExpiredRules() {
    store.addMute(new MuteRuleInput("user-1", "tenant-1", MuteScope.ENTITY,
        "entity-1", "work-item", Instant.now().minus(1, ChronoUnit.HOURS)));
    store.addMute(new MuteRuleInput("user-1", "tenant-1", MuteScope.ENTITY,
        "entity-2", "work-item", null));

    List<MuteRule> active = store.activeMutes("user-1", "tenant-1");
    assertThat(active).hasSize(1);
    assertThat(active.get(0).scopeId()).isEqualTo("entity-2");

    // Second read should also return 1 — expired rule was evicted, not just filtered
    List<MuteRule> secondRead = store.activeMutes("user-1", "tenant-1");
    assertThat(secondRead).hasSize(1);
}
```

Run: `mvn --batch-mode test -pl notification-settings-inmem -Dtest=InMemorySuppressionStoreTest#activeMutes_evictsExpiredRules`
Expected: FAIL (expired rule is filtered but not evicted — backing list still grows)

- [ ] **Step 2: Implement InMemorySuppressionStore eviction**

Replace `activeMutes` method body with `computeIfPresent` eviction:

```java
@Override
public List<MuteRule> activeMutes(String userId, String tenancyId) {
    String key = makeKey(userId, tenancyId);
    Instant now = Instant.now();
    List<MuteRule> active = new ArrayList<>();
    muteStore.computeIfPresent(key, (k, rules) -> {
        List<MuteRule> filtered = rules.stream()
                .filter(r -> r.expiresAt() == null || !now.isAfter(r.expiresAt()))
                .toList();
        active.addAll(filtered);
        return filtered.isEmpty() ? null : new ArrayList<>(filtered);
    });
    return active.isEmpty() ? List.of() : List.copyOf(active);
}
```

Run: `mvn --batch-mode test -pl notification-settings-inmem`
Expected: ALL PASS

- [ ] **Step 3: Fix JPA activeMutes server-side filtering (#157-F6)**

In `JpaSuppressionStore.activeMutes()`, replace the JPQL query and remove Java-side filtering:

```java
@Override
public List<MuteRule> activeMutes(String userId, String tenancyId) {
    Instant now = Instant.now();
    List<MuteRuleEntity> entities = entityManager.createQuery(
                    "SELECT m FROM MuteRuleEntity m WHERE m.userId = :userId AND m.tenancyId = :tenancyId"
                    + " AND (m.expiresAt IS NULL OR m.expiresAt > :now)",
                    MuteRuleEntity.class)
            .setParameter("userId", userId)
            .setParameter("tenancyId", tenancyId)
            .setParameter("now", now)
            .getResultList();

    return entities.stream()
            .map(MuteRuleEntity::toMuteRule)
            .toList();
}
```

Run: `mvn --batch-mode test -pl notification-settings-jpa`
Expected: ALL PASS

- [ ] **Step 4: Write failing test for InMemoryDigestBuffer.pendingCount()**

```java
@Test
void pendingCount_returnsItemCount() {
    buffer.add(KEY, sampleInput("one"));
    buffer.add(KEY, sampleInput("two"));
    assertThat(buffer.pendingCount(KEY)).isEqualTo(2);
}

@Test
void pendingCount_returnsZero_whenKeyAbsent() {
    assertThat(buffer.pendingCount(KEY)).isEqualTo(0);
}
```

Run: `mvn --batch-mode test -pl notification-dispatch -Dtest=InMemoryDigestBufferTest#pendingCount_returnsItemCount`
Expected: FAIL — method does not exist

- [ ] **Step 5: Write failing test for InMemoryDigestBuffer.pendingKeysForUser()**

```java
@Test
void pendingKeysForUser_filtersToUser() {
    var otherKey = new DigestBufferKey("other-user", TENANT, DeliveryChannels.EMAIL);
    buffer.add(KEY, sampleInput("mine"));
    buffer.add(otherKey, sampleInput("theirs"));
    
    Set<DigestBufferKey> keys = buffer.pendingKeysForUser(USER, TENANT);
    assertThat(keys).containsExactly(KEY);
}
```

Run: `mvn --batch-mode test -pl notification-dispatch -Dtest=InMemoryDigestBufferTest#pendingKeysForUser_filtersToUser`
Expected: FAIL — method does not exist

- [ ] **Step 6: Implement InMemoryDigestBuffer changes**

Switch `ArrayList` to `CopyOnWriteArrayList` for thread safety (R1-05). Implement `pendingCount` and `pendingKeysForUser`:

```java
record BufferEntry(CopyOnWriteArrayList<NotificationInput> notifications, Instant firstAdded) {}

@Override
public void add(DigestBufferKey key, NotificationInput notification) {
    buffers.compute(key, (k, entry) -> {
        if (entry == null) {
            var list = new CopyOnWriteArrayList<NotificationInput>();
            list.add(notification);
            return new BufferEntry(list, Instant.now());
        }
        entry.notifications().add(notification);
        if (entry.notifications().size() > maxBufferSize) {
            entry.notifications().remove(0);
            LOG.debugf("Buffer eviction for key %s — max size %d exceeded", key, maxBufferSize);
        }
        return entry;
    });
}

@Override
public int pendingCount(DigestBufferKey key) {
    var entry = buffers.get(key);
    return entry != null ? entry.notifications().size() : 0;
}

@Override
public Set<DigestBufferKey> pendingKeysForUser(String userId, String tenancyId) {
    return buffers.keySet().stream()
            .filter(k -> k.userId().equals(userId) && k.tenancyId().equals(tenancyId))
            .collect(java.util.stream.Collectors.toUnmodifiableSet());
}
```

Run: `mvn --batch-mode test -pl notification-dispatch -Dtest=InMemoryDigestBufferTest`
Expected: ALL PASS

- [ ] **Step 7: Update NoOpDigestBuffer**

Add the two new methods:

```java
@Override
public int pendingCount(DigestBufferKey key) {
    return 0;
}

@Override
public Set<DigestBufferKey> pendingKeysForUser(String userId, String tenancyId) {
    return Set.of();
}
```

- [ ] **Step 8: Full build check**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS

- [ ] **Step 9: Commit**

```
fix(stores): eviction, server-side filtering, digest buffer thread safety (#157,#163)
```

---

### Task 3: SuppressionEvaluator — Thread Instant now

Thread `Instant now` through `evaluate()` and `evaluateUserLevel()`. Remove mute expiry re-filtering from `checkMuted` — store is now authoritative (Task 2).

**Files:**
- Modify: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/SuppressionEvaluator.java`
- Modify: `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/SuppressionEvaluatorTest.java`

**Interfaces:**
- Consumes: Store-authoritative expiry from Task 2
- Produces: `evaluate(List<MuteRule>, Optional<Snooze>, QuietHours, String, String, String, Instant)`, `evaluateUserLevel(Optional<Snooze>, QuietHours, Instant)`

- [ ] **Step 1: Update all existing tests to pass `Instant now` parameter**

The test file already has `private static final NOW = Instant.now()`. Update every `evaluator.evaluate(...)` and `evaluator.evaluateUserLevel(...)` call to pass `NOW` as the last parameter. This will fail to compile until Step 3.

For quiet hours tests that need a specific time, construct a deterministic `Instant` from a known `LocalTime` and `ZoneId`:

```java
private static final ZoneId TZ = ZoneId.of("UTC");
// For "within quiet hours 22:00-07:00 at 23:00 UTC"
private static final Instant DURING_QH = LocalDate.of(2026, 1, 1).atTime(23, 0).atZone(TZ).toInstant();
// For "outside quiet hours at 12:00 UTC"
private static final Instant OUTSIDE_QH = LocalDate.of(2026, 1, 1).atTime(12, 0).atZone(TZ).toInstant();
```

- [ ] **Step 2: Write new test: expiry check removed from evaluator**

```java
@Test
void evaluate_expiredMuteFromStore_notRefiltered() {
    // Store returns an "expired" rule — evaluator should trust the store and treat it as active.
    // This verifies the evaluator no longer re-filters by expiry.
    var expiredRule = new MuteRule("rule-1", USER, TENANT, MuteScope.ENTITY,
            "entity-1", "work-item", NOW.minus(2, ChronoUnit.HOURS),
            NOW.minus(1, ChronoUnit.HOURS));
    var result = evaluator.evaluate(List.of(expiredRule), Optional.empty(), null,
            "work-item", "entity-1", "test-category", NOW);
    // Store is authoritative — if it returned the rule, the evaluator trusts it
    assertThat(result.isMuted()).isTrue();
}
```

Run: `mvn --batch-mode test -pl notification-dispatch -Dtest=SuppressionEvaluatorTest`
Expected: FAIL — signature mismatch (no `Instant now` parameter yet)

- [ ] **Step 3: Implement SuppressionEvaluator changes**

1. Add `Instant now` parameter to `evaluate()` and `evaluateUserLevel()`
2. Remove `Instant.now()` from `checkMuted` — remove the expiry check entirely (lines 75-79). The store (F5/F6) handles expiry.
3. Pass `now` to `checkSnoozed` — replace `Instant.now()` with the parameter
4. Pass `now` to `checkQuietHours` — replace `LocalTime.now(tz)` with `now.atZone(tz).toLocalTime()`

```java
public SuppressionResult evaluate(final List<MuteRule> activeMutes,
                                  final Optional<Snooze> activeSnooze,
                                  final QuietHours quietHours,
                                  final String entityType,
                                  final String entityId,
                                  final String category,
                                  final Instant now) {
    final boolean isMuted = checkMuted(activeMutes, entityType, entityId, category);
    final boolean isSnoozed = checkSnoozed(activeSnooze, now);
    final boolean quietHoursActive = checkQuietHours(quietHours, now);
    return new SuppressionResult(isMuted, isSnoozed, quietHoursActive);
}

public SuppressionResult evaluateUserLevel(final Optional<Snooze> activeSnooze,
                                           final QuietHours quietHours,
                                           final Instant now) {
    return new SuppressionResult(false, checkSnoozed(activeSnooze, now), checkQuietHours(quietHours, now));
}
```

`checkMuted` — remove expiry filtering (lines 75-79):
```java
private boolean checkMuted(final List<MuteRule> activeMutes,
                           final String entityType,
                           final String entityId,
                           final String category) {
    for (final MuteRule rule : activeMutes) {
        if (rule.scope() == MuteScope.ENTITY) {
            if (entityType.equals(rule.entityType()) && entityId.equals(rule.scopeId())) {
                return true;
            }
        } else if (rule.scope() == MuteScope.CATEGORY) {
            if (category.equals(rule.scopeId())) {
                if (rule.entityType() == null || rule.entityType().equals(entityType)) {
                    return true;
                }
            }
        }
    }
    return false;
}
```

`checkSnoozed` — accept `Instant now`:
```java
boolean checkSnoozed(final Optional<Snooze> activeSnooze, final Instant now) {
    return activeSnooze.filter(snooze -> now.isBefore(snooze.until())).isPresent();
}
```

`checkQuietHours` — accept `Instant now`:
```java
boolean checkQuietHours(final QuietHours quietHours, final Instant now) {
    if (quietHours == null) return false;
    final LocalTime localNow = now.atZone(quietHours.timezone()).toLocalTime();
    final LocalTime start = quietHours.start();
    final LocalTime end = quietHours.end();
    if (start.isBefore(end)) {
        return !localNow.isBefore(start) && localNow.isBefore(end);
    } else {
        return !localNow.isBefore(start) || localNow.isBefore(end);
    }
}
```

- [ ] **Step 4: Fix callers — NotificationDispatcher and DigestFlushScheduler**

In `NotificationDispatcher.dispatchToUser()`, pass `Instant.now()`:
```java
Instant now = Instant.now();
var suppressionResult = suppressionEvaluator.evaluate(
        activeMutes, activeSnooze, quietHours,
        entityType, entityId != null ? entityId : "", category, now);
```

In `DigestFlushScheduler.processKey()`, the existing `Instant now` local variable already exists — pass it:
```java
var suppression = suppressionEvaluator.evaluateUserLevel(activeSnooze, quietHours, now);
```

- [ ] **Step 5: Run all tests**

Run: `mvn --batch-mode test -pl notification-dispatch`
Expected: ALL PASS

- [ ] **Step 6: Commit**

```
fix(dispatch): thread Instant now through SuppressionEvaluator — store-authoritative expiry (#157)
```

---

### Task 4: TemplateResolver — MethodHandle Cache

Add `ConcurrentHashMap<Class<?>, ConcurrentHashMap<String, Optional<MethodHandle>>>` cache.

**Files:**
- Modify: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/TemplateResolver.java`
- Modify: `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/TemplateResolverTest.java`

**Interfaces:**
- Consumes: nothing new
- Produces: same `extractField(Object, String)` signature — internal optimization only

- [ ] **Step 1: Write test for cache behavior**

```java
@Test
void extractField_cachedAcrossCalls() {
    var event = new TestEvent("entity-1", "actor-1");
    // First call populates cache
    String first = TemplateResolver.extractField(event, "entityId");
    // Second call uses cache
    String second = TemplateResolver.extractField(event, "entityId");
    assertThat(first).isEqualTo("entity-1");
    assertThat(second).isEqualTo("entity-1");
}

@Test
void extractField_missingField_cachedAsEmpty() {
    var event = new TestEvent("entity-1", "actor-1");
    // First call — field doesn't exist
    String first = TemplateResolver.extractField(event, "nonExistent");
    // Second call — should return null without re-reflecting
    String second = TemplateResolver.extractField(event, "nonExistent");
    assertThat(first).isNull();
    assertThat(second).isNull();
}
```

Run: `mvn --batch-mode test -pl notification-dispatch -Dtest=TemplateResolverTest`
Expected: PASS (behavior is the same, just faster)

- [ ] **Step 2: Implement cache**

Replace `extractField` with cached version:

```java
private static final ConcurrentHashMap<Class<?>, ConcurrentHashMap<String, Optional<MethodHandle>>> HANDLE_CACHE =
        new ConcurrentHashMap<>();

static String extractField(final Object pojo, final String fieldName) {
    try {
        var classHandles = HANDLE_CACHE.computeIfAbsent(pojo.getClass(), k -> new ConcurrentHashMap<>());
        var handle = classHandles.computeIfAbsent(fieldName, f -> {
            try {
                var method = pojo.getClass().getMethod(f);
                return Optional.of(MethodHandles.lookup().unreflect(method));
            } catch (Exception e) {
                return Optional.empty();
            }
        });
        if (handle.isEmpty()) return null;
        final Object value = handle.get().invoke(pojo);
        return value != null ? value.toString() : null;
    } catch (Throwable e) {
        return null;
    }
}
```

Run: `mvn --batch-mode test -pl notification-dispatch -Dtest=TemplateResolverTest`
Expected: ALL PASS

- [ ] **Step 3: Commit**

```
perf(dispatch): cache MethodHandles in TemplateResolver (#157)
```

---

### Task 5: ChannelRouter + NotificationDispatcher — isAtLeast + Quiet Hours Buffering

Add `QuietHoursAction` parameter to `ChannelRouter.route()`, implement quiet hours buffering logic, wire through `NotificationDispatcher`.

**Files:**
- Modify: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/ChannelRouter.java`
- Modify: `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/ChannelRouterTest.java`
- Modify: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/NotificationDispatcher.java`
- Modify: `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/NotificationDispatcherTest.java`

**Interfaces:**
- Consumes: `NotificationSeverity.isAtLeast()`, `QuietHoursAction` enum from Task 1
- Produces: `ChannelRouter.route(Map, SuppressionResult, NotificationSeverity, QuietHoursAction)`

- [ ] **Step 1: Update existing ChannelRouterTest calls to pass `null` as quietHoursAction**

All existing `router.route(channelDefaults, suppressionResult, severity)` calls gain a 4th parameter `null` (meaning SUPPRESS — current behavior). This makes them compile once we change the signature.

- [ ] **Step 2: Write failing test for quiet hours buffering**

```java
@Test
void route_bufferForDigest_quietHoursActive_routesToDigest() {
    var suppression = new SuppressionResult(false, false, true); // quiet hours active
    var channels = router.route(Map.of(), suppression, NotificationSeverity.INFO,
            QuietHoursAction.BUFFER_FOR_DIGEST);
    
    var email = channels.stream().filter(c -> c.channelId().equals(DeliveryChannels.EMAIL)).findFirst();
    assertThat(email).isPresent();
    assertThat(email.get().digested()).isTrue();
    assertThat(email.get().suppressed()).isFalse();
}

@Test
void route_bufferForDigest_urgentDuringQuietHours_alsoBuffered() {
    var suppression = new SuppressionResult(false, false, true);
    var channels = router.route(Map.of(), suppression, NotificationSeverity.URGENT,
            QuietHoursAction.BUFFER_FOR_DIGEST);
    
    var email = channels.stream().filter(c -> c.channelId().equals(DeliveryChannels.EMAIL)).findFirst();
    assertThat(email).isPresent();
    assertThat(email.get().digested()).isTrue();
}

@Test
void route_bufferForDigest_noDigestSchedule_stillSuppressed() {
    // SMS has no digest schedule in setUp
    var suppression = new SuppressionResult(false, false, true);
    var channels = router.route(Map.of(), suppression, NotificationSeverity.INFO,
            QuietHoursAction.BUFFER_FOR_DIGEST);
    
    var sms = channels.stream().filter(c -> c.channelId().equals(DeliveryChannels.SMS)).findFirst();
    assertThat(sms).isPresent();
    assertThat(sms.get().suppressed()).isTrue();
    assertThat(sms.get().digested()).isFalse();
}
```

Run: `mvn --batch-mode test -pl notification-dispatch -Dtest=ChannelRouterTest`
Expected: FAIL — signature mismatch

- [ ] **Step 3: Implement ChannelRouter changes**

Change `route` signature to accept `QuietHoursAction`. Replace ordinal comparison with `isAtLeast`. Add quiet hours buffering logic:

```java
public Set<ResolvedChannel> route(final Map<String, ChannelPreference> channelDefaults,
                                  final SuppressionResult suppressionResult,
                                  final NotificationSeverity severity,
                                  final QuietHoursAction quietHoursAction) {
    // ... per channel (after resolving effectiveDigest):

    final boolean quietHoursBuffering = suppressionResult.quietHoursActive()
            && quietHoursAction == QuietHoursAction.BUFFER_FOR_DIGEST
            && effectiveDigest != null;

    if (suppressionResult.quietHoursActive()
            && quietHoursAction == QuietHoursAction.BUFFER_FOR_DIGEST
            && effectiveDigest == null) {
        LOG.warnf("BUFFER_FOR_DIGEST on channel %s but no digest schedule — notification suppressed",
                channelId);
    }

    final boolean suppressed = descriptor.external()
            && (suppressionResult.isSnoozed()
                || (suppressionResult.quietHoursActive() && !quietHoursBuffering));

    final boolean digested = descriptor.external()
            && effectiveDigest != null
            && (!severity.isAtLeast(NotificationSeverity.URGENT) || quietHoursBuffering);

    result.add(new ResolvedChannel(channelId, deliverer, suppressed, digested));
}
```

- [ ] **Step 4: Update NotificationDispatcher to pass QuietHoursAction**

In `dispatchToUser()`, resolve `QuietHoursAction` from preferences and pass to `channelRouter.route()`:

```java
final QuietHoursAction quietHoursAction = preferences
        .map(NotificationPreferences::quietHours)
        .map(QuietHours::action)
        .orElse(null);

final Set<ResolvedChannel> channels = channelRouter.route(
        channelDefaults, suppressionResult, notificationInput.severity(), quietHoursAction);
```

- [ ] **Step 5: Run all tests**

Run: `mvn --batch-mode test -pl notification-dispatch`
Expected: ALL PASS

- [ ] **Step 6: Commit**

```
feat(dispatch): quiet hours digest buffering + isAtLeast severity comparison (#157,#162)
```

---

### Task 6: DigestFlushScheduler — Instant now + Quiet Hours Transition + GroupBy

Thread `Instant now` through `processKey`, add quiet hours deferred key tracking, resolve `groupBy` for `DigestSummary`, fix test names, add missing tests.

**Files:**
- Modify: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/DigestFlushScheduler.java`
- Modify: `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/DigestFlushSchedulerTest.java`

**Interfaces:**
- Consumes: `SuppressionEvaluator.evaluateUserLevel(Optional, QuietHours, Instant)` from Task 3, `DigestSummary(... DigestGroupBy)` from Task 1
- Produces: `processKey(DigestBufferKey, Instant)` (package-private, testable)

- [ ] **Step 1: Rename misleading test (#163-F4)**

Rename `tick_flushesWhenIntervalElapsed` → `tick_doesNotFlush_whenIntervalNotElapsed`.

- [ ] **Step 2: Write positive flush test (#163-F5)**

Thread `Instant now` through `processKey` first (make it accept `Instant now`), then:

```java
@Test
void processKey_flushesWhenIntervalElapsed() {
    buffer.add(EMAIL_KEY, sampleInput("Notification 1"));
    preferenceStore.prefs = new NotificationPreferences(USER, TENANT,
            Map.of(DeliveryChannels.EMAIL, new ChannelPreference(true, NotificationSeverity.INFO,
                    new DigestSchedule.Interval(Duration.ofHours(4)), null)),
            null, Instant.now());
    
    // Simulate 5 hours after buffer add
    Instant futureNow = Instant.now().plus(5, ChronoUnit.HOURS);
    scheduler.processKey(EMAIL_KEY, futureNow);
    
    assertThat(emailDeliverer.received).hasSize(1);
    assertThat(emailDeliverer.received.get(0).notifications()).hasSize(1);
}
```

Expected: FAIL — `processKey` doesn't accept `Instant now` yet

- [ ] **Step 3: Write quiet hours deferral test (#163-F6)**

```java
@Test
void processKey_defersWhenQuietHoursActive() {
    buffer.add(EMAIL_KEY, sampleInput("Notification 1"));
    
    // Quiet hours 22:00-07:00 UTC, now is 23:00 UTC
    var qh = new QuietHours(LocalTime.of(22, 0), LocalTime.of(7, 0), ZoneId.of("UTC"), null);
    preferenceStore.prefs = new NotificationPreferences(USER, TENANT,
            Map.of(DeliveryChannels.EMAIL, new ChannelPreference(true, NotificationSeverity.INFO,
                    new DigestSchedule.Interval(Duration.ofMinutes(1)), null)),
            qh, Instant.now());
    
    Instant duringQH = LocalDate.of(2026, 1, 1).atTime(23, 0).atZone(ZoneId.of("UTC")).toInstant();
    scheduler.processKey(EMAIL_KEY, duringQH);
    
    assertThat(emailDeliverer.received).isEmpty();
    assertThat(buffer.pendingKeys()).contains(EMAIL_KEY);
}
```

- [ ] **Step 4: Write quiet hours transition flush test (#162)**

```java
@Test
void processKey_flushesImmediatelyAfterQuietHoursEnd() {
    buffer.add(EMAIL_KEY, sampleInput("Deferred notification"));
    
    var qh = new QuietHours(LocalTime.of(22, 0), LocalTime.of(7, 0), ZoneId.of("UTC"),
            QuietHoursAction.BUFFER_FOR_DIGEST);
    preferenceStore.prefs = new NotificationPreferences(USER, TENANT,
            Map.of(DeliveryChannels.EMAIL, new ChannelPreference(true, NotificationSeverity.INFO,
                    new DigestSchedule.Interval(Duration.ofHours(4)), null)),
            qh, Instant.now());
    
    // First tick during quiet hours — deferred
    Instant duringQH = LocalDate.of(2026, 1, 1).atTime(23, 0).atZone(ZoneId.of("UTC")).toInstant();
    scheduler.processKey(EMAIL_KEY, duringQH);
    assertThat(emailDeliverer.received).isEmpty();
    
    // Second tick after quiet hours end — flush immediately regardless of schedule
    Instant afterQH = LocalDate.of(2026, 1, 2).atTime(8, 0).atZone(ZoneId.of("UTC")).toInstant();
    scheduler.processKey(EMAIL_KEY, afterQH);
    assertThat(emailDeliverer.received).hasSize(1);
}
```

- [ ] **Step 5: Write groupBy pass-through test (#159)**

```java
@Test
void processKey_passesGroupByToDigestSummary() {
    buffer.add(EMAIL_KEY, sampleInput("Notification 1"));
    preferenceStore.prefs = new NotificationPreferences(USER, TENANT,
            Map.of(DeliveryChannels.EMAIL, new ChannelPreference(true, NotificationSeverity.INFO,
                    new DigestSchedule.Interval(Duration.ofHours(4)), DigestGroupBy.CATEGORY)),
            null, Instant.now());
    
    Instant futureNow = Instant.now().plus(5, ChronoUnit.HOURS);
    scheduler.processKey(EMAIL_KEY, futureNow);
    
    assertThat(emailDeliverer.received).hasSize(1);
    assertThat(emailDeliverer.received.get(0).groupBy()).isEqualTo(DigestGroupBy.CATEGORY);
}
```

- [ ] **Step 6: Implement DigestFlushScheduler changes**

1. Change `processKey(DigestBufferKey key)` → `processKey(DigestBufferKey key, Instant now)` (package-private)
2. `tick()` calls `processKey(key, Instant.now())`
3. Add `quietHoursDeferredKeys` field
4. Implement the new guard chain (quiet hours → schedule gate → snooze → flush)
5. Resolve `groupBy` from `ChannelPreference` and pass to `DigestSummary`

```java
private final Set<DigestBufferKey> quietHoursDeferredKeys = ConcurrentHashMap.newKeySet();

@Scheduled(every = "${casehub.notification.digest.tick-interval:1m}")
void tick() {
    Instant now = Instant.now();
    for (DigestBufferKey key : digestBuffer.pendingKeys()) {
        try {
            processKey(key, now);
        } catch (Exception e) {
            LOG.warnf(e, "Digest flush failed for key %s", key);
        }
    }
}

void processKey(DigestBufferKey key, Instant now) {
    var prefs = preferenceStore.get(key.userId(), key.tenancyId());
    DigestSchedule schedule = prefs
            .map(NotificationPreferences::channelDefaults)
            .map(cd -> cd.get(key.channelId()))
            .map(ChannelPreference::digestSchedule)
            .orElse(null);

    if (schedule == null) {
        LOG.debugf("Orphan drain for key %s — schedule removed", key);
        flushKey(key, now, null);
        return;
    }

    // 1. Quiet hours tracking
    var quietHours = prefs.map(NotificationPreferences::quietHours).orElse(null);
    if (quietHours != null) {
        var qhResult = suppressionEvaluator.evaluateUserLevel(Optional.empty(), quietHours, now);
        if (qhResult.quietHoursActive()) {
            quietHoursDeferredKeys.add(key);
            return;
        }
    }

    // 2. Schedule gate
    Instant oldest = digestBuffer.oldestPendingTimestamp(key).orElse(now);
    Instant lastFlush = lastFlushTimes.getOrDefault(key, Instant.EPOCH);
    boolean deferredFlush = quietHoursDeferredKeys.contains(key);
    if (!deferredFlush && !schedule.isFlushDue(oldest, lastFlush, now)) {
        return;
    }

    // 3. Snooze check
    var activeSnooze = suppressionStore.activeSnooze(key.userId(), key.tenancyId());
    var suppression = suppressionEvaluator.evaluateUserLevel(activeSnooze, quietHours, now);
    if (suppression.isSnoozed()) {
        return;
    }

    // 4. Flush
    quietHoursDeferredKeys.remove(key);
    DigestGroupBy groupBy = prefs
            .map(NotificationPreferences::channelDefaults)
            .map(cd -> cd.get(key.channelId()))
            .map(ChannelPreference::groupBy)
            .orElse(null);
    flushKey(key, now, groupBy);
}

private void flushKey(DigestBufferKey key, Instant now, DigestGroupBy groupBy) {
    Instant periodStart = lastFlushTimes.getOrDefault(key,
            digestBuffer.oldestPendingTimestamp(key).orElse(now));

    List<NotificationInput> items = digestBuffer.drain(key);
    if (items.isEmpty()) {
        LOG.debugf("Empty drain for key %s", key);
        return;
    }

    var summary = new DigestSummary(
            key.userId(), key.tenancyId(), key.channelId(),
            items, periodStart, now, groupBy);

    channelRegistry.resolveDeliverer(key.channelId())
            .ifPresentOrElse(
                    deliverer -> {
                        try {
                            var result = deliverer.deliverDigest(summary);
                            if (result.success()) {
                                LOG.infof("Digest flushed: user=%s, channel=%s, count=%d",
                                        key.userId(), key.channelId(), items.size());
                                lastFlushTimes.put(key, now);
                            } else {
                                LOG.warnf("Digest delivery failed: user=%s, channel=%s, reason=%s",
                                        key.userId(), key.channelId(), result.failureReason());
                            }
                        } catch (Exception e) {
                            LOG.warnf(e, "Digest delivery error: user=%s, channel=%s",
                                    key.userId(), key.channelId());
                        }
                    },
                    () -> LOG.warnf("No deliverer for channel '%s' — digest items lost", key.channelId())
            );
}
```

- [ ] **Step 7: Update test stubs for new signatures**

Update `StubPreferenceStore`, `StubSuppressionStore`, test helpers, and existing test data to use the new record constructors (ChannelPreference with 4 args, QuietHours with 4 args, DigestSummary with 7 args).

- [ ] **Step 8: Run all tests**

Run: `mvn --batch-mode test -pl notification-dispatch`
Expected: ALL PASS

- [ ] **Step 9: Commit**

```
feat(dispatch): quiet hours transition flush, groupBy pass-through, deterministic tests (#159,#162,#163)
```

---

### Task 7: TargetResolver + EntityWatcherProvider

New SPI, `@DefaultBean` no-op, TargetResolver integration with `ENTITY_WATCHERS` case.

**Files:**
- Create: `platform/src/main/java/io/casehub/platform/subscription/NoOpEntityWatcherProvider.java`
- Modify: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/TargetResolver.java`
- Modify: `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/TargetResolverTest.java`

**Interfaces:**
- Consumes: `EntityWatcherProvider` SPI, `TargetType.ENTITY_WATCHERS` from Task 1
- Produces: `NoOpEntityWatcherProvider @DefaultBean`, updated `TargetResolver` constructor

- [ ] **Step 1: Create NoOpEntityWatcherProvider**

```java
package io.casehub.platform.subscription;

import io.casehub.platform.api.subscription.EntityWatcherProvider;
import io.quarkus.arc.DefaultBean;
import jakarta.enterprise.context.ApplicationScoped;
import org.jboss.logging.Logger;

import java.util.Set;

@DefaultBean
@ApplicationScoped
public class NoOpEntityWatcherProvider implements EntityWatcherProvider {
    private static final Logger LOG = Logger.getLogger(NoOpEntityWatcherProvider.class);

    @Override
    public Set<String> watchersOf(String entityType, String entityId, String tenancyId) {
        LOG.warnf("ENTITY_WATCHERS target used but no EntityWatcherProvider is registered"
                + " — notifications to %s/%s will not be delivered", entityType, entityId);
        return Set.of();
    }
}
```

- [ ] **Step 2: Write failing tests for ENTITY_WATCHERS**

```java
@Test
void resolve_entityWatchersTarget_expandsViaProvider() {
    var targets = List.of(new NotificationTarget(TargetType.ENTITY_WATCHERS, "work-item"));
    var sub = subscription(targets, false);
    var pojo = new TestEvent("entity-1", "actor-1");
    
    Set<String> result = resolver.resolve(sub, pojo);
    assertThat(result).containsExactlyInAnyOrder("watcher-1", "watcher-2");
}

@Test
void resolve_entityWatchersTarget_blankId_usesTemplateEntityType() {
    var targets = List.of(new NotificationTarget(TargetType.ENTITY_WATCHERS, ""));
    var sub = subscription(targets, false);
    var pojo = new TestEvent("entity-1", "actor-1");
    
    Set<String> result = resolver.resolve(sub, pojo);
    // template.entityType() is "work-item" — should resolve the same watchers
    assertThat(result).containsExactlyInAnyOrder("watcher-1", "watcher-2");
}

@Test
void resolve_entityWatchersTarget_noProvider_returnsEmpty() {
    // Create resolver with NoOp provider
    var noOpResolver = new TargetResolver(groupProvider, new NoOpEntityWatcherProvider());
    var targets = List.of(new NotificationTarget(TargetType.ENTITY_WATCHERS, "work-item"));
    var sub = subscription(targets, false);
    var pojo = new TestEvent("entity-1", "actor-1");
    
    Set<String> result = noOpResolver.resolve(sub, pojo);
    assertThat(result).isEmpty();
}
```

This requires updating the test's `TargetResolver` constructor call and adding an `EntityWatcherProvider` stub.

- [ ] **Step 3: Implement TargetResolver changes**

Add `EntityWatcherProvider` injection and `ENTITY_WATCHERS` case:

```java
private final EntityWatcherProvider entityWatcherProvider;

@Inject
public TargetResolver(final GroupMembershipProvider groupMembershipProvider,
                      final EntityWatcherProvider entityWatcherProvider) {
    this.groupMembershipProvider = groupMembershipProvider;
    this.entityWatcherProvider = entityWatcherProvider;
}
```

New case in the switch:
```java
case ENTITY_WATCHERS -> {
    String entityType = target.id().isBlank() ? template.entityType() : target.id();
    String entityId = TemplateResolver.extractField(pojo, template.entityIdField());
    if (entityId != null) {
        Set<String> watchers = entityWatcherProvider.watchersOf(
                entityType, entityId, subscription.tenancyId());
        if (watchers.isEmpty()) {
            LOG.debugf("ENTITY_WATCHERS for %s/%s resolved to no watchers",
                    entityType, entityId);
        }
        recipients.addAll(watchers);
    } else {
        LOG.warnf("ENTITY_WATCHERS target: entityIdField '%s' resolved to null on %s",
                template.entityIdField(), pojo.getClass().getSimpleName());
    }
}
```

- [ ] **Step 4: Update existing TargetResolverTest**

All existing `new TargetResolver(groupProvider)` calls need updating to `new TargetResolver(groupProvider, entityWatcherProvider)` with a no-op or stub provider. Add the stub `EntityWatcherProvider` alongside the existing `GroupMembershipProvider` stub in the test.

- [ ] **Step 5: Run all tests**

Run: `mvn --batch-mode test -pl notification-dispatch`
Expected: ALL PASS

- [ ] **Step 6: Commit**

```
feat(dispatch): EntityWatcherProvider SPI + ENTITY_WATCHERS target type (#156)
```

---

### Task 8: REST Endpoints + Flyway + PLATFORM.md

Digest status endpoint, preferences `Instant.EPOCH` fix, Flyway V2 SQL fix, PLATFORM.md capability ownership update.

**Files:**
- Modify: `notifications/src/main/java/io/casehub/platform/notification/rest/NotificationPreferenceResource.java`
- Create: `notifications/src/main/java/io/casehub/platform/notification/rest/DigestStatusResource.java` (or add to existing resource — decide at implementation time)
- Modify: `notifications/src/test/java/io/casehub/platform/notification/rest/NotificationPreferenceResourceTest.java`
- Modify: `subscriptions-jpa/src/main/resources/db/subscription/migration/V2__subscription_targets.sql`
- Modify: `../parent/docs/PLATFORM.md` (casehub-parent repo)

**Interfaces:**
- Consumes: `DigestBuffer.pendingCount()`, `DigestBuffer.pendingKeysForUser()` from Task 2
- Produces: `GET /notifications/digest/status` endpoint, `GET /notifications/preferences` fix

- [ ] **Step 1: Fix Instant.EPOCH in preferences GET (#157-F8)**

In `NotificationPreferenceResource.get()`, replace `Instant.now()` with `Instant.EPOCH`:

```java
.orElseGet(() -> new NotificationPreferences(
        principal.actorId(), principal.tenancyId(),
        Map.of(), null, Instant.EPOCH));
```

- [ ] **Step 2: Write test for digest status endpoint (#161)**

```java
@Test
void digestStatus_returnsPendingCountsPerChannel() {
    // Arrange: add items to digest buffer for the test user
    // ... setup DigestBuffer mock/stub ...
    
    // Act
    given()
        .when().get("/notifications/digest/status")
        .then()
        .statusCode(200)
        .body("email", is(2))
        .body("sms", is(1));
}

@Test
void digestStatus_returnsEmptyMap_whenNoPending() {
    given()
        .when().get("/notifications/digest/status")
        .then()
        .statusCode(200)
        .body("size()", is(0));
}
```

- [ ] **Step 3: Implement digest status endpoint**

```java
@GET
@Path("/notifications/digest/status")
public Map<String, Integer> digestStatus() {
    String userId = principal.actorId();
    String tenancyId = principal.tenancyId();

    Map<String, Integer> result = new LinkedHashMap<>();
    for (DigestBufferKey key : digestBuffer.pendingKeysForUser(userId, tenancyId)) {
        int count = digestBuffer.pendingCount(key);
        if (count > 0) {
            result.put(key.channelId(), count);
        }
    }
    return result;
}
```

Inject `DigestBuffer` into the resource (or create a new `DigestStatusResource` — choose based on the existing REST resource structure).

- [ ] **Step 4: Fix Flyway V2 SQL (#157-F7)**

Replace string concatenation in `V2__subscription_targets.sql`:

```sql
UPDATE subscription SET targets_json =
    jsonb_build_array(jsonb_build_object('type', 'USER', 'id', owner_id))::text
WHERE targets_json IS NULL;
```

- [ ] **Step 5: Update PLATFORM.md capability ownership**

Add notification pipeline entry to the Capability Ownership table in `casehub-parent/docs/PLATFORM.md`:

```
| Notification pipeline (subscriptions, dispatch, digest, preferences, suppression) | `casehub-platform` | SubscriptionEngine + NotificationDispatcher + DigestFlushScheduler + ChannelRouter + TargetResolver + SuppressionEvaluator. SPIs in platform-api: NotificationStore, SubscriptionStore, NotificationPreferenceStore, SuppressionStore, DigestBuffer, DeliveryChannelRegistry, EntityWatcherProvider, EventTypeRegistry. Submodules: notifications/ (REST+SSE), subscriptions/ (engine+REST), notification-dispatch/ (pipeline), notification-settings-inmem/, notification-settings-jpa/, notifications-inmem/, notifications-jpa/, subscriptions-inmem/, subscriptions-jpa/. |
```

- [ ] **Step 6: Full build**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS

- [ ] **Step 7: Commit**

Platform changes:
```
feat(notifications): digest status endpoint, preferences fix, Flyway V2 fix (#157,#161)
```

Parent docs commit (separate repo):
```
docs: add notification pipeline to PLATFORM.md capability ownership
```
