# SPI Batch Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #171 — JPA-backed DataSourceRegistry for durable DataSource persistence
**Issue group:** #171, #139, #172, #164, #165, #167, #168, #169

**Goal:** DataSource infrastructure (alpha extraction, JPA registry, marshaller config,
descriptor update), digest/delivery improvements, and structural cleanup.

**Architecture:** Nine sequential tasks following the spec's dependency order. SPI
changes in platform-api first (marshallerKeys, update(), MarshallerRegistry), then
implementations (InMem, JPA), then notification improvements and structural cleanup.

**Tech Stack:** Java 21, Quarkus, Hibernate ORM, Flyway, CDI events, JUnit 5, AssertJ

## Global Constraints

- `platform-api/` must remain zero-dependency — no Quarkus, no JPA, no casehubio imports
- Every JPA module gets its own Flyway migration directory (`classpath:db/<module>/migration`)
- Flyway DDL uses `TEXT` for JSON columns (H2 compatibility) — JPA layer uses `@JdbcTypeCode(SqlTypes.JSON)` for PostgreSQL JSONB semantics
- `@DefaultBean` NoOp implementations must NOT fire CDI events
- IntelliJ MCP (`mcp__intellij-index__*`) is mandatory for all code navigation and structural editing
- Pre-release — breaking API changes are free

---

### Task 1: UUIDv7 Relocation (#168)

**Files:**
- Move: `platform-api/src/main/java/io/casehub/platform/api/notification/UUIDv7.java` → `platform-api/src/main/java/io/casehub/platform/api/util/`
- Move: `platform-api/src/test/java/io/casehub/platform/api/notification/UUIDv7Test.java` → `platform-api/src/test/java/io/casehub/platform/api/util/`

**Interfaces:**
- Produces: `io.casehub.platform.api.util.UUIDv7` — same API, new package

- [ ] **Step 1: Create target directories**

```bash
mkdir -p /Users/mdproctor/claude/casehub/platform/platform-api/src/main/java/io/casehub/platform/api/util
mkdir -p /Users/mdproctor/claude/casehub/platform/platform-api/src/test/java/io/casehub/platform/api/util
```

- [ ] **Step 2: Move UUIDv7 class via IntelliJ**

Use `ide_move_file` to move UUIDv7.java to the new package. This updates all 46
references across the codebase automatically.

```
ide_move_file(file="platform-api/src/main/java/io/casehub/platform/api/notification/UUIDv7.java",
              destination="platform-api/src/main/java/io/casehub/platform/api/util")
```

- [ ] **Step 3: Move UUIDv7Test via IntelliJ**

```
ide_move_file(file="platform-api/src/test/java/io/casehub/platform/api/notification/UUIDv7Test.java",
              destination="platform-api/src/test/java/io/casehub/platform/api/util")
```

- [ ] **Step 4: Build to verify all imports updated**

```bash
mvn --batch-mode -f /Users/mdproctor/claude/casehub/platform/pom.xml compile test-compile -q
```

Expected: BUILD SUCCESS — all 46 references updated by ide_move_file.

- [ ] **Step 5: Run UUIDv7 tests**

```bash
mvn --batch-mode -f /Users/mdproctor/claude/casehub/platform/platform-api/pom.xml test -pl . -Dtest=UUIDv7Test -q
```

Expected: Tests pass.

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add -A
git -C /Users/mdproctor/claude/casehub/platform commit -m "refactor(platform#168): relocate UUIDv7 to io.casehub.platform.api.util"
```

---

### Task 2: Alpha Network Extraction (prerequisite for #171)

**Files:**
- Create: `datasource-alpha/pom.xml`
- Create: `datasource-alpha/src/main/java/io/casehub/platform/datasource/alpha/AlphaDataSource.java`
- Create: `datasource-alpha/src/main/java/io/casehub/platform/datasource/alpha/TypeNode.java`
- Create: `datasource-alpha/src/main/java/io/casehub/platform/datasource/alpha/FilterNode.java`
- Create: `datasource-alpha/src/main/java/io/casehub/platform/datasource/alpha/FanOutProcessor.java`
- Modify: `datasource-inmem/pom.xml` — add datasource-alpha dependency
- Modify: `datasource-inmem/src/main/java/io/casehub/platform/datasource/memory/InMemoryDataSourceRegistry.java` — update imports
- Delete: `datasource-inmem/src/main/java/io/casehub/platform/datasource/memory/AlphaDataSource.java` (after move)
- Delete: `datasource-inmem/src/main/java/io/casehub/platform/datasource/memory/TypeNode.java` (after move)
- Delete: `datasource-inmem/src/main/java/io/casehub/platform/datasource/memory/FilterNode.java` (after move)
- Delete: `datasource-inmem/src/main/java/io/casehub/platform/datasource/memory/FanOutProcessor.java` (after move)
- Modify: `pom.xml` (parent) — add `<module>datasource-alpha</module>`

**Interfaces:**
- Produces: `io.casehub.platform.datasource.alpha.AlphaDataSource<T>` — same API, new package

- [ ] **Step 1: Create datasource-alpha module pom.xml**

```bash
mkdir -p /Users/mdproctor/claude/casehub/platform/datasource-alpha/src/main/java/io/casehub/platform/datasource/alpha
```

Write `datasource-alpha/pom.xml`:

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

    <artifactId>casehub-platform-datasource-alpha</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform DataSource Alpha Network</name>
    <description>Rete alpha network runtime for DataSource — AlphaDataSource, TypeNode,
        FilterNode, FanOutProcessor. Shared by all DataSourceRegistry backends
        (datasource-inmem, datasource-jpa). Pure runtime — no CDI, no persistence.</description>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-api</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>org.jboss.logging</groupId>
            <artifactId>jboss-logging</artifactId>
        </dependency>
    </dependencies>

    <build>
        <plugins>
            <plugin>
                <groupId>io.smallrye</groupId>
                <artifactId>jandex-maven-plugin</artifactId>
                <version>${jandex-maven-plugin.version}</version>
                <executions>
                    <execution>
                        <id>make-index</id>
                        <goals><goal>jandex</goal></goals>
                    </execution>
                </executions>
            </plugin>
        </plugins>
    </build>
</project>
```

