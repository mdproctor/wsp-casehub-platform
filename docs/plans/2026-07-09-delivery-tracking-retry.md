# Delivery Tracking and Guaranteed Retry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #154 — feat: guaranteed notification delivery and delivery tracking
**Issue group:** #154

**Goal:** Add universal delivery tracking (every channel delivery recorded) and per-channel
retry with exponential backoff to the notification dispatch pipeline.

**Architecture:** New SPI types in `platform-api/`, `@DefaultBean` no-op in `platform/`,
inmem and JPA backends in new modules, retry processor and dispatcher integration in
`notification-dispatch/`. Follows the established digest-buffer module pattern exactly.

**Tech Stack:** Java 21, Quarkus 3.32.2, Hibernate ORM Panache, Flyway V3000, Jackson,
CDI async events, `@Scheduled` polling.

## Global Constraints

- `platform-api/` remains zero-dependency — pure Java only (CDI annotations acceptable per protocol)
- Flyway V3000 range for `delivery-tracking-jpa/` (`classpath:db/delivery-tracking/migration`)
- `@DefaultBean` no-op in `platform/` must not fire CDI events (protocol: `noop-registry-must-not-fire-cdi-events`)
- In-memory module: `@Alternative @Priority(100)`, size-based eviction (protocol: `store-owned-retention-mechanism`)
- JPA module: `@ApplicationScoped`, `@Scheduled` retention purge, store-owned retention
- Three-tier CDI priority: NoOp (`@DefaultBean`) < JPA (`@ApplicationScoped`) < InMem (`@Alternative @Priority(100)`)
- Jackson for payload serialization — records work natively since 2.12+
- All new types use existing `UUIDv7.generate()` for ID generation
- `quarkus-jackson` dependency only in modules that deserialize payloads (dispatch, jpa)

---

### Task 1: SPI Types in `platform-api/`

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/delivery/DeliveryType.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/delivery/DeliveryStatus.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/delivery/DeliveryAttempt.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/delivery/DeliveryAttemptStore.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/delivery/DeliveryAttemptQuery.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/delivery/DeliveryAttemptPage.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/delivery/DeliveryExhausted.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/delivery/DeliveryChannelDescriptor.java`
- Test: `platform-api/src/test/java/io/casehub/platform/api/delivery/DeliveryAttemptTest.java`
- Test: `platform-api/src/test/java/io/casehub/platform/api/delivery/DeliveryChannelDescriptorTest.java`

**Interfaces:**
- Produces: `DeliveryType`, `DeliveryStatus`, `DeliveryAttempt`, `DeliveryAttemptStore`,
  `DeliveryAttemptQuery`, `DeliveryAttemptPage`, `DeliveryExhausted` — used by all subsequent tasks
- Produces: Modified `DeliveryChannelDescriptor` with `guaranteedMinSeverity` — used by Tasks 2, 4, 5

- [ ] **Step 1: Write `DeliveryType` enum**

```java
package io.casehub.platform.api.delivery;

public enum DeliveryType {
    IMMEDIATE,
    DIGEST
}
```

- [ ] **Step 2: Write `DeliveryStatus` enum**

```java
package io.casehub.platform.api.delivery;

public enum DeliveryStatus {
    DELIVERED,
    FAILED,
    RETRYING,
    EXPIRED
}
```

- [ ] **Step 3: Write `DeliveryAttempt` record**

```java
package io.casehub.platform.api.delivery;

import java.time.Instant;
import java.util.Objects;

public record DeliveryAttempt(
        String id,
        String notificationId,
        String channelId,
        String userId,
        String tenancyId,
        DeliveryType deliveryType,
        DeliveryStatus status,
        int attemptCount,
        Instant createdAt,
        Instant lastAttemptedAt,
        Instant deliveredAt,
        Instant nextRetryAt,
        String failureReason,
        String payload
) {
    public DeliveryAttempt {
        Objects.requireNonNull(id, "id");
        Objects.requireNonNull(channelId, "channelId");
        Objects.requireNonNull(userId, "userId");
        Objects.requireNonNull(tenancyId, "tenancyId");
        Objects.requireNonNull(deliveryType, "deliveryType");
        Objects.requireNonNull(status, "status");
        Objects.requireNonNull(createdAt, "createdAt");
        Objects.requireNonNull(payload, "payload");
    }
}
```

- [ ] **Step 4: Write `DeliveryAttemptQuery` and `DeliveryAttemptPage` records**

```java
package io.casehub.platform.api.delivery;

import java.util.Objects;

public record DeliveryAttemptQuery(
        String userId,
        String tenancyId,
        String channelId,
        DeliveryStatus status,
        String cursor,
        int limit
) {
    public DeliveryAttemptQuery {
        Objects.requireNonNull(tenancyId, "tenancyId");
        if (limit <= 0) throw new IllegalArgumentException("limit must be positive");
    }
}
```

```java
package io.casehub.platform.api.delivery;

import java.util.List;

