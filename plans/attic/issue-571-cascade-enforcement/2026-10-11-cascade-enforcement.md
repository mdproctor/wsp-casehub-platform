# Cascade Enforcement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #571 — feat: cascade enforcement in RegistryService — deregister propagation + orphan handling
**Issue group:** #571

**Goal:** Wire cascade enforcement into RegistryService so that deregistering an entry (or TTL expiry) applies CascadeRules to relationship targets — DEREGISTER, MARK_ORPHANED, NOTIFY, or NONE.

**Architecture:** A shared `CascadeEngine` (pure Java, framework-neutral) implements the cascade algorithm with cycle detection and depth limiting. Both `InMemoryRegistryService` and `JpaRegistryService` delegate to it via callback interfaces. `deregister()` returns `CascadeResult`. `HeartbeatScheduler` triggers cascade on TTL expiry with configurable grace period.

**Tech Stack:** Java 21, JUnit 5, AssertJ, Flyway (JPA migration)

## Global Constraints

- `platform-api/` must remain zero-dependency — pure Java only
- `registry-inmem-core` depends only on `platform-api` — no CDI, no Spring
- `registry-jpa-common` is framework-neutral — no CDI, no Spring (EntityManager only)
- All record constructors use `Objects.requireNonNull` for required fields
- Immutable records with defensive copies for collections
- Thread-safe via `java.util.concurrent` — never `synchronized`
- Pre-release: breaking SPI changes are acceptable

---

## Batch 1: SPI Types — CascadeRule, RegistryEntry, RegistryEvent, CascadeResult

### Task 1: Extend CascadeRule with onSourceExpired and cascadeGracePeriod

**Files:**
- Modify: `platform-api/src/main/java/io/casehub/platform/api/registry/CascadeRule.java`
- Test: `platform-api/src/test/java/io/casehub/platform/api/registry/CascadeRuleTest.java`

**Interfaces:**
- Produces: `CascadeRule(String relationshipType, CascadeAction onSourceDeregister, CascadeAction onSourceExpired, Duration cascadeGracePeriod)`, `effectiveOnSourceExpired()`, 2-arg convenience constructor

- [ ] **Step 1: Write failing tests for CascadeRule**

```java
package io.casehub.platform.api.registry;

import org.junit.jupiter.api.Test;
import java.time.Duration;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class CascadeRuleTest {

    @Test
    void fullConstructorSetsAllFields() {
        var rule = new CascadeRule("owns", CascadeAction.DEREGISTER,
                CascadeAction.NOTIFY, Duration.ofSeconds(30));
        assertThat(rule.relationshipType()).isEqualTo("owns");
        assertThat(rule.onSourceDeregister()).isEqualTo(CascadeAction.DEREGISTER);
        assertThat(rule.onSourceExpired()).isEqualTo(CascadeAction.NOTIFY);
        assertThat(rule.cascadeGracePeriod()).isEqualTo(Duration.ofSeconds(30));
    }

    @Test
    void convenienceConstructorDefaultsNullableFields() {
        var rule = new CascadeRule("owns", CascadeAction.DEREGISTER);
        assertThat(rule.onSourceExpired()).isNull();
        assertThat(rule.cascadeGracePeriod()).isNull();
    }

    @Test
    void effectiveOnSourceExpiredFallsBackToDeregister() {
        var rule = new CascadeRule("owns", CascadeAction.DEREGISTER);
        assertThat(rule.effectiveOnSourceExpired()).isEqualTo(CascadeAction.DEREGISTER);
    }

    @Test
    void effectiveOnSourceExpiredUsesExplicitValue() {
        var rule = new CascadeRule("owns", CascadeAction.DEREGISTER,
                CascadeAction.NOTIFY, null);
        assertThat(rule.effectiveOnSourceExpired()).isEqualTo(CascadeAction.NOTIFY);
    }

    @Test
    void nullRelationshipTypeThrows() {
        assertThatThrownBy(() -> new CascadeRule(null, CascadeAction.DEREGISTER))
                .isInstanceOf(NullPointerException.class);
    }

    @Test
    void nullOnSourceDeregisterThrows() {
        assertThatThrownBy(() -> new CascadeRule("owns", null))
                .isInstanceOf(NullPointerException.class);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl platform-api -Dtest=CascadeRuleTest`
