# DataSource Deregistration Lifecycle — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #138 — DataSource deregistration lifecycle
**Issue group:** #138

**Goal:** Add Rete-style self-pruning to the DataSource system — reference-counted deregistration with CDI events, convergent router wiring, and subscription engine reaction.

**Architecture:** The alpha network already self-prunes (TypeNode removes empty FilterNodes, AlphaDataSource removes empty TypeNodes). This extends that pattern to the registry level via share counting. Deregistration marks a DataSource for removal; cleanup fires when the share count (active subscriber count) reaches zero. CDI events (`DataSourceDeregistered`) notify consumers, who unsubscribe their handles, triggering the bottom-up prune. Register becomes idempotent (first-descriptor-wins). The router uses convergent wiring with identity-based comparison to handle CDI event reordering.

**Tech Stack:** Java 21, Quarkus CDI, ConcurrentHashMap, AtomicInteger, JUnit 5, AssertJ, Mockito

## Global Constraints

- `platform-api/` must remain zero-dependency — no Quarkus, no JPA
- Pre-release: breaking contract changes cost nothing
- `DataSourceDeregistered` carries both `descriptor` and `dataSource` instance (identity comparison)
- Register is idempotent (first-descriptor-wins); upsert is removed
- Deregister javadoc uses eventual language (async CDI cascade)
- Thread safety: `synchronized(this)` on AlphaDataSource for markForRemoval and unsubscribe decrement-and-check; subscribe uses unsynchronized AtomicInteger increment
- Deregister cleanup callback uses `sources.remove(key, source)` with identity equality as authoritative guard, gating `descriptors.remove(key)`

---

### Task 1: DataSourceDeregistered CDI event + SPI javadoc (platform-api)

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/datasource/DataSourceDeregistered.java`
- Create: `platform-api/src/test/java/io/casehub/platform/api/datasource/DataSourceDeregisteredTest.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/datasource/DataSourceRegistry.java` — class-level javadoc, register() javadoc, deregister() javadoc
- Modify: `platform-api/src/main/java/io/casehub/platform/api/datasource/DataSourceDescriptor.java` — remove upsert language

**Interfaces:**
- Produces: `DataSourceDeregistered(DataSourceDescriptor descriptor, DataSource<?> dataSource)` — used by Tasks 3, 4, 5

- [ ] **Step 1: Write DataSourceDeregistered test**

```java
package io.casehub.platform.api.datasource;

import org.junit.jupiter.api.Test;
import io.casehub.platform.api.path.Path;
import java.util.Map;
import java.util.Set;
import java.util.function.Predicate;

import static org.assertj.core.api.Assertions.*;

class DataSourceDeregisteredTest {

    private final DataSourceDescriptor desc = new DataSourceDescriptor(
            Path.parse("test"), "t1",
            new ClassObjectType<>(Object.class), null,
            Set.of(), Map.of());

    private final DataSource<Object> stubDs = new DataSource<>() {
        @Override public void add(Object value) {}
        @Override public SubscriptionHandle subscribe(DataProcessor<? super Object> p) { return null; }
        @Override public <U> SubscriptionHandle subscribe(ObjectType<U> t, DataProcessor<? super U> p) { return null; }
        @Override public <U> SubscriptionHandle subscribe(ObjectType<U> t, Predicate<U> f, DataProcessor<? super U> p) { return null; }
        @Override public <U> SubscriptionHandle subscribe(Class<U> t, Predicate<U> f, DataProcessor<? super U> p) { return null; }
    };

    @Test
    void rejectsNullDescriptor() {
        assertThatThrownBy(() -> new DataSourceDeregistered(null, stubDs))
                .isInstanceOf(NullPointerException.class);
    }

    @Test
    void rejectsNullDataSource() {
        assertThatThrownBy(() -> new DataSourceDeregistered(desc, null))
                .isInstanceOf(NullPointerException.class);
    }

