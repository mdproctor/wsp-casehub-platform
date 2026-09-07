# Dual-Framework Core Extraction — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** casehubio/platform#276 — Extract framework-neutral core from platform modules
**Issue group:** casehubio/parent#469 (epic), casehubio/platform#276

**Goal:** Extract framework-neutral POJO cores from all CDI-coupled platform modules, enabling both Quarkus and Spring Boot consumers. Existing Quarkus artifact names preserved — zero consumer breakage.

**Architecture:** Each CDI-coupled module splits into module-core/ (pure Java POJOs with constructor injection), module/ (existing Quarkus artifact: CDI producers + event observers), and module-spring/ (new: Spring Boot auto-configuration). Core modules depend only on platform-api and standard Java. Framework modules are thin wiring.

**Tech Stack:** Java 21, Maven, Quarkus 3.32.x (existing), Spring Boot 3.x (new), JUnit 5

## Global Constraints

- platform-api/ unchanged — zero-dep pure Java, already framework-neutral
- JPA @Entity classes stay in existing -jpa persistence modules — not extracted
- Core modules: zero CDI, zero Spring, zero Quarkus imports
- Core modules: constructor injection only — no field injection
- Quarkus modules: retain existing artifact names and Maven coordinates
- Spring modules: `module-spring` suffix, @AutoConfiguration registered via META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports
- Spring Boot 3.x, Jakarta EE namespace (compatible with Quarkus 3.x)
- All code navigation and editing via IntelliJ MCP tools

---

## Batch 1: Infrastructure

### Task 1: Add Spring Boot BOM to parent POM and scaffold spring-testing module

**Files:**
- Modify: `pom.xml` (parent POM — add Spring Boot BOM import, add new modules)
- Create: `spring-testing/pom.xml`
- Create: `spring-testing/src/main/java/io/casehub/platform/testing/spring/SpringFixedCurrentPrincipal.java`
- Create: `spring-testing/src/main/java/io/casehub/platform/testing/spring/SpringTestConfig.java`
- Test: `spring-testing/src/test/java/io/casehub/platform/testing/spring/SpringFixedCurrentPrincipalTest.java`

**Interfaces:**
- Consumes: `CurrentPrincipal` from platform-api (`io.casehub.platform.api.identity.CurrentPrincipal`)
- Produces: `SpringFixedCurrentPrincipal` implementing `CurrentPrincipal` for Spring test contexts

- [ ] **Step 1: Add Spring Boot BOM to parent POM dependencyManagement**

In `pom.xml`, add the Spring Boot BOM import after the quarkus-bom import and add a `spring-boot.version` property:

```xml
<!-- In <properties> -->
<spring-boot.version>3.4.5</spring-boot.version>

<!-- In <dependencyManagement><dependencies>, after quarkus-bom -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-dependencies</artifactId>
    <version>${spring-boot.version}</version>
    <type>pom</type>
    <scope>import</scope>
</dependency>
```

Add new modules to the `<modules>` section:

```xml
<module>spring-testing</module>
```

- [ ] **Step 2: Create spring-testing/pom.xml**

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

    <artifactId>casehub-platform-spring-testing</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform :: Spring Testing</name>
    <description>Spring Boot test fixtures — @TestConfiguration overrides for platform SPIs.
        Parallel to casehub-platform-testing for Quarkus.</description>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-api</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-autoconfigure</artifactId>
        </dependency>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-test</artifactId>
            <scope>test</scope>
        </dependency>
    </dependencies>
</project>
```

- [ ] **Step 3: Write failing test for SpringFixedCurrentPrincipal**

```java
package io.casehub.platform.testing.spring;

import io.casehub.platform.api.identity.CurrentPrincipal;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;

class SpringFixedCurrentPrincipalTest {

    @Test
    void returnsConfiguredActorId() {
        var principal = new SpringFixedCurrentPrincipal("actor-1", "tenant-1");
        assertThat(principal.actorId()).isEqualTo("actor-1");
    }

    @Test
    void returnsConfiguredTenancyId() {
        var principal = new SpringFixedCurrentPrincipal("actor-1", "tenant-1");
        assertThat(principal.tenancyId()).isEqualTo("tenant-1");
    }

