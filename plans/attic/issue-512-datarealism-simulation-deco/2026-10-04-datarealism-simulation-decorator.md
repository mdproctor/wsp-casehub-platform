# DataRealism Tagging in Simulation Decorator Generator — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #512 — feat: DataRealism tagging in simulation decorator generator (Phase 2a)
**Issue group:** #512

**Goal:** Replace `boolean simulated` in the simulation journal pipeline with `DataRealism` enum, enabling consumers to distinguish naive ref responses from realistic simulation responses.

**Architecture:** `DataRealism` already exists in `simulation-api` but is unused. This wires it through three layers: (1) `SimulationStrategy` declares its realism level via a new `dataRealism()` default method, (2) `JournalEntry` replaces `boolean simulated` with `DataRealism dataRealism` (nullable — `null` means delegate was called, not simulated), (3) `SimulationDecoratorProcessor` generates code that passes `strategy.get().dataRealism()` for simulated paths and `null` for delegate paths.

**Tech Stack:** Java 21, Maven, Jandex APT, CDI decorators

## Global Constraints

- `simulation-api` must remain zero-dependency and J2CL-safe
- `simulation-core` depends on `simulation-api` only (no CDI)
- `simulation-generator` is build-time only (APT)
- All primitives in `yaml-core` MUST use `j.u.c` locks — never `synchronized`
- Tasks 4 (request-scoped CDI producer) and 5 (seed file loading) from the issue are deferred to follow-up issues

---

## Batch 1: API Layer — SimulationStrategy.dataRealism()

### Task 1: Add `dataRealism()` default method to `SimulationStrategy` and override in 5 implementations

**Files:**
- Modify: `simulation-api/src/main/java/io/casehub/platform/simulation/SimulationStrategy.java`
- Modify: `simulation-core/src/main/java/io/casehub/platform/simulation/strategy/SequentialStrategy.java`
- Modify: `simulation-core/src/main/java/io/casehub/platform/simulation/strategy/KeyLookupStrategy.java`
- Modify: `simulation-core/src/main/java/io/casehub/platform/simulation/strategy/RandomStrategy.java`
- Modify: `simulation-core/src/main/java/io/casehub/platform/simulation/strategy/RecordedReplayStrategy.java`
- Modify: `simulation-core/src/main/java/io/casehub/platform/simulation/strategy/NearestMatchStrategy.java`
- Test: `simulation-core/src/test/java/io/casehub/platform/simulation/strategy/SequentialStrategyTest.java`
- Test: `simulation-core/src/test/java/io/casehub/platform/simulation/strategy/KeyLookupStrategyTest.java`
- Test: `simulation-core/src/test/java/io/casehub/platform/simulation/strategy/RandomStrategyTest.java`
- Test: `simulation-core/src/test/java/io/casehub/platform/simulation/strategy/RecordedReplayStrategyTest.java`
- Test: `simulation-core/src/test/java/io/casehub/platform/simulation/strategy/NearestMatchStrategyTest.java`

**Interfaces:**
- Produces: `SimulationStrategy.dataRealism()` → `DataRealism` (default: `DOMAIN_PLAUSIBLE`)

**Strategy → DataRealism mapping (from issue):**

| Strategy | DataRealism |
|----------|------------|
| `SequentialStrategy` | `STRUCTURALLY_VALID` |
| `RandomStrategy` | `STRUCTURALLY_VALID` |
| `KeyLookupStrategy` | `DOMAIN_PLAUSIBLE` |
| `NearestMatchStrategy` | `DOMAIN_PLAUSIBLE` |
| `RecordedReplayStrategy` | `RECORDED_REAL` |

- [ ] **Step 1: Write failing tests for each strategy's `dataRealism()`**

Add one test per strategy test class asserting the expected `DataRealism` value. Example for `SequentialStrategyTest`:

```java
@Test
void dataRealismReturnsStructurallyValid() {
    var strategy = new SequentialStrategy<>(corpus, QN, ExhaustionPolicy.WRAP);
    assertThat(strategy.dataRealism()).isEqualTo(DataRealism.STRUCTURALLY_VALID);
}
```

