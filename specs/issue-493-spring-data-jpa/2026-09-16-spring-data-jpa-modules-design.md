# Spring Data JPA Modules for Platform Persistence

**Issue:** casehubio/parent#493
**Date:** 2026-09-16
**Status:** Draft

## Problem

Platform has 10 JPA persistence modules using plain EntityManager under Quarkus Hibernate ORM. None have Spring Data JPA equivalents. Spring deployment requires these for data access.

## Architecture

### Three-Tier Module Pattern

Each JPA domain becomes three modules:

```
*-jpa-common          entities + Flyway SQL + shared helpers
     ↑                    (jakarta.persistence-api only)
     |
     ├── *-jpa            Quarkus store impl (existing, modified)
     |                    (quarkus-hibernate-orm)
     |
     └── *-spring-jpa     Spring Data store impl (new)
                          (spring-boot-starter-data-jpa)
```

Applied uniformly to all 10 domains.

### Module Inventory

| Domain | jpa-common contents | spring-jpa contents |
|--------|-------------------|-------------------|
| **acl** | 3 entities (AclEntryEntity, AclAuditLogEntity, ResourceParentEntity) + 1 key (ResourceParentKey) + V1 SQL | JpaRepository × 3, SpringAccessControlProvider, AclRetentionScheduler |
| **datasource** | 1 entity (DataSourceDescriptorEntity) + 1 key (RegistryKey) + V4000 SQL | JpaRepository × 1, SpringDataSourceRegistry |
| **delivery-tracking** | 2 entities (DeliveryAttemptEntity, EngagementEventEntity) + V3000 SQL | JpaRepository × 2, SpringDeliveryAttemptStore, RetentionScheduler |
| **digest** | 1 entity (DigestBufferEntity) + V2000 SQL | JpaRepository × 1, SpringDigestBuffer, RetentionScheduler |
| **memory** | 1 entity (MemoryEntry) + V1000/V1001 SQL | JpaRepository × 1, SpringCaseMemoryStore |
| **notification-settings** | 3 entities (NotificationPreferencesEntity, MuteRuleEntity, SnoozeEntity) + V1 SQL | JpaRepository × 3, SpringNotificationPreferenceStore, SpringSuppressionStore, RetentionScheduler |
| **notifications** | 1 entity (NotificationEntity) + V1 SQL | JpaRepository × 1, SpringNotificationStore, RetentionScheduler |
| **persistence** | 1 entity (PreferenceEntry) + V1 SQL | JpaRepository × 1, SpringPreferenceStore, SpringPreferenceProvider |
| **platform-view** | 2 entities (SubjectViewEntity, ViewMembershipEntity) + 2 helpers (LabelPatternPredicates, JpaLabelPatternQuerySupport) + V5000 SQL | JpaRepository × 2, SpringSubjectViewStore, SpringCrossTenantSubjectViewStore, SpringViewMembershipTracker |
| **subscriptions** | 1 entity (SubscriptionEntity) + V1 SQL | JpaRepository × 1, SpringSubscriptionStore |

**Totals:** 10 jpa-common modules + 10 spring-jpa modules = 20 new Maven modules. Existing 10 -jpa modules modified to depend on their -jpa-common.

### jpa-common Module Structure

Each jpa-common module contains:

- **Entity classes** — pure `jakarta.persistence` annotations, no Quarkus or Spring imports
- **Composite key classes** — records implementing `Serializable` (e.g., `ResourceParentKey`)
- **Flyway migration SQL** — same `classpath:db/*/migration/` paths as today
- **JPA Criteria API helpers** — framework-neutral (e.g., `LabelPatternPredicates`)

Dependencies: `jakarta.persistence-api` (provided scope), `casehub-platform-api` (where entity references SPI types).

No CDI, no Spring, no Quarkus. The entity classes are identical to today — they already use only standard JPA annotations.

### spring-jpa Module Structure

Each spring-jpa module contains:

