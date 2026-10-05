# Scenario State Machine DSL Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #491 — feat: PlaybookStateMachineExecutor — YAML state machine runtime for incident lifecycle playbooks
**Issue group:** #491

**Goal:** Enable state-machine-driven scenarios to be declared in YAML and compiled to existing orchestration primitives.

**Architecture:** Generalize `OrcStateMachine` by removing the `<S extends Enum<S>>` bound, add strategy-based state matching via `StateMatchingStrategy<S>`. Build a YAML DSL parser that extracts state metadata entries from step lists, validates the state machine graph, and a compiler that wires `OrcStateMachine`, `StructuralStepEvaluator`, `DeadlineContext`, and `EventRouter` together.

**Tech Stack:** Java 21+, yaml-core (zero-dep), yaml-step-runtime (Quarkus CDI), Jackson YAML, JUnit 5

## Global Constraints

- yaml-core must remain zero-dependency — no Quarkus, no JPA, no casehubio imports. Pure Java only.
- yaml-plugin-api must remain zero-dependency, J2CL-safe.
- All orchestration primitives MUST use j.u.c locks or lock-free atomics — never `synchronized` (virtual thread pinning).
- `OrcStateMachine` generalization must not break existing enum callers — all existing tests must pass unchanged.
- Thread-safe via `java.util.concurrent`.

---

## Batch 1: Generalize OrcStateMachine — remove enum bound

After this batch: all orchestration interfaces accept generic `<S>` instead of `<S extends Enum<S>>`. Existing enum-based tests continue to pass. New string-state tests demonstrate the generalization works.

### Task 1: Remove enum bound from OrcStateMachine interface hierarchy

