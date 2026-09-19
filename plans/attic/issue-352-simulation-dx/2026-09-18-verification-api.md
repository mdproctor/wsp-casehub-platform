# Simulation Verification API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #332 — simulation verification API
**Issue group:** #312, #313, #314, #315, #317, #318, #319, #320, #321, #322, #323, #325, #326, #327, #328, #329, #330, #332

**Goal:** Build a Mockito-quality verification API on InvocationJournal so tests can assert which SPI methods were called, with what arguments, in what order, and for which tenant.

**Architecture:** SimulationVerifier is a stateful wrapper around InvocationJournal. MethodVerification provides a fluent filter-then-assert API. JournalEntry gains tenancyId. The generator update adds tenancyId extraction to all generated decorators.

**Tech Stack:** Pure Java (no CDI in verification classes). Jandex for generator. JUnit 5 + AssertJ for tests.

## Global Constraints

- simulation-core has no CDI dependency — SimulationVerifier and MethodVerification are POJOs
- JournalEntry is a record in simulation-core — immutable, no CDI
- Generator changes require rebuilding platform-simulation-core to regenerate decorators
- All assertion failures throw AssertionError (standard JUnit contract)

---

## Batch 1: JournalEntry tenancyId + runtime update

### Task 1: Add tenancyId to JournalEntry and update all usages

**Files:**
- Modify: `simulation-core/src/main/java/io/casehub/platform/simulation/JournalEntry.java`
- Modify: `simulation-core/src/main/java/io/casehub/platform/simulation/SimulationRuntime.java:121-128`
- Modify: `simulation-core/src/test/java/io/casehub/platform/simulation/InvocationJournalTest.java`
- Modify: `simulation-core/src/test/java/io/casehub/platform/simulation/SimulationRuntimeTest.java:288,300`
- Modify: `simulation-generator/src/main/java/io/casehub/platform/simulation/generator/SimulationDecoratorProcessor.java:247,251,258,264`
- Test: `simulation-core/src/test/java/io/casehub/platform/simulation/InvocationJournalTest.java`

**Interfaces:**
- Produces: `JournalEntry(String qualifiedName, String tenancyId, Object input, Object output, Instant timestamp, boolean simulated)` — used by Task 2 and Task 3
- Produces: `SimulationRuntime.recordJournal(String qualifiedName, String tenancyId, Object input, Object output, boolean simulated)` — called by generated decorators

- [ ] **Step 1: Update JournalEntry record**

Add `tenancyId` as the second field:

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

Use `ide_replace_text_in_file` to replace the record body.

- [ ] **Step 2: Update SimulationRuntime.recordJournal()**

Change the method signature and the JournalEntry constructor call:

```java
public void recordJournal(final String qualifiedName, final String tenancyId,
                           final Object input, final Object output, final boolean simulated) {
    final var stack = overlayStack;
    if (stack.isEmpty()) return;
    final var topOverlay = stack.get(stack.size() - 1);
    topOverlay.journal().record(new JournalEntry(qualifiedName, tenancyId, input, output,
            Instant.now(), simulated));
}
```

- [ ] **Step 3: Update InvocationJournalTest**

All `JournalEntry` constructor calls need the new `tenancyId` parameter (second position). Replace all occurrences, e.g.:

```java
// Before:
new JournalEntry("spi.method", "input", "output", Instant.now(), true)
// After:
new JournalEntry("spi.method", "tenant-1", "input", "output", Instant.now(), true)
```

Update all 8 constructor calls in the test file. Use `ide_replace_text_in_file` with each distinct pattern.

- [ ] **Step 4: Update SimulationRuntimeTest**

Update the two `recordJournal` calls at lines 288 and 300:

```java
// Before:
runtime.recordJournal(QN, "input", "output", true);
// After:
runtime.recordJournal(QN, "tenant-1", "input", "output", true);
```

- [ ] **Step 5: Update SimulationDecoratorProcessor**

The generator emits `recordJournal` calls at 4 locations (lines 247, 251, 258, 264). Each needs `tenancyIdExpr()` inserted as the second argument. The generator already injects `CurrentPrincipal` (line 165) and uses `currentPrincipal.tenancyId()` for capture (line 260).

