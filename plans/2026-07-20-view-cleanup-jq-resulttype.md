# View Deletion Cleanup + JQ ResultType Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #185 — Subject view: proactive membership cleanup on view deletion
**Issue group:** #185, #190

**Goal:** Fix two platform gaps: (1) `deleteView` now cleans up membership records
and fires REMOVED events; (2) `JQExpressionEngine.compile()` honours scalar
`resultType` instead of always returning `List<JsonNode>`.

**Architecture:** #190 adds a `ScalarJQExpression` record inside `JQExpressionEngine`
with a three-way branch in `compile()` (Boolean / List / scalar). #185 adds two
methods to the `ViewMembershipTracker` SPI (`getSubjectsByView`, `removeMembershipByView`),
implements them across all three backends (NoOp, InMemory, JPA), modifies the V5000
schema to add a `view_id` index, and changes `SubjectViewOrchestrator.deleteView()`
from `boolean` to `List<SubjectViewEvent>`.

**Tech Stack:** Java 21, Quarkus, jackson-jq, JPA (Hibernate ORM Panache), AssertJ,
JUnit 5

## Global Constraints

- Pre-release platform — breaking changes cost nothing. Fix the design.
- `platform-api/` is zero-dependency — no Quarkus, no JPA imports.
- IntelliJ MCP mandatory for all `.java` edits and navigation.
- All edits via `ide_edit_member`, `ide_insert_member`, `ide_replace_member`,
  or `ide_create_file`. Never `Edit`/`Write` on existing `.java` files.

---

### Task 1: JQExpressionEngine — ScalarJQExpression (#190)

**Files:**
- Modify: `expression/src/main/java/io/casehub/platform/expression/JQExpressionEngine.java`
- Modify: `expression/src/test/java/io/casehub/platform/expression/JQExpressionEngineTest.java`

**Interfaces:**
- Consumes: `CompiledExpression<C, R>` (platform-api), `ExpressionEvaluationException` (platform-api), jackson-jq `JsonQuery`/`Scope`
- Produces: `JQExpressionEngine.compile()` now returns `ScalarJQExpression` for non-Boolean, non-List result types. No public API change — `ExpressionEngine` SPI unchanged.

- [ ] **Step 1: Write failing tests for scalar result types**

Add seven tests to `JQExpressionEngineTest`. Use `ide_insert_member` on class
`JQExpressionEngineTest` in file
`expression/src/test/java/io/casehub/platform/expression/JQExpressionEngineTest.java`,
positioned after the last existing test:

```java
@Test
void compile_stringResult() {
    ObjectNode input = MAPPER.createObjectNode().put("name", "alice");
    CompiledExpression<JsonNode, String> expr =
            engine.compile(".name", JsonNode.class, String.class);
    assertThat(expr.eval(input)).isEqualTo("alice");
}

@Test
void compile_integerResult() {
    ObjectNode input = MAPPER.createObjectNode().put("count", 42);
    CompiledExpression<JsonNode, Integer> expr =
            engine.compile(".count", JsonNode.class, Integer.class);
    assertThat(expr.eval(input)).isEqualTo(42);
}

@Test
void compile_stringResult_nullField_returnsNull() {
    ObjectNode input = MAPPER.createObjectNode();
    input.putNull("name");
    CompiledExpression<JsonNode, String> expr =
            engine.compile(".name", JsonNode.class, String.class);
    assertThat(expr.eval(input)).isNull();
}

@Test
void compile_stringResult_missingField_returnsNull() {
    ObjectNode input = MAPPER.createObjectNode().put("other", "value");
    CompiledExpression<JsonNode, String> expr =
            engine.compile(".name", JsonNode.class, String.class);
    assertThat(expr.eval(input)).isNull();
}

@Test
void compile_mapContext_stringResult() {
    CompiledExpression<Map<String, Object>, String> expr =
            engine.compile(".name", Map.class, String.class);
    var context = new java.util.HashMap<String, Object>();
    context.put("name", "alice");
    assertThat(expr.eval(context)).isEqualTo("alice");
}

@Test
void compile_scalarResult_cachedForSameExpression() {
    CompiledExpression<?, ?> first = engine.compile(".name", JsonNode.class, String.class);
    CompiledExpression<?, ?> second = engine.compile(".name", JsonNode.class, String.class);
    assertThat(first).isSameAs(second);
}

@Test
void compile_differentResultTypes_produceDifferentInstances() {
    CompiledExpression<?, ?> stringExpr = engine.compile(".value", JsonNode.class, String.class);
    CompiledExpression<?, ?> intExpr = engine.compile(".value", JsonNode.class, Integer.class);
    assertThat(stringExpr).isNotSameAs(intExpr);
}
```