    @Test
    void mutableSettersWork() {
        var principal = new SpringFixedCurrentPrincipal("actor-1", "tenant-1");
        principal.setActorId("actor-2");
        principal.setTenancyId("tenant-2");
        assertThat(principal.actorId()).isEqualTo("actor-2");
        assertThat(principal.tenancyId()).isEqualTo("tenant-2");
    }
}
```

- [ ] **Step 4: Run test to verify it fails**

Run: `mvn --batch-mode test -pl spring-testing -Dtest=SpringFixedCurrentPrincipalTest`
Expected: Compilation failure — class not found

- [ ] **Step 5: Implement SpringFixedCurrentPrincipal**

```java
package io.casehub.platform.testing.spring;

import io.casehub.platform.api.identity.CurrentPrincipal;

import java.util.Set;

public class SpringFixedCurrentPrincipal implements CurrentPrincipal {

    private String actorId;
    private String tenancyId;
    private Set<String> groups = Set.of();

    public SpringFixedCurrentPrincipal(String actorId, String tenancyId) {
        this.actorId = actorId;
        this.tenancyId = tenancyId;
    }

    @Override public String actorId() { return actorId; }
    @Override public String tenancyId() { return tenancyId; }
    @Override public Set<String> groups() { return groups; }

    public void setActorId(String actorId) { this.actorId = actorId; }
    public void setTenancyId(String tenancyId) { this.tenancyId = tenancyId; }
    public void setGroups(Set<String> groups) { this.groups = groups; }
}
```

- [ ] **Step 6: Create SpringTestConfig**

```java
package io.casehub.platform.testing.spring;

import io.casehub.platform.api.identity.CurrentPrincipal;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;

@TestConfiguration
public class SpringTestConfig {