```
src/main/java/io/casehub/platform/<domain>/spring/jpa/
  ├── <Entity>Repository.java          Spring Data JpaRepository interface
  ├── Spring<Store>.java               SPI implementation using repositories
  ├── <Domain>RetentionScheduler.java  @Scheduled retention (where applicable)
  └── <Domain>JpaAutoConfiguration.java  @AutoConfiguration

src/main/resources/
  └── META-INF/spring/
      └── org.springframework.boot.autoconfigure.AutoConfiguration.imports

src/test/java/...
  └── Spring<Store>Test.java           @DataJpaTest + H2 PostgreSQL mode
```

Dependencies:
- `*-jpa-common` (entities + SQL)
- `spring-boot-starter-data-jpa`
- `casehub-platform-api` (SPI interfaces)
- Test: `spring-boot-starter-test`, `com.h2database:h2`

### Query Style

Spring Data JPA repositories with derived query methods where possible, `@Query` for JPQL/native queries where Spring Data derived methods are insufficient:

```java
// Simple — derived query
public interface NotificationEntityRepository extends JpaRepository<NotificationEntity, String> {
    long countByUserIdAndTenancyIdAndStatus(String userId, String tenancyId, NotificationStatus status);
    List<NotificationEntity> findByUserIdAndTenancyIdOrderByCreatedAtDesc(String userId, String tenancyId);
}

// Complex — @Query
public interface AclEntryEntityRepository extends JpaRepository<AclEntryEntity, Long> {
    @Query("SELECT e FROM AclEntryEntity e WHERE e.actorId IN :actorIds AND e.resourceId = :resourceId AND e.tenancyId = :tenancyId AND (e.expiresAt IS NULL OR e.expiresAt > :now)")
    List<AclEntryEntity> findActiveByActorsAndResource(
            @Param("actorIds") Set<String> actorIds,
            @Param("resourceId") String resourceId,
            @Param("tenancyId") String tenancyId,
            @Param("now") Instant now);
}
```

Cursor-based pagination (notifications, delivery-tracking) uses custom `@Query` with the same keyset logic as the Quarkus implementations.

### Event Publishing

Store implementations that fire CDI events in the Quarkus modules use `ApplicationEventPublisher` in the Spring equivalents:

```java
@Service
public class SpringNotificationStore implements NotificationStore {
    private final NotificationEntityRepository repo;
    private final ApplicationEventPublisher events;

    // constructor injection

    @Override
    @Transactional
    public Notification store(NotificationInput input) {
        NotificationEntity entity = NotificationEntity.fromInput(input);
        repo.save(entity);
        Notification notification = entity.toNotification();
        events.publishEvent(new NotificationCreated(notification));
        return notification;
    }
}
```

The event record types (NotificationCreated, SubscriptionUpdated, etc.) are framework-neutral records from platform-api — used by both frameworks.

### Scheduled Tasks

5 modules have retention schedulers. Spring equivalents use `org.springframework.scheduling.annotation.Scheduled`:

```java
@Component
public class NotificationRetentionScheduler {
    private final NotificationEntityRepository repo;

    @Scheduled(cron = "${casehub.notification.jpa.retention-purge-cron:0 0 3 * * ?}")
    @Transactional
    public void purgeExpired() {
        // same logic as Quarkus counterpart
    }
}
```

Modules with schedulers: acl (2), notifications (1), notification-settings (1), digest (1), delivery-tracking (2).

### Auto-Configuration

Each module self-registers:

```java
@AutoConfiguration
@ConditionalOnClass(SpringNotificationStore.class)
@EnableJpaRepositories(basePackageClasses = NotificationEntityRepository.class)
public class NotificationsJpaAutoConfiguration {

    @Bean
    @ConditionalOnMissingBean(NotificationStore.class)
    public SpringNotificationStore springNotificationStore(
            NotificationEntityRepository repo,
            ApplicationEventPublisher events) {
        return new SpringNotificationStore(repo, events);
    }
}
```