- [ ] **Step 2: Run tests — verify they fail**

Run: `mvn --batch-mode test -pl expression -Dtest="JQExpressionEngineTest#compile_stringResult+compile_integerResult+compile_stringResult_nullField_returnsNull+compile_stringResult_missingField_returnsNull+compile_mapContext_stringResult+compile_scalarResult_cachedForSameExpression+compile_differentResultTypes_produceDifferentInstances"`

Expected: FAIL — `compile_stringResult` returns `List<JsonNode>`, not `String`;
`compile_integerResult` returns `List<JsonNode>`, not `Integer`.

- [ ] **Step 3: Add ScalarJQExpression record**

Use `ide_insert_member` on class `JQExpressionEngine` in file
`expression/src/main/java/io/casehub/platform/expression/JQExpressionEngine.java`,
positioned after `ListJQExpression`:

```java
private record ScalarJQExpression<R>(JsonQuery query, Scope rootScope,
                                     Class<R> resultType, ObjectMapper mapper)
        implements CompiledExpression<JsonNode, R> {

    @Override
    public String type() {return "jq";}

    @Override
    public R eval(JsonNode context) {
        try {
            Scope          childScope = Scope.newChildScope(rootScope);
            List<JsonNode> out        = new ArrayList<>();
            query.apply(childScope, context, out::add);
            if (out.isEmpty()) {return null;}
            JsonNode first = out.getFirst();
            if (first.isNull()) {return null;}
            if (resultType == String.class) {
                return resultType.cast(first.asText());
            }
            return mapper.convertValue(first, resultType);
        } catch (Exception e) {
            throw new ExpressionEvaluationException(
                    "JQ evaluation failed", e);
        }
    }
}
```

- [ ] **Step 4: Update compile method — three-way branch**

Use `ide_replace_member` on method `compile` (the 4-parameter overload,
`parameterCount=4`) in class `JQExpressionEngine`:

```java
@Override
@SuppressWarnings("unchecked")
public <C, R> CompiledExpression<C, R> compile(
        String expression, Class<C> contextType, Class<R> resultType,
        Map<String, Object> variables) {
    Objects.requireNonNull(expression, "expression");

    var key = new CacheKey(expression, contextType, resultType);
    return (CompiledExpression<C, R>) expressionCache.computeIfAbsent(key, k -> {
        JsonQuery query = compileQuery(expression);
        CompiledExpression<JsonNode, ?> jqExpr;
        if (resultType == Boolean.class) {
            jqExpr = new BooleanJQExpression(query, rootScope);
        } else if (resultType == List.class) {
            jqExpr = new ListJQExpression(query, rootScope);
        } else {
            jqExpr = new ScalarJQExpression<>(query, rootScope, resultType, MAPPER);
        }

        if (contextType == JsonNode.class) {
            return jqExpr;
        }
        return new MapAdaptedJQExpression<>(jqExpr, MAPPER);
    });
}
```

- [ ] **Step 5: Run all JQExpressionEngine tests**

Run: `mvn --batch-mode test -pl expression -Dtest="JQExpressionEngineTest"`

Expected: ALL PASS (18 tests — 11 existing + 7 new).

- [ ] **Step 6: Verify with ide_diagnostics**

Run `ide_diagnostics` on `JQExpressionEngine.java` — expect no errors.

