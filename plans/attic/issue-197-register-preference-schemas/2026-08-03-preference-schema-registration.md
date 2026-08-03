# Preference Schema Registration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #197 — register preference keys from domain modules
**Issue group:** #197

**Goal:** Define platform-level PreferenceKey constants, register their schemas, and migrate three retention schedulers from @ConfigProperty to PreferenceProvider reads.

**Architecture:** Six `IntPreference` keys defined as constants in `PlatformPreferenceKeys` (platform-api). A `PlatformPreferenceRegistrar` @Startup bean (platform/) registers `PreferenceSchemaDescriptor` entries. Three retention schedulers migrate from `@ConfigProperty` field injection to `PreferenceProvider.resolve().getOrDefault()` call-time resolution at platform-global scope (`Path.root()`).

**Tech Stack:** Java 21, Quarkus (CDI, @Scheduled), JPA, PreferenceProvider SPI

## Global Constraints

- `platform-api/` must remain zero-dependency — only standard Java types
- All preference keys use namespace `casehub.platform`
- All six keys are `IntPreference` with `IntPreference::parse`
- Resolve at platform-global scope: `new SettingsScope(Path.root(), Instant.now())`
- `getOrDefault()` for null-safe reads — never `get()` directly
- Keep per-source-type MicroProfile Config overrides in delivery-tracking-jpa (infrastructure, not migrated)
- `@ConfigProperty` for `claimTimeout` in delivery-tracking-jpa stays as-is (infrastructure)

---

### Task 1: PlatformPreferenceKeys Constants

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/preferences/PlatformPreferenceKeys.java`
- Test: `platform-api/src/test/java/io/casehub/platform/api/preferences/PlatformPreferenceKeysTest.java`

**Interfaces:**
- Consumes: `PreferenceKey<T>` record, `IntPreference` record
- Produces: Six `public static final PreferenceKey<IntPreference>` constants — `NOTIFICATION_RETENTION_DAYS`, `NOTIFICATION_UNREAD_RETENTION_DAYS`, `ACL_AUDIT_RETENTION_DAYS`, `DELIVERY_ATTEMPT_RETENTION_DAYS`, `DELIVERY_FAILED_RETENTION_DAYS`, `DELIVERY_ENGAGEMENT_RETENTION_DAYS`

- [ ] **Step 1: Write the test**

```java
package io.casehub.platform.api.preferences;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;

import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.*;

class PlatformPreferenceKeysTest {

    static Stream<Arguments> keys() {
        return Stream.of(
            Arguments.of(PlatformPreferenceKeys.NOTIFICATION_RETENTION_DAYS,
                         "notification.retention-days", 90),
            Arguments.of(PlatformPreferenceKeys.NOTIFICATION_UNREAD_RETENTION_DAYS,
                         "notification.unread-retention-days", 365),
            Arguments.of(PlatformPreferenceKeys.ACL_AUDIT_RETENTION_DAYS,
                         "acl.audit-retention-days", 365),
            Arguments.of(PlatformPreferenceKeys.DELIVERY_ATTEMPT_RETENTION_DAYS,
                         "delivery.attempt-retention-days", 30),
            Arguments.of(PlatformPreferenceKeys.DELIVERY_FAILED_RETENTION_DAYS,
                         "delivery.failed-retention-days", 365),
            Arguments.of(PlatformPreferenceKeys.DELIVERY_ENGAGEMENT_RETENTION_DAYS,
                         "delivery.engagement-retention-days", 90)
        );
    }

    @ParameterizedTest
    @MethodSource("keys")
    void key_has_correct_namespace_and_qualifiedName(PreferenceKey<IntPreference> key,
                                                     String expectedName, int expectedDefault) {
        assertEquals("casehub.platform", key.namespace());
        assertEquals(expectedName, key.name());
        assertEquals("casehub.platform." + expectedName, key.qualifiedName());
    }

    @ParameterizedTest
    @MethodSource("keys")
    void key_has_correct_default(PreferenceKey<IntPreference> key,
                                 String expectedName, int expectedDefault) {
        assertEquals(expectedDefault, key.defaultValue().value());
    }

    @ParameterizedTest
    @MethodSource("keys")
    void key_parser_round_trips(PreferenceKey<IntPreference> key,
                                String expectedName, int expectedDefault) {
        IntPreference parsed = key.parse(String.valueOf(expectedDefault));
        assertEquals(expectedDefault, parsed.value());
    }