Repeat for each strategy with its expected value from the table above.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl simulation-core -Dtest="SequentialStrategyTest#dataRealismReturnsStructurallyValid,KeyLookupStrategyTest#dataRealismReturnsDomainPlausible,RandomStrategyTest#dataRealismReturnsStructurallyValid,RecordedReplayStrategyTest#dataRealismReturnsRecordedReal,NearestMatchStrategyTest#dataRealismReturnsDomainPlausible"`
Expected: compilation error — `dataRealism()` method doesn't exist yet.

- [ ] **Step 3: Add default method to `SimulationStrategy` and overrides in each implementation**

In `SimulationStrategy.java`, add:

```java
default DataRealism dataRealism() {
    return DataRealism.DOMAIN_PLAUSIBLE;
}
```

In each strategy implementation, add `@Override` with the value from the mapping table. For `SequentialStrategy`:

```java
@Override
public DataRealism dataRealism() {
    return DataRealism.STRUCTURALLY_VALID;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl simulation-api,simulation-core`
Expected: all tests PASS. This is purely additive — no existing code is broken.

- [ ] **Step 5: Commit**

```
feat(#512): add dataRealism() to SimulationStrategy with per-strategy overrides
```

---

## Batch 2: Core Layer — JournalEntry, Runtime, Verification, and Callers

### Task 2: Replace `boolean simulated` with `DataRealism dataRealism` in `JournalEntry` and update all callers

**Files:**
- Modify: `simulation-core/src/main/java/io/casehub/platform/simulation/JournalEntry.java`
- Modify: `simulation-core/src/main/java/io/casehub/platform/simulation/SimulationRuntime.java:141-148`
- Modify: `simulation-core/src/main/java/io/casehub/platform/simulation/MethodVerification.java:77-107,131-136`
- Modify: `simulation-core/src/main/java/io/casehub/platform/simulation/SimulationVerifier.java:67-77`
- Modify: `simulation-core/src/main/java/io/casehub/platform/simulation/Simulation.java:39`
- Modify: `simulation-core/src/main/java/io/casehub/platform/simulation/TemporalSimulationDriver.java:148-150`
- Test: `simulation-core/src/test/java/io/casehub/platform/simulation/SimulationRuntimeTest.java`
- Test: `simulation-core/src/test/java/io/casehub/platform/simulation/SimulationVerifierTest.java`
- Test: `simulation-core/src/test/java/io/casehub/platform/simulation/InvocationJournalTest.java`

**Interfaces:**
- Consumes: `DataRealism` enum from `simulation-api`
- Produces: `JournalEntry(String, String, Object, Object, Instant, DataRealism)` — replaces `boolean` 6th parameter with `DataRealism` (nullable; `null` = not simulated)
- Produces: `SimulationRuntime.recordJournal(String, String, Object, Object, DataRealism)` — replaces `boolean` 5th parameter

**Design decisions:**
- `null` DataRealism means "not simulated" (delegate path was executed). This replaces `false`.
- `allSimulated()` checks `dataRealism() != null`
- `noneSimulated()` checks `dataRealism() == null`
- `formatSequence()` displays `dataRealism=` instead of `simulated=`
- `Simulation.resolve()` uses `strategy.dataRealism()` (strategy is already resolved in that method)
- `TemporalSimulationDriver` uses `DataRealism.DOMAIN_PLAUSIBLE` (temporal profiles are authored domain-realistic sequences)

- [ ] **Step 1: Write new tests for DataRealism-based journal assertions**

In `SimulationRuntimeTest`, update the existing journal tests to use `DataRealism`:

```java
@Test
void journalReturnsOverlayJournal() {
    // ...setup...
    runtime.recordJournal(QN, "tenant-1", "input", "output", DataRealism.DOMAIN_PLAUSIBLE);

    final var journal = runtime.journal(overlay);
    assertThat(journal).hasSize(1);
    assertThat(journal.get(0).dataRealism()).isEqualTo(DataRealism.DOMAIN_PLAUSIBLE);
}

@Test
void recordJournalNoOpWhenNoOverlay() {
    // ...setup...
    runtime.recordJournal(QN, "tenant-1", "input", "output", null);
    // no exception
}
```

In `SimulationVerifierTest`, update `entry()` helper and explicit `JournalEntry` constructors:

```java
private JournalEntry entry(String qn) {
    return new JournalEntry(qn, "t1", "in", "out", Instant.now(), DataRealism.DOMAIN_PLAUSIBLE);
}
```

Replace all `new JournalEntry(..., true)` with `..., DataRealism.DOMAIN_PLAUSIBLE)` and all `..., false)` with `..., null)`.

In `InvocationJournalTest`, apply the same substitution to all `new JournalEntry(...)` calls.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl simulation-core`
Expected: compilation errors — `JournalEntry` record still has `boolean simulated`.

- [ ] **Step 3: Update `JournalEntry` record**

Replace:
```java
public record JournalEntry(
    String qualifiedName,
    String tenancyId,
    Object input,
    Object output,
    Instant timestamp,
    boolean simulated
) {}
```

With:
```java
public record JournalEntry(
    String qualifiedName,
    String tenancyId,
    Object input,
    Object output,
    Instant timestamp,
    DataRealism dataRealism
) {}
```

- [ ] **Step 4: Update `SimulationRuntime.recordJournal()`**

Change method signature from `boolean simulated` to `DataRealism dataRealism`:

```java
public void recordJournal(final String qualifiedName, final String tenancyId,
                           final Object input, final Object output, final DataRealism dataRealism) {
    final var stack = overlayStack;
    if (stack.isEmpty()) return;
    final var topOverlay = stack.get(stack.size() - 1);
    topOverlay.journal().record(new JournalEntry(qualifiedName, tenancyId, input, output,
            Instant.now(), dataRealism));
}
```

- [ ] **Step 5: Update `MethodVerification.allSimulated()` and `noneSimulated()`**

In `allSimulated()`, replace `e -> !e.simulated()` with `e -> e.dataRealism() == null`:

```java
public void allSimulated() {
    List<JournalEntry> entries = matchingEntries();
    if (entries.isEmpty()) {
        throw new AssertionError(
            "Expected \"" + qualifiedName + "\" to have simulated calls, but no calls found."
            + context());
    }
    long nonSimulated = entries.stream().filter(e -> e.dataRealism() == null).count();
    if (nonSimulated > 0) {
        throw new AssertionError(
            "Expected all calls to \"" + qualifiedName + "\" to be simulated, but "
            + nonSimulated + " of " + entries.size() + " were passed through to delegate."
            + matchingDetails());
    }
}
```

In `noneSimulated()`, replace `JournalEntry::simulated` filter with `e -> e.dataRealism() != null`:

```java
public void noneSimulated() {
    List<JournalEntry> entries = matchingEntries();
    if (entries.isEmpty()) {
        throw new AssertionError(
            "Expected \"" + qualifiedName + "\" to have non-simulated calls, but no calls found."
            + context());
    }
    long simulated = entries.stream().filter(e -> e.dataRealism() != null).count();
    if (simulated > 0) {
        throw new AssertionError(
            "Expected no calls to \"" + qualifiedName + "\" to be simulated, but "
            + simulated + " of " + entries.size() + " were simulated."
            + matchingDetails());
    }
}
```

In `matchingDetails()`, replace `simulated=` with `dataRealism=`:

```java
sb.append("  ").append(i + 1).append(". tenant=").append(e.tenancyId())
  .append(" input=").append(e.input())
  .append(" dataRealism=").append(e.dataRealism())
  .append(" at=").append(e.timestamp()).append("\n");
```

- [ ] **Step 6: Update `SimulationVerifier.formatSequence()`**

Replace `simulated=` with `dataRealism=`:

```java
sb.append("  ").append(i + 1).append(". ").append(e.qualifiedName())
  .append(" tenant=").append(e.tenancyId())
  .append(" dataRealism=").append(e.dataRealism())
  .append(" at=").append(e.timestamp()).append("\n");
```

- [ ] **Step 7: Update `Simulation.resolve()`**

Replace `true` with `strategy.dataRealism()` on line 39:

```java
public <I, O> O resolve(String qualifiedName, I input) {
    SimulationStrategy<I, O> strategy = runtime
            .<I, O>strategyFor(qualifiedName)
            .orElseThrow(() -> new SimulationConfigException(
                    "No strategy configured for '" + qualifiedName + "'"));
    O output = strategy.resolve(input);
    runtime.recordJournal(qualifiedName, null, input, output, strategy.dataRealism());
    return output;
}
```

- [ ] **Step 8: Update `TemporalSimulationDriver`**

Replace `true` with `DataRealism.DOMAIN_PLAUSIBLE` around line 148-150:

```java
if (simulation != null) {
    simulation.recordJournal(effectiveQN,
                             profile.tenancyId(), entry.label(),
                             entry.event(), DataRealism.DOMAIN_PLAUSIBLE);
}
```

- [ ] **Step 9: Run all simulation-core tests**

Run: `mvn --batch-mode test -pl simulation-core`
Expected: all tests PASS.

- [ ] **Step 10: Commit**

```
feat(#512): replace boolean simulated with DataRealism in JournalEntry and all callers
```

---

## Batch 3: Generator Layer — SimulationDecoratorProcessor

### Task 3: Update `SimulationDecoratorProcessor` to emit `strategy.get().dataRealism()` and `null`

**Files:**
- Modify: `simulation-generator/src/main/java/io/casehub/platform/simulation/generator/SimulationDecoratorProcessor.java:143-416`
- Test: `simulation-generator/src/test/java/io/casehub/platform/simulation/generator/SimulationDecoratorProcessorTest.java`

**Interfaces:**
- Consumes: `SimulationStrategy.dataRealism()` (from Task 1)
- Consumes: `SimulationRuntime.recordJournal(String, String, Object, Object, DataRealism)` (from Task 2)

**Changes to generated code:**
1. Add `import io.casehub.platform.simulation.DataRealism;` to generated decorators
2. Simulated path: change `true` → `strategy.get().dataRealism()`
3. Delegate path: change `false` → `null`