- [ ] **Step 7: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add expression/src/main/java/io/casehub/platform/expression/JQExpressionEngine.java expression/src/test/java/io/casehub/platform/expression/JQExpressionEngineTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#190): JQExpressionEngine — ScalarJQExpression for non-Boolean, non-List result types"
```

---

### Task 2: ViewMembershipTracker SPI + all implementations (#185)

**Files:**
- Modify: `platform-api/src/main/java/io/casehub/platform/api/view/ViewMembershipTracker.java`
- Modify: `platform-view-jpa/src/main/resources/db/view/migration/V5000__subject_view.sql`
- Modify: `platform/src/main/java/io/casehub/platform/view/NoOpViewMembershipTracker.java`
- Modify: `platform/src/test/java/io/casehub/platform/view/NoOpViewMembershipTrackerTest.java`
- Modify: `platform-view-inmem/src/main/java/io/casehub/platform/view/inmem/InMemoryViewMembershipTracker.java`
- Modify: `platform-view-inmem/src/test/java/io/casehub/platform/view/inmem/InMemoryViewMembershipTrackerTest.java`
- Modify: `platform-view-jpa/src/main/java/io/casehub/platform/view/jpa/JpaViewMembershipTracker.java`
- Modify: `platform-view-jpa/src/test/java/io/casehub/platform/view/jpa/JpaViewMembershipTrackerTest.java`

**Interfaces:**
- Consumes: nothing new
- Produces: `ViewMembershipTracker.getSubjectsByView(UUID viewId) → Set<UUID>`,
  `ViewMembershipTracker.removeMembershipByView(UUID viewId) → void`.
  Used by Task 3's `SubjectViewOrchestrator.deleteView()`.

- [ ] **Step 1: Add SPI methods to ViewMembershipTracker**

Use `ide_insert_member` on interface `ViewMembershipTracker` in file
`platform-api/src/main/java/io/casehub/platform/api/view/ViewMembershipTracker.java`,
positioned after `removeMembership`:

```java
Set<UUID> getSubjectsByView(UUID viewId);
void removeMembershipByView(UUID viewId);
```

- [ ] **Step 2: Add view_id index to V5000 schema**

Use `ide_replace_text_in_file` on
`platform-view-jpa/src/main/resources/db/view/migration/V5000__subject_view.sql`
to append the index after the existing `idx_view_membership_subject` line.
Search for the last line `CREATE INDEX idx_view_membership_subject ON view_membership (subject_id);`
and replace with:

```sql
CREATE INDEX idx_view_membership_subject ON view_membership (subject_id);
CREATE INDEX idx_view_membership_view ON view_membership (view_id);
```

- [ ] **Step 3: Write NoOp failing tests**

Use `ide_insert_member` on class `NoOpViewMembershipTrackerTest` in file
`platform/src/test/java/io/casehub/platform/view/NoOpViewMembershipTrackerTest.java`,
positioned after `removeMembershipDoesNotThrow`:

```java
@Test
void getSubjectsByViewReturnsEmpty() {
    assertThat(tracker.getSubjectsByView(UUID.randomUUID())).isEmpty();
}

@Test
void removeMembershipByViewDoesNotThrow() {
    tracker.removeMembershipByView(UUID.randomUUID());
}
```

- [ ] **Step 4: Run NoOp tests — verify compilation failure**

Run: `mvn --batch-mode test -pl platform -Dtest="NoOpViewMembershipTrackerTest" -DfailIfNoTests=false`

Expected: COMPILATION FAIL — `NoOpViewMembershipTracker` does not implement
the two new abstract methods.

- [ ] **Step 5: Implement NoOp methods**

Use `ide_insert_member` on class `NoOpViewMembershipTracker` in file
`platform/src/main/java/io/casehub/platform/view/NoOpViewMembershipTracker.java`,
positioned after `removeMembership`:

```java
@Override
public Set<UUID> getSubjectsByView(UUID viewId) {
    return Set.of();
}

@Override
public void removeMembershipByView(UUID viewId) {
}
```

- [ ] **Step 6: Run NoOp tests — verify pass**

Run: `mvn --batch-mode test -pl platform -Dtest="NoOpViewMembershipTrackerTest"`

Expected: ALL PASS (6 tests).

- [ ] **Step 7: Write InMemory failing tests**

Use `ide_insert_member` on class `InMemoryViewMembershipTrackerTest` in file
`platform-view-inmem/src/test/java/io/casehub/platform/view/inmem/InMemoryViewMembershipTrackerTest.java`,
positioned after `bulkGetEmptySetReturnsEmpty`:

```java
@Test
void getSubjectsByView_returnsMatchingSubjects() {
    var s1 = UUID.randomUUID();
    var s2 = UUID.randomUUID();
    var s3 = UUID.randomUUID();
    var v1 = UUID.randomUUID();
    var v2 = UUID.randomUUID();
    tracker.updateMembership(s1, Map.of(v1, "View A", v2, "View B"));
    tracker.updateMembership(s2, Map.of(v1, "View A"));
    tracker.updateMembership(s3, Map.of(v2, "View B"));

    assertThat(tracker.getSubjectsByView(v1)).containsExactlyInAnyOrder(s1, s2);
}