`@ConditionalOnMissingBean` on SPI type ensures the JPA store only activates when no higher-priority implementation is present (mirrors `@DefaultBean` in Quarkus). Modules that are `@Alternative @Priority(1)` in Quarkus get `@Primary` in Spring.

### Flyway Configuration

Migration SQL stays in jpa-common under the existing paths (`db/acl/migration/`, `db/notification/migration/`, etc.). Spring Boot's Flyway auto-configuration discovers migrations on the classpath. Consumers configure `spring.flyway.locations` to include the relevant paths — identical to how Quarkus consumers configure `quarkus.flyway.locations`.

### Testing

`@DataJpaTest` with H2 in PostgreSQL mode (`spring.datasource.url=jdbc:h2:mem:test;MODE=PostgreSQL`). Each module's test verifies its SPI contract: store, query, update, delete.

PostgreSQL-only features (`websearch_to_tsquery` in memory-jpa, recursive CTEs in acl-jpa) get `@Disabled("PostgreSQL-only — covered by Quarkus integration tests")` with a note to revisit.

### Migration of Existing Modules

Existing `-jpa` modules are modified:
1. Entity classes and SQL files **move** to `-jpa-common`
2. `-jpa` pom.xml adds dependency on `-jpa-common`
3. Store implementations update imports (entity package changes from `*.jpa` to `*.jpa.common` or similar)
4. Tests remain in `-jpa` unchanged (they test the Quarkus store implementations)

This is a refactor with no behaviour change for existing `-jpa` modules.

### Complexity Assessment

| Module | Complexity | Notes |
|--------|-----------|-------|
| persistence-jpa | Low | 1 entity, simple CRUD |
| datasource-jpa | Low | 1 entity, simple CRUD + events |
| digest-jpa | Low | 1 entity, simple CRUD + scheduler |
| memory-jpa | Low | 1 entity, FTS needs @Disabled |
| notifications-jpa | Low | 1 entity, cursor pagination, 3 events |
| subscriptions-jpa | Low | 1 entity, JSON columns, 3 events |
| notification-settings-jpa | Med | 3 entities, 2 stores, JSON columns, scheduler |
| delivery-tracking-jpa | Med | 2 entities, SELECT FOR UPDATE, 2 schedulers |
| acl-jpa | Med | 3 entities, deny cascade, parent chain, recursive CTE, scheduler |
| platform-view-jpa | Med | 2 entities, Criteria API helpers, 3 stores, abstract query support |

### Build Order

jpa-common modules must build before both -jpa and -spring-jpa modules. The dependency graph:

```
platform-api
  └── *-jpa-common
        ├── *-jpa (existing)
        └── *-spring-jpa (new)
```

All 10 jpa-common modules are independent of each other. All 10 spring-jpa modules are independent of each other.

## Out of Scope

- Spring Data MongoDB equivalents (separate issue #498)
- Integration testing with real PostgreSQL (Testcontainers) — can be added later
- Performance benchmarking Spring vs Quarkus JPA stores
- Spring Data JPA auditing annotations (@CreatedDate, @LastModifiedDate) — keep entity annotations stable

## References

- casehubio/parent#493 — issue body
- casehubio/parent#501 — parent epic
- `persistence-jpa/src/main/java/.../PreferenceEntry.java` — example entity (pure JPA)
- `persistence-jpa/src/main/java/.../JpaPreferenceStore.java` — example Quarkus store
- `notifications-inmem-core/src/main/java/.../InMemoryNotificationStore.java` — core extraction pattern (Consumer<T>)
- `platform-spring/src/main/java/.../PlatformDefaultsManualConfig.java` — existing Spring auto-config
- `spring-generator/src/main/java/.../AutoConfigurationWriter.java` — generated auto-config pattern
- `spring-testing/src/main/java/.../SpringTestConfig.java` — existing Spring test fixtures
- D1–D7 in `specs/issue-493-spring-data-jpa/decisions.md`