Expected: compilation failure (CascadeRule doesn't have the new fields yet)

- [ ] **Step 3: Implement CascadeRule changes**

Use `ide_replace_member` to replace the entire CascadeRule record body:

```java
package io.casehub.platform.api.registry;

import java.time.Duration;
import java.util.Objects;

public record CascadeRule(
        String relationshipType,
        CascadeAction onSourceDeregister,
        CascadeAction onSourceExpired,
        Duration cascadeGracePeriod
) {
    public CascadeRule {
        Objects.requireNonNull(relationshipType, "relationshipType");
        Objects.requireNonNull(onSourceDeregister, "onSourceDeregister");
    }

    public CascadeRule(String relationshipType, CascadeAction onSourceDeregister) {
        this(relationshipType, onSourceDeregister, null, null);
    }

    public CascadeAction effectiveOnSourceExpired() {
        return onSourceExpired != null ? onSourceExpired : onSourceDeregister;
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl platform-api -Dtest=CascadeRuleTest`
Expected: PASS (6 tests)

- [ ] **Step 5: Fix compilation in downstream modules**

The existing `InMemoryRegistryService` and `JpaRegistryService` use 2-arg `CascadeRule` constructor — these should still compile since we added the convenience constructor. Verify:

Run: `mvn --batch-mode compile -pl registry-inmem-core,registry-jpa-common`
Expected: compilation success

- [ ] **Step 6: Commit**

```bash
git add platform-api/src/main/java/io/casehub/platform/api/registry/CascadeRule.java platform-api/src/test/java/io/casehub/platform/api/registry/CascadeRuleTest.java
git commit -m "feat(registry): extend CascadeRule with onSourceExpired and cascadeGracePeriod Refs #571"
```

### Task 2: Add orphanedAt to RegistryEntry + new event kinds + CascadeResult types + deregister return type

**Files:**
- Modify: `platform-api/src/main/java/io/casehub/platform/api/registry/RegistryEntry.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/registry/RegistryEvent.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/registry/RegistryService.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/registry/CascadeResult.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/registry/CascadeEffect.java`
- Modify: `platform-api/src/test/java/io/casehub/platform/api/registry/RegistryEntryTest.java`
- Modify: `platform-core/src/main/java/io/casehub/platform/registry/NoOpRegistryService.java`

**Interfaces:**
- Consumes: `CascadeAction` (from platform-api)
- Produces: `RegistryEntry.orphanedAt()`, `isOrphaned()`, `withOrphaned(Instant)`, `CascadeResult`, `CascadeEffect`, `RegistryEvent.orphaned()`, `RegistryEvent.cascadeNotified()`, `RegistryService.deregister()` returns `CascadeResult`

- [ ] **Step 1: Write failing tests for RegistryEntry.orphanedAt**

Add to existing `RegistryEntryTest.java`:

```java
@Test
void orphanedAtDefaultsToNull() {
    var entry = new RegistryEntry("id", "type", "ns", "tenant",
            Map.of(), Instant.now(), null, Duration.ofSeconds(30),
            HealthStatus.HEALTHY, null);
    assertThat(entry.orphanedAt()).isNull();
    assertThat(entry.isOrphaned()).isFalse();
}

@Test
void withOrphanedSetsTimestamp() {
    var now = Instant.now();
    var entry = new RegistryEntry("id", "type", "ns", "tenant",
            Map.of(), Instant.now(), null, Duration.ofSeconds(30),
            HealthStatus.HEALTHY, null);
    var orphaned = entry.withOrphaned(now);
    assertThat(orphaned.orphanedAt()).isEqualTo(now);
    assertThat(orphaned.isOrphaned()).isTrue();
    assertThat(orphaned.health()).isEqualTo(HealthStatus.HEALTHY);
}

@Test
void withHealthPreservesOrphanedAt() {
    var now = Instant.now();
    var entry = new RegistryEntry("id", "type", "ns", "tenant",
            Map.of(), Instant.now(), null, Duration.ofSeconds(30),
            HealthStatus.HEALTHY, now);
    var down = entry.withHealth(HealthStatus.DOWN);
    assertThat(down.orphanedAt()).isEqualTo(now);
}

@Test
void withHeartbeatPreservesOrphanedAt() {
    var orphanedAt = Instant.now().minusSeconds(60);
    var entry = new RegistryEntry("id", "type", "ns", "tenant",
            Map.of(), Instant.now(), null, Duration.ofSeconds(30),
            HealthStatus.HEALTHY, orphanedAt);
    var heartbeated = entry.withHeartbeat(Instant.now());
    assertThat(heartbeated.orphanedAt()).isEqualTo(orphanedAt);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl platform-api -Dtest=RegistryEntryTest`
Expected: compilation failure

- [ ] **Step 3: Implement RegistryEntry changes**

Use `ide_replace_member` to update the RegistryEntry record. The key changes: add `Instant orphanedAt` parameter (nullable), add `isOrphaned()`, add `withOrphaned(Instant)`, update existing `withHealth()` and `withHeartbeat()` to carry orphanedAt through.

```java
package io.casehub.platform.api.registry;

import java.time.Duration;
import java.time.Instant;
import java.util.Map;
import java.util.Objects;

public record RegistryEntry(
        String id,
        String type,
        String namespace,
        String tenancyId,
        Map<String, String> metadata,
        Instant registeredAt,
        Instant lastHeartbeat,
        Duration ttl,
        HealthStatus health,
        Instant orphanedAt
) {
    public RegistryEntry {
        Objects.requireNonNull(id, "id");
        Objects.requireNonNull(type, "type");
        Objects.requireNonNull(namespace, "namespace");
        Objects.requireNonNull(tenancyId, "tenancyId");
        Objects.requireNonNull(metadata, "metadata");
        Objects.requireNonNull(registeredAt, "registeredAt");
        Objects.requireNonNull(ttl, "ttl");
        Objects.requireNonNull(health, "health");
        metadata = Map.copyOf(metadata);
    }

    public boolean isOrphaned() {
        return orphanedAt != null;
    }

    public RegistryEntry withOrphaned(Instant now) {
        return new RegistryEntry(id, type, namespace, tenancyId,
                metadata, registeredAt, lastHeartbeat, ttl, health, now);
    }

    public RegistryEntry withHealth(HealthStatus newHealth) {
        return new RegistryEntry(id, type, namespace, tenancyId,
                metadata, registeredAt, lastHeartbeat, ttl, newHealth, orphanedAt);
    }

    public RegistryEntry withHeartbeat(Instant now) {
        return new RegistryEntry(id, type, namespace, tenancyId,
                metadata, registeredAt, now, ttl, HealthStatus.HEALTHY, orphanedAt);
    }
}
```

- [ ] **Step 4: Create CascadeResult and CascadeEffect records**

Create `platform-api/src/main/java/io/casehub/platform/api/registry/CascadeResult.java`:

```java
package io.casehub.platform.api.registry;

import java.util.List;
import java.util.Objects;

public record CascadeResult(
        RegistryEntry deregistered,
        List<CascadeEffect> cascadeEffects
) {
    public CascadeResult {
        Objects.requireNonNull(cascadeEffects, "cascadeEffects");
        cascadeEffects = List.copyOf(cascadeEffects);
    }

    public static CascadeResult empty() {
        return new CascadeResult(null, List.of());
    }

    public static CascadeResult simple(RegistryEntry entry) {
        return new CascadeResult(entry, List.of());
    }

    public boolean hasFailures() {
        return cascadeEffects.stream().anyMatch(e -> e.failure() != null);
    }
}
```

Create `platform-api/src/main/java/io/casehub/platform/api/registry/CascadeEffect.java`:

```java
package io.casehub.platform.api.registry;

import java.util.Objects;

public record CascadeEffect(
        String targetId,
        CascadeAction action,
        Relationship relationship,
        RegistryEntry targetEntry,
        String failure
) {
    public CascadeEffect {
        Objects.requireNonNull(targetId, "targetId");
        Objects.requireNonNull(action, "action");
        Objects.requireNonNull(relationship, "relationship");
    }
}
```

- [ ] **Step 5: Add ORPHANED and CASCADE_NOTIFIED event kinds + factory methods**

Use `ide_edit_member` on RegistryEvent to add the new EventKind values and factory methods:

```java
// In EventKind enum, add:
ORPHANED, CASCADE_NOTIFIED

// Add factory methods:
public static RegistryEvent orphaned(RegistryEntry entry) {
    return new RegistryEvent(EventKind.ORPHANED, entry, null);
}

public static RegistryEvent cascadeNotified(RegistryEntry entry, Relationship rel) {
    return new RegistryEvent(EventKind.CASCADE_NOTIFIED, entry, rel);
}
```

- [ ] **Step 6: Change RegistryService.deregister return type**

Use `ide_edit_member` to change `deregister` signature in `RegistryService.java`:

```java
CascadeResult deregister(String id);
```

- [ ] **Step 7: Update NoOpRegistryService**

Use `ide_replace_member` to update `deregister` in `NoOpRegistryService.java`:

```java
@Override public CascadeResult deregister(String id) { return CascadeResult.empty(); }
```

- [ ] **Step 8: Fix compilation across all modules**

Run: `mvn --batch-mode compile`

All call sites that used `deregister()` as a void call will need updating. Fix each compilation error — callers that ignored the void return will now ignore the `CascadeResult` return (no functional change needed, just recompile).

Expected compilation failures in:
- `InMemoryRegistryService.deregister()` — currently returns void
- `JpaRegistryService.deregister()` — currently returns void
- `NoOpRegistryServiceTest` — may reference old constructor

Fix `InMemoryRegistryService.deregister()` temporarily to return `CascadeResult.simple(removed)` (full cascade wiring comes in Batch 2).
Fix `JpaRegistryService.deregister()` temporarily to return `CascadeResult.simple(entry)`.
Fix all `RegistryEntry` constructor calls to pass `null` as `orphanedAt`.

- [ ] **Step 9: Run all tests to verify everything passes**

Run: `mvn --batch-mode test -pl platform-api,platform-core,registry-inmem-core,registry-jpa-common`
Expected: PASS

- [ ] **Step 10: Commit**

```bash
git add platform-api/ platform-core/ registry-inmem-core/ registry-jpa-common/
git commit -m "feat(registry): add orphanedAt, CascadeResult, new event kinds, deregister return type Refs #571"
```

---

## Batch 2: CascadeEngine + InMemoryRegistryService Integration

### Task 3: Implement CascadeEngine with tests

**Files:**
- Create: `../../platform-api/src/main/java/io/casehub/platform/api/registry/CascadeEngine.java`
- Create: `registry-inmem-core/src/test/java/io/casehub/platform/registry/memory/CascadeEngineTest.java`

**Interfaces:**
- Consumes: `CascadeRule`, `CascadeAction`, `CascadeResult`, `CascadeEffect`, `RegistryEntry`, `RegistryEvent`, `Relationship`
- Produces: `CascadeEngine.applyCascade(sourceId, rules, actionSelector, resolver, relQuery, mutator, eventSink, visited, maxDepth)` → `List<CascadeEffect>`

- [ ] **Step 1: Write failing tests for CascadeEngine**

```java
package io.casehub.platform.registry.memory;

import io.casehub.platform.api.registry.*;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.time.Duration;
import java.time.Instant;
import java.util.*;
import java.util.function.Consumer;
import java.util.function.Function;

import static org.assertj.core.api.Assertions.assertThat;

class CascadeEngineTest {

    private CascadeEngine engine;
    private Map<String, RegistryEntry> entries;
    private List<Relationship> relationships;
    private List<RegistryEvent> events;

    @BeforeEach
    void setUp() {
        engine = new CascadeEngine();
        entries = new HashMap<>();
        relationships = new ArrayList<>();
        events = new ArrayList<>();
    }

    private RegistryEntry entry(String id) {
        return new RegistryEntry(id, "service", "default", "tenant-1",
                Map.of(), Instant.now(), null, Duration.ofSeconds(30),
                HealthStatus.HEALTHY, null);
    }

    private CascadeEngine.EntryMutator mutator() {
        return new CascadeEngine.EntryMutator() {
            @Override public void deregister(String id) { entries.remove(id); }
            @Override public void markOrphaned(String id, Instant now) {
                var e = entries.get(id);
                if (e != null) entries.put(id, e.withOrphaned(now));
            }
        };
    }

    private List<Relationship> outbound(String sourceId) {
        return relationships.stream()
                .filter(r -> r.sourceId().equals(sourceId)).toList();
    }

    @Test
    void deregisterCascade_removesTarget() {
        entries.put("A", entry("A"));
        entries.put("B", entry("B"));
        relationships.add(new Relationship("A", "B", "owns"));
        var rules = List.of(new CascadeRule("owns", CascadeAction.DEREGISTER));

        var effects = engine.applyCascade("A", rules,
                CascadeRule::onSourceDeregister,
                id -> Optional.ofNullable(entries.get(id)),
                this::outbound, mutator(), events::add,
                new HashSet<>(Set.of("A")), 10);

        assertThat(entries.containsKey("B")).isFalse();
        assertThat(effects).hasSize(1);
        assertThat(effects.get(0).action()).isEqualTo(CascadeAction.DEREGISTER);
        assertThat(effects.get(0).failure()).isNull();
    }

    @Test
    void markOrphanedCascade_setsOrphanedAt() {
        entries.put("A", entry("A"));
        entries.put("B", entry("B"));
        relationships.add(new Relationship("A", "B", "owns"));
        var rules = List.of(new CascadeRule("owns", CascadeAction.MARK_ORPHANED));

        engine.applyCascade("A", rules,
                CascadeRule::onSourceDeregister,
                id -> Optional.ofNullable(entries.get(id)),
                this::outbound, mutator(), events::add,
                new HashSet<>(Set.of("A")), 10);

        assertThat(entries.get("B").isOrphaned()).isTrue();
        assertThat(events).anyMatch(e -> e.kind() == RegistryEvent.EventKind.ORPHANED);
    }

    @Test
    void notifyCascade_firesEventNoStateChange() {
        entries.put("A", entry("A"));
        entries.put("B", entry("B"));
        relationships.add(new Relationship("A", "B", "owns"));
        var rules = List.of(new CascadeRule("owns", CascadeAction.NOTIFY));

        engine.applyCascade("A", rules,
                CascadeRule::onSourceDeregister,
                id -> Optional.ofNullable(entries.get(id)),
                this::outbound, mutator(), events::add,
                new HashSet<>(Set.of("A")), 10);

        assertThat(entries.containsKey("B")).isTrue();
        assertThat(entries.get("B").isOrphaned()).isFalse();
        assertThat(events).anyMatch(e -> e.kind() == RegistryEvent.EventKind.CASCADE_NOTIFIED);
    }

    @Test
    void noneCascade_doesNothing() {
        entries.put("A", entry("A"));
        entries.put("B", entry("B"));
        relationships.add(new Relationship("A", "B", "owns"));
        var rules = List.of(new CascadeRule("owns", CascadeAction.NONE));

        var effects = engine.applyCascade("A", rules,
                CascadeRule::onSourceDeregister,
                id -> Optional.ofNullable(entries.get(id)),
                this::outbound, mutator(), events::add,
                new HashSet<>(Set.of("A")), 10);

        assertThat(entries.containsKey("B")).isTrue();
        assertThat(effects).isEmpty();
    }

    @Test
    void recursiveCascade_A_B_C() {
        entries.put("A", entry("A"));
        entries.put("B", entry("B"));
        entries.put("C", entry("C"));
        relationships.add(new Relationship("A", "B", "owns"));
        relationships.add(new Relationship("B", "C", "owns"));
        var rules = List.of(new CascadeRule("owns", CascadeAction.DEREGISTER));

        var effects = engine.applyCascade("A", rules,
                CascadeRule::onSourceDeregister,
                id -> Optional.ofNullable(entries.get(id)),
                this::outbound, mutator(), events::add,
                new HashSet<>(Set.of("A")), 10);

        assertThat(entries.containsKey("B")).isFalse();
        assertThat(entries.containsKey("C")).isFalse();
    }

    @Test
    void cycleDetection_A_B_A() {
        entries.put("A", entry("A"));
        entries.put("B", entry("B"));
        relationships.add(new Relationship("A", "B", "owns"));
        relationships.add(new Relationship("B", "A", "owns"));
        var rules = List.of(new CascadeRule("owns", CascadeAction.DEREGISTER));

        var effects = engine.applyCascade("A", rules,
                CascadeRule::onSourceDeregister,
                id -> Optional.ofNullable(entries.get(id)),
                this::outbound, mutator(), events::add,
                new HashSet<>(Set.of("A")), 10);

        assertThat(entries.containsKey("B")).isFalse();
        assertThat(effects).hasSize(1);
    }

    @Test
    void depthLimit_stopsRecursion() {
        for (int i = 0; i < 15; i++) {
            entries.put("n" + i, entry("n" + i));
            if (i > 0) relationships.add(new Relationship("n" + (i - 1), "n" + i, "owns"));
        }
        var rules = List.of(new CascadeRule("owns", CascadeAction.DEREGISTER));

        engine.applyCascade("n0", rules,
                CascadeRule::onSourceDeregister,
                id -> Optional.ofNullable(entries.get(id)),
                this::outbound, mutator(), events::add,
                new HashSet<>(Set.of("n0")), 5);

        assertThat(entries.containsKey("n5")).isFalse();
        assertThat(entries.containsKey("n6")).isTrue();
    }

    @Test
    void noMatchingRule_noCascade() {
        entries.put("A", entry("A"));
        entries.put("B", entry("B"));
        relationships.add(new Relationship("A", "B", "owns"));
        var rules = List.of(new CascadeRule("contains", CascadeAction.DEREGISTER));

        var effects = engine.applyCascade("A", rules,
                CascadeRule::onSourceDeregister,
                id -> Optional.ofNullable(entries.get(id)),
                this::outbound, mutator(), events::add,
                new HashSet<>(Set.of("A")), 10);

        assertThat(entries.containsKey("B")).isTrue();
        assertThat(effects).isEmpty();
    }

    @Test
    void actionSelectorUsesExpiredAction() {
        entries.put("A", entry("A"));
        entries.put("B", entry("B"));
        relationships.add(new Relationship("A", "B", "owns"));
        var rules = List.of(new CascadeRule("owns", CascadeAction.DEREGISTER,
                CascadeAction.NOTIFY, null));

        engine.applyCascade("A", rules,
                CascadeRule::effectiveOnSourceExpired,
                id -> Optional.ofNullable(entries.get(id)),
                this::outbound, mutator(), events::add,
                new HashSet<>(Set.of("A")), 10);

        assertThat(entries.containsKey("B")).isTrue();
        assertThat(events).anyMatch(e -> e.kind() == RegistryEvent.EventKind.CASCADE_NOTIFIED);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl registry-inmem-core -Dtest=CascadeEngineTest`
Expected: compilation failure (CascadeEngine doesn't exist)

- [ ] **Step 3: Implement CascadeEngine**

Create `../../platform-api/src/main/java/io/casehub/platform/api/registry/CascadeEngine.java`:

```java
package io.casehub.platform.registry.memory;

import io.casehub.platform.api.registry.*;

import java.time.Instant;
import java.util.*;
import java.util.function.Consumer;
import java.util.function.Function;
import java.util.logging.Logger;

public class CascadeEngine {

    private static final Logger LOG = Logger.getLogger(CascadeEngine.class.getName());

    @FunctionalInterface
    public interface EntryResolver {
        Optional<RegistryEntry> resolve(String id);
    }

    @FunctionalInterface
    public interface RelationshipQuery {
        List<Relationship> outboundFrom(String sourceId);
    }

    public interface EntryMutator {
        void deregister(String id);
        void markOrphaned(String id, Instant now);
    }

    public List<CascadeEffect> applyCascade(
            String sourceId,
            List<CascadeRule> rules,
            Function<CascadeRule, CascadeAction> actionSelector,
            EntryResolver resolver,
            RelationshipQuery relQuery,
            EntryMutator mutator,
            Consumer<RegistryEvent> eventSink,
            Set<String> visited,
            int maxDepth
    ) {
        visited.add(sourceId);
        if (visited.size() > maxDepth) {
            LOG.warning("Cascade depth limit reached at " + maxDepth + " for source " + sourceId);
            return List.of();
        }

        var ruleMap = new HashMap<String, CascadeRule>();
        for (var rule : rules) {
            ruleMap.put(rule.relationshipType(), rule);
        }

        var outbound = relQuery.outboundFrom(sourceId);
        var effects = new ArrayList<CascadeEffect>();

        for (var rel : outbound) {
            var rule = ruleMap.get(rel.type());
            if (rule == null) continue;

            var action = actionSelector.apply(rule);
            if (action == CascadeAction.NONE) continue;

            var targetId = rel.targetId();
            if (visited.contains(targetId)) continue;

            try {
                var targetOpt = resolver.resolve(targetId);
                if (targetOpt.isEmpty()) continue;
                var target = targetOpt.get();

                switch (action) {
                    case DEREGISTER -> {
                        mutator.deregister(targetId);
                        eventSink.accept(RegistryEvent.deregistered(target));
                        var childEffects = applyCascade(targetId, rules, actionSelector,
                                resolver, relQuery, mutator, eventSink, visited, maxDepth);
                        effects.add(new CascadeEffect(targetId, action, rel, null, null));
                        effects.addAll(childEffects);
                    }
                    case MARK_ORPHANED -> {
                        var now = Instant.now();
                        mutator.markOrphaned(targetId, now);
                        var orphaned = resolver.resolve(targetId).orElse(target.withOrphaned(now));
                        eventSink.accept(RegistryEvent.orphaned(orphaned));
                        effects.add(new CascadeEffect(targetId, action, rel, orphaned, null));
                    }
                    case NOTIFY -> {
                        eventSink.accept(RegistryEvent.cascadeNotified(target, rel));
                        effects.add(new CascadeEffect(targetId, action, rel, target, null));
                    }
                    default -> {}
                }
            } catch (Exception e) {
                effects.add(new CascadeEffect(targetId, action, rel, null, e.getMessage()));
            }
        }

        return effects;
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl registry-inmem-core -Dtest=CascadeEngineTest`
Expected: PASS (9 tests)

- [ ] **Step 5: Commit**

```bash
git add registry-inmem-core/src/main/java/io/casehub/platform/registry/memory/CascadeEngine.java registry-inmem-core/src/test/java/io/casehub/platform/registry/memory/CascadeEngineTest.java
git commit -m "feat(registry): implement CascadeEngine with cycle detection and depth limit Refs #571"
```

### Task 4: Wire CascadeEngine into InMemoryRegistryService + HeartbeatScheduler

**Files:**
- Modify: `registry-inmem-core/src/main/java/io/casehub/platform/registry/memory/InMemoryRegistryService.java`
- Modify: `registry-inmem-core/src/main/java/io/casehub/platform/registry/memory/HeartbeatScheduler.java`
- Modify: `registry-inmem-core/src/test/java/io/casehub/platform/registry/memory/InMemoryRegistryServiceTest.java`
- Modify: `registry-inmem-core/src/test/java/io/casehub/platform/registry/memory/HeartbeatSchedulerTest.java`

**Interfaces:**
- Consumes: `CascadeEngine.applyCascade()`, `CascadeResult`, `CascadeEffect`
- Produces: `InMemoryRegistryService.deregister()` returns `CascadeResult` with cascade effects; `HeartbeatScheduler.checkHeartbeats()` fires HEARTBEAT_EXPIRED and triggers cascade with grace period

- [ ] **Step 1: Write failing integration tests in InMemoryRegistryServiceTest**

Add cascade integration tests:

```java
// --- cascade enforcement ---

@Test
void deregisterCascadesDeregister() {
    registry.register(entry("app-1", "app", "ns"));
    registry.register(entry("pool-1", "pool", "ns"));
    registry.link(new Relationship("app-1", "pool-1", "owns"));
    registry.registerCascadeRule(new CascadeRule("owns", CascadeAction.DEREGISTER));

    var result = registry.deregister("app-1");

    assertThat(registry.resolve("pool-1")).isEmpty();
    assertThat(result.deregistered().id()).isEqualTo("app-1");
    assertThat(result.cascadeEffects()).hasSize(1);
    assertThat(result.cascadeEffects().get(0).action()).isEqualTo(CascadeAction.DEREGISTER);
}

@Test
void deregisterCascadesMarkOrphaned() {
    registry.register(entry("app-1", "app", "ns"));
    registry.register(entry("pool-1", "pool", "ns"));
    registry.link(new Relationship("app-1", "pool-1", "owns"));
    registry.registerCascadeRule(new CascadeRule("owns", CascadeAction.MARK_ORPHANED));

    registry.deregister("app-1");

    assertThat(registry.resolve("pool-1")).isPresent()
            .hasValueSatisfying(e -> assertThat(e.isOrphaned()).isTrue());
}

@Test
void deregisterCascadesNotify() {
    registry.register(entry("app-1", "app", "ns"));
    registry.register(entry("pool-1", "pool", "ns"));
    registry.link(new Relationship("app-1", "pool-1", "owns"));
    registry.registerCascadeRule(new CascadeRule("owns", CascadeAction.NOTIFY));
    cdiEvents.clear();

    registry.deregister("app-1");

    assertThat(registry.resolve("pool-1")).isPresent();
    assertThat(cdiEvents).anyMatch(e -> e.kind() == RegistryEvent.EventKind.CASCADE_NOTIFIED);
}

@Test
void deregisterWithoutCascadeRules_returnsSimpleResult() {
    registry.register(entry("svc-1", "service", "default"));
    var result = registry.deregister("svc-1");
    assertThat(result.deregistered().id()).isEqualTo("svc-1");
    assertThat(result.cascadeEffects()).isEmpty();
}

@Test
void deregisterUnknown_returnsEmpty() {
    var result = registry.deregister("nope");
    assertThat(result.deregistered()).isNull();
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl registry-inmem-core -Dtest=InMemoryRegistryServiceTest`
Expected: some tests fail (cascade not wired yet)

- [ ] **Step 3: Wire CascadeEngine into InMemoryRegistryService**

Use `ide_edit_member` to:
1. Add `CascadeEngine` field
2. Add `outboundRelationships(String sourceId)` helper method
3. Replace `deregister()` implementation with cascade-aware version

Key implementation:

```java
private final CascadeEngine cascadeEngine = new CascadeEngine();
private static final int MAX_CASCADE_DEPTH = 10;

List<Relationship> outboundRelationships(String sourceId) {
    return relationships.stream()
            .filter(r -> r.sourceId().equals(sourceId)).toList();
}

@Override
public CascadeResult deregister(String id) {
    var removed = entries.remove(id);
    if (removed == null) return CascadeResult.empty();

    var rules = List.copyOf(cascadeRules.values());
    var effects = List.<CascadeEffect>of();
    if (!rules.isEmpty()) {
        effects = cascadeEngine.applyCascade(id, rules,
                CascadeRule::onSourceDeregister,
                k -> Optional.ofNullable(entries.get(k)),
                this::outboundRelationships,
                new CascadeEngine.EntryMutator() {
                    @Override public void deregister(String tid) { entries.remove(tid); }
                    @Override public void markOrphaned(String tid, Instant now) {
                        entries.computeIfPresent(tid, (k, e) -> e.withOrphaned(now));
                    }
                },
                cdiEventSink, new HashSet<>(Set.of(id)), MAX_CASCADE_DEPTH);
    }

    relationships.removeIf(r -> r.sourceId().equals(id) || r.targetId().equals(id));
    var event = RegistryEvent.deregistered(removed);
    cdiEventSink.accept(event);
    notifyWatchers(event);
    return new CascadeResult(removed, effects);
}
```

- [ ] **Step 4: Run integration tests**

Run: `mvn --batch-mode test -pl registry-inmem-core -Dtest=InMemoryRegistryServiceTest`
Expected: PASS

- [ ] **Step 5: Write HeartbeatScheduler cascade tests**

Add to `HeartbeatSchedulerTest.java`:

```java
@Test
void ttlExpiry_firesHeartbeatExpiredEvent() {
    var entry = new RegistryEntry("svc-1", "service", "default", "tenant-1",
            Map.of(), Instant.now().minus(Duration.ofSeconds(60)), null,
            Duration.ofSeconds(5), HealthStatus.HEALTHY, null);
    registry.register(entry);
    events.clear();

    scheduler.checkHeartbeats();

    assertThat(events).anyMatch(e -> e.kind() == RegistryEvent.EventKind.HEARTBEAT_EXPIRED);
}

@Test
void ttlExpiry_cascadesWithNoGracePeriod() {
    var source = new RegistryEntry("src", "app", "ns", "tenant-1",
            Map.of(), Instant.now().minus(Duration.ofSeconds(60)), null,
            Duration.ofSeconds(5), HealthStatus.HEALTHY, null);
    var target = new RegistryEntry("tgt", "pool", "ns", "tenant-1",
            Map.of(), Instant.now(), null, Duration.ofSeconds(300),
            HealthStatus.HEALTHY, null);
    registry.register(source);
    registry.register(target);
    registry.link(new Relationship("src", "tgt", "owns"));
    registry.registerCascadeRule(new CascadeRule("owns",
            CascadeAction.DEREGISTER, CascadeAction.DEREGISTER, null));

    scheduler.checkHeartbeats();

    assertThat(registry.resolve("tgt")).isEmpty();
}

@Test
void ttlExpiry_respectsGracePeriod() {
    var source = new RegistryEntry("src", "app", "ns", "tenant-1",
            Map.of(), Instant.now().minus(Duration.ofSeconds(60)), null,
            Duration.ofSeconds(5), HealthStatus.HEALTHY, null);
    var target = new RegistryEntry("tgt", "pool", "ns", "tenant-1",
            Map.of(), Instant.now(), null, Duration.ofSeconds(300),
            HealthStatus.HEALTHY, null);
    registry.register(source);
    registry.register(target);
    registry.link(new Relationship("src", "tgt", "owns"));
    registry.registerCascadeRule(new CascadeRule("owns",
            CascadeAction.DEREGISTER, CascadeAction.DEREGISTER,
            Duration.ofMinutes(5)));

    scheduler.checkHeartbeats();

    assertThat(registry.resolve("src").get().health()).isEqualTo(HealthStatus.DOWN);
    assertThat(registry.resolve("tgt")).isPresent();
}
```

- [ ] **Step 6: Update HeartbeatScheduler with cascade and HEARTBEAT_EXPIRED**

Update `HeartbeatScheduler` to:
1. Accept `CascadeEngine` and cascade rules as dependencies
2. Fire `HEARTBEAT_EXPIRED` instead of `HEALTH_CHANGED` on TTL expiry
3. Trigger cascade with grace period check

The constructor changes to accept the event sink directly (currently HeartbeatScheduler only takes InMemoryRegistryService — it needs access to the event sink for cascade events).

- [ ] **Step 7: Run all tests**

Run: `mvn --batch-mode test -pl registry-inmem-core`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add registry-inmem-core/
git commit -m "feat(registry): wire cascade into InMemoryRegistryService and HeartbeatScheduler Refs #571"
```

---

## Batch 3: JPA Integration + Flyway Migration

### Task 5: Update JPA entities + Flyway migration + JpaRegistryService cascade

**Files:**
- Modify: `registry-jpa-common/src/main/java/io/casehub/platform/registry/jpa/RegistryEntryEntity.java`
- Modify: `registry-jpa-common/src/main/java/io/casehub/platform/registry/jpa/CascadeRuleEntity.java`
- Create: `registry-jpa-common/src/main/resources/db/registry/migration/V2__cascade_enforcement.sql`
- Modify: `registry-jpa-common/src/main/java/io/casehub/platform/registry/jpa/JpaRegistryService.java`

**Interfaces:**
- Consumes: `CascadeEngine`, `CascadeResult`, `CascadeEffect`
- Produces: `JpaRegistryService.deregister()` returns `CascadeResult` with cascade effects; `JpaRegistryService.checkHeartbeats()` fires HEARTBEAT_EXPIRED and triggers cascade

- [ ] **Step 1: Create Flyway V2 migration**

Create `registry-jpa-common/src/main/resources/db/registry/migration/V2__cascade_enforcement.sql`:

```sql
ALTER TABLE registry_entry ADD COLUMN orphaned_at TIMESTAMP WITH TIME ZONE;

ALTER TABLE registry_cascade_rule ADD COLUMN on_source_expired VARCHAR(30);
ALTER TABLE registry_cascade_rule ADD COLUMN cascade_grace_period_seconds BIGINT;
```

- [ ] **Step 2: Update RegistryEntryEntity — add orphanedAt field**

Use `ide_insert_member` to add to RegistryEntryEntity:

```java
@Column(name = "orphaned_at")
public Instant orphanedAt;
```

- [ ] **Step 3: Update CascadeRuleEntity — add new columns**

Use `ide_insert_member` to add to CascadeRuleEntity:

```java
@Column(name = "on_source_expired")
public String onSourceExpired;

@Column(name = "cascade_grace_period_seconds")
public Long cascadeGracePeriodSeconds;
```

- [ ] **Step 4: Update JpaRegistryService — cascade in deregister + toRegistryEntry + registerCascadeRule + cascadeRules + checkHeartbeats**

Key changes:
1. `toRegistryEntry()` — include `orphanedAt`
2. `registerCascadeRule()` — persist new fields
3. `cascadeRules()` — read new fields, construct Duration from seconds
4. `deregister()` — use CascadeEngine, return CascadeResult
5. `checkHeartbeats()` — fire HEARTBEAT_EXPIRED, trigger cascade with grace period

- [ ] **Step 5: Verify compilation**

Run: `mvn --batch-mode compile -pl registry-jpa-common`
Expected: compilation success

- [ ] **Step 6: Commit**

```bash
git add registry-jpa-common/
git commit -m "feat(registry): JPA cascade enforcement — entities, migration, service Refs #571"
```

### Task 6: Update Spring JPA + run full build

**Files:**
- Modify: `registry-spring-jpa/src/main/java/io/casehub/platform/registry/spring/jpa/RegistryHeartbeatSchedulerConfig.java` (if needed — may just delegate to JpaRegistryService.checkHeartbeats())

**Interfaces:**
- Consumes: `JpaRegistryService.checkHeartbeats()` (already handles cascade internally)

- [ ] **Step 1: Verify Spring JPA module compiles**

Run: `mvn --batch-mode compile -pl registry-spring-jpa`
Expected: PASS (RegistryHeartbeatSchedulerConfig delegates to JpaRegistryService.checkHeartbeats() which now handles cascade internally)

- [ ] **Step 2: Run full platform build**

Run: `mvn --batch-mode install`
Expected: PASS (all modules compile and tests pass)

- [ ] **Step 3: Update CLAUDE.md module table if needed**

Update the registry module descriptions in CLAUDE.md to reflect cascade enforcement capability.

- [ ] **Step 4: Commit**

```bash
git add registry-spring-jpa/ CLAUDE.md
git commit -m "feat(registry): cascade enforcement complete — all modules green Refs #571"
```

---

## References

- [specs/issue-571-cascade-enforcement/2026-10-11-cascade-enforcement-design.md] — design spec this plan implements
- [platform-api/src/main/java/io/casehub/platform/api/registry/CascadeRule.java] — existing CascadeRule
- [platform-api/src/main/java/io/casehub/platform/api/registry/RegistryEntry.java] — existing RegistryEntry
- [platform-api/src/main/java/io/casehub/platform/api/registry/RegistryEvent.java] — existing RegistryEvent
- [platform-api/src/main/java/io/casehub/platform/api/registry/RegistryService.java] — existing SPI
- [platform-core/src/main/java/io/casehub/platform/registry/NoOpRegistryService.java] — NoOp implementation
- [registry-inmem-core/src/main/java/io/casehub/platform/registry/memory/InMemoryRegistryService.java] — InMemory implementation
- [registry-inmem-core/src/main/java/io/casehub/platform/registry/memory/HeartbeatScheduler.java] — heartbeat scheduler
- [registry-jpa-common/src/main/java/io/casehub/platform/registry/jpa/JpaRegistryService.java] — JPA implementation
- [registry-jpa-common/src/main/resources/db/registry/migration/V1__registry_initial_schema.sql] — existing schema
- [GitHub #571] — focal issue