public record DeliveryAttemptPage(
        List<DeliveryAttempt> attempts,
        String nextCursor
) {
    public DeliveryAttemptPage {
        attempts = List.copyOf(attempts);
    }
}
```

- [ ] **Step 5: Write `DeliveryAttemptStore` SPI**

```java
package io.casehub.platform.api.delivery;

import java.time.Instant;
import java.util.List;

public interface DeliveryAttemptStore {
    void store(DeliveryAttempt attempt);
    void update(DeliveryAttempt attempt);
    List<DeliveryAttempt> claimRetryable(Instant now, int batchSize);
    DeliveryAttemptPage find(DeliveryAttemptQuery query);
    List<DeliveryAttempt> findByNotificationId(String notificationId);
}
```

- [ ] **Step 6: Write `DeliveryExhausted` CDI event record**

```java
package io.casehub.platform.api.delivery;

import java.util.Objects;

public record DeliveryExhausted(DeliveryAttempt attempt) {
    public DeliveryExhausted {
        Objects.requireNonNull(attempt, "attempt");
    }
}
```

- [ ] **Step 7: Modify `DeliveryChannelDescriptor` — add `guaranteedMinSeverity`**

Add `NotificationSeverity guaranteedMinSeverity` as the last constructor parameter (nullable).
Update the compact constructor validation — do NOT add `Objects.requireNonNull` for this field
since it is intentionally nullable (`null` = no retry).

- [ ] **Step 8: Write failing test for `DeliveryAttempt` validation**

```java
package io.casehub.platform.api.delivery;

import org.junit.jupiter.api.Test;
import java.time.Instant;
import static org.assertj.core.api.Assertions.*;

class DeliveryAttemptTest {

    @Test
    void rejectsNullId() {
        assertThatNullPointerException().isThrownBy(() ->
            new DeliveryAttempt(null, null, "email", "user1", "tenant1",
                DeliveryType.IMMEDIATE, DeliveryStatus.DELIVERED, 1,
                Instant.now(), Instant.now(), Instant.now(), null, null, "{}"));
    }

    @Test
    void acceptsNullableFields() {
        var attempt = new DeliveryAttempt(
                "id1", null, "email", "user1", "tenant1",
                DeliveryType.DIGEST, DeliveryStatus.RETRYING, 0,
                Instant.now(), null, null, null, null, "{}");
        assertThat(attempt.notificationId()).isNull();
        assertThat(attempt.deliveredAt()).isNull();
        assertThat(attempt.nextRetryAt()).isNull();
    }
}
```

- [ ] **Step 9: Write test for modified `DeliveryChannelDescriptor`**

```java
package io.casehub.platform.api.delivery;

