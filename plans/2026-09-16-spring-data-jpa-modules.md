# Spring Data JPA Modules Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** casehubio/parent#493 — Platform Spring Data JPA (10 modules)
**Issue group:** casehubio/parent#493 (part of epic #501)

**Goal:** Create Spring Data JPA equivalents for all 10 platform JPA persistence modules, enabling Spring Boot deployments to use the same database schemas.

**Architecture:** Three-tier pattern per domain: `*-jpa-common` (entities + Flyway SQL, jakarta.persistence-api only) shared between `*-jpa` (Quarkus, existing) and `*-spring-jpa` (Spring Data, new). Each spring-jpa module has JpaRepository interfaces, SPI-implementing store services, auto-configuration, and @DataJpaTest tests.

**Tech Stack:** Spring Data JPA 3.x, Spring Boot 3.x auto-configuration, H2 with PostgreSQL mode for testing, Flyway for migrations (shared SQL from jpa-common).

## Global Constraints

- jpa-common modules: `jakarta.persistence-api` (provided) + `casehub-platform-api` only — no Quarkus, no Spring
- spring-jpa modules: `spring-boot-starter-data-jpa` + jpa-common + platform-api
- Entity classes keep existing package names (same Java package, different Maven module)
- Flyway SQL stays at existing `classpath:db/*/migration/` paths
- Spring `@Transactional` is `org.springframework.transaction.annotation.Transactional` (not jakarta)
- Auto-config ordering: spring-jpa loads before `PlatformDefaultsManualConfig` (the mock fallback)
- Tests: `@DataJpaTest` + H2 `MODE=PostgreSQL`
- No `quarkus:build` goal in any new module

---

## Batch 1: Foundation — shared entity extraction

### Task 1: Extract entities and SQL to jpa-common modules, update existing jpa poms

**Files:** (per domain — 10 jpa-common modules created, 10 jpa pom.xml modified)

Create modules:
- `persistence-jpa-common/pom.xml`, move `PreferenceEntry.java` + `V1__*.sql`
- `acl-jpa-common/pom.xml`, move `AclEntryEntity.java`, `AclAuditLogEntity.java`, `ResourceParentEntity.java`, `ResourceParentKey.java` + `V1__*.sql`
- `datasource-jpa-common/pom.xml`, move `DataSourceDescriptorEntity.java`, `RegistryKey.java` + `V4000__*.sql`
- `delivery-tracking-jpa-common/pom.xml`, move `DeliveryAttemptEntity.java`, `EngagementEventEntity.java` + `V3000__*.sql`
- `digest-jpa-common/pom.xml`, move `DigestBufferEntity.java` + `V2000__*.sql`
- `memory-jpa-common/pom.xml`, move `MemoryEntry.java` + `V1000__*.sql`, `V1001__*.sql`
- `notification-settings-jpa-common/pom.xml`, move `NotificationPreferencesEntity.java`, `MuteRuleEntity.java`, `SnoozeEntity.java` + `V1__*.sql`
- `notifications-jpa-common/pom.xml`, move `NotificationEntity.java` + `V1__*.sql`
- `platform-view-jpa-common/pom.xml`, move `SubjectViewEntity.java`, `ViewMembershipEntity.java`, `LabelPatternPredicates.java`, `JpaLabelPatternQuerySupport.java` + `V5000__*.sql`
- `subscriptions-jpa-common/pom.xml`, move `SubscriptionEntity.java` + `V1__*.sql`

Modify: each existing `*-jpa/pom.xml` to depend on its `*-jpa-common`

**Interfaces:**
- Produces: All entity classes at their existing FQCNs, available via `*-jpa-common` dependency
- Produces: Flyway SQL at existing classpath locations

- [ ] **Step 1: Create the jpa-common pom.xml template**

Every jpa-common module follows the same pom structure. Here is `persistence-jpa-common/pom.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>

    <parent>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-platform-parent</artifactId>
        <version>0.2-SNAPSHOT</version>
    </parent>

    <artifactId>casehub-platform-persistence-jpa-common</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform Persistence JPA Common</name>
    <description>Shared JPA entities and Flyway migrations for preference persistence.</description>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-api</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>jakarta.persistence</groupId>
            <artifactId>jakarta.persistence-api</artifactId>
            <scope>provided</scope>
        </dependency>
    </dependencies>
</project>
```

Create the same structure for all 10 domains, substituting:

| Domain | artifactId | description |
|--------|-----------|-------------|
| persistence | `casehub-platform-persistence-jpa-common` | preference persistence |
| acl | `casehub-platform-acl-jpa-common` | ACL persistence |
| datasource | `casehub-platform-datasource-jpa-common` | data source persistence |
| delivery-tracking | `casehub-platform-delivery-tracking-jpa-common` | delivery tracking persistence |
| digest | `casehub-platform-digest-jpa-common` | digest buffer persistence |
| memory | `casehub-platform-memory-jpa-common` | case memory persistence |
| notification-settings | `casehub-platform-notification-settings-jpa-common` | notification settings persistence |
| notifications | `casehub-platform-notifications-jpa-common` | notification persistence |
| platform-view | `casehub-platform-platform-view-jpa-common` | subject view persistence |
| subscriptions | `casehub-platform-subscriptions-jpa-common` | subscription persistence |

Modules that reference Jackson (subscriptions-jpa-common entities use `ObjectMapper` for JSON columns, notification-settings-jpa-common entities use `@JdbcTypeCode`) add `com.fasterxml.jackson.core:jackson-databind` or `org.hibernate.orm:hibernate-core` as additional provided-scope dependencies.

- [ ] **Step 2: Move entity classes to jpa-common modules**

Use `ide_move_file` for each entity class. The Java package stays the same — only the Maven module changes:

| Source | Destination |
|--------|------------|
| `persistence-jpa/src/main/java/.../persistence/jpa/PreferenceEntry.java` | `persistence-jpa-common/src/main/java/.../persistence/jpa/PreferenceEntry.java` |
| `acl-jpa/src/main/java/.../acl/jpa/AclEntryEntity.java` | `acl-jpa-common/src/main/java/.../acl/jpa/AclEntryEntity.java` |
| `acl-jpa/src/main/java/.../acl/jpa/AclAuditLogEntity.java` | `acl-jpa-common/src/main/java/.../acl/jpa/AclAuditLogEntity.java` |
| `acl-jpa/src/main/java/.../acl/jpa/ResourceParentEntity.java` | `acl-jpa-common/src/main/java/.../acl/jpa/ResourceParentEntity.java` |
| `acl-jpa/src/main/java/.../acl/jpa/ResourceParentKey.java` | `acl-jpa-common/src/main/java/.../acl/jpa/ResourceParentKey.java` |
| `datasource-jpa/src/main/java/.../datasource/jpa/DataSourceDescriptorEntity.java` | `datasource-jpa-common/src/main/java/.../datasource/jpa/DataSourceDescriptorEntity.java` |
| `datasource-jpa/src/main/java/.../datasource/jpa/RegistryKey.java` | `datasource-jpa-common/src/main/java/.../datasource/jpa/RegistryKey.java` |
| `delivery-tracking-jpa/src/main/java/.../delivery/tracking/jpa/DeliveryAttemptEntity.java` | `delivery-tracking-jpa-common/src/main/java/.../delivery/tracking/jpa/DeliveryAttemptEntity.java` |
| `delivery-tracking-jpa/src/main/java/.../delivery/tracking/jpa/EngagementEventEntity.java` | `delivery-tracking-jpa-common/src/main/java/.../delivery/tracking/jpa/EngagementEventEntity.java` |
| `digest-jpa/src/main/java/.../delivery/digest/jpa/DigestBufferEntity.java` | `digest-jpa-common/src/main/java/.../delivery/digest/jpa/DigestBufferEntity.java` |
| `memory-jpa/src/main/java/.../memory/jpa/MemoryEntry.java` | `memory-jpa-common/src/main/java/.../memory/jpa/MemoryEntry.java` |
| `notification-settings-jpa/src/main/java/.../notification/settings/jpa/NotificationPreferencesEntity.java` | `notification-settings-jpa-common/src/main/java/.../notification/settings/jpa/NotificationPreferencesEntity.java` |
| `notification-settings-jpa/src/main/java/.../notification/settings/jpa/MuteRuleEntity.java` | `notification-settings-jpa-common/src/main/java/.../notification/settings/jpa/MuteRuleEntity.java` |
| `notification-settings-jpa/src/main/java/.../notification/settings/jpa/SnoozeEntity.java` | `notification-settings-jpa-common/src/main/java/.../notification/settings/jpa/SnoozeEntity.java` |
| `notifications-jpa/src/main/java/.../notification/jpa/NotificationEntity.java` | `notifications-jpa-common/src/main/java/.../notification/jpa/NotificationEntity.java` |
| `platform-view-jpa/src/main/java/.../view/jpa/SubjectViewEntity.java` | `platform-view-jpa-common/src/main/java/.../view/jpa/SubjectViewEntity.java` |
| `platform-view-jpa/src/main/java/.../view/jpa/ViewMembershipEntity.java` | `platform-view-jpa-common/src/main/java/.../view/jpa/ViewMembershipEntity.java` |
| `platform-view-jpa/src/main/java/.../view/jpa/LabelPatternPredicates.java` | `platform-view-jpa-common/src/main/java/.../view/jpa/LabelPatternPredicates.java` |
| `platform-view-jpa/src/main/java/.../view/jpa/JpaLabelPatternQuerySupport.java` | `platform-view-jpa-common/src/main/java/.../view/jpa/JpaLabelPatternQuerySupport.java` |
| `subscriptions-jpa/src/main/java/.../subscription/jpa/SubscriptionEntity.java` | `subscriptions-jpa-common/src/main/java/.../subscription/jpa/SubscriptionEntity.java` |

- [ ] **Step 3: Move Flyway SQL to jpa-common modules**

Move each `src/main/resources/db/*/migration/*.sql` directory from the `-jpa` module to the corresponding `-jpa-common` module. The classpath path (`db/*/migration/`) stays identical.

| Source | Destination |
|--------|------------|
| `persistence-jpa/src/main/resources/db/platform/migration/` | `persistence-jpa-common/src/main/resources/db/platform/migration/` |
| `acl-jpa/src/main/resources/db/acl/migration/` | `acl-jpa-common/src/main/resources/db/acl/migration/` |
| `datasource-jpa/src/main/resources/db/datasource/migration/` | `datasource-jpa-common/src/main/resources/db/datasource/migration/` |
| `delivery-tracking-jpa/src/main/resources/db/delivery-tracking/migration/` | `delivery-tracking-jpa-common/src/main/resources/db/delivery-tracking/migration/` |
| `digest-jpa/src/main/resources/db/digest/migration/` | `digest-jpa-common/src/main/resources/db/digest/migration/` |
| `memory-jpa/src/main/resources/db/memory/migration/` | `memory-jpa-common/src/main/resources/db/memory/migration/` |
| `notification-settings-jpa/src/main/resources/db/notification-settings/migration/` | `notification-settings-jpa-common/src/main/resources/db/notification-settings/migration/` |
| `notifications-jpa/src/main/resources/db/notification/migration/` | `notifications-jpa-common/src/main/resources/db/notification/migration/` |
| `platform-view-jpa/src/main/resources/db/view/migration/` | `platform-view-jpa-common/src/main/resources/db/view/migration/` |
| `subscriptions-jpa/src/main/resources/db/subscription/migration/` | `subscriptions-jpa-common/src/main/resources/db/subscription/migration/` |

- [ ] **Step 4: Add jpa-common dependency to each existing -jpa pom.xml**

Add to each existing `-jpa` module's pom.xml:

```xml
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-platform-{domain}-jpa-common</artifactId>
    <version>${project.version}</version>
</dependency>
```

- [ ] **Step 5: Add jpa-common modules to parent pom.xml**

Add all 10 jpa-common modules to the `<modules>` section of the parent pom.xml, ordered before their corresponding `-jpa` modules.

- [ ] **Step 6: Build and verify**

Run: `mvn --batch-mode install`
Expected: All existing modules compile and tests pass. Entity classes are now resolved via the jpa-common transitive dependency.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor: extract entities and Flyway SQL to jpa-common modules

Move entity classes and migration SQL from 10 -jpa modules into shared
-jpa-common counterparts. Existing -jpa modules depend on their common
module. No behaviour change — same packages, same classpath paths.