- [ ] **Step 1: Update test assertions for new generated code patterns**

In `SimulationDecoratorProcessorTest`, update:

```java
@Test
void journalRecordingForSimulatedPathUsesStrategyDataRealism() {
    // ...
    assertThat(code).contains("simResult, strategy.get().dataRealism())");
}

@Test
void journalRecordingForDelegatePathUsesNull() {
    // ...
    assertThat(code).contains("result, null)");
}
```

Also add test for DataRealism import:

```java
@Test
void generatedDecoratorImportsDataRealism() {
    // ...
    assertThat(code).contains("import io.casehub.platform.simulation.DataRealism;");
}
```

Update `voidMethodChecksStrategyThenDelegatesWithCapture` if it asserts on `true`/`false`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl simulation-generator -Dtest="SimulationDecoratorProcessorTest"`
Expected: assertion failures — generated code still uses `true`/`false`.

- [ ] **Step 3: Update `generateDecoratorSource()` to add DataRealism import**

In `generateDecoratorSource()`, after the `SimulationStrategy` import line (line 158), add:

```java
sb.append("import io.casehub.platform.simulation.DataRealism;\n");
```

- [ ] **Step 4: Update `generateSimulatedMethod()` — simulated path**

In `generateSimulatedMethod()`, change the two `recordJournal` calls in the simulated path.

For **void** simulated path (line 391), change:
```java
// old: sb.append(indent).append("        simulation.recordJournal(qualifiedName, __simTenancyId, ").append(inputExpr).append(", null, true);\n");
// new:
sb.append(indent).append("        simulation.recordJournal(qualifiedName, __simTenancyId, ").append(inputExpr).append(", null, strategy.get().dataRealism());\n");
```

For **non-void** simulated path (line 395), change:
```java
// old: sb.append(indent).append("        simulation.recordJournal(qualifiedName, __simTenancyId, ").append(inputExpr).append(", simResult, true);\n");
// new:
sb.append(indent).append("        simulation.recordJournal(qualifiedName, __simTenancyId, ").append(inputExpr).append(", simResult, strategy.get().dataRealism());\n");
```

- [ ] **Step 5: Update `generateSimulatedMethod()` — delegate path**

For **void** delegate path (line 402), change:
```java
// old: sb.append(indent).append("    simulation.recordJournal(qualifiedName, __simTenancyId, ").append(inputExpr).append(", null, false);\n");
// new:
sb.append(indent).append("    simulation.recordJournal(qualifiedName, __simTenancyId, ").append(inputExpr).append(", null, null);\n");
```

For **non-void** delegate path (line 408), change:
```java
// old: sb.append(indent).append("    simulation.recordJournal(qualifiedName, __simTenancyId, ").append(inputExpr).append(", result, false);\n");
// new:
sb.append(indent).append("    simulation.recordJournal(qualifiedName, __simTenancyId, ").append(inputExpr).append(", result, null);\n");
```

- [ ] **Step 6: Run generator tests**

Run: `mvn --batch-mode test -pl simulation-generator`
Expected: all tests PASS.

- [ ] **Step 7: Run full build to verify generated decorators compile**

Run: `mvn --batch-mode install -pl simulation-api,simulation-core,simulation-inmem,simulation-generator,simulation-config-core,simulation-config,simulation-testing,platform-simulation-core,memory-simulation-core,agent-simulation-core`
Expected: BUILD SUCCESS — generated decorators use the new `recordJournal(... DataRealism)` signature.

- [ ] **Step 8: Commit**

```
feat(#512): update SimulationDecoratorProcessor to emit DataRealism in generated decorators
```

---

## References

- [GitHub #512](https://github.com/casehubio/platform/issues/512) — focal issue
- simulation-api/src/main/java/io/casehub/platform/simulation/DataRealism.java — existing enum (5 values)
- simulation-api/src/main/java/io/casehub/platform/simulation/SimulationStrategy.java — interface to extend
- simulation-core/src/main/java/io/casehub/platform/simulation/JournalEntry.java — record to change
- simulation-core/src/main/java/io/casehub/platform/simulation/SimulationRuntime.java:141-148 — recordJournal method
- simulation-core/src/main/java/io/casehub/platform/simulation/MethodVerification.java — allSimulated/noneSimulated
- simulation-core/src/main/java/io/casehub/platform/simulation/SimulationVerifier.java:67-77 — formatSequence
- simulation-core/src/main/java/io/casehub/platform/simulation/Simulation.java:39 — resolve() caller
- simulation-core/src/main/java/io/casehub/platform/simulation/TemporalSimulationDriver.java:148-150 — temporal caller
- simulation-generator/src/main/java/io/casehub/platform/simulation/generator/SimulationDecoratorProcessor.java:331-416 — code generation
