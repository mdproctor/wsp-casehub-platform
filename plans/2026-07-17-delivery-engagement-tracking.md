# Delivery Engagement Tracking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #170 — Delivery engagement tracking — email open, push tap callbacks
**Issue group:** #170

**Goal:** Add engagement event recording (opened, clicked, dismissed, etc.) to the
delivery tracking infrastructure, with a generic callback endpoint for external
channel providers and an in-app bridge via CDI events.

**Architecture:** Engagement events are children of delivery attempts — stored in
`DeliveryAttemptStore` with summary timestamps on `DeliveryAttempt`. Three recording
paths converge on `EngagementRecorder`: SPI callback handler, direct REST, and
programmatic. In-app engagement bridges via `@ObservesAsync NotificationStatusChanged`.

**Tech Stack:** Java 21, Quarkus (CDI, RESTEasy Reactive, Scheduler), JPA/Hibernate,
Flyway, AssertJ, JUnit 5

## Global Constraints

- `platform-api/` must remain zero-dependency — no Quarkus, no JPA imports
- Pre-release platform — breaking changes are free
- Engagement tracking gated by `casehub.delivery.engagement.enabled` (default `false`)
- `recordEngagement()` is append-only; summary fields are first-write-wins (idempotent)
- `ON DELETE CASCADE` on engagement_event FK to delivery_attempt

---

### Task 1: platform-api — New Types, DeliveryAttempt Extension, and All Call Site Updates

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/delivery/EngagementType.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/delivery/EngagementEvent.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/delivery/RawEngagement.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/delivery/EngagementRecorded.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/delivery/EngagementCallbackHandler.java`
- Create: `platform-api/src/test/java/io/casehub/platform/api/delivery/EngagementEventTest.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/delivery/DeliveryAttempt.java` — add `firstOpenedAt`, `firstClickedAt`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/delivery/DeliveryAttemptStore.java` — add 3 methods
- Modify: `platform-api/src/test/java/io/casehub/platform/api/delivery/DeliveryAttemptTest.java` — update all constructors
- Modify: `platform/src/main/java/io/casehub/platform/delivery/NoOpDeliveryAttemptStore.java` — add no-op implementations
- Modify: `delivery-tracking-jpa/src/main/java/io/casehub/platform/delivery/tracking/jpa/DeliveryAttemptEntity.java` — add 2 fields, update fromDomain/toDomain
- Modify: `delivery-tracking-inmem/src/main/java/io/casehub/platform/delivery/tracking/inmem/InMemoryDeliveryAttemptStore.java:62` — claimRetryable constructor
- Modify: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/DeliveryTracker.java` — 5 constructor calls
- Modify: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/DeliveryRetryProcessor.java` — 3 constructor calls
- Modify: `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/DeliveryTrackerTest.java` — no direct constructor calls (uses tracker methods)
- Modify: `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/DeliveryRetryProcessorTest.java` — 4 constructor calls in helpers
- Modify: `delivery-tracking-inmem/src/test/java/io/casehub/platform/delivery/tracking/inmem/InMemoryDeliveryAttemptStoreTest.java` — 4 constructor calls in helpers
- Modify: `delivery-tracking-jpa/src/test/java/io/casehub/platform/delivery/tracking/jpa/JpaDeliveryAttemptStoreTest.java` — 2 constructor calls in helpers

**Interfaces:**
- Produces: `EngagementType` enum (OPENED, CLICKED, DISMISSED, REPLIED, CONVERTED)
- Produces: `EngagementEvent` record (id, attemptId, notificationId, channelId, userId, tenancyId, type, recordedAt, metadata)
- Produces: `RawEngagement` record (attemptId, type, metadata)
- Produces: `EngagementRecorded` record (event)
- Produces: `EngagementCallbackHandler` interface (channelId(), translate(String))
- Produces: `DeliveryAttemptStore.recordEngagement(EngagementEvent)`
- Produces: `DeliveryAttemptStore.findEngagementsByAttemptId(String) → List<EngagementEvent>`
- Produces: `DeliveryAttemptStore.findEngagementsByNotificationId(String) → List<EngagementEvent>`
- Produces: `DeliveryAttempt.firstOpenedAt()`, `DeliveryAttempt.firstClickedAt()`

- [ ] **Step 1: Create EngagementType enum**

```java
package io.casehub.platform.api.delivery;

public enum EngagementType {
    OPENED,
    CLICKED,
    DISMISSED,
    REPLIED,
    CONVERTED
}
```

Use `ide_create_file` for `platform-api/src/main/java/io/casehub/platform/api/delivery/EngagementType.java`.

- [ ] **Step 2: Create EngagementEvent record**

```java
package io.casehub.platform.api.delivery;

import java.time.Instant;
import java.util.Objects;

public record EngagementEvent(
        String id,
        String attemptId,
        String notificationId,
        String channelId,
        String userId,
        String tenancyId,
        EngagementType type,
        Instant recordedAt,
        String metadata
) {
    public EngagementEvent {
        Objects.requireNonNull(id, "id");
        Objects.requireNonNull(attemptId, "attemptId");
        Objects.requireNonNull(channelId, "channelId");
        Objects.requireNonNull(userId, "userId");
        Objects.requireNonNull(tenancyId, "tenancyId");
        Objects.requireNonNull(type, "type");
        Objects.requireNonNull(recordedAt, "recordedAt");
    }
}
```

Use `ide_create_file` for `platform-api/src/main/java/io/casehub/platform/api/delivery/EngagementEvent.java`.

- [ ] **Step 3: Create RawEngagement record**

```java
package io.casehub.platform.api.delivery;

import java.util.Objects;

public record RawEngagement(
        String attemptId,
        EngagementType type,
        String metadata
) {
    public RawEngagement {
        Objects.requireNonNull(attemptId, "attemptId");
        Objects.requireNonNull(type, "type");
    }
}
```

Use `ide_create_file` for `platform-api/src/main/java/io/casehub/platform/api/delivery/RawEngagement.java`.

- [ ] **Step 4: Create EngagementRecorded CDI event**

```java
package io.casehub.platform.api.delivery;

import java.util.Objects;

public record EngagementRecorded(EngagementEvent event) {
    public EngagementRecorded {
        Objects.requireNonNull(event, "event");
    }
}
```

Use `ide_create_file` for `platform-api/src/main/java/io/casehub/platform/api/delivery/EngagementRecorded.java`.

- [ ] **Step 5: Create EngagementCallbackHandler SPI**

```java
package io.casehub.platform.api.delivery;

import java.util.List;

public interface EngagementCallbackHandler {

    String channelId();

    List<RawEngagement> translate(String rawPayload);
}
```

Use `ide_create_file` for `platform-api/src/main/java/io/casehub/platform/api/delivery/EngagementCallbackHandler.java`.

- [ ] **Step 6: Write failing tests for EngagementEvent validation**

```java
package io.casehub.platform.api.delivery;

import org.junit.jupiter.api.Test;

import java.time.Instant;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatNullPointerException;

class EngagementEventTest {

    @Test
    void rejectsNullId() {
        assertThatNullPointerException().isThrownBy(() ->
                new EngagementEvent(null, "attempt-1", "notif-1", "email", "user-1", "tenant-1",
                        EngagementType.OPENED, Instant.now(), null));
    }

    @Test
    void rejectsNullAttemptId() {
        assertThatNullPointerException().isThrownBy(() ->
                new EngagementEvent("id-1", null, "notif-1", "email", "user-1", "tenant-1",
                        EngagementType.OPENED, Instant.now(), null));
    }

    @Test
    void rejectsNullType() {
        assertThatNullPointerException().isThrownBy(() ->
                new EngagementEvent("id-1", "attempt-1", "notif-1", "email", "user-1", "tenant-1",
                        null, Instant.now(), null));
    }

    @Test
    void acceptsNullableFields() {
        var event = new EngagementEvent("id-1", "attempt-1", null, "email", "user-1", "tenant-1",
                EngagementType.CLICKED, Instant.now(), null);
        assertThat(event.notificationId()).isNull();
        assertThat(event.metadata()).isNull();
    }

    @Test
    void allFieldsRoundTrip() {
        var now = Instant.now();
        var event = new EngagementEvent("id-1", "attempt-1", "notif-1", "email", "user-1", "tenant-1",
                EngagementType.OPENED, now, "{\"url\":\"https://example.com\"}");
        assertThat(event.id()).isEqualTo("id-1");
        assertThat(event.attemptId()).isEqualTo("attempt-1");
        assertThat(event.notificationId()).isEqualTo("notif-1");
        assertThat(event.channelId()).isEqualTo("email");
        assertThat(event.type()).isEqualTo(EngagementType.OPENED);
        assertThat(event.recordedAt()).isEqualTo(now);
        assertThat(event.metadata()).isEqualTo("{\"url\":\"https://example.com\"}");
    }

    @Test
    void rawEngagementRejectsNullAttemptId() {
        assertThatNullPointerException().isThrownBy(() ->
                new RawEngagement(null, EngagementType.OPENED, null));
    }

    @Test
    void rawEngagementRejectsNullType() {
        assertThatNullPointerException().isThrownBy(() ->
                new RawEngagement("attempt-1", null, null));
    }

    @Test
    void rawEngagementAcceptsNullMetadata() {
        var raw = new RawEngagement("attempt-1", EngagementType.CLICKED, null);
        assertThat(raw.metadata()).isNull();
    }

    @Test
    void engagementRecordedRejectsNullEvent() {
        assertThatNullPointerException().isThrownBy(() ->
                new EngagementRecorded(null));
    }
}
```

