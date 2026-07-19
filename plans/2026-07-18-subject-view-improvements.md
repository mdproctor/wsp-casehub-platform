# Subject View Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #184 — Subject View Toolkit — improvements before work-queues migration
**Issue group:** #184

**Goal:** Seven improvements to the subject view toolkit to unblock
casehub-work-queues migration — CHANGED events, additionalConditions,
in-memory query support, bulk membership, orchestrator, caching, and
scope-aware evaluation.

**Architecture:** Changes span five modules (platform-api, platform,
platform-view, platform-view-inmem, platform-view-jpa). All SPI
additions use default methods for backward compatibility. The new
SubjectViewOrchestrator in platform-view composes evaluator + store +
tracker into a single entry point with caching and scope filtering.

**Tech Stack:** Java 21, Quarkus (CDI, JPA/Hibernate, SmallRye Config),
PostgreSQL, Flyway, JUnit 5, AssertJ

## Global Constraints

- `platform-api/` must remain zero-dependency — no Quarkus, no JPA
- Pre-release platform — API breaks are free
- IntelliJ MCP required for all code operations — never bash grep/Edit on source files
- `project_path: /Users/mdproctor/claude/casehub/platform` for all ide_* calls

---

### Task 1: additionalConditions on SubjectViewSpec (§2)

Constructor change ripples through all modules — do this first so later
tasks use the updated constructor from the start.

**Files:**
- Modify: `platform-api/src/main/java/io/casehub/platform/api/view/SubjectViewSpec.java`
- Modify: `platform-api/src/test/java/io/casehub/platform/api/view/SubjectViewSpecTest.java`
- Modify: `platform-view-jpa/src/main/java/io/casehub/platform/view/jpa/SubjectViewEntity.java`
- Create: `platform-view-jpa/src/main/resources/db/view/migration/V5001__subject_view_additional_conditions.sql`
- Modify: `platform-view-inmem/src/main/java/io/casehub/platform/view/inmem/InMemorySubjectViewStore.java`
- Modify: `platform-view-inmem/src/test/java/io/casehub/platform/view/inmem/InMemorySubjectViewStoreTest.java`
- Modify: `platform-view/src/test/java/io/casehub/platform/view/SubjectViewEvaluatorTest.java`
- Modify: `platform-view-jpa/src/test/java/io/casehub/platform/view/jpa/JpaSubjectViewStoreTest.java`
- Modify: `platform-view-jpa/src/test/java/io/casehub/platform/view/jpa/JpaViewMembershipTrackerTest.java`

**Interfaces:**
- Produces: `SubjectViewSpec` record with 9 components (id, name, tenancyId, labelPattern, scope, sortField, sortDirection, additionalConditions, createdAt)

- [ ] **Step 1: Write failing test for additionalConditions**

Add to `SubjectViewSpecTest`:

```java
@Test
void additionalConditionsNullable() {
    var spec = new SubjectViewSpec(
        UUID.randomUUID(), "view", "t1", "iot/**",
        null, null, null, null, null);
    assertThat(spec.additionalConditions()).isNull();
}

@Test
void additionalConditionsPreserved() {
    var spec = new SubjectViewSpec(
        UUID.randomUUID(), "view", "t1", "iot/**",
        null, null, null, "status == 'OPEN'", null);
    assertThat(spec.additionalConditions()).isEqualTo("status == 'OPEN'");
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl platform-api -Dtest=SubjectViewSpecTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: Compilation error — constructor has wrong arity

- [ ] **Step 3: Add additionalConditions to SubjectViewSpec**

Use `ide_edit_member` on `SubjectViewSpec` (member=SubjectViewSpec) to replace the record declaration. Add `String additionalConditions` between `sortDirection` and `createdAt`.

```java
public record SubjectViewSpec(
    UUID id,
    String name,
    String tenancyId,
    String labelPattern,
    Path scope,
    String sortField,
    String sortDirection,
    String additionalConditions,
    Instant createdAt
) {
    public SubjectViewSpec {
        Objects.requireNonNull(name, "name must not be null");
        Objects.requireNonNull(tenancyId, "tenancyId must not be null");
        Objects.requireNonNull(labelPattern, "labelPattern must not be null");
    }
}
```

- [ ] **Step 4: Fix all existing SubjectViewSpec constructor calls**

Every existing 8-arg constructor call needs the new `additionalConditions` parameter (null) inserted before the last argument (`createdAt`).

Files with constructor calls (use `ide_find_references` on SubjectViewSpec to confirm):
- `SubjectViewSpecTest` — all test constructors
- `SubjectViewEvaluatorTest.view()` helper
- `InMemorySubjectViewStore.save()` — the `new SubjectViewSpec(...)` call
- `InMemorySubjectViewStoreTest.spec()` helper + inline constructors
- `SubjectViewEntity.toSpec()`
- `JpaSubjectViewStoreTest` — any inline constructors

For each file, use `ide_replace_member` or `ide_edit_member` to update the constructor calls. Add `null` for additionalConditions in the correct position, or `spec.additionalConditions()` where the field should be carried through.

**InMemorySubjectViewStore.save()** — update the persisted constructor:
```java
var persisted = new SubjectViewSpec(id, spec.name(), spec.tenancyId(),
    spec.labelPattern(), spec.scope(), spec.sortField(),
    spec.sortDirection(), spec.additionalConditions(), createdAt);
```

**SubjectViewEntity.toSpec()** — add `additionalConditions` field:
```java
return new SubjectViewSpec(id, name, tenancyId, labelPattern,
    parsedScope, sortField, sortDirection, additionalConditions, createdAt);
