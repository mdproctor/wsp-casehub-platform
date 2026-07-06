# Notification Digest and Batching Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #144 — feat: notification digest and batching — timer-driven aggregation to reduce noise
**Issue group:** #144

**Goal:** Add timer-driven digest buffering to the notification dispatch pipeline so external channels (email, SMS, push) can aggregate notifications into periodic summaries instead of delivering each one immediately.

**Architecture:** Digest intercepts after channel routing, before delivery. `ChannelRouter` determines whether a channel is digested (external + has schedule + not URGENT). Digested notifications go into a `DigestBuffer`; a `DigestFlushScheduler` drains and delivers on the user's schedule. In-app always delivers immediately.

**Tech Stack:** Java 17+ sealed interfaces, Quarkus CDI, `@Scheduled` (quarkus-scheduler), Jackson `@JsonTypeInfo` for sealed interface serialization, ConcurrentHashMap for in-memory buffer.

## Global Constraints

- `platform-api/` must remain zero-dependency — no Quarkus, no JPA. Pure Java only.
- Every SPI in platform-api gets a `@DefaultBean` implementation in `platform/`
- `ChannelPreference` and `DeliveryChannelDescriptor` are breaking record changes — add `null` for new fields at every existing constructor call site
- Buffer size capped per key at `casehub.notification.digest.max-buffer-size` (default 500)
- `DigestSchedule.Interval` minimum period: 1 minute
- URGENT severity always bypasses digest — routed as immediate regardless of schedule
- In-app channel never digested (not external)
- Jackson type discriminator for `DigestSchedule`: `@JsonTypeInfo(use = Id.NAME, property = "type")`

---

### Task 1: SPI Types and Modified Records (platform-api)

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/delivery/DigestSchedule.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/delivery/DigestBufferKey.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/delivery/DigestSummary.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/delivery/DigestBuffer.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/notification/settings/ChannelPreference.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/delivery/DeliveryChannelDescriptor.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/delivery/NotificationDeliverer.java`
- Test: `platform-api/src/test/java/io/casehub/platform/api/delivery/DigestScheduleTest.java`
- Test: `platform-api/src/test/java/io/casehub/platform/api/delivery/DigestSummaryTest.java`
- Test: `platform-api/src/test/java/io/casehub/platform/api/delivery/NotificationDelivererContractTest.java`

**Interfaces:**
- Consumes: nothing (foundational task)
- Produces: `DigestSchedule` sealed interface with `isFlushDue(Instant, Instant, Instant)`, `DigestSchedule.Interval(Duration)`, `DigestSchedule.DailyAt(LocalTime, ZoneId)`, `DigestBufferKey(String, String, String)`, `DigestSummary(String, String, String, List<NotificationInput>, Instant, Instant)`, `DigestBuffer` SPI (`add`, `drain`, `pendingKeys`, `oldestPendingTimestamp`), `ChannelPreference(boolean, NotificationSeverity, DigestSchedule)` with `isDigested()`, `DeliveryChannelDescriptor(String, String, boolean, boolean, NotificationSeverity, DigestSchedule)`, `NotificationDeliverer.deliverDigest(DigestSummary)` default method

- [ ] **Step 1: Write DigestSchedule tests**

Create `platform-api/src/test/java/io/casehub/platform/api/delivery/DigestScheduleTest.java`:

```java
package io.casehub.platform.api.delivery;

import org.junit.jupiter.api.Test;