Use `ide_create_file` for `platform-api/src/test/java/io/casehub/platform/api/delivery/EngagementEventTest.java`.

- [ ] **Step 7: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl platform-api -Dtest=EngagementEventTest`
Expected: PASS — all record constructors already created in Steps 1-5.

- [ ] **Step 8: Add two fields to DeliveryAttempt record**

Use `ide_edit_member` on `DeliveryAttempt.java`, member `DeliveryAttempt`:

```java
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
        String payload,
        Instant firstOpenedAt,
        Instant firstClickedAt
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

- [ ] **Step 9: Add three methods to DeliveryAttemptStore**

Use `ide_insert_member` on `DeliveryAttemptStore.java`, position `last`:

```java
void recordEngagement(EngagementEvent event);

List<EngagementEvent> findEngagementsByAttemptId(String attemptId);

List<EngagementEvent> findEngagementsByNotificationId(String notificationId);
```

- [ ] **Step 10: Update NoOpDeliveryAttemptStore**

Use `ide_insert_member` on `NoOpDeliveryAttemptStore.java`, position `last`:

```java
@Override
public void recordEngagement(EngagementEvent event) {}

@Override
public List<EngagementEvent> findEngagementsByAttemptId(String attemptId) {
    return List.of();
}

@Override
public List<EngagementEvent> findEngagementsByNotificationId(String notificationId) {
    return List.of();
}
```

- [ ] **Step 11: Update DeliveryAttemptEntity — add fields and update fromDomain/toDomain**

Use `ide_insert_member` on `DeliveryAttemptEntity.java`, position `after`, anchor `payload`:

```java
@Column(name = "first_opened_at")
public Instant firstOpenedAt;

@Column(name = "first_clicked_at")
public Instant firstClickedAt;
```

Use `ide_edit_member` on `DeliveryAttemptEntity.java`, member `fromDomain`:

```java
public static DeliveryAttemptEntity fromDomain(DeliveryAttempt attempt) {
    var entity = new DeliveryAttemptEntity();
    entity.id = attempt.id();
    entity.notificationId = attempt.notificationId();
    entity.channelId = attempt.channelId();
    entity.userId = attempt.userId();
    entity.tenancyId = attempt.tenancyId();
    entity.deliveryType = attempt.deliveryType();
    entity.status = attempt.status();
    entity.attemptCount = attempt.attemptCount();
    entity.createdAt = attempt.createdAt();
    entity.lastAttemptedAt = attempt.lastAttemptedAt();
    entity.deliveredAt = attempt.deliveredAt();
    entity.nextRetryAt = attempt.nextRetryAt();
    entity.failureReason = attempt.failureReason();
    entity.payload = attempt.payload();
    entity.firstOpenedAt = attempt.firstOpenedAt();
    entity.firstClickedAt = attempt.firstClickedAt();
    return entity;
}
```

Use `ide_edit_member` on `DeliveryAttemptEntity.java`, member `toDomain`:

```java
public DeliveryAttempt toDomain() {
    return new DeliveryAttempt(
            id, notificationId, channelId, userId, tenancyId,
            deliveryType, status, attemptCount,
            createdAt, lastAttemptedAt, deliveredAt,
            nextRetryAt, failureReason, payload,
            firstOpenedAt, firstClickedAt);
}
```

- [ ] **Step 12: Update DeliveryTracker — all 5 constructor calls**

Use `ide_replace_member` on `DeliveryTracker.java`, member `recordSuccess`:

```java
var now = Instant.now();
try {
    store.store(new DeliveryAttempt(
            UUIDv7.generate(), notificationId, channelId,
            input.userId(), input.tenancyId(),
            DeliveryType.IMMEDIATE, DeliveryStatus.DELIVERED, 1,
            now, now, now, null, null,
            serialize(input), null, null));
} catch (Exception e) {
    LOG.warnf(e, "Failed to record delivery success for channel '%s', user '%s'",
            channelId, input.userId());
}
```

Use `ide_replace_member` on `DeliveryTracker.java`, member `recordFailure`:

```java
var now = Instant.now();
boolean retryEligible = guaranteedMinSeverity != null
        && input.severity().isAtLeast(guaranteedMinSeverity);
try {
    store.store(new DeliveryAttempt(
            UUIDv7.generate(), notificationId, channelId,
            input.userId(), input.tenancyId(),
            DeliveryType.IMMEDIATE,
            retryEligible ? DeliveryStatus.RETRYING : DeliveryStatus.FAILED,
            1, now, now, null,
            retryEligible ? now.plus(baseDelay) : null,
            failureReason,
            serialize(input), null, null));
} catch (Exception e) {
    LOG.warnf(e, "Failed to record delivery failure for channel '%s', user '%s'",
            channelId, input.userId());
}
```

Use `ide_replace_member` on `DeliveryTracker.java`, member `preRecordDigest`:

```java
var now = Instant.now();
NotificationSeverity maxSeverity = summary.notifications().stream()
        .map(NotificationInput::severity)
        .max(Comparator.comparingInt(Enum::ordinal))
        .orElse(NotificationSeverity.INFO);

boolean retryEligible = guaranteedMinSeverity != null
        && maxSeverity.isAtLeast(guaranteedMinSeverity);

var attempt = new DeliveryAttempt(
        UUIDv7.generate(), null, channelId,
        summary.userId(), summary.tenancyId(),
        DeliveryType.DIGEST,
        retryEligible ? DeliveryStatus.RETRYING : DeliveryStatus.FAILED,
        0, now, null, null,
        null,
        null,
        serialize(summary), null, null);
try {
    store.store(attempt);
} catch (Exception e) {
    LOG.warnf(e, "Failed to pre-record digest delivery for channel '%s', user '%s'",
            channelId, summary.userId());
}
return attempt;
```

Use `ide_replace_member` on `DeliveryTracker.java`, member `confirmDigestSuccess`:

```java
var now = Instant.now();
try {
    store.update(new DeliveryAttempt(
            preRecorded.id(), preRecorded.notificationId(), preRecorded.channelId(),
            preRecorded.userId(), preRecorded.tenancyId(), preRecorded.deliveryType(),
            DeliveryStatus.DELIVERED, preRecorded.attemptCount() + 1,
            preRecorded.createdAt(), now, now, null, null, preRecorded.payload(),
            preRecorded.firstOpenedAt(), preRecorded.firstClickedAt()));
} catch (Exception e) {
    LOG.warnf(e, "Failed to confirm digest success for attempt '%s'", preRecorded.id());
}
```

Use `ide_replace_member` on `DeliveryTracker.java`, member `confirmDigestFailure`:

```java
var now = Instant.now();
try {
    store.update(new DeliveryAttempt(
            preRecorded.id(), preRecorded.notificationId(), preRecorded.channelId(),
            preRecorded.userId(), preRecorded.tenancyId(), preRecorded.deliveryType(),
            DeliveryStatus.RETRYING, 1,
            preRecorded.createdAt(), now, null,
            now.plus(baseDelay),
            failureReason, preRecorded.payload(),
            preRecorded.firstOpenedAt(), preRecorded.firstClickedAt()));
} catch (Exception e) {
    LOG.warnf(e, "Failed to confirm digest failure for attempt '%s'", preRecorded.id());
}
```