```

**SubjectViewEntity.fromSpec()** — add field copy:
```java
entity.additionalConditions = spec.additionalConditions();
```

- [ ] **Step 5: Add additionalConditions to SubjectViewEntity**

Use `ide_insert_member` to add after `sortDirection`:
```java
@Column(name = "additional_conditions", columnDefinition = "TEXT")
public String additionalConditions;
```

Update `toSpec()` and `fromSpec()` as shown in Step 4.

- [ ] **Step 6: Create Flyway migration V5001**

Create file `platform-view-jpa/src/main/resources/db/view/migration/V5001__subject_view_additional_conditions.sql`:
```sql
ALTER TABLE subject_view ADD COLUMN additional_conditions TEXT;
```

- [ ] **Step 7: Add InMemorySubjectViewStore test for additionalConditions**

Add to `InMemorySubjectViewStoreTest`:
```java
@Test
void savePreservesAdditionalConditions() {
    var input = new SubjectViewSpec(null, "v", "t1", "iot/**",
        null, null, null, "status == 'OPEN'", null);
    var saved = store.save(input);
    assertThat(saved.additionalConditions()).isEqualTo("status == 'OPEN'");
}
```

- [ ] **Step 8: Run all tests, verify green**

Run: `mvn --batch-mode test -pl platform-api,platform-view,platform-view-inmem`
Expected: All tests pass

- [ ] **Step 9: Verify with ide_diagnostics**

Run `ide_diagnostics` on each modified file to check for compilation errors.

- [ ] **Step 10: Commit**

```
feat(#184): add additionalConditions to SubjectViewSpec

Opaque nullable TEXT field for domain-specific filter expressions
(JEXL, MVEL, JQ). Platform stores it, never interprets it.
Includes Flyway V5001, entity mapping, and in-memory store support.
```

---

### Task 2: CHANGED event + computeEvents (§1)

**Files:**
- Modify: `platform-api/src/main/java/io/casehub/platform/api/view/ViewEventType.java`
- Modify: `platform-view/src/main/java/io/casehub/platform/view/SubjectViewEvaluator.java`
- Modify: `platform-view/src/test/java/io/casehub/platform/view/SubjectViewEvaluatorTest.java`

**Interfaces:**
- Produces: `ViewEventType.CHANGED`, `SubjectViewEvaluator.computeEvents(UUID, String, Map, Map)` replacing `diff()`

- [ ] **Step 1: Write failing tests for computeEvents + CHANGED**

Replace the existing diff tests in `SubjectViewEvaluatorTest` with computeEvents tests. Use `ide_edit_member` to replace each test method:

```java
@Test
void computeEvents_added() {
    var viewId = UUID.randomUUID();
    var subjectId = UUID.randomUUID();
    Map<UUID, String> before = Map.of();
    Map<UUID, String> after = Map.of(viewId, "iot-triage");

    var events = evaluator.computeEvents(subjectId, "t1", before, after);

    assertThat(events).hasSize(1);
    assertThat(events.get(0).type()).isEqualTo(ViewEventType.ADDED);
    assertThat(events.get(0).viewName()).isEqualTo("iot-triage");
    assertThat(events.get(0).subjectId()).isEqualTo(subjectId);
}

@Test
void computeEvents_removed() {
    var viewId = UUID.randomUUID();
    Map<UUID, String> before = Map.of(viewId, "iot-triage");
    Map<UUID, String> after = Map.of();

    var events = evaluator.computeEvents(UUID.randomUUID(), "t1", before, after);

    assertThat(events).hasSize(1);
    assertThat(events.get(0).type()).isEqualTo(ViewEventType.REMOVED);
}

@Test
void computeEvents_changed() {
    var viewId = UUID.randomUUID();
    var subjectId = UUID.randomUUID();
    Map<UUID, String> before = Map.of(viewId, "view-1");
    Map<UUID, String> after = Map.of(viewId, "view-1");

    var events = evaluator.computeEvents(subjectId, "t1", before, after);

    assertThat(events).hasSize(1);
    assertThat(events.get(0).type()).isEqualTo(ViewEventType.CHANGED);
    assertThat(events.get(0).viewId()).isEqualTo(viewId);
}

@Test
void computeEvents_changedUsesAfterViewName() {
    var viewId = UUID.randomUUID();
    Map<UUID, String> before = Map.of(viewId, "old-name");
    Map<UUID, String> after = Map.of(viewId, "new-name");

    var events = evaluator.computeEvents(UUID.randomUUID(), "t1", before, after);

    assertThat(events).hasSize(1);
    assertThat(events.get(0).type()).isEqualTo(ViewEventType.CHANGED);
    assertThat(events.get(0).viewName()).isEqualTo("new-name");
}

@Test
void computeEvents_mixed() {
    var removedId = UUID.randomUUID();
    var addedId = UUID.randomUUID();
    var changedId = UUID.randomUUID();
    Map<UUID, String> before = Map.of(removedId, "old-view", changedId, "stable");
    Map<UUID, String> after = Map.of(addedId, "new-view", changedId, "stable");

    var events = evaluator.computeEvents(UUID.randomUUID(), "t1", before, after);

    assertThat(events).hasSize(3);
    assertThat(events).extracting(SubjectViewEvent::type)
        .containsExactlyInAnyOrder(
            ViewEventType.ADDED, ViewEventType.REMOVED, ViewEventType.CHANGED);
}

@Test
void computeEvents_identicalMapsAllChanged() {
    var v1 = UUID.randomUUID();
    var v2 = UUID.randomUUID();
    Map<UUID, String> state = Map.of(v1, "a", v2, "b");

    var events = evaluator.computeEvents(UUID.randomUUID(), "t1", state, state);

    assertThat(events).hasSize(2);
    assertThat(events).allMatch(e -> e.type() == ViewEventType.CHANGED);
}

@Test
void computeEvents_bothEmpty() {
    var events = evaluator.computeEvents(
        UUID.randomUUID(), "t1", Map.of(), Map.of());
    assertThat(events).isEmpty();
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl platform-view -Dtest=SubjectViewEvaluatorTest`
Expected: Compilation error — `computeEvents` and `ViewEventType.CHANGED` not defined

- [ ] **Step 3: Add CHANGED to ViewEventType**

Use `ide_edit_member` on `ViewEventType` (member=ViewEventType):
```java
public enum ViewEventType {
    ADDED,
    REMOVED,
    CHANGED
}
```

- [ ] **Step 4: Add computeEvents and remove diff**

Use `ide_edit_member` to replace `diff` method on `SubjectViewEvaluator`:

```java
public List<SubjectViewEvent> computeEvents(
        UUID subjectId,
        String tenancyId,
        Map<UUID, String> before,
        Map<UUID, String> after) {
    List<SubjectViewEvent> events = new ArrayList<>();

    before.forEach((id, name) -> {
        if (after.containsKey(id)) {
            events.add(new SubjectViewEvent(subjectId, id,
                after.get(id), ViewEventType.CHANGED, tenancyId));
        } else {
            events.add(new SubjectViewEvent(subjectId, id, name,
                ViewEventType.REMOVED, tenancyId));
        }
    });

    after.forEach((id, name) -> {
        if (!before.containsKey(id)) {
            events.add(new SubjectViewEvent(subjectId, id, name,
                ViewEventType.ADDED, tenancyId));
        }
    });

    return events;
}
```

- [ ] **Step 5: Remove old diff test methods**

Delete the old test methods that reference `diff()`: `diff_added`, `diff_removed`, `diff_noChange`, `diff_addedAndRemoved`. Use `ide_edit_member` to remove each.

- [ ] **Step 6: Run tests, verify green**

Run: `mvn --batch-mode test -pl platform-api,platform-view`
Expected: All tests pass

- [ ] **Step 7: Verify no remaining references to diff()**

Use `ide_find_references` on the old `diff` method to confirm nothing still references it. If any remain, update them.

- [ ] **Step 8: Commit**

```
feat(#184): add CHANGED event type and computeEvents method

diff() renamed to computeEvents() — broader contract that emits
CHANGED for stable memberships alongside ADDED/REMOVED. Domain
controls event volume by choosing which lifecycle events trigger
re-evaluation.
```

---

### Task 3: Bulk getLastKnownMembership (§4)

**Files:**
- Modify: `platform-api/src/main/java/io/casehub/platform/api/view/ViewMembershipTracker.java`
- Modify: `platform/src/main/java/io/casehub/platform/view/NoOpViewMembershipTracker.java`
- Modify: `platform/src/test/java/io/casehub/platform/view/NoOpViewMembershipTrackerTest.java`
- Modify: `platform-view-inmem/src/main/java/io/casehub/platform/view/inmem/InMemoryViewMembershipTracker.java`
- Modify: `platform-view-inmem/src/test/java/io/casehub/platform/view/inmem/InMemoryViewMembershipTrackerTest.java`
- Modify: `platform-view-jpa/src/main/java/io/casehub/platform/view/jpa/JpaViewMembershipTracker.java`
- Modify: `platform-view-jpa/src/test/java/io/casehub/platform/view/jpa/JpaViewMembershipTrackerTest.java`

**Interfaces:**
- Produces: `ViewMembershipTracker.getLastKnownMembership(Set<UUID>)` default method returning `Map<UUID, Map<UUID, String>>` (only subjects with ≥1 membership)

- [ ] **Step 1: Write failing tests**

Add to `InMemoryViewMembershipTrackerTest`:

```java
@Test
void bulkGetReturnsOnlyTrackedSubjects() {
    var s1 = UUID.randomUUID();
    var s2 = UUID.randomUUID();
    var untracked = UUID.randomUUID();
    var v1 = UUID.randomUUID();
    var v2 = UUID.randomUUID();
    tracker.updateMembership(s1, Map.of(v1, "view-1"));
    tracker.updateMembership(s2, Map.of(v2, "view-2"));

    var result = tracker.getLastKnownMembership(Set.of(s1, s2, untracked));

    assertThat(result).hasSize(2);
    assertThat(result.get(s1)).containsEntry(v1, "view-1");
    assertThat(result.get(s2)).containsEntry(v2, "view-2");
    assertThat(result).doesNotContainKey(untracked);
}

@Test
void bulkGetEmptySetReturnsEmpty() {
    assertThat(tracker.getLastKnownMembership(Set.of())).isEmpty();
}
```

Add to `NoOpViewMembershipTrackerTest`:
```java
@Test
void bulkGetReturnsEmpty() {
    assertThat(tracker.getLastKnownMembership(
        Set.of(UUID.randomUUID(), UUID.randomUUID()))).isEmpty();
}
```

Add to `JpaViewMembershipTrackerTest`:
```java
@Test
void bulkGetReturnsOnlyTrackedSubjects() {
    var s1 = UUID.randomUUID();
    var s2 = UUID.randomUUID();
    var v1 = UUID.randomUUID();
    var v2 = UUID.randomUUID();
    tracker.updateMembership(s1, Map.of(v1, "view-1"));
    tracker.updateMembership(s2, Map.of(v2, "view-2"));

    var result = tracker.getLastKnownMembership(Set.of(s1, s2, UUID.randomUUID()));

    assertThat(result).hasSize(2);
    assertThat(result.get(s1)).containsEntry(v1, "view-1");
    assertThat(result.get(s2)).containsEntry(v2, "view-2");
}

@Test
void bulkGetEmptySetReturnsEmpty() {
    assertThat(tracker.getLastKnownMembership(Set.of())).isEmpty();
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl platform,platform-view-inmem -Dtest="NoOpViewMembershipTrackerTest,InMemoryViewMembershipTrackerTest"`
Expected: Compilation error — `getLastKnownMembership(Set)` not defined

- [ ] **Step 3: Add default method to ViewMembershipTracker SPI**

Use `ide_insert_member` on `ViewMembershipTracker`, after `getLastKnownMembership(UUID)`:

```java
default Map<UUID, Map<UUID, String>> getLastKnownMembership(Set<UUID> subjectIds) {
    Map<UUID, Map<UUID, String>> result = new HashMap<>();
    for (UUID subjectId : subjectIds) {
        Map<UUID, String> membership = getLastKnownMembership(subjectId);
        if (!membership.isEmpty()) {
            result.put(subjectId, membership);
        }
    }
    return result;
}
```

Add `import java.util.HashMap;` and `import java.util.Set;` to the interface.

- [ ] **Step 4: Override in NoOpViewMembershipTracker**

Use `ide_insert_member` after `getLastKnownMembership(UUID)`:
```java
@Override
public Map<UUID, Map<UUID, String>> getLastKnownMembership(Set<UUID> subjectIds) {
    return Map.of();
}
```

- [ ] **Step 5: Override in InMemoryViewMembershipTracker**

Use `ide_insert_member` after `getLastKnownMembership(UUID)`:
```java
@Override
public Map<UUID, Map<UUID, String>> getLastKnownMembership(Set<UUID> subjectIds) {
    Map<UUID, Map<UUID, String>> result = new HashMap<>();
    for (UUID subjectId : subjectIds) {
        Map<UUID, String> membership = getLastKnownMembership(subjectId);
        if (!membership.isEmpty()) {
            result.put(subjectId, membership);
        }
    }
    return result;
}
```

- [ ] **Step 6: Override in JpaViewMembershipTracker (optimized)**

Use `ide_insert_member` after `getLastKnownMembership(UUID)`:
```java
@Override
public Map<UUID, Map<UUID, String>> getLastKnownMembership(Set<UUID> subjectIds) {
    if (subjectIds.isEmpty()) return Map.of();
    return em.createQuery(
            "SELECT e FROM ViewMembershipEntity e WHERE e.subjectId IN :sids",
            ViewMembershipEntity.class)
        .setParameter("sids", subjectIds)
        .getResultList()
        .stream()
        .collect(Collectors.groupingBy(
            e -> e.subjectId,
            Collectors.toMap(e -> e.viewId, e -> e.viewName)));
}
```

- [ ] **Step 7: Run all tests, verify green**

Run: `mvn --batch-mode test -pl platform-api,platform,platform-view-inmem,platform-view-jpa`
Expected: All tests pass

- [ ] **Step 8: Commit**

```
feat(#184): add bulk getLastKnownMembership to ViewMembershipTracker

Default method loops over single-subject calls. JPA overrides with
WHERE IN query. Returns only subjects with ≥1 membership — callers
use getOrDefault(subjectId, Map.of()).
```

---

### Task 4: Scope-aware evaluateMembership (§7 — evaluator only)

**Files:**
- Modify: `platform-view/src/main/java/io/casehub/platform/view/SubjectViewEvaluator.java`
- Modify: `platform-view/src/test/java/io/casehub/platform/view/SubjectViewEvaluatorTest.java`

**Interfaces:**
- Consumes: `Path.isAncestorOf(Path)`, `SubjectViewSpec.scope()`
- Produces: `SubjectViewEvaluator.evaluateMembership(Set<String>, List<SubjectViewSpec>, Path)` overload

- [ ] **Step 1: Write failing tests for scope overload**

Add to `SubjectViewEvaluatorTest`:

```java
@Test
void evaluateMembership_scopeFiltersIncompatibleViews() {
    var euView = new SubjectViewSpec(UUID.randomUUID(), "eu-iot", "t1",
        "iot/**", Path.of("eu"), null, null, null, null);
    var usView = new SubjectViewSpec(UUID.randomUUID(), "us-iot", "t1",
        "iot/**", Path.of("us"), null, null, null, null);
    var subjectScope = Path.of("eu", "germany");

    var result = evaluator.evaluateMembership(
        Set.of("iot/triage/hvac"), List.of(euView, usView), subjectScope);

    assertThat(result).containsKey(euView.id());
    assertThat(result).doesNotContainKey(usView.id());
}

@Test
void evaluateMembership_nullScopeViewMatchesAll() {
    var globalView = new SubjectViewSpec(UUID.randomUUID(), "global", "t1",
        "iot/**", null, null, null, null, null);
    var subjectScope = Path.of("eu", "germany");

    var result = evaluator.evaluateMembership(
        Set.of("iot/triage/hvac"), List.of(globalView), subjectScope);

    assertThat(result).containsKey(globalView.id());
}

@Test
void evaluateMembership_exactScopeMatchIncludes() {
    var view = new SubjectViewSpec(UUID.randomUUID(), "de-iot", "t1",
        "iot/**", Path.of("eu", "germany"), null, null, null, null);

    var result = evaluator.evaluateMembership(
        Set.of("iot/triage/hvac"), List.of(view), Path.of("eu", "germany"));

    assertThat(result).containsKey(view.id());
}

@Test
void evaluateMembership_nullSubjectScopeSkipsFiltering() {
    var scopedView = new SubjectViewSpec(UUID.randomUUID(), "eu-iot", "t1",
        "iot/**", Path.of("eu"), null, null, null, null);

    var result = evaluator.evaluateMembership(
        Set.of("iot/triage/hvac"), List.of(scopedView), null);

    assertThat(result).containsKey(scopedView.id());
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl platform-view -Dtest=SubjectViewEvaluatorTest`
Expected: Compilation error — 3-arg overload not defined

- [ ] **Step 3: Add scope overload to SubjectViewEvaluator**

Use `ide_insert_member` after `evaluateMembership(Set, List)`:

```java
public Map<UUID, String> evaluateMembership(
        Set<String> subjectLabelPaths,
        List<SubjectViewSpec> views,
        Path subjectScope) {
    if (subjectScope == null) {
        return evaluateMembership(subjectLabelPaths, views);
    }
    var filtered = views.stream()
        .filter(v -> v.scope() == null
            || v.scope().equals(subjectScope)
            || v.scope().isAncestorOf(subjectScope))
        .toList();
    return evaluateMembership(subjectLabelPaths, filtered);
}
```

Add `import io.casehub.platform.api.path.Path;` if not already present.

- [ ] **Step 4: Run tests, verify green**

Run: `mvn --batch-mode test -pl platform-view`
Expected: All tests pass

- [ ] **Step 5: Commit**

```
feat(#184): add scope-aware evaluateMembership overload

Pre-filters views by scope compatibility before label pattern
matching. Null subject scope skips filtering (backward compatible).
```

---

### Task 5: SubjectViewOrchestrator + caching (§5 + §6 + §7 orchestrator)

**Files:**
- Create: `platform-view/src/main/java/io/casehub/platform/view/SubjectViewOrchestrator.java`
- Create: `platform-view/src/test/java/io/casehub/platform/view/SubjectViewOrchestratorTest.java`

**Interfaces:**
- Consumes: `SubjectViewEvaluator.evaluateMembership()`, `SubjectViewEvaluator.computeEvents()`, `SubjectViewStore`, `ViewMembershipTracker.getLastKnownMembership(UUID)`, `ViewMembershipTracker.getLastKnownMembership(Set<UUID>)`
- Produces: `evaluateAndTrack(UUID, String, Set<String>)`, `evaluateAndTrack(UUID, String, Set<String>, Path)`, `evaluateAndTrackBatch(Map, String)`, `evaluateAndTrackBatch(Map, String, Function)`, `saveView(SubjectViewSpec)`, `deleteView(UUID)`

- [ ] **Step 1: Write failing test for basic evaluateAndTrack**

Create `SubjectViewOrchestratorTest.java`:

```java
package io.casehub.platform.view;

import io.casehub.platform.api.path.Path;
import io.casehub.platform.api.view.*;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.*;
import java.util.function.Function;

import static org.assertj.core.api.Assertions.assertThat;

class SubjectViewOrchestratorTest {

    private SubjectViewEvaluator evaluator;
    private StubViewStore viewStore;
    private StubTracker tracker;
    private SubjectViewOrchestrator orchestrator;

    @BeforeEach
    void setUp() {
        evaluator = new SubjectViewEvaluator();
        viewStore = new StubViewStore();
        tracker = new StubTracker();
        orchestrator = new SubjectViewOrchestrator();
        orchestrator.evaluator = evaluator;
        orchestrator.viewStore = viewStore;
        orchestrator.tracker = tracker;
        orchestrator.cacheTtlSeconds = 0;
    }

    private SubjectViewSpec view(String name, String pattern) {
        return viewStore.save(new SubjectViewSpec(
            null, name, "t1", pattern,
            null, null, null, null, null));
    }

    @Test
    void evaluateAndTrack_addsToView() {
        var v = view("iot-all", "iot/**");
        var subjectId = UUID.randomUUID();

        var events = orchestrator.evaluateAndTrack(
            subjectId, "t1", Set.of("iot/triage/hvac"));

        assertThat(events).hasSize(1);
        assertThat(events.get(0).type()).isEqualTo(ViewEventType.ADDED);
        assertThat(events.get(0).viewId()).isEqualTo(v.id());
        assertThat(tracker.getLastKnownMembership(subjectId))
            .containsKey(v.id());
    }

    @Test
    void evaluateAndTrack_changedOnSecondCall() {
        view("iot-all", "iot/**");
        var subjectId = UUID.randomUUID();

        orchestrator.evaluateAndTrack(subjectId, "t1", Set.of("iot/triage/hvac"));
        var events = orchestrator.evaluateAndTrack(
            subjectId, "t1", Set.of("iot/triage/hvac"));

        assertThat(events).hasSize(1);
        assertThat(events.get(0).type()).isEqualTo(ViewEventType.CHANGED);
    }

    @Test
    void evaluateAndTrack_removedWhenLabelsNoLongerMatch() {
        view("iot-all", "iot/**");
        var subjectId = UUID.randomUUID();

        orchestrator.evaluateAndTrack(subjectId, "t1", Set.of("iot/triage/hvac"));
        var events = orchestrator.evaluateAndTrack(
            subjectId, "t1", Set.of("legal/compliance"));

        assertThat(events).hasSize(1);
        assertThat(events.get(0).type()).isEqualTo(ViewEventType.REMOVED);
    }
}
```

Use inline stub implementations (at the bottom of the test file or as static inner classes):

```java
static class StubViewStore implements SubjectViewStore {
    private final Map<UUID, SubjectViewSpec> store = new LinkedHashMap<>();

    @Override
    public SubjectViewSpec save(SubjectViewSpec spec) {
        UUID id = spec.id() != null ? spec.id() : UUID.randomUUID();
        var saved = new SubjectViewSpec(id, spec.name(), spec.tenancyId(),
            spec.labelPattern(), spec.scope(), spec.sortField(),
            spec.sortDirection(), spec.additionalConditions(),
            java.time.Instant.now());
        store.put(id, saved);
        return saved;
    }

    @Override
    public Optional<SubjectViewSpec> findById(UUID id) {
        return Optional.ofNullable(store.get(id));
    }

    @Override
    public List<SubjectViewSpec> findByTenancy(String tenancyId) {
        return store.values().stream()
            .filter(s -> s.tenancyId().equals(tenancyId)).toList();
    }

    @Override
    public void delete(UUID id) { store.remove(id); }
}

static class StubTracker implements ViewMembershipTracker {
    private final Map<UUID, Map<UUID, String>> state = new HashMap<>();

    @Override
    public Map<UUID, String> getLastKnownMembership(UUID subjectId) {
        return state.getOrDefault(subjectId, Map.of());
    }

    @Override
    public void updateMembership(UUID subjectId, Map<UUID, String> m) {
        state.put(subjectId, Map.copyOf(m));
    }

    @Override
    public void removeMembership(UUID subjectId) { state.remove(subjectId); }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl platform-view -Dtest=SubjectViewOrchestratorTest`
Expected: Compilation error — class not found

- [ ] **Step 3: Implement SubjectViewOrchestrator**

Create `platform-view/src/main/java/io/casehub/platform/view/SubjectViewOrchestrator.java` via `ide_create_file`:

```java
package io.casehub.platform.view;

import io.casehub.platform.api.path.Path;
import io.casehub.platform.api.view.*;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import org.eclipse.microprofile.config.inject.ConfigProperty;

import java.time.Instant;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.function.Function;

@ApplicationScoped
public class SubjectViewOrchestrator {

    @Inject
    SubjectViewEvaluator evaluator;

    @Inject
    SubjectViewStore viewStore;

    @Inject
    ViewMembershipTracker tracker;

    @ConfigProperty(name = "casehub.view.cache.ttl-seconds", defaultValue = "0")
    int cacheTtlSeconds;

    private final ConcurrentHashMap<String, CachedViews> viewCache = new ConcurrentHashMap<>();

    public List<SubjectViewEvent> evaluateAndTrack(
            UUID subjectId, String tenancyId, Set<String> labelPaths) {
        var before = tracker.getLastKnownMembership(subjectId);
        var views = getViews(tenancyId);
        var after = evaluator.evaluateMembership(labelPaths, views);
        var events = evaluator.computeEvents(subjectId, tenancyId, before, after);
        tracker.updateMembership(subjectId, after);
        return events;
    }

    public List<SubjectViewEvent> evaluateAndTrack(
            UUID subjectId, String tenancyId,
            Set<String> labelPaths, Path subjectScope) {
        var before = tracker.getLastKnownMembership(subjectId);
        var views = getViews(tenancyId);
        var after = evaluator.evaluateMembership(labelPaths, views, subjectScope);
        var events = evaluator.computeEvents(subjectId, tenancyId, before, after);
        tracker.updateMembership(subjectId, after);
        return events;
    }

    public Map<UUID, List<SubjectViewEvent>> evaluateAndTrackBatch(
            Map<UUID, Set<String>> subjectLabelPaths, String tenancyId) {
        var subjectIds = subjectLabelPaths.keySet();
        var allBefore = tracker.getLastKnownMembership(subjectIds);
        var views = getViews(tenancyId);

        Map<UUID, List<SubjectViewEvent>> result = new LinkedHashMap<>();
        subjectLabelPaths.forEach((subjectId, labelPaths) -> {
            var before = allBefore.getOrDefault(subjectId, Map.of());
            var after = evaluator.evaluateMembership(labelPaths, views);
            var events = evaluator.computeEvents(subjectId, tenancyId, before, after);
            tracker.updateMembership(subjectId, after);
            result.put(subjectId, events);
        });
        return result;
    }

    public Map<UUID, List<SubjectViewEvent>> evaluateAndTrackBatch(
            Map<UUID, Set<String>> subjectLabelPaths, String tenancyId,
            Function<UUID, Path> scopeResolver) {
        var subjectIds = subjectLabelPaths.keySet();
        var allBefore = tracker.getLastKnownMembership(subjectIds);
        var views = getViews(tenancyId);

        Map<UUID, List<SubjectViewEvent>> result = new LinkedHashMap<>();
        subjectLabelPaths.forEach((subjectId, labelPaths) -> {
            var before = allBefore.getOrDefault(subjectId, Map.of());
            Path scope = scopeResolver != null ? scopeResolver.apply(subjectId) : null;
            var after = evaluator.evaluateMembership(labelPaths, views, scope);
            var events = evaluator.computeEvents(subjectId, tenancyId, before, after);
            tracker.updateMembership(subjectId, after);
            result.put(subjectId, events);
        });
        return result;
    }

    public SubjectViewSpec saveView(SubjectViewSpec spec) {
        var saved = viewStore.save(spec);
        invalidateViewCache(spec.tenancyId());
        return saved;
    }

    public void deleteView(UUID viewId) {
        var spec = viewStore.findById(viewId);
        viewStore.delete(viewId);
        spec.ifPresent(s -> invalidateViewCache(s.tenancyId()));
    }

    private List<SubjectViewSpec> getViews(String tenancyId) {
        if (cacheTtlSeconds <= 0) {
            return viewStore.findByTenancy(tenancyId);
        }
        var cached = viewCache.get(tenancyId);
        if (cached != null && !cached.isExpired(cacheTtlSeconds)) {
            return cached.views();
        }
        var views = viewStore.findByTenancy(tenancyId);
        viewCache.put(tenancyId, new CachedViews(views, Instant.now()));
        return views;
    }

    private void invalidateViewCache(String tenancyId) {
        viewCache.remove(tenancyId);
    }

    private record CachedViews(List<SubjectViewSpec> views, Instant fetchedAt) {
        boolean isExpired(int ttlSeconds) {
            return Instant.now().isAfter(fetchedAt.plusSeconds(ttlSeconds));
        }
    }
}
```

- [ ] **Step 4: Run basic tests, verify green**

Run: `mvn --batch-mode test -pl platform-view -Dtest=SubjectViewOrchestratorTest`
Expected: Pass

- [ ] **Step 5: Add batch, saveView, deleteView, caching, and scope tests**

Add to `SubjectViewOrchestratorTest`:

```java
@Test
void evaluateAndTrackBatch_multipleSubjects() {
    var v = view("iot-all", "iot/**");
    var s1 = UUID.randomUUID();
    var s2 = UUID.randomUUID();

    var result = orchestrator.evaluateAndTrackBatch(
        Map.of(s1, Set.of("iot/triage"), s2, Set.of("legal/foo")), "t1");

    assertThat(result.get(s1)).hasSize(1);
    assertThat(result.get(s1).get(0).type()).isEqualTo(ViewEventType.ADDED);
    assertThat(result.get(s2)).hasSize(0);
}

@Test
void saveView_returnsPersistedSpec() {
    var spec = new SubjectViewSpec(null, "test", "t1",
        "iot/**", null, null, null, null, null);
    var saved = orchestrator.saveView(spec);
    assertThat(saved.id()).isNotNull();
    assertThat(viewStore.findById(saved.id())).isPresent();
}

@Test
void deleteView_removesFromStore() {
    var saved = orchestrator.saveView(new SubjectViewSpec(null, "test", "t1",
        "iot/**", null, null, null, null, null));
    orchestrator.deleteView(saved.id());
    assertThat(viewStore.findById(saved.id())).isEmpty();
}

@Test
void deleteView_nonExistentIsNoOp() {
    orchestrator.deleteView(UUID.randomUUID());
}

@Test
void caching_viewsCachedWhenTtlPositive() {
    orchestrator.cacheTtlSeconds = 60;
    view("iot-all", "iot/**");
    var s = UUID.randomUUID();

    orchestrator.evaluateAndTrack(s, "t1", Set.of("iot/x"));
    viewStore.save(new SubjectViewSpec(null, "new-view", "t1",
        "legal/**", null, null, null, null, null));
    var events = orchestrator.evaluateAndTrack(s, "t1", Set.of("iot/x"));

    assertThat(events).extracting(SubjectViewEvent::type)
        .containsOnly(ViewEventType.CHANGED);
    assertThat(events).hasSize(1);
}

@Test
void caching_saveViewInvalidatesCache() {
    orchestrator.cacheTtlSeconds = 60;
    view("iot-all", "iot/**");
    var s = UUID.randomUUID();

    orchestrator.evaluateAndTrack(s, "t1", Set.of("iot/x"));
    orchestrator.saveView(new SubjectViewSpec(null, "legal-all", "t1",
        "legal/**", null, null, null, null, null));
    var events = orchestrator.evaluateAndTrack(s, "t1", Set.of("iot/x"));

    assertThat(events).hasSize(2);
}

@Test
void evaluateAndTrack_withScope() {
    var euView = viewStore.save(new SubjectViewSpec(null, "eu-iot", "t1",
        "iot/**", Path.of("eu"), null, null, null, null));
    var usView = viewStore.save(new SubjectViewSpec(null, "us-iot", "t1",
        "iot/**", Path.of("us"), null, null, null, null));

    var events = orchestrator.evaluateAndTrack(
        UUID.randomUUID(), "t1", Set.of("iot/triage"), Path.of("eu", "germany"));

    assertThat(events).hasSize(1);
    assertThat(events.get(0).viewId()).isEqualTo(euView.id());
}

@Test
void evaluateAndTrackBatch_withScopeResolver() {
    var euView = viewStore.save(new SubjectViewSpec(null, "eu-iot", "t1",
        "iot/**", Path.of("eu"), null, null, null, null));
    var s1 = UUID.randomUUID();
    var s2 = UUID.randomUUID();

    Map<UUID, Path> scopes = Map.of(
        s1, Path.of("eu", "germany"),
        s2, Path.of("us", "california"));

    var result = orchestrator.evaluateAndTrackBatch(
        Map.of(s1, Set.of("iot/x"), s2, Set.of("iot/x")),
        "t1", scopes::get);

    assertThat(result.get(s1)).hasSize(1);
    assertThat(result.get(s2)).isEmpty();
}
```

- [ ] **Step 6: Run all tests, verify green**

Run: `mvn --batch-mode test -pl platform-view`
Expected: All tests pass

- [ ] **Step 7: Verify with ide_diagnostics**

Run `ide_diagnostics` on `SubjectViewOrchestrator.java`.

- [ ] **Step 8: Commit**

```
feat(#184): add SubjectViewOrchestrator with caching and scope support

Composes evaluator + store + tracker into a single entry point.
Reduces domain observer from ~12 lines to ~5. TTL-based view cache
(default off). saveView/deleteView invalidate cache automatically.
Scope-aware overloads and batch evaluation included.
```

---

### Task 6: InMemorySubjectViewQuerySupport (§3)

**Files:**
- Create: `platform-view-inmem/src/main/java/io/casehub/platform/view/inmem/InMemorySubjectViewQuerySupport.java`
- Create: `platform-view-inmem/src/test/java/io/casehub/platform/view/inmem/InMemorySubjectViewQuerySupportTest.java`

**Interfaces:**
- Consumes: `SubjectViewQuery<S>`, `LabelPatternMatcher.matches()`, `SubjectViewSpec`
- Produces: `InMemorySubjectViewQuerySupport<S>` abstract class with constructor `(Supplier<Collection<S>>, Function<S, Set<String>>, Function<S, String>, Function<String, Comparator<S>>)`

- [ ] **Step 1: Write failing test with a concrete test subclass**

Create `InMemorySubjectViewQuerySupportTest.java`:

```java
package io.casehub.platform.view.inmem;

import io.casehub.platform.api.path.Path;
import io.casehub.platform.api.view.SubjectViewSpec;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.*;

import static org.assertj.core.api.Assertions.assertThat;

class InMemorySubjectViewQuerySupportTest {

    private List<TestSubject> subjects;
    private TestQuery query;

    record TestSubject(UUID id, String tenancyId, Set<String> labels, String name) {}

    static class TestQuery extends InMemorySubjectViewQuerySupport<TestSubject> {
        TestQuery(List<TestSubject> subjects) {
            super(() -> subjects,
                  TestSubject::labels,
                  TestSubject::tenancyId,
                  field -> "name".equals(field)
                      ? Comparator.comparing(TestSubject::name) : null);
        }
    }

    @BeforeEach
    void setUp() {
        subjects = new ArrayList<>();
        query = new TestQuery(subjects);
    }

    private SubjectViewSpec view(String pattern) {
        return new SubjectViewSpec(UUID.randomUUID(), "v", "t1",
            pattern, null, null, null, null, null);
    }

    private SubjectViewSpec sortedView(String pattern, String sortField, String dir) {
        return new SubjectViewSpec(UUID.randomUUID(), "v", "t1",
            pattern, null, sortField, dir, null, null);
    }

    @Test
    void findByView_matchesByLabelPattern() {
        subjects.add(new TestSubject(UUID.randomUUID(), "t1",
            Set.of("iot/triage/hvac"), "s1"));
        subjects.add(new TestSubject(UUID.randomUUID(), "t1",
            Set.of("legal/compliance"), "s2"));

        var result = query.findByView(view("iot/**"));

        assertThat(result).hasSize(1);
        assertThat(result.get(0).name()).isEqualTo("s1");
    }

    @Test
    void findByView_filtersByTenancy() {
        subjects.add(new TestSubject(UUID.randomUUID(), "t1",
            Set.of("iot/x"), "s1"));
        subjects.add(new TestSubject(UUID.randomUUID(), "t2",
            Set.of("iot/x"), "s2"));

        var result = query.findByView(view("iot/**"));

        assertThat(result).hasSize(1);
        assertThat(result.get(0).tenancyId()).isEqualTo("t1");
    }

    @Test
    void findByView_pagination() {
        for (int i = 0; i < 5; i++) {
            subjects.add(new TestSubject(UUID.randomUUID(), "t1",
                Set.of("iot/x"), "s" + i));
        }

        var page = query.findByView(view("iot/**"), 1, 2);

        assertThat(page).hasSize(2);
    }

    @Test
    void countByView() {
        subjects.add(new TestSubject(UUID.randomUUID(), "t1",
            Set.of("iot/x"), "s1"));
        subjects.add(new TestSubject(UUID.randomUUID(), "t1",
            Set.of("iot/y"), "s2"));
        subjects.add(new TestSubject(UUID.randomUUID(), "t1",
            Set.of("legal/x"), "s3"));

        assertThat(query.countByView(view("iot/**"))).isEqualTo(2);
    }

    @Test
    void findByView_sortAscending() {
        subjects.add(new TestSubject(UUID.randomUUID(), "t1",
            Set.of("iot/x"), "charlie"));
        subjects.add(new TestSubject(UUID.randomUUID(), "t1",
            Set.of("iot/y"), "alpha"));
        subjects.add(new TestSubject(UUID.randomUUID(), "t1",
            Set.of("iot/z"), "bravo"));

        var result = query.findByView(sortedView("iot/**", "name", "ASC"));

        assertThat(result).extracting(TestSubject::name)
            .containsExactly("alpha", "bravo", "charlie");
    }

    @Test
    void findByView_sortDescending() {
        subjects.add(new TestSubject(UUID.randomUUID(), "t1",
            Set.of("iot/x"), "alpha"));
        subjects.add(new TestSubject(UUID.randomUUID(), "t1",
            Set.of("iot/y"), "bravo"));

        var result = query.findByView(sortedView("iot/**", "name", "DESC"));

        assertThat(result).extracting(TestSubject::name)
            .containsExactly("bravo", "alpha");
    }

    @Test
    void findByView_noSortFieldNoOrdering() {
        subjects.add(new TestSubject(UUID.randomUUID(), "t1",
            Set.of("iot/x"), "s1"));

        var result = query.findByView(view("iot/**"));

        assertThat(result).hasSize(1);
    }

    @Test
    void findByView_emptyResultsWhenNoMatch() {
        subjects.add(new TestSubject(UUID.randomUUID(), "t1",
            Set.of("legal/x"), "s1"));

        assertThat(query.findByView(view("iot/**"))).isEmpty();
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl platform-view-inmem -Dtest=InMemorySubjectViewQuerySupportTest`
Expected: Compilation error — class not found

- [ ] **Step 3: Implement InMemorySubjectViewQuerySupport**

Create via `ide_create_file`:

```java
package io.casehub.platform.view.inmem;

import io.casehub.platform.api.view.LabelPatternMatcher;
import io.casehub.platform.api.view.SubjectViewQuery;
import io.casehub.platform.api.view.SubjectViewSpec;

import java.util.*;
import java.util.function.Function;
import java.util.function.Supplier;
import java.util.stream.Stream;

public abstract class InMemorySubjectViewQuerySupport<S>
        implements SubjectViewQuery<S> {

    private final Supplier<Collection<S>> subjectSource;
    private final Function<S, Set<String>> labelExtractor;
    private final Function<S, String> tenancyExtractor;
    private final Function<String, Comparator<S>> sortFieldResolver;

    protected InMemorySubjectViewQuerySupport(
            Supplier<Collection<S>> subjectSource,
            Function<S, Set<String>> labelExtractor,
            Function<S, String> tenancyExtractor,
            Function<String, Comparator<S>> sortFieldResolver) {
        this.subjectSource = subjectSource;
        this.labelExtractor = labelExtractor;
        this.tenancyExtractor = tenancyExtractor;
        this.sortFieldResolver = sortFieldResolver;
    }

    @Override
    public List<S> findByView(SubjectViewSpec view) {
        var stream = subjectSource.get().stream()
            .filter(s -> tenancyExtractor.apply(s).equals(view.tenancyId()))
            .filter(s -> labelExtractor.apply(s).stream()
                .anyMatch(p -> LabelPatternMatcher.matches(
                    view.labelPattern(), p)));
        return sorted(stream, view).toList();
    }

    @Override
    public List<S> findByView(SubjectViewSpec view, int offset, int limit) {
        return findByView(view).stream()
            .skip(offset).limit(limit).toList();
    }

    @Override
    public long countByView(SubjectViewSpec view) {
        return findByView(view).size();
    }

    private Stream<S> sorted(Stream<S> stream, SubjectViewSpec view) {
        if (view.sortField() == null || sortFieldResolver == null) {
            return stream;
        }
        Comparator<S> cmp = sortFieldResolver.apply(view.sortField());
        if (cmp == null) return stream;
        if ("DESC".equalsIgnoreCase(view.sortDirection())) {
            cmp = cmp.reversed();
        }
        return stream.sorted(cmp);
    }
}
```

- [ ] **Step 4: Run tests, verify green**

Run: `mvn --batch-mode test -pl platform-view-inmem`
Expected: All tests pass

- [ ] **Step 5: Commit**

```
feat(#184): add InMemorySubjectViewQuerySupport abstract helper

Parallel to JpaLabelPatternQuerySupport. Domains extend with concrete
types. Includes tenancy filtering, label pattern matching, and
configurable sort field resolution.
```

---

### Task 7: Full build + CLAUDE.md update

**Files:**
- Modify: `CLAUDE.md` (module descriptions)
- Modify: `ARC42STORIES.MD` (L13 description)

- [ ] **Step 1: Run full build**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS

- [ ] **Step 2: Update CLAUDE.md module descriptions**

Update the `platform-view/` module entry to mention SubjectViewOrchestrator and caching.
Update the `platform-view-inmem/` entry to mention InMemorySubjectViewQuerySupport.
Update the Package Structure to include the new public types.

- [ ] **Step 3: Update ARC42STORIES.MD L13 description**

Update L13 to mention ADDED/REMOVED/CHANGED lifecycle events instead of ADDED/REMOVED.

- [ ] **Step 4: Commit**

```
docs: sync CLAUDE.md and ARC42STORIES.MD — #184 complete
```