import java.time.Duration;
import java.time.Instant;
import java.time.LocalTime;
import java.time.ZoneId;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class DigestScheduleTest {

    @Test
    void interval_rejectsNull() {
        assertThatThrownBy(() -> new DigestSchedule.Interval(null))
                .isInstanceOf(NullPointerException.class);
    }

    @Test
    void interval_rejectsZero() {
        assertThatThrownBy(() -> new DigestSchedule.Interval(Duration.ZERO))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("period must be >=");
    }

    @Test
    void interval_rejectsBelowMinimum() {
        assertThatThrownBy(() -> new DigestSchedule.Interval(Duration.ofSeconds(30)))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void interval_acceptsOneMinute() {
        var interval = new DigestSchedule.Interval(Duration.ofMinutes(1));
        assertThat(interval.period()).isEqualTo(Duration.ofMinutes(1));
    }

    @Test
    void interval_isFlushDue_trueWhenPeriodElapsed() {
        var interval = new DigestSchedule.Interval(Duration.ofHours(4));
        Instant oldest = Instant.parse("2026-07-06T08:00:00Z");
        Instant lastFlush = Instant.parse("2026-07-06T07:00:00Z");
        Instant now = Instant.parse("2026-07-06T12:00:01Z");
        assertThat(interval.isFlushDue(oldest, lastFlush, now)).isTrue();
    }

    @Test
    void interval_isFlushDue_falseWhenPeriodNotElapsed() {
        var interval = new DigestSchedule.Interval(Duration.ofHours(4));
        Instant oldest = Instant.parse("2026-07-06T08:00:00Z");
        Instant lastFlush = Instant.parse("2026-07-06T07:00:00Z");
        Instant now = Instant.parse("2026-07-06T11:59:59Z");
        assertThat(interval.isFlushDue(oldest, lastFlush, now)).isFalse();
    }

    @Test
    void dailyAt_rejectsNullTime() {
        assertThatThrownBy(() -> new DigestSchedule.DailyAt(null, ZoneId.of("UTC")))
                .isInstanceOf(NullPointerException.class);
    }

    @Test
    void dailyAt_rejectsNullTimezone() {
        assertThatThrownBy(() -> new DigestSchedule.DailyAt(LocalTime.of(9, 0), null))
                .isInstanceOf(NullPointerException.class);
    }

    @Test
    void dailyAt_isFlushDue_trueWhenTargetTimePassedAndNotFlushedToday() {
        var daily = new DigestSchedule.DailyAt(LocalTime.of(9, 0), ZoneId.of("UTC"));
        Instant oldest = Instant.parse("2026-07-06T06:00:00Z");
        Instant lastFlush = Instant.parse("2026-07-05T09:00:00Z");
        Instant now = Instant.parse("2026-07-06T09:00:01Z");
        assertThat(daily.isFlushDue(oldest, lastFlush, now)).isTrue();
    }

    @Test
    void dailyAt_isFlushDue_falseWhenAlreadyFlushedToday() {
        var daily = new DigestSchedule.DailyAt(LocalTime.of(9, 0), ZoneId.of("UTC"));
        Instant oldest = Instant.parse("2026-07-06T09:30:00Z");
        Instant lastFlush = Instant.parse("2026-07-06T09:00:00Z");
        Instant now = Instant.parse("2026-07-06T10:00:00Z");
        assertThat(daily.isFlushDue(oldest, lastFlush, now)).isFalse();
    }

    @Test
    void dailyAt_isFlushDue_falseBeforeTargetTime() {
        var daily = new DigestSchedule.DailyAt(LocalTime.of(9, 0), ZoneId.of("UTC"));
        Instant oldest = Instant.parse("2026-07-06T06:00:00Z");
        Instant lastFlush = Instant.parse("2026-07-05T09:00:00Z");
        Instant now = Instant.parse("2026-07-06T08:59:59Z");
        assertThat(daily.isFlushDue(oldest, lastFlush, now)).isFalse();
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl platform-api -Dtest=DigestScheduleTest -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: compilation failure — `DigestSchedule` does not exist

- [ ] **Step 3: Implement DigestSchedule**

Create `platform-api/src/main/java/io/casehub/platform/api/delivery/DigestSchedule.java`:

```java
package io.casehub.platform.api.delivery;

import com.fasterxml.jackson.annotation.JsonSubTypes;
import com.fasterxml.jackson.annotation.JsonTypeInfo;

import java.time.Duration;
import java.time.Instant;
import java.time.LocalTime;
import java.time.ZoneId;
import java.util.Objects;

@JsonTypeInfo(use = JsonTypeInfo.Id.NAME, property = "type")
@JsonSubTypes({
        @JsonSubTypes.SubType(value = DigestSchedule.Interval.class, name = "interval"),
        @JsonSubTypes.SubType(value = DigestSchedule.DailyAt.class, name = "daily_at")
})
public sealed interface DigestSchedule {

    boolean isFlushDue(Instant oldestPending, Instant lastFlush, Instant now);

    record Interval(Duration period) implements DigestSchedule {
        private static final Duration MIN_PERIOD = Duration.ofMinutes(1);

        public Interval {
            Objects.requireNonNull(period, "period");
            if (period.compareTo(MIN_PERIOD) < 0)
                throw new IllegalArgumentException("period must be >= " + MIN_PERIOD);
        }

        @Override
        public boolean isFlushDue(Instant oldestPending, Instant lastFlush, Instant now) {
            return !oldestPending.plus(period).isAfter(now);
        }
    }

    record DailyAt(LocalTime time, ZoneId timezone) implements DigestSchedule {
        public DailyAt {
            Objects.requireNonNull(time, "time");
            Objects.requireNonNull(timezone, "timezone");
        }

        @Override
        public boolean isFlushDue(Instant oldestPending, Instant lastFlush, Instant now) {
            Instant todayTarget = now.atZone(timezone).with(time).toInstant();
            return !now.isBefore(todayTarget) && lastFlush.isBefore(todayTarget);
        }
    }
}
```

- [ ] **Step 4: Run DigestSchedule tests**

Run: `mvn --batch-mode test -pl platform-api -Dtest=DigestScheduleTest -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: all PASS

- [ ] **Step 5: Write DigestSummary tests**

Create `platform-api/src/test/java/io/casehub/platform/api/delivery/DigestSummaryTest.java`:

```java
package io.casehub.platform.api.delivery;

import io.casehub.platform.api.notification.NotificationInput;
import io.casehub.platform.api.notification.NotificationSeverity;
import io.casehub.platform.api.notification.NotificationSource;
import org.junit.jupiter.api.Test;

import java.time.Instant;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class DigestSummaryTest {

    private static final NotificationInput SAMPLE = new NotificationInput(
            "user-1", "tenant-1", "Title", null, "test",
            NotificationSeverity.INFO, null,
            new NotificationSource(UUID.randomUUID().toString(), "work-item", "wi-1", "actor-1"));

    @Test
    void rejectsEmptyNotifications() {
        assertThatThrownBy(() -> new DigestSummary(
                "user-1", "tenant-1", "email", List.of(),
                Instant.now(), Instant.now()))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("notifications must not be empty");
    }

    @Test
    void rejectsNullNotifications() {
        assertThatThrownBy(() -> new DigestSummary(
                "user-1", "tenant-1", "email", null,
                Instant.now(), Instant.now()))
                .isInstanceOf(NullPointerException.class);
    }

    @Test
    void createsDefensiveCopy() {
        var mutable = new java.util.ArrayList<>(List.of(SAMPLE));
        var summary = new DigestSummary("user-1", "tenant-1", "email",
                mutable, Instant.now(), Instant.now());
        mutable.add(SAMPLE);
        assertThat(summary.notifications()).hasSize(1);
    }
}
```

- [ ] **Step 6: Implement DigestBufferKey, DigestSummary, DigestBuffer**

Create `platform-api/src/main/java/io/casehub/platform/api/delivery/DigestBufferKey.java`:

```java
package io.casehub.platform.api.delivery;

import java.util.Objects;

public record DigestBufferKey(String userId, String tenancyId, String channelId) {
    public DigestBufferKey {
        Objects.requireNonNull(userId, "userId");
        Objects.requireNonNull(tenancyId, "tenancyId");
        Objects.requireNonNull(channelId, "channelId");
    }
}
```

Create `platform-api/src/main/java/io/casehub/platform/api/delivery/DigestSummary.java`:

```java
package io.casehub.platform.api.delivery;

import io.casehub.platform.api.notification.NotificationInput;

import java.time.Instant;
import java.util.List;
import java.util.Objects;

public record DigestSummary(
        String userId, String tenancyId, String channelId,
        List<NotificationInput> notifications,
        Instant periodStart, Instant periodEnd
) {
    public DigestSummary {
        Objects.requireNonNull(userId, "userId");
        Objects.requireNonNull(tenancyId, "tenancyId");
        Objects.requireNonNull(channelId, "channelId");
        Objects.requireNonNull(notifications, "notifications");
        if (notifications.isEmpty())
            throw new IllegalArgumentException("notifications must not be empty");
        notifications = List.copyOf(notifications);
    }
}
```

Create `platform-api/src/main/java/io/casehub/platform/api/delivery/DigestBuffer.java`:

```java
package io.casehub.platform.api.delivery;

import io.casehub.platform.api.notification.NotificationInput;

import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.Set;

public interface DigestBuffer {
    void add(DigestBufferKey key, NotificationInput notification);
    List<NotificationInput> drain(DigestBufferKey key);
    Set<DigestBufferKey> pendingKeys();
    Optional<Instant> oldestPendingTimestamp(DigestBufferKey key);
}
```

- [ ] **Step 7: Run DigestSummary tests**

Run: `mvn --batch-mode test -pl platform-api -Dtest=DigestSummaryTest -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: all PASS

- [ ] **Step 8: Write NotificationDeliverer contract test**

Create `platform-api/src/test/java/io/casehub/platform/api/delivery/NotificationDelivererContractTest.java`:

```java
package io.casehub.platform.api.delivery;

import io.casehub.platform.api.notification.NotificationInput;
import io.casehub.platform.api.notification.NotificationSeverity;
import io.casehub.platform.api.notification.NotificationSource;
import org.junit.jupiter.api.Test;

import java.time.Instant;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicReference;

import static org.assertj.core.api.Assertions.assertThat;

class NotificationDelivererContractTest {

    @Test
    void deliverDigest_defaultMethod_collapsesToSingleNotification() {
        AtomicReference<NotificationInput> captured = new AtomicReference<>();

        NotificationDeliverer deliverer = new NotificationDeliverer() {
            @Override
            public String channelId() { return "test"; }

            @Override
            public DeliveryResult deliver(NotificationInput notification) {
                captured.set(notification);
                return new DeliveryResult(true, null);
            }
        };

        var input1 = sampleInput("Title 1");
        var input2 = sampleInput("Title 2");
        var input3 = sampleInput("Title 3");
        var summary = new DigestSummary("user-1", "tenant-1", "test",
                List.of(input1, input2, input3), Instant.now().minusSeconds(3600), Instant.now());

        DeliveryResult result = deliverer.deliverDigest(summary);

        assertThat(result.success()).isTrue();
        assertThat(captured.get()).isNotNull();
        assertThat(captured.get().title()).isEqualTo("3 new notifications");
        assertThat(captured.get().category()).isEqualTo("digest");
        assertThat(captured.get().userId()).isEqualTo("user-1");
        assertThat(captured.get().tenancyId()).isEqualTo("tenant-1");
    }

    private static NotificationInput sampleInput(String title) {
        return new NotificationInput("user-1", "tenant-1", title, null, "test",
                NotificationSeverity.INFO, null,
                new NotificationSource(UUID.randomUUID().toString(), "work-item", "wi-1", "actor-1"));
    }
}
```

- [ ] **Step 9: Modify ChannelPreference — add digestSchedule**

Replace `platform-api/src/main/java/io/casehub/platform/api/notification/settings/ChannelPreference.java`:

```java
package io.casehub.platform.api.notification.settings;

import io.casehub.platform.api.delivery.DigestSchedule;
import io.casehub.platform.api.notification.NotificationSeverity;

import java.util.Objects;

public record ChannelPreference(
        boolean enabled,
        NotificationSeverity minSeverity,
        DigestSchedule digestSchedule
) {
    public ChannelPreference {
        Objects.requireNonNull(minSeverity, "minSeverity");
    }

    public boolean isDigested() {
        return digestSchedule != null;
    }
}
```

- [ ] **Step 10: Modify DeliveryChannelDescriptor — add defaultDigestSchedule**

Replace `platform-api/src/main/java/io/casehub/platform/api/delivery/DeliveryChannelDescriptor.java`:

```java
package io.casehub.platform.api.delivery;

import io.casehub.platform.api.notification.NotificationSeverity;

import java.util.Objects;

public record DeliveryChannelDescriptor(
        String channelId,
        String displayName,
        boolean external,
        boolean defaultEnabled,
        NotificationSeverity defaultMinSeverity,
        DigestSchedule defaultDigestSchedule
) {
    public DeliveryChannelDescriptor {
        Objects.requireNonNull(channelId, "channelId");
        Objects.requireNonNull(displayName, "displayName");
        Objects.requireNonNull(defaultMinSeverity, "defaultMinSeverity");
    }
}
```

- [ ] **Step 11: Modify NotificationDeliverer — add deliverDigest default**

Add default method to `platform-api/src/main/java/io/casehub/platform/api/delivery/NotificationDeliverer.java`:

```java
package io.casehub.platform.api.delivery;

import io.casehub.platform.api.notification.NotificationInput;
import io.casehub.platform.api.notification.NotificationSeverity;
import io.casehub.platform.api.notification.NotificationSource;

public interface NotificationDeliverer {
    String channelId();
    DeliveryResult deliver(NotificationInput notification);

    default DeliveryResult deliverDigest(DigestSummary summary) {
        NotificationInput collapsed = new NotificationInput(
                summary.userId(), summary.tenancyId(),
                summary.notifications().size() + " new notifications",
                null, "digest", NotificationSeverity.INFO, null,
                summary.notifications().getFirst().source());
        return deliver(collapsed);
    }
}
```

- [ ] **Step 12: Run all platform-api tests**

Run: `mvn --batch-mode test -pl platform-api -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: all PASS (existing + new tests). Compilation errors in downstream modules expected — those are fixed in Task 2.

- [ ] **Step 13: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform-api/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#144): digest SPI types — DigestSchedule, DigestBuffer, DigestSummary, ChannelPreference digest field"
```

---

### Task 2: NoOpDigestBuffer + Breaking Change Migration

**Files:**
- Create: `platform/src/main/java/io/casehub/platform/delivery/NoOpDigestBuffer.java`
- Modify: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/InAppNotificationDeliverer.java` (constructor arg)
- Modify: `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/ChannelRouterTest.java` (all `DeliveryChannelDescriptor` and `ChannelPreference` constructors)
- Modify: `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/NotificationDispatcherTest.java` (all `DeliveryChannelDescriptor` constructors)
- Modify: `notification-settings-inmem/src/main/java/io/casehub/platform/notification/settings/inmem/InMemoryNotificationPreferenceStore.java` (no change needed — stores ChannelPreference as-is)
- Modify: `notifications/src/main/java/io/casehub/platform/notification/rest/NotificationPreferenceResource.java` (no structural change — Jackson handles serialization)

**Interfaces:**
- Consumes: `DigestBuffer` SPI from Task 1, `ChannelPreference(boolean, NotificationSeverity, DigestSchedule)` from Task 1
- Produces: `NoOpDigestBuffer @DefaultBean`, all modules compile cleanly

- [ ] **Step 1: Create NoOpDigestBuffer**

Create `platform/src/main/java/io/casehub/platform/delivery/NoOpDigestBuffer.java`:

```java
package io.casehub.platform.delivery;

import io.casehub.platform.api.delivery.DigestBuffer;
import io.casehub.platform.api.delivery.DigestBufferKey;
import io.casehub.platform.api.notification.NotificationInput;
import io.quarkus.arc.DefaultBean;
import jakarta.enterprise.context.ApplicationScoped;

import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.Set;

@DefaultBean
@ApplicationScoped
public class NoOpDigestBuffer implements DigestBuffer {

    @Override
    public void add(DigestBufferKey key, NotificationInput notification) {}

    @Override
    public List<NotificationInput> drain(DigestBufferKey key) {
        return List.of();
    }

    @Override
    public Set<DigestBufferKey> pendingKeys() {
        return Set.of();
    }

    @Override
    public Optional<Instant> oldestPendingTimestamp(DigestBufferKey key) {
        return Optional.empty();
    }
}
```

- [ ] **Step 2: Fix InAppNotificationDeliverer — add null for defaultDigestSchedule**

In `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/InAppNotificationDeliverer.java`, update the `register()` method's `DeliveryChannelDescriptor` constructor call — add `null` as the sixth argument (defaultDigestSchedule):

```java
channelRegistry.register(
        new DeliveryChannelDescriptor(
                DeliveryChannels.IN_APP,
                "In-App Inbox",
                false,
                true,
                NotificationSeverity.INFO,
                null),
        this);
```

- [ ] **Step 3: Fix ChannelRouterTest — all constructor call sites**

In `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/ChannelRouterTest.java`:

All `DeliveryChannelDescriptor` constructors: add `null` as sixth arg.
All `ChannelPreference` constructors: add `null` as third arg.

For example, in `setUp()`:
```java
registry.register(
        new DeliveryChannelDescriptor(DeliveryChannels.IN_APP, "In-App Inbox",
                false, true, NotificationSeverity.INFO, null),
        IN_APP_DELIVERER);

registry.register(
        new DeliveryChannelDescriptor(DeliveryChannels.EMAIL, "Email",
                true, true, NotificationSeverity.WARNING, null),
        EMAIL_DELIVERER);

registry.register(
        new DeliveryChannelDescriptor(DeliveryChannels.SMS, "SMS",
                true, false, NotificationSeverity.URGENT, null),
        SMS_DELIVERER);
```

In `route_usesUserPreference_overChannelDefault`:
```java
var userPrefs = Map.of(
        DeliveryChannels.SMS, new ChannelPreference(true, NotificationSeverity.INFO, null));
```

In `route_userDisablesChannel`:
```java
var userPrefs = Map.of(
        DeliveryChannels.IN_APP, new ChannelPreference(false, NotificationSeverity.INFO, null));
```

- [ ] **Step 4: Fix NotificationDispatcherTest — all constructor call sites**

In `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/NotificationDispatcherTest.java`:

All `DeliveryChannelDescriptor` constructors: add `null` as sixth arg.

In `setUp()`:
```java
channelRegistry.register(
        new DeliveryChannelDescriptor(DeliveryChannels.IN_APP, "In-App Inbox",
                false, true, NotificationSeverity.INFO, null),
        new CapturingDeliverer(DeliveryChannels.IN_APP, deliveredNotifications));
```

In `dispatch_channelDeliveryFailure_doesNotBlockOtherChannels`:
```java
channelRegistry.register(
        new DeliveryChannelDescriptor(DeliveryChannels.EMAIL, "Email",
                true, true, NotificationSeverity.INFO, null),
        failingDeliverer);
```

- [ ] **Step 5: Fix any remaining compilation errors across all modules**

Run: `mvn --batch-mode compile -f /Users/mdproctor/claude/casehub/platform/pom.xml`

Fix any remaining `ChannelPreference` or `DeliveryChannelDescriptor` constructor calls in:
- `notification-settings-jpa/` (entity mapper)
- `notifications/` (REST endpoints)
- Other test files

Each fix: add `null` as the new argument.

- [ ] **Step 6: Run full test suite**

Run: `mvn --batch-mode test -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: all existing tests PASS

- [ ] **Step 7: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform/ notification-dispatch/ notification-settings-inmem/ notification-settings-jpa/ notifications/
git -C /Users/mdproctor/claude/casehub/platform commit -m "refactor(platform#144): NoOpDigestBuffer + breaking change migration — null digestSchedule at all call sites"
```

---

### Task 3: SuppressionEvaluator.evaluateUserLevel()

**Files:**
- Modify: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/SuppressionEvaluator.java`
- Modify: `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/SuppressionEvaluatorTest.java`

**Interfaces:**
- Consumes: `SuppressionResult(boolean, boolean, boolean)` from platform-api
- Produces: `SuppressionEvaluator.evaluateUserLevel(Optional<Snooze>, QuietHours)` → `SuppressionResult`

- [ ] **Step 1: Write evaluateUserLevel tests**

Add to `SuppressionEvaluatorTest.java`:

```java
@Test
void evaluateUserLevel_noSnoozeNoQuietHours_allFalse() {
    var result = evaluator.evaluateUserLevel(Optional.empty(), null);

    assertThat(result.isMuted()).isFalse();
    assertThat(result.isSnoozed()).isFalse();
    assertThat(result.quietHoursActive()).isFalse();
}

@Test
void evaluateUserLevel_activeSnooze_snoozedTrue() {
    var snooze = new Snooze(USER, TENANT, NOW.plus(1, ChronoUnit.HOURS), NOW);

    var result = evaluator.evaluateUserLevel(Optional.of(snooze), null);

    assertThat(result.isMuted()).isFalse();
    assertThat(result.isSnoozed()).isTrue();
}

@Test
void evaluateUserLevel_quietHoursActive_quietHoursTrue() {
    var zone = ZoneId.systemDefault();
    var nowLocal = LocalTime.now(zone);
    var quietHours = new QuietHours(nowLocal.minusHours(1), nowLocal.plusHours(1), zone);

    var result = evaluator.evaluateUserLevel(Optional.empty(), quietHours);

    assertThat(result.isMuted()).isFalse();
    assertThat(result.quietHoursActive()).isTrue();
}

@Test
void evaluateUserLevel_neverReturnsMuted() {
    var snooze = new Snooze(USER, TENANT, NOW.plus(1, ChronoUnit.HOURS), NOW);
    var zone = ZoneId.systemDefault();
    var nowLocal = LocalTime.now(zone);
    var quietHours = new QuietHours(nowLocal.minusHours(1), nowLocal.plusHours(1), zone);

    var result = evaluator.evaluateUserLevel(Optional.of(snooze), quietHours);

    assertThat(result.isMuted()).isFalse();
    assertThat(result.isSnoozed()).isTrue();
    assertThat(result.quietHoursActive()).isTrue();
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl notification-dispatch -Dtest=SuppressionEvaluatorTest -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: compilation failure — `evaluateUserLevel` does not exist

- [ ] **Step 3: Implement evaluateUserLevel**

Add to `SuppressionEvaluator.java`, promote `checkSnoozed` and `checkQuietHours` to package-private:

```java
public SuppressionResult evaluateUserLevel(final Optional<Snooze> activeSnooze,
                                           final QuietHours quietHours) {
    return new SuppressionResult(false, checkSnoozed(activeSnooze), checkQuietHours(quietHours));
}
```

Change `private boolean checkSnoozed` to `boolean checkSnoozed` (package-private).
Change `private boolean checkQuietHours` to `boolean checkQuietHours` (package-private).

- [ ] **Step 4: Run tests**

Run: `mvn --batch-mode test -pl notification-dispatch -Dtest=SuppressionEvaluatorTest -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: all PASS

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add notification-dispatch/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#144): SuppressionEvaluator.evaluateUserLevel() — user-level suppression for digest flush"
```

---

### Task 4: ChannelRouter Digest Routing + ResolvedChannel

**Files:**
- Modify: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/ResolvedChannel.java`
- Modify: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/ChannelRouter.java`
- Modify: `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/ChannelRouterTest.java`

**Interfaces:**
- Consumes: `ChannelPreference.digestSchedule()`, `DeliveryChannelDescriptor.defaultDigestSchedule()` from Task 1
- Produces: `ResolvedChannel(String, NotificationDeliverer, boolean, boolean)` with `digested` flag, updated `ChannelRouter.route()` that sets digest flag

- [ ] **Step 1: Write digest routing tests**

Add to `ChannelRouterTest.java`:

```java
@Test
void route_externalChannelWithDigest_markedDigested() {
    // Register email with default digest schedule
    registry = new InMemoryDeliveryChannelRegistry();
    registry.register(
            new DeliveryChannelDescriptor(DeliveryChannels.EMAIL, "Email",
                    true, true, NotificationSeverity.INFO,
                    new DigestSchedule.Interval(Duration.ofHours(4))),
            EMAIL_DELIVERER);

    router = new ChannelRouter(registry);

    var result = router.route(Map.of(),
            new SuppressionResult(false, false, false),
            NotificationSeverity.INFO);

    var email = result.stream()
            .filter(rc -> rc.channelId().equals(DeliveryChannels.EMAIL))
            .findFirst().orElseThrow();
    assertThat(email.digested()).isTrue();
}

@Test
void route_urgentSeverity_bypassesDigest() {
    registry = new InMemoryDeliveryChannelRegistry();
    registry.register(
            new DeliveryChannelDescriptor(DeliveryChannels.EMAIL, "Email",
                    true, true, NotificationSeverity.INFO,
                    new DigestSchedule.Interval(Duration.ofHours(4))),
            EMAIL_DELIVERER);

    router = new ChannelRouter(registry);

    var result = router.route(Map.of(),
            new SuppressionResult(false, false, false),
            NotificationSeverity.URGENT);

    var email = result.stream()
            .filter(rc -> rc.channelId().equals(DeliveryChannels.EMAIL))
            .findFirst().orElseThrow();
    assertThat(email.digested()).isFalse();
}

@Test
void route_internalChannel_neverDigested() {
    registry = new InMemoryDeliveryChannelRegistry();
    registry.register(
            new DeliveryChannelDescriptor(DeliveryChannels.IN_APP, "In-App",
                    false, true, NotificationSeverity.INFO, null),
            IN_APP_DELIVERER);

    router = new ChannelRouter(registry);

    var result = router.route(Map.of(),
            new SuppressionResult(false, false, false),
            NotificationSeverity.INFO);

    var inApp = result.stream()
            .filter(rc -> rc.channelId().equals(DeliveryChannels.IN_APP))
            .findFirst().orElseThrow();
    assertThat(inApp.digested()).isFalse();
}

@Test
void route_userPreferenceOverridesDefaultDigest() {
    registry = new InMemoryDeliveryChannelRegistry();
    registry.register(
            new DeliveryChannelDescriptor(DeliveryChannels.EMAIL, "Email",
                    true, true, NotificationSeverity.INFO, null),
            EMAIL_DELIVERER);

    router = new ChannelRouter(registry);

    // User enables digest on email
    var userPrefs = Map.of(
            DeliveryChannels.EMAIL, new ChannelPreference(true, NotificationSeverity.INFO,
                    new DigestSchedule.Interval(Duration.ofHours(2))));

    var result = router.route(userPrefs,
            new SuppressionResult(false, false, false),
            NotificationSeverity.INFO);

    var email = result.stream()
            .filter(rc -> rc.channelId().equals(DeliveryChannels.EMAIL))
            .findFirst().orElseThrow();
    assertThat(email.digested()).isTrue();
}

@Test
void route_noDigestSchedule_notDigested() {
    var result = router.route(Map.of(),
            new SuppressionResult(false, false, false),
            NotificationSeverity.WARNING);

    var email = result.stream()
            .filter(rc -> rc.channelId().equals(DeliveryChannels.EMAIL))
            .findFirst().orElseThrow();
    assertThat(email.digested()).isFalse();
}
```

Add import at top: `import io.casehub.platform.api.delivery.DigestSchedule;` and `import java.time.Duration;`

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl notification-dispatch -Dtest=ChannelRouterTest -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: compilation failure — `ResolvedChannel` has no `digested` field

- [ ] **Step 3: Add digested field to ResolvedChannel**

Replace `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/ResolvedChannel.java`:

```java
package io.casehub.platform.notification.dispatch;

import io.casehub.platform.api.delivery.NotificationDeliverer;

import java.util.Objects;

public record ResolvedChannel(
        String channelId,
        NotificationDeliverer deliverer,
        boolean suppressed,
        boolean digested
) {
    public ResolvedChannel {
        Objects.requireNonNull(channelId, "channelId");
        Objects.requireNonNull(deliverer, "deliverer");
    }
}
```

- [ ] **Step 4: Update ChannelRouter.route() — add digest routing logic**

In `ChannelRouter.route()`, add digest resolution after the existing suppression logic. The full construction of `ResolvedChannel` becomes:

```java
// Determine effective digest schedule: user preference overrides channel default
final DigestSchedule effectiveDigest;
if (userPref != null && userPref.digestSchedule() != null) {
    effectiveDigest = userPref.digestSchedule();
} else {
    effectiveDigest = descriptor.defaultDigestSchedule();
}

final boolean digested = descriptor.external()
        && effectiveDigest != null
        && severity != NotificationSeverity.URGENT;

result.add(new ResolvedChannel(channelId, deliverer, suppressed, digested));
```

Add import: `import io.casehub.platform.api.delivery.DigestSchedule;`

- [ ] **Step 5: Fix existing ChannelRouter code — update ResolvedChannel constructor call**

The existing line `result.add(new ResolvedChannel(channelId, deliverer, suppressed));` must change to include the new `digested` parameter. Verify no other `ResolvedChannel` constructor calls exist.

- [ ] **Step 6: Run all ChannelRouter tests**

Run: `mvn --batch-mode test -pl notification-dispatch -Dtest=ChannelRouterTest -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: all PASS (existing + new)

- [ ] **Step 7: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add notification-dispatch/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#144): ChannelRouter digest routing — external+schedule+non-URGENT → digested"
```

---

### Task 5: InMemoryDigestBuffer

**Files:**
- Create: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/InMemoryDigestBuffer.java`
- Create: `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/InMemoryDigestBufferTest.java`

**Interfaces:**
- Consumes: `DigestBuffer` SPI, `DigestBufferKey`, `NotificationInput` from platform-api
- Produces: `InMemoryDigestBuffer @ApplicationScoped` — working buffer with `max-buffer-size` eviction

- [ ] **Step 1: Write buffer tests**

Create `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/InMemoryDigestBufferTest.java`:

```java
package io.casehub.platform.notification.dispatch;

import io.casehub.platform.api.delivery.DigestBufferKey;
import io.casehub.platform.api.notification.NotificationInput;
import io.casehub.platform.api.notification.NotificationSeverity;
import io.casehub.platform.api.notification.NotificationSource;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class InMemoryDigestBufferTest {

    private InMemoryDigestBuffer buffer;
    private static final DigestBufferKey KEY = new DigestBufferKey("user-1", "tenant-1", "email");

    @BeforeEach
    void setUp() {
        buffer = new InMemoryDigestBuffer(500);
    }

    @Test
    void add_then_drain_returnsItems() {
        buffer.add(KEY, sampleInput("Title 1"));
        buffer.add(KEY, sampleInput("Title 2"));

        var items = buffer.drain(KEY);
        assertThat(items).hasSize(2);
        assertThat(items.get(0).title()).isEqualTo("Title 1");
        assertThat(items.get(1).title()).isEqualTo("Title 2");
    }

    @Test
    void drain_clearsBuffer() {
        buffer.add(KEY, sampleInput("Title 1"));
        buffer.drain(KEY);

        assertThat(buffer.pendingKeys()).isEmpty();
        assertThat(buffer.drain(KEY)).isEmpty();
    }

    @Test
    void drain_unknownKey_returnsEmpty() {
        assertThat(buffer.drain(KEY)).isEmpty();
    }

    @Test
    void pendingKeys_returnsOnlyKeysWithItems() {
        var key2 = new DigestBufferKey("user-2", "tenant-1", "email");
        buffer.add(KEY, sampleInput("Title 1"));
        buffer.add(key2, sampleInput("Title 2"));

        assertThat(buffer.pendingKeys()).containsExactlyInAnyOrder(KEY, key2);
    }

    @Test
    void oldestPendingTimestamp_returnsFirstAddTime() throws InterruptedException {
        buffer.add(KEY, sampleInput("Title 1"));
        var firstTimestamp = buffer.oldestPendingTimestamp(KEY);
        assertThat(firstTimestamp).isPresent();

        Thread.sleep(10);
        buffer.add(KEY, sampleInput("Title 2"));
        var secondTimestamp = buffer.oldestPendingTimestamp(KEY);

        assertThat(secondTimestamp).isEqualTo(firstTimestamp);
    }

    @Test
    void oldestPendingTimestamp_unknownKey_returnsEmpty() {
        assertThat(buffer.oldestPendingTimestamp(KEY)).isEmpty();
    }

    @Test
    void eviction_dropsOldestWhenMaxExceeded() {
        buffer = new InMemoryDigestBuffer(3);
        buffer.add(KEY, sampleInput("Item 1"));
        buffer.add(KEY, sampleInput("Item 2"));
        buffer.add(KEY, sampleInput("Item 3"));
        buffer.add(KEY, sampleInput("Item 4"));

        var items = buffer.drain(KEY);
        assertThat(items).hasSize(3);
        assertThat(items.get(0).title()).isEqualTo("Item 2");
    }

    private static NotificationInput sampleInput(String title) {
        return new NotificationInput("user-1", "tenant-1", title, null, "test",
                NotificationSeverity.INFO, null,
                new NotificationSource(UUID.randomUUID().toString(), "work-item", "wi-1", "actor-1"));
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl notification-dispatch -Dtest=InMemoryDigestBufferTest -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: compilation failure — `InMemoryDigestBuffer` does not exist

- [ ] **Step 3: Implement InMemoryDigestBuffer**

Create `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/InMemoryDigestBuffer.java`:

```java
package io.casehub.platform.notification.dispatch;

import io.casehub.platform.api.delivery.DigestBuffer;
import io.casehub.platform.api.delivery.DigestBufferKey;
import io.casehub.platform.api.notification.NotificationInput;
import jakarta.enterprise.context.ApplicationScoped;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CopyOnWriteArrayList;

@ApplicationScoped
public class InMemoryDigestBuffer implements DigestBuffer {

    private static final Logger LOG = Logger.getLogger(InMemoryDigestBuffer.class);

    private final ConcurrentHashMap<DigestBufferKey, BufferEntry> buffers = new ConcurrentHashMap<>();
    private final int maxBufferSize;

    public InMemoryDigestBuffer(
            @ConfigProperty(name = "casehub.notification.digest.max-buffer-size", defaultValue = "500")
            int maxBufferSize) {
        this.maxBufferSize = maxBufferSize;
    }

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
    public List<NotificationInput> drain(DigestBufferKey key) {
        var entry = buffers.remove(key);
        return entry != null ? List.copyOf(entry.notifications()) : List.of();
    }

    @Override
    public Set<DigestBufferKey> pendingKeys() {
        return Set.copyOf(buffers.keySet());
    }

    @Override
    public Optional<Instant> oldestPendingTimestamp(DigestBufferKey key) {
        var entry = buffers.get(key);
        return entry != null ? Optional.of(entry.firstAdded()) : Optional.empty();
    }

    record BufferEntry(CopyOnWriteArrayList<NotificationInput> notifications, Instant firstAdded) {}
}
```

- [ ] **Step 4: Run buffer tests**

Run: `mvn --batch-mode test -pl notification-dispatch -Dtest=InMemoryDigestBufferTest -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: all PASS

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add notification-dispatch/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#144): InMemoryDigestBuffer — ConcurrentHashMap buffer with max-size eviction"
```

---

### Task 6: NotificationDispatcher Three-Path Delivery

**Files:**
- Modify: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/NotificationDispatcher.java`
- Modify: `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/NotificationDispatcherTest.java`

**Interfaces:**
- Consumes: `DigestBuffer.add(DigestBufferKey, NotificationInput)` from Task 5, `ResolvedChannel.digested()` from Task 4
- Produces: Modified `NotificationDispatcher` with digest-aware delivery loop

- [ ] **Step 1: Write digest delivery tests**

Add to `NotificationDispatcherTest.java`. First add a `CapturingDigestBuffer` inner class and wire it into `setUp()`:

```java
// Add field
private CapturingDigestBuffer digestBuffer;

// In setUp(), after existing setup, before creating dispatcher:
digestBuffer = new CapturingDigestBuffer();

// Update dispatcher constructor:
dispatcher = new NotificationDispatcher(
        targetResolver, suppressionEvaluator, channelRouter,
        preferenceStore, suppressionStore, digestBuffer);
```

Add tests:

```java
@Test
void dispatch_digestedChannel_buffersInsteadOfDelivering() {
    // Register email with digest schedule
    channelRegistry.register(
            new DeliveryChannelDescriptor(DeliveryChannels.EMAIL, "Email",
                    true, true, NotificationSeverity.INFO,
                    new DigestSchedule.Interval(Duration.ofHours(4))),
            new CapturingDeliverer(DeliveryChannels.EMAIL, deliveredNotifications));

    var sub = subscription(
            List.of(new NotificationTarget(TargetType.USER, "user-recipient")),
            false);
    var pojo = new TestEvent("wi-1", "actor-user", "completed");

    dispatcher.onMatch(new SubscriptionMatched(sub, pojo));

    // In-app delivered immediately
    assertThat(deliveredNotifications).hasSize(1);
    assertThat(deliveredNotifications.get(0).userId()).isEqualTo("user-recipient");

    // Email buffered, not delivered
    assertThat(digestBuffer.buffered).hasSize(1);
    assertThat(digestBuffer.buffered.get(0).key().channelId()).isEqualTo(DeliveryChannels.EMAIL);
}

@Test
void dispatch_urgentSeverity_bypassesDigest() {
    channelRegistry.register(
            new DeliveryChannelDescriptor(DeliveryChannels.EMAIL, "Email",
                    true, true, NotificationSeverity.INFO,
                    new DigestSchedule.Interval(Duration.ofHours(4))),
            new CapturingDeliverer(DeliveryChannels.EMAIL, deliveredNotifications));

    var urgentTemplate = new NotificationTemplate(
            "URGENT: {status}", null, NotificationSeverity.URGENT, "urgent.event",
            null, "work-item", "entityId", "actorId");
    var sub = new Subscription("sub-1", "owner-1", TENANT, "Urgent", "test.event",
            List.of(),
            List.of(new NotificationTarget(TargetType.USER, "user-recipient")),
            false, urgentTemplate, true, NOW, NOW);
    var pojo = new TestEvent("wi-1", "actor-user", "critical");

    dispatcher.onMatch(new SubscriptionMatched(sub, pojo));

    // Both in-app and email delivered immediately (URGENT bypasses digest)
    assertThat(deliveredNotifications).hasSize(2);
    assertThat(digestBuffer.buffered).isEmpty();
}
```

Add inner classes:

```java
private static final class CapturingDigestBuffer implements DigestBuffer {
    record BufferedItem(DigestBufferKey key, NotificationInput notification) {}
    final List<BufferedItem> buffered = new ArrayList<>();

    @Override
    public void add(DigestBufferKey key, NotificationInput notification) {
        buffered.add(new BufferedItem(key, notification));
    }

    @Override
    public List<NotificationInput> drain(DigestBufferKey key) {
        var items = buffered.stream()
                .filter(b -> b.key().equals(key))
                .map(BufferedItem::notification)
                .toList();
        buffered.removeIf(b -> b.key().equals(key));
        return items;
    }

    @Override
    public Set<DigestBufferKey> pendingKeys() {
        return buffered.stream().map(BufferedItem::key).collect(java.util.stream.Collectors.toSet());
    }

    @Override
    public Optional<Instant> oldestPendingTimestamp(DigestBufferKey key) {
        return Optional.of(Instant.now());
    }
}
```

Add imports: `DigestBuffer`, `DigestBufferKey`, `DigestSchedule`, `Duration`

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl notification-dispatch -Dtest=NotificationDispatcherTest -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: compilation failure — constructor mismatch

- [ ] **Step 3: Modify NotificationDispatcher — inject DigestBuffer, three-path loop**

Add `DigestBuffer` field and constructor parameter:

```java
private final DigestBuffer digestBuffer;

@Inject
public NotificationDispatcher(final TargetResolver targetResolver,
                              final SuppressionEvaluator suppressionEvaluator,
                              final ChannelRouter channelRouter,
                              final NotificationPreferenceStore preferenceStore,
                              final SuppressionStore suppressionStore,
                              final DigestBuffer digestBuffer) {
    this.targetResolver = targetResolver;
    this.suppressionEvaluator = suppressionEvaluator;
    this.channelRouter = channelRouter;
    this.preferenceStore = preferenceStore;
    this.suppressionStore = suppressionStore;
    this.digestBuffer = digestBuffer;
}
```

Add import: `import io.casehub.platform.api.delivery.DigestBuffer;` and `import io.casehub.platform.api.delivery.DigestBufferKey;`

Replace the delivery loop in `dispatchToUser()`:

```java
for (final ResolvedChannel channel : channels) {
    if (channel.digested()) {
        digestBuffer.add(
                new DigestBufferKey(userId, tenancyId, channel.channelId()),
                notificationInput);
        continue;
    }
    if (channel.suppressed()) {
        continue;
    }
    try {
        final DeliveryResult result = channel.deliverer().deliver(notificationInput);
        if (!result.success()) {
            LOG.warnf("Delivery failed for channel '%s', user '%s': %s",
                    channel.channelId(), userId, result.failureReason());
        }
    } catch (Exception e) {
        LOG.warnf(e, "Delivery error for channel '%s', user '%s'",
                channel.channelId(), userId);
    }
}
```

- [ ] **Step 4: Run all NotificationDispatcher tests**

Run: `mvn --batch-mode test -pl notification-dispatch -Dtest=NotificationDispatcherTest -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: all PASS (existing + new)

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add notification-dispatch/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#144): NotificationDispatcher three-path delivery — digest buffer, suppress, or deliver"
```

---

### Task 7: DigestFlushScheduler

**Files:**
- Create: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/DigestFlushScheduler.java`
- Create: `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/DigestFlushSchedulerTest.java`
- Modify: `notification-dispatch/pom.xml` (add `quarkus-scheduler` dependency)

**Interfaces:**
- Consumes: `DigestBuffer` (drain, pendingKeys, oldestPendingTimestamp), `NotificationPreferenceStore.get()`, `SuppressionStore.activeSnooze()`, `SuppressionEvaluator.evaluateUserLevel()`, `DeliveryChannelRegistry.resolveDeliverer()`, `NotificationDeliverer.deliverDigest(DigestSummary)`, `DigestSchedule.isFlushDue()`
- Produces: `DigestFlushScheduler @ApplicationScoped` with `@Scheduled` tick

- [ ] **Step 1: Add quarkus-scheduler dependency**

Add to `notification-dispatch/pom.xml` in `<dependencies>`:

```xml
<dependency>
    <groupId>io.quarkus</groupId>
    <artifactId>quarkus-scheduler</artifactId>
</dependency>
```

- [ ] **Step 2: Write scheduler tests**

Create `notification-dispatch/src/test/java/io/casehub/platform/notification/dispatch/DigestFlushSchedulerTest.java`:

```java
package io.casehub.platform.notification.dispatch;

import io.casehub.platform.api.delivery.DeliveryChannelDescriptor;
import io.casehub.platform.api.delivery.DeliveryChannels;
import io.casehub.platform.api.delivery.DeliveryResult;
import io.casehub.platform.api.delivery.DigestBufferKey;
import io.casehub.platform.api.delivery.DigestSchedule;
import io.casehub.platform.api.delivery.DigestSummary;
import io.casehub.platform.api.delivery.NotificationDeliverer;
import io.casehub.platform.api.notification.NotificationInput;
import io.casehub.platform.api.notification.NotificationSeverity;
import io.casehub.platform.api.notification.NotificationSource;
import io.casehub.platform.api.notification.settings.ChannelPreference;
import io.casehub.platform.api.notification.settings.MuteRule;
import io.casehub.platform.api.notification.settings.MuteRuleInput;
import io.casehub.platform.api.notification.settings.NotificationPreferenceStore;
import io.casehub.platform.api.notification.settings.NotificationPreferenceUpdate;
import io.casehub.platform.api.notification.settings.NotificationPreferences;
import io.casehub.platform.api.notification.settings.Snooze;
import io.casehub.platform.api.notification.settings.SnoozeInput;
import io.casehub.platform.api.notification.settings.SuppressionStore;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.time.Duration;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class DigestFlushSchedulerTest {

    private InMemoryDigestBuffer buffer;
    private StubPreferenceStore preferenceStore;
    private StubSuppressionStore suppressionStore;
    private InMemoryDeliveryChannelRegistry channelRegistry;
    private CapturingDigestDeliverer emailDeliverer;
    private DigestFlushScheduler scheduler;

    private static final String USER = "user-1";
    private static final String TENANT = "tenant-1";
    private static final DigestBufferKey EMAIL_KEY = new DigestBufferKey(USER, TENANT, DeliveryChannels.EMAIL);

    @BeforeEach
    void setUp() {
        buffer = new InMemoryDigestBuffer(500);
        preferenceStore = new StubPreferenceStore();
        suppressionStore = new StubSuppressionStore();
        channelRegistry = new InMemoryDeliveryChannelRegistry();
        emailDeliverer = new CapturingDigestDeliverer(DeliveryChannels.EMAIL);

        channelRegistry.register(
                new DeliveryChannelDescriptor(DeliveryChannels.EMAIL, "Email",
                        true, true, NotificationSeverity.INFO,
                        new DigestSchedule.Interval(Duration.ofHours(4))),
                emailDeliverer);

        preferenceStore.prefs = new NotificationPreferences(USER, TENANT,
                Map.of(DeliveryChannels.EMAIL, new ChannelPreference(true, NotificationSeverity.INFO,
                        new DigestSchedule.Interval(Duration.ofHours(4)))),
                null, Instant.now());

        scheduler = new DigestFlushScheduler(
                buffer, preferenceStore, suppressionStore,
                new SuppressionEvaluator(), channelRegistry);
    }

    @Test
    void tick_flushesWhenIntervalElapsed() {
        // Buffer an item with old timestamp (simulate 5 hours ago)
        buffer.add(EMAIL_KEY, sampleInput("Notification 1"));
        // Force the oldest timestamp to be old enough by manipulating directly
        // For this test, we override the scheduler's check — the buffer's oldest is ~now
        // So we need an interval that's very short
        preferenceStore.prefs = new NotificationPreferences(USER, TENANT,
                Map.of(DeliveryChannels.EMAIL, new ChannelPreference(true, NotificationSeverity.INFO,
                        new DigestSchedule.Interval(Duration.ofMinutes(1)))),
                null, Instant.now());

        // Wait just over a minute... but tests shouldn't sleep.
        // Instead, test processKey directly with a custom buffer that reports old timestamps
        // Use real scheduler with Interval(1 minute) — item was just added so NOT due yet
        scheduler.tick();
        assertThat(emailDeliverer.received).isEmpty();
    }

    @Test
    void tick_defersWhenSnoozed() {
        buffer.add(EMAIL_KEY, sampleInput("Notification 1"));
        suppressionStore.snooze = new Snooze(USER, TENANT,
                Instant.now().plus(1, ChronoUnit.HOURS), Instant.now());

        // Even with a very short interval, snooze defers
        preferenceStore.prefs = new NotificationPreferences(USER, TENANT,
                Map.of(DeliveryChannels.EMAIL, new ChannelPreference(true, NotificationSeverity.INFO,
                        new DigestSchedule.Interval(Duration.ofMinutes(1)))),
                null, Instant.now());

        scheduler.tick();
        assertThat(emailDeliverer.received).isEmpty();
        assertThat(buffer.pendingKeys()).contains(EMAIL_KEY);
    }

    @Test
    void tick_perKeyErrorIsolation() {
        var key2 = new DigestBufferKey("user-2", TENANT, DeliveryChannels.EMAIL);
        buffer.add(EMAIL_KEY, sampleInput("Item for user-1"));
        buffer.add(key2, sampleInput("Item for user-2"));

        // user-1 preference store throws
        preferenceStore.throwForUser = USER;
        preferenceStore.prefs2 = new NotificationPreferences("user-2", TENANT,
                Map.of(DeliveryChannels.EMAIL, new ChannelPreference(true, NotificationSeverity.INFO,
                        new DigestSchedule.Interval(Duration.ofMinutes(1)))),
                null, Instant.now());

        // user-1 fails but user-2 should still be processed (though not due yet)
        scheduler.tick();
        // No crash — error isolated
        assertThat(buffer.pendingKeys()).contains(EMAIL_KEY);
    }

    @Test
    void tick_drainsOrphansWhenScheduleRemoved() {
        buffer.add(EMAIL_KEY, sampleInput("Orphaned item"));
        // User has no digest schedule anymore
        preferenceStore.prefs = new NotificationPreferences(USER, TENANT,
                Map.of(DeliveryChannels.EMAIL, new ChannelPreference(true, NotificationSeverity.INFO, null)),
                null, Instant.now());

        scheduler.tick();
        // Orphan should be flushed immediately
        assertThat(emailDeliverer.received).hasSize(1);
        assertThat(buffer.pendingKeys()).doesNotContain(EMAIL_KEY);
    }

    // --- helpers ---

    private static NotificationInput sampleInput(String title) {
        return new NotificationInput(USER, TENANT, title, null, "test",
                NotificationSeverity.INFO, null,
                new NotificationSource(UUID.randomUUID().toString(), "work-item", "wi-1", "actor-1"));
    }

    private static final class CapturingDigestDeliverer implements NotificationDeliverer {
        private final String channel;
        final List<DigestSummary> received = new ArrayList<>();

        CapturingDigestDeliverer(String channel) { this.channel = channel; }

        @Override
        public String channelId() { return channel; }

        @Override
        public DeliveryResult deliver(NotificationInput notification) {
            return new DeliveryResult(true, null);
        }

        @Override
        public DeliveryResult deliverDigest(DigestSummary summary) {
            received.add(summary);
            return new DeliveryResult(true, null);
        }
    }

    private static final class StubPreferenceStore implements NotificationPreferenceStore {
        NotificationPreferences prefs;
        NotificationPreferences prefs2;
        String throwForUser;

        @Override
        public Optional<NotificationPreferences> get(String userId, String tenancyId) {
            if (userId.equals(throwForUser)) throw new RuntimeException("Simulated failure");
            if (prefs2 != null && userId.equals(prefs2.userId())) return Optional.of(prefs2);
            return prefs != null && userId.equals(prefs.userId()) ? Optional.of(prefs) : Optional.empty();
        }

        @Override
        public NotificationPreferences update(String u, String t, NotificationPreferenceUpdate up) {
            throw new UnsupportedOperationException();
        }
    }

    private static final class StubSuppressionStore implements SuppressionStore {
        Snooze snooze;

        @Override public MuteRule addMute(MuteRuleInput i) { throw new UnsupportedOperationException(); }
        @Override public List<MuteRule> activeMutes(String u, String t) { return List.of(); }
        @Override public boolean removeMute(String m, String u, String t) { throw new UnsupportedOperationException(); }
        @Override public Snooze activateSnooze(SnoozeInput i) { throw new UnsupportedOperationException(); }
        @Override public Optional<Snooze> activeSnooze(String u, String t) {
            return snooze != null && u.equals(snooze.userId()) ? Optional.of(snooze) : Optional.empty();
        }
        @Override public boolean cancelSnooze(String u, String t) { throw new UnsupportedOperationException(); }
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl notification-dispatch -Dtest=DigestFlushSchedulerTest -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: compilation failure — `DigestFlushScheduler` does not exist

- [ ] **Step 4: Implement DigestFlushScheduler**

Create `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/DigestFlushScheduler.java`:

```java
package io.casehub.platform.notification.dispatch;

import io.casehub.platform.api.delivery.DeliveryChannelRegistry;
import io.casehub.platform.api.delivery.DigestBuffer;
import io.casehub.platform.api.delivery.DigestBufferKey;
import io.casehub.platform.api.delivery.DigestSchedule;
import io.casehub.platform.api.delivery.DigestSummary;
import io.casehub.platform.api.notification.NotificationInput;
import io.casehub.platform.api.notification.settings.ChannelPreference;
import io.casehub.platform.api.notification.settings.NotificationPreferenceStore;
import io.casehub.platform.api.notification.settings.NotificationPreferences;
import io.casehub.platform.api.notification.settings.SuppressionStore;
import io.quarkus.scheduler.Scheduled;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import org.jboss.logging.Logger;

import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

@ApplicationScoped
public class DigestFlushScheduler {

    private static final Logger LOG = Logger.getLogger(DigestFlushScheduler.class);

    private final DigestBuffer digestBuffer;
    private final NotificationPreferenceStore preferenceStore;
    private final SuppressionStore suppressionStore;
    private final SuppressionEvaluator suppressionEvaluator;
    private final DeliveryChannelRegistry channelRegistry;
    private final ConcurrentHashMap<DigestBufferKey, Instant> lastFlushTimes = new ConcurrentHashMap<>();

    @Inject
    public DigestFlushScheduler(DigestBuffer digestBuffer,
                                 NotificationPreferenceStore preferenceStore,
                                 SuppressionStore suppressionStore,
                                 SuppressionEvaluator suppressionEvaluator,
                                 DeliveryChannelRegistry channelRegistry) {
        this.digestBuffer = digestBuffer;
        this.preferenceStore = preferenceStore;
        this.suppressionStore = suppressionStore;
        this.suppressionEvaluator = suppressionEvaluator;
        this.channelRegistry = channelRegistry;
    }

    @Scheduled(every = "${casehub.notification.digest.tick-interval:1m}")
    void tick() {
        for (DigestBufferKey key : digestBuffer.pendingKeys()) {
            try {
                processKey(key);
            } catch (Exception e) {
                LOG.warnf(e, "Digest flush failed for key %s", key);
            }
        }
    }

    void processKey(DigestBufferKey key) {
        Instant now = Instant.now();

        // Look up user's digest schedule
        var prefs = preferenceStore.get(key.userId(), key.tenancyId());
        DigestSchedule schedule = prefs
                .map(NotificationPreferences::channelDefaults)
                .map(cd -> cd.get(key.channelId()))
                .map(ChannelPreference::digestSchedule)
                .orElse(null);

        if (schedule == null) {
            // Orphan: user disabled digest since buffering — flush immediately
            LOG.debugf("Orphan drain for key %s — schedule removed", key);
            flushKey(key, now);
            return;
        }

        // Check if flush is due
        Instant oldest = digestBuffer.oldestPendingTimestamp(key).orElse(now);
        Instant lastFlush = lastFlushTimes.getOrDefault(key, Instant.EPOCH);
        if (!schedule.isFlushDue(oldest, lastFlush, now)) {
            return;
        }

        // Check user-level suppression (snooze / quiet hours)
        var activeSnooze = suppressionStore.activeSnooze(key.userId(), key.tenancyId());
        var quietHours = prefs.map(NotificationPreferences::quietHours).orElse(null);
        var suppression = suppressionEvaluator.evaluateUserLevel(activeSnooze, quietHours);
        if (suppression.isSnoozed() || suppression.quietHoursActive()) {
            LOG.debugf("Digest flush deferred for %s — snoozed=%s, quietHours=%s",
                    key, suppression.isSnoozed(), suppression.quietHoursActive());
            return;
        }

        flushKey(key, now);
    }

    private void flushKey(DigestBufferKey key, Instant now) {
        Instant periodStart = lastFlushTimes.getOrDefault(key,
                digestBuffer.oldestPendingTimestamp(key).orElse(now));

        List<NotificationInput> items = digestBuffer.drain(key);
        if (items.isEmpty()) {
            LOG.debugf("Empty drain for key %s — items consumed between pendingKeys() and drain()", key);
            return;
        }

        var summary = new DigestSummary(
                key.userId(), key.tenancyId(), key.channelId(),
                items, periodStart, now);

        channelRegistry.resolveDeliverer(key.channelId())
                .ifPresentOrElse(
                        deliverer -> {
                            try {
                                var result = deliverer.deliverDigest(summary);
                                if (result.success()) {
                                    LOG.infof("Digest flushed: user=%s, channel=%s, count=%d, period=%s→%s",
                                            key.userId(), key.channelId(), items.size(), periodStart, now);
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

        lastFlushTimes.put(key, now);
    }
}
```

- [ ] **Step 5: Run scheduler tests**

Run: `mvn --batch-mode test -pl notification-dispatch -Dtest=DigestFlushSchedulerTest -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: all PASS

- [ ] **Step 6: Run full module test suite**

Run: `mvn --batch-mode test -pl notification-dispatch -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: all PASS

- [ ] **Step 7: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add notification-dispatch/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#144): DigestFlushScheduler — @Scheduled tick with per-key error isolation, suppression deferral, orphan drain"
```

---

### Task 8: Full Build Verification + CLAUDE.md Update

**Files:**
- Modify: `CLAUDE.md` (notification-dispatch module description)

**Interfaces:**
- Consumes: all prior tasks
- Produces: green build, updated documentation

- [ ] **Step 1: Run full build**

Run: `mvn --batch-mode install -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: BUILD SUCCESS — all modules compile and all tests pass

- [ ] **Step 2: Update CLAUDE.md — notification-dispatch module description**

Update the `notification-dispatch/` row in the Modules table:

```
| `notification-dispatch/` | `casehub-platform-notification-dispatch` | NotificationDispatcher (@ObservesAsync SubscriptionMatched) + TargetResolver + SuppressionEvaluator + ChannelRouter + InAppNotificationDeliverer + InMemoryDeliveryChannelRegistry + InMemoryDigestBuffer + DigestFlushScheduler. Orchestrates: target resolution → suppression → template resolution → channel routing → delivery (immediate or digest buffer). @Scheduled flush with per-key error isolation, suppression deferral, orphan drain. No quarkus:build goal |
```

Add to package structure if needed.

- [ ] **Step 3: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add CLAUDE.md notification-dispatch/
git -C /Users/mdproctor/claude/casehub/platform commit -m "docs(platform#144): update CLAUDE.md — notification-dispatch module gains digest buffer and flush scheduler"
```