- [ ] **Step 13: Update DeliveryRetryProcessor — 3 constructor calls**

Use `ide_replace_member` on `DeliveryRetryProcessor.java`, member `processAttempt`:

```java
try {
    var deliverer = channelRegistry.resolveDeliverer(attempt.channelId()).orElse(null);
    if (deliverer == null) {
        expire(attempt, now, "channel not registered");
        return;
    }

    DeliveryResult result;
    if (attempt.deliveryType() == DeliveryType.IMMEDIATE) {
        var input = objectMapper.readValue(attempt.payload(), NotificationInput.class);
        result = deliverer.deliver(input);
    } else {
        var summary = objectMapper.readValue(attempt.payload(), DigestSummary.class);
        result = deliverer.deliverDigest(summary);
    }

    if (result.success()) {
        store.update(new DeliveryAttempt(
                attempt.id(), attempt.notificationId(), attempt.channelId(),
                attempt.userId(), attempt.tenancyId(), attempt.deliveryType(),
                DeliveryStatus.DELIVERED, attempt.attemptCount() + 1,
                attempt.createdAt(), now, now, null, null, attempt.payload(),
                attempt.firstOpenedAt(), attempt.firstClickedAt()));
    } else {
        advanceOrExpire(attempt, now, result.failureReason());
    }
} catch (Exception e) {
    LOG.warnf(e, "Retry failed for attempt %s", attempt.id());
    advanceOrExpire(attempt, now, e.getMessage());
}
```

Use `ide_replace_member` on `DeliveryRetryProcessor.java`, member `advanceOrExpire`:

```java
int newCount = attempt.attemptCount() + 1;
if (newCount > maxRetries) {
    expire(attempt, now, failureReason);
} else {
    Instant nextRetry = computeBackoff(newCount);
    store.update(new DeliveryAttempt(
            attempt.id(), attempt.notificationId(), attempt.channelId(),
            attempt.userId(), attempt.tenancyId(), attempt.deliveryType(),
            DeliveryStatus.RETRYING, newCount,
            attempt.createdAt(), now, null,
            nextRetry, failureReason, attempt.payload(),
            attempt.firstOpenedAt(), attempt.firstClickedAt()));
}
```

Use `ide_replace_member` on `DeliveryRetryProcessor.java`, member `expire`:

```java
var expired = new DeliveryAttempt(
        attempt.id(), attempt.notificationId(), attempt.channelId(),
        attempt.userId(), attempt.tenancyId(), attempt.deliveryType(),
        DeliveryStatus.EXPIRED, attempt.attemptCount() + 1,
        attempt.createdAt(), now, null, null,
        failureReason, attempt.payload(),
        attempt.firstOpenedAt(), attempt.firstClickedAt());
store.update(expired);
exhaustedEvent.fireAsync(new DeliveryExhausted(expired));
```

- [ ] **Step 14: Update InMemoryDeliveryAttemptStore.claimRetryable constructor**

Use `ide_replace_member` on `InMemoryDeliveryAttemptStore.java`, member `claimRetryable`:

```java
List<DeliveryAttempt> eligible = store.values().stream()
        .filter(a -> a.status() == DeliveryStatus.RETRYING)
        .filter(a -> a.nextRetryAt() != null)
        .filter(a -> !a.nextRetryAt().isAfter(now))
        .sorted(Comparator.comparing(DeliveryAttempt::nextRetryAt))
        .limit(batchSize)
        .toList();

Instant claimExpiry = now.plus(CLAIM_TIMEOUT);
List<DeliveryAttempt> claimed = new ArrayList<>(eligible.size());
for (DeliveryAttempt a : eligible) {
    var advanced = new DeliveryAttempt(
            a.id(), a.notificationId(), a.channelId(), a.userId(), a.tenancyId(),
            a.deliveryType(), a.status(), a.attemptCount(),
            a.createdAt(), a.lastAttemptedAt(), a.deliveredAt(),
            claimExpiry, a.failureReason(), a.payload(),
            a.firstOpenedAt(), a.firstClickedAt());
    store.put(a.id(), advanced);
    claimed.add(a);
}
return claimed;
```

- [ ] **Step 15: Update DeliveryAttemptTest — all constructor calls**

Update all `new DeliveryAttempt(...)` calls to append `, null, null` for the two new fields. Use `ide_edit_member` for each test method.

- [ ] **Step 16: Update InMemoryDeliveryAttemptStoreTest — helper methods**

Update the three `attempt()` helper overloads and the `updateModifiesExistingRecord` test to append `, null, null` to every `new DeliveryAttempt(...)`.

- [ ] **Step 17: Update JpaDeliveryAttemptStoreTest — helper methods**

Update the two `attempt()` helper overloads and the `updateModifiesExistingRecord` test to append `, null, null` to every `new DeliveryAttempt(...)`.

- [ ] **Step 18: Update DeliveryRetryProcessorTest — helper methods**

Update `retryableAttempt()`, `retryableDigestAttempt()`, and `skipsAttemptsWithFutureNextRetryAt` to append `, null, null` to every `new DeliveryAttempt(...)`.

- [ ] **Step 19: Build and test**

Run: `mvn --batch-mode install -DskipTests`
Expected: BUILD SUCCESS — all call sites updated, compilation clean.

Run: `mvn --batch-mode test`
Expected: All tests pass.

- [ ] **Step 20: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add -A
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#170): engagement types, DeliveryAttempt extension, and call site updates"
```

---

### Task 2: InMemory Engagement Implementation

**Files:**
- Modify: `delivery-tracking-inmem/src/main/java/io/casehub/platform/delivery/tracking/inmem/InMemoryDeliveryAttemptStore.java`
- Modify: `delivery-tracking-inmem/src/test/java/io/casehub/platform/delivery/tracking/inmem/InMemoryDeliveryAttemptStoreTest.java`

**Interfaces:**
- Consumes: `EngagementEvent` record, `EngagementType` enum, `DeliveryAttemptStore.recordEngagement/findEngagementsByAttemptId/findEngagementsByNotificationId`
- Produces: Working in-memory engagement storage with eviction cascade (used by Task 4 tests and Task 5)

- [ ] **Step 1: Write failing tests for engagement recording**

Add to `InMemoryDeliveryAttemptStoreTest`:

```java
@Test
void recordEngagementStoresEvent() {
    var attempt = attempt("notif-1", DeliveryStatus.DELIVERED);
    store.store(attempt);
    var event = new EngagementEvent(
            "eng-1", attempt.id(), "notif-1", "email", "user-1", "tenant-1",
            EngagementType.OPENED, Instant.now(), null);
    store.recordEngagement(event);
    var events = store.findEngagementsByAttemptId(attempt.id());
    assertThat(events).hasSize(1);
    assertThat(events.getFirst().type()).isEqualTo(EngagementType.OPENED);
}

@Test
void recordEngagementSetsFirstOpenedAt() {
    var attempt = attempt("notif-1", DeliveryStatus.DELIVERED);
    store.store(attempt);
    var now = Instant.now();
    store.recordEngagement(new EngagementEvent(
            "eng-1", attempt.id(), "notif-1", "email", "user-1", "tenant-1",
            EngagementType.OPENED, now, null));
    var updated = store.findByNotificationId("notif-1").getFirst();
    assertThat(updated.firstOpenedAt()).isEqualTo(now);
    assertThat(updated.firstClickedAt()).isNull();
}

@Test
void recordEngagementFirstWriteWinsForSummary() {
    var attempt = attempt("notif-1", DeliveryStatus.DELIVERED);
    store.store(attempt);
    var first = Instant.now().minusSeconds(60);
    var second = Instant.now();
    store.recordEngagement(new EngagementEvent(
            "eng-1", attempt.id(), "notif-1", "email", "user-1", "tenant-1",
            EngagementType.OPENED, first, null));
    store.recordEngagement(new EngagementEvent(
            "eng-2", attempt.id(), "notif-1", "email", "user-1", "tenant-1",
            EngagementType.OPENED, second, null));
    var updated = store.findByNotificationId("notif-1").getFirst();
    assertThat(updated.firstOpenedAt()).isEqualTo(first);
}