- [ ] **Step 2: Add module to parent pom.xml**

Add `<module>datasource-alpha</module>` BEFORE `<module>datasource-inmem</module>`
in the parent pom.xml module list (build order dependency).

- [ ] **Step 3: Move the four alpha network classes via IntelliJ**

Use `ide_move_file` for each class. This updates imports in InMemoryDataSourceRegistry,
SubscriptionEngineTest, DataSourceRouterTest, and AlphaDataSourceTest.

```
ide_move_file(file="datasource-inmem/src/main/java/io/casehub/platform/datasource/memory/AlphaDataSource.java",
              destination="datasource-alpha/src/main/java/io/casehub/platform/datasource/alpha")
ide_move_file(file="datasource-inmem/src/main/java/io/casehub/platform/datasource/memory/TypeNode.java",
              destination="datasource-alpha/src/main/java/io/casehub/platform/datasource/alpha")
ide_move_file(file="datasource-inmem/src/main/java/io/casehub/platform/datasource/memory/FilterNode.java",
              destination="datasource-alpha/src/main/java/io/casehub/platform/datasource/alpha")
ide_move_file(file="datasource-inmem/src/main/java/io/casehub/platform/datasource/memory/FanOutProcessor.java",
              destination="datasource-alpha/src/main/java/io/casehub/platform/datasource/alpha")
```

After move, change visibility of TypeNode, FilterNode, FanOutProcessor from
`final class` (package-private) to `public final class` — they're now in a
different package from AlphaDataSource's consumers.

- [ ] **Step 4: Add datasource-alpha dependency to datasource-inmem/pom.xml**

Add before the existing `casehub-platform-api` dependency:

```xml
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-platform-datasource-alpha</artifactId>
    <version>${project.version}</version>
</dependency>
```

- [ ] **Step 5: Sync IntelliJ and build**

```
ide_sync_files(paths=["datasource-alpha/", "datasource-inmem/", "pom.xml"])
ide_reload_project()
```

```bash
mvn --batch-mode -f /Users/mdproctor/claude/casehub/platform/pom.xml compile test-compile -q
```

Expected: BUILD SUCCESS.

- [ ] **Step 6: Run existing tests**

```bash
mvn --batch-mode -f /Users/mdproctor/claude/casehub/platform/datasource-inmem/pom.xml test -q
mvn --batch-mode -f /Users/mdproctor/claude/casehub/platform/subscriptions/pom.xml test -q
```

Expected: All existing tests pass — no functional change.

- [ ] **Step 7: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add -A
git -C /Users/mdproctor/claude/casehub/platform commit -m "refactor(platform#171): extract alpha network to datasource-alpha module"
```

---

### Task 3: Marshaller Configuration Model — SPI (#139)

**Files:**
- Modify: `platform-api/src/main/java/io/casehub/platform/api/datasource/DataSourceDescriptor.java` — add `marshallerKeys` field
- Modify: `platform-api/src/main/java/io/casehub/platform/api/datasource/Marshaller.java` — update javadoc
- Create: `platform-api/src/main/java/io/casehub/platform/api/datasource/MarshallerRegistry.java`
- Create: `platform/src/main/java/io/casehub/platform/datasource/NoOpMarshallerRegistry.java`
- Create: `platform-api/src/test/java/io/casehub/platform/api/datasource/MarshallerRegistryTest.java`
- Modify: All 20 DataSourceDescriptor constructor call sites — add `Map.of()` parameter

**Interfaces:**
- Produces: `MarshallerRegistry` SPI — `register(String, Marshaller<?,?>)`, `resolve(String) → Optional<Marshaller<?,?>>`
- Produces: `DataSourceDescriptor.marshallerKeys()` — `Map<String, String>` (eventType → marshallerKey)

- [ ] **Step 1: Write MarshallerRegistry SPI test**

Create `platform-api/src/test/java/io/casehub/platform/api/datasource/MarshallerRegistryTest.java`:

```java
package io.casehub.platform.api.datasource;

import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class MarshallerRegistryTest {

    @Test
    void defaultMethodsHaveExpectedContracts() {
        // MarshallerRegistry is an interface — verify default method contracts
        // exist by checking interface shape. Concrete tests are on implementations.
        assertThat(MarshallerRegistry.class.isInterface()).isTrue();
    }
}
```

- [ ] **Step 2: Create MarshallerRegistry SPI**

Create `platform-api/src/main/java/io/casehub/platform/api/datasource/MarshallerRegistry.java`:

```java
package io.casehub.platform.api.datasource;

import java.util.Optional;

/**
 * Registry for named {@link Marshaller} instances.
 *
 * <p>Implementations must populate during bean initialization ({@code @PostConstruct}),
 * not during {@code @Observes StartupEvent}. The JPA DataSourceRegistry reconciles
 * persisted descriptors at StartupEvent and calls {@link #resolve(String)} for each
 * marshallerKey — if this registry also populates at StartupEvent, ordering is
 * nondeterministic and reconciliation may fail with spurious errors.
 */
public interface MarshallerRegistry {

    void register(String key, Marshaller<?, ?> marshaller);