    @Bean
    public CurrentPrincipal currentPrincipal() {
        return new SpringFixedCurrentPrincipal("test-actor", "test-tenant");
    }
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl spring-testing`
Expected: 3 tests PASS

- [ ] **Step 8: Commit**

```bash
git add spring-testing/ pom.xml
git commit -m "feat(#276): add Spring Boot BOM and spring-testing scaffold

Adds spring-boot-dependencies BOM to parent POM for consistent Spring Boot
version management. Creates spring-testing module with SpringFixedCurrentPrincipal
and SpringTestConfig — parallel to casehub-platform-testing for Quarkus.

Refs casehubio/platform#276"
```

---

## Batch 2: Platform-View Reference Extraction

This batch proves the full extraction pattern on platform-view — the reference
implementation for all subsequent Category A extractions.

### Task 1: Create platform-view-core and extract POJO logic

**Files:**
- Create: `platform-view-core/pom.xml`
- Move: `SubjectViewEvaluator.java` from `platform-view/` to `platform-view-core/` (use `ide_move_file`)
- Move: `SubjectViewOrchestrator.java` from `platform-view/` to `platform-view-core/` (use `ide_move_file`)
- Edit: `SubjectViewEvaluator` — remove `@ApplicationScoped` (use `ide_edit_member`)
- Edit: `SubjectViewOrchestrator` — remove `@ApplicationScoped`, convert `@Inject` fields to constructor params (use `ide_change_signature` + `ide_edit_member`)
- Move: `SubjectViewEvaluatorTest.java` to `platform-view-core/` (use `ide_move_file`)
- Move: `SubjectViewOrchestratorTest.java` to `platform-view-core/` (use `ide_move_file`)
- Test: `platform-view-core/src/test/java/io/casehub/platform/view/SubjectViewEvaluatorTest.java`
- Test: `platform-view-core/src/test/java/io/casehub/platform/view/SubjectViewOrchestratorTest.java`

**Interfaces:**
- Consumes: `SubjectViewStore`, `ViewMembershipTracker`, `SubjectViewSpec`, `SubjectViewEvent`, `PreferenceProvider`, `LabelPatternMatcher` from platform-api
- Produces: `SubjectViewEvaluator` (POJO — no annotations), `SubjectViewOrchestrator` (POJO — constructor-injected)

- [ ] **Step 1: Create platform-view-core/pom.xml**

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

    <artifactId>casehub-platform-view-core</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform :: Subject View Core</name>
    <description>Framework-neutral view evaluation and orchestration logic.
        Pure Java POJOs — no CDI, no Spring.</description>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-api</artifactId>
            <version>${project.version}</version>
        </dependency>

        <!-- Test -->
        <dependency>
            <groupId>org.junit.jupiter</groupId>
            <artifactId>junit-jupiter</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.assertj</groupId>
            <artifactId>assertj-core</artifactId>
            <scope>test</scope>
        </dependency>
    </dependencies>
</project>
```

Add `<module>platform-view-core</module>` to parent pom.xml `<modules>`, BEFORE `platform-view`.

- [ ] **Step 2: Create directory structure for platform-view-core**

```bash
mkdir -p platform-view-core/src/main/java/io/casehub/platform/view
mkdir -p platform-view-core/src/test/java/io/casehub/platform/view
```

- [ ] **Step 3: Move SubjectViewEvaluator to platform-view-core**

Use `ide_move_file` to move:
- `platform-view/src/main/java/io/casehub/platform/view/SubjectViewEvaluator.java` → `platform-view-core/src/main/java/io/casehub/platform/view/SubjectViewEvaluator.java`

Then edit the class to remove CDI annotation. The class should become:

```java
package io.casehub.platform.view;

import io.casehub.platform.api.path.Path;
import io.casehub.platform.api.view.LabelPatternMatcher;
import io.casehub.platform.api.view.SubjectViewEvent;
import io.casehub.platform.api.view.SubjectViewSpec;
import io.casehub.platform.api.view.ViewEventType;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

public class SubjectViewEvaluator {
    // All existing methods unchanged — they are already pure logic
}
```

Remove: `import jakarta.enterprise.context.ApplicationScoped;` and `@ApplicationScoped` annotation.

- [ ] **Step 4: Convert SubjectViewOrchestrator to constructor injection**

Move the file first:
- `platform-view/src/main/java/io/casehub/platform/view/SubjectViewOrchestrator.java` → `platform-view-core/src/main/java/io/casehub/platform/view/SubjectViewOrchestrator.java`

Then rewrite the class header to use constructor injection:

```java
package io.casehub.platform.view;

import io.casehub.platform.api.identity.TenancyConstants;
import io.casehub.platform.api.path.Path;
import io.casehub.platform.api.preferences.PlatformPreferenceKeys;
import io.casehub.platform.api.preferences.PreferenceProvider;
import io.casehub.platform.api.preferences.SettingsScope;
import io.casehub.platform.api.view.SubjectViewEvent;
import io.casehub.platform.api.view.SubjectViewSpec;
import io.casehub.platform.api.view.SubjectViewStore;
import io.casehub.platform.api.view.ViewEventType;
import io.casehub.platform.api.view.ViewMembershipTracker;

import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.function.Function;

public class SubjectViewOrchestrator {

    private final SubjectViewEvaluator evaluator;
    private final SubjectViewStore viewStore;
    private final ViewMembershipTracker tracker;
    private final PreferenceProvider preferenceProvider;
    private final ConcurrentHashMap<String, CachedViews> viewCache = new ConcurrentHashMap<>();

    public SubjectViewOrchestrator(
            SubjectViewEvaluator evaluator,
            SubjectViewStore viewStore,
            ViewMembershipTracker tracker,
            PreferenceProvider preferenceProvider) {
        this.evaluator = evaluator;
        this.viewStore = viewStore;
        this.tracker = tracker;
        this.preferenceProvider = preferenceProvider;
    }

    // All existing methods unchanged — they reference fields by name, which is the same
    // ... (rest of class body unchanged)
}
```

Remove: `import jakarta.enterprise.context.ApplicationScoped;`, `import jakarta.inject.Inject;`, `@ApplicationScoped`, all `@Inject` annotations.

- [ ] **Step 5: Move existing tests to platform-view-core**

Use `ide_move_file`:
- `platform-view/src/test/java/io/casehub/platform/view/SubjectViewEvaluatorTest.java` → `platform-view-core/src/test/java/io/casehub/platform/view/SubjectViewEvaluatorTest.java`
- `platform-view/src/test/java/io/casehub/platform/view/SubjectViewOrchestratorTest.java` → `platform-view-core/src/test/java/io/casehub/platform/view/SubjectViewOrchestratorTest.java`

Update test for SubjectViewOrchestrator to use constructor instantiation instead of CDI injection. The test should construct the orchestrator directly:

```java
var evaluator = new SubjectViewEvaluator();
var orchestrator = new SubjectViewOrchestrator(
    evaluator, mockViewStore, mockTracker, mockPreferenceProvider);
```

- [ ] **Step 6: Update platform-view pom.xml to depend on core**

Replace `quarkus-arc` as the only compile dep alongside platform-api. Add dependency on core:

```xml
<dependencies>
    <dependency>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-platform-view-core</artifactId>
        <version>${project.version}</version>
    </dependency>
    <dependency>
        <groupId>io.quarkus</groupId>
        <artifactId>quarkus-arc</artifactId>
    </dependency>
    <!-- platform-api comes transitively from core -->
</dependencies>
```

- [ ] **Step 7: Run core tests to verify they pass without CDI**

Run: `mvn --batch-mode test -pl platform-view-core`
Expected: All tests PASS — pure JUnit 5, no container needed

- [ ] **Step 8: Commit**

```bash
git add platform-view-core/ pom.xml
git -C . add platform-view/
git commit -m "feat(#276): extract platform-view-core — pure Java view evaluation logic

Moves SubjectViewEvaluator and SubjectViewOrchestrator to platform-view-core
as framework-neutral POJOs. Removes CDI annotations, converts field injection
to constructor injection. Tests run with plain JUnit 5.

Refs casehubio/platform#276"
```

### Task 2: Add CDI producers to platform-view Quarkus module

**Files:**
- Create: `platform-view/src/main/java/io/casehub/platform/view/quarkus/ViewBeans.java`
- Test: existing @QuarkusTest tests in platform-view (should still pass)

**Interfaces:**
- Consumes: `SubjectViewEvaluator`, `SubjectViewOrchestrator` from platform-view-core
- Produces: CDI-managed beans for both classes

- [ ] **Step 1: Create CDI producer class**

```java
package io.casehub.platform.view.quarkus;

import io.casehub.platform.api.preferences.PreferenceProvider;
import io.casehub.platform.api.view.SubjectViewStore;
import io.casehub.platform.api.view.ViewMembershipTracker;
import io.casehub.platform.view.SubjectViewEvaluator;
import io.casehub.platform.view.SubjectViewOrchestrator;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.inject.Produces;

@ApplicationScoped
public class ViewBeans {

    @Produces
    @ApplicationScoped
    public SubjectViewEvaluator subjectViewEvaluator() {
        return new SubjectViewEvaluator();
    }

    @Produces
    @ApplicationScoped
    public SubjectViewOrchestrator subjectViewOrchestrator(
            SubjectViewEvaluator evaluator,
            SubjectViewStore viewStore,
            ViewMembershipTracker tracker,
            PreferenceProvider preferenceProvider) {
        return new SubjectViewOrchestrator(evaluator, viewStore, tracker, preferenceProvider);
    }
}
```

- [ ] **Step 2: Verify existing Quarkus tests still pass**

Run: `mvn --batch-mode test -pl platform-view`
Expected: All existing tests PASS — CDI produces the same beans via @Produces

- [ ] **Step 3: Verify full build**

Run: `mvn --batch-mode install -pl platform-view-core,platform-view`
Expected: BUILD SUCCESS

- [ ] **Step 4: Commit**

```bash
git add platform-view/
git commit -m "feat(#276): add CDI producers to platform-view Quarkus module

ViewBeans @Produces SubjectViewEvaluator and SubjectViewOrchestrator from
the core POJOs. Existing Quarkus consumers see no change — same artifact
name, same bean types, same behavior.

Refs casehubio/platform#276"
```

### Task 3: Create platform-view-spring auto-configuration

**Files:**
- Create: `platform-view-spring/pom.xml`
- Create: `platform-view-spring/src/main/java/io/casehub/platform/view/spring/ViewAutoConfiguration.java`
- Create: `platform-view-spring/src/main/resources/META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`
- Test: `platform-view-spring/src/test/java/io/casehub/platform/view/spring/ViewAutoConfigurationTest.java`

**Interfaces:**
- Consumes: `SubjectViewEvaluator`, `SubjectViewOrchestrator` from platform-view-core
- Produces: Spring-managed beans for both classes

- [ ] **Step 1: Create platform-view-spring/pom.xml**

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