**Files:**
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcStateMachine.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/BlockingOrcStateMachine.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/EventRouter.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/ScenarioScope.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/PrimitiveFactory.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultOrcStateMachine.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultBlockingOrcStateMachine.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultScenarioScope.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultPrimitiveFactory.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/orchestration/OrcStateMachineTest.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/orchestration/BlockingOrcStateMachineTest.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/orchestration/ConcurrentStateMachineTest.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/orchestration/EventRouterTest.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/orchestration/PrimitiveFactoryTest.java`

**Interfaces:**
- Produces: `OrcStateMachine<S>` (no enum bound), `BlockingOrcStateMachine<S>` (no enum bound), all downstream types updated

- [ ] **Step 1: Run existing tests to establish baseline**

Run: `mvn --batch-mode test -pl yaml-core -Dtest="OrcStateMachineTest,BlockingOrcStateMachineTest,ConcurrentStateMachineTest,EventRouterTest,PrimitiveFactoryTest,ScenarioScopeTest" -DfailIfNoTests=false`
Expected: All pass.

- [ ] **Step 2: Remove `extends Enum<S>` from all interfaces**

Change in each file — remove the bound:
- `OrcStateMachine.java`: `<S extends Enum<S>>` → `<S>`
- `BlockingOrcStateMachine.java`: `<S extends Enum<S>>` → `<S>`
- `EventRouter.java`: `<S extends Enum<S>>` → `<S>`
- `ScenarioScope.java`: `stateMachine` method — `<S extends Enum<S>>` → `<S>`, remove `Class<S> stateType` parameter (not needed without enum)
- `PrimitiveFactory.java`: `createStateMachine` method — `<S extends Enum<S>>` → `<S>`, remove `Class<S> stateType` parameter

- [ ] **Step 3: Update DefaultOrcStateMachine — remove enum dependencies**

The `Builder` currently uses `EnumSet.noneOf(stateType)` for `terminalStates`. Replace with `new HashSet<>()`. Remove `Class<S> stateType` field from Builder.

The `builder()` static factory currently takes `Class<S> stateType`. Change to:
```java
public static <S> Builder<S> builder(String name, S initialState) {
    return new Builder<>(name, initialState);
}
```

Keep a backward-compatible overload for enum callers:
```java
public static <S extends Enum<S>> Builder<S> builder(String name, Class<S> stateType, S initialState) {
    return new Builder<>(name, initialState);
}
```

The `transition()` method uses `AtomicReference.compareAndSet` which uses `==`. For enums this works (singletons). For strings, caller must use interned strings. For objects, this is a known limitation — the pattern strategy (D1) addresses it later. For now, document that string callers should intern their states.

EventRouter's `fire()` calls `current.name()` — this only works for enums. Change to `String.valueOf(current)` which calls `toString()` and works for any type. For enums, `toString()` returns the same as `name()` by default.

- [ ] **Step 4: Update DefaultBlockingOrcStateMachine**

Remove `<S extends Enum<S>>` bound → `<S>`. The `awaitState` uses `currentState() != target` — reference equality. For string states, this only works with interned strings. Document this constraint. The `awaitTransition` uses `lastFrom == from && lastTo == to` — same constraint.

- [ ] **Step 5: Update DefaultScenarioScope and DefaultPrimitiveFactory**

`ScenarioScope.stateMachine()` — remove `Class<S> stateType` param, keep backward-compat overload.
`PrimitiveFactory.createStateMachine()` — same treatment.
`DefaultPrimitiveFactory.createStateMachine()` — adapt to new signature.
`DefaultScenarioScope.stateMachine()` — adapt to new signature.

- [ ] **Step 6: Fix compiler errors in test files**

The test files use `builder("name", StateEnum.class, INITIAL)`. These continue to work via the backward-compatible overload. Run `ide_diagnostics` to find any remaining issues.

- [ ] **Step 7: Run all existing tests — verify no regressions**

Run: `mvn --batch-mode test -pl yaml-core -Dtest="OrcStateMachineTest,BlockingOrcStateMachineTest,ConcurrentStateMachineTest,EventRouterTest,PrimitiveFactoryTest,ScenarioScopeTest" -DfailIfNoTests=false`
Expected: All pass — zero regressions.

- [ ] **Step 8: Write string-state test to verify generalization**

Create test in `OrcStateMachineTest` that uses `String` states with the new builder:

```java
@Test
void stringStates_transitionSucceeds() {
    String PENDING = "PENDING".intern();
    String APPROVED = "APPROVED".intern();
    String REJECTED = "REJECTED".intern();
    
    var sm = DefaultOrcStateMachine.<String>builder("order", PENDING)
            .transition(PENDING, APPROVED)
            .transition(PENDING, REJECTED)
            .terminal(APPROVED, REJECTED)
            .build();
    
    assertThat(sm.currentState()).isEqualTo(PENDING);
    assertThat(sm.transition(PENDING, APPROVED)).isTrue();
    assertThat(sm.currentState()).isEqualTo(APPROVED);
}
```

Run: `mvn --batch-mode test -pl yaml-core -Dtest="OrcStateMachineTest#stringStates_transitionSucceeds"`
Expected: PASS

- [ ] **Step 9: Write string-state EventRouter test**

```java
@Test
void stringStates_eventRouterFires() {
    String PENDING = "PENDING".intern();
    String APPROVED = "APPROVED".intern();
    
    var sm = DefaultOrcStateMachine.<String>builder("order", PENDING)
            .on("approve", PENDING, APPROVED)
            .terminal(APPROVED)
            .build();
    
    var router = sm.builder("order", PENDING)
            .on("approve", PENDING, APPROVED)
            .terminal(APPROVED)
            .buildRouter(sm);
    
    assertThat(router.fire("approve")).isTrue();
    assertThat(sm.currentState()).isEqualTo(APPROVED);
}
```

Run: `mvn --batch-mode test -pl yaml-core -Dtest="EventRouterTest"`
Expected: PASS

- [ ] **Step 10: Commit**

```bash
git add yaml-core/
git commit -m "feat(#491): generalize OrcStateMachine — remove enum bound, support generic state types

Remove <S extends Enum<S>> bound from OrcStateMachine, BlockingOrcStateMachine,
EventRouter, ScenarioScope, PrimitiveFactory. Backward-compatible overloads
preserve existing enum API. String states verified via new tests.

Refs #491"
```

---

## Batch 2: YAML scenario format — parser and validator

After this batch: YAML scenario definitions can be parsed into a validated `StateMachineDefinition` model. No execution yet — just parsing and validation.

### Task 2: Define ScenarioDefinition model types

**Files:**
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/scenario/ScenarioDefinition.java`
- Create: `../../../../yaml-step-runtime/src/main/java/io/casehub/yaml/step/statemachine/StateDefinition.java`
- Create: `../../../../yaml-step-runtime/src/main/java/io/casehub/yaml/step/statemachine/EventTransition.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/scenario/ScenarioDefinitionTest.java`