    @Test
    void all_keys_have_unique_qualifiedNames() {
        var names = keys().map(a -> ((PreferenceKey<?>) a.get()[0]).qualifiedName()).toList();
        assertEquals(names.size(), names.stream().distinct().count());
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl platform-api -Dtest=PlatformPreferenceKeysTest`
Expected: FAIL — `PlatformPreferenceKeys` class does not exist

- [ ] **Step 3: Create PlatformPreferenceKeys**

Use `ide_create_file` to create:

```java
package io.casehub.platform.api.preferences;

public final class PlatformPreferenceKeys {

    public static final PreferenceKey<IntPreference> NOTIFICATION_RETENTION_DAYS =
            new PreferenceKey<>("casehub.platform", "notification.retention-days",
                    IntPreference.of(90), IntPreference::parse);

    public static final PreferenceKey<IntPreference> NOTIFICATION_UNREAD_RETENTION_DAYS =
            new PreferenceKey<>("casehub.platform", "notification.unread-retention-days",
                    IntPreference.of(365), IntPreference::parse);

    public static final PreferenceKey<IntPreference> ACL_AUDIT_RETENTION_DAYS =
            new PreferenceKey<>("casehub.platform", "acl.audit-retention-days",
                    IntPreference.of(365), IntPreference::parse);

    public static final PreferenceKey<IntPreference> DELIVERY_ATTEMPT_RETENTION_DAYS =
            new PreferenceKey<>("casehub.platform", "delivery.attempt-retention-days",
                    IntPreference.of(30), IntPreference::parse);

    public static final PreferenceKey<IntPreference> DELIVERY_FAILED_RETENTION_DAYS =
            new PreferenceKey<>("casehub.platform", "delivery.failed-retention-days",
                    IntPreference.of(365), IntPreference::parse);

    public static final PreferenceKey<IntPreference> DELIVERY_ENGAGEMENT_RETENTION_DAYS =
            new PreferenceKey<>("casehub.platform", "delivery.engagement-retention-days",
                    IntPreference.of(90), IntPreference::parse);

    private PlatformPreferenceKeys() {}
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode test -pl platform-api -Dtest=PlatformPreferenceKeysTest`
Expected: PASS — all 4 test methods green

- [ ] **Step 5: Commit**

```bash
git -C $PROJECT add platform-api/src/main/java/io/casehub/platform/api/preferences/PlatformPreferenceKeys.java platform-api/src/test/java/io/casehub/platform/api/preferences/PlatformPreferenceKeysTest.java
git -C $PROJECT commit -m "feat(#197): define PlatformPreferenceKeys — 6 retention preference key constants

Refs casehubio/platform#197"
```

---

### Task 2: PlatformPreferenceRegistrar

**Files:**
- Create: `platform/src/main/java/io/casehub/platform/preferences/PlatformPreferenceRegistrar.java`
- Test: `preferences-editor/src/test/java/io/casehub/platform/preferences/editor/PlatformPreferenceRegistrarTest.java`

**Interfaces:**
- Consumes: `PlatformPreferenceKeys.*` (6 constants from Task 1), `PreferenceSchemaDescriptor.of(key)` builder, `PreferenceSchemaRegistry.register()`, `PreferenceConstraintKeys.MIN/MAX`
- Produces: 6 registered `PreferenceSchemaDescriptor` entries in the schema registry at startup

- [ ] **Step 1: Write the integration test**

Test goes in `preferences-editor/` because `InMemoryPreferenceSchemaRegistry` (the real registry) lives there. `casehub-platform` is already a test dependency of `preferences-editor`, so CDI discovers `PlatformPreferenceRegistrar` automatically.

```java
package io.casehub.platform.preferences.editor;

import io.casehub.platform.api.preferences.PlatformPreferenceKeys;
import io.casehub.platform.api.preferences.PreferenceSchemaDescriptor;
import io.casehub.platform.api.preferences.PreferenceSchemaRegistry;
import io.quarkus.test.junit.QuarkusTest;
import jakarta.inject.Inject;
import org.junit.jupiter.api.Test;

import java.util.Set;

import static org.junit.jupiter.api.Assertions.*;

@QuarkusTest
class PlatformPreferenceRegistrarTest {

    @Inject PreferenceSchemaRegistry registry;

    @Test
    void all_platform_keys_are_registered() {
        Set<PreferenceSchemaDescriptor> all = registry.discover();
        var qualifiedNames = all.stream()
                .map(PreferenceSchemaDescriptor::qualifiedName)
                .filter(n -> n.startsWith("casehub.platform."))
                .toList();

        assertTrue(qualifiedNames.contains("casehub.platform.notification.retention-days"));
        assertTrue(qualifiedNames.contains("casehub.platform.notification.unread-retention-days"));
        assertTrue(qualifiedNames.contains("casehub.platform.acl.audit-retention-days"));
        assertTrue(qualifiedNames.contains("casehub.platform.delivery.attempt-retention-days"));
        assertTrue(qualifiedNames.contains("casehub.platform.delivery.failed-retention-days"));
        assertTrue(qualifiedNames.contains("casehub.platform.delivery.engagement-retention-days"));
    }

    @Test
    void notification_retention_descriptor_has_correct_shape() {
        var descriptor = registry.resolve("casehub.platform.notification.retention-days");
        assertTrue(descriptor.isPresent());
        var d = descriptor.get();
        assertEquals("casehub.platform", d.namespace());
        assertEquals("notification.retention-days", d.name());
        assertEquals("integer", d.type());
        assertEquals("90", d.defaultValue());
        assertFalse(d.multiValue());
        assertNotNull(d.label());
        assertNotNull(d.description());
        assertEquals(1, d.constraints().get("min"));
        assertEquals(3650, d.constraints().get("max"));
    }

    @Test
    void all_descriptors_have_labels_and_constraints() {
        for (var d : registry.discover()) {
            if (!d.qualifiedName().startsWith("casehub.platform.")) continue;
            assertNotNull(d.label(), d.qualifiedName() + " missing label");
            assertFalse(d.constraints().isEmpty(), d.qualifiedName() + " missing constraints");
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl preferences-editor -Dtest=PlatformPreferenceRegistrarTest`
Expected: FAIL — `PlatformPreferenceRegistrar` class does not exist, no registrations found

- [ ] **Step 3: Create PlatformPreferenceRegistrar**

Use `ide_create_file` to create:

```java
package io.casehub.platform.preferences;

import io.casehub.platform.api.preferences.PlatformPreferenceKeys;
import io.casehub.platform.api.preferences.PreferenceConstraintKeys;
import io.casehub.platform.api.preferences.PreferenceSchemaDescriptor;
import io.casehub.platform.api.preferences.PreferenceSchemaRegistry;
import io.quarkus.runtime.StartupEvent;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.event.Observes;
import jakarta.inject.Inject;

import java.util.Map;

@ApplicationScoped
public class PlatformPreferenceRegistrar {

    @Inject
    PreferenceSchemaRegistry registry;

    void onStart(@Observes StartupEvent event) {
        registry.register(PreferenceSchemaDescriptor.of(PlatformPreferenceKeys.NOTIFICATION_RETENTION_DAYS)
                .label("Notification retention (days)")
                .description("Days to retain read and dismissed notifications before purge")
                .constraints(Map.of(PreferenceConstraintKeys.MIN, 1, PreferenceConstraintKeys.MAX, 3650))
                .build());

        registry.register(PreferenceSchemaDescriptor.of(PlatformPreferenceKeys.NOTIFICATION_UNREAD_RETENTION_DAYS)
                .label("Unread notification retention (days)")
                .description("Days to retain unread notifications before purge")
                .constraints(Map.of(PreferenceConstraintKeys.MIN, 1, PreferenceConstraintKeys.MAX, 3650))
                .build());

        registry.register(PreferenceSchemaDescriptor.of(PlatformPreferenceKeys.ACL_AUDIT_RETENTION_DAYS)
                .label("ACL audit log retention (days)")
                .description("Days to retain ACL audit log entries before purge")
                .constraints(Map.of(PreferenceConstraintKeys.MIN, 30, PreferenceConstraintKeys.MAX, 3650))
                .build());

        registry.register(PreferenceSchemaDescriptor.of(PlatformPreferenceKeys.DELIVERY_ATTEMPT_RETENTION_DAYS)
                .label("Delivery attempt retention (days)")
                .description("Days to retain delivered and expired delivery attempts before purge")
                .constraints(Map.of(PreferenceConstraintKeys.MIN, 1, PreferenceConstraintKeys.MAX, 3650))
                .build());

        registry.register(PreferenceSchemaDescriptor.of(PlatformPreferenceKeys.DELIVERY_FAILED_RETENTION_DAYS)
                .label("Failed delivery retention (days)")
                .description("Days to retain failed delivery attempts before purge")
                .constraints(Map.of(PreferenceConstraintKeys.MIN, 30, PreferenceConstraintKeys.MAX, 3650))
                .build());

        registry.register(PreferenceSchemaDescriptor.of(PlatformPreferenceKeys.DELIVERY_ENGAGEMENT_RETENTION_DAYS)
                .label("Engagement event retention (days)")
                .description("Days to retain engagement events before purge")
                .constraints(Map.of(PreferenceConstraintKeys.MIN, 1, PreferenceConstraintKeys.MAX, 3650))
                .build());
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode test -pl preferences-editor -Dtest=PlatformPreferenceRegistrarTest`
Expected: PASS — all 3 tests green

- [ ] **Step 5: Run existing preferences-editor tests to check for regressions**

Run: `mvn --batch-mode test -pl preferences-editor`
Expected: All existing tests still pass. `PreferenceSchemaResourceTest` uses `greaterThanOrEqualTo(3)` for count, so additional registrations from PlatformPreferenceRegistrar are fine. The `sorted_by_qualifiedName` test checks `[0]`, `[1]`, `[2]` positions — platform keys sort before `casehub.work.*` test keys, so the indices shift. If that test fails, it needs updating to account for platform keys preceding work keys alphabetically.

- [ ] **Step 6: Commit**

```bash
git -C $PROJECT add platform/src/main/java/io/casehub/platform/preferences/PlatformPreferenceRegistrar.java preferences-editor/src/test/java/io/casehub/platform/preferences/editor/PlatformPreferenceRegistrarTest.java
git -C $PROJECT commit -m "feat(#197): PlatformPreferenceRegistrar — registers 6 retention schemas at startup

Refs casehubio/platform#197"
```

---

### Task 3: Migrate NotificationRetentionScheduler

**Files:**
- Modify: `notifications-jpa/src/main/java/io/casehub/platform/notification/jpa/NotificationRetentionScheduler.java`
- Create: `notifications-jpa/src/test/java/io/casehub/platform/notification/jpa/NotificationRetentionSchedulerTest.java`

**Interfaces:**
- Consumes: `PlatformPreferenceKeys.NOTIFICATION_RETENTION_DAYS`, `PlatformPreferenceKeys.NOTIFICATION_UNREAD_RETENTION_DAYS`, `PreferenceProvider.resolve(SettingsScope)`, `Preferences.getOrDefault(PreferenceKey)`, `Path.root()`, `SettingsScope`
- Produces: Retention purge now reads days from PreferenceProvider instead of @ConfigProperty

- [ ] **Step 1: Write the test**

```java
package io.casehub.platform.notification.jpa;

import io.casehub.platform.api.notification.NotificationStatus;
import io.quarkus.test.junit.QuarkusTest;
import jakarta.inject.Inject;
import jakarta.persistence.EntityManager;
import jakarta.transaction.Transactional;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;

@QuarkusTest
class NotificationRetentionSchedulerTest {

    @Inject NotificationRetentionScheduler scheduler;
    @Inject EntityManager em;

    @BeforeEach
    @Transactional
    void setUp() {
        em.createQuery("DELETE FROM NotificationEntity").executeUpdate();
    }

    @Test
    @Transactional
    void purge_removes_old_read_notifications_retains_recent() {
        insertNotification(NotificationStatus.READ, Instant.now().minus(100, ChronoUnit.DAYS));
        insertNotification(NotificationStatus.READ, Instant.now().minus(10, ChronoUnit.DAYS));

        scheduler.purge();

        long remaining = em.createQuery("SELECT COUNT(n) FROM NotificationEntity n", Long.class)
                           .getSingleResult();
        assertEquals(1, remaining);
    }

    @Test
    @Transactional
    void purge_removes_old_dismissed_notifications() {
        insertNotification(NotificationStatus.DISMISSED, Instant.now().minus(100, ChronoUnit.DAYS));
        insertNotification(NotificationStatus.DISMISSED, Instant.now().minus(10, ChronoUnit.DAYS));

        scheduler.purge();

        long remaining = em.createQuery("SELECT COUNT(n) FROM NotificationEntity n", Long.class)
                           .getSingleResult();
        assertEquals(1, remaining);
    }

    @Test
    @Transactional
    void purge_removes_old_unread_notifications_at_longer_retention() {
        insertNotification(NotificationStatus.UNREAD, Instant.now().minus(400, ChronoUnit.DAYS));
        insertNotification(NotificationStatus.UNREAD, Instant.now().minus(100, ChronoUnit.DAYS));

        scheduler.purge();

        long remaining = em.createQuery("SELECT COUNT(n) FROM NotificationEntity n", Long.class)
                           .getSingleResult();
        assertEquals(1, remaining);
    }

    @Test
    @Transactional
    void purge_no_old_notifications_deletes_nothing() {
        insertNotification(NotificationStatus.READ, Instant.now());
        insertNotification(NotificationStatus.UNREAD, Instant.now());

        scheduler.purge();

        long remaining = em.createQuery("SELECT COUNT(n) FROM NotificationEntity n", Long.class)
                           .getSingleResult();
        assertEquals(2, remaining);
    }

    private void insertNotification(NotificationStatus status, Instant createdAt) {
        NotificationEntity entity = new NotificationEntity();
        entity.id = UUID.randomUUID().toString();
        entity.userId = "user1";
        entity.tenancyId = "test-tenant";
        entity.title = "Test";
        entity.body = "Test body";
        entity.category = "test";
        entity.severity = io.casehub.platform.api.notification.NotificationSeverity.INFO;
        entity.status = status;
        entity.createdAt = createdAt;
        em.persist(entity);
    }
}
```

- [ ] **Step 2: Run test to verify it passes with current @ConfigProperty code**

Run: `mvn --batch-mode test -pl notifications-jpa -Dtest=NotificationRetentionSchedulerTest`
Expected: PASS — existing @ConfigProperty defaults (90, 365) produce same behavior as test expects

- [ ] **Step 3: Migrate NotificationRetentionScheduler to PreferenceProvider**

Use `ide_edit_member` and `ide_replace_member` to modify `NotificationRetentionScheduler`:

1. Remove `@ConfigProperty` fields `retentionDays` and `unreadRetentionDays`
2. Remove `org.eclipse.microprofile.config.inject.ConfigProperty` import
3. Add `@Inject PreferenceProvider preferenceProvider;` field
4. Add imports for `PreferenceProvider`, `PlatformPreferenceKeys`, `SettingsScope`, `Path`
5. Replace `purge()` body to read values from PreferenceProvider:

Replace the `purge()` method body with:

```java
        var prefs = preferenceProvider.resolve(new SettingsScope(Path.root(), Instant.now()));
        int retentionDays = prefs.getOrDefault(PlatformPreferenceKeys.NOTIFICATION_RETENTION_DAYS).value();
        int unreadRetentionDays = prefs.getOrDefault(PlatformPreferenceKeys.NOTIFICATION_UNREAD_RETENTION_DAYS).value();

        Instant readDismissedCutoff = Instant.now().minus(retentionDays, ChronoUnit.DAYS);
        Instant unreadCutoff        = Instant.now().minus(unreadRetentionDays, ChronoUnit.DAYS);

        LOG.infof("Starting notification retention purge: READ/DISMISSED < %s, UNREAD < %s",
                  readDismissedCutoff, unreadCutoff);

        int readDismissed = em.createQuery(
                                      "DELETE FROM NotificationEntity " +
                                      "WHERE status IN (:read, :dismissed) AND createdAt < :cutoff")
                              .setParameter("read", NotificationStatus.READ)
                              .setParameter("dismissed", NotificationStatus.DISMISSED)
                              .setParameter("cutoff", readDismissedCutoff)
                              .executeUpdate();

        int unread = em.createQuery(
                               "DELETE FROM NotificationEntity " +
                               "WHERE status = :unread AND createdAt < :cutoff")
                       .setParameter("unread", NotificationStatus.UNREAD)
                       .setParameter("cutoff", unreadCutoff)
                       .executeUpdate();

        LOG.infof("Notification retention purge completed: %d notifications deleted",
                  readDismissed + unread);
```

- [ ] **Step 4: Run test to verify it still passes**

Run: `mvn --batch-mode test -pl notifications-jpa -Dtest=NotificationRetentionSchedulerTest`
Expected: PASS — `MockPreferenceProvider` returns null for unset keys; `getOrDefault()` returns the key's built-in defaults (90, 365), same as the old @ConfigProperty defaults.

- [ ] **Step 5: Run full notifications-jpa test suite**

Run: `mvn --batch-mode test -pl notifications-jpa`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git -C $PROJECT add notifications-jpa/
git -C $PROJECT commit -m "feat(#197): migrate NotificationRetentionScheduler to PreferenceProvider

Replace @ConfigProperty with PreferenceProvider.resolve().getOrDefault() for
notification.retention-days and notification.unread-retention-days.

Refs casehubio/platform#197"
```

---

### Task 4: Migrate AclRetentionPurge

**Files:**
- Modify: `acl-jpa/src/main/java/io/casehub/platform/acl/jpa/AclRetentionPurge.java`
- Modify: `acl-jpa/src/test/java/io/casehub/platform/acl/jpa/AclRetentionPurgeTest.java`

**Interfaces:**
- Consumes: `PlatformPreferenceKeys.ACL_AUDIT_RETENTION_DAYS`, `PreferenceProvider.resolve(SettingsScope)`, `Preferences.getOrDefault(PreferenceKey)`, `Path.root()`, `SettingsScope`
- Produces: Audit log purge now reads days from PreferenceProvider instead of @ConfigProperty

- [ ] **Step 1: Verify existing test passes before migration**

Run: `mvn --batch-mode test -pl acl-jpa -Dtest=AclRetentionPurgeTest`
Expected: PASS — baseline green

- [ ] **Step 2: Migrate AclRetentionPurge to PreferenceProvider**

Use `ide_edit_member` and `ide_replace_member` to modify `AclRetentionPurge`:

1. Remove `@ConfigProperty` field `auditRetentionDays`
2. Remove `org.eclipse.microprofile.config.inject.ConfigProperty` import
3. Add `@Inject PreferenceProvider preferenceProvider;` field
4. Add imports for `PreferenceProvider`, `PlatformPreferenceKeys`, `Preferences`, `SettingsScope`, `Path`
5. Replace `purgeAuditLog()` body — read `auditRetentionDays` from PreferenceProvider:

```java
        var prefs = preferenceProvider.resolve(new SettingsScope(Path.root(), Instant.now()));
        int auditRetentionDays = prefs.getOrDefault(PlatformPreferenceKeys.ACL_AUDIT_RETENTION_DAYS).value();

        Instant cutoff = Instant.now().minus(Duration.ofDays(auditRetentionDays));
        int purged = entityManager.createQuery(
                                          "DELETE FROM AclAuditLogEntity e " +
                                          "WHERE e.performedAt < :cutoff")
                                  .setParameter("cutoff", cutoff)
                                  .executeUpdate();
        if (purged > 0) {
            LOG.infof("ACL audit log purge: %d records removed (older than %d days)", purged, auditRetentionDays);
        }
```

- [ ] **Step 3: Run existing test to verify it still passes**

Run: `mvn --batch-mode test -pl acl-jpa -Dtest=AclRetentionPurgeTest`
Expected: PASS — `MockPreferenceProvider` returns null; `getOrDefault()` returns 365 (same as old @ConfigProperty default). The existing test inserts an audit log entry 400 days old and expects it to be purged — still works.

- [ ] **Step 4: Run full acl-jpa test suite**

Run: `mvn --batch-mode test -pl acl-jpa`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git -C $PROJECT add acl-jpa/
git -C $PROJECT commit -m "feat(#197): migrate AclRetentionPurge to PreferenceProvider

Replace @ConfigProperty with PreferenceProvider.resolve().getOrDefault() for
acl.audit-retention-days.

Refs casehubio/platform#197"
```

---

### Task 5: Migrate JpaDeliveryAttemptStore Retention

**Files:**
- Modify: `delivery-tracking-jpa/src/main/java/io/casehub/platform/delivery/tracking/jpa/JpaDeliveryAttemptStore.java`
- Create: `delivery-tracking-jpa/src/test/java/io/casehub/platform/delivery/tracking/jpa/DeliveryRetentionPurgeTest.java`

**Interfaces:**
- Consumes: `PlatformPreferenceKeys.DELIVERY_ATTEMPT_RETENTION_DAYS`, `PlatformPreferenceKeys.DELIVERY_FAILED_RETENTION_DAYS`, `PlatformPreferenceKeys.DELIVERY_ENGAGEMENT_RETENTION_DAYS`, `PreferenceProvider`, `SettingsScope`, `Path`
- Produces: Retention purge defaults now come from PreferenceProvider; per-source-type MicroProfile Config overrides still take precedence

- [ ] **Step 1: Write the test**

```java
package io.casehub.platform.delivery.tracking.jpa;

import io.casehub.platform.api.delivery.DeliverySourceType;
import io.casehub.platform.api.delivery.DeliveryStatus;
import io.casehub.platform.api.delivery.DeliveryType;
import io.quarkus.test.junit.QuarkusTest;
import jakarta.inject.Inject;
import jakarta.persistence.EntityManager;
import jakarta.transaction.Transactional;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;

@QuarkusTest
class DeliveryRetentionPurgeTest {

    @Inject JpaDeliveryAttemptStore store;
    @Inject EntityManager em;

    @BeforeEach
    @Transactional
    void setUp() {
        em.createQuery("DELETE FROM EngagementEventEntity").executeUpdate();
        em.createQuery("DELETE FROM DeliveryAttemptEntity").executeUpdate();
    }

    @Test
    @Transactional
    void attemptRetentionPurge_removes_old_delivered_retains_recent() {
        insertAttempt(DeliveryStatus.DELIVERED, Instant.now().minus(60, ChronoUnit.DAYS));
        insertAttempt(DeliveryStatus.DELIVERED, Instant.now().minus(10, ChronoUnit.DAYS));

        store.attemptRetentionPurge();

        long remaining = em.createQuery("SELECT COUNT(e) FROM DeliveryAttemptEntity e", Long.class)
                           .getSingleResult();
        assertEquals(1, remaining);
    }

    @Test
    @Transactional
    void attemptRetentionPurge_failed_uses_longer_retention() {
        insertAttempt(DeliveryStatus.FAILED, Instant.now().minus(400, ChronoUnit.DAYS));
        insertAttempt(DeliveryStatus.FAILED, Instant.now().minus(100, ChronoUnit.DAYS));

        store.attemptRetentionPurge();

        long remaining = em.createQuery("SELECT COUNT(e) FROM DeliveryAttemptEntity e", Long.class)
                           .getSingleResult();
        assertEquals(1, remaining);
    }

    @Test
    @Transactional
    void engagementRetentionPurge_removes_old_engagement_events() {
        String attemptId = insertAttempt(DeliveryStatus.DELIVERED, Instant.now());
        insertEngagement(attemptId, Instant.now().minus(100, ChronoUnit.DAYS));
        insertEngagement(attemptId, Instant.now().minus(10, ChronoUnit.DAYS));

        store.engagementRetentionPurge();

        long remaining = em.createQuery("SELECT COUNT(e) FROM EngagementEventEntity e", Long.class)
                           .getSingleResult();
        assertEquals(1, remaining);
    }

    private String insertAttempt(DeliveryStatus status, Instant createdAt) {
        DeliveryAttemptEntity entity = new DeliveryAttemptEntity();
        entity.id = UUID.randomUUID().toString();
        entity.sourceId = "src-1";
        entity.sourceType = DeliverySourceType.NOTIFICATION;
        entity.channelId = "in_app";
        entity.userId = "user1";
        entity.tenancyId = "test-tenant";
        entity.deliveryType = DeliveryType.IMMEDIATE;
        entity.status = status;
        entity.attemptCount = 1;
        entity.createdAt = createdAt;
        entity.lastAttemptedAt = createdAt;
        em.persist(entity);
        return entity.id;
    }

    private void insertEngagement(String attemptId, Instant recordedAt) {
        EngagementEventEntity entity = new EngagementEventEntity();
        entity.id = UUID.randomUUID().toString();
        entity.attemptId = attemptId;
        entity.sourceId = "src-1";
        entity.sourceType = DeliverySourceType.NOTIFICATION;
        entity.channelId = "in_app";
        entity.userId = "user1";
        entity.tenancyId = "test-tenant";
        entity.type = io.casehub.platform.api.delivery.EngagementType.OPENED;
        entity.recordedAt = recordedAt;
        em.persist(entity);
    }
}
```

- [ ] **Step 2: Run test to verify it passes with current @ConfigProperty code**

Run: `mvn --batch-mode test -pl delivery-tracking-jpa -Dtest=DeliveryRetentionPurgeTest`
Expected: PASS — existing @ConfigProperty defaults (30, 365, 90) match test expectations

- [ ] **Step 3: Migrate JpaDeliveryAttemptStore retention to PreferenceProvider**

Use `ide_edit_member` and `ide_replace_member` to modify `JpaDeliveryAttemptStore`:

1. Remove three `@ConfigProperty` default fields: `defaultAttemptDays`, `defaultFailedAttemptDays`, `defaultEngagementDays`
2. Add `@Inject PreferenceProvider preferenceProvider;` field
3. Add imports for `PreferenceProvider`, `PlatformPreferenceKeys`, `SettingsScope`, `Path`
4. Change `resolveRetentionConfig` signature from `int defaultValue` to `PreferenceKey<IntPreference> defaultKey`:

```java
    private int resolveRetentionConfig(DeliverySourceType sourceType, String suffix, PreferenceKey<IntPreference> defaultKey) {
        String key = "casehub.delivery.retention.\"" + sourceType.name().toLowerCase() + "\"." + suffix;
        int prefDefault = preferenceProvider.resolve(new SettingsScope(Path.root(), Instant.now()))
                                            .getOrDefault(defaultKey).value();
        return config.getOptionalValue(key, Integer.class).orElse(prefDefault);
    }
```

5. Update callers in `attemptRetentionPurge()`:

```java
            int attemptDays = resolveRetentionConfig(sourceType, "attempt-days", PlatformPreferenceKeys.DELIVERY_ATTEMPT_RETENTION_DAYS);
            int failedDays  = resolveRetentionConfig(sourceType, "failed-attempt-days", PlatformPreferenceKeys.DELIVERY_FAILED_RETENTION_DAYS);
```

6. Update caller in `engagementRetentionPurge()`:

```java
            int engagementDays = resolveRetentionConfig(sourceType, "engagement-days", PlatformPreferenceKeys.DELIVERY_ENGAGEMENT_RETENTION_DAYS);
```

7. Add `PreferenceKey` import: `import io.casehub.platform.api.preferences.PreferenceKey;` and `import io.casehub.platform.api.preferences.IntPreference;`

- [ ] **Step 4: Run test to verify it still passes**

Run: `mvn --batch-mode test -pl delivery-tracking-jpa -Dtest=DeliveryRetentionPurgeTest`
Expected: PASS — same defaults via PreferenceProvider fallback

- [ ] **Step 5: Run full delivery-tracking-jpa test suite**

Run: `mvn --batch-mode test -pl delivery-tracking-jpa`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git -C $PROJECT add delivery-tracking-jpa/
git -C $PROJECT commit -m "feat(#197): migrate delivery retention purge to PreferenceProvider

Replace @ConfigProperty defaults with PreferenceProvider.resolve().getOrDefault()
for delivery retention days. Per-source-type MicroProfile Config overrides preserved.

Refs casehubio/platform#197"
```

---

### Task 6: Doc Updates, Full Build, and Follow-up Issue

**Files:**
- Modify: `docs/guides/consumer-guide.md` — add preference schema registration section
- Modify: `CLAUDE.md` — update `platform/` module description

**Interfaces:**
- Consumes: All previous tasks
- Produces: Updated documentation, follow-up issue filed

- [ ] **Step 1: Add "Registering preference schemas" to consumer-guide.md**

Add a new section after the existing preferences content showing the pattern:
- Define `PreferenceKey<T>` constants in a keys class
- Create `@ApplicationScoped` registrar with `@Observes StartupEvent`
- Build `PreferenceSchemaDescriptor.of(key).label(...).description(...).constraints(...).build()`
- Reference `PlatformPreferenceRegistrar` as the canonical example

- [ ] **Step 2: Update CLAUDE.md platform/ module description**

Add `PlatformPreferenceRegistrar @ApplicationScoped` to the `platform/` module entry.

- [ ] **Step 3: Run full build**

Run: `mvn --batch-mode install`
Expected: All modules compile and test green

- [ ] **Step 4: Commit doc updates**

```bash
git -C $PROJECT add docs/guides/consumer-guide.md CLAUDE.md
git -C $PROJECT commit -m "docs(#197): preference schema registration pattern in consumer guide

Refs casehubio/platform#197"
```

- [ ] **Step 5: File follow-up issue for remaining candidates**

```bash
gh issue create --repo casehubio/platform \
  --title "feat: register remaining platform preference schemas" \
  --body "Follow-up from #197. Remaining @ConfigProperty values identified as preference candidates:

- casehub.delivery.engagement.enabled (boolean) — notification-dispatch
- casehub.delivery.retry.max-retries (int) — notification-dispatch
- casehub.notification.digest.retention-days (int) — digest-jpa
- casehub.view.cache.ttl-seconds (int) — platform-view

Pattern established in #197: PlatformPreferenceKeys + PlatformPreferenceRegistrar." \
  --label "scale: S" --label "complexity: Low"
```
