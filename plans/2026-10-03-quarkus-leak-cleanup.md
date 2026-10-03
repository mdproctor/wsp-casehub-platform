# Quarkus Leak Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** casehubio/engine#1207 — Spring: Quarkus imports leaked into -core modules
**Issue group:** casehubio/engine#1206 (parent epic)

**Goal:** Remove all Quarkus/CDI imports from common-core, engine-support-core, and runtime-core so these modules compile without any CDI/Quarkus dependency, enabling Spring compilation.

**Architecture:** Each -core module becomes a pure-Java POJO module with constructor injection. CDI wiring stays in the Quarkus sibling module (common/, runtime/). Spring wiring is handled by the existing -spring modules (common-spring/, runtime-spring/). The transformation is mechanical: remove annotations, add constructor params, and ensure the wiring modules produce the beans.

**Tech Stack:** Java 21, Maven, Quarkus 3.32.2, Spring Boot 4.1.0

## Global Constraints

- -core modules must have ZERO imports from `jakarta.enterprise.*`, `io.quarkus.*`, or `jakarta.inject.*`
- `jakarta.annotation.PostConstruct` is allowed (part of jakarta.annotation, not CDI)
- `jakarta.ws.rs.*` annotations are allowed in engine-support-core (JAX-RS is framework-neutral)
- `@Vetoed` classes (ActorStateResource, ActorStateAggregator) are JAX-RS resources, not CDI — leave them as-is but replace inline FQN `@jakarta.enterprise.inject.Vetoed` with a non-CDI mechanism if feasible
- Event<T> → Consumer<T> constructor param (Quarkus bridges to CDI Event, Spring bridges to ApplicationEventPublisher)
- Instance<T> → List<T> or Optional<T> constructor param (Quarkus collects from Instance, Spring from ObjectProvider)
- Instance<T> used with isResolvable() guard → Optional<T> (not List<T>)
- Arc.container() → static holder pattern (init method called by framework bootstrap bean)
- @VirtualThreads ExecutorService is NOT in runtime-core (it's in the runtime/ Quarkus module only) — no action needed for this issue
- All existing tests must continue to pass after each batch
- spring-integration-test must pass after the final batch

---

## Batch 1: common-core cleanup (5 files)

### Task 1: Remove CDI annotations from common-core observation/convergence classes

**Files:**
- Modify: `common-core/src/main/java/io/casehub/engine/common/internal/observation/RuleRegistry.java`
- Modify: `common-core/src/main/java/io/casehub/engine/common/internal/observation/ContextHistoryBuffer.java`
- Modify: `common-core/src/main/java/io/casehub/engine/common/internal/observation/ObservationRegistry.java`
- Modify: `common-core/src/main/java/io/casehub/engine/common/internal/convergence/ActivityTracker.java`
- Modify: `common-core/src/main/java/io/casehub/engine/common/internal/signal/SignalRegistry.java`
- Modify: `common/src/main/java/io/casehub/engine/common/quarkus/CommonBeans.java` (add @Produces)
- Test: existing tests in `common-core/src/test/`

**Interfaces:**
- Produces: same public APIs as before — these are internal classes, no signature changes visible to consumers except constructor params

- [ ] **Step 1: Verify all tests pass before changes**

Run: `mvn -pl common-core,common -am test --batch-mode` in the engine directory.
Expected: BUILD SUCCESS

- [ ] **Step 2: Clean simple @ApplicationScoped classes (RuleRegistry, ContextHistoryBuffer, ObservationRegistry, ActivityTracker)**

For each of these 4 files:
1. Remove `import jakarta.enterprise.context.ApplicationScoped;`
2. Remove `@ApplicationScoped` annotation from class
3. Verify the class already uses constructor injection (constructor params, not @Inject fields)
4. If the class has `@Inject` on fields, convert to constructor param

Use `ide_edit_member` with `member = className` to update class declarations, and `ide_replace_member` to update constructors.

- [ ] **Step 3: Clean SignalRegistry (complex — uses Instance<T> and Event<T>)**

`SignalRegistry` has inline FQN references:
- `jakarta.enterprise.inject.Instance<ActivityTracker>` field → change to `Optional<ActivityTracker>` constructor param
- `jakarta.enterprise.event.Event<PheromoneStateChangedEvent>` field → change to `Consumer<PheromoneStateChangedEvent>` constructor param
- Replace `activityTrackerInstance.isResolvable()` guard → `activityTracker.isPresent()` 
- Replace `activityTrackerInstance.get()` → `activityTracker.get()`
- Replace `pheromoneEvent.fireAsync(...)` → `pheromoneEventConsumer.accept(...)`
- Remove `@ApplicationScoped`, `@Inject`, all `jakarta.enterprise.*` imports

- [ ] **Step 4: Add @Produces methods to CommonBeans**

Open `common/src/main/java/io/casehub/engine/common/quarkus/CommonBeans.java`. Add `@Produces @ApplicationScoped` methods for each of the 5 cleaned classes:

```java
@Produces @ApplicationScoped
RuleRegistry ruleRegistry() { return new RuleRegistry(); }

@Produces @ApplicationScoped
ContextHistoryBuffer contextHistoryBuffer() { return new ContextHistoryBuffer(); }

@Produces @ApplicationScoped
ObservationRegistry observationRegistry() { return new ObservationRegistry(); }

@Produces @ApplicationScoped
ActivityTracker activityTracker() { return new ActivityTracker(); }

@Produces @ApplicationScoped
SignalRegistry signalRegistry(
    Optional<ActivityTracker> activityTracker,
    Event<PheromoneStateChangedEvent> pheromoneEvent) {
  return new SignalRegistry(
      activityTracker,
      pheromoneEvent == null ? e -> {} : pheromoneEvent::fireAsync);
}
```

Adapt constructor params based on what each class actually needs after step 2/3.

- [ ] **Step 5: Verify tests pass**

Run: `mvn -pl common-core,common -am test --batch-mode`
Expected: BUILD SUCCESS

- [ ] **Step 6: Verify zero CDI imports in common-core**

Run: `ide_search_text` for `jakarta.enterprise` and `io.quarkus` in `common-core/src/main/**/*.java`.
Expected: 0 matches (excluding test files — test files may still use CDI for test infrastructure)

- [ ] **Step 7: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/198/engine add common-core/ common/
git -C /Users/mdproctor/claude/casehub/slots/198/engine commit -m "feat(#1207): remove CDI imports from common-core — 5 files cleaned

Remove @ApplicationScoped from 4 observation/convergence classes.
Convert SignalRegistry's Instance<T> to Optional<T> and Event<T> to Consumer<T>.
Add @Produces methods to CommonBeans for all 5 classes.

Refs casehubio/engine#1206"
```

---

## Batch 2: engine-support-core cleanup (3 files)

### Task 2: Replace Arc.container() with static holder in CasehubFlow and CasehubCallableTaskBuilder

**Files:**
- Modify: `engine-support-core/src/main/java/io/casehub/engine/flow/CasehubFlow.java`
- Modify: `engine-support-core/src/main/java/io/casehub/engine/flow/CasehubCallableTaskBuilder.java`
- Modify: `engine-support-core/src/main/java/io/casehub/engine/flow/CasehubFlowContext.java` (create if needed)
- Modify: engine-support Quarkus bootstrap bean (add init call)
- Test: existing tests

**Interfaces:**
- Produces: `CasehubFlowContext.init(CasehubDispatch, CallableDispatchRegistry)` — called once at startup by framework bean

- [ ] **Step 1: Create CasehubFlowContext static holder**

Create a new class in engine-support-core:

```java
package io.casehub.engine.flow;

public final class CasehubFlowContext {
    private static volatile CasehubDispatch dispatch;
    private static volatile CallableDispatchRegistry callableRegistry;

    private CasehubFlowContext() {}

    public static void init(CasehubDispatch dispatch, CallableDispatchRegistry registry) {
        CasehubFlowContext.dispatch = dispatch;
        CasehubFlowContext.callableRegistry = registry;
    }

    static CasehubDispatch dispatch() {
        if (dispatch == null) throw new IllegalStateException("CasehubFlowContext not initialized");
        return dispatch;
    }

    static CallableDispatchRegistry callableRegistry() {
        if (callableRegistry == null) throw new IllegalStateException("CasehubFlowContext not initialized");
        return callableRegistry;
    }
}
```

Use `ide_create_file`.

- [ ] **Step 2: Update CasehubFlow to use static holder**

Replace `Arc.container().instance(CasehubDispatch.class).get()` with `CasehubFlowContext.dispatch()`.
Remove `import io.quarkus.arc.Arc;`.

- [ ] **Step 3: Update CasehubCallableTaskBuilder to use static holder**

Replace `Arc.container().instance(CallableDispatchRegistry.class).get()` with `CasehubFlowContext.callableRegistry()`.
Remove `import io.quarkus.arc.Arc;`.

- [ ] **Step 4: Add bootstrap init call in engine-support Quarkus module**

Find or create a bootstrap bean that calls `CasehubFlowContext.init(dispatch, registry)` at startup. Look for an existing `@Observes StartupEvent` handler or create one.

- [ ] **Step 5: Run tests**

Run: `mvn -pl engine-support-core -am test --batch-mode`
Expected: BUILD SUCCESS

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/198/engine add engine-support-core/
git -C /Users/mdproctor/claude/casehub/slots/198/engine commit -m "feat(#1207): replace Arc.container() with static holder in engine-support-core

CasehubFlow and CasehubCallableTaskBuilder now use CasehubFlowContext
static holder instead of Arc.container() CDI lookup.

Refs casehubio/engine#1206"
```

### Task 3: Convert PheromoneCloudEventBridge to POJO

**Files:**
- Modify: `engine-support-core/src/main/java/io/casehub/engine/pheromone/PheromoneCloudEventBridge.java`
- Modify: engine-support Quarkus wiring (add @Produces and CDI event observer)
- Test: existing tests

**Interfaces:**
- Produces: `PheromoneCloudEventBridge(Consumer<CloudEvent>)` — constructor takes a Consumer for emitting CloudEvents

- [ ] **Step 1: Refactor PheromoneCloudEventBridge to POJO**

Current: `@ApplicationScoped` with `@Inject Event<CloudEvent>` and `@ObservesAsync PheromoneStateChangedEvent`.

Target: POJO with `Consumer<CloudEvent>` constructor param and a public `onPheromoneStateChanged(PheromoneStateChangedEvent)` method (no @ObservesAsync).

Remove all `jakarta.enterprise.*` and `jakarta.inject.*` imports.

- [ ] **Step 2: Add Quarkus wiring**

In the engine-support Quarkus wiring module, add:
1. `@Produces @ApplicationScoped` method that creates PheromoneCloudEventBridge with CDI Event bridge
2. `@ObservesAsync` handler that delegates to the bridge's `onPheromoneStateChanged()` method

- [ ] **Step 3: Verify zero CDI imports in engine-support-core**

Run `ide_search_text` for `jakarta.enterprise` and `io.quarkus` in `engine-support-core/src/main/**/*.java`.
Expected: 0 matches in non-JAX-RS files. `@Vetoed` on ActorStateResource/ActorStateAggregator is acceptable for now (JAX-RS resource, not CDI bean).

- [ ] **Step 4: Run tests and commit**

Run: `mvn -pl engine-support-core -am test --batch-mode`
Expected: BUILD SUCCESS

```bash
git -C /Users/mdproctor/claude/casehub/slots/198/engine add engine-support-core/
git -C /Users/mdproctor/claude/casehub/slots/198/engine commit -m "feat(#1207): convert PheromoneCloudEventBridge to POJO in engine-support-core

Replace @ApplicationScoped + CDI events with Consumer<T> constructor param.
Quarkus wiring bridges CDI Event<T> to the Consumer.

Refs casehubio/engine#1206"
```

---

## Batch 3: runtime-core Quarkus-specific annotations (15 files)

### Task 4: Remove @DefaultBean from InMemory* stores in runtime-core

**Files:**
- Modify: 9 files with `@DefaultBean` in runtime-core: InMemoryImprovementBlockStore, InMemoryConductorInboxRepository, InMemoryDenyPatternStore, InMemoryArtifactManifestStore, InMemoryWatchPatternStore, InMemoryGatePolicyStore, DefaultComplianceChecklistProvider, DefaultEscalationProvider, DefaultSummarizationProvider
- Modify: `runtime/src/main/java/io/casehub/engine/runtime/quarkus/RuntimeBeans.java` (add @Produces @DefaultBean)

**Interfaces:**
- Produces: same store interfaces — no API changes

- [ ] **Step 1: Find all @DefaultBean usages in runtime-core**

Run `ide_search_text` for `@DefaultBean` in `runtime-core/src/main/**/*.java`.
List every file.

- [ ] **Step 2: For each file, remove CDI annotations**

For each @DefaultBean class:
1. Remove `import io.quarkus.arc.DefaultBean;`
2. Remove `@DefaultBean` annotation
3. Also remove `@ApplicationScoped` if present
4. Convert to constructor injection if using field injection
5. Add corresponding `@Produces @DefaultBean` method in RuntimeBeans.java

- [ ] **Step 3: Remove @Unremovable from runtime-core**

Run `ide_search_text` for `@Unremovable` in `runtime-core/src/main/**/*.java`.
For each file: remove annotation and import. No other changes needed.

- [ ] **Step 4: Replace StartupEvent/@Observes with init callbacks**

Run `ide_search_text` for `StartupEvent` in `runtime-core/src/main/**/*.java`.
For each file (expect ~3: CapabilityAreaBootstrap, EvolutionBootstrap, and similar):
1. Replace `void onStartup(@Observes StartupEvent event)` with `@PostConstruct void init()` (if the method only needs to run once at startup)
2. Or extract to an init callback interface if the startup logic needs CDI-specific context
3. Remove `import io.quarkus.runtime.StartupEvent;` and `import jakarta.enterprise.event.Observes;`

- [ ] **Step 5: Run tests**

Run: `mvn -pl runtime-core,runtime -am test --batch-mode`
Expected: BUILD SUCCESS

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/198/engine add runtime-core/ runtime/
git -C /Users/mdproctor/claude/casehub/slots/198/engine commit -m "feat(#1207): remove Quarkus-specific annotations from runtime-core

Remove @DefaultBean (~9 files), @Unremovable (~4 files), and
StartupEvent/@Observes (~3 files). Add @Produces equivalents in RuntimeBeans.

Refs casehubio/engine#1206"
```

---

## Batch 4: runtime-core @ApplicationScoped removal

This is the largest batch — 68 classes in runtime-core have `@ApplicationScoped` (71 total with CDI imports). The transformation is mechanical: ~45 are no-arg classes (just remove the annotation), ~21 use constructor injection (already correct pattern), and only 2 use field injection (EvolutionBootstrap, CapabilityAreaBootstrap — need conversion to constructor injection). Split into sub-tasks by package area.

### Task 5: Remove @ApplicationScoped from runtime-core improvement/ package

**Files:**
- Modify: all `@ApplicationScoped` classes in `runtime-core/src/main/java/.../improvement/`
- Modify: `runtime/src/main/java/.../quarkus/RuntimeBeans.java` (add @Produces)

**Interfaces:**
- Produces: same class APIs — constructors may gain new params

- [ ] **Step 1: Find all @ApplicationScoped in improvement/**

Run `ide_search_text` for `@ApplicationScoped` in `runtime-core/src/main/**/improvement/**/*.java`.
List every file. Expect a subset of the 69 files in improvement/ — many will be interfaces, records, or enums without CDI annotations.

- [ ] **Step 2: For each class, remove CDI and convert to POJO**

Pattern for each file:
1. Remove `import jakarta.enterprise.context.ApplicationScoped;`
2. Remove `@ApplicationScoped`
3. If class uses `@Inject` field injection, convert to constructor injection
4. If class has `Event<T>` fields, convert to `Consumer<T>` constructor param
5. If class has `Instance<T>` fields:
   - Used with `isResolvable()` → convert to `Optional<T>`
   - Used as collection → convert to `List<T>`
6. Remove all `jakarta.enterprise.*` and `jakarta.inject.*` imports

- [ ] **Step 3: Add @Produces methods to RuntimeBeans for each cleaned class**

For each class that was self-wiring via @ApplicationScoped: check if RuntimeBeans already has a @Produces for it. If not, add one. If it already exists, verify the constructor params match the updated constructor.

- [ ] **Step 4: Run tests**

Run: `mvn -pl runtime-core,runtime -am test --batch-mode`
Expected: BUILD SUCCESS

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/198/engine add runtime-core/ runtime/
git -C /Users/mdproctor/claude/casehub/slots/198/engine commit -m "feat(#1207): remove @ApplicationScoped from runtime-core improvement/ package

Convert all CDI beans to POJOs with constructor injection.
Instance<T> → Optional<T>/List<T>, Event<T> → Consumer<T>.

Refs casehubio/engine#1206"
```

### Task 6: Remove @ApplicationScoped from remaining runtime-core packages

**Files:**
- Modify: `@ApplicationScoped` classes in runtime-core packages: `engine/`, `routing/`, `worker/`, `stigmergy/`, `observation/`, `context/`, `acl/`, `convergence/`, `diff/`, `memory/`, `config/`, `executor/`, `recovery/`, `work/`, `marshaller/`, `milestone/`, `scheduler/`, `signal/`
- Modify: `runtime/src/main/java/.../quarkus/RuntimeBeans.java`

**Interfaces:**
- Produces: same class APIs

- [ ] **Step 1: Find all remaining @ApplicationScoped in runtime-core**

Run `ide_search_text` for `@ApplicationScoped` in `runtime-core/src/main/**/*.java` (excluding improvement/).

- [ ] **Step 2: Apply same POJO conversion pattern as Task 5**

Same mechanical process. For each file: remove CDI, convert injection, update RuntimeBeans.

- [ ] **Step 3: Handle special cases**

- `NoOpOversightGateService.java` in worker/ — has `@Observes StartupEvent` but no `@ApplicationScoped`. Convert startup observer to `@PostConstruct` or init callback.
- `NoOpEvent.java` in improvement/ — implements `jakarta.enterprise.event.Event<T>` as a no-op stub. Replace with a local `Consumer<T>` no-op (`e -> {}`) and delete the file.
- `ImprovementOutcomeEventCapture.java` — has `@ObservesAsync ImprovementCaseCompleted`. Convert observer method to a public `Consumer<ImprovementCaseCompleted>` callback wired by the Quarkus module.

- [ ] **Step 4: Run tests**

Run: `mvn -pl runtime-core,runtime -am test --batch-mode`
Expected: BUILD SUCCESS

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/198/engine add runtime-core/ runtime/
git -C /Users/mdproctor/claude/casehub/slots/198/engine commit -m "feat(#1207): remove @ApplicationScoped from remaining runtime-core packages

Clean engine/, routing/, worker/, stigmergy/, observation/, and
smaller packages. Handle @VirtualThreads ExecutorService.

Refs casehubio/engine#1206"
```

---

## Batch 5: RuntimeManualConfig update + final verification

### Task 7: Update RuntimeManualConfig to handle new constructor signatures

**Files:**
- Modify: `runtime-spring/src/main/java/io/casehub/engine/runtime/spring/RuntimeManualConfig.java`
- Test: `spring-integration-test/`

**Interfaces:**
- Consumes: updated constructor signatures from Tasks 4-6 (Instance<T> → List<T>/Optional<T>)

- [ ] **Step 1: Replace notResolvable() calls with proper Spring wiring**

`RuntimeManualConfig` has 12 `notResolvable()` calls — 5 in `caseStatusChangedHandler()`, 7 in `caseContextChangedEventHandler()`.

After Tasks 4-6, the constructors that accepted `Instance<T>` now accept `List<T>` or `Optional<T>`. Update each call:
- `notResolvable()` (which returns a fake `Instance<T>`) → `List.of()` (for `List<T>` params) or `Optional.empty()` (for `Optional<T>` params)
- If Spring beans exist for the type, inject them properly via `@Bean` method params or `ObjectProvider<T>.stream().toList()`

- [ ] **Step 2: Update Event<T> params to Consumer<T>**

RuntimeBeans passes CDI `Event<T>` to constructors. The Spring equivalent is `Consumer<T>` wrapping `ApplicationEventPublisher`. Check if `SpringEventDispatcher` already handles this. If not, create `Consumer<T>` lambdas that call `applicationEventPublisher.publishEvent(event)`.

- [ ] **Step 3: Remove notResolvable() method if no longer used**

If all 12 calls are replaced, delete the `notResolvable()` helper method and its `import jakarta.enterprise.inject.Instance`.

- [ ] **Step 4: Run spring-integration-test**

Run: `mvn -pl spring-integration-test -am test --batch-mode`
Expected: BUILD SUCCESS

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/198/engine add runtime-spring/
git -C /Users/mdproctor/claude/casehub/slots/198/engine commit -m "feat(#1207): update RuntimeManualConfig for new constructor signatures

Replace 12 notResolvable() calls with proper List.of()/Optional.empty().
Instance<T> → List<T>/Optional<T>, Event<T> → Consumer<T>.

Refs casehubio/engine#1206"
```

### Task 8: Final verification — zero CDI imports in all -core modules

**Files:**
- No modifications — verification only

- [ ] **Step 1: Verify zero CDI/Quarkus imports in all -core modules**

Run `ide_search_text` for each pattern in `*-core/src/main/**/*.java`:
- `jakarta.enterprise` → expect 0 matches
- `io.quarkus` → expect 0 matches
- `jakarta.inject` → expect 0 matches (jakarta.annotation.* is OK)

Exception: `@Vetoed` on ActorStateResource/ActorStateAggregator in engine-support-core — these are JAX-RS resources. Document as known exception if not yet replaced.

- [ ] **Step 2: Full build with tests**

Run: `mvn --batch-mode install` in the engine directory.
Expected: BUILD SUCCESS for all modules including spring-integration-test.

- [ ] **Step 3: Commit verification marker (if any cleanup needed)**

If any files were missed, fix and commit. Otherwise, this step is a no-op.

---

## References

- [2026-10-03-spring-completeness-design.md] — design spec for the full epic
- [runtime/src/main/java/.../quarkus/RuntimeBeans.java] — existing Quarkus wiring (70+ @Produces methods)
- [runtime-spring/src/main/java/.../spring/RuntimeManualConfig.java] — hand-written Spring config (12 notResolvable() calls)
- [common-core/src/main/java/.../signal/SignalRegistry.java] — complex case with Instance<T> + Event<T>
- [engine-support-core/src/main/java/.../flow/CasehubFlow.java] — static utility using Arc.container()
- [engine-support-core/src/main/java/.../flow/CasehubCallableTaskBuilder.java] — ServiceLoader class using Arc.container()
- Platform Core Module Architecture table (CLAUDE.md) — Event<T> → Consumer<T>, Instance<T> → List<T> patterns
- casehubio/engine#1207 — focal issue
- casehubio/engine#1206 — parent epic