@Test
void getSubjectsByView_unknownView_returnsEmpty() {
    tracker.updateMembership(UUID.randomUUID(), Map.of(UUID.randomUUID(), "v"));
    assertThat(tracker.getSubjectsByView(UUID.randomUUID())).isEmpty();
}

@Test
void removeMembershipByView_removesAllRecordsForView() {
    var s1 = UUID.randomUUID();
    var s2 = UUID.randomUUID();
    var v1 = UUID.randomUUID();
    var v2 = UUID.randomUUID();
    tracker.updateMembership(s1, Map.of(v1, "View A", v2, "View B"));
    tracker.updateMembership(s2, Map.of(v1, "View A"));

    tracker.removeMembershipByView(v1);

    assertThat(tracker.getLastKnownMembership(s1))
            .containsExactlyEntriesOf(Map.of(v2, "View B"));
    assertThat(tracker.getLastKnownMembership(s2)).isEmpty();
}

@Test
void removeMembershipByView_unknownView_isNoOp() {
    var subject = UUID.randomUUID();
    var view    = UUID.randomUUID();
    tracker.updateMembership(subject, Map.of(view, "View A"));

    tracker.removeMembershipByView(UUID.randomUUID());

    assertThat(tracker.getLastKnownMembership(subject))
            .containsExactlyEntriesOf(Map.of(view, "View A"));
}

@Test
void removeMembershipByView_leavesOtherViewsIntact() {
    var subject = UUID.randomUUID();
    var v1      = UUID.randomUUID();
    var v2      = UUID.randomUUID();
    tracker.updateMembership(subject, Map.of(v1, "View A", v2, "View B"));

    tracker.removeMembershipByView(v1);

    assertThat(tracker.getLastKnownMembership(subject))
            .containsExactlyEntriesOf(Map.of(v2, "View B"));
}
```

- [ ] **Step 8: Run InMemory tests — verify compilation failure**

Run: `mvn --batch-mode test -pl platform-view-inmem -Dtest="InMemoryViewMembershipTrackerTest" -DfailIfNoTests=false`

Expected: COMPILATION FAIL — `InMemoryViewMembershipTracker` does not implement
the two new abstract methods.

- [ ] **Step 9: Implement InMemory methods**

Use `ide_insert_member` on class `InMemoryViewMembershipTracker` in file
`platform-view-inmem/src/main/java/io/casehub/platform/view/inmem/InMemoryViewMembershipTracker.java`,
positioned after `removeMembership`. Note: inner maps are stored as `Map.copyOf`
(immutable). `removeMembershipByView` must create a new filtered map, not mutate.

```java
@Override
public Set<UUID> getSubjectsByView(UUID viewId) {
    Set<UUID> result = new java.util.HashSet<>();
    state.forEach((subjectId, membership) -> {
        if (membership.containsKey(viewId)) {
            result.add(subjectId);
        }
    });
    return result;
}

@Override
public void removeMembershipByView(UUID viewId) {
    state.forEach((subjectId, membership) -> {
        if (membership.containsKey(viewId)) {
            Map<UUID, String> updated = new java.util.HashMap<>(membership);
            updated.remove(viewId);
            if (updated.isEmpty()) {
                state.remove(subjectId);
            } else {
                state.replace(subjectId, Map.copyOf(updated));
            }
        }
    });
}
```

- [ ] **Step 10: Run InMemory tests — verify pass**

Run: `mvn --batch-mode test -pl platform-view-inmem -Dtest="InMemoryViewMembershipTrackerTest"`

Expected: ALL PASS (14 tests — 9 existing + 5 new).

- [ ] **Step 11: Write JPA failing tests**

Use `ide_insert_member` on class `JpaViewMembershipTrackerTest` in file
`platform-view-jpa/src/test/java/io/casehub/platform/view/jpa/JpaViewMembershipTrackerTest.java`,
positioned after `updateTwiceSameViewWithinTransaction`:

```java
@Test
void getSubjectsByView_returnsMatchingSubjects() {
    var s1 = UUID.randomUUID();
    var s2 = UUID.randomUUID();
    var v1 = UUID.randomUUID();
    var v2 = UUID.randomUUID();
    tracker.updateMembership(s1, Map.of(v1, "View A", v2, "View B"));
    tracker.updateMembership(s2, Map.of(v1, "View A"));

    assertThat(tracker.getSubjectsByView(v1)).containsExactlyInAnyOrder(s1, s2);
}