**Interfaces:**
- Produces: `StateMachineDefinition` (record: name, initialState, states Map<String, StateDefinition>), `StateDefinition` (record: name, steps List<Map<String,Object>>, next String, onFailure String, deadline String, events Map<String, EventTransition>, isTerminal boolean), `EventTransition` (sealed: Simple (target), Guarded (target, when), MatchBased (List<MatchCase>))

- [ ] **Step 1: Write test for ScenarioDefinition construction and validation**

```java
@Test
void validLinearScenario_constructsSuccessfully() {
    var states = new LinkedHashMap<String, StateDefinition>();
    states.put("DETECTED", new StateDefinition("DETECTED", 
        List.of(Map.of("notify.team", Map.of("channel", "ops"))),
        "TRIAGING", "ESCALATED", null, Map.of(), false));
    states.put("TRIAGING", new StateDefinition("TRIAGING",
        List.of(Map.of("classify", Map.of())),
        "RESOLVED", null, null, Map.of(), false));
    states.put("RESOLVED", new StateDefinition("RESOLVED",
        List.of(), null, null, null, Map.of(), true));
    states.put("ESCALATED", new StateDefinition("ESCALATED",
        List.of(), null, null, null, Map.of(), true));
    
    var def = new ScenarioDefinition("incident", states);
    assertThat(def.initialState()).isEqualTo("DETECTED");
    assertThat(def.states()).hasSize(4);
}
```

- [ ] **Step 2: Implement ScenarioDefinition, StateDefinition, EventTransition**

Records with validation in compact constructors. `StateMachineDefinition` derives `initialState` from the first entry in the ordered map.

- [ ] **Step 3: Run test to verify**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest="ScenarioDefinitionTest"`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add yaml-step-runtime/
git commit -m "feat(#491): add ScenarioDefinition model types — StateDefinition, EventTransition

Records representing the parsed YAML scenario model. ScenarioDefinition
holds ordered states, derives initial state from first entry.

Refs #491"
```

### Task 3: Implement YAML scenario parser with two-phase metadata extraction