    <artifactId>casehub-platform-view-spring</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform :: Subject View Spring</name>
    <description>Spring Boot auto-configuration for platform-view.
        Produces view beans from platform-view-core POJOs.</description>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-view-core</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-autoconfigure</artifactId>
        </dependency>

        <!-- Test -->
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-test</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-spring-testing</artifactId>
            <version>${project.version}</version>
            <scope>test</scope>
        </dependency>
    </dependencies>
</project>
```

Add `<module>platform-view-spring</module>` to parent pom.xml.

- [ ] **Step 2: Write failing test for Spring auto-configuration**

```java
package io.casehub.platform.view.spring;

import io.casehub.platform.view.SubjectViewEvaluator;
import io.casehub.platform.view.SubjectViewOrchestrator;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.autoconfigure.AutoConfigurations;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;

import static org.assertj.core.api.Assertions.assertThat;

class ViewAutoConfigurationTest {

    private final ApplicationContextRunner contextRunner = new ApplicationContextRunner()
            .withConfiguration(AutoConfigurations.of(ViewAutoConfiguration.class));

    @Test
    void evaluatorBeanCreated() {
        contextRunner.run(context -> {
            assertThat(context).hasSingleBean(SubjectViewEvaluator.class);
        });
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mvn --batch-mode test -pl platform-view-spring -Dtest=ViewAutoConfigurationTest`
Expected: Compilation failure — ViewAutoConfiguration not found

- [ ] **Step 4: Implement ViewAutoConfiguration**

```java
package io.casehub.platform.view.spring;

import io.casehub.platform.api.preferences.PreferenceProvider;
import io.casehub.platform.api.view.SubjectViewStore;
import io.casehub.platform.api.view.ViewMembershipTracker;
import io.casehub.platform.view.SubjectViewEvaluator;
import io.casehub.platform.view.SubjectViewOrchestrator;
import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnClass;
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.context.annotation.Bean;

@AutoConfiguration
@ConditionalOnClass(SubjectViewEvaluator.class)
public class ViewAutoConfiguration {

    @Bean
    @ConditionalOnMissingBean
    public SubjectViewEvaluator subjectViewEvaluator() {
        return new SubjectViewEvaluator();
    }

    @Bean
    @ConditionalOnMissingBean
    public SubjectViewOrchestrator subjectViewOrchestrator(
            SubjectViewEvaluator evaluator,
            SubjectViewStore viewStore,
            ViewMembershipTracker tracker,
            PreferenceProvider preferenceProvider) {
        return new SubjectViewOrchestrator(evaluator, viewStore, tracker, preferenceProvider);
    }
}
```

- [ ] **Step 5: Register auto-configuration**

Create file:
`platform-view-spring/src/main/resources/META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`

Contents:
```
io.casehub.platform.view.spring.ViewAutoConfiguration
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl platform-view-spring`
Expected: Tests PASS (note: the orchestrator test may need mock SPI beans in context — add @MockBean or use test doubles)

- [ ] **Step 7: Verify full build of all view modules**

Run: `mvn --batch-mode install -pl platform-view-core,platform-view,platform-view-spring`
Expected: BUILD SUCCESS

- [ ] **Step 8: Commit**

```bash
git add platform-view-spring/ pom.xml
git commit -m "feat(#276): add platform-view-spring auto-configuration

Spring Boot auto-configuration for platform-view. Produces SubjectViewEvaluator
and SubjectViewOrchestrator beans from core POJOs. @ConditionalOnMissingBean
allows consumer overrides — equivalent to CDI @DefaultBean displacement.

Refs casehubio/platform#276"
```

---

## Batch 3: Platform Defaults Extraction

Extracts the @DefaultBean no-op implementations from platform/ into a
platform-core module. This is the most impactful extraction — every
consumer depends on these defaults.

### Task 1: Create platform-core and extract NoOp POJOs

**Files:**
- Create: `platform-core/pom.xml`
- Move all NoOp/Mock classes from `platform/src/main/java/` to `platform-core/src/main/java/` — each class has CDI annotations removed
- Key classes: `MockCurrentPrincipal`, `MockPreferenceProvider`, `MockGroupMembershipProvider`, `NoOpCaseMemoryStore`, `NoOpAccessControlProvider`, `NoOpWorkerCredentialStore`, `NoOpDIDResolver`, `NoOpActorDIDProvider`, `NoOpDigestBuffer`, `NoOpDeliveryChannelRegistry`, `NoOpDeliveryAttemptStore`, `NoOpEventTypeRegistry`, `NoOpSubscriptionStore`, `NoOpNotificationPreferenceStore`, `NoOpSuppressionStore`, `NoOpCrossTenantSubjectViewStore`, `NoOpEntityWatcherProvider`, `AutoApproveWorkerAuthorizationPolicy`
- Test: pure JUnit 5 tests for each NoOp (verify they return expected defaults)

**Interfaces:**
- Consumes: all SPI interfaces from platform-api
- Produces: NoOp POJOs implementing each SPI — no annotations, constructor injection where needed

**Extraction pattern per class:**

1. Move class to `platform-core/` (same package)
2. Remove `@DefaultBean`, `@ApplicationScoped`, `@Inject`, `@ConfigProperty`
3. For classes with `@ConfigProperty` (MockCurrentPrincipal, MockPreferenceProvider): convert config values to constructor parameters
4. Write pure JUnit test verifying default behavior

### Task 2: Add @Produces @DefaultBean wiring in platform/ Quarkus module

**Files:**
- Create: `platform/src/main/java/io/casehub/platform/quarkus/DefaultBeans.java`
- Modify: `platform/pom.xml` — add dependency on platform-core

Each NoOp POJO gets a `@Produces @DefaultBean @ApplicationScoped` method.
For config-backed mocks (MockCurrentPrincipal), the producer injects
`@ConfigProperty` values and passes them to the constructor.

### Task 3: Create platform-spring auto-configuration

**Files:**
- Create: `platform-spring/pom.xml`
- Create: `platform-spring/src/main/java/io/casehub/platform/spring/PlatformDefaultsAutoConfiguration.java`
- Create: auto-configuration registration file

Each NoOp gets a `@Bean @ConditionalOnMissingBean` method.
For config-backed mocks, use `@Value` to inject config values.

---

## Batch 4: Leaf Services — Expression, Identity, Governance

Each follows the proven Batch 2 pattern. Per module:
1. Create module-core/pom.xml (depends on platform-api)
2. Move business logic classes → constructor injection, remove CDI annotations
3. Update existing module → @Produces methods, depends on core
4. Create module-spring/ → @AutoConfiguration, depends on core
5. Move pure tests to core, add framework-specific tests
6. Build & verify

### Task 1: Extract expression-core

**Key classes to extract:** `DefaultExpressionEngineRegistry`, `MvelExpressionEngine`, `JQExpressionEngine`, `ScalarJQExpression`, `MapAdaptedJQExpression`, `MockSecretManager`, `MockConfigManager`

**CDI entry points staying in expression/ Quarkus module:** @Produces for each engine, @DefaultBean for mocks

### Task 2: Extract identity-core

**Key classes to extract:** `CompositeDIDResolver`, `WebDIDResolver`, `KeyDIDResolver`, `ScimDIDResolver`, `CompositeActorDIDProvider`, `ConfiguredActorDIDProvider`, `ScimActorDIDProvider`, `ScimAgentLookup`, `CdiPriorityUtils`, `JwtVCValidator`

**Special pattern:** `@DIDMethod` CDI qualifier → core takes a `List<DIDResolver>` ordered by priority. Quarkus module collects `Instance<DIDResolver>` and sorts by @Priority. Spring module collects `List<DIDResolver>` with @Order.

### Task 3: Extract governance-core

**Key classes to extract:** `DefaultPolicyEnforcer`

**Note:** Uses `Executors.newVirtualThreadPerTaskExecutor()` — pure Java, no CDI dependency. Extraction is trivial: remove @ApplicationScoped, add constructor.

---

## Batch 5: Agent Stack

### Task 1: Extract agent-runtime-core, agent-claude-core, agent-openai-core, agent-gemini-core, agent-codex-core, agent-gemini-cli-core

Each agent backend follows identical pattern: remove @ApplicationScoped, convert to constructor injection, @Produces in existing module.

### Task 2: Extract agent-router-core

**Special pattern:** `Instance<AgentBackend>` → core takes `List<AgentBackend>`. Quarkus module collects from CDI Instance<>. Spring module collects from ObjectProvider<>.

### Task 3: Extract agent-gate-core

**Special pattern:** CDI `@Decorator @Priority(2000)` → core is a POJO wrapping a delegate AgentProvider. Quarkus module uses @Decorator. Spring module uses @Bean @Primary wrapping the delegate.

### Task 4: Extract agent-langchain4j-core

**Special pattern:** `@DefaultBean @Priority(10)` ChatModel → core POJO, Quarkus @DefaultBean, Spring @ConditionalOnMissingBean.

---

## Batch 6: Notification Pipeline

### Task 1: Extract notification stores (inmem + settings-inmem + delivery-tracking-inmem + digest-inmem + delivery-channel-inmem)

All are ConcurrentHashMap POJOs with annotation-only coupling. Batch extraction — remove annotations, create cores, add producers.

### Task 2: Extract notification-dispatch-core

**Key classes to extract:** `TargetResolver`, `SuppressionEvaluator`, `ChannelRouter`, `TemplateResolver`, `DeliveryTracker`, `DeliveryRetryProcessor` (logic), `DigestFlushScheduler` (logic), `EngagementRecorder` (logic), `InAppNotificationDeliverer` (logic), `InAppEngagementBridge` (logic)

**CDI entry points staying in Quarkus module:** 2x @ObservesAsync (SubscriptionMatched, NotificationStatusChanged), 2x @Scheduled (digest flush, delivery retry)

**Event callback pattern:** Core defines `DispatchEvents` interface with methods for each CDI event the module fires. Quarkus module implements via CDI Event<>. Spring module implements via ApplicationEventPublisher.

### Task 3: Extract notifications-core (REST + push logic)

---

## Batch 7: Data Infrastructure

### Task 1: Extract datasource-inmem-core, endpoints-memory-core, memory-inmem-core

### Task 2: Extract acl-inmem-core, acl-admin-core, acl-worker-core

### Task 3: Extract callback-inmem-core, callback-core, scim-core

### Task 4: Extract config-core, endpoints-config-core, preferences-editor-core

---

## Batch 8: Category C Modules

Framework-specific implementations sharing utility classes.

### Task 1: Create subscriptions shared utility + framework modules

Extract pure utility logic (filter compilation, event type matching) to subscriptions-core/. Create subscriptions-quarkus/ (renamed from subscriptions/) and subscriptions-spring/ with full framework-specific implementations.

### Task 2: Create streams-* framework modules

Each streams module gets a Spring equivalent. Shared CloudEvent parsing/building logic extracted to a common utility.

### Task 3: Create mcp framework modules

CDI BeanManager scanning logic has no Spring equivalent — Spring uses classpath scanning. MCP domain content formatting and schema building extracted as shared utility.

---

## References

- [2026-09-07-dual-framework-core-extraction-design.md] — design spec this plan implements
- [platform-view/src/main/java/io/casehub/platform/view/SubjectViewOrchestrator.java] — reference extraction source
- [platform-view/src/main/java/io/casehub/platform/view/SubjectViewEvaluator.java] — reference extraction source
- [platform-view/pom.xml] — reference module POM
- [pom.xml] — parent POM (BOM modifications)
- GE-20260615-c234fc — @DefaultBean silently ignored without quarkus-arc
- GE-20260522-adb5cd — moving beans to library JARs breaks CDI discovery
- GE-20260604-81a6a6 — @DefaultBean @Unremovable for cross-module injection
- PP-20260514-engine-spi-noops-defaultbean — @DefaultBean pattern
- PP-20260518-platform-spi-contract — SPI implementation contract
- casehubio/platform#276 — focal issue
- casehubio/parent#469 — parent epic