Refs casehubio/parent#493"
```

---

## Batch 2: Pattern establishment — persistence-spring-jpa

### Task 2: Create persistence-spring-jpa (full pattern example)

**Files:**
- Create: `persistence-spring-jpa/pom.xml`
- Create: `persistence-spring-jpa/src/main/java/io/casehub/platform/persistence/spring/jpa/PreferenceEntryRepository.java`
- Create: `persistence-spring-jpa/src/main/java/io/casehub/platform/persistence/spring/jpa/SpringPreferenceStore.java`
- Create: `persistence-spring-jpa/src/main/java/io/casehub/platform/persistence/spring/jpa/SpringPreferenceProvider.java`
- Create: `persistence-spring-jpa/src/main/java/io/casehub/platform/persistence/spring/jpa/PersistenceJpaAutoConfiguration.java`
- Create: `persistence-spring-jpa/src/main/resources/META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`
- Create: `persistence-spring-jpa/src/test/java/io/casehub/platform/persistence/spring/jpa/SpringPreferenceStoreTest.java`
- Create: `persistence-spring-jpa/src/test/resources/application.properties`
- Test: `persistence-spring-jpa/src/test/java/.../SpringPreferenceStoreTest.java`

**Interfaces:**
- Consumes: `PreferenceEntry` entity from `persistence-jpa-common`
- Produces: `PreferenceStore` and `PreferenceProvider` SPI implementations for Spring Boot

- [ ] **Step 1: Write the test**

Create `persistence-spring-jpa/src/test/resources/application.properties`:
```properties
spring.datasource.url=jdbc:h2:mem:test;MODE=PostgreSQL
spring.datasource.driver-class-name=org.h2.Driver
spring.jpa.hibernate.ddl-auto=none
spring.flyway.locations=classpath:db/platform/migration
```

Create `persistence-spring-jpa/src/test/java/io/casehub/platform/persistence/spring/jpa/SpringPreferenceStoreTest.java`:

```java
package io.casehub.platform.persistence.spring.jpa;

import io.casehub.platform.api.path.Path;
import io.casehub.platform.api.preferences.PreferenceQuery;
import io.casehub.platform.api.preferences.PreferenceRecord;
import io.casehub.platform.api.preferences.PreferenceStore;
import io.casehub.platform.api.preferences.SettingsScope;
import io.casehub.platform.mock.MockCurrentPrincipal;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.orm.jpa.DataJpaTest;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Import;

import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

@DataJpaTest
@Import(SpringPreferenceStoreTest.TestConfig.class)
class SpringPreferenceStoreTest {

    @Configuration
    static class TestConfig {
        @Bean
        MockCurrentPrincipal currentPrincipal() {
            return new MockCurrentPrincipal("test-user", List.of(), "tenant-1", false);
        }

        @Bean
        SpringPreferenceStore springPreferenceStore(
                PreferenceEntryRepository repo,
                MockCurrentPrincipal principal,
                ApplicationEventPublisher events) {
            return new SpringPreferenceStore(repo, principal, events);
        }

        @Bean
        SpringPreferenceProvider springPreferenceProvider(PreferenceEntryRepository repo) {
            return new SpringPreferenceProvider(repo);
        }
    }

    @Autowired PreferenceStore store;
    @Autowired SpringPreferenceProvider provider;

    @BeforeEach
    void setup() {
        store.set("tenant-1", Path.root(), "ui", "theme", "", "dark");
    }

    @Test
    void setAndList() {
        List<PreferenceRecord> records = store.list(new PreferenceQuery("tenant-1", Path.root(), "ui"));
        assertEquals(1, records.size());
        assertEquals("dark", records.getFirst().value());
    }

    @Test
    void deleteRemovesEntry() {
        store.delete("tenant-1", Path.root(), "ui", "theme", "");
        List<PreferenceRecord> records = store.list(new PreferenceQuery("tenant-1", Path.root(), "ui"));
        assertTrue(records.isEmpty());
    }