    @Test
    void holdsBothFields() {
        var event = new DataSourceDeregistered(desc, stubDs);
        assertThat(event.descriptor()).isSameAs(desc);
        assertThat(event.dataSource()).isSameAs(stubDs);
    }
}
```

- [ ] **Step 2: Run test — verify compile failure** (DataSourceDeregistered doesn't exist yet)

Run: `mvn -pl platform-api test -Dtest=DataSourceDeregisteredTest --batch-mode`

- [ ] **Step 3: Create DataSourceDeregistered record**

```java
package io.casehub.platform.api.datasource;

import java.util.Objects;

/**
 * CDI event fired by non-no-op {@link DataSourceRegistry} implementations after every
 * successful {@link DataSourceRegistry#deregister} call.
 *
 * <p>Consumers use this event to react to DataSource removals at runtime (e.g., router
 * unwiring routes, subscription engine releasing handles).
 *
 * <p>Carries both the descriptor and the {@link DataSource} instance being deregistered.
 * The instance enables identity-based comparison in CDI observers — necessary because
 * {@code @ObservesAsync} does not guarantee event ordering during deregister + register
 * sequences.
 *
 * <p>The no-op {@code @DefaultBean} implementation must NOT fire this event — it stores
 * nothing, and firing would trigger cleanup for phantom DataSources.
 *
 * <p>Any future non-no-op {@link DataSourceRegistry} implementation has a required
 * obligation to fire this event after marking the DataSource for removal.
 */
public record DataSourceDeregistered(DataSourceDescriptor descriptor, DataSource<?> dataSource) {