Add a helper method to generate the tenancyId expression with a try-catch for MissingTenancyException:

```java
private String tenancyIdExpr() {
    return "(() -> { try { return currentPrincipal.tenancyId(); } catch (Exception e) { return null; } }).get()";
}
```

Then update each `recordJournal` call in the generator output. For example, change:

```java
sb.append("            simulation.recordJournal(qualifiedName, ").append(inputExpr).append(", simResult, true);\n");
```

to:

```java
sb.append("            simulation.recordJournal(qualifiedName, ").append(tenancyIdExpr()).append(", ").append(inputExpr).append(", simResult, true);\n");
```

Apply this to all 4 `recordJournal` emit sites.

- [ ] **Step 6: Run tests to verify all changes compile and pass**

Run: `mvn --batch-mode -pl simulation-core test -Dsurefire.useFile=false`

Expected: All tests pass with the updated JournalEntry constructor.

- [ ] **Step 7: Rebuild platform-simulation-core to regenerate decorators**

Run: `mvn --batch-mode -pl simulation-generator install -DskipTests && mvn --batch-mode -pl platform-simulation-core compile`

Expected: Decorators regenerated with new `recordJournal` signature.

- [ ] **Step 8: Commit**

```bash
git add simulation-core/ simulation-generator/
git commit -m "feat(#332): add tenancyId to JournalEntry, update recordJournal and generator

Refs casehubio/platform#332"
```

## Batch 2: SimulationVerifier + MethodVerification

### Task 2: SimulationVerifier with count assertions

**Files:**
- Create: `simulation-core/src/main/java/io/casehub/platform/simulation/SimulationVerifier.java`
- Create: `simulation-core/src/main/java/io/casehub/platform/simulation/MethodVerification.java`
- Create: `simulation-core/src/test/java/io/casehub/platform/simulation/SimulationVerifierTest.java`

**Interfaces:**
- Consumes: `InvocationJournal` (from simulation-core), `JournalEntry` with tenancyId (from Task 1)
- Produces: `SimulationVerifier.on(InvocationJournal)` — entry point
- Produces: `SimulationVerifier.method(String qualifiedName)` → `MethodVerification`
- Produces: `MethodVerification.wasCalled()`, `.wasCalled(int)`, `.wasNeverCalled()`, `.wasCalledAtLeast(int)`, `.wasCalledAtMost(int)`

- [ ] **Step 1: Write failing tests for count assertions**

```java
package io.casehub.platform.simulation;

import org.junit.jupiter.api.Test;
import java.time.Instant;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class SimulationVerifierTest {

    private InvocationJournal journalWith(JournalEntry... entries) {
        var journal = new InvocationJournal();
        for (var e : entries) journal.record(e);
        return journal;
    }

    private JournalEntry entry(String qn) {
        return new JournalEntry(qn, "t1", "in", "out", Instant.now(), true);
    }

    @Test
    void wasCalled_passes_when_method_called_at_least_once() {
        var journal = journalWith(entry("spi.a"));
        SimulationVerifier.on(journal).method("spi.a").wasCalled();
    }

    @Test
    void wasCalled_fails_when_method_never_called() {
        var journal = journalWith(entry("spi.b"));
        assertThatThrownBy(() ->
            SimulationVerifier.on(journal).method("spi.a").wasCalled()
        ).isInstanceOf(AssertionError.class);
    }

    @Test
    void wasCalled_exact_count_passes() {
        var journal = journalWith(entry("spi.a"), entry("spi.a"), entry("spi.a"));
        SimulationVerifier.on(journal).method("spi.a").wasCalled(3);
    }

    @Test
    void wasCalled_exact_count_fails_on_mismatch() {
        var journal = journalWith(entry("spi.a"), entry("spi.a"));
        assertThatThrownBy(() ->
            SimulationVerifier.on(journal).method("spi.a").wasCalled(3)
        ).isInstanceOf(AssertionError.class);
    }

    @Test
    void wasNeverCalled_passes_when_absent() {
        var journal = journalWith(entry("spi.b"));
        SimulationVerifier.on(journal).method("spi.a").wasNeverCalled();
    }

    @Test
    void wasNeverCalled_fails_when_present() {
        var journal = journalWith(entry("spi.a"));
        assertThatThrownBy(() ->
            SimulationVerifier.on(journal).method("spi.a").wasNeverCalled()
        ).isInstanceOf(AssertionError.class);
    }

    @Test
    void wasCalledAtLeast_passes() {
        var journal = journalWith(entry("spi.a"), entry("spi.a"), entry("spi.a"));
        SimulationVerifier.on(journal).method("spi.a").wasCalledAtLeast(2);
    }

    @Test
    void wasCalledAtMost_passes() {
        var journal = journalWith(entry("spi.a"));
        SimulationVerifier.on(journal).method("spi.a").wasCalledAtMost(3);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode -pl simulation-core test -Dtest='SimulationVerifierTest' -Dsurefire.useFile=false`