    @Test
    void resolveWalksHierarchy() {
        store.set("tenant-1", Path.parse("org/team"), "ui", "theme", "", "light");
        var prefs = provider.resolve(new SettingsScope("tenant-1", Path.parse("org/team"), null));
        assertEquals("light", prefs.get("ui.theme"));
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl persistence-spring-jpa`
Expected: FAIL — classes do not exist yet

- [ ] **Step 3: Create pom.xml**

Create `persistence-spring-jpa/pom.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>

    <parent>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-platform-parent</artifactId>
        <version>0.2-SNAPSHOT</version>
    </parent>

    <artifactId>casehub-platform-persistence-spring-jpa</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform Persistence Spring Data JPA</name>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-persistence-jpa-common</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-api</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-data-jpa</artifactId>
        </dependency>
        <dependency>
            <groupId>org.flywaydb</groupId>
            <artifactId>flyway-core</artifactId>
        </dependency>
        <dependency>
            <groupId>org.flywaydb</groupId>
            <artifactId>flyway-database-postgresql</artifactId>
        </dependency>

        <!-- Test -->
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-test</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>com.h2database</groupId>
            <artifactId>h2</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-core</artifactId>
            <version>${project.version}</version>
            <scope>test</scope>
        </dependency>
    </dependencies>
</project>
```

- [ ] **Step 4: Create repository interface**

Create `PreferenceEntryRepository.java`:

```java
package io.casehub.platform.persistence.spring.jpa;

import io.casehub.platform.persistence.jpa.PreferenceEntry;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;

import java.util.List;
import java.util.Optional;

public interface PreferenceEntryRepository extends JpaRepository<PreferenceEntry, Long> {

    Optional<PreferenceEntry> findByTenancyIdAndScopeAndNamespaceAndNameAndSubKey(
            String tenancyId, String scope, String namespace, String name, String subKey);

    List<PreferenceEntry> findByTenancyIdAndScopeAndNamespace(
            String tenancyId, String scope, String namespace);

    List<PreferenceEntry> findByTenancyIdAndScope(String tenancyId, String scope);

    List<PreferenceEntry> findByTenancyIdAndNamespace(String tenancyId, String namespace);

    List<PreferenceEntry> findByTenancyId(String tenancyId);

    List<PreferenceEntry> findByTenancyIdAndScopeIn(String tenancyId, List<String> scopes);

    @Modifying
    @Query("DELETE FROM PreferenceEntry e WHERE e.tenancyId = ?1 AND e.scope = ?2 AND e.namespace = ?3 AND e.name = ?4 AND e.subKey = ?5")
    int deleteByKey(String tenancyId, String scope, String namespace, String name, String subKey);

    @Modifying
    @Query("DELETE FROM PreferenceEntry e WHERE e.tenancyId = ?1 AND e.scope = ?2 AND e.namespace = ?3")
    int deleteByNamespace(String tenancyId, String scope, String namespace);
}
```

- [ ] **Step 5: Create SpringPreferenceStore**

Create `SpringPreferenceStore.java`:

```java
package io.casehub.platform.persistence.spring.jpa;

import io.casehub.platform.api.identity.CurrentPrincipal;
import io.casehub.platform.api.path.Path;
import io.casehub.platform.api.preferences.PreferenceChanged;
import io.casehub.platform.api.preferences.PreferencePermissions;
import io.casehub.platform.api.preferences.PreferenceQuery;
import io.casehub.platform.api.preferences.PreferenceRecord;
import io.casehub.platform.api.preferences.PreferenceStore;
import io.casehub.platform.persistence.jpa.PreferenceEntry;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

public class SpringPreferenceStore implements PreferenceStore {

    private final PreferenceEntryRepository repo;
    private final CurrentPrincipal principal;
    private final ApplicationEventPublisher events;

    public SpringPreferenceStore(PreferenceEntryRepository repo,
                                 CurrentPrincipal principal,
                                 ApplicationEventPublisher events) {
        this.repo = repo;
        this.principal = principal;
        this.events = events;
    }

    @Override
    @Transactional
    public void set(String tenancyId, Path scope, String namespace, String name, String subKey, String value) {
        PreferencePermissions.assertTenant(tenancyId, principal);
        String scopeValue = scope.value();
        PreferenceEntry existing = repo.findByTenancyIdAndScopeAndNamespaceAndNameAndSubKey(
                tenancyId, scopeValue, namespace, name, subKey).orElse(null);
        if (existing != null) {
            existing.value = value;
            repo.save(existing);
        } else {
            PreferenceEntry entry = new PreferenceEntry();
            entry.tenancyId = tenancyId;
            entry.scope = scopeValue;
            entry.namespace = namespace;
            entry.name = name;
            entry.subKey = subKey;
            entry.value = value;
            repo.save(entry);
        }
        events.publishEvent(new PreferenceChanged(tenancyId, scope, namespace));
    }

    @Override
    @Transactional
    public void delete(String tenancyId, Path scope, String namespace, String name, String subKey) {
        PreferencePermissions.assertTenant(tenancyId, principal);
        repo.deleteByKey(tenancyId, scope.value(), namespace, name, subKey);
        events.publishEvent(new PreferenceChanged(tenancyId, scope, namespace));
    }

    @Override
    @Transactional(readOnly = true)
    public List<PreferenceRecord> list(PreferenceQuery query) {
        String scopeValue = query.scope() != null ? query.scope().value() : null;
        List<PreferenceEntry> entries;
        if (scopeValue != null && query.namespace() != null) {
            entries = repo.findByTenancyIdAndScopeAndNamespace(query.tenancyId(), scopeValue, query.namespace());
        } else if (scopeValue != null) {
            entries = repo.findByTenancyIdAndScope(query.tenancyId(), scopeValue);
        } else if (query.namespace() != null) {
            entries = repo.findByTenancyIdAndNamespace(query.tenancyId(), query.namespace());
        } else {
            entries = repo.findByTenancyId(query.tenancyId());
        }
        return entries.stream()
                .map(e -> new PreferenceRecord(e.tenancyId, pathFromStored(e.scope), e.namespace, e.name, e.subKey, e.value))
                .toList();
    }

    @Override
    @Transactional
    public void deleteAll(String tenancyId, Path scope, String namespace) {
        PreferencePermissions.assertTenant(tenancyId, principal);
        repo.deleteByNamespace(tenancyId, scope.value(), namespace);
        events.publishEvent(new PreferenceChanged(tenancyId, scope, namespace));
    }

    private static Path pathFromStored(String stored) {
        return stored.isEmpty() ? Path.root() : Path.parse(stored);
    }
}
```

- [ ] **Step 6: Create SpringPreferenceProvider**

Create `SpringPreferenceProvider.java`:

```java
package io.casehub.platform.persistence.spring.jpa;

import io.casehub.platform.api.path.Path;
import io.casehub.platform.api.preferences.MapPreferences;
import io.casehub.platform.api.preferences.PreferenceProvider;
import io.casehub.platform.api.preferences.Preferences;
import io.casehub.platform.api.preferences.SettingsScope;
import io.casehub.platform.persistence.jpa.PreferenceEntry;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

public class SpringPreferenceProvider implements PreferenceProvider {

    private final PreferenceEntryRepository repo;

    public SpringPreferenceProvider(PreferenceEntryRepository repo) {
        this.repo = repo;
    }

    @Override
    @Transactional(readOnly = true)
    public Preferences resolve(SettingsScope scope) {
        List<String> ancestors = ancestors(scope.scope());
        List<PreferenceEntry> rows = repo.findByTenancyIdAndScopeIn(scope.tenancyId(), ancestors);

        Map<String, Integer> scopeOrder = new HashMap<>();
        for (int i = 0; i < ancestors.size(); i++) {
            scopeOrder.put(ancestors.get(i), i);
        }
        rows.sort((a, b) -> Integer.compare(
                scopeOrder.getOrDefault(a.scope, -1),
                scopeOrder.getOrDefault(b.scope, -1)));

        Map<String, Object> merged = new HashMap<>();
        for (PreferenceEntry row : rows) {
            String mapKey = row.subKey.isEmpty()
                    ? row.namespace + "." + row.name
                    : row.namespace + "." + row.name + "." + row.subKey;
            merged.put(mapKey, row.value);
        }
        return new MapPreferences(merged);
    }

    private static List<String> ancestors(Path path) {
        List<String> result = new ArrayList<>();
        Path current = path;
        while (current != null) {
            result.add(0, current.value());
            current = current.parent();
        }
        if (path.depth() > 0) {
            result.add(0, Path.root().value());
        }
        return result;
    }
}
```

- [ ] **Step 7: Create auto-configuration**

Create `PersistenceJpaAutoConfiguration.java`:

```java
package io.casehub.platform.persistence.spring.jpa;

import io.casehub.platform.api.identity.CurrentPrincipal;
import io.casehub.platform.api.preferences.PreferenceProvider;
import io.casehub.platform.api.preferences.PreferenceStore;
import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnClass;
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.context.annotation.Bean;
import org.springframework.data.jpa.repository.config.EnableJpaRepositories;

@AutoConfiguration
@ConditionalOnClass(SpringPreferenceStore.class)
@EnableJpaRepositories(basePackageClasses = PreferenceEntryRepository.class)
public class PersistenceJpaAutoConfiguration {

    @Bean
    @ConditionalOnMissingBean(PreferenceStore.class)
    public SpringPreferenceStore springPreferenceStore(
            PreferenceEntryRepository repo,
            CurrentPrincipal principal,
            ApplicationEventPublisher events) {
        return new SpringPreferenceStore(repo, principal, events);
    }

    @Bean
    @ConditionalOnMissingBean(PreferenceProvider.class)
    public SpringPreferenceProvider springPreferenceProvider(PreferenceEntryRepository repo) {
        return new SpringPreferenceProvider(repo);
    }
}
```

Create `src/main/resources/META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`:

```
io.casehub.platform.persistence.spring.jpa.PersistenceJpaAutoConfiguration
```

- [ ] **Step 8: Add module to parent pom.xml, build, and run tests**

Add `persistence-spring-jpa` to the parent pom `<modules>` section.

Run: `mvn --batch-mode test -pl persistence-spring-jpa`
Expected: PASS — all 3 tests green

- [ ] **Step 9: Commit**

```bash
git add persistence-spring-jpa/
git commit -m "feat: add persistence-spring-jpa — Spring Data JPA PreferenceStore + PreferenceProvider

Implements PreferenceStore and PreferenceProvider SPIs using Spring Data
JPA repositories. Shares entities and Flyway SQL via persistence-jpa-common.
Auto-configured via @ConditionalOnMissingBean.

Refs casehubio/parent#493"
```

---

## Batch 3: Simple CRUD modules

### Task 3: Create digest-spring-jpa

**Files:**
- Create: `digest-spring-jpa/pom.xml`
- Create: `digest-spring-jpa/src/main/java/io/casehub/platform/delivery/digest/spring/jpa/DigestBufferEntityRepository.java`
- Create: `digest-spring-jpa/src/main/java/io/casehub/platform/delivery/digest/spring/jpa/SpringDigestBuffer.java`
- Create: `digest-spring-jpa/src/main/java/io/casehub/platform/delivery/digest/spring/jpa/DigestRetentionScheduler.java`
- Create: `digest-spring-jpa/src/main/java/io/casehub/platform/delivery/digest/spring/jpa/DigestJpaAutoConfiguration.java`
- Create: standard resources (imports file, test application.properties)
- Test: `digest-spring-jpa/src/test/java/.../SpringDigestBufferTest.java`

**Interfaces:**
- Consumes: `DigestBufferEntity` from `digest-jpa-common`, `DigestBuffer` SPI from `platform-api`
- Produces: `DigestBuffer` implementation for Spring Boot

Quarkus counterpart: `digest-jpa/src/main/java/io/casehub/platform/delivery/digest/jpa/JpaDigestBuffer.java`

Follow the pattern from Task 2 — pom.xml with `digest-jpa-common` dependency, repository interface for `DigestBufferEntity`, `SpringDigestBuffer` implementing `DigestBuffer` SPI, `DigestRetentionScheduler` with `@Scheduled(cron = "0 0 3 * * ?")`, and `DigestJpaAutoConfiguration`. The Quarkus counterpart at the path above is the implementation reference for all SPI method translations.

- [ ] **Step 1: Write @DataJpaTest for DigestBuffer SPI contract (add, drain, pendingKeys)**
- [ ] **Step 2: Run test to verify it fails**
- [ ] **Step 3: Create pom.xml, repository, store, scheduler, and auto-config**
- [ ] **Step 4: Run tests to verify they pass**
- [ ] **Step 5: Commit**

### Task 4: Create memory-spring-jpa

**Files:**
- Create: `memory-spring-jpa/pom.xml`
- Create: `memory-spring-jpa/src/main/java/io/casehub/platform/memory/spring/jpa/MemoryEntryRepository.java`
- Create: `memory-spring-jpa/src/main/java/io/casehub/platform/memory/spring/jpa/SpringCaseMemoryStore.java`
- Create: `memory-spring-jpa/src/main/java/io/casehub/platform/memory/spring/jpa/MemoryJpaAutoConfiguration.java`
- Create: standard resources
- Test: `memory-spring-jpa/src/test/java/.../SpringCaseMemoryStoreTest.java`

**Interfaces:**
- Consumes: `MemoryEntry` from `memory-jpa-common`, `CaseMemoryStore` SPI from `platform-api`
- Produces: `CaseMemoryStore` implementation for Spring Boot

Quarkus counterpart: `memory-jpa/src/main/java/io/casehub/platform/memory/jpa/JpaCaseMemoryStore.java`

FTS queries (`websearch_to_tsquery`) are PostgreSQL-specific. For the Spring implementation:
- CRUD methods (store, storeAll, erase, eraseAll) use repository directly
- RELEVANCE-order queries with a question parameter: use `@Query` with native SQL. In the test, mark FTS tests with `@Disabled("PostgreSQL-only — websearch_to_tsquery")`.
- CHRONOLOGICAL queries without FTS work with standard JPQL.

- [ ] **Step 1: Write @DataJpaTest for CaseMemoryStore SPI contract (store, find by entity, erase)**
- [ ] **Step 2: Run test to verify it fails**
- [ ] **Step 3: Create pom.xml, repository, store, and auto-config**
- [ ] **Step 4: Run tests to verify they pass (FTS tests @Disabled)**
- [ ] **Step 5: Commit**

---

## Batch 4: Event-publishing modules

### Task 5: Create notifications-spring-jpa

**Files:**
- Create: `notifications-spring-jpa/pom.xml`
- Create: `notifications-spring-jpa/src/main/java/io/casehub/platform/notification/spring/jpa/NotificationEntityRepository.java`
- Create: `notifications-spring-jpa/src/main/java/io/casehub/platform/notification/spring/jpa/SpringNotificationStore.java`
- Create: `notifications-spring-jpa/src/main/java/io/casehub/platform/notification/spring/jpa/NotificationRetentionScheduler.java`
- Create: `notifications-spring-jpa/src/main/java/io/casehub/platform/notification/spring/jpa/NotificationsJpaAutoConfiguration.java`
- Create: standard resources
- Test: `notifications-spring-jpa/src/test/java/.../SpringNotificationStoreTest.java`

**Interfaces:**
- Consumes: `NotificationEntity` from `notifications-jpa-common`, `NotificationStore` SPI
- Produces: `NotificationStore` implementation — 3 event types (NotificationCreated, NotificationStatusChanged, AllNotificationsRead)

Quarkus counterpart: `notifications-jpa/src/main/java/io/casehub/platform/notification/jpa/JpaNotificationStore.java`

Key implementation details:
- Cursor-based pagination in `find()`: keyset on `(createdAt DESC, id DESC)` with Base64-encoded cursor. Use `@Query` with dynamic JPQL.
- `storeAll()`: iterate and `repo.save()` each, fire event per notification
- Events: `ApplicationEventPublisher.publishEvent()` for all 3 event types

- [ ] **Step 1: Write @DataJpaTest for NotificationStore SPI (store, find with cursor, unreadCount, markRead, dismiss, markAllRead)**
- [ ] **Step 2: Run test to verify it fails**
- [ ] **Step 3: Create pom.xml, repository, store, scheduler, and auto-config**
- [ ] **Step 4: Run tests to verify they pass**
- [ ] **Step 5: Commit**

### Task 6: Create subscriptions-spring-jpa + datasource-spring-jpa

**Files (subscriptions):**
- Create: `subscriptions-spring-jpa/pom.xml`
- Create: `subscriptions-spring-jpa/src/main/java/io/casehub/platform/subscription/spring/jpa/SubscriptionEntityRepository.java`
- Create: `subscriptions-spring-jpa/src/main/java/io/casehub/platform/subscription/spring/jpa/SpringSubscriptionStore.java`
- Create: `subscriptions-spring-jpa/src/main/java/io/casehub/platform/subscription/spring/jpa/SubscriptionsJpaAutoConfiguration.java`
- Test: `subscriptions-spring-jpa/src/test/java/.../SpringSubscriptionStoreTest.java`

**Files (datasource):**
- Create: `datasource-spring-jpa/pom.xml`
- Create: `datasource-spring-jpa/src/main/java/io/casehub/platform/datasource/spring/jpa/DataSourceDescriptorEntityRepository.java`
- Create: `datasource-spring-jpa/src/main/java/io/casehub/platform/datasource/spring/jpa/SpringDataSourceRegistry.java`
- Create: `datasource-spring-jpa/src/main/java/io/casehub/platform/datasource/spring/jpa/DataSourceJpaAutoConfiguration.java`
- Test: `datasource-spring-jpa/src/test/java/.../SpringDataSourceRegistryTest.java`

**Interfaces:**
- subscriptions: `SubscriptionStore` SPI + 3 events (Created, Updated, Deleted). Uses `ObjectMapper` for JSON column serialization.
- datasource: `DataSourceRegistry` SPI + 3 events. Has startup reconciliation (`@EventListener(ApplicationReadyEvent.class)`), in-memory `ConcurrentHashMap` caching, depends on `datasource-alpha` for `AlphaDataSource`.

Quarkus counterparts:
- `subscriptions-jpa/src/main/java/.../JpaSubscriptionStore.java`
- `datasource-jpa/src/main/java/.../JpaDataSourceRegistry.java`

Key for subscriptions: cursor pagination (same pattern as notifications), JSON column serialization via `ObjectMapper`.

Key for datasource: `@EventListener(ApplicationReadyEvent.class)` replaces `@Observes StartupEvent`. ConcurrentHashMap caching logic is identical. Additional dependency on `casehub-platform-datasource-alpha`.

- [ ] **Step 1: Write tests for both modules**
- [ ] **Step 2: Run tests to verify they fail**
- [ ] **Step 3: Create pom.xml, repositories, stores, and auto-configs for both**
- [ ] **Step 4: Run tests to verify they pass**
- [ ] **Step 5: Commit**

---

## Batch 5: Complex modules

### Task 7: Create notification-settings-spring-jpa + delivery-tracking-spring-jpa

**Files (notification-settings):**
- Create: `notification-settings-spring-jpa/pom.xml`
- Create: `notification-settings-spring-jpa/src/main/java/io/casehub/platform/notification/settings/spring/jpa/NotificationPreferencesEntityRepository.java`
- Create: `notification-settings-spring-jpa/src/main/java/io/casehub/platform/notification/settings/spring/jpa/MuteRuleEntityRepository.java`
- Create: `notification-settings-spring-jpa/src/main/java/io/casehub/platform/notification/settings/spring/jpa/SnoozeEntityRepository.java`
- Create: `notification-settings-spring-jpa/src/main/java/io/casehub/platform/notification/settings/spring/jpa/SpringNotificationPreferenceStore.java`
- Create: `notification-settings-spring-jpa/src/main/java/io/casehub/platform/notification/settings/spring/jpa/SpringSuppressionStore.java`
- Create: `notification-settings-spring-jpa/src/main/java/io/casehub/platform/notification/settings/spring/jpa/SuppressionRetentionScheduler.java`
- Create: `notification-settings-spring-jpa/src/main/java/io/casehub/platform/notification/settings/spring/jpa/NotificationSettingsJpaAutoConfiguration.java`
- Test: `notification-settings-spring-jpa/src/test/java/.../SpringNotificationPreferenceStoreTest.java`

**Files (delivery-tracking):**
- Create: `delivery-tracking-spring-jpa/pom.xml`
- Create: `delivery-tracking-spring-jpa/src/main/java/io/casehub/platform/delivery/tracking/spring/jpa/DeliveryAttemptEntityRepository.java`
- Create: `delivery-tracking-spring-jpa/src/main/java/io/casehub/platform/delivery/tracking/spring/jpa/EngagementEventEntityRepository.java`
- Create: `delivery-tracking-spring-jpa/src/main/java/io/casehub/platform/delivery/tracking/spring/jpa/SpringDeliveryAttemptStore.java`
- Create: `delivery-tracking-spring-jpa/src/main/java/io/casehub/platform/delivery/tracking/spring/jpa/DeliveryTrackingRetentionScheduler.java`
- Create: `delivery-tracking-spring-jpa/src/main/java/io/casehub/platform/delivery/tracking/spring/jpa/DeliveryTrackingJpaAutoConfiguration.java`
- Test: `delivery-tracking-spring-jpa/src/test/java/.../SpringDeliveryAttemptStoreTest.java`

**Interfaces:**
- notification-settings: `NotificationPreferenceStore` + `SuppressionStore` SPIs. 3 entities, JSON columns for channelDefaults + quietHours, lazy expiry eviction on reads.
- delivery-tracking: `DeliveryAttemptStore` SPI. `claimRetryable()` uses `@Lock(PESSIMISTIC_WRITE)` with `@QueryHints(@QueryHint(name = "jakarta.persistence.lock.timeout", value = "-2"))` for SKIP LOCKED. Cursor pagination. 2 retention schedulers. Engagement event recording with first-opened/first-clicked tracking.

Quarkus counterparts:
- `notification-settings-jpa/src/main/java/.../JpaNotificationPreferenceStore.java`
- `notification-settings-jpa/src/main/java/.../JpaSuppressionStore.java`
- `delivery-tracking-jpa/src/main/java/.../JpaDeliveryAttemptStore.java`

Key for delivery-tracking `claimRetryable()`: Spring Data JPA supports `@Lock` and `@QueryHints` on repository methods:

```java
@Lock(LockModeType.PESSIMISTIC_WRITE)
@QueryHints(@QueryHint(name = "jakarta.persistence.lock.timeout", value = "-2"))
@Query("SELECT e FROM DeliveryAttemptEntity e WHERE e.status = :status AND e.nextRetryAt IS NOT NULL AND e.nextRetryAt <= :now ORDER BY e.nextRetryAt ASC")
List<DeliveryAttemptEntity> findRetryable(@Param("status") DeliveryStatus status, @Param("now") Instant now, Pageable pageable);
```

Key for delivery-tracking retention: needs `PreferenceProvider` and MicroProfile `Config` in Quarkus — Spring equivalent uses `@Value` and `PreferenceProvider` (injected via auto-config).

- [ ] **Step 1: Write tests for both modules**
- [ ] **Step 2: Run tests to verify they fail**
- [ ] **Step 3: Create pom.xml, repositories, stores, schedulers, and auto-configs for both**
- [ ] **Step 4: Run tests to verify they pass**
- [ ] **Step 5: Commit**

### Task 8: Create acl-spring-jpa

**Files:**
- Create: `acl-spring-jpa/pom.xml`
- Create: `acl-spring-jpa/src/main/java/io/casehub/platform/acl/spring/jpa/AclEntryEntityRepository.java`
- Create: `acl-spring-jpa/src/main/java/io/casehub/platform/acl/spring/jpa/AclAuditLogEntityRepository.java`
- Create: `acl-spring-jpa/src/main/java/io/casehub/platform/acl/spring/jpa/ResourceParentEntityRepository.java`
- Create: `acl-spring-jpa/src/main/java/io/casehub/platform/acl/spring/jpa/SpringAccessControlProvider.java`
- Create: `acl-spring-jpa/src/main/java/io/casehub/platform/acl/spring/jpa/AclRetentionScheduler.java`
- Create: `acl-spring-jpa/src/main/java/io/casehub/platform/acl/spring/jpa/AclJpaAutoConfiguration.java`
- Test: `acl-spring-jpa/src/test/java/.../SpringAccessControlProviderTest.java`

**Interfaces:**
- `AccessControlProvider` SPI — most complex module. 3 entities, 3 repositories.
- Key operations: `canAccess()` (recursive parent chain traversal, deny cascade, wildcard matching), `accessibleResources()` (paginated keyset), `accessibleResourcesIncludingInherited()` (recursive CTE — `@Disabled` in H2 tests).
- Audit logging: every grant/revoke/deny writes `AclAuditLogEntity`.
- Group expansion: `GroupMembershipProvider.groupsOf()` builds candidate set.

Quarkus counterpart: `acl-jpa/src/main/java/.../JpaAccessControlProvider.java` (460 lines)

The ACL provider is too complex for derived query methods. Use `@Query` for all ACL entry lookups. The recursive CTE in `accessibleResourcesIncludingInherited()` uses `@Query(nativeQuery = true)` — mark this test with `@Disabled("PostgreSQL-only — recursive CTE")`.

Repository methods needed:

```java
public interface AclEntryEntityRepository extends JpaRepository<AclEntryEntity, Long> {
    List<AclEntryEntity> findByActorIdAndResourceIdAndTenancyId(String actorId, String resourceId, String tenancyId);

    @Query("SELECT e FROM AclEntryEntity e WHERE e.actorId = ?1 AND e.resourceId = ?2 AND e.action = ?3 AND e.tenancyId = ?4 AND e.entryType = ?5")
    List<AclEntryEntity> findByActorResourceActionType(String actorId, String resourceId, String action, String tenancyId, String entryType);

    @Modifying
    @Query("DELETE FROM AclEntryEntity e WHERE e.actorId = ?1 AND e.resourceId = ?2 AND e.action = ?3 AND e.tenancyId = ?4 AND e.entryType = ?5")
    int deleteByActorResourceActionType(String actorId, String resourceId, String action, String tenancyId, String entryType);

    @Modifying
    @Query("DELETE FROM AclEntryEntity e WHERE e.actorId = ?1 AND e.resourceId = ?2 AND e.tenancyId = ?3")
    int deleteByActorAndResource(String actorId, String resourceId, String tenancyId);

    @Query("SELECT COUNT(e) FROM AclEntryEntity e WHERE e.actorId IN ?1 AND e.resourceId = ?2 AND e.action IN ?3 AND e.entryType = ?4 AND (e.expiresAt IS NULL OR e.expiresAt > ?5) AND e.tenancyId = ?6")
    long countActiveByActorsResourceActionsTypeTenant(java.util.Set<String> actorIds, String resourceId, java.util.List<String> actions, String entryType, java.time.Instant now, String tenancyId);

    @Query("SELECT COUNT(e) FROM AclEntryEntity e WHERE e.actorId IN ?1 AND e.resourceId = ?2 AND e.action IN ?3 AND e.entryType = ?4 AND (e.expiresAt IS NULL OR e.expiresAt > ?5)")
    long countActiveByActorsResourceActionsType(java.util.Set<String> actorIds, String resourceId, java.util.List<String> actions, String entryType, java.time.Instant now);

    @Modifying
    @Query("DELETE FROM AclEntryEntity e WHERE (e.expiresAt IS NOT NULL AND e.expiresAt < ?1)")
    int deleteExpired(java.time.Instant now);
}
```

- [ ] **Step 1: Write @DataJpaTest for AccessControlProvider SPI (grant, canAccess with deny cascade, revoke, accessibleResources)**
- [ ] **Step 2: Run test to verify it fails**
- [ ] **Step 3: Create pom.xml, repositories, store, scheduler, and auto-config**
- [ ] **Step 4: Run tests to verify they pass (recursive CTE test @Disabled)**
- [ ] **Step 5: Commit**

### Task 9: Create platform-view-spring-jpa

**Files:**
- Create: `platform-view-spring-jpa/pom.xml`
- Create: `platform-view-spring-jpa/src/main/java/io/casehub/platform/view/spring/jpa/SubjectViewEntityRepository.java`
- Create: `platform-view-spring-jpa/src/main/java/io/casehub/platform/view/spring/jpa/ViewMembershipEntityRepository.java`
- Create: `platform-view-spring-jpa/src/main/java/io/casehub/platform/view/spring/jpa/SpringSubjectViewStore.java`
- Create: `platform-view-spring-jpa/src/main/java/io/casehub/platform/view/spring/jpa/SpringCrossTenantSubjectViewStore.java`
- Create: `platform-view-spring-jpa/src/main/java/io/casehub/platform/view/spring/jpa/SpringViewMembershipTracker.java`
- Create: `platform-view-spring-jpa/src/main/java/io/casehub/platform/view/spring/jpa/PlatformViewJpaAutoConfiguration.java`
- Test: `platform-view-spring-jpa/src/test/java/.../SpringSubjectViewStoreTest.java`

**Interfaces:**
- `SubjectViewStore` SPI (save, findById, findByTenancy, delete)
- `CrossTenantSubjectViewStore` SPI (cross-tenant view queries)
- `ViewMembershipTracker` SPI (membership tracking, update, remove)
- Uses `LabelPatternPredicates` and `JpaLabelPatternQuerySupport` from `platform-view-jpa-common` (Criteria API helpers — framework-neutral)

Quarkus counterparts:
- `platform-view-jpa/src/main/java/.../JpaSubjectViewStore.java`
- `platform-view-jpa/src/main/java/.../JpaCrossTenantSubjectViewStore.java`
- `platform-view-jpa/src/main/java/.../JpaViewMembershipTracker.java`

The `JpaLabelPatternQuerySupport` abstract class uses JPA Criteria API directly — it's framework-neutral and lives in jpa-common. The Spring implementation extends it the same way the Quarkus implementation does.

- [ ] **Step 1: Write @DataJpaTest for SubjectViewStore + ViewMembershipTracker SPI contracts**
- [ ] **Step 2: Run test to verify it fails**
- [ ] **Step 3: Create pom.xml, repositories, stores, and auto-config**
- [ ] **Step 4: Run tests to verify they pass**
- [ ] **Step 5: Commit**

---

## Batch 6: Verification and cleanup

### Task 10: Full build verification and parent pom updates

**Files:**
- Modify: `pom.xml` (parent — add all new modules to `<modules>`)
- Modify: `CLAUDE.md` (add new spring-jpa modules to module table)

- [ ] **Step 1: Ensure all 20 new modules are in parent pom.xml `<modules>` section**

Order: jpa-common modules immediately before their corresponding -jpa modules, spring-jpa modules after the -jpa modules.

- [ ] **Step 2: Run full build**

Run: `mvn --batch-mode install`
Expected: All modules compile, all tests pass (including existing -jpa tests and new spring-jpa tests)

- [ ] **Step 3: Update CLAUDE.md module table**

Add entries for each new module following the existing table format.

- [ ] **Step 4: Commit**

```bash
git add pom.xml CLAUDE.md
git commit -m "feat: complete Spring Data JPA modules — 10 jpa-common + 10 spring-jpa

Closes casehubio/parent#493

Refs casehubio/parent#501"
```

## References

- `specs/issue-493-spring-data-jpa/2026-09-16-spring-data-jpa-modules-design.md` — design spec
- `specs/issue-493-spring-data-jpa/decisions.md` — D1-D7 design decisions
- `persistence-jpa/src/main/java/io/casehub/platform/persistence/jpa/JpaPreferenceStore.java` — Quarkus store pattern
- `../../persistence-jpa-common/src/main/java/io/casehub/platform/persistence/jpa/PreferenceEntry.java` — pure JPA entity pattern
- `platform-spring/src/main/java/io/casehub/platform/spring/PlatformDefaultsManualConfig.java` — Spring auto-config mock fallback
- `spring-generator/src/main/java/io/casehub/platform/spring/generator/AutoConfigurationWriter.java` — generated auto-config structure
- `acl-jpa/src/main/java/io/casehub/platform/acl/jpa/JpaAccessControlProvider.java` — most complex store (460 lines)
- `delivery-tracking-jpa/src/main/java/io/casehub/platform/delivery/tracking/jpa/JpaDeliveryAttemptStore.java` — PESSIMISTIC_WRITE + scheduled retention
- `notifications-jpa/src/main/java/io/casehub/platform/notification/jpa/JpaNotificationStore.java` — cursor pagination + events pattern
- `datasource-jpa/src/main/java/io/casehub/platform/datasource/jpa/JpaDataSourceRegistry.java` — startup reconciliation + caching
- casehubio/parent#493 — focal issue
- casehubio/parent#501 — parent epic