@Test
void getSubjectsByView_unknownView_returnsEmpty() {
    assertThat(tracker.getSubjectsByView(UUID.randomUUID())).isEmpty();
}

@Test
void removeMembershipByView_removesAllRecordsForView() {
    var s1 = UUID.randomUUID();
    var s2 = UUID.randomUUID();
    var v1 = UUID.randomUUID();
    var v2 = UUID.randomUUID();
    tracker.updateMembership(s1, Map.of(v1, "View A", v2, "View B"));
    tracker.updateMembership(s2, Map.of(v1, "View A"));

    tracker.removeMembershipByView(v1);

    assertThat(tracker.getLastKnownMembership(s1))
            .containsExactlyEntriesOf(Map.of(v2, "View B"));
    assertThat(tracker.getLastKnownMembership(s2)).isEmpty();
}

@Test
void removeMembershipByView_unknownView_isNoOp() {
    var subject = UUID.randomUUID();
    var view    = UUID.randomUUID();
    tracker.updateMembership(subject, Map.of(view, "View A"));

    tracker.removeMembershipByView(UUID.randomUUID());

    assertThat(tracker.getLastKnownMembership(subject))
            .containsExactlyEntriesOf(Map.of(view, "View A"));
}

@Test
void removeMembershipByView_leavesOtherViewsIntact() {
    var subject = UUID.randomUUID();
    var v1      = UUID.randomUUID();
    var v2      = UUID.randomUUID();
    tracker.updateMembership(subject, Map.of(v1, "View A", v2, "View B"));

    tracker.removeMembershipByView(v1);

    assertThat(tracker.getLastKnownMembership(subject))
            .containsExactlyEntriesOf(Map.of(v2, "View B"));
}
```

- [ ] **Step 12: Run JPA tests — verify compilation failure**

Run: `mvn --batch-mode test -pl platform-view-jpa -Dtest="JpaViewMembershipTrackerTest" -DfailIfNoTests=false`

Expected: COMPILATION FAIL — `JpaViewMembershipTracker` does not implement
the two new abstract methods.

- [ ] **Step 13: Implement JPA methods**

Use `ide_insert_member` on class `JpaViewMembershipTracker` in file
`platform-view-jpa/src/main/java/io/casehub/platform/view/jpa/JpaViewMembershipTracker.java`,
positioned after `removeMembership`:

```java
@Override
public Set<UUID> getSubjectsByView(UUID viewId) {
    return new java.util.HashSet<>(em.createQuery(
                    "SELECT DISTINCT e.subjectId FROM ViewMembershipEntity e WHERE e.viewId = :vid",
                    UUID.class)
            .setParameter("vid", viewId)
            .getResultList());
}

@Override
@Transactional
public void removeMembershipByView(UUID viewId) {
    em.createQuery("DELETE FROM ViewMembershipEntity e WHERE e.viewId = :vid")
      .setParameter("vid", viewId)
      .executeUpdate();
}
```

- [ ] **Step 14: Run JPA tests — verify pass**

Run: `mvn --batch-mode test -pl platform-view-jpa -Dtest="JpaViewMembershipTrackerTest"`

Expected: ALL PASS (12 tests — 7 existing + 5 new).

- [ ] **Step 15: Verify all three modules compile**

Run `ide_build_project` with project path `/Users/mdproctor/claude/casehub/platform`.

Expected: BUILD SUCCESS.

- [ ] **Step 16: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform-api/src/main/java/io/casehub/platform/api/view/ViewMembershipTracker.java platform/src/main/java/io/casehub/platform/view/NoOpViewMembershipTracker.java platform/src/test/java/io/casehub/platform/view/NoOpViewMembershipTrackerTest.java platform-view-inmem/src/main/java/io/casehub/platform/view/inmem/InMemoryViewMembershipTracker.java platform-view-inmem/src/test/java/io/casehub/platform/view/inmem/InMemoryViewMembershipTrackerTest.java platform-view-jpa/src/main/java/io/casehub/platform/view/jpa/JpaViewMembershipTracker.java platform-view-jpa/src/test/java/io/casehub/platform/view/jpa/JpaViewMembershipTrackerTest.java platform-view-jpa/src/main/resources/db/view/migration/V5000__subject_view.sql
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#185): ViewMembershipTracker — getSubjectsByView + removeMembershipByView across all implementations"
```