Expected: Compilation failure (SimulationVerifier doesn't exist yet)

- [ ] **Step 3: Implement SimulationVerifier and MethodVerification**

`SimulationVerifier.java`:

```java
package io.casehub.platform.simulation;

import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.stream.Collectors;

public final class SimulationVerifier {

    private final InvocationJournal journal;
    private final Set<String> verifiedMethods = new HashSet<>();

    private SimulationVerifier(InvocationJournal journal) {
        this.journal = journal;
    }

    public static SimulationVerifier on(InvocationJournal journal) {
        return new SimulationVerifier(journal);
    }

    public MethodVerification method(String qualifiedName) {
        verifiedMethods.add(qualifiedName);
        return new MethodVerification(qualifiedName, journal);
    }

    public void inOrder(String... qualifiedNames) {
        List<JournalEntry> entries = journal.entries();
        int searchFrom = 0;
        for (String qn : qualifiedNames) {
            boolean found = false;
            for (int i = searchFrom; i < entries.size(); i++) {
                if (qn.equals(entries.get(i).qualifiedName())) {
                    searchFrom = i + 1;
                    found = true;
                    break;
                }
            }
            if (!found) {
                throw new AssertionError(
                    "Expected calls in order " + String.join(" → ", qualifiedNames)
                    + " but \"" + qn + "\" was not found after position " + searchFrom
                    + ".\n\nActual call sequence:\n" + formatSequence(entries));
            }
        }
    }

    public void noUnverifiedCalls() {
        Set<String> allMethods = journal.entries().stream()
                .map(JournalEntry::qualifiedName)
                .collect(Collectors.toSet());
        Set<String> unverified = new HashSet<>(allMethods);
        unverified.removeAll(verifiedMethods);
        if (!unverified.isEmpty()) {
            StringBuilder sb = new StringBuilder("Unverified calls found in journal:\n");
            for (String qn : unverified) {
                sb.append("  - ").append(qn).append(": ")
                  .append(journal.countFor(qn)).append(" call(s)\n");
            }
            throw new AssertionError(sb.toString());
        }
    }

    static String formatSequence(List<JournalEntry> entries) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < entries.size(); i++) {
            JournalEntry e = entries.get(i);
            sb.append("  ").append(i + 1).append(". ").append(e.qualifiedName())
              .append(" tenant=").append(e.tenancyId())
              .append(" simulated=").append(e.simulated())
              .append(" at=").append(e.timestamp()).append("\n");
        }
        return sb.toString();
    }
}
```

`MethodVerification.java`:

```java
package io.casehub.platform.simulation;

import java.util.ArrayList;
import java.util.List;
import java.util.function.Predicate;

public final class MethodVerification {

    private final String qualifiedName;
    private final InvocationJournal journal;
    private final List<Predicate<JournalEntry>> filters = new ArrayList<>();

    MethodVerification(String qualifiedName, InvocationJournal journal) {
        this.qualifiedName = qualifiedName;
        this.journal = journal;
    }

    public MethodVerification forTenant(String tenancyId) {
        filters.add(e -> tenancyId.equals(e.tenancyId()));
        return this;
    }

    public MethodVerification matching(Predicate<JournalEntry> predicate) {
        filters.add(predicate);
        return this;
    }

    public void wasCalled() {
        long count = matchingCount();
        if (count == 0) {
            throw new AssertionError(
                "Expected \"" + qualifiedName + "\" to be called at least once, but was never called."
                + context());
        }
    }

    public void wasCalled(int exactCount) {
        long count = matchingCount();
        if (count != exactCount) {
            throw new AssertionError(
                "Expected \"" + qualifiedName + "\" to be called exactly " + exactCount
                + " time(s), but was called " + count + " time(s)."
                + matchingDetails());
        }
    }

    public void wasNeverCalled() {
        long count = matchingCount();
        if (count != 0) {
            throw new AssertionError(
                "Expected \"" + qualifiedName + "\" to never be called, but was called "
                + count + " time(s)."
                + matchingDetails());
        }
    }

    public void wasCalledAtLeast(int min) {
        long count = matchingCount();
        if (count < min) {
            throw new AssertionError(
                "Expected \"" + qualifiedName + "\" to be called at least " + min
                + " time(s), but was called " + count + " time(s)."
                + matchingDetails());
        }
    }

    public void wasCalledAtMost(int max) {
        long count = matchingCount();
        if (count > max) {
            throw new AssertionError(
                "Expected \"" + qualifiedName + "\" to be called at most " + max
                + " time(s), but was called " + count + " time(s)."
                + matchingDetails());
        }
    }

    public void allSimulated() {
        List<JournalEntry> entries = matchingEntries();
        if (entries.isEmpty()) {
            throw new AssertionError(
                "Expected \"" + qualifiedName + "\" to have simulated calls, but no calls found."
                + context());
        }
        long nonSimulated = entries.stream().filter(e -> !e.simulated()).count();
        if (nonSimulated > 0) {
            throw new AssertionError(
                "Expected all calls to \"" + qualifiedName + "\" to be simulated, but "
                + nonSimulated + " of " + entries.size() + " were passed through to delegate."
                + matchingDetails());
        }
    }

    public void noneSimulated() {
        List<JournalEntry> entries = matchingEntries();
        if (entries.isEmpty()) {
            throw new AssertionError(
                "Expected \"" + qualifiedName + "\" to have non-simulated calls, but no calls found."
                + context());
        }
        long simulated = entries.stream().filter(JournalEntry::simulated).count();
        if (simulated > 0) {
            throw new AssertionError(
                "Expected no calls to \"" + qualifiedName + "\" to be simulated, but "
                + simulated + " of " + entries.size() + " were simulated."
                + matchingDetails());
        }
    }

    private List<JournalEntry> matchingEntries() {
        return journal.entriesFor(qualifiedName).stream()
                .filter(e -> filters.stream().allMatch(f -> f.test(e)))
                .toList();
    }

    private long matchingCount() {
        return matchingEntries().size();
    }

    private String context() {
        List<JournalEntry> all = journal.entries();
        if (all.isEmpty()) return "\n\nJournal is empty — no calls recorded.";
        return "\n\nOther methods called:\n" + SimulationVerifier.formatSequence(all);
    }

    private String matchingDetails() {
        List<JournalEntry> entries = journal.entriesFor(qualifiedName);
        if (entries.isEmpty()) return context();
        StringBuilder sb = new StringBuilder("\n\nActual calls to \"" + qualifiedName + "\":\n");
        for (int i = 0; i < entries.size(); i++) {
            JournalEntry e = entries.get(i);
            sb.append("  ").append(i + 1).append(". tenant=").append(e.tenancyId())
              .append(" input=").append(e.input())
              .append(" simulated=").append(e.simulated())
              .append(" at=").append(e.timestamp()).append("\n");
        }
        return sb.toString();
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode -pl simulation-core test -Dtest='SimulationVerifierTest' -Dsurefire.useFile=false`

Expected: All 8 tests pass.

- [ ] **Step 5: Commit**

```bash
git add simulation-core/src/main/java/io/casehub/platform/simulation/SimulationVerifier.java \
      simulation-core/src/main/java/io/casehub/platform/simulation/MethodVerification.java \
      simulation-core/src/test/java/io/casehub/platform/simulation/SimulationVerifierTest.java
git commit -m "feat(#332): add SimulationVerifier and MethodVerification with count assertions

Refs casehubio/platform#332"
```

### Task 3: Filtering, order, exhaustive verification + documentation

**Files:**
- Modify: `simulation-core/src/test/java/io/casehub/platform/simulation/SimulationVerifierTest.java`
- Modify: `docs/guides/simulation-guide.md`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: `SimulationVerifier.on()`, `MethodVerification.forTenant()`, `.matching()`, `.allSimulated()`, `.noneSimulated()` (from Task 2)
- Consumes: `SimulationVerifier.inOrder()`, `.noUnverifiedCalls()` (from Task 2)

- [ ] **Step 1: Write failing tests for filtering, order, exhaustive, and simulation path**

Add these tests to `SimulationVerifierTest.java`:

```java
@Test
void forTenant_filters_by_tenancy() {
    var journal = journalWith(
        new JournalEntry("spi.a", "t1", "in1", "out1", Instant.now(), true),
        new JournalEntry("spi.a", "t2", "in2", "out2", Instant.now(), true),
        new JournalEntry("spi.a", "t1", "in3", "out3", Instant.now(), true)
    );
    SimulationVerifier.on(journal).method("spi.a").forTenant("t1").wasCalled(2);
    SimulationVerifier.on(journal).method("spi.a").forTenant("t2").wasCalled(1);
}

@Test
void matching_filters_by_predicate() {
    var journal = journalWith(
        new JournalEntry("spi.a", "t1", "alpha", "out", Instant.now(), true),
        new JournalEntry("spi.a", "t1", "beta", "out", Instant.now(), true),
        new JournalEntry("spi.a", "t1", "alpha", "out", Instant.now(), true)
    );
    SimulationVerifier.on(journal).method("spi.a")
        .matching(e -> "alpha".equals(e.input()))
        .wasCalled(2);
}

@Test
void chained_filters_apply_with_and_semantics() {
    var journal = journalWith(
        new JournalEntry("spi.a", "t1", "alpha", "out", Instant.now(), true),
        new JournalEntry("spi.a", "t2", "alpha", "out", Instant.now(), true),
        new JournalEntry("spi.a", "t1", "beta", "out", Instant.now(), true)
    );
    SimulationVerifier.on(journal).method("spi.a")
        .forTenant("t1")
        .matching(e -> "alpha".equals(e.input()))
        .wasCalled(1);
}

@Test
void inOrder_passes_for_correct_sequence() {
    var journal = journalWith(entry("spi.a"), entry("spi.b"), entry("spi.c"));
    SimulationVerifier.on(journal).inOrder("spi.a", "spi.b", "spi.c");
}

@Test
void inOrder_passes_with_interleaved_calls() {
    var journal = journalWith(entry("spi.a"), entry("spi.x"), entry("spi.b"));
    SimulationVerifier.on(journal).inOrder("spi.a", "spi.b");
}

@Test
void inOrder_fails_for_wrong_sequence() {
    var journal = journalWith(entry("spi.b"), entry("spi.a"));
    assertThatThrownBy(() ->
        SimulationVerifier.on(journal).inOrder("spi.a", "spi.b")
    ).isInstanceOf(AssertionError.class);
}

@Test
void noUnverifiedCalls_passes_when_all_verified() {
    var journal = journalWith(entry("spi.a"), entry("spi.b"));
    var verifier = SimulationVerifier.on(journal);
    verifier.method("spi.a").wasCalled();
    verifier.method("spi.b").wasCalled();
    verifier.noUnverifiedCalls();
}

@Test
void noUnverifiedCalls_fails_when_unverified_exist() {
    var journal = journalWith(entry("spi.a"), entry("spi.b"));
    var verifier = SimulationVerifier.on(journal);
    verifier.method("spi.a").wasCalled();
    assertThatThrownBy(verifier::noUnverifiedCalls)
        .isInstanceOf(AssertionError.class)
        .hasMessageContaining("spi.b");
}

@Test
void allSimulated_passes_when_all_simulated() {
    var journal = journalWith(
        new JournalEntry("spi.a", "t1", "in", "out", Instant.now(), true),
        new JournalEntry("spi.a", "t1", "in2", "out2", Instant.now(), true)
    );
    SimulationVerifier.on(journal).method("spi.a").allSimulated();
}

@Test
void allSimulated_fails_when_some_not_simulated() {
    var journal = journalWith(
        new JournalEntry("spi.a", "t1", "in", "out", Instant.now(), true),
        new JournalEntry("spi.a", "t1", "in2", "out2", Instant.now(), false)
    );
    assertThatThrownBy(() ->
        SimulationVerifier.on(journal).method("spi.a").allSimulated()
    ).isInstanceOf(AssertionError.class);
}

@Test
void noneSimulated_passes_when_all_passthrough() {
    var journal = journalWith(
        new JournalEntry("spi.a", "t1", "in", "out", Instant.now(), false)
    );
    SimulationVerifier.on(journal).method("spi.a").noneSimulated();
}

@Test
void error_message_includes_actual_calls() {
    var journal = journalWith(
        new JournalEntry("spi.a", "t1", "input-val", "out", Instant.now(), true)
    );
    assertThatThrownBy(() ->
        SimulationVerifier.on(journal).method("spi.a").wasCalled(5)
    ).isInstanceOf(AssertionError.class)
     .hasMessageContaining("input-val")
     .hasMessageContaining("t1");
}

@Test
void empty_journal_wasNeverCalled_passes() {
    var journal = new InvocationJournal();
    SimulationVerifier.on(journal).method("spi.a").wasNeverCalled();
}
```

- [ ] **Step 2: Run tests to verify they pass**

These tests exercise the already-implemented code from Task 2. All should pass.

Run: `mvn --batch-mode -pl simulation-core test -Dtest='SimulationVerifierTest' -Dsurefire.useFile=false`

Expected: All 22 tests pass.

- [ ] **Step 3: Run all simulation-core tests**

Run: `mvn --batch-mode -pl simulation-core test -Dsurefire.useFile=false`

Expected: All tests pass including updated InvocationJournalTest and SimulationRuntimeTest.

- [ ] **Step 4: Update simulation guide**

Add a "Verification" section after the existing "Schema-driven random generation" section in `docs/guides/simulation-guide.md`:

```markdown
#### Verification — asserting SPI interactions

After running a scenario with an overlay, verify which methods were called:

```java
var overlay = runtime.pushOverlay(config, corpus);
// ... run the code under test ...

var verifier = SimulationVerifier.on(overlay.journal());

// Count assertions
verifier.method("case-memory-store.store").wasCalled(3);
verifier.method("case-memory-store.erase").wasNeverCalled();

// Tenant-scoped
verifier.method("case-memory-store.store")
    .forTenant("hospital-a")
    .wasCalled(2);

// Argument matching
verifier.method("case-memory-store.store")
    .matching(e -> ((MemoryInput) e.input()).domain().equals("cardiology"))
    .wasCalled(1);

// Simulation path — was the strategy used or the real delegate?
verifier.method("case-memory-store.store").allSimulated();

// Order — methods called in this sequence (interleaved calls allowed)
verifier.inOrder("case-memory-store.query", "case-memory-store.store");

// Exhaustive — no unexpected SPI calls
verifier.noUnverifiedCalls();

runtime.popOverlay(overlay);
```

This replaces Mockito's `verify()` for SPI testing. The mapping:
- `verify(mock).method(args)` → `verifier.method(qn).matching(...).wasCalled()`
- `verify(mock, times(N))` → `verifier.method(qn).wasCalled(N)`
- `verify(mock, never())` → `verifier.method(qn).wasNeverCalled()`
- `verifyNoMoreInteractions(mock)` → `verifier.noUnverifiedCalls()`
```

- [ ] **Step 5: Update CLAUDE.md simulation-core description**

Add verification API to the simulation-core module description — mention `SimulationVerifier` and `MethodVerification`.

- [ ] **Step 6: Commit**

```bash
git add simulation-core/src/test/ docs/guides/simulation-guide.md CLAUDE.md
git commit -m "feat(#332): add filtering, order, exhaustive verification + documentation

Closes casehubio/platform#332"
```

## References

- [2026-09-18-verification-api-design.md] — design spec this plan implements
- [simulation-core/src/main/java/.../JournalEntry.java] — current 5-field record
- [simulation-core/src/main/java/.../InvocationJournal.java] — existing journal API
- [simulation-core/src/main/java/.../SimulationRuntime.java:121-128] — recordJournal method
- [simulation-generator/src/.../SimulationDecoratorProcessor.java:247-267] — generator emit sites
- [D79-D85] — design decisions for verification API
- [GitHub #332] — feat: simulation verification API
