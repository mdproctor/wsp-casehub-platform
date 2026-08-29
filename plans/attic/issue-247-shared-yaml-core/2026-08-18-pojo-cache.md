# POJO Deserialization Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** casehubio/engine#926 — perf: cache POJO deserialization per evaluation cycle
**Issue group:** #902, #237, #238, #925, #926

**Goal:** Cache the deserialized POJO in `MvelExpressionEngine` to avoid redundant
Jackson deserialization when multiple MVEL expressions fire against the same context state.

**Architecture:** Add a `private volatile CachedPojo` field (single-entry cache) keyed
by CaseContext identity + version + contextClass. New `resolveTypedPojo()` helper
replaces direct `deserializeToPojo()` calls. Cache miss → deserialize and store.
Cache hit → return stored POJO.

**Tech Stack:** Java 21, Jackson, JUnit 5, AssertJ

## Global Constraints

- All changes in `runtime/` module only — `MvelExpressionEngine.java` + test
- No API changes, no behavioral changes
- IntelliJ MCP required for all source file operations

---

## Batch 1: Cache Implementation

### Task 1: Add CachedPojo record and resolveTypedPojo helper with tests

**Files:**
- Modify: `runtime/src/main/java/io/casehub/engine/internal/engine/MvelExpressionEngine.java`
- Modify: `runtime/src/test/java/io/casehub/engine/internal/engine/MvelExpressionEngineTest.java`

**Interfaces:**
- Produces: `resolveTypedPojo(CaseContext, Class<?>)` → `Object` — replaces direct `deserializeToPojo()` calls

- [ ] **Step 1: Write failing tests for cache behavior**

Add tests to `MvelExpressionEngineTest`:

```java
@Test
void evaluate_sameContextVersion_deserializesOnce() {
    // Create a CaseContext with a typed MVEL expression
    // Evaluate the same expression twice against the same context (no mutations between)
    // Verify the second call is a cache hit (same POJO reference)
}

@Test
void evaluate_differentVersion_redeserializes() {
    // Evaluate once, mutate the context (version increments), evaluate again
    // Verify a fresh POJO is deserialized
}

@Test
void evaluate_differentContext_redeserializes() {
    // Evaluate against context A, then context B (different instance)
    // Verify cache miss on B
}
```

The test needs access to the cached POJO to verify cache hits. Two approaches:
1. Verify by object identity: if the returned evaluation result is derived from the
   same POJO, it implies cache hit. However, MVEL recompiles on each call, so the
   compiled expression produces a new result object each time.
2. Better: add a package-private `cachedPojoForTesting()` accessor that returns
   the current `cachedPojo` field. This is a testing seam, not a public API.

Check existing test patterns in `MvelExpressionEngineTest` to determine the right
approach — the test already creates `CaseContext` instances and evaluates expressions.

Run: `mvn --batch-mode test -pl runtime -Dtest=MvelExpressionEngineTest -f pom.xml`
Expected: FAIL — new test methods reference non-existent `resolveTypedPojo`/`CachedPojo`

- [ ] **Step 2: Add CachedPojo record and resolveTypedPojo helper**

In `MvelExpressionEngine`, add:

```java
private volatile CachedPojo cachedPojo;

private record CachedPojo(CaseContext context, long version,
                           Class<?> contextClass, Object pojo) {}

private Object resolveTypedPojo(final CaseContext context, final Class<?> contextClass) {
    final CachedPojo cached = this.cachedPojo;
    if (cached != null
            && cached.context == context
            && cached.version == context.getVersion()
            && cached.contextClass == contextClass) {
        return cached.pojo;
    }
    final Object pojo = deserializeToPojo(context, contextClass);
    this.cachedPojo = new CachedPojo(context, context.getVersion(), contextClass, pojo);
    return pojo;
}
```

- [ ] **Step 3: Replace deserializeToPojo calls in evaluate()**

In `evaluate()`, replace:
```java
final Object pojo = deserializeToPojo(context, typed.contextClass());
```
with:
```java
final Object pojo = resolveTypedPojo(context, typed.contextClass());
```

- [ ] **Step 4: Replace deserializeToPojo call in extractString()**

In `extractString()`, replace:
```java
final Object pojo = deserializeToPojo(context, typed.contextClass());
```
with:
```java
final Object pojo = resolveTypedPojo(context, typed.contextClass());
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl runtime -Dtest=MvelExpressionEngineTest`
Expected: ALL PASS

- [ ] **Step 6: Run full runtime module tests**

Run: `mvn --batch-mode test -pl runtime`
Expected: BUILD SUCCESS

- [ ] **Step 7: Commit**

```bash
git add runtime/
git commit -m "perf(#926): cache POJO deserialization per evaluation cycle

Single-entry volatile cache in MvelExpressionEngine keyed by
CaseContext identity + version + contextClass. Avoids redundant
Jackson deserialization when N MVEL expressions fire per context change.

Closes casehubio/engine#926
Refs casehubio/engine#926"
```

---

## References

- [2026-08-18-pojo-cache-design.md] — design spec
- `runtime/src/main/java/io/casehub/engine/internal/engine/MvelExpressionEngine.java` — primary file
- `runtime/src/test/java/io/casehub/engine/internal/engine/MvelExpressionEngineTest.java` — test file
- `api/src/main/java/io/casehub/api/context/CaseContext.java` — `getVersion()` contract
- casehubio/engine#926 — focal issue
- casehubio/engine#238 §3 — caching requirement origin