import io.casehub.platform.api.notification.NotificationSeverity;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class DeliveryChannelDescriptorTest {

    @Test
    void acceptsNullGuaranteedMinSeverity() {
        var desc = new DeliveryChannelDescriptor(
                "in_app", "In-App", false, true,
                NotificationSeverity.INFO, null, null);
        assertThat(desc.guaranteedMinSeverity()).isNull();
    }

    @Test
    void carriesGuaranteedMinSeverity() {
        var desc = new DeliveryChannelDescriptor(
                "email", "Email", true, true,
                NotificationSeverity.INFO, null, NotificationSeverity.WARNING);
        assertThat(desc.guaranteedMinSeverity()).isEqualTo(NotificationSeverity.WARNING);
    }
}
```

- [ ] **Step 10: Run tests, verify pass**

Run: `mvn --batch-mode -pl platform-api test`

- [ ] **Step 11: Fix `InAppNotificationDeliverer.register()` call site**

Add `null` as the last argument to the `DeliveryChannelDescriptor` constructor call in
`InAppNotificationDeliverer.register()`. Use `ide_find_references` on `DeliveryChannelDescriptor`
constructor to find ALL call sites and update each one.

- [ ] **Step 12: Run full build to verify no compilation errors**

Run: `mvn --batch-mode -pl platform-api,platform,notification-dispatch install`

- [ ] **Step 13: Commit**

```
feat(platform#154): add delivery tracking SPI types to platform-api

DeliveryAttempt, DeliveryAttemptStore, DeliveryStatus, DeliveryType,
DeliveryExhausted. DeliveryChannelDescriptor gains guaranteedMinSeverity.
```

---

### Task 2: `NoOpDeliveryAttemptStore` in `platform/`

**Files:**
- Create: `platform/src/main/java/io/casehub/platform/delivery/NoOpDeliveryAttemptStore.java`

**Interfaces:**
- Consumes: `DeliveryAttemptStore` SPI from Task 1
- Produces: `@DefaultBean` no-op — active when no real backend on classpath

- [ ] **Step 1: Write `NoOpDeliveryAttemptStore`**

Follow `NoOpDigestBuffer` pattern exactly — `@DefaultBean @ApplicationScoped`, all methods
return empty results, `store()`/`update()` are silent no-ops. Must NOT fire CDI events
(protocol: `noop-registry-must-not-fire-cdi-events`).

```java
package io.casehub.platform.delivery;

import io.casehub.platform.api.delivery.DeliveryAttempt;
import io.casehub.platform.api.delivery.DeliveryAttemptPage;
import io.casehub.platform.api.delivery.DeliveryAttemptQuery;
import io.casehub.platform.api.delivery.DeliveryAttemptStore;
import io.quarkus.arc.DefaultBean;
import jakarta.enterprise.context.ApplicationScoped;

import java.time.Instant;
import java.util.List;

@DefaultBean
@ApplicationScoped
public class NoOpDeliveryAttemptStore implements DeliveryAttemptStore {

    @Override
    public void store(DeliveryAttempt attempt) {}

    @Override
    public void update(DeliveryAttempt attempt) {}

    @Override
    public List<DeliveryAttempt> claimRetryable(Instant now, int batchSize) {
        return List.of();
    }

    @Override
    public DeliveryAttemptPage find(DeliveryAttemptQuery query) {
        return new DeliveryAttemptPage(List.of(), null);
    }

    @Override
    public List<DeliveryAttempt> findByNotificationId(String notificationId) {
        return List.of();
    }
}
```

- [ ] **Step 2: Build platform module**

Run: `mvn --batch-mode -pl platform install`

- [ ] **Step 3: Commit**

```
feat(platform#154): add NoOpDeliveryAttemptStore @DefaultBean
```

---

### Task 3: `InMemoryDeliveryAttemptStore` module (`delivery-tracking-inmem/`)

**Files:**
- Create: `delivery-tracking-inmem/pom.xml`
- Create: `delivery-tracking-inmem/src/main/java/io/casehub/platform/delivery/tracking/inmem/InMemoryDeliveryAttemptStore.java`
- Test: `delivery-tracking-inmem/src/test/java/io/casehub/platform/delivery/tracking/inmem/InMemoryDeliveryAttemptStoreTest.java`
- Modify: `pom.xml` (parent — add `<module>delivery-tracking-inmem</module>`)

**Interfaces:**
- Consumes: `DeliveryAttemptStore` SPI, `DeliveryAttempt`, `DeliveryAttemptQuery`, `DeliveryAttemptPage`, `DeliveryStatus` from Task 1
- Produces: `@Alternative @Priority(100)` in-memory store — used by Task 5 tests

- [ ] **Step 1: Create `delivery-tracking-inmem/pom.xml`**

Follow `digest-inmem/pom.xml` pattern exactly: parent `casehub-platform-parent`,
artifact `casehub-platform-delivery-tracking-inmem`, deps on `platform-api` + `quarkus-arc`,
jandex plugin, test deps on `junit-jupiter` + `assertj-core`.

- [ ] **Step 2: Add module to parent POM**

Add `<module>delivery-tracking-inmem</module>` after `<module>digest-jpa</module>` in the
parent `pom.xml` modules list.

- [ ] **Step 3: Write failing contract tests**

Test class: `InMemoryDeliveryAttemptStoreTest`. Tests:

1. `storeAndFindByNotificationId` — store an IMMEDIATE attempt, find by notificationId,
   verify all fields round-trip
2. `claimRetryableReturnsOnlyEligible` — store one RETRYING attempt with `nextRetryAt` in
   the past and one with `nextRetryAt` in the future. `claimRetryable(now, 10)` returns only
   the past one
3. `claimRetryableAdvancesNextRetryAt` — after claiming, the record's `nextRetryAt` is
   advanced by claim-timeout (5 minutes default), preventing double-claim
4. `claimRetryableRespectsMaxBatchSize` — store 5 retryable, claim with batchSize=2, get 2
5. `findByQueryFilters` — store attempts for different users/channels/statuses, verify
   `find(query)` filters correctly
6. `updateModifiesExistingRecord` — store, then update with new status/attemptCount/nextRetryAt,
   verify the stored record reflects the update
7. `evictsWhenMaxSizeExceeded` — configure max-size=3, store 5, verify oldest 2 evicted
8. `findByNotificationIdReturnsEmptyForDigest` — store a DIGEST attempt (notificationId=null),
   `findByNotificationId("any")` returns empty
9. `claimRetryableSkipsNullNextRetryAt` — store a RETRYING attempt with `nextRetryAt=null`
   (pre-persist pattern), verify `claimRetryable` does not return it

- [ ] **Step 4: Run tests, verify they fail**

Run: `mvn --batch-mode -pl delivery-tracking-inmem test`
Expected: compilation failures (class not yet written)

- [ ] **Step 5: Implement `InMemoryDeliveryAttemptStore`**

Follow `InMemoryDigestBuffer` pattern: `@Alternative @Priority(100) @ApplicationScoped`,
`ConcurrentHashMap<String, DeliveryAttempt>` keyed by ID, `@ConfigProperty` for
`casehub.delivery.tracking.inmem.max-size` (default 10000), oldest-first eviction.

`claimRetryable(now, batchSize)`: filter entries where `status == RETRYING` and
`nextRetryAt != null` and `nextRetryAt <= now`, sort by `nextRetryAt` ascending,
take `batchSize`, advance each claimed record's `nextRetryAt` by 5 minutes (claim timeout).

`find(query)`: filter by `tenancyId` (required), optional `userId`, `channelId`, `status`.
Sort by `createdAt` DESC. Simple offset-based cursor (encode/decode offset as string).

`update(attempt)`: replace entry by ID — `ConcurrentHashMap.put(attempt.id(), attempt)`.

- [ ] **Step 6: Run tests, verify they pass**

Run: `mvn --batch-mode -pl delivery-tracking-inmem test`

- [ ] **Step 7: Commit**

```
feat(platform#154): add InMemoryDeliveryAttemptStore in delivery-tracking-inmem/

@Alternative @Priority(100), ConcurrentHashMap storage, size-based eviction.
```

---

### Task 4: `ResolvedChannel` and `ChannelRouter` modifications (`notification-dispatch/`)

**Files:**
- Modify: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/ResolvedChannel.java`
- Modify: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/ChannelRouter.java`
- Modify: `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/ChannelRouterTest.java`

**Interfaces:**
- Consumes: Modified `DeliveryChannelDescriptor` (Task 1)
- Produces: Modified `ResolvedChannel` with `guaranteedMinSeverity` — used by Task 5

- [ ] **Step 1: Write failing test for `ResolvedChannel` with `guaranteedMinSeverity`**

Add a test to `ChannelRouterTest` that verifies the `guaranteedMinSeverity` is populated
from the channel descriptor:

```java
@Test
void routePopulatesGuaranteedMinSeverity() {
    // Register a channel with guaranteedMinSeverity = WARNING
    // Route a notification
    // Assert ResolvedChannel.guaranteedMinSeverity() == WARNING
}
```

- [ ] **Step 2: Run test, verify it fails**

Run: `mvn --batch-mode -pl notification-dispatch test -Dtest=ChannelRouterTest#routePopulatesGuaranteedMinSeverity`

- [ ] **Step 3: Modify `ResolvedChannel` record**

Add `NotificationSeverity guaranteedMinSeverity` field (nullable, last position). The
compact constructor already validates `channelId` and `deliverer` — no change needed there.

- [ ] **Step 4: Fix all `ResolvedChannel` constructor call sites**

Use `ide_find_references` on `ResolvedChannel` constructor to find all instantiations.
Add `null` or `descriptor.guaranteedMinSeverity()` as appropriate. The `ChannelRouter.route()`
method passes `descriptor.guaranteedMinSeverity()`.

- [ ] **Step 5: Modify `ChannelRouter.route()` to pass `guaranteedMinSeverity`**

In the `result.add(new ResolvedChannel(...))` call, add `descriptor.guaranteedMinSeverity()`
as the last argument.

- [ ] **Step 6: Run all `ChannelRouterTest` tests**

Run: `mvn --batch-mode -pl notification-dispatch test -Dtest=ChannelRouterTest`

- [ ] **Step 7: Commit**

```
feat(platform#154): add guaranteedMinSeverity to ResolvedChannel and ChannelRouter
```

---

### Task 5: Dispatcher Integration + Retry Processor (`notification-dispatch/`)

**Files:**
- Modify: `notification-dispatch/pom.xml` (add `quarkus-jackson` + `delivery-tracking-inmem` test dep)
- Modify: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/NotificationDispatcher.java`
- Modify: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/DigestFlushScheduler.java`
- Create: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/DeliveryRetryProcessor.java`
- Create: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/DeliveryTracker.java`
- Test: `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/DeliveryTrackerTest.java`
- Test: `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/DeliveryRetryProcessorTest.java`
- Modify: `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/NotificationDispatcherTest.java`

**Interfaces:**
- Consumes: `DeliveryAttemptStore` (Task 1), `ResolvedChannel.guaranteedMinSeverity()` (Task 4),
  `InMemoryDeliveryAttemptStore` (Task 3 — test dep)
- Produces: `DeliveryTracker` (shared helper for creating/updating attempts),
  `DeliveryRetryProcessor` (`@Scheduled` retry processor)

This is the largest task. It has three sub-deliverables that build on each other:

**5A: `DeliveryTracker` — shared helper for creating `DeliveryAttempt` records**

- [ ] **Step 5A.1: Add dependencies to `notification-dispatch/pom.xml`**

Add `quarkus-jackson` as compile dep (needed for payload serialization).
Add `casehub-platform-delivery-tracking-inmem` as test dep.

- [ ] **Step 5A.2: Write failing test for `DeliveryTracker`**

`DeliveryTracker` is an `@ApplicationScoped` bean that encapsulates the logic of:
- Serializing `NotificationInput` or `DigestSummary` to JSON
- Determining retry eligibility (severity vs `guaranteedMinSeverity`)
- Creating `DeliveryAttempt` records with the correct status

```java
@QuarkusTest
class DeliveryTrackerTest {

    @Inject DeliveryTracker tracker;
    @Inject DeliveryAttemptStore store;

    @Test
    void recordsSuccessfulDelivery() {
        var input = testNotificationInput(NotificationSeverity.INFO);
        tracker.recordSuccess("email", input, "notif-1");
        var attempts = store.findByNotificationId("notif-1");
        assertThat(attempts).hasSize(1);
        assertThat(attempts.getFirst().status()).isEqualTo(DeliveryStatus.DELIVERED);
        assertThat(attempts.getFirst().deliveredAt()).isNotNull();
        assertThat(attempts.getFirst().deliveryType()).isEqualTo(DeliveryType.IMMEDIATE);
    }

    @Test
    void recordsFailureWithRetry() {
        var input = testNotificationInput(NotificationSeverity.URGENT);
        tracker.recordFailure("email", input, "notif-1",
                NotificationSeverity.WARNING, "connection refused");
        var attempts = store.findByNotificationId("notif-1");
        assertThat(attempts).hasSize(1);
        assertThat(attempts.getFirst().status()).isEqualTo(DeliveryStatus.RETRYING);
        assertThat(attempts.getFirst().nextRetryAt()).isNotNull();
        assertThat(attempts.getFirst().attemptCount()).isEqualTo(1);
    }

    @Test
    void recordsFailureWithoutRetryWhenBelowThreshold() {
        var input = testNotificationInput(NotificationSeverity.INFO);
        tracker.recordFailure("email", input, "notif-1",
                NotificationSeverity.WARNING, "connection refused");
        var attempts = store.findByNotificationId("notif-1");
        assertThat(attempts).hasSize(1);
        assertThat(attempts.getFirst().status()).isEqualTo(DeliveryStatus.FAILED);
        assertThat(attempts.getFirst().nextRetryAt()).isNull();
    }

    @Test
    void recordsFailureWithoutRetryWhenThresholdNull() {
        var input = testNotificationInput(NotificationSeverity.URGENT);
        tracker.recordFailure("email", input, "notif-1",
                null, "connection refused");
        var attempts = store.findByNotificationId("notif-1");
        assertThat(attempts).hasSize(1);
        assertThat(attempts.getFirst().status()).isEqualTo(DeliveryStatus.FAILED);
    }

    @Test
    void preRecordDigestCreatesRetryingWithNullNextRetryAt() {
        var summary = testDigestSummary(NotificationSeverity.URGENT);
        String attemptId = tracker.preRecordDigest("email", summary,
                NotificationSeverity.WARNING);
        var attempts = store.findByNotificationId(null);
        // Use find query instead
        var page = store.find(new DeliveryAttemptQuery(
                summary.userId(), summary.tenancyId(), null, null, null, 10));
        assertThat(page.attempts()).anyMatch(a ->
                a.id().equals(attemptId)
                && a.status() == DeliveryStatus.RETRYING
                && a.nextRetryAt() == null
                && a.attemptCount() == 0);
    }
}
```

- [ ] **Step 5A.3: Implement `DeliveryTracker`**

`@ApplicationScoped`, injects `DeliveryAttemptStore`, `ObjectMapper`,
and `@ConfigProperty` for `casehub.delivery.retry.base-delay` (default "30s", parsed as `Duration`).

Methods:
- `recordSuccess(channelId, NotificationInput, notificationId)` — stores DELIVERED attempt
- `recordFailure(channelId, NotificationInput, notificationId, guaranteedMinSeverity, failureReason)` — stores RETRYING or FAILED
- `preRecordDigest(channelId, DigestSummary, guaranteedMinSeverity)` → returns attemptId — stores RETRYING with `nextRetryAt=null`, `attemptCount=0`
- `confirmDigestSuccess(attemptId)` — updates to DELIVERED
- `confirmDigestFailure(attemptId, failureReason)` — sets `nextRetryAt = now + baseDelay`, `attemptCount=1`

Wrap all `store()`/`update()` calls in try/catch — log warning on failure, never block pipeline.

- [ ] **Step 5A.4: Run tests, verify pass**

Run: `mvn --batch-mode -pl notification-dispatch test -Dtest=DeliveryTrackerTest`

- [ ] **Step 5A.5: Commit**

```
feat(platform#154): add DeliveryTracker helper for delivery attempt recording
```

**5B: Dispatcher + DigestFlushScheduler integration**

- [ ] **Step 5B.1: Write failing test for `NotificationDispatcher` tracking**

Add tests to `NotificationDispatcherTest`:

```java
@Test
void deliverySuccessCreatesDeliveredAttempt() {
    // Fire a SubscriptionMatched event
    // Verify DeliveryAttemptStore has a DELIVERED record for each channel
}

@Test
void deliveryFailureCreatesRetryingAttemptWhenEligible() {
    // Register a channel with guaranteedMinSeverity = WARNING
    // Use a deliverer that returns DeliveryResult(false, "error")
    // Fire SubscriptionMatched with WARNING severity
    // Verify RETRYING attempt stored
}

@Test
void deliveryFailureCreateFailedAttemptWhenBelowThreshold() {
    // Register a channel with guaranteedMinSeverity = URGENT
    // Deliverer returns failure, notification severity = INFO
    // Verify FAILED attempt stored (not RETRYING)
}
```

- [ ] **Step 5B.2: Modify `NotificationDispatcher` to inject `DeliveryTracker`**

Add `DeliveryTracker` constructor parameter. In the delivery loop, replace the current
log-only handling with `DeliveryTracker` calls:
- On success → `tracker.recordSuccess(channel.channelId(), notificationInput, notification.id())`
- On failure → `tracker.recordFailure(channel.channelId(), notificationInput, notification.id(), channel.guaranteedMinSeverity(), result.failureReason())`
- On exception → same as failure with `e.getMessage()` as reason

Note: `notificationId` is the result of `notificationStore.store()` from `InAppNotificationDeliverer`.
For external channels where the in-app store has already returned a `Notification`, pass that ID.
If there is no in-app delivery (in-app disabled), use `null`.

The dispatcher needs to track the stored notification ID from the in-app channel delivery.
Restructure the delivery loop to deliver in-app first (capture the notificationId), then
external channels use that ID for correlation.

- [ ] **Step 5B.3: Modify `DigestFlushScheduler.flushKey()` for pre-persist tracking**

Inject `DeliveryTracker`. In `flushKey()`, after draining and building `DigestSummary`:
1. Determine max severity across `summary.notifications()`
2. Resolve `guaranteedMinSeverity` from the channel descriptor
3. Call `tracker.preRecordDigest(channelId, summary, guaranteedMinSeverity)` → get attemptId
4. Attempt `deliverer.deliverDigest(summary)`
5. On success → `tracker.confirmDigestSuccess(attemptId)`
6. On failure → `tracker.confirmDigestFailure(attemptId, reason)`

- [ ] **Step 5B.4: Run tests, verify pass**

Run: `mvn --batch-mode -pl notification-dispatch test`

- [ ] **Step 5B.5: Commit**

```
feat(platform#154): integrate delivery tracking into NotificationDispatcher and DigestFlushScheduler
```

**5C: `DeliveryRetryProcessor`**

- [ ] **Step 5C.1: Write failing tests for `DeliveryRetryProcessor`**

```java
@QuarkusTest
class DeliveryRetryProcessorTest {

    @Inject DeliveryRetryProcessor processor;
    @Inject DeliveryAttemptStore store;
    @Inject DeliveryChannelRegistry channelRegistry;

    @Test
    void retriesAndDeliversSuccessfully() {
        // Store a RETRYING attempt with nextRetryAt in the past
        // Register a mock deliverer that returns success
        // Call processor.tick()
        // Verify attempt status is now DELIVERED
    }

    @Test
    void incrementsAttemptCountOnFailure() {
        // Store a RETRYING attempt (attemptCount=1)
        // Register a mock deliverer that returns failure
        // Call processor.tick()
        // Verify attemptCount=2, status=RETRYING, nextRetryAt advanced
    }

    @Test
    void expiresWhenMaxRetriesExceeded() {
        // Store a RETRYING attempt with attemptCount = maxRetries
        // Register a mock deliverer that returns failure
        // Call processor.tick()
        // Verify status=EXPIRED
    }

    @Test
    void firesDeliveryExhaustedOnExpiry() {
        // Same setup as above
        // Verify DeliveryExhausted CDI event was fired
    }

    @Test
    void handlesExceptionSameAsFailure() {
        // Register a deliverer that throws RuntimeException
        // Verify attemptCount incremented, not infinite loop
    }

    @Test
    void handlesMissingDelivererByExpiring() {
        // Store a RETRYING attempt for an unregistered channel
        // Call processor.tick()
        // Verify status=EXPIRED with failureReason="channel not registered"
    }

    @Test
    void retriesDigestViaDeliverDigest() {
        // Store a RETRYING attempt with deliveryType=DIGEST
        // Register a mock deliverer
        // Call processor.tick()
        // Verify deliverer.deliverDigest() was called (not deliver())
    }

    @Test
    void skipsAttemptsWithFutureNextRetryAt() {
        // Store a RETRYING attempt with nextRetryAt in the future
        // Call processor.tick()
        // Verify attempt unchanged
    }
}
```

- [ ] **Step 5C.2: Implement `DeliveryRetryProcessor`**

`@ApplicationScoped`, `@Scheduled(every = "${casehub.delivery.retry.tick-interval:30s}")`.
Injects: `DeliveryAttemptStore`, `DeliveryChannelRegistry`, `ObjectMapper`,
`jakarta.enterprise.event.Event<DeliveryExhausted>`.

Config properties:
- `casehub.delivery.retry.max-retries` (int, default 5)
- `casehub.delivery.retry.base-delay` (Duration, default "30s")
- `casehub.delivery.retry.max-delay` (Duration, default "30m")
- `casehub.delivery.retry.jitter-ms` (int, default 5000)
- `casehub.delivery.retry.batch-size` (int, default 50)

`tick()`:
1. `store.claimRetryable(now, batchSize)` → batch
2. For each attempt (try/catch per attempt):
   a. Resolve deliverer from `channelRegistry.resolveDeliverer(attempt.channelId())`
   b. If absent → expire with "channel not registered"
   c. Deserialize payload based on `attempt.deliveryType()`:
      - `IMMEDIATE` → `objectMapper.readValue(attempt.payload(), NotificationInput.class)`
      - `DIGEST` → `objectMapper.readValue(attempt.payload(), DigestSummary.class)`
   d. Call `deliverer.deliver(input)` or `deliverer.deliverDigest(summary)`
   e. If success → update to `DELIVERED`
   f. If failure or exception → `advanceOrExpire(attempt, reason)`

`advanceOrExpire(attempt, failureReason)`:
1. `newCount = attempt.attemptCount() + 1`
2. If `newCount > maxRetries` → update to `EXPIRED`, fire `DeliveryExhausted`
3. Else → compute `nextRetryAt` with exponential backoff + jitter, update

`computeBackoff(attemptCount)`:
```java
long delayMs = Math.min(
    baseDelay.toMillis() * (1L << (attemptCount - 1)),
    maxDelay.toMillis());
long jitter = ThreadLocalRandom.current().nextLong(0, jitterMs + 1);
return Instant.now().plusMillis(delayMs + jitter);
```

- [ ] **Step 5C.3: Run tests, verify pass**

Run: `mvn --batch-mode -pl notification-dispatch test -Dtest=DeliveryRetryProcessorTest`

- [ ] **Step 5C.4: Run full notification-dispatch test suite**

Run: `mvn --batch-mode -pl notification-dispatch test`

- [ ] **Step 5C.5: Commit**

```
feat(platform#154): add DeliveryRetryProcessor — @Scheduled retry with exponential backoff
```

---

### Task 6: `JpaDeliveryAttemptStore` module (`delivery-tracking-jpa/`)

**Files:**
- Create: `delivery-tracking-jpa/pom.xml`
- Create: `delivery-tracking-jpa/src/main/java/io/casehub/platform/delivery/tracking/jpa/DeliveryAttemptEntity.java`
- Create: `delivery-tracking-jpa/src/main/java/io/casehub/platform/delivery/tracking/jpa/JpaDeliveryAttemptStore.java`
- Create: `delivery-tracking-jpa/src/main/resources/db/delivery-tracking/migration/V3000__delivery_attempt.sql`
- Create: `delivery-tracking-jpa/src/test/resources/application.properties`
- Test: `delivery-tracking-jpa/src/test/java/io/casehub/platform/delivery/tracking/jpa/JpaDeliveryAttemptStoreTest.java`
- Modify: `pom.xml` (parent — add `<module>delivery-tracking-jpa</module>`)

**Interfaces:**
- Consumes: `DeliveryAttemptStore` SPI, all delivery types from Task 1
- Produces: `@ApplicationScoped` JPA store with `claimRetryable` via `SELECT FOR UPDATE SKIP LOCKED`

- [ ] **Step 1: Create `delivery-tracking-jpa/pom.xml`**

Follow `digest-jpa/pom.xml` pattern: parent `casehub-platform-parent`,
artifact `casehub-platform-delivery-tracking-jpa`. Deps:
- `casehub-platform-api` (compile)
- `quarkus-hibernate-orm-panache` (compile)
- `quarkus-flyway` (compile)
- `quarkus-jdbc-postgresql` (optional)
- `quarkus-jackson` (compile)
- `casehub-platform-testing` (test)
- `quarkus-junit` (test)
- `assertj-core` (test)
- `quarkus-jdbc-h2` (test)

Jandex plugin.

- [ ] **Step 2: Add module to parent POM**

Add `<module>delivery-tracking-jpa</module>` after `<module>delivery-tracking-inmem</module>`.

- [ ] **Step 3: Write Flyway migration `V3000__delivery_attempt.sql`**

```sql
-- Delivery attempt tracking (platform#154)

CREATE TABLE IF NOT EXISTS delivery_attempt (
    id                VARCHAR(36) NOT NULL PRIMARY KEY,
    notification_id   VARCHAR(36),
    channel_id        VARCHAR(255) NOT NULL,
    user_id           VARCHAR(255) NOT NULL,
    tenancy_id        VARCHAR(255) NOT NULL,
    delivery_type     VARCHAR(20) NOT NULL,
    status            VARCHAR(20) NOT NULL,
    attempt_count     INTEGER NOT NULL DEFAULT 0,
    created_at        TIMESTAMP WITH TIME ZONE NOT NULL,
    last_attempted_at TIMESTAMP WITH TIME ZONE,
    delivered_at      TIMESTAMP WITH TIME ZONE,
    next_retry_at     TIMESTAMP WITH TIME ZONE,
    failure_reason    TEXT,
    payload           TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_delivery_attempt_retry
    ON delivery_attempt (status, next_retry_at);

CREATE INDEX IF NOT EXISTS idx_delivery_attempt_notification
    ON delivery_attempt (notification_id);

CREATE INDEX IF NOT EXISTS idx_delivery_attempt_user
    ON delivery_attempt (user_id, tenancy_id, created_at);
```

- [ ] **Step 4: Write JPA entity `DeliveryAttemptEntity`**

`@Entity @Table(name = "delivery_attempt")`. Fields map 1:1 to SQL columns.
Conversion methods: `static fromDomain(DeliveryAttempt)` and `toDomain()`.
Enums stored as `@Enumerated(EnumType.STRING)`.

- [ ] **Step 5: Write failing contract tests**

Similar to Task 3's contract tests but with `@QuarkusTest` and `@TestTransaction`:

1. `storeAndFindByNotificationId`
2. `claimRetryableUsesForUpdateSkipLocked` — store multiple RETRYING attempts, claim with
   batchSize < total, verify claimed records have `nextRetryAt` advanced
3. `claimRetryableSkipsNullNextRetryAt`
4. `findByQueryWithCursorPagination` — store 5 attempts, query with limit=2, use nextCursor
   to get page 2
5. `updateModifiesExistingRecord`
6. `retentionPurge` — manually invoke the retention purge method, verify old DELIVERED/EXPIRED
   records are removed, recent ones kept

- [ ] **Step 6: Implement `JpaDeliveryAttemptStore`**

`@ApplicationScoped`, `@Inject EntityManager`. Follow `JpaDigestBuffer` pattern.

`claimRetryable(now, batchSize)`:
```java
@Transactional
public List<DeliveryAttempt> claimRetryable(Instant now, int batchSize) {
    List<DeliveryAttemptEntity> entities = entityManager.createQuery(
        "SELECT e FROM DeliveryAttemptEntity e " +
        "WHERE e.status = :status AND e.nextRetryAt IS NOT NULL AND e.nextRetryAt <= :now " +
        "ORDER BY e.nextRetryAt ASC", DeliveryAttemptEntity.class)
        .setParameter("status", DeliveryStatus.RETRYING)
        .setParameter("now", now)
        .setMaxResults(batchSize)
        .setLockMode(LockModeType.PESSIMISTIC_WRITE)
        .setHint("jakarta.persistence.lock.timeout", -2) // SKIP LOCKED
        .getResultList();

    Instant claimExpiry = now.plus(claimTimeout);
    for (DeliveryAttemptEntity entity : entities) {
        entity.nextRetryAt = claimExpiry;
    }
    entityManager.flush();

    return entities.stream().map(DeliveryAttemptEntity::toDomain).toList();
}
```

`find(query)`: keyset pagination on `(createdAt, id)` — same cursor encoding as
`NotificationStore`. Decode cursor → `(Instant, String)`, WHERE clause:
`(created_at, id) < (:cursorTime, :cursorId)`.

Retention purge: `@Scheduled(cron = "0 0 3 * * ?")` — runs daily at 03:00.

- [ ] **Step 7: Write `application.properties` for tests**

```properties
quarkus.datasource.db-kind=h2
quarkus.datasource.jdbc.url=jdbc:h2:mem:delivery-tracking-test;MODE=PostgreSQL;DB_CLOSE_DELAY=-1
quarkus.hibernate-orm.database.generation=none
quarkus.flyway.locations=classpath:db/delivery-tracking/migration
quarkus.flyway.migrate-at-start=true
```

- [ ] **Step 8: Run tests, verify pass**

Run: `mvn --batch-mode -pl delivery-tracking-jpa test`

- [ ] **Step 9: Run full project build**

Run: `mvn --batch-mode install`

- [ ] **Step 10: Commit**

```
feat(platform#154): add JpaDeliveryAttemptStore in delivery-tracking-jpa/

Flyway V3000, SELECT FOR UPDATE SKIP LOCKED claim semantics,
@Scheduled retention purge (90d delivered/expired, 365d failed).
```

---

### Task 7: CLAUDE.md + ARC42STORIES.MD update

**Files:**
- Modify: `CLAUDE.md` (module table — add `delivery-tracking-inmem/` and `delivery-tracking-jpa/`)
- Modify: `ARC42STORIES.MD` (building block view — add delivery tracking modules)

**Interfaces:**
- Consumes: all prior tasks (documents what was built)

- [ ] **Step 1: Update CLAUDE.md module table**

Add entries for `delivery-tracking-inmem/` and `delivery-tracking-jpa/` following the
existing module table format. Also add the new SPI types to the package structure.

- [ ] **Step 2: Update ARC42STORIES.MD**

Add delivery tracking to the building block view (§5) and update the notification
layer in §4 if needed.

- [ ] **Step 3: Commit**

```
docs(platform#154): update CLAUDE.md and ARC42STORIES.MD for delivery tracking modules
```

---

## Dependency Graph

```
Task 1 (SPI types)
  ├── Task 2 (NoOp @DefaultBean)
  ├── Task 3 (InMemory store)
  ├── Task 4 (ResolvedChannel + ChannelRouter)
  │     └── Task 5 (Dispatcher + Retry Processor)
  │           └── requires Task 3 as test dep
  └── Task 6 (JPA store)
        └── Task 7 (Docs)
```

Tasks 2, 3, 4 can run in parallel after Task 1. Task 5 requires Tasks 3 and 4.
Task 6 can run in parallel with Tasks 4–5 (independent module). Task 7 runs last.