    public DataSourceDeregistered {
        Objects.requireNonNull(descriptor, "descriptor");
        Objects.requireNonNull(dataSource, "dataSource");
    }
}
```

- [ ] **Step 4: Run test — verify all 3 pass**

Run: `mvn -pl platform-api test -Dtest=DataSourceDeregisteredTest --batch-mode`

- [ ] **Step 5: Update DataSourceRegistry javadoc**

Update **class-level javadoc** — add `DataSourceDeregistered` obligation section after the existing `DataSourceRegistered` one.

Update **`register()` javadoc** — change from upsert to idempotent:
```
* <p>{@code (path, tenancyId)} is the unique key — idempotent: re-registering
* the same key returns the existing {@link DataSource} instance (first descriptor wins).
* Descriptor update requires explicit {@link #deregister} followed by {@code register()}.
```

Update **`deregister()` javadoc** — use eventual language:
```
* <p>Deregistering eventually stops further deliveries to all active subscriptions
* on that DataSource once CDI observers have processed the {@link DataSourceDeregistered}
* event and unsubscribed. Between {@code deregister()} returning and observer completion,
* deliveries continue and {@link SubscriptionHandle#isActive()} remains {@code true}.
```

- [ ] **Step 6: Update DataSourceDescriptor javadoc**

Change:
```
* <p>The unique key is {@code (path, tenancyId)}. Re-registering the same key replaces
* the descriptor — no merge semantics.
```
To:
```
* <p>The unique key is {@code (path, tenancyId)}. Registration is idempotent —
* re-registering the same key returns the existing DataSource (first descriptor wins).
* Descriptor update requires explicit deregister followed by register.
```

- [ ] **Step 7: Run full platform-api tests**

Run: `mvn -pl platform-api test --batch-mode`
Expected: all pass (javadoc changes are non-breaking)

- [ ] **Step 8: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform-api/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#138): DataSourceDeregistered CDI event + idempotent register contract"
```

---

### Task 2: AlphaDataSource reference counting + lifecycle (datasource-inmem)

**Files:**
- Modify: `datasource-inmem/src/main/java/io/casehub/platform/datasource/memory/AlphaDataSource.java`
- Modify: `datasource-inmem/src/test/java/io/casehub/platform/datasource/memory/AlphaDataSourceTest.java`

**Interfaces:**
- Consumes: nothing from Task 1
- Produces: `markForRemoval(Runnable onEmpty)`, `isPendingRemoval()`, share count tracking — used by Task 3

- [ ] **Step 1: Write reference counting tests**

Add to `AlphaDataSourceTest.java`:

```java
@Test
void markForRemoval_zeroSubscribers_firesImmediately() {
    var ds = new AlphaDataSource<>();
    var fired = new AtomicBoolean(false);
    ds.markForRemoval(() -> fired.set(true));
    assertThat(fired.get()).isTrue();
    assertThat(ds.isPendingRemoval()).isTrue();
}

@Test
void markForRemoval_activeSubscribers_defersCallback() {
    var ds = new AlphaDataSource<>();
    ds.subscribe(obj -> {});
    var fired = new AtomicBoolean(false);
    ds.markForRemoval(() -> fired.set(true));
    assertThat(fired.get()).isFalse();
    assertThat(ds.isPendingRemoval()).isTrue();
}

@Test
void lastUnsubscribe_afterMarkForRemoval_firesCallback() {
    var ds = new AlphaDataSource<>();
    var h1 = ds.subscribe(obj -> {});
    var h2 = ds.subscribe(obj -> {});
    var fired = new AtomicBoolean(false);
    ds.markForRemoval(() -> fired.set(true));
    assertThat(fired.get()).isFalse();

    h1.unsubscribe();
    assertThat(fired.get()).isFalse();

    h2.unsubscribe();
    assertThat(fired.get()).isTrue();
}

@Test
void unsubscribe_withoutMarkForRemoval_doesNotFireCallback() {
    var ds = new AlphaDataSource<>();
    var h = ds.subscribe(obj -> {});
    h.unsubscribe();
    // No exception, no callback — just normal unsubscribe
}

@Test
void subscribeDuringDrain_defersCleanup() {
    var ds = new AlphaDataSource<>();
    var h1 = ds.subscribe(obj -> {});
    var fired = new AtomicBoolean(false);
    ds.markForRemoval(() -> fired.set(true));

    // Subscribe during drain
    var h2 = ds.subscribe(obj -> {});
    h1.unsubscribe();
    assertThat(fired.get()).isFalse(); // h2 still active

    h2.unsubscribe();
    assertThat(fired.get()).isTrue();
}

@Test
void isPendingRemoval_falseBeforeMark() {
    var ds = new AlphaDataSource<>();
    assertThat(ds.isPendingRemoval()).isFalse();
}

@Test
void typedSubscription_countsTowardShareCount() {
    var ds = new AlphaDataSource<>();
    var h = ds.subscribe(new ClassObjectType<>(String.class), (DataProcessor<? super String>) s -> {});
    var fired = new AtomicBoolean(false);
    ds.markForRemoval(() -> fired.set(true));
    assertThat(fired.get()).isFalse();

    h.unsubscribe();
    assertThat(fired.get()).isTrue();
}
```

- [ ] **Step 2: Run tests — verify compile failures** (markForRemoval, isPendingRemoval don't exist)

Run: `mvn -pl datasource-inmem test -Dtest=AlphaDataSourceTest --batch-mode`

- [ ] **Step 3: Implement reference counting on AlphaDataSource**

Add fields:
```java
private final AtomicInteger shareCount = new AtomicInteger(0);
private volatile boolean pendingRemoval = false;
private Runnable onEmpty;
```

Add lifecycle methods:
```java
void markForRemoval(Runnable onEmpty) {
    synchronized (this) {
        this.pendingRemoval = true;
        this.onEmpty = onEmpty;
        if (shareCount.get() == 0) {
            onEmpty.run();
        }
    }
}

boolean isPendingRemoval() {
    return pendingRemoval;
}

private void onSubscriberRemoved() {
    synchronized (this) {
        if (shareCount.decrementAndGet() == 0 && pendingRemoval) {
            onEmpty.run();
        }
    }
}
```

Modify all `subscribe()` overloads to increment `shareCount` before wiring:
```java
@Override
public SubscriptionHandle subscribe(DataProcessor<? super T> processor) {
    shareCount.incrementAndGet();
    directSubscribers.addSubscriber(processor);
    return new Handle(() -> directSubscribers.removeSubscriber(processor), this);
}
```

Same pattern for the `ObjectType` and `ObjectType + Predicate` variants. The `Class<U>` convenience variant delegates to the `ObjectType` variant (no change needed — count is incremented by the delegate).

Modify `Handle` — add `AlphaDataSource<?>` owner reference, call `onSubscriberRemoved()` after unwiring:
```java
private static final class Handle implements SubscriptionHandle {

    private final AtomicBoolean active = new AtomicBoolean(true);
    private final Runnable unsubscribeAction;
    private final AlphaDataSource<?> owner;

    Handle(Runnable unsubscribeAction, AlphaDataSource<?> owner) {
        this.unsubscribeAction = unsubscribeAction;
        this.owner = owner;
    }

    @Override
    public void unsubscribe() {
        if (active.compareAndSet(true, false)) {
            unsubscribeAction.run();
            owner.onSubscriberRemoved();
        }
    }

    @Override
    public boolean isActive() {
        return active.get();
    }
}
```

- [ ] **Step 4: Run AlphaDataSource tests — verify all pass**

Run: `mvn -pl datasource-inmem test -Dtest=AlphaDataSourceTest --batch-mode`
Expected: all existing tests + 7 new tests pass

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add datasource-inmem/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#138): AlphaDataSource reference counting + markForRemoval lifecycle"
```

---

### Task 3: InMemoryDataSourceRegistry idempotent register + lifecycle deregister (datasource-inmem)

**Files:**
- Modify: `datasource-inmem/src/main/java/io/casehub/platform/datasource/memory/InMemoryDataSourceRegistry.java`
- Modify: `datasource-inmem/src/test/java/io/casehub/platform/datasource/memory/InMemoryDataSourceRegistryTest.java`

**Interfaces:**
- Consumes: `AlphaDataSource.markForRemoval(Runnable)`, `AlphaDataSource.isPendingRemoval()` from Task 2; `DataSourceDeregistered` from Task 1
- Produces: idempotent `register()`, lifecycle-aware `deregister()` with CDI event firing — used by Tasks 4, 5

- [ ] **Step 1: Write idempotent register + lifecycle deregister tests**

Add to `InMemoryDataSourceRegistryTest.java`:

```java
@Test
void register_idempotent_returnsSameDataSource() {
    DataSource<?> ds1 = registry.register(descriptor("test", "t1"));
    DataSource<?> ds2 = registry.register(descriptor("test", "t1"));
    assertThat(ds2).isSameAs(ds1);
}

@Test
void deregister_noSubscribers_cleansImmediately() {
    registry.register(descriptor("test", "t1"));
    registry.deregister(Path.parse("test"), "t1");
    assertThat(registry.resolve(Path.parse("test"), "t1")).isEmpty();
    assertThat(registry.resolveSource(Path.parse("test"), "t1")).isEmpty();
}

@Test
void deregister_activeSubscribers_defersCleanup() {
    DataSource<?> ds = registry.register(descriptor("test", "t1"));
    @SuppressWarnings("unchecked")
    var handle = ((DataSource<Object>) ds).subscribe(obj -> {});

    registry.deregister(Path.parse("test"), "t1");

    // Still resolvable during drain
    assertThat(registry.resolve(Path.parse("test"), "t1")).isPresent();
    assertThat(registry.resolveSource(Path.parse("test"), "t1")).isPresent();

    handle.unsubscribe();

    // Cleaned after last subscriber leaves
    assertThat(registry.resolve(Path.parse("test"), "t1")).isEmpty();
    assertThat(registry.resolveSource(Path.parse("test"), "t1")).isEmpty();
}

@Test
void register_duringDrain_createsNewDataSource() {
    DataSource<?> ds1 = registry.register(descriptor("test", "t1"));
    @SuppressWarnings("unchecked")
    var handle = ((DataSource<Object>) ds1).subscribe(obj -> {});

    registry.deregister(Path.parse("test"), "t1");

    // Re-register during drain
    DataSource<?> ds2 = registry.register(descriptor("test", "t1"));
    assertThat(ds2).isNotSameAs(ds1);

    // Old handle unsubscribes — should NOT remove new DataSource
    handle.unsubscribe();
    assertThat(registry.resolveSource(Path.parse("test"), "t1")).isPresent();
    assertThat(registry.resolveSource(Path.parse("test"), "t1").get()).isSameAs(ds2);
}

@Test
void deregister_unknownKey_noOp() {
    registry.deregister(Path.parse("nonexistent"), "t1");
    // No exception
}
```

- [ ] **Step 2: Run tests — verify failures** (register now returns new instance each time)

Run: `mvn -pl datasource-inmem test -Dtest=InMemoryDataSourceRegistryTest --batch-mode`

- [ ] **Step 3: Implement idempotent register**

Replace `register()`:
```java
@Override
public DataSource<?> register(final DataSourceDescriptor descriptor) {
    final RegistryKey key = new RegistryKey(descriptor.path().value(), descriptor.tenancyId());
    final boolean[] created = {false};

    DataSource<?> result = sources.compute(key, (k, existing) -> {
        if (existing instanceof AlphaDataSource<?> alpha && !alpha.isPendingRemoval()) {
            return existing;
        }
        created[0] = true;
        return new AlphaDataSource<>();
    });

    if (created[0]) {
        descriptors.put(key, descriptor);
        if (dataSourceRegisteredEvent != null) {
            dataSourceRegisteredEvent.fireAsync(new DataSourceRegistered(descriptor))
                .whenComplete((e, t) -> {
                    if (t != null) {
                        LOG.warnf(t, "DataSourceRegistered observer failed for path %s",
                            descriptor.path());
                    }
                });
        }
    }

    return result;
}
```

- [ ] **Step 4: Implement lifecycle-aware deregister**

Add `Event<DataSourceDeregistered>` field and update constructors:
```java
private final Event<DataSourceDeregistered> dataSourceDeregisteredEvent;

@Inject
public InMemoryDataSourceRegistry(Event<DataSourceRegistered> dataSourceRegisteredEvent,
                                   Event<DataSourceDeregistered> dataSourceDeregisteredEvent) {
    this.dataSourceRegisteredEvent = dataSourceRegisteredEvent;
    this.dataSourceDeregisteredEvent = dataSourceDeregisteredEvent;
}

InMemoryDataSourceRegistry() {
    this.dataSourceRegisteredEvent = null;
    this.dataSourceDeregisteredEvent = null;
}
```

Replace `deregister()`:
```java
@Override
public void deregister(final Path path, final String tenancyId) {
    final RegistryKey key = new RegistryKey(path.value(), tenancyId);
    final AlphaDataSource<?> source = (AlphaDataSource<?>) sources.get(key);
    if (source == null) {
        return;
    }
    final DataSourceDescriptor descriptor = descriptors.get(key);

    source.markForRemoval(() -> {
        if (sources.remove(key, source)) {
            descriptors.remove(key);
        }
    });

    if (descriptor != null && dataSourceDeregisteredEvent != null) {
        dataSourceDeregisteredEvent.fireAsync(new DataSourceDeregistered(descriptor, source))
            .whenComplete((e, t) -> {
                if (t != null) {
                    LOG.warnf(t, "DataSourceDeregistered observer failed for path %s", path);
                }
            });
    }
}
```

- [ ] **Step 5: Fix existing test constructor calls**

The no-arg constructor now sets both event fields to null — tests using `new InMemoryDataSourceRegistry()` need no change.

`SubscriptionEngineTest` uses `new InMemoryDataSourceRegistry(null)` (single-arg) — this will no longer compile. Update to `new InMemoryDataSourceRegistry()`.

File: `subscriptions/src/test/java/io/casehub/platform/subscription/engine/SubscriptionEngineTest.java`
Change: `registry = new InMemoryDataSourceRegistry(null);` → `registry = new InMemoryDataSourceRegistry();`

- [ ] **Step 6: Run all datasource-inmem tests**

Run: `mvn -pl datasource-inmem test --batch-mode`
Expected: all pass — existing `deregister_removesBoth` test still works (zero subscribers → immediate cleanup)

- [ ] **Step 7: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add datasource-inmem/ platform-api/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#138): idempotent register + lifecycle-aware deregister with CDI event"
```

---

### Task 4: DataSourceRouter convergent wiring + identity-aware unwiring (platform)

**Files:**
- Modify: `platform/src/main/java/io/casehub/platform/datasource/DataSourceRouter.java`
- Modify: `datasource-inmem/src/test/java/io/casehub/platform/datasource/memory/DataSourceRouterTest.java`

**Interfaces:**
- Consumes: `DataSourceDeregistered` from Task 1; `InMemoryDataSourceRegistry` from Task 3
- Produces: convergent router — consumers of DataSource events see correct routing regardless of CDI event order

- [ ] **Step 1: Write deregistration and convergence tests**

Add to `DataSourceRouterTest.java`:

```java
@Test
void deregister_removesWiredRoute() {
    DataSourceDescriptor descriptor = new DataSourceDescriptor(
            Path.parse("siem"), "t1",
            new ClassObjectType<>(CloudEvent.class), null,
            Set.of(), Map.of());
    DataSource<?> ds = registry.register(descriptor);
    List<Object> received = new ArrayList<>();
    ds.subscribe(received::add);

    router.onStartup(null);
    router.onDataSourceRegistered(new DataSourceRegistered(descriptor));
    router.onDataSourceDeregistered(new DataSourceDeregistered(descriptor, ds));
    router.onCloudEvent(cloudEvent("siem.alert", "t1"));

    assertThat(received).isEmpty();
}

@Test
void deregister_identityMismatch_doesNotRemove() {
    DataSourceDescriptor descriptor = new DataSourceDescriptor(
            Path.parse("siem"), "t1",
            new ClassObjectType<>(CloudEvent.class), null,
            Set.of(), Map.of());
    DataSource<?> ds = registry.register(descriptor);
    List<Object> received = new ArrayList<>();
    ds.subscribe(received::add);

    router.onStartup(null);
    router.onDataSourceRegistered(new DataSourceRegistered(descriptor));

    // Deregister event with a DIFFERENT DataSource instance — should be ignored
    DataSource<Object> otherDs = new AlphaDataSource<>();
    router.onDataSourceDeregistered(new DataSourceDeregistered(descriptor, otherDs));
    router.onCloudEvent(cloudEvent("siem.alert", "t1"));

    assertThat(received).hasSize(1);
}

@Test
void wireRoute_replacesWhenInstanceChanges() {
    DataSourceDescriptor descriptor = new DataSourceDescriptor(
            Path.parse("siem"), "t1",
            new ClassObjectType<>(CloudEvent.class), null,
            Set.of(), Map.of());

    // First registration
    DataSource<?> ds1 = registry.register(descriptor);
    List<Object> received1 = new ArrayList<>();
    ds1.subscribe(received1::add);

    router.onStartup(null);
    router.onDataSourceRegistered(new DataSourceRegistered(descriptor));

    // Deregister + re-register (simulates drain-aware replacement)
    @SuppressWarnings("unchecked")
    var handle = ((DataSource<Object>) ds1).subscribe(obj -> {});
    registry.deregister(Path.parse("siem"), "t1");
    handle.unsubscribe(); // drain completes

    DataSource<?> ds2 = registry.register(descriptor);
    List<Object> received2 = new ArrayList<>();
    ds2.subscribe(received2::add);

    router.onDataSourceRegistered(new DataSourceRegistered(descriptor));
    router.onCloudEvent(cloudEvent("siem.alert", "t1"));

    assertThat(received1).isEmpty();
    assertThat(received2).hasSize(1);
}

@Test
void wireRoute_skipsWhenResolveReturnsEmpty() {
    DataSourceDescriptor descriptor = new DataSourceDescriptor(
            Path.parse("siem"), "t1",
            new ClassObjectType<>(CloudEvent.class), null,
            Set.of(), Map.of());
    registry.register(descriptor);
    registry.deregister(Path.parse("siem"), "t1");

    router.onStartup(null);
    // DataSourceRegistered event arrives after deregistration completed
    router.onDataSourceRegistered(new DataSourceRegistered(descriptor));

    // Route should not be wired — resolveSource returns empty
    router.onCloudEvent(cloudEvent("siem.alert", "t1"));
    // No exception, no routing — silent skip
}
```

- [ ] **Step 2: Run tests — verify compile failure** (onDataSourceDeregistered doesn't exist)

Run: `mvn -pl datasource-inmem test -Dtest=DataSourceRouterTest --batch-mode`

- [ ] **Step 3: Implement convergent wireRoute and identity-aware unwireRoute**

Change `pendingEvents` type from `List<DataSourceRegistered>` to `List<Object>`:
```java
private final List<Object> pendingEvents = new ArrayList<>();
```

Replace `wireRoute`:
```java
private void wireRoute(DataSourceRegistered event) {
    DataSourceDescriptor descriptor = event.descriptor();

    var resolved = registry.resolveSource(descriptor.path(), descriptor.tenancyId());
    if (resolved.isEmpty()) {
        LOG.debugf("DataSourceRegistered but resolveSource empty (deregistered?): path=%s, tenancyId=%s",
                descriptor.path(), descriptor.tenancyId());
        return;
    }

    DataSource<?> dataSource = resolved.get();

    // Remove stale entry for same key with different instance
    wiredDataSources.removeIf(w ->
            w.descriptor().path().equals(descriptor.path())
            && w.descriptor().tenancyId().equals(descriptor.tenancyId())
            && w.dataSource() != dataSource);

    // Add if not already wired with this instance
    boolean alreadyWired = wiredDataSources.stream()
            .anyMatch(w -> w.descriptor().path().equals(descriptor.path())
                    && w.descriptor().tenancyId().equals(descriptor.tenancyId())
                    && w.dataSource() == dataSource);

    if (!alreadyWired) {
        wiredDataSources.add(new WiredDataSource(descriptor, dataSource));
        LOG.debugf("Wired DataSource: path=%s, tenancyId=%s", descriptor.path(), descriptor.tenancyId());
    }
}
```

Add `unwireRoute`:
```java
private void unwireRoute(DataSourceDeregistered event) {
    wiredDataSources.removeIf(w ->
            w.descriptor().path().equals(event.descriptor().path())
            && w.descriptor().tenancyId().equals(event.descriptor().tenancyId())
            && w.dataSource() == event.dataSource());
}
```

Add `onDataSourceDeregistered` observer:
```java
public void onDataSourceDeregistered(@ObservesAsync DataSourceDeregistered event) {
    if (!started.get()) {
        synchronized (pendingEvents) {
            pendingEvents.add(event);
        }
        return;
    }
    unwireRoute(event);
}
```

Update `onStartup` to dispatch both event types:
```java
public void onStartup(@Observes StartupEvent ev) {
    synchronized (pendingEvents) {
        for (Object event : pendingEvents) {
            if (event instanceof DataSourceRegistered r) {
                wireRoute(r);
            } else if (event instanceof DataSourceDeregistered d) {
                unwireRoute(d);
            }
        }
        pendingEvents.clear();
    }
    started.set(true);
    LOG.debug("DataSourceRouter started");
}
```

Update `onDataSourceRegistered` to add to `List<Object>`:
```java
public void onDataSourceRegistered(@ObservesAsync DataSourceRegistered event) {
    if (!started.get()) {
        synchronized (pendingEvents) {
            pendingEvents.add(event);
        }
        return;
    }
    wireRoute(event);
}
```

- [ ] **Step 4: Run all DataSourceRouter tests**

Run: `mvn -pl datasource-inmem test -Dtest=DataSourceRouterTest --batch-mode`
Expected: all 4 existing + 4 new tests pass

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform/ datasource-inmem/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#138): convergent DataSourceRouter wiring + identity-aware unwiring"
```

---

### Task 5: SubscriptionEngine deregistration reaction (subscriptions)

**Files:**
- Modify: `subscriptions/src/main/java/io/casehub/platform/subscription/engine/SubscriptionEngine.java`
- Modify: `subscriptions/src/test/java/io/casehub/platform/subscription/engine/SubscriptionEngineTest.java`

**Interfaces:**
- Consumes: `DataSourceDeregistered` from Task 1

- [ ] **Step 1: Write deregistration reaction tests**

Add to `SubscriptionEngineTest.java`:

```java
@Test
void onDataSourceDeregistered_notificationPath_unwiresAll() {
    engine.onStartup(null);
    var sub = subStore.store(subscriptionInput("owner1", "t1", "work.created", true));
    engine.onCreated(new SubscriptionCreated(sub));

    var ds = registry.resolveSource(NOTIFICATION_DATASOURCE_PATH, PLATFORM_TENANT_ID).orElseThrow();
    var desc = new DataSourceDescriptor(
            NOTIFICATION_DATASOURCE_PATH, PLATFORM_TENANT_ID,
            new ClassObjectType<>(Object.class), null, Set.of(), Map.of());

    engine.onDataSourceDeregistered(new DataSourceDeregistered(desc, ds));

    // Push event — should NOT match (engine unwired)
    pushEvent("work.created", "t1", UUID.randomUUID(), "actor1");
    assertThat(firedEvents).isEmpty();
}

@Test
void onDataSourceDeregistered_otherPath_ignored() {
    engine.onStartup(null);
    var sub = subStore.store(subscriptionInput("owner1", "t1", "work.created", true));
    engine.onCreated(new SubscriptionCreated(sub));

    var otherDesc = new DataSourceDescriptor(
            Path.parse("other/datasource"), PLATFORM_TENANT_ID,
            new ClassObjectType<>(Object.class), null, Set.of(), Map.of());
    DataSource<Object> otherDs = new AlphaDataSource<>();

    engine.onDataSourceDeregistered(new DataSourceDeregistered(otherDesc, otherDs));

    // Push event — should still match (notification DataSource unaffected)
    pushEvent("work.created", "t1", UUID.randomUUID(), "actor1");
    assertThat(firedEvents).hasSize(1);
}

@Test
void onCreated_afterDeregistration_skipsWithoutError() {
    engine.onStartup(null);

    var ds = registry.resolveSource(NOTIFICATION_DATASOURCE_PATH, PLATFORM_TENANT_ID).orElseThrow();
    var desc = new DataSourceDescriptor(
            NOTIFICATION_DATASOURCE_PATH, PLATFORM_TENANT_ID,
            new ClassObjectType<>(Object.class), null, Set.of(), Map.of());
    engine.onDataSourceDeregistered(new DataSourceDeregistered(desc, ds));

    var sub = subStore.store(subscriptionInput("owner1", "t1", "work.created", true));
    engine.onCreated(new SubscriptionCreated(sub));

    // No exception, subscription not wired (notification DataSource is null)
    pushEvent("work.created", "t1", UUID.randomUUID(), "actor1");
    assertThat(firedEvents).isEmpty();
}
```

- [ ] **Step 2: Run tests — verify compile failure** (onDataSourceDeregistered doesn't exist)

Run: `mvn -pl subscriptions test -Dtest=SubscriptionEngineTest --batch-mode`

- [ ] **Step 3: Implement SubscriptionEngine deregistration handler**

Add observer method:
```java
void onDataSourceDeregistered(@ObservesAsync final DataSourceDeregistered event) {
    if (!NOTIFICATION_DATASOURCE_PATH.equals(event.descriptor().path())) {
        return;
    }
    handles.forEach((id, handle) -> handle.unsubscribe());
    handles.clear();
    notificationDataSource = null;
    LOG.info("Notification DataSource deregistered — all subscriptions unwired");
}
```

Add null guard to `wireSubscription`:
```java
private void wireSubscription(final Subscription subscription) {
    if (notificationDataSource == null) {
        LOG.warnf("Cannot wire subscription %s — notification DataSource not available", subscription.id());
        return;
    }
    // ... existing implementation
}
```

Add same null guard to `wireAndReturnHandle`:
```java
private SubscriptionHandle wireAndReturnHandle(final Subscription subscription) {
    if (notificationDataSource == null) {
        LOG.warnf("Cannot wire subscription %s — notification DataSource not available", subscription.id());
        return null;
    }
    // ... existing implementation
}
```

Update `onUpdated` to handle null return from `wireAndReturnHandle` (already safe — `compute()` with null return removes the key).

- [ ] **Step 4: Run all SubscriptionEngine tests**

Run: `mvn -pl subscriptions test -Dtest=SubscriptionEngineTest --batch-mode`
Expected: all existing + 3 new tests pass

- [ ] **Step 5: Run full project build**

Run: `mvn --batch-mode install`
Expected: all modules compile and all tests pass

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add subscriptions/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#138): SubscriptionEngine observes DataSourceDeregistered — unwires handles + null guard"
```