@Test
void findEngagementsByNotificationId() {
    var a1 = attempt("notif-1", DeliveryStatus.DELIVERED);
    var a2 = attempt("notif-1", "user-2", "tenant-1",
            DeliveryStatus.DELIVERED, null);
    store.store(a1);
    store.store(a2);
    store.recordEngagement(new EngagementEvent(
            "eng-1", a1.id(), "notif-1", "email", "user-1", "tenant-1",
            EngagementType.OPENED, Instant.now(), null));
    store.recordEngagement(new EngagementEvent(
            "eng-2", a2.id(), "notif-1", "email", "user-2", "tenant-1",
            EngagementType.CLICKED, Instant.now(), null));
    var events = store.findEngagementsByNotificationId("notif-1");
    assertThat(events).hasSize(2);
}

@Test
void evictionCascadesToEngagementEvents() {
    var smallStore = new InMemoryDeliveryAttemptStore(1);
    var a1 = attempt("notif-1", DeliveryStatus.DELIVERED);
    smallStore.store(a1);
    smallStore.recordEngagement(new EngagementEvent(
            "eng-1", a1.id(), "notif-1", "email", "user-1", "tenant-1",
            EngagementType.OPENED, Instant.now(), null));
    var a2 = attempt("notif-2", DeliveryStatus.DELIVERED);
    smallStore.store(a2);
    assertThat(smallStore.findEngagementsByAttemptId(a1.id())).isEmpty();
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl delivery-tracking-inmem -Dtest=InMemoryDeliveryAttemptStoreTest`
Expected: FAIL — methods not yet implemented.

- [ ] **Step 3: Implement engagement methods in InMemoryDeliveryAttemptStore**

Add a second map field using `ide_insert_member`, anchor `store`, position `after`:

```java
private final ConcurrentHashMap<String, List<EngagementEvent>> engagementStore = new ConcurrentHashMap<>();
```

Add the three methods using `ide_insert_member`, position `last`:

```java
@Override
public void recordEngagement(EngagementEvent event) {
    engagementStore.computeIfAbsent(event.attemptId(), k -> new ArrayList<>()).add(event);
    store.computeIfPresent(event.attemptId(), (id, attempt) -> {
        Instant firstOpened = attempt.firstOpenedAt();
        Instant firstClicked = attempt.firstClickedAt();
        if (event.type() == EngagementType.OPENED && firstOpened == null) {
            firstOpened = event.recordedAt();
        }
        if (event.type() == EngagementType.CLICKED && firstClicked == null) {
            firstClicked = event.recordedAt();
        }
        if (firstOpened == attempt.firstOpenedAt() && firstClicked == attempt.firstClickedAt()) {
            return attempt;
        }
        return new DeliveryAttempt(
                attempt.id(), attempt.notificationId(), attempt.channelId(),
                attempt.userId(), attempt.tenancyId(), attempt.deliveryType(),
                attempt.status(), attempt.attemptCount(),
                attempt.createdAt(), attempt.lastAttemptedAt(), attempt.deliveredAt(),
                attempt.nextRetryAt(), attempt.failureReason(), attempt.payload(),
                firstOpened, firstClicked);
    });
}

@Override
public List<EngagementEvent> findEngagementsByAttemptId(String attemptId) {
    return List.copyOf(engagementStore.getOrDefault(attemptId, List.of()));
}

@Override
public List<EngagementEvent> findEngagementsByNotificationId(String notificationId) {
    return engagementStore.values().stream()
            .flatMap(List::stream)
            .filter(e -> notificationId.equals(e.notificationId()))
            .sorted(Comparator.comparing(EngagementEvent::recordedAt))
            .toList();
}
```

Update `evictIfNeeded` to cascade using `ide_replace_member`:

```java
if (maxSize <= 0 || store.size() <= maxSize) {
    return;
}
store.values().stream()
        .sorted(Comparator.comparing(DeliveryAttempt::createdAt))
        .limit(store.size() - maxSize)
        .forEach(a -> {
            store.remove(a.id());
            engagementStore.remove(a.id());
            LOG.debugf("Evicted delivery attempt %s — max size %d exceeded", a.id(), maxSize);
        });
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl delivery-tracking-inmem`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add delivery-tracking-inmem/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#170): InMemory engagement recording with eviction cascade"
```

---

### Task 3: JPA Engagement Implementation

**Files:**
- Create: `delivery-tracking-jpa/src/main/resources/db/delivery-tracking/migration/V3001__engagement_event.sql`
- Create: `delivery-tracking-jpa/src/main/java/io/casehub/platform/delivery/tracking/jpa/EngagementEventEntity.java`
- Modify: `delivery-tracking-jpa/src/main/java/io/casehub/platform/delivery/tracking/jpa/JpaDeliveryAttemptStore.java`
- Modify: `delivery-tracking-jpa/src/test/java/io/casehub/platform/delivery/tracking/jpa/JpaDeliveryAttemptStoreTest.java`

**Interfaces:**
- Consumes: `EngagementEvent`, `EngagementType`, `DeliveryAttemptStore` SPI from Task 1
- Produces: JPA-backed engagement persistence with FK cascade and conditional summary updates

- [ ] **Step 1: Create V3001 migration**

```sql
-- Engagement tracking (platform#170)

ALTER TABLE delivery_attempt ADD COLUMN first_opened_at TIMESTAMP WITH TIME ZONE;
ALTER TABLE delivery_attempt ADD COLUMN first_clicked_at TIMESTAMP WITH TIME ZONE;

CREATE TABLE engagement_event (
    id              VARCHAR(36) NOT NULL PRIMARY KEY,
    attempt_id      VARCHAR(36) NOT NULL REFERENCES delivery_attempt(id) ON DELETE CASCADE,
    notification_id VARCHAR(36),
    channel_id      VARCHAR(255) NOT NULL,
    user_id         VARCHAR(255) NOT NULL,
    tenancy_id      VARCHAR(255) NOT NULL,
    type            VARCHAR(20) NOT NULL,
    recorded_at     TIMESTAMP WITH TIME ZONE NOT NULL,
    metadata        TEXT
);

CREATE INDEX idx_engagement_event_attempt ON engagement_event (attempt_id);
CREATE INDEX idx_engagement_event_notification ON engagement_event (notification_id);
CREATE INDEX idx_engagement_event_user ON engagement_event (user_id, tenancy_id, type, recorded_at);
```

Write to `delivery-tracking-jpa/src/main/resources/db/delivery-tracking/migration/V3001__engagement_event.sql`.

- [ ] **Step 2: Create EngagementEventEntity**

```java
package io.casehub.platform.delivery.tracking.jpa;

import io.casehub.platform.api.delivery.EngagementEvent;
import io.casehub.platform.api.delivery.EngagementType;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

import java.time.Instant;

@Entity
@Table(name = "engagement_event")
public class EngagementEventEntity {

    @Id
    @Column(name = "id", length = 36)
    public String id;

    @Column(name = "attempt_id", nullable = false, length = 36)
    public String attemptId;

    @Column(name = "notification_id", length = 36)
    public String notificationId;

    @Column(name = "channel_id", nullable = false)
    public String channelId;

    @Column(name = "user_id", nullable = false)
    public String userId;

    @Column(name = "tenancy_id", nullable = false)
    public String tenancyId;

    @Enumerated(EnumType.STRING)
    @Column(name = "type", nullable = false, length = 20)
    public EngagementType type;

    @Column(name = "recorded_at", nullable = false)
    public Instant recordedAt;

    @Column(name = "metadata", columnDefinition = "TEXT")
    public String metadata;

    public static EngagementEventEntity fromDomain(EngagementEvent event) {
        var entity = new EngagementEventEntity();
        entity.id = event.id();
        entity.attemptId = event.attemptId();
        entity.notificationId = event.notificationId();
        entity.channelId = event.channelId();
        entity.userId = event.userId();
        entity.tenancyId = event.tenancyId();
        entity.type = event.type();
        entity.recordedAt = event.recordedAt();
        entity.metadata = event.metadata();
        return entity;
    }

    public EngagementEvent toDomain() {
        return new EngagementEvent(
                id, attemptId, notificationId, channelId,
                userId, tenancyId, type, recordedAt, metadata);
    }
}
```

Use `ide_create_file` for `delivery-tracking-jpa/src/main/java/io/casehub/platform/delivery/tracking/jpa/EngagementEventEntity.java`.

- [ ] **Step 3: Write failing tests for JPA engagement**

Add to `JpaDeliveryAttemptStoreTest`:

```java
@Test
@TestTransaction
void recordEngagementStoresAndUpdatesSummary() {
    var attempt = attempt("notif-1", DeliveryStatus.DELIVERED);
    store.store(attempt);
    var now = Instant.now();
    var event = new EngagementEvent(
            UUIDv7.generate(), attempt.id(), "notif-1", "email", "user-1", "tenant-1",
            EngagementType.OPENED, now, "{\"source\":\"pixel\"}");
    store.recordEngagement(event);
    var found = store.findEngagementsByAttemptId(attempt.id());
    assertThat(found).hasSize(1);
    assertThat(found.getFirst().type()).isEqualTo(EngagementType.OPENED);
    var updated = store.findByNotificationId("notif-1").getFirst();
    assertThat(updated.firstOpenedAt()).isEqualTo(now);
}

@Test
@TestTransaction
void recordEngagementFirstWriteWins() {
    var attempt = attempt("notif-1", DeliveryStatus.DELIVERED);
    store.store(attempt);
    var first = Instant.now().minusSeconds(60);
    var second = Instant.now();
    store.recordEngagement(new EngagementEvent(
            UUIDv7.generate(), attempt.id(), "notif-1", "email", "user-1", "tenant-1",
            EngagementType.OPENED, first, null));
    store.recordEngagement(new EngagementEvent(
            UUIDv7.generate(), attempt.id(), "notif-1", "email", "user-1", "tenant-1",
            EngagementType.OPENED, second, null));
    var updated = store.findByNotificationId("notif-1").getFirst();
    assertThat(updated.firstOpenedAt()).isEqualTo(first);
}

@Test
@TestTransaction
void findEngagementsByNotificationIdAcrossAttempts() {
    var a1 = attempt("notif-1", DeliveryStatus.DELIVERED);
    var a2 = attempt("notif-1", "user-2", "tenant-1",
            DeliveryStatus.DELIVERED, null);
    store.store(a1);
    store.store(a2);
    store.recordEngagement(new EngagementEvent(
            UUIDv7.generate(), a1.id(), "notif-1", "email", "user-1", "tenant-1",
            EngagementType.OPENED, Instant.now(), null));
    store.recordEngagement(new EngagementEvent(
            UUIDv7.generate(), a2.id(), "notif-1", "email", "user-2", "tenant-1",
            EngagementType.CLICKED, Instant.now(), null));
    assertThat(store.findEngagementsByNotificationId("notif-1")).hasSize(2);
}
```

- [ ] **Step 4: Implement JPA engagement methods**

Add to `JpaDeliveryAttemptStore` using `ide_insert_member`, position `last`:

```java
@Override
@Transactional
public void recordEngagement(EngagementEvent event) {
    getEntityManager().persist(EngagementEventEntity.fromDomain(event));
    if (event.type() == EngagementType.OPENED) {
        getEntityManager().createQuery(
                "UPDATE DeliveryAttemptEntity e SET e.firstOpenedAt = :ts " +
                "WHERE e.id = :id AND e.firstOpenedAt IS NULL")
                .setParameter("ts", event.recordedAt())
                .setParameter("id", event.attemptId())
                .executeUpdate();
    }
    if (event.type() == EngagementType.CLICKED) {
        getEntityManager().createQuery(
                "UPDATE DeliveryAttemptEntity e SET e.firstClickedAt = :ts " +
                "WHERE e.id = :id AND e.firstClickedAt IS NULL")
                .setParameter("ts", event.recordedAt())
                .setParameter("id", event.attemptId())
                .executeUpdate();
    }
}

@Override
public List<EngagementEvent> findEngagementsByAttemptId(String attemptId) {
    return getEntityManager()
            .createQuery("FROM EngagementEventEntity e WHERE e.attemptId = :attemptId ORDER BY e.recordedAt",
                    EngagementEventEntity.class)
            .setParameter("attemptId", attemptId)
            .getResultList()
            .stream()
            .map(EngagementEventEntity::toDomain)
            .toList();
}

@Override
public List<EngagementEvent> findEngagementsByNotificationId(String notificationId) {
    return getEntityManager()
            .createQuery("FROM EngagementEventEntity e WHERE e.notificationId = :notificationId ORDER BY e.recordedAt",
                    EngagementEventEntity.class)
            .setParameter("notificationId", notificationId)
            .getResultList()
            .stream()
            .map(EngagementEventEntity::toDomain)
            .toList();
}
```

- [ ] **Step 5: Run tests**

Run: `mvn --batch-mode test -pl delivery-tracking-jpa`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add delivery-tracking-jpa/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#170): JPA engagement persistence with V3001 migration"
```

---

### Task 4: EngagementRecorder

**Files:**
- Create: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/EngagementRecorder.java`
- Create: `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/EngagementRecorderTest.java`

**Interfaces:**
- Consumes: `DeliveryAttempt`, `DeliveryAttemptStore.recordEngagement()`, `EngagementEvent`, `EngagementType`, `EngagementRecorded`, `UUIDv7`
- Produces: `EngagementRecorder.record(DeliveryAttempt attempt, EngagementType type, String metadata)` — used by Tasks 5 and 6

- [ ] **Step 1: Write failing tests**

```java
package io.casehub.platform.notification.dispatch;

import io.casehub.platform.api.delivery.DeliveryAttempt;
import io.casehub.platform.api.delivery.DeliveryStatus;
import io.casehub.platform.api.delivery.DeliveryType;
import io.casehub.platform.api.delivery.EngagementEvent;
import io.casehub.platform.api.delivery.EngagementRecorded;
import io.casehub.platform.api.delivery.EngagementType;
import io.casehub.platform.api.util.UUIDv7;
import io.casehub.platform.delivery.tracking.inmem.InMemoryDeliveryAttemptStore;
import jakarta.enterprise.event.Event;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.time.Instant;
import java.util.ArrayList;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

class EngagementRecorderTest {

    private InMemoryDeliveryAttemptStore store;
    private List<EngagementRecorded> firedEvents;
    private EngagementRecorder recorder;

    @BeforeEach
    void setUp() {
        store = new InMemoryDeliveryAttemptStore(10000);
        firedEvents = new ArrayList<>();
        recorder = new EngagementRecorder(store, new CapturingEngagementEvent(firedEvents), true);
    }

    @Test
    void recordStoresEventAndFiresCdiEvent() {
        var attempt = deliveredAttempt();
        store.store(attempt);
        recorder.record(attempt, EngagementType.OPENED, null);
        var events = store.findEngagementsByAttemptId(attempt.id());
        assertThat(events).hasSize(1);
        assertThat(events.getFirst().type()).isEqualTo(EngagementType.OPENED);
        assertThat(events.getFirst().attemptId()).isEqualTo(attempt.id());
        assertThat(events.getFirst().notificationId()).isEqualTo(attempt.notificationId());
        assertThat(events.getFirst().channelId()).isEqualTo(attempt.channelId());
        assertThat(events.getFirst().userId()).isEqualTo(attempt.userId());
        assertThat(events.getFirst().tenancyId()).isEqualTo(attempt.tenancyId());
        assertThat(firedEvents).hasSize(1);
        assertThat(firedEvents.getFirst().event().type()).isEqualTo(EngagementType.OPENED);
    }

    @Test
    void recordWithMetadata() {
        var attempt = deliveredAttempt();
        store.store(attempt);
        recorder.record(attempt, EngagementType.CLICKED, "{\"url\":\"https://example.com\"}");
        var events = store.findEngagementsByAttemptId(attempt.id());
        assertThat(events.getFirst().metadata()).isEqualTo("{\"url\":\"https://example.com\"}");
    }

    @Test
    void noOpWhenDisabled() {
        var disabledRecorder = new EngagementRecorder(store, new CapturingEngagementEvent(firedEvents), false);
        var attempt = deliveredAttempt();
        store.store(attempt);
        disabledRecorder.record(attempt, EngagementType.OPENED, null);
        assertThat(store.findEngagementsByAttemptId(attempt.id())).isEmpty();
        assertThat(firedEvents).isEmpty();
    }

    private DeliveryAttempt deliveredAttempt() {
        return new DeliveryAttempt(
                UUIDv7.generate(), "notif-1", "email", "user-1", "tenant-1",
                DeliveryType.IMMEDIATE, DeliveryStatus.DELIVERED, 1,
                Instant.now(), Instant.now(), Instant.now(), null, null, "{}",
                null, null);
    }

    private static class CapturingEngagementEvent implements Event<EngagementRecorded> {
        private final List<EngagementRecorded> events;
        CapturingEngagementEvent(List<EngagementRecorded> events) { this.events = events; }
        @Override public void fire(EngagementRecorded e) { events.add(e); }
        @Override public <U extends EngagementRecorded> Event<U> select(Class<U> c, java.lang.annotation.Annotation... a) { throw new UnsupportedOperationException(); }
        @Override public <U extends EngagementRecorded> Event<U> select(jakarta.enterprise.util.TypeLiteral<U> t, java.lang.annotation.Annotation... a) { throw new UnsupportedOperationException(); }
        @Override public Event<EngagementRecorded> select(java.lang.annotation.Annotation... a) { throw new UnsupportedOperationException(); }
        @Override public java.util.concurrent.CompletionStage<EngagementRecorded> fireAsync(EngagementRecorded e) { events.add(e); return java.util.concurrent.CompletableFuture.completedFuture(e); }
        @Override public java.util.concurrent.CompletionStage<EngagementRecorded> fireAsync(EngagementRecorded e, jakarta.enterprise.event.NotificationOptions o) { return fireAsync(e); }
    }
}
```

Use `ide_create_file`.

- [ ] **Step 2: Implement EngagementRecorder**

```java
package io.casehub.platform.notification.dispatch;

import io.casehub.platform.api.delivery.DeliveryAttempt;
import io.casehub.platform.api.delivery.DeliveryAttemptStore;
import io.casehub.platform.api.delivery.EngagementEvent;
import io.casehub.platform.api.delivery.EngagementRecorded;
import io.casehub.platform.api.delivery.EngagementType;
import io.casehub.platform.api.util.UUIDv7;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.event.Event;
import jakarta.inject.Inject;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import java.time.Instant;

@ApplicationScoped
public class EngagementRecorder {

    private static final Logger LOG = Logger.getLogger(EngagementRecorder.class);

    private final DeliveryAttemptStore store;
    private final Event<EngagementRecorded> engagementEvent;
    private final boolean enabled;

    @Inject
    public EngagementRecorder(DeliveryAttemptStore store,
                              Event<EngagementRecorded> engagementEvent,
                              @ConfigProperty(name = "casehub.delivery.engagement.enabled", defaultValue = "false")
                              boolean enabled) {
        this.store = store;
        this.engagementEvent = engagementEvent;
        this.enabled = enabled;
    }

    public void record(DeliveryAttempt attempt, EngagementType type, String metadata) {
        if (!enabled) {
            return;
        }
        var event = new EngagementEvent(
                UUIDv7.generate(),
                attempt.id(),
                attempt.notificationId(),
                attempt.channelId(),
                attempt.userId(),
                attempt.tenancyId(),
                type,
                Instant.now(),
                metadata);
        try {
            store.recordEngagement(event);
            engagementEvent.fireAsync(new EngagementRecorded(event));
        } catch (Exception e) {
            LOG.warnf(e, "Failed to record engagement for attempt '%s'", attempt.id());
        }
    }
}
```

Use `ide_create_file`.

- [ ] **Step 3: Run tests**

Run: `mvn --batch-mode test -pl notification-dispatch -Dtest=EngagementRecorderTest`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/EngagementRecorder.java notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/EngagementRecorderTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#170): EngagementRecorder convergence point with opt-in gate"
```

---

### Task 5: EngagementCallbackResource

**Files:**
- Create: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/EngagementCallbackResource.java`
- Create: `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/EngagementCallbackResourceTest.java`
- Modify: `notification-dispatch/pom.xml` — add `quarkus-rest` and `quarkus-rest-jackson`

**Interfaces:**
- Consumes: `EngagementRecorder.record()`, `DeliveryAttemptStore.findByNotificationId()`, `EngagementCallbackHandler`, `RawEngagement`, `EngagementType`, `CurrentPrincipal`
- Produces: `POST /delivery/engagement/callback/{channelId}`, `POST /delivery/engagement/{attemptId}` REST endpoints

- [ ] **Step 1: Add RESTEasy dependencies to notification-dispatch pom.xml**

Add before the `<!-- Test -->` comment in `notification-dispatch/pom.xml`:

```xml
<dependency>
    <groupId>io.quarkus</groupId>
    <artifactId>quarkus-rest</artifactId>
</dependency>
<dependency>
    <groupId>io.quarkus</groupId>
    <artifactId>quarkus-rest-jackson</artifactId>
</dependency>
```

- [ ] **Step 2: Write failing tests**

```java
package io.casehub.platform.notification.dispatch;

import io.casehub.platform.api.delivery.DeliveryAttempt;
import io.casehub.platform.api.delivery.DeliveryAttemptStore;
import io.casehub.platform.api.delivery.DeliveryStatus;
import io.casehub.platform.api.delivery.DeliveryType;
import io.casehub.platform.api.delivery.EngagementCallbackHandler;
import io.casehub.platform.api.delivery.EngagementType;
import io.casehub.platform.api.delivery.RawEngagement;
import io.casehub.platform.api.identity.CurrentPrincipal;
import io.casehub.platform.api.util.UUIDv7;
import io.casehub.platform.delivery.tracking.inmem.InMemoryDeliveryAttemptStore;
import io.casehub.platform.api.delivery.EngagementRecorded;
import jakarta.enterprise.event.Event;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class EngagementCallbackResourceTest {

    private InMemoryDeliveryAttemptStore store;
    private EngagementRecorder recorder;
    private EngagementCallbackResource resource;
    private List<EngagementRecorded> firedEvents;

    @BeforeEach
    void setUp() {
        store = new InMemoryDeliveryAttemptStore(10000);
        firedEvents = new ArrayList<>();
        recorder = new EngagementRecorder(store,
                new EngagementRecorderTest.CapturingEngagementEvent(firedEvents), true);
    }

    @Test
    void directPathRecordsEngagement() {
        var attempt = deliveredAttempt();
        store.store(attempt);
        var principal = fixedPrincipal("tenant-1");
        resource = new EngagementCallbackResource(store, recorder, principal, Map.of(), true);

        var response = resource.recordDirect(attempt.id(), new EngagementCallbackResource.DirectEngagementRequest(
                EngagementType.OPENED, null));
        assertThat(response.getStatus()).isEqualTo(200);
        assertThat(store.findEngagementsByAttemptId(attempt.id())).hasSize(1);
    }

    @Test
    void directPathReturns404ForMissingAttempt() {
        var principal = fixedPrincipal("tenant-1");
        resource = new EngagementCallbackResource(store, recorder, principal, Map.of(), true);

        var response = resource.recordDirect("nonexistent", new EngagementCallbackResource.DirectEngagementRequest(
                EngagementType.OPENED, null));
        assertThat(response.getStatus()).isEqualTo(404);
    }

    @Test
    void directPathReturns403ForTenantMismatch() {
        var attempt = deliveredAttempt();
        store.store(attempt);
        var principal = fixedPrincipal("other-tenant");
        resource = new EngagementCallbackResource(store, recorder, principal, Map.of(), true);

        var response = resource.recordDirect(attempt.id(), new EngagementCallbackResource.DirectEngagementRequest(
                EngagementType.OPENED, null));
        assertThat(response.getStatus()).isEqualTo(403);
    }

    @Test
    void callbackPathDelegatesToHandler() {
        var attempt = deliveredAttempt();
        store.store(attempt);
        var handler = new TestCallbackHandler(attempt.id());
        resource = new EngagementCallbackResource(store, recorder, fixedPrincipal("tenant-1"),
                Map.of("email", handler), true);

        var response = resource.handleCallback("email", "{\"event\":\"open\"}");
        assertThat(response.getStatus()).isEqualTo(200);
        assertThat(store.findEngagementsByAttemptId(attempt.id())).hasSize(1);
    }

    @Test
    void callbackPathReturns404ForUnknownChannel() {
        resource = new EngagementCallbackResource(store, recorder, fixedPrincipal("tenant-1"),
                Map.of(), true);

        var response = resource.handleCallback("unknown", "{}");
        assertThat(response.getStatus()).isEqualTo(404);
    }

    @Test
    void callbackPathSkipsNonexistentAttempts() {
        var handler = new TestCallbackHandler("nonexistent-attempt");
        resource = new EngagementCallbackResource(store, recorder, fixedPrincipal("tenant-1"),
                Map.of("email", handler), true);

        var response = resource.handleCallback("email", "{}");
        assertThat(response.getStatus()).isEqualTo(200);
        assertThat(firedEvents).isEmpty();
    }

    @Test
    void returns404WhenDisabled() {
        var attempt = deliveredAttempt();
        store.store(attempt);
        resource = new EngagementCallbackResource(store, recorder, fixedPrincipal("tenant-1"),
                Map.of(), false);

        var directResponse = resource.recordDirect(attempt.id(),
                new EngagementCallbackResource.DirectEngagementRequest(EngagementType.OPENED, null));
        assertThat(directResponse.getStatus()).isEqualTo(404);

        var callbackResponse = resource.handleCallback("email", "{}");
        assertThat(callbackResponse.getStatus()).isEqualTo(404);
    }

    private DeliveryAttempt deliveredAttempt() {
        return new DeliveryAttempt(
                UUIDv7.generate(), "notif-1", "email", "user-1", "tenant-1",
                DeliveryType.IMMEDIATE, DeliveryStatus.DELIVERED, 1,
                Instant.now(), Instant.now(), Instant.now(), null, null, "{}",
                null, null);
    }

    private CurrentPrincipal fixedPrincipal(String tenancyId) {
        return new CurrentPrincipal() {
            @Override public String actorId() { return "actor-1"; }
            @Override public String tenancyId() { return tenancyId; }
            @Override public List<String> groups() { return List.of(); }
        };
    }

    private static class TestCallbackHandler implements EngagementCallbackHandler {
        private final String attemptId;
        TestCallbackHandler(String attemptId) { this.attemptId = attemptId; }
        @Override public String channelId() { return "email"; }
        @Override public List<RawEngagement> translate(String rawPayload) {
            return List.of(new RawEngagement(attemptId, EngagementType.OPENED, null));
        }
    }
}
```

Use `ide_create_file`.

- [ ] **Step 3: Implement EngagementCallbackResource**

```java
package io.casehub.platform.notification.dispatch;

import io.casehub.platform.api.delivery.DeliveryAttempt;
import io.casehub.platform.api.delivery.DeliveryAttemptStore;
import io.casehub.platform.api.delivery.EngagementCallbackHandler;
import io.casehub.platform.api.delivery.EngagementType;
import io.casehub.platform.api.identity.CurrentPrincipal;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.inject.Instance;
import jakarta.inject.Inject;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.core.Response;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import java.util.Map;
import java.util.stream.Collectors;

@Path("/delivery/engagement")
@ApplicationScoped
public class EngagementCallbackResource {

    private static final Logger LOG = Logger.getLogger(EngagementCallbackResource.class);

    private final DeliveryAttemptStore store;
    private final EngagementRecorder recorder;
    private final CurrentPrincipal principal;
    private final Map<String, EngagementCallbackHandler> handlers;
    private final boolean enabled;

    @Inject
    public EngagementCallbackResource(DeliveryAttemptStore store,
                                      EngagementRecorder recorder,
                                      CurrentPrincipal principal,
                                      Instance<EngagementCallbackHandler> handlerInstances,
                                      @ConfigProperty(name = "casehub.delivery.engagement.enabled", defaultValue = "false")
                                      boolean enabled) {
        this.store = store;
        this.recorder = recorder;
        this.principal = principal;
        this.handlers = handlerInstances.stream()
                .collect(Collectors.toMap(EngagementCallbackHandler::channelId, h -> h));
        this.enabled = enabled;
    }

    EngagementCallbackResource(DeliveryAttemptStore store,
                               EngagementRecorder recorder,
                               CurrentPrincipal principal,
                               Map<String, EngagementCallbackHandler> handlers,
                               boolean enabled) {
        this.store = store;
        this.recorder = recorder;
        this.principal = principal;
        this.handlers = handlers;
        this.enabled = enabled;
    }

    @POST
    @Path("/callback/{channelId}")
    @Consumes({"application/json", "application/x-www-form-urlencoded"})
    public Response handleCallback(@PathParam("channelId") String channelId, String rawPayload) {
        if (!enabled) {
            return Response.status(404).build();
        }
        var handler = handlers.get(channelId);
        if (handler == null) {
            return Response.status(404).build();
        }
        var rawEvents = handler.translate(rawPayload);
        for (var raw : rawEvents) {
            var attempts = store.findByNotificationId(null);
            DeliveryAttempt attempt = findAttemptById(raw.attemptId());
            if (attempt == null) {
                LOG.debugf("Engagement callback for nonexistent attempt '%s' — skipping", raw.attemptId());
                continue;
            }
            recorder.record(attempt, raw.type(), raw.metadata());
        }
        return Response.ok().build();
    }

    @POST
    @Path("/{attemptId}")
    @Consumes("application/json")
    public Response recordDirect(@PathParam("attemptId") String attemptId,
                                 DirectEngagementRequest request) {
        if (!enabled) {
            return Response.status(404).build();
        }
        DeliveryAttempt attempt = findAttemptById(attemptId);
        if (attempt == null) {
            return Response.status(404).build();
        }
        if (!attempt.tenancyId().equals(principal.tenancyId())) {
            return Response.status(403).build();
        }
        recorder.record(attempt, request.type(), request.metadata());
        return Response.ok().build();
    }

    private DeliveryAttempt findAttemptById(String attemptId) {
        var page = store.find(new io.casehub.platform.api.delivery.DeliveryAttemptQuery(
                null, null, null, null, null, 1));
        return store.find(new io.casehub.platform.api.delivery.DeliveryAttemptQuery(
                null, null, null, null, null, Integer.MAX_VALUE))
                .attempts().stream()
                .filter(a -> a.id().equals(attemptId))
                .findFirst()
                .orElse(null);
    }

    public record DirectEngagementRequest(EngagementType type, String metadata) {}
}
```

**Note:** The `findAttemptById` is a naive scan — `DeliveryAttemptStore` does not have a `findById` method. This is a gap we should address. Add a `findById` method to the store or use `findByNotificationId` differently. For now, the callback handler provides the attemptId, and the direct path validates via the store. The implementer should add a `findById(String)` method to `DeliveryAttemptStore` and its implementations — this is a clean SPI addition that was missing from the original design.

Use `ide_create_file`.

- [ ] **Step 4: Add findById to DeliveryAttemptStore and implementations**

Add to `DeliveryAttemptStore` using `ide_insert_member`:

```java
DeliveryAttempt findById(String id);
```

Add to `NoOpDeliveryAttemptStore`:

```java
@Override
public DeliveryAttempt findById(String id) {
    return null;
}
```

Add to `InMemoryDeliveryAttemptStore`:

```java
@Override
public DeliveryAttempt findById(String id) {
    return store.get(id);
}
```

Add to `JpaDeliveryAttemptStore`:

```java
@Override
public DeliveryAttempt findById(String id) {
    var entity = getEntityManager().find(DeliveryAttemptEntity.class, id);
    return entity != null ? entity.toDomain() : null;
}
```

Then update `EngagementCallbackResource.findAttemptById` to use `store.findById(attemptId)`.

- [ ] **Step 5: Run tests**

Run: `mvn --batch-mode test -pl notification-dispatch -Dtest=EngagementCallbackResourceTest`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add -A
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#170): EngagementCallbackResource REST endpoints with findById SPI addition"
```

---

### Task 6: InAppEngagementBridge

**Files:**
- Create: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/InAppEngagementBridge.java`
- Create: `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/InAppEngagementBridgeTest.java`

**Interfaces:**
- Consumes: `EngagementRecorder.record()`, `DeliveryAttemptStore.findByNotificationId()`, `NotificationStatusChanged`, `NotificationStatus`, `DeliveryChannels.IN_APP`
- Produces: CDI observer that bridges in-app notification read/dismiss to engagement events

- [ ] **Step 1: Write failing tests**

```java
package io.casehub.platform.notification.dispatch;

import io.casehub.platform.api.delivery.DeliveryAttempt;
import io.casehub.platform.api.delivery.DeliveryChannels;
import io.casehub.platform.api.delivery.DeliveryStatus;
import io.casehub.platform.api.delivery.DeliveryType;
import io.casehub.platform.api.delivery.EngagementRecorded;
import io.casehub.platform.api.delivery.EngagementType;
import io.casehub.platform.api.notification.Notification;
import io.casehub.platform.api.notification.NotificationSeverity;
import io.casehub.platform.api.notification.NotificationSource;
import io.casehub.platform.api.notification.NotificationStatus;
import io.casehub.platform.api.notification.NotificationStatusChanged;
import io.casehub.platform.api.util.UUIDv7;
import io.casehub.platform.delivery.tracking.inmem.InMemoryDeliveryAttemptStore;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.time.Instant;
import java.util.ArrayList;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

class InAppEngagementBridgeTest {

    private InMemoryDeliveryAttemptStore store;
    private List<EngagementRecorded> firedEvents;
    private InAppEngagementBridge bridge;

    @BeforeEach
    void setUp() {
        store = new InMemoryDeliveryAttemptStore(10000);
        firedEvents = new ArrayList<>();
        var recorder = new EngagementRecorder(store,
                new EngagementRecorderTest.CapturingEngagementEvent(firedEvents), true);
        bridge = new InAppEngagementBridge(store, recorder, true);
    }

    @Test
    void mapsReadToOpened() {
        var attempt = inAppAttempt("notif-1");
        store.store(attempt);
        var notification = testNotification("notif-1", NotificationStatus.READ);
        bridge.onStatusChanged(new NotificationStatusChanged(notification, NotificationStatus.UNREAD));
        var events = store.findEngagementsByAttemptId(attempt.id());
        assertThat(events).hasSize(1);
        assertThat(events.getFirst().type()).isEqualTo(EngagementType.OPENED);
    }

    @Test
    void mapsDismissedToDismissed() {
        var attempt = inAppAttempt("notif-1");
        store.store(attempt);
        var notification = testNotification("notif-1", NotificationStatus.DISMISSED);
        bridge.onStatusChanged(new NotificationStatusChanged(notification, NotificationStatus.READ));
        var events = store.findEngagementsByAttemptId(attempt.id());
        assertThat(events).hasSize(1);
        assertThat(events.getFirst().type()).isEqualTo(EngagementType.DISMISSED);
    }

    @Test
    void skipsWhenNoInAppAttemptFound() {
        var notification = testNotification("notif-no-attempt", NotificationStatus.READ);
        bridge.onStatusChanged(new NotificationStatusChanged(notification, NotificationStatus.UNREAD));
        assertThat(firedEvents).isEmpty();
    }

    @Test
    void skipsNonInAppAttempts() {
        var emailAttempt = new DeliveryAttempt(
                UUIDv7.generate(), "notif-1", "email", "user-1", "tenant-1",
                DeliveryType.IMMEDIATE, DeliveryStatus.DELIVERED, 1,
                Instant.now(), Instant.now(), Instant.now(), null, null, "{}",
                null, null);
        store.store(emailAttempt);
        var notification = testNotification("notif-1", NotificationStatus.READ);
        bridge.onStatusChanged(new NotificationStatusChanged(notification, NotificationStatus.UNREAD));
        assertThat(store.findEngagementsByAttemptId(emailAttempt.id())).isEmpty();
    }

    @Test
    void skipsWhenDisabled() {
        var disabledBridge = new InAppEngagementBridge(store,
                new EngagementRecorder(store, new EngagementRecorderTest.CapturingEngagementEvent(firedEvents), false),
                false);
        var attempt = inAppAttempt("notif-1");
        store.store(attempt);
        var notification = testNotification("notif-1", NotificationStatus.READ);
        disabledBridge.onStatusChanged(new NotificationStatusChanged(notification, NotificationStatus.UNREAD));
        assertThat(store.findEngagementsByAttemptId(attempt.id())).isEmpty();
    }

    private DeliveryAttempt inAppAttempt(String notificationId) {
        return new DeliveryAttempt(
                UUIDv7.generate(), notificationId, DeliveryChannels.IN_APP, "user-1", "tenant-1",
                DeliveryType.IMMEDIATE, DeliveryStatus.DELIVERED, 1,
                Instant.now(), Instant.now(), Instant.now(), null, null, "{}",
                null, null);
    }

    private Notification testNotification(String id, NotificationStatus status) {
        return new Notification(
                id, "user-1", "tenant-1", "Test", "body",
                "test", NotificationSeverity.INFO, null,
                new NotificationSource("evt-1", "work-item", "wi-1", "actor-1"),
                status, Instant.now(),
                status == NotificationStatus.READ ? Instant.now() : null,
                status == NotificationStatus.DISMISSED ? Instant.now() : null);
    }
}
```

Use `ide_create_file`.

- [ ] **Step 2: Implement InAppEngagementBridge**

```java
package io.casehub.platform.notification.dispatch;

import io.casehub.platform.api.delivery.DeliveryAttemptStore;
import io.casehub.platform.api.delivery.DeliveryChannels;
import io.casehub.platform.api.delivery.EngagementType;
import io.casehub.platform.api.notification.NotificationStatus;
import io.casehub.platform.api.notification.NotificationStatusChanged;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.event.ObservesAsync;
import jakarta.inject.Inject;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

@ApplicationScoped
public class InAppEngagementBridge {

    private static final Logger LOG = Logger.getLogger(InAppEngagementBridge.class);

    private final DeliveryAttemptStore store;
    private final EngagementRecorder recorder;
    private final boolean enabled;

    @Inject
    public InAppEngagementBridge(DeliveryAttemptStore store,
                                 EngagementRecorder recorder,
                                 @ConfigProperty(name = "casehub.delivery.engagement.enabled", defaultValue = "false")
                                 boolean enabled) {
        this.store = store;
        this.recorder = recorder;
        this.enabled = enabled;
    }

    void onStatusChanged(@ObservesAsync NotificationStatusChanged event) {
        if (!enabled) {
            return;
        }
        var notification = event.notification();
        var newStatus = notification.status();
        EngagementType type;
        if (newStatus == NotificationStatus.READ) {
            type = EngagementType.OPENED;
        } else if (newStatus == NotificationStatus.DISMISSED) {
            type = EngagementType.DISMISSED;
        } else {
            return;
        }
        var attempts = store.findByNotificationId(notification.id());
        var inAppAttempt = attempts.stream()
                .filter(a -> DeliveryChannels.IN_APP.equals(a.channelId()))
                .findFirst()
                .orElse(null);
        if (inAppAttempt == null) {
            LOG.debugf("No in-app delivery attempt for notification '%s' — skipping engagement bridge",
                    notification.id());
            return;
        }
        recorder.record(inAppAttempt, type, null);
    }
}
```

Use `ide_create_file`.

- [ ] **Step 3: Run tests**

Run: `mvn --batch-mode test -pl notification-dispatch -Dtest=InAppEngagementBridgeTest`
Expected: PASS

- [ ] **Step 4: Full build**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS — all modules compile and all tests pass.

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add notification-dispatch/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#170): InAppEngagementBridge — CDI observer for in-app read/dismiss engagement"
```

---

## Self-Review Checklist

**Spec coverage:**
- ✅ EngagementType enum — Task 1
- ✅ EngagementEvent record — Task 1
- ✅ RawEngagement record — Task 1
- ✅ EngagementRecorded CDI event — Task 1
- ✅ EngagementCallbackHandler SPI — Task 1
- ✅ DeliveryAttempt +2 fields — Task 1
- ✅ DeliveryAttemptStore +3 methods — Task 1
- ✅ NoOp implementation — Task 1
- ✅ InMemory implementation — Task 2
- ✅ JPA implementation + V3001 — Task 3
- ✅ EngagementRecorder — Task 4
- ✅ EngagementCallbackResource — Task 5
- ✅ InAppEngagementBridge — Task 6
- ✅ Deployment opt-in gate — Tasks 4, 5, 6
- ✅ All constructor call site updates — Task 1
- ✅ Eviction cascade — Task 2
- ✅ ON DELETE CASCADE — Task 3
- ✅ First-write-wins summary fields — Tasks 2, 3
- ✅ Append-only event storage — Tasks 2, 3

**Gap found during self-review:** `DeliveryAttemptStore` has no `findById(String)` method — needed by `EngagementCallbackResource` to look up an attempt by ID. Added as a step in Task 5. This is a clean SPI addition the spec didn't anticipate.

**Placeholder scan:** No TBD/TODO. All steps have concrete code.
**Type consistency:** ✅ — all signatures match across tasks.
**Tooling safety:** ✅ — all source file operations use `ide_*` tools. Bash only for git/maven.