---

### Task 3: SubjectViewOrchestrator.deleteView enhancement (#185)

**Files:**
- Modify: `platform-view/src/main/java/io/casehub/platform/view/SubjectViewOrchestrator.java`
- Modify: `platform-view/src/test/java/io/casehub/platform/view/SubjectViewOrchestratorTest.java`

**Interfaces:**
- Consumes: `ViewMembershipTracker.getSubjectsByView(UUID)` and
  `ViewMembershipTracker.removeMembershipByView(UUID)` from Task 2
- Produces: `SubjectViewOrchestrator.deleteView(UUID viewId) → List<SubjectViewEvent>`
  (breaking change from `boolean`). Consumed by engine's `CaseQueueViewManager`.

- [ ] **Step 1: Update StubTracker in test with new methods**

Use `ide_insert_member` on class `StubTracker` (inner class of
`SubjectViewOrchestratorTest`) in file
`platform-view/src/test/java/io/casehub/platform/view/SubjectViewOrchestratorTest.java`,
positioned after `removeMembership`:

```java
@Override
public Set<UUID> getSubjectsByView(UUID viewId) {
    Set<UUID> result = new java.util.HashSet<>();
    state.forEach((subjectId, membership) -> {
        if (membership.containsKey(viewId)) {
            result.add(subjectId);
        }
    });
    return result;
}

@Override
public void removeMembershipByView(UUID viewId) {
    state.forEach((subjectId, membership) -> {
        if (membership.containsKey(viewId)) {
            Map<UUID, String> updated = new java.util.HashMap<>(membership);
            updated.remove(viewId);
            if (updated.isEmpty()) {
                state.remove(subjectId);
            } else {
                state.put(subjectId, Map.copyOf(updated));
            }
        }
    });
}
```

- [ ] **Step 2: Write failing tests for deleteView**

Use `ide_edit_member` to replace the existing `deleteView_removesFromStore` test
(it will fail to compile since the return type changes). Replace with:

```java
@Test
void deleteView_removesFromStore() {
    var saved = orchestrator.saveView(new SubjectViewSpec(null, "test", "t1",
        "iot/**", null, null, null, null, null));
    var events = orchestrator.deleteView(saved.id());
    assertThat(viewStore.findById(saved.id())).isEmpty();
    assertThat(events).isEmpty();
}
```

Use `ide_edit_member` to replace the existing `deleteView_nonExistentIsNoOp` test:

```java
@Test
void deleteView_nonExistentIsNoOp() {
    var events = orchestrator.deleteView(UUID.randomUUID());
    assertThat(events).isEmpty();
}
```

Then use `ide_insert_member` to add the new tests after `deleteView_nonExistentIsNoOp`:

```java
@Test
void deleteView_returnsRemovedEventsForMembers() {
    var saved = orchestrator.saveView(new SubjectViewSpec(null, "Test View", "t1",
        "iot/**", null, null, null, null, null));
    var s1 = UUID.randomUUID();
    var s2 = UUID.randomUUID();
    tracker.updateMembership(s1, Map.of(saved.id(), "Test View"));
    tracker.updateMembership(s2, Map.of(saved.id(), "Test View"));

    var events = orchestrator.deleteView(saved.id());

    assertThat(events).hasSize(2);
    assertThat(events).allMatch(e -> e.type() == ViewEventType.REMOVED);
    assertThat(events).allMatch(e -> e.viewId().equals(saved.id()));
    assertThat(events).allMatch(e -> e.viewName().equals("Test View"));
    assertThat(events).allMatch(e -> e.tenancyId().equals("t1"));
    assertThat(events.stream().map(SubjectViewEvent::subjectId)
            .collect(java.util.stream.Collectors.toSet()))
            .containsExactlyInAnyOrder(s1, s2);
}

@Test
void deleteView_removesMembershipRecords() {
    var saved = orchestrator.saveView(new SubjectViewSpec(null, "Test View", "t1",
        "iot/**", null, null, null, null, null));
    var subject = UUID.randomUUID();
    tracker.updateMembership(subject, Map.of(saved.id(), "Test View"));

    orchestrator.deleteView(saved.id());

    assertThat(tracker.getLastKnownMembership(subject)).isEmpty();
}

@Test
void deleteView_invalidatesViewCache() {
    orchestrator.cacheTtlSeconds = 60;
    var saved = orchestrator.saveView(new SubjectViewSpec(null, "cached-view", "t1",
        "iot/**", null, null, null, null, null));
    var s = UUID.randomUUID();
    orchestrator.evaluateAndTrack(s, "t1", Set.of("iot/x"));

    orchestrator.deleteView(saved.id());
    var events = orchestrator.evaluateAndTrack(s, "t1", Set.of("iot/x"));

    assertThat(events).hasSize(1);
    assertThat(events.get(0).type()).isEqualTo(ViewEventType.REMOVED);
}

@Test
void deleteView_eventsCarryCorrectViewNameAndTenancyId() {
    var saved = orchestrator.saveView(new SubjectViewSpec(null, "Named View", "tenant-42",
        "iot/**", null, null, null, null, null));
    var subject = UUID.randomUUID();
    tracker.updateMembership(subject, Map.of(saved.id(), "Named View"));

    var events = orchestrator.deleteView(saved.id());

    assertThat(events).hasSize(1);
    assertThat(events.get(0).viewName()).isEqualTo("Named View");
    assertThat(events.get(0).tenancyId()).isEqualTo("tenant-42");
}
```

- [ ] **Step 3: Run tests — verify compilation failure**

Run: `mvn --batch-mode test -pl platform-view -Dtest="SubjectViewOrchestratorTest" -DfailIfNoTests=false`

Expected: COMPILATION FAIL — `deleteView` still returns `boolean`, tests expect
`List<SubjectViewEvent>`.

- [ ] **Step 4: Change deleteView return type and implement**

Use `ide_edit_member` on method `deleteView` in class `SubjectViewOrchestrator`
in file `platform-view/src/main/java/io/casehub/platform/view/SubjectViewOrchestrator.java`:

```java
public List<SubjectViewEvent> deleteView(UUID viewId) {
    var spec = viewStore.findById(viewId);
    if (spec.isEmpty()) {return List.of();}
    var s = spec.get();

    Set<UUID> members = tracker.getSubjectsByView(viewId);
    List<SubjectViewEvent> events = members.stream()
            .map(subjectId -> new SubjectViewEvent(
                    subjectId, viewId, s.name(), ViewEventType.REMOVED, s.tenancyId()))
            .toList();

    viewStore.delete(viewId);
    invalidateViewCache(s.tenancyId());
    tracker.removeMembershipByView(viewId);
    return events;
}
```

Add the missing import for `Set` if not already present — `ide_edit_member` with
`reformat=true` will handle import optimization.

- [ ] **Step 5: Run all orchestrator tests — verify pass**

Run: `mvn --batch-mode test -pl platform-view -Dtest="SubjectViewOrchestratorTest"`

Expected: ALL PASS (15 tests — 11 existing/updated + 4 new).

- [ ] **Step 6: Verify with ide_diagnostics**

Run `ide_diagnostics` on `SubjectViewOrchestrator.java` — expect no errors.

- [ ] **Step 7: Full build**

Run: `mvn --batch-mode install`

Expected: BUILD SUCCESS across all modules.

- [ ] **Step 8: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform-view/src/main/java/io/casehub/platform/view/SubjectViewOrchestrator.java platform-view/src/test/java/io/casehub/platform/view/SubjectViewOrchestratorTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#185): SubjectViewOrchestrator.deleteView — proactive membership cleanup with REMOVED events"
```
