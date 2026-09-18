# Simulation Verification API — Design Spec

**Issue:** casehubio/platform#332
**Branch:** issue-294-simulation-service
**Date:** 2026-09-18

---

## Problem

The simulation framework replaces Mockito's `when/thenReturn` for SPI
testing (corpus + strategy). But Mockito's `verify()` — asserting that
methods were called with specific arguments — has no equivalent. The
`InvocationJournal` records all intercepted calls during an overlay
scenario but provides only raw data access (`entries()`, `entriesFor()`,
`countFor()`). Tests must manually filter and assert on journal entries,
which is verbose and error-prone.

## Scope

**In scope:**
- `JournalEntry` update: add `tenancyId` field
- `SimulationRuntime.recordJournal()` update: accept tenancyId
- `SimulationDecoratorProcessor` update: inject `CurrentPrincipal`, pass tenancyId
- `SimulationVerifier` — stateful verification entry point
- `MethodVerification` — per-method fluent assertion builder
- Order verification (`inOrder`)
- Exhaustive verification (`noUnverifiedCalls`)
- Mockito-quality error messages

**Out of scope:**
- Migration bridge (`SimulationMigrator`) — deferred (D84)
- Per-SPI typed verifiers in simulation-testing — future extension
- Capture-mode verification — journal is the data source (D79)

## Design

### 1. JournalEntry update (simulation-core)

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

### 2. SimulationRuntime.recordJournal update

```java
public void recordJournal(String qualifiedName, String tenancyId,
                           Object input, Object output, boolean simulated)
```

The existing 4-arg signature is removed (pre-release, no compat concern).

### 3. Generator update (simulation-generator)

`SimulationDecoratorProcessor` updates:
- Generated decorators inject `CurrentPrincipal` alongside `SimulationRuntime`
- Each intercepted method calls `simulation.recordJournal(qualifiedName,
  currentPrincipal.tenancyId(), input, output, simulated)`
- `tenancyId()` may throw `MissingTenancyException` — catch and pass
  `null` (some test environments have no tenant context)

### 4. SimulationVerifier (simulation-core)

Stateful entry point that tracks which qualified names have been verified:

```java
public final class SimulationVerifier {

    public static SimulationVerifier on(InvocationJournal journal) { ... }

    public MethodVerification method(String qualifiedName) { ... }

    public void inOrder(String... qualifiedNames) { ... }

    public void noUnverifiedCalls() { ... }
}
```

`on()` factory takes an `InvocationJournal`. Each `method()` call
registers the qualified name as "verified" for `noUnverifiedCalls()`.

### 5. MethodVerification (simulation-core)

Fluent builder for per-method assertions. Filters are chainable; terminal
methods assert:

```java
public final class MethodVerification {

    // Filters (chainable, return this)
    public MethodVerification forTenant(String tenancyId) { ... }
    public MethodVerification matching(Predicate<JournalEntry> predicate) { ... }

    // Terminal assertions (throw AssertionError on failure)
    public void wasCalled() { ... }           // >= 1
    public void wasCalled(int exactCount) { ... }
    public void wasNeverCalled() { ... }      // == 0
    public void wasCalledAtLeast(int min) { ... }
    public void wasCalledAtMost(int max) { ... }

    // Simulation path assertions
    public void allSimulated() { ... }
    public void noneSimulated() { ... }
}
```

**Filter semantics:** `forTenant()` and `matching()` are additive — each
narrows the set of journal entries that the terminal assertion operates on.
Multiple `matching()` calls chain with AND semantics.

**`forTenant()`** is syntactic sugar for
`matching(e -> tenancyId.equals(e.tenancyId()))` (D85).

### 6. Order verification

`inOrder(String... qualifiedNames)` asserts that the journal contains
entries for the given qualified names in the specified order. The entries
need not be adjacent — other calls may occur between them. The assertion
checks that for each consecutive pair (A, B), there exists an entry for A
with a timestamp before some entry for B.

### 7. Exhaustive verification

`noUnverifiedCalls()` checks that every distinct qualified name in the
journal has been referenced by at least one `method()` call. If any
unverified methods exist, the error message lists them with their call
counts:

```
Unverified calls found in journal:
  - notification-store.store: 2 calls
  - endpoint-registry.register: 1 call
```

### 8. Error messages

All assertion failures include:
- What was expected
- What actually happened
- Full call listing for the relevant qualified name
- Summary of all other methods called (context)

Example:
```
Expected "case-memory-store.store" to be called exactly 3 times,
but was called 1 time.

Matching calls:
  1. tenant=hospital-a, input=MemoryInput[domain=cardiology, ...],
     output=Memory[...], simulated=true, at=2026-09-18T20:30:00Z

Other methods called:
  - case-memory-store.query: 2 calls
  - notification-store.store: 1 call
```

## Deliverables

1. **JournalEntry** — add `tenancyId` field
2. **SimulationRuntime** — update `recordJournal` signature
3. **SimulationDecoratorProcessor** — inject CurrentPrincipal, pass tenancyId
4. **SimulationVerifier** — stateful verification entry point
5. **MethodVerification** — fluent per-method assertion builder
6. **Update existing tests** — JournalEntry constructor calls, recordJournal calls
7. **SimulationVerifier unit tests** — per-assertion, filtering, order, exhaustive
8. **Simulation guide update** — verification section
9. **CLAUDE.md update** — simulation-core module description

## Testing

- **Count assertions:** wasCalled, wasCalled(n), wasNeverCalled, wasCalledAtLeast, wasCalledAtMost
- **Filtering:** forTenant, matching, chained filters
- **Simulation path:** allSimulated, noneSimulated, mixed
- **Order:** inOrder with adjacent and non-adjacent entries
- **Exhaustive:** noUnverifiedCalls with verified and unverified methods
- **Error messages:** verify message content on assertion failure
- **Edge cases:** empty journal, no matching entries, single entry

## Trade-offs

- **Untyped input/output** (D81) — journal stores `Object`, requiring casts
  in `matching()` predicates. Acceptable because the journal is inherently
  heterogeneous. Typed wrappers are a future extension.

- **CurrentPrincipal injection in decorators** (D80) — adds one CDI dependency
  to every generated decorator. Negligible overhead; the decorator already
  injects SimulationRuntime.

- **Stateful verifier** (D82) — mutable tracking of verified methods. Required
  for `noUnverifiedCalls()`. The alternative (stateless) cannot support
  exhaustive verification.

## References

- InvocationJournal.java — existing journal API (entries, entriesFor, countFor)
- JournalEntry.java — current 5-field record
- SimulationOverlay.java — owns journal per overlay
- SimulationRuntime.java — recordJournal method (line 121)
- SimulationDecoratorProcessor.java — generated decorator code template
- CurrentPrincipal — platform-api identity SPI
- Mockito verify() — conceptual model for the API
- D79-D85 — design decisions for this issue