    Optional<Marshaller<?, ?>> resolve(String key);
}
```

- [ ] **Step 3: Add marshallerKeys to DataSourceDescriptor**

Use `ide_edit_member` to replace the DataSourceDescriptor record declaration.
Add `Map<String, String> marshallerKeys` as the 7th field. Update the compact
constructor to make a defensive copy of marshallerKeys (same pattern as
acceptedEventTypes and properties). Update `isPlatformGlobal()` if needed.

The new constructor signature:
```java
public DataSourceDescriptor(Path path, String tenancyId, ObjectType<?> objectType,
                            Path endpointPath, Set<String> acceptedEventTypes,
                            Map<String, String> properties, Map<String, String> marshallerKeys)
```

Add null check and defensive copy in compact constructor:
```java
marshallerKeys = Map.copyOf(Objects.requireNonNull(marshallerKeys, "marshallerKeys"));
```

- [ ] **Step 4: Fix all 20 DataSourceDescriptor constructor call sites**

Each call site gets `Map.of()` appended as the last argument. The call sites are:

**platform-api/src/test/java/:**
- `DataSourceDescriptorTest.java` (3 sites)
- `DataSourceRegisteredTest.java` (1 site)
- `DataSourceDeregisteredTest.java` (1 site)

**datasource-inmem/src/test/java/:**
- `InMemoryDataSourceRegistryTest.java` (1 site)
- `DataSourceRouterTest.java` (6 sites)

**subscriptions/src/main/java/:**
- `SubscriptionEngine.java` (1 site — the notification DataSource descriptor)

**subscriptions/src/test/java/:**
- `SubscriptionEngineTest.java` (4 sites)

**platform/src/test/java/:**
- `NoOpDataSourceRegistryTest.java` (1 site)

Use `ide_search_text` to find all `new DataSourceDescriptor(` and update each via
`ide_replace_member` or targeted edits.

- [ ] **Step 5: Update Marshaller.java javadoc**

Use `ide_edit_member` to replace the Marshaller interface declaration. Remove the
reference to non-existent `MarshallNode`:

```java
/**
 * Transforms objects from one type to another.
 *
 * <p>Used as a pre-processing decorator on {@link DataSource#add(Object)} when
 * configured via {@link DataSourceDescriptor#marshallerKeys()}. Typical use case:
 * unmarshalling {@code CloudEvent} payloads into domain objects before alpha
 * network routing.
 *
 * @param <I> input type
 * @param <O> output type
 */
@FunctionalInterface
public interface Marshaller<I, O> {
    O marshal(I input) throws MarshalException;
}
```

- [ ] **Step 6: Create NoOpMarshallerRegistry**

Create `platform/src/main/java/io/casehub/platform/datasource/NoOpMarshallerRegistry.java`:

```java
package io.casehub.platform.datasource;

import io.casehub.platform.api.datasource.Marshaller;
import io.casehub.platform.api.datasource.MarshallerRegistry;
import io.quarkus.arc.DefaultBean;
import jakarta.enterprise.context.ApplicationScoped;
import java.util.Optional;

@DefaultBean
@ApplicationScoped
public class NoOpMarshallerRegistry implements MarshallerRegistry {

    @Override
    public void register(String key, Marshaller<?, ?> marshaller) {
        // Silent no-op — no marshallers stored
    }

    @Override
    public Optional<Marshaller<?, ?>> resolve(String key) {
        return Optional.empty();
    }
}
```

- [ ] **Step 7: Build and test**

```bash
mvn --batch-mode -f /Users/mdproctor/claude/casehub/platform/pom.xml compile test-compile -q
mvn --batch-mode -f /Users/mdproctor/claude/casehub/platform/pom.xml test -q
```

Expected: BUILD SUCCESS, all tests pass.

- [ ] **Step 8: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add -A
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#139): MarshallerRegistry SPI and marshallerKeys on DataSourceDescriptor"
```

---

### Task 4: DataSource Descriptor Update — SPI (#172)

**Files:**
- Modify: `platform-api/src/main/java/io/casehub/platform/api/datasource/DataSourceRegistry.java` — add `update()` method
- Create: `platform-api/src/main/java/io/casehub/platform/api/datasource/DataSourceUpdated.java`
- Modify: `platform/src/main/java/io/casehub/platform/datasource/NoOpDataSourceRegistry.java` — add `update()` no-op
- Modify: `datasource-inmem/src/main/java/io/casehub/platform/datasource/memory/InMemoryDataSourceRegistry.java` — add `update()`
- Modify: `platform/src/main/java/io/casehub/platform/datasource/DataSourceRouter.java` — observe DataSourceUpdated
- Create: `platform-api/src/test/java/io/casehub/platform/api/datasource/DataSourceUpdatedTest.java`
- Modify: `datasource-inmem/src/test/java/io/casehub/platform/datasource/memory/InMemoryDataSourceRegistryTest.java` — add update tests
- Modify: `platform/src/test/java/io/casehub/platform/datasource/NoOpDataSourceRegistryTest.java` — add update test

**Interfaces:**
- Consumes: `DataSourceRegistry` (existing), `DataSourceDescriptor.marshallerKeys()` from Task 3
- Produces: `DataSourceRegistry.update(DataSourceDescriptor)`, `DataSourceUpdated(old, new, dataSource)` CDI event

- [ ] **Step 1: Write DataSourceUpdated record test**

Create `platform-api/src/test/java/io/casehub/platform/api/datasource/DataSourceUpdatedTest.java`:

```java
package io.casehub.platform.api.datasource;

import io.casehub.platform.api.path.Path;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;
import java.util.Map;
import java.util.Set;

class DataSourceUpdatedTest {

    @Test
    void nullsRejected() {
        var desc = new DataSourceDescriptor(
            Path.of("test"), "t1", new ClassObjectType<>(Object.class), null,
            Set.of(), Map.of(), Map.of());
        DataSource<?> ds = new DataSource<>() {
            @Override public void add(Object value) {}
            @Override public SubscriptionHandle subscribe(DataProcessor<? super Object> p) { return null; }
            @Override public <U> SubscriptionHandle subscribe(ObjectType<U> t, DataProcessor<? super U> p) { return null; }
            @Override public <U> SubscriptionHandle subscribe(ObjectType<U> t, java.util.function.Predicate<U> f, DataProcessor<? super U> p) { return null; }
            @Override public <U> SubscriptionHandle subscribe(Class<U> t, java.util.function.Predicate<U> f, DataProcessor<? super U> p) { return null; }
        };

        assertThatThrownBy(() -> new DataSourceUpdated(null, desc, ds))
            .isInstanceOf(NullPointerException.class);
        assertThatThrownBy(() -> new DataSourceUpdated(desc, null, ds))
            .isInstanceOf(NullPointerException.class);
        assertThatThrownBy(() -> new DataSourceUpdated(desc, desc, null))
            .isInstanceOf(NullPointerException.class);
    }

    @Test
    void holdsAllFields() {
        var old = new DataSourceDescriptor(
            Path.of("test"), "t1", new ClassObjectType<>(Object.class), null,
            Set.of(), Map.of(), Map.of());
        var updated = new DataSourceDescriptor(
            Path.of("test"), "t1", new ClassObjectType<>(Object.class), Path.of("new-ep"),
            Set.of("order.created"), Map.of("k", "v"), Map.of());
        DataSource<?> ds = new DataSource<>() {
            @Override public void add(Object value) {}
            @Override public SubscriptionHandle subscribe(DataProcessor<? super Object> p) { return null; }
            @Override public <U> SubscriptionHandle subscribe(ObjectType<U> t, DataProcessor<? super U> p) { return null; }
            @Override public <U> SubscriptionHandle subscribe(ObjectType<U> t, java.util.function.Predicate<U> f, DataProcessor<? super U> p) { return null; }
            @Override public <U> SubscriptionHandle subscribe(Class<U> t, java.util.function.Predicate<U> f, DataProcessor<? super U> p) { return null; }
        };
        var event = new DataSourceUpdated(old, updated, ds);
        assertThat(event.oldDescriptor()).isSameAs(old);
        assertThat(event.newDescriptor()).isSameAs(updated);
        assertThat(event.dataSource()).isSameAs(ds);
    }
}
```

- [ ] **Step 2: Create DataSourceUpdated record**

Create `platform-api/src/main/java/io/casehub/platform/api/datasource/DataSourceUpdated.java`:

```java
package io.casehub.platform.api.datasource;

import java.util.Objects;

/**
 * CDI event fired by non-no-op {@link DataSourceRegistry} implementations after
 * every successful {@link DataSourceRegistry#update(DataSourceDescriptor)} call.
 *
 * <p>Carries the old and new descriptors plus the current DataSource instance.
 * The instance is necessary because marshalling changes may rebuild the decorator,
 * producing a new DataSource in the registry's sources map.
 */
public record DataSourceUpdated(
        DataSourceDescriptor oldDescriptor,
        DataSourceDescriptor newDescriptor,
        DataSource<?> dataSource) {

    public DataSourceUpdated {
        Objects.requireNonNull(oldDescriptor, "oldDescriptor");
        Objects.requireNonNull(newDescriptor, "newDescriptor");
        Objects.requireNonNull(dataSource, "dataSource");
    }
}
```

- [ ] **Step 3: Add update() to DataSourceRegistry SPI**

Use `ide_insert_member` to add `update()` after `deregister()` in DataSourceRegistry:

```java
/**
 * Update the descriptor for an existing DataSource registration.
 *
 * <p>Key match: {@code (path, tenancyId)} must match an existing registration.
 * The DataSource instance survives — active subscriptions are preserved.
 *
 * <p>Immutable field: {@code objectType} — changing objectType invalidates
 * TypeNode routing for existing subscribers. ObjectType changes require
 * {@link #deregister} followed by {@link #register}. Implementations MUST
 * throw {@code IllegalArgumentException} if objectType differs.
 *
 * <p>Non-no-op implementations MUST throw {@code IllegalStateException} if the
 * key is not found. The {@code @DefaultBean} NoOp is exempt (accepts silently).
 *
 * @throws IllegalStateException if key not found (non-no-op implementations)
 * @throws IllegalArgumentException if objectType differs from existing
 */
void update(DataSourceDescriptor descriptor);
```

- [ ] **Step 4: Implement update() in NoOpDataSourceRegistry**

Use `ide_insert_member` to add after `deregister()`:

```java
@Override
public void update(final DataSourceDescriptor descriptor) {
    // Silent no-op — consistent with displacement contract
}
```

- [ ] **Step 5: Write update() tests for InMemoryDataSourceRegistry**

Add tests to `InMemoryDataSourceRegistryTest`:

```java
@Test
void update_replacesDescriptor() {
    var desc = descriptor("test", "t1");
    registry.register(desc);
    var updated = new DataSourceDescriptor(
        Path.of("test"), "t1", new ClassObjectType<>(Object.class), Path.of("new-ep"),
        Set.of("order.created"), Map.of("k", "v"), Map.of());
    registry.update(updated);
    assertThat(registry.resolve(Path.of("test"), "t1")).contains(updated);
}

@Test
void update_throwsIfNotFound() {
    var desc = descriptor("nonexistent", "t1");
    assertThatThrownBy(() -> registry.update(desc))
        .isInstanceOf(IllegalStateException.class);
}

@Test
void update_throwsIfObjectTypeChanges() {
    var desc = descriptor("test", "t1");
    registry.register(desc);
    var changed = new DataSourceDescriptor(
        Path.of("test"), "t1", new ClassObjectType<>(String.class), null,
        Set.of(), Map.of(), Map.of());
    assertThatThrownBy(() -> registry.update(changed))
        .isInstanceOf(IllegalArgumentException.class);
}

@Test
void update_preservesDataSourceInstance() {
    var desc = descriptor("test", "t1");
    DataSource<?> ds = registry.register(desc);
    var updated = new DataSourceDescriptor(
        Path.of("test"), "t1", new ClassObjectType<>(Object.class), Path.of("new-ep"),
        Set.of(), Map.of(), Map.of());
    registry.update(updated);
    assertThat(registry.resolveSource(Path.of("test"), "t1")).containsSame(ds);
}
```

- [ ] **Step 6: Implement update() in InMemoryDataSourceRegistry**

Use `ide_insert_member` to add after `deregister()`:

```java
@Override
public void update(final DataSourceDescriptor descriptor) {
    final RegistryKey key = new RegistryKey(descriptor.path().value(), descriptor.tenancyId());
    final DataSourceDescriptor existing = descriptors.get(key);
    if (existing == null) {
        throw new IllegalStateException("No DataSource registered for path=" +
            descriptor.path() + ", tenancyId=" + descriptor.tenancyId());
    }
    if (!descriptor.objectType().getTypeKey().equals(existing.objectType().getTypeKey())) {
        throw new IllegalArgumentException("objectType is immutable — deregister and re-register to change type");
    }
    descriptors.put(key, descriptor);
    if (dataSourceUpdatedEvent != null) {
        DataSource<?> ds = sources.get(key);
        dataSourceUpdatedEvent.fireAsync(new DataSourceUpdated(existing, descriptor, ds))
            .whenComplete((e, t) -> {
                if (t != null) {
                    LOG.warnf(t, "DataSourceUpdated observer failed for path %s", descriptor.path());
                }
            });
    }
}
```

Also inject `Event<DataSourceUpdated> dataSourceUpdatedEvent` in the constructor.

- [ ] **Step 7: Add DataSourceUpdated observer to DataSourceRouter**

Use `ide_insert_member` to add after `onDataSourceDeregistered()`:

```java
public void onDataSourceUpdated(@ObservesAsync DataSourceUpdated event) {
    if (!started.get()) {
        pendingEvents.add(event);
        return;
    }
    var path = event.newDescriptor().path().value();
    var tenancyId = event.newDescriptor().tenancyId();
    for (int i = 0; i < wiredDataSources.size(); i++) {
        var wired = wiredDataSources.get(i);
        if (wired.descriptor().path().value().equals(path)
                && wired.descriptor().tenancyId().equals(tenancyId)) {
            wiredDataSources.set(i, new WiredDataSource(event.newDescriptor(), event.dataSource()));
            LOG.debugf("DataSource updated for path %s, tenant %s", path, tenancyId);
            return;
        }
    }
}
```

- [ ] **Step 8: Add update test to NoOpDataSourceRegistryTest**

```java
@Test
void update_silentNoOp() {
    var desc = new DataSourceDescriptor(
        Path.of("test"), "t1", new ClassObjectType<>(Object.class), null,
        Set.of(), Map.of(), Map.of());
    // NoOp does not throw — even though nothing is registered
    registry.update(desc);
}
```

- [ ] **Step 9: Build and test**

```bash
mvn --batch-mode -f /Users/mdproctor/claude/casehub/platform/pom.xml test -q
```

Expected: All tests pass.

- [ ] **Step 10: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add -A
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#172): DataSource descriptor update mechanism with DataSourceUpdated CDI event"
```

---

### Task 5: JPA-backed DataSourceRegistry (#171)

**Files:**
- Create: `datasource-jpa/pom.xml`
- Create: `datasource-jpa/src/main/java/io/casehub/platform/datasource/jpa/JpaDataSourceRegistry.java`
- Create: `datasource-jpa/src/main/java/io/casehub/platform/datasource/jpa/DataSourceDescriptorEntity.java`
- Create: `datasource-jpa/src/main/java/io/casehub/platform/datasource/jpa/RegistryKey.java`
- Create: `datasource-jpa/src/main/resources/db/datasource/migration/V4000__datasource_descriptor.sql`
- Create: `datasource-jpa/src/test/java/io/casehub/platform/datasource/jpa/JpaDataSourceRegistryTest.java`
- Create: `datasource-jpa/src/test/resources/application.properties`
- Modify: `pom.xml` (parent) — add `<module>datasource-jpa</module>`

**Interfaces:**
- Consumes: `DataSourceRegistry` (SPI), `AlphaDataSource` (from datasource-alpha, Task 2), `MarshallerRegistry` (Task 3), `DataSourceUpdated` (Task 4)
- Produces: `@ApplicationScoped JpaDataSourceRegistry` — JPA-backed DataSourceRegistry

- [ ] **Step 1: Create module structure and pom.xml**

```bash
mkdir -p /Users/mdproctor/claude/casehub/platform/datasource-jpa/src/main/java/io/casehub/platform/datasource/jpa
mkdir -p /Users/mdproctor/claude/casehub/platform/datasource-jpa/src/main/resources/db/datasource/migration
mkdir -p /Users/mdproctor/claude/casehub/platform/datasource-jpa/src/test/java/io/casehub/platform/datasource/jpa
mkdir -p /Users/mdproctor/claude/casehub/platform/datasource-jpa/src/test/resources
```

Write `datasource-jpa/pom.xml` — follows delivery-tracking-jpa pattern:

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

    <artifactId>casehub-platform-datasource-jpa</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform DataSource JPA</name>
    <description>JPA-backed DataSourceRegistry. @ApplicationScoped — Tier 2, beats @DefaultBean no-op.
        Hibernate ORM (blocking-only). Startup reconciliation restores DataSources from DB.
        Add as compile dep; consumers must add classpath:db/datasource/migration to
        quarkus.flyway.locations. Do NOT combine with datasource-inmem in production scope.</description>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-api</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-datasource-alpha</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-hibernate-orm-panache</artifactId>
        </dependency>
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-flyway</artifactId>
        </dependency>
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-jdbc-postgresql</artifactId>
            <optional>true</optional>
        </dependency>

        <!-- Test -->
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-testing</artifactId>
            <version>${project.version}</version>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-junit</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-jdbc-h2</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.assertj</groupId>
            <artifactId>assertj-core</artifactId>
            <scope>test</scope>
        </dependency>
    </dependencies>

    <build>
        <plugins>
            <plugin>
                <groupId>io.smallrye</groupId>
                <artifactId>jandex-maven-plugin</artifactId>
                <version>${jandex-maven-plugin.version}</version>
                <executions>
                    <execution>
                        <id>make-index</id>
                        <goals><goal>jandex</goal></goals>
                    </execution>
                </executions>
            </plugin>
        </plugins>
    </build>
</project>
```

- [ ] **Step 2: Write Flyway migration**

Create `datasource-jpa/src/main/resources/db/datasource/migration/V4000__datasource_descriptor.sql`:

```sql
-- DataSource descriptor persistence (platform#171)

CREATE TABLE IF NOT EXISTS datasource_descriptor (
    path              VARCHAR(1024) NOT NULL,
    tenancy_id        VARCHAR(255)  NOT NULL,
    object_type_key   VARCHAR(255)  NOT NULL,
    endpoint_path     VARCHAR(1024),
    accepted_event_types TEXT,
    properties        TEXT,
    marshaller_keys   TEXT,
    registered_at     TIMESTAMP WITH TIME ZONE NOT NULL,
    PRIMARY KEY (path, tenancy_id)
);
```

- [ ] **Step 3: Write test application.properties**

Create `datasource-jpa/src/test/resources/application.properties`:

```properties
quarkus.datasource.db-kind=h2
quarkus.datasource.jdbc.url=jdbc:h2:mem:test;DB_CLOSE_DELAY=-1
quarkus.hibernate-orm.database.generation=none
quarkus.flyway.locations=classpath:db/datasource/migration
quarkus.flyway.migrate-at-start=true
```

- [ ] **Step 4: Write DataSourceDescriptorEntity**

Create `datasource-jpa/src/main/java/io/casehub/platform/datasource/jpa/DataSourceDescriptorEntity.java`.
Follow `DeliveryAttemptEntity` pattern — public fields, `fromDomain()`/`toDomain()`.
Use `@IdClass` with a composite key class or `@EmbeddedId`. JSON fields as TEXT with
Jackson serialization in fromDomain/toDomain.

- [ ] **Step 5: Write RegistryKey**

Create `datasource-jpa/src/main/java/io/casehub/platform/datasource/jpa/RegistryKey.java`:

```java
package io.casehub.platform.datasource.jpa;

record RegistryKey(String path, String tenancyId) {}
```

- [ ] **Step 6: Write failing JpaDataSourceRegistry tests**

Create `datasource-jpa/src/test/java/io/casehub/platform/datasource/jpa/JpaDataSourceRegistryTest.java`.
Test: register persists and creates DataSource, resolve returns persisted descriptor,
resolveSource returns DataSource, discover queries, deregister removes, update
replaces descriptor, update throws on not-found, update throws on objectType change,
idempotent register returns existing DataSource.

- [ ] **Step 7: Implement JpaDataSourceRegistry**

Create `datasource-jpa/src/main/java/io/casehub/platform/datasource/jpa/JpaDataSourceRegistry.java`:
- `@ApplicationScoped`, injects `EntityManager`, `Event<DataSourceRegistered>`,
  `Event<DataSourceDeregistered>`, `Event<DataSourceUpdated>`
- In-memory `ConcurrentHashMap<RegistryKey, AlphaDataSource<?>>` for runtime DataSources
- In-memory `ConcurrentHashMap<RegistryKey, DataSourceDescriptor>` for descriptor cache
- `@Observes StartupEvent` loads all entities, creates AlphaDataSources, fires events
- `register()` — `@Transactional`, persist entity, create AlphaDataSource, fire event
- `resolve()`/`resolveSource()` — cache lookup with platform-global fallback
- `discover()` — JPQL query
- `deregister()` — `@Transactional`, remove entity, markForRemoval on AlphaDataSource
- `update()` — `@Transactional`, merge entity, objectType check, fire DataSourceUpdated

- [ ] **Step 8: Add module to parent pom.xml**

Add `<module>datasource-jpa</module>` after `<module>datasource-inmem</module>`.

- [ ] **Step 9: Build and test**

```bash
mvn --batch-mode -f /Users/mdproctor/claude/casehub/platform/pom.xml compile test-compile -q
mvn --batch-mode -f /Users/mdproctor/claude/casehub/platform/datasource-jpa/pom.xml test -q
```

- [ ] **Step 10: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add -A
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#171): JPA-backed DataSourceRegistry with Flyway V4000 migration"
```

---

### Task 6: InMemoryDeliveryChannelRegistry Extraction (#169)

**Files:**
- Create: `delivery-channel-inmem/pom.xml`
- Move: `notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/InMemoryDeliveryChannelRegistry.java` → `delivery-channel-inmem/src/main/java/io/casehub/platform/delivery/channel/inmem/`
- Modify: `notification-dispatch/pom.xml` — add delivery-channel-inmem dependency
- Modify: `pom.xml` (parent) — add `<module>delivery-channel-inmem</module>`

**Interfaces:**
- Produces: `@ApplicationScoped InMemoryDeliveryChannelRegistry` — same API, new module

- [ ] **Step 1: Create module structure**

```bash
mkdir -p /Users/mdproctor/claude/casehub/platform/delivery-channel-inmem/src/main/java/io/casehub/platform/delivery/channel/inmem
```

Write `delivery-channel-inmem/pom.xml`:

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

    <artifactId>casehub-platform-delivery-channel-inmem</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform Delivery Channel In-Memory</name>
    <description>@ApplicationScoped InMemoryDeliveryChannelRegistry — ConcurrentHashMap,
        startup-populated. Production implementation — channels are static, not dynamic.</description>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-api</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-arc</artifactId>
        </dependency>
    </dependencies>

    <build>
        <plugins>
            <plugin>
                <groupId>io.smallrye</groupId>
                <artifactId>jandex-maven-plugin</artifactId>
                <version>${jandex-maven-plugin.version}</version>
                <executions>
                    <execution>
                        <id>make-index</id>
                        <goals><goal>jandex</goal></goals>
                    </execution>
                </executions>
            </plugin>
        </plugins>
    </build>
</project>
```

- [ ] **Step 2: Move via IntelliJ**

```
ide_move_file(file="notification-dispatch/src/main/java/io/casehub/platform/notification/dispatch/InMemoryDeliveryChannelRegistry.java",
              destination="delivery-channel-inmem/src/main/java/io/casehub/platform/delivery/channel/inmem")
```

- [ ] **Step 3: Add dependency and module declarations**

Add `delivery-channel-inmem` as compile dep in `notification-dispatch/pom.xml`.
Add `<module>delivery-channel-inmem</module>` to parent pom.xml before `notification-dispatch`.

- [ ] **Step 4: Build and test**

```bash
mvn --batch-mode -f /Users/mdproctor/claude/casehub/platform/pom.xml compile test-compile -q
mvn --batch-mode -f /Users/mdproctor/claude/casehub/platform/notification-dispatch/pom.xml test -q
```

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add -A
git -C /Users/mdproctor/claude/casehub/platform commit -m "refactor(platform#169): extract InMemoryDeliveryChannelRegistry to delivery-channel-inmem module"
```

---

### Task 7: BUFFER_FOR_DIGEST Validation (#164)

**Files:**
- Create: `notifications/src/main/java/io/casehub/platform/notification/rest/PreferenceValidator.java`
- Modify: `notifications/src/main/java/io/casehub/platform/notification/rest/NotificationPreferenceResource.java` — inject and call validator
- Create: `notifications/src/test/java/io/casehub/platform/notification/rest/PreferenceValidatorTest.java`

**Interfaces:**
- Consumes: `DeliveryChannelRegistry`, `NotificationPreferenceUpdate`, `NotificationPreferences`
- Produces: `PreferenceValidator.validate()` — throws `IllegalArgumentException` on invalid BUFFER_FOR_DIGEST

- [ ] **Step 1: Write PreferenceValidator test**

Test cases: (1) BUFFER_FOR_DIGEST with at least one digested channel passes, (2) BUFFER_FOR_DIGEST with zero digested channels throws, (3) non-BUFFER_FOR_DIGEST action passes regardless, (4) null quiet hours action passes.

- [ ] **Step 2: Implement PreferenceValidator**

`@ApplicationScoped` in `notifications/`. Inject `DeliveryChannelRegistry`. Check
effective channel preferences against channel defaults when BUFFER_FOR_DIGEST is set.

- [ ] **Step 3: Wire into NotificationPreferenceResource.update()**

Inject `PreferenceValidator`, call `validator.validate(update, existing)` before
`store.update()`. Load existing preferences first for the validation context.

- [ ] **Step 4: Test the wiring**

Add integration test in `NotificationPreferenceResourceTest` that verifies a PUT
with BUFFER_FOR_DIGEST and no digested channels returns 400.

- [ ] **Step 5: Build and test**

```bash
mvn --batch-mode -f /Users/mdproctor/claude/casehub/platform/notifications/pom.xml test -q
```

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add -A
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#164): validate BUFFER_FOR_DIGEST requires at least one digested channel"
```

---

### Task 8: Secondary Index for pendingKeysForUser (#165)

**Files:**
- Modify: `digest-inmem/src/main/java/io/casehub/platform/delivery/digest/inmem/InMemoryDigestBuffer.java` — add userIndex
- Modify: `digest-inmem/src/test/java/io/casehub/platform/delivery/digest/inmem/InMemoryDigestBufferTest.java` — add index tests

**Interfaces:**
- Consumes: `DigestBuffer` (SPI), `DigestBufferKey`
- Produces: O(1) `pendingKeysForUser()` via secondary reverse-lookup map

- [ ] **Step 1: Write test for O(1) lookup**

Add to `InMemoryDigestBufferTest`:

```java
@Test
void pendingKeysForUser_returnsOnlyMatchingKeys() {
    var key1 = new DigestBufferKey("user1", "t1", "email");
    var key2 = new DigestBufferKey("user1", "t1", "push");
    var key3 = new DigestBufferKey("user2", "t1", "email");
    buffer.add(key1, notification());
    buffer.add(key2, notification());
    buffer.add(key3, notification());

    var result = buffer.pendingKeysForUser("user1", "t1");
    assertThat(result).containsExactlyInAnyOrder(key1, key2);
}

@Test
void pendingKeysForUser_removedOnDrain() {
    var key = new DigestBufferKey("user1", "t1", "email");
    buffer.add(key, notification());
    buffer.drain(key);

    assertThat(buffer.pendingKeysForUser("user1", "t1")).isEmpty();
}
```

- [ ] **Step 2: Add secondary index**

Add to `InMemoryDigestBuffer`:

```java
private final ConcurrentHashMap<String, Set<DigestBufferKey>> userIndex =
    new ConcurrentHashMap<>();

private static String userKey(String userId, String tenancyId) {
    return userId + "|" + tenancyId;
}
```

Update `add()` — after adding to `buffers`, add to `userIndex`:
```java
userIndex.compute(userKey(key.userId(), key.tenancyId()), (k, set) -> {
    if (set == null) set = ConcurrentHashMap.newKeySet();
    set.add(key);
    return set;
});
```

Update `drain()` — after removing from `buffers`, remove from `userIndex`:
```java
if (entry != null) {
    userIndex.computeIfPresent(userKey(key.userId(), key.tenancyId()), (k, set) -> {
        set.remove(key);
        return set.isEmpty() ? null : set;
    });
}
```

Replace `pendingKeysForUser()`:
```java
@Override
public Set<DigestBufferKey> pendingKeysForUser(String userId, String tenancyId) {
    var set = userIndex.get(userKey(userId, tenancyId));
    return set != null ? Set.copyOf(set) : Set.of();
}
```

- [ ] **Step 3: Build and test**

```bash
mvn --batch-mode -f /Users/mdproctor/claude/casehub/platform/digest-inmem/pom.xml test -q
```

- [ ] **Step 4: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add -A
git -C /Users/mdproctor/claude/casehub/platform commit -m "perf(platform#165): secondary index for InMemoryDigestBuffer.pendingKeysForUser"
```

---

### Task 9: Digest Buffer Retention (#167)

**Files:**
- Modify: `digest-jpa/src/main/java/io/casehub/platform/delivery/digest/jpa/JpaDigestBuffer.java` — add retentionPurge()
- Modify: `digest-inmem/src/main/java/io/casehub/platform/delivery/digest/inmem/InMemoryDigestBuffer.java` — add TTL eviction
- Modify: `digest-jpa/src/test/java/io/casehub/platform/delivery/digest/jpa/JpaDigestBufferTest.java` — add retention test
- Modify: `digest-inmem/src/test/java/io/casehub/platform/delivery/digest/inmem/InMemoryDigestBufferTest.java` — add TTL test

**Interfaces:**
- Consumes: `DigestBuffer` (SPI), `DigestBufferKey`
- Produces: `@Scheduled retentionPurge()` in JPA, lazy TTL eviction in InMem

- [ ] **Step 1: Write JPA retention test**

Add to `JpaDigestBufferTest`:

```java
@Test
@TestTransaction
void retentionPurge_removesOnlyOrphanKeys() {
    // key1: all entries old → should be purged
    // key2: mix of old and recent → should NOT be purged
    // Insert old entry for key1 (buffered_at = 91 days ago)
    // Insert old entry for key2 (buffered_at = 91 days ago)
    // Insert recent entry for key2 (buffered_at = now)
    // Run retentionPurge()
    // Verify key1 entries deleted, key2 entries preserved
}
```

- [ ] **Step 2: Implement JPA retention purge**

Use `ide_insert_member` to add to `JpaDigestBuffer`:

```java
@ConfigProperty(name = "casehub.notification.digest.retention-days", defaultValue = "90")
int retentionDays;

@Scheduled(cron = "0 0 3 * * ?")
@Transactional
void retentionPurge() {
    Instant cutoff = Instant.now().minus(Duration.ofDays(retentionDays));
    int purged = entityManager.createQuery(
            "DELETE FROM DigestBufferEntity e WHERE e.bufferedAt < :cutoff " +
            "AND NOT EXISTS (" +
            "  SELECT 1 FROM DigestBufferEntity recent " +
            "  WHERE recent.userId = e.userId " +
            "  AND recent.tenancyId = e.tenancyId " +
            "  AND recent.channelId = e.channelId " +
            "  AND recent.bufferedAt >= :cutoff" +
            ")")
        .setParameter("cutoff", cutoff)
        .executeUpdate();
    if (purged > 0) {
        LOG.infof("Digest retention purge: %d orphan rows removed", purged);
    }
}
```

- [ ] **Step 3: Write InMem TTL test**

Add to `InMemoryDigestBufferTest`:

```java
@Test
void expiredEntries_notVisibleInPendingKeys() {
    // Add entry, manually set firstAdded to beyond retention period
    // Verify pendingKeys() does not include it
    // Verify pendingKeysForUser() does not include it
    // Verify pendingCount() returns 0
    // Verify drain() returns empty
}
```

- [ ] **Step 4: Implement InMem TTL eviction**

Add `lastModified` to `BufferEntry`. Add `retentionDays` config property. Add
private `isExpired(BufferEntry)` method. Apply TTL check in `pendingKeys()`,
`pendingKeysForUser()`, `pendingCount()`, `oldestPendingTimestamp()`, and `drain()`.

- [ ] **Step 5: Build and test**

```bash
mvn --batch-mode -f /Users/mdproctor/claude/casehub/platform/digest-jpa/pom.xml test -q
mvn --batch-mode -f /Users/mdproctor/claude/casehub/platform/digest-inmem/pom.xml test -q
```

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add -A
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#167): digest buffer orphan retention — JPA scheduled purge + InMem TTL eviction"
```