**Files:**
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/scenario/ScenarioParser.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/scenario/ScenarioParserTest.java`

**Interfaces:**
- Consumes: `StateMachineDefinition`, `StateDefinition`, `EventTransition` from Task 2
- Produces: `ScenarioParser.parse(Map<String, Object> yamlRoot) → ScenarioDefinition`

- [ ] **Step 1: Write test for parsing linear scenario YAML**

```java
@Test
void parseLinearScenario_extractsMetadataAndSteps() {
    // Build a Map<String, Object> matching the YAML structure:
    // states:
    //   DETECTED:
    //     - next: TRIAGING
    //     - on-failure: ESCALATED
    //     - notify.team: { channel: ops }
    //   TRIAGING:
    //     - next: RESOLVED
    //     - classify: {}
    //   RESOLVED: terminal
    //   ESCALATED: terminal
    
    var detected = List.of(
        Map.of("next", "TRIAGING"),
        Map.of("on-failure", "ESCALATED"),
        Map.of("notify.team", Map.of("channel", "ops"))
    );
    var triaging = List.of(
        Map.of("next", "RESOLVED"),
        Map.of("classify", Map.of())
    );
    
    var states = new LinkedHashMap<String, Object>();
    states.put("DETECTED", detected);
    states.put("TRIAGING", triaging);
    states.put("RESOLVED", "terminal");
    states.put("ESCALATED", "terminal");
    
    var root = Map.<String, Object>of("states", states);
    
    ScenarioDefinition def = ScenarioParser.parse(root);
    
    assertThat(def.initialState()).isEqualTo("DETECTED");
    assertThat(def.states().get("DETECTED").next()).isEqualTo("TRIAGING");
    assertThat(def.states().get("DETECTED").onFailure()).isEqualTo("ESCALATED");
    assertThat(def.states().get("DETECTED").steps()).hasSize(1); // metadata extracted
    assertThat(def.states().get("RESOLVED").isTerminal()).isTrue();
}
```

- [ ] **Step 2: Write test for parsing event-driven state**

```java
@Test
void parseEventDrivenState_extractsOnEvents() {
    var pending = List.of(
        Map.of("on", Map.of("approve", "APPROVED", "reject", "REJECTED")),
        Map.of("validate.order", Map.of())
    );
    
    var states = new LinkedHashMap<String, Object>();
    states.put("PENDING", pending);
    states.put("APPROVED", "terminal");
    states.put("REJECTED", "terminal");
    
    var root = Map.<String, Object>of("states", states);
    ScenarioDefinition def = ScenarioParser.parse(root);
    
    assertThat(def.states().get("PENDING").events()).containsKey("approve");
    assertThat(def.states().get("PENDING").events().get("approve"))
        .isInstanceOf(EventTransition.Simple.class);
}
```

- [ ] **Step 3: Write test for parsing guarded event transitions**

```java
@Test
void parseGuardedEvent_extractsToAndWhen() {
    var approved = List.of(
        Map.of("on", Map.of(
            "ship", Map.of("to", "SHIPPED", "when", "${inventory.available}"),
            "cancel", "CANCELLED"
        ))
    );
    
    var states = new LinkedHashMap<String, Object>();
    states.put("APPROVED", approved);
    states.put("SHIPPED", "terminal");
    states.put("CANCELLED", "terminal");
    
    var root = Map.<String, Object>of("states", states);
    ScenarioDefinition def = ScenarioParser.parse(root);
    
    var shipEvent = def.states().get("APPROVED").events().get("ship");
    assertThat(shipEvent).isInstanceOf(EventTransition.Guarded.class);
    assertThat(((EventTransition.Guarded) shipEvent).target()).isEqualTo("SHIPPED");
    assertThat(((EventTransition.Guarded) shipEvent).when()).isEqualTo("${inventory.available}");
}
```

- [ ] **Step 4: Write test for parsing deadline with expression**

```java
@Test
void parseDeadlineExpression_preservesRawString() {
    var detected = List.of(
        Map.of("next", "RESOLVED"),
        Map.of("deadline", "${config.sla.timeout} -> ESCALATED"),
        Map.of("notify", Map.of())
    );
    
    var states = new LinkedHashMap<String, Object>();
    states.put("DETECTED", detected);
    states.put("RESOLVED", "terminal");
    states.put("ESCALATED", "terminal");
    
    var root = Map.<String, Object>of("states", states);
    ScenarioDefinition def = ScenarioParser.parse(root);
    
    assertThat(def.states().get("DETECTED").deadline())
        .isEqualTo("${config.sla.timeout} -> ESCALATED");
}
```

- [ ] **Step 5: Implement ScenarioParser.parse()**

Two-phase extraction:
1. For each state entry: if value is string "terminal" → terminal state, no steps. If value is a List → iterate entries, extract reserved metadata keys (`next`, `on-failure`, `deadline`, `on`, `terminal`), collect remaining entries as steps.
2. Parse event transitions using scalar-or-object polymorphism: string → Simple, map with `to`/`when` → Guarded, list → MatchBased.

Reserved metadata keys for extraction: `next`, `on-failure`, `deadline`, `on`, `terminal`.

- [ ] **Step 6: Run all parser tests**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest="ScenarioParserTest"`
Expected: All pass.

- [ ] **Step 7: Commit**

```bash
git add yaml-step-runtime/
git commit -m "feat(#491): YAML scenario parser — two-phase metadata extraction

Parses YAML state definitions with metadata entries (next, on-failure,
deadline, on, terminal) extracted in phase 1, remaining entries passed
as steps. Supports scalar-or-object polymorphism for event transitions.

Refs #491"
```

### Task 4: Implement scenario validator

**Files:**
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/scenario/ScenarioValidator.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/scenario/ScenarioValidatorTest.java`

**Interfaces:**
- Consumes: `StateMachineDefinition` from Task 2
- Produces: `ScenarioValidator.validate(ScenarioDefinition) → List<String>` (empty = valid, otherwise list of error messages)

- [ ] **Step 1: Write failing tests for each validation rule**

```java
@Test
void referencedStateDoesNotExist_returnsError() {
    // state with next: NONEXISTENT
}

@Test
void noTerminalState_returnsError() { ... }

@Test
void initialStateIsTerminal_returnsError() { ... }

@Test
void deadEndState_neitherNextNorOnNorTerminal_returnsError() { ... }

@Test
void unreachableState_returnsError() { ... }

@Test
void duplicateStateNames_handledByLinkedHashMap() { ... }

@Test
void nextAndOnMutuallyExclusive_returnsError() { ... }

@Test
void transitionFromTerminalState_returnsError() { ... }

