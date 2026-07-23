# Design: View Deletion Membership Cleanup (#185) + JQ ResultType (#190)

**Date:** 2026-07-20
**Branch:** issue-185-view-cleanup-jq-resulttype
**Covers:** #185, #190

---

## #185 — Proactive membership cleanup on view deletion

### Problem

`SubjectViewOrchestrator.deleteView()` removes the view definition but leaves
membership records orphaned. No REMOVED events fire, so downstream systems
watching for membership changes are never notified. Lazy cleanup via
`evaluateAndTrack()` eventually corrects state, but the event gap is real.

### Root cause

`ViewMembershipTracker` is subject-keyed only. There is no way to query "which
subjects are in view X?" or to bulk-remove membership by view. The schema has
`PRIMARY KEY (subject_id, view_id)` and an index on `subject_id` only — no
`view_id` index.

### Design

#### SPI additions — ViewMembershipTracker

Two new abstract methods (no defaults — all implementations must update):

```java
Set<UUID> getSubjectsByView(UUID viewId);
void removeMembershipByView(UUID viewId);
```

#### Schema change — V5000

Add index to the existing `V5000__subject_view.sql` (pre-release, no deployed
databases):

```sql
CREATE INDEX idx_view_membership_view ON view_membership (view_id);
```

#### Orchestrator — deleteView return type change

`SubjectViewOrchestrator.deleteView(UUID viewId)` changes from `boolean` to
`List<SubjectViewEvent>`. Consistent with `evaluateAndTrack()` which already
returns events.

Sequence:
1. `viewStore.findById(viewId)` — get spec (for tenancyId, name)
2. If empty → return `List.of()` (view doesn't exist, nothing to do)
3. `tracker.getSubjectsByView(viewId)` — get all member subject IDs
4. Build `SubjectViewEvent(subjectId, viewId, name, REMOVED, tenancyId)` for each
5. `viewStore.delete(viewId)` — delete view definition first
6. `invalidateViewCache(tenancyId)`
7. `tracker.removeMembershipByView(viewId)` — clean up membership records
8. Return events

Deletion ordering: the view definition is deleted (step 5) before membership
cleanup (step 7). Any concurrent `evaluateAndTrack` that loads views after
step 5 will not find the deleted view and will not create new membership
records for it. If membership cleanup fails after view deletion, orphaned
records self-correct — the next `evaluateAndTrack` per affected subject will
not find the view, will produce REMOVED events, and will update membership.
This matches the existing non-transactional coordination pattern across all
orchestrator methods.

#### Implementations

**NoOpViewMembershipTracker:**
- `getSubjectsByView` → `Set.of()`
- `removeMembershipByView` → no-op

**InMemoryViewMembershipTracker:**
- `getSubjectsByView` → scan ConcurrentHashMap entries, collect subject IDs
  whose membership map contains the viewId
- `removeMembershipByView` → iterate all entries; for each entry whose
  immutable inner map (`Map.copyOf`) contains the viewId, create a new map
  with viewId filtered out; if the new map is empty, `remove()` the entry;
  otherwise `replace()` with the new immutable map

**JpaViewMembershipTracker:**
- `getSubjectsByView` → `SELECT DISTINCT e.subjectId FROM ViewMembershipEntity e
  WHERE e.viewId = :vid`
- `removeMembershipByView` → bulk JPQL DELETE, consistent with
  `removeMembership(UUID)` pattern:
  `DELETE FROM ViewMembershipEntity e WHERE e.viewId = :vid`

#### Cross-repo ripple

Engine's `CaseQueueViewManager.deleteQueueView()` calls
`views.deleteView(viewId)` and returns the result as `boolean`. The return type
change will require an engine update (wsp-casehub-platform#1).

---

## #190 — JQExpressionEngine.compile() resultType handling

### Problem

`JQExpressionEngine.compile()` accepts a `resultType` parameter but only
branches on `Boolean.class` vs everything else. Non-Boolean scalar types
(String, Integer, etc.) always produce `ListJQExpression`, which returns
`List<JsonNode>` regardless of the requested type. This violates the
`ExpressionEngine` SPI contract.

RAS works around this with `JqResultUnwrapper` — a wrapper that unwraps the
first list element to the target type.

### Design

#### New expression record — ScalarJQExpression

Private record inside `JQExpressionEngine`, alongside `BooleanJQExpression` and
`ListJQExpression`:

```java
private record ScalarJQExpression<R>(JsonQuery query, Scope rootScope,
                                     Class<R> resultType, ObjectMapper mapper)
        implements CompiledExpression<JsonNode, R> {

    @Override public String type() { return "jq"; }

    @Override public R eval(JsonNode context) {
        try {
            Scope childScope = Scope.newChildScope(rootScope);
            List<JsonNode> out = new ArrayList<>();
            query.apply(childScope, context, out::add);
            if (out.isEmpty()) { return null; }
            JsonNode first = out.getFirst();
            if (first.isNull()) { return null; }
            if (resultType == String.class) {
                return resultType.cast(first.asText());
            }
            return mapper.convertValue(first, resultType);
        } catch (Exception e) {
            throw new ExpressionEvaluationException("JQ evaluation failed", e);
        }
    }
}
```

Null semantics: empty result → null, null JsonNode → null. String uses
`asText()` (handles all node types). Everything else uses
`ObjectMapper.convertValue`.

#### Compile method — complete updated method body

```java
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
```

`MapAdaptedJQExpression` wraps any expression type when
`contextType != JsonNode.class`. Its mapper handles context conversion
(Map→JsonNode); `ScalarJQExpression`'s mapper handles result conversion
(JsonNode→R). Both reference the same static `MAPPER` instance — each serves
a distinct purpose in the pipeline.

#### What doesn't change

- `BooleanJQExpression` — unchanged
- `ListJQExpression` — unchanged
- `MapAdaptedJQExpression` — unchanged (delegates to inner expression)
- `ExpressionEngine` SPI — unchanged
- `CacheKey` — unchanged (already includes resultType)

#### Cross-repo ripple

RAS's `JqResultUnwrapper` becomes redundant. `SituationDefinitionRegistry`
can compile directly with the target type (wsp-casehub-platform#2).

---

## Test strategy

### #185 tests

- **ViewMembershipTracker SPI tests** (per implementation):
  - `getSubjectsByView` returns correct subject IDs
  - `getSubjectsByView` returns empty set for unknown viewId
  - `removeMembershipByView` removes all records for the view
  - `removeMembershipByView` is no-op for unknown viewId
  - `removeMembershipByView` leaves other views' membership intact

- **SubjectViewOrchestrator tests**:
  - `deleteView` returns REMOVED events for each member
  - `deleteView` removes membership records (tracker state verified)
  - `deleteView` returns empty list for non-existent view
  - `deleteView` returns empty list for view with no members
  - `deleteView` invalidates view cache
  - `deleteView` events carry correct `viewName` from `SubjectViewSpec`
  - `deleteView` events carry correct `tenancyId` from `SubjectViewSpec`

### #190 tests

- **ScalarJQExpression tests** (via JQExpressionEngine):
  - String result type — field extraction returns String
  - Integer result type — numeric extraction returns Integer
  - String result on null field — returns null
  - String result on missing field — returns null (empty JQ output)
  - Map context with String result type — works via MapAdaptedJQExpression
  - Caching — same expression/context/result type returns same instance
  - Caching — different result types produce different instances