@Test
void validScenario_returnsEmptyList() { ... }
```

- [ ] **Step 2: Implement ScenarioValidator**

Graph walk from initial state, collecting reachable states. Check each validation rule from the spec's "Parse-time validation" section.

- [ ] **Step 3: Run tests**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest="ScenarioValidatorTest"`
Expected: All pass.

- [ ] **Step 4: Commit**

```bash
git add yaml-step-runtime/
git commit -m "feat(#491): scenario validator — reachability, terminal states, mutual exclusivity

Validates: referenced states exist, initial state not terminal, at least
one terminal, no dead-end states, all reachable, next/on mutually exclusive,
no transitions from terminal states.

Refs #491"
```

---

## Batch 3: DSL compiler — wire YAML to existing primitives

After this batch: a parsed and validated YAML scenario can be compiled and executed using the existing orchestration primitives. Full lifecycle: enter initial state → execute steps → transition → deadline enforcement → error handling.

### Task 5: Implement ScenarioCompiler — build state machine and wire handlers

**Files:**
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/scenario/ScenarioCompiler.java`
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/scenario/CompiledScenario.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/scenario/ScenarioCompilerTest.java`

**Interfaces:**
- Consumes: `StateMachineDefinition` from Task 2, `ScenarioScope` (yaml-core), `StructuralStepEvaluator` (yaml-step-runtime), `StepWalker` (yaml-step-runtime), `StepRunner` (yaml-step-runtime), `VariableResolver` (yaml-core), `PluginRegistry` (yaml-plugin-api), `DeadlineContext` (yaml-step-runtime)
- Produces: `ScenarioCompiler.compile(ScenarioDefinition, ScenarioScope, PluginRegistry, VariableResolver, StepRunner) → CompiledScenario`, `CompiledScenario.execute() → Result`

- [ ] **Step 1: Write test for linear scenario execution**

```java
@Test
void linearScenario_executesAllStatesInOrder() {
    // Build a 3-state linear scenario: A → B → C (terminal)
    // Each state has one step that records execution
    // Verify all steps executed in order
    var executionLog = new CopyOnWriteArrayList<String>();
    
    StepRunner runner = (step, resolver) -> {
        String action = ((ResolvedStep.PluginStep) step).definition().name();
        executionLog.add(action);
        return Result.of(Map.of());
    };
    
    // Parse scenario YAML, compile, execute
    // ...
    
    assertThat(executionLog).containsExactly("step-a", "step-b");
    // C is terminal with no steps
}
```

- [ ] **Step 2: Write test for on-failure transition**

```java
@Test
void stepFailure_transitionsToOnFailureState() {
    // State A has on-failure: ERROR, step that fails
    // State ERROR is terminal with a notification step
    // Verify: A's step fails → transitions to ERROR → ERROR's step executes
}
```

- [ ] **Step 3: Write test for deadline transition**

```java
@Test
void deadlineExpires_transitionsToDeadlineTarget() {
    // State A has deadline: 100ms -> TIMEOUT, step that sleeps 500ms
    // State TIMEOUT is terminal
    // Verify: deadline fires → transitions to TIMEOUT
}
```

- [ ] **Step 4: Write test for event-driven state**

```java
@Test
void eventDrivenState_waitsForEventThenTransitions() {
    // State A has on: { go: B }, entry step
    // State B is terminal
    // Verify: A's steps execute, then state machine waits
    // Fire "go" event → transitions to B
}
```

- [ ] **Step 5: Implement CompiledScenario record**

```java
public record CompiledScenario(
        OrcStateMachine<String> stateMachine,
        EventRouter<String> eventRouter,
        ScenarioScope scope,
        ScenarioDefinition definition,
        StructuralStepEvaluator evaluator,
        VariableResolver resolver,
        StepRunner runner) {
    
    public Result execute() { ... }
}
```

The `execute()` method:
1. Enter initial state
2. Run onEnter handler (step evaluation)
3. If completion-driven (`next:`) and steps succeed → transition to next state, loop
4. If event-driven (`on:`) → return control (caller fires events externally)
5. If `on-failure` and steps fail → transition to failure state, continue from there
6. Terminal state reached → return final Result
7. Deadline wiring: `scope.withDeadline(duration, () -> sm.transition(current, deadlineTarget))`

- [ ] **Step 6: Implement ScenarioCompiler.compile()**

1. Intern all state names (`String.intern()`)
2. Build `DefaultOrcStateMachine<String>` via builder — register all transitions (from next, on-failure, deadline targets, event targets)
3. Mark terminal states
4. For each non-terminal state: resolve steps via `StepWalker.resolve()`, register `onEnter` handler that:
   a. Sets up deadline if present (resolve expression via VariableResolver, parse duration)
   b. Evaluates steps via `StructuralStepEvaluator.evaluate()`
   c. On success + has `next:` → `transition(current, next)`
   d. On failure + has `on-failure:` → `transition(current, onFailure)`
5. For event-driven states: build EventRouter mappings
6. Return `CompiledStateMachine`

- [ ] **Step 7: Run all compiler tests**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest="ScenarioCompilerTest"`
Expected: All pass.

- [ ] **Step 8: Commit**

```bash
git add yaml-step-runtime/
git commit -m "feat(#491): ScenarioCompiler — wire YAML scenarios to orchestration primitives

Compiles ScenarioDefinition to OrcStateMachine + onEnter handlers +
deadline wiring + error transitions + EventRouter. CompiledScenario
executes the full lifecycle using existing StructuralStepEvaluator.

Refs #491"
```

---

## Batch 4: Integration tests + full build verification

After this batch: end-to-end tests cover all use cases from the spec. Full Maven build passes.

### Task 6: Integration tests for all spec use cases

**Files:**
- Create: `../../../../yaml-step-runtime/src/test/java/io/casehub/yaml/step/statemachine/StateMachineIntegrationTest.java`

**Interfaces:**
- Consumes: `StateMachineParser`, `StateMachineValidator`, `StateMachineCompiler`, `CompiledStateMachine` from Tasks 2-5

- [ ] **Step 1: Write integration test — linear incident lifecycle**

Parse the full YAML from the spec's "Linear incident lifecycle" use case. Compile and execute. Verify all states visited in order, results stored in StepResultStore.

- [ ] **Step 2: Write integration test — event-driven order processing**

Parse the "Event-driven order processing" use case. Compile. Verify entry steps execute, then state waits. Fire events externally. Verify transitions.

- [ ] **Step 3: Write integration test — conditional branching**

Parse the "Conditional branching on completion" use case. Use step results to drive `if/then/else` branching. Verify correct branch taken.

- [ ] **Step 4: Write integration test — mixed scenario**

Parse the "Mixed" use case. Verify completion-driven, event-driven, deadline, and error paths all work together.

- [ ] **Step 5: Write integration test — expression-resolvable deadline**

Use a VariableResolver that provides config values. Verify deadline resolves from expression.

- [ ] **Step 6: Write integration test — resumability via StepResultStore**

Pre-populate StepResultStore with completed steps. Compile and execute. Verify state machine reconstructs at the correct state.

- [ ] **Step 7: Run full build**

Run: `mvn --batch-mode install`
Expected: All modules build and all tests pass.

- [ ] **Step 8: Commit**

```bash
git add yaml-step-runtime/
git commit -m "test(#491): integration tests — all spec use cases verified

Linear lifecycle, event-driven, conditional branching, mixed scenario,
expression deadlines, and StepResultStore resumability all covered.

Refs #491"
```

---

## References

- [2026-10-01-scenario-state-machine-dsl-design.md] — design spec this plan implements
- `OrcStateMachine.java:3` — current interface with `<S extends Enum<S>>` bound
- `DefaultOrcStateMachine.java:12-218` — builder, CAS transitions, EventRouter integration
- `BlockingOrcStateMachine.java:6` — await/awaitAnyState
- `EventRouter.java:8-36` — MatchPattern-based event dispatch
- `ScenarioScope.java:3-48` — factory for orchestration primitives
- `DefaultScenarioScope.java:11-309` — primitive creation and lifecycle
- `StructuralStepEvaluator.java:21-419` — step evaluation with decorator chain
- `StepWalker.java:13-386` — YAML step resolution
- `DecoratorChain.java:451-500` — existing `transition` decorator
- `DeadlineContext.java:6-28` — deadline tracking
- `PrimitiveFactory.java:6-36` — primitive creation SPI
- `DefaultPrimitiveFactory.java:8` — default implementation
- casehubio/platform#491 — focal issue
- casehubio/casehub-pages#509 — TypeScript alignment issue
