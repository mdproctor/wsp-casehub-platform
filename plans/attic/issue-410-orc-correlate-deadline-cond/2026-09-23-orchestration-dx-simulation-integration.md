# Orchestration DX + Simulation Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #391 — DX refinements for runtime orchestration
**Issue group:** #391, #405, #411, #412, #413

**Goal:** Add DX refinements (shorthand forms, prefix rewriting, compute blocks, expression defaults) to yaml-core and platform-api, then integrate simulation with orchestration primitives (blocking state machine, shared-state primitives, spawn/childScope, simulation bridges).

**Architecture:** yaml-core stays zero-dependency. New orchestration primitives (BlockingOrcStateMachine, OrcCounter, OrcGauge, OrcFlag, OrcAccumulator, OrcMap, PrimitiveFactory, SpawnedTask) join the existing `io.casehub.yaml.core.orchestration` package. Platform-api gains ExpressionContext enum. simulation-config gains CDI bridges (SpeedMultiplier producer, CorpusVariableSource, FeedBinding).

**Tech Stack:** Java 21+ (virtual threads), java.util.concurrent (LongAdder, AtomicReference, AtomicBoolean, DoubleAccumulator, ConcurrentHashMap, ReentrantLock, Condition), Quarkus CDI (@Produces), JUnit 5, Maven

## Global Constraints

- yaml-core: zero external dependencies. Pure Java + java.util.concurrent only.
- All orchestration primitives MUST use j.u.c locks or lock-free primitives. NEVER `synchronized` (D13 — virtual thread pinning).
- SpeedMultiplier contract: 1.0 = real-time (1:1 wall-clock mapping).
- ForEachDirective `parse(Object)` is the canonical pattern for shorthand sealed types.
- ComputeBlock engine is non-optional — resolved at parse time.
- ScenarioScope same-name-same-instance contract via `ConcurrentHashMap.computeIfAbsent`.
- Build: `mvn --batch-mode install`

---

## Batch 1: Expression & DX Foundation (#391)

### Task 1: ExpressionContext enum + registry defaults (D4)

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/expression/ExpressionContext.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/expression/ExpressionEngineRegistry.java`
- Modify: `expression/src/main/java/io/casehub/platform/expression/DefaultExpressionEngineRegistry.java`
- Test: `platform-api/src/test/java/io/casehub/platform/api/expression/ExpressionContextTest.java`
- Test: `expression/src/test/java/io/casehub/platform/expression/DefaultExpressionEngineRegistryTest.java`

**Interfaces:**
- Produces: `ExpressionContext` enum (CONDITION, TRANSFORM, FILTER), `ExpressionEngineRegistry.registerDefault(ExpressionContext, String)`, `ExpressionEngineRegistry.resolveDefault(ExpressionContext)`

- [ ] **Step 1: Write ExpressionContext enum with test**

```java
public enum ExpressionContext {
    CONDITION,
    TRANSFORM,
    FILTER
}
```

Test: verify all three values exist, valueOf works.

- [ ] **Step 2: Add default methods to ExpressionEngineRegistry interface**

Add to ExpressionEngineRegistry:
```java
default void registerDefault(ExpressionContext context, String engineType) {
    // no-op default for backward compat
}

default String resolveDefault(ExpressionContext context) {
    return null;
}
```

- [ ] **Step 3: Implement in DefaultExpressionEngineRegistry**

Use `EnumMap<ExpressionContext, String>` for defaults storage. Override both methods.

- [ ] **Step 4: Write tests for default registration and resolution**

Test: register CONDITION→"mvel", TRANSFORM→"jq", resolve returns correct engine. Test: resolveDefault returns null for unregistered context. Test: registerDefault overwrites previous registration.

- [ ] **Step 5: Register platform defaults at startup**

In expression module's startup bean (or @Startup), register: CONDITION→"mvel", TRANSFORM→"jq", FILTER→"jq".

- [ ] **Step 6: Run `mvn --batch-mode install -pl platform-api,expression` and commit**

### Task 2: Shorthand directive types (D1)

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/LoopDirective.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/RetryDirective.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/orchestration/LoopDirectiveTest.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/orchestration/RetryDirectiveTest.java`

**Interfaces:**
- Consumes: ForEachDirective pattern (sealed type + `parse(Object)`)
- Produces: `LoopDirective.parse(Object)`, `RetryDirective.parse(Object)`

- [ ] **Step 1: Write LoopDirective tests**

Test `parse(5)` → `LoopDirective.Count(5)`. Test `parse(Map.of("count", 5))` → `LoopDirective.Count(5)`. Test `parse(Map.of("count", 5, "until", "${done}"))` → `LoopDirective.CountUntil(5, "${done}")`. Test `parse(null)` throws.

- [ ] **Step 2: Implement LoopDirective**

```java
public sealed interface LoopDirective {
    static LoopDirective parse(Object value) { ... }

    record Count(int count) implements LoopDirective {}
    record CountUntil(int count, String until) implements LoopDirective {}
    record Until(String until) implements LoopDirective {}
}
```

- [ ] **Step 3: Write RetryDirective tests**

Test `parse(3)` → `RetryDirective.Simple(3)`. Test `parse(Map.of("max", 3, "backoff", "exponential", "delay", "1s"))` → full form. Test parse of map with only `max`.

- [ ] **Step 4: Implement RetryDirective**

```java
public sealed interface RetryDirective {
    static RetryDirective parse(Object value) { ... }

    record Simple(int max) implements RetryDirective {}
    record Full(int max, String backoff, Duration delay) implements RetryDirective {}
}
```

Uses DurationParser for delay string → Duration.

- [ ] **Step 5: Run `mvn --batch-mode install -pl yaml-core` and commit**

### Task 3: VariablePrefixRewriter (D2)

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/resolver/VariablePrefixRewriter.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/resolver/VariablePrefixRewriterTest.java`

**Interfaces:**
- Consumes: VariableResolver prefix sources (registered scope names)
- Produces: `VariablePrefixRewriter.rewrite(String input, String defaultPrefix, Set<String> knownPrefixes, Set<String> forEachVars) → String`

- [ ] **Step 1: Write tests for bare reference rewriting**

Test: `rewrite("${regime}", "var", known, forEach)` → `"${var.regime}"`. Test: `rewrite("${result.x}", "var", Set.of("result"), forEach)` → `"${result.x}"` (known prefix, not rewritten). Test: `rewrite("${instrument.symbol}", "var", known, Set.of("instrument"))` → `"${each.instrument.symbol}"` (forEach var). Test: multiple references in one string.

- [ ] **Step 2: Implement VariablePrefixRewriter**

Static utility. Regex-based `$\{([^}]+)\}` scan. For each reference:
1. Extract the first dotted segment
2. If it matches a known prefix → skip
3. If it matches a forEach variable → prepend `each.`
4. Otherwise → prepend defaultPrefix + `.`

- [ ] **Step 3: Test edge cases**

Default value syntax: `${name:-default}` — rewrite the name part, preserve default. Nested references. No-prefix reference with no default prefix (identity — returns unchanged). Empty string input.

- [ ] **Step 4: Run tests and commit**

### Task 4: ComputeBlock record (D3)

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/ComputeBlock.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/orchestration/ComputeBlockTest.java`

**Interfaces:**
- Consumes: D4 ExpressionContext (conceptually — engine resolved at parse time by consumer)
- Produces: `ComputeBlock(String engine, String expression)` record

- [ ] **Step 1: Write tests**

Test: constructor with engine + expression. Test: null engine throws. Test: null expression throws. Test: `parse(Map)` factory — `Map.of("engine", "jq", "expression", "...")` → ComputeBlock. Test: `parse(Map)` with only `expression` + supplied default engine.

- [ ] **Step 2: Implement ComputeBlock**

```java
public record ComputeBlock(String engine, String expression) {
    public ComputeBlock {
        Objects.requireNonNull(engine, "engine must not be null");
        Objects.requireNonNull(expression, "expression must not be null");
    }

    public static ComputeBlock parse(Map<String, Object> map, String defaultEngine) {
        String engine = (String) map.getOrDefault("engine", defaultEngine);
        String expression = (String) map.get("expression");
        if (engine == null) throw new IllegalArgumentException("engine required");
        return new ComputeBlock(engine, expression);
    }
}
```

- [ ] **Step 3: Run `mvn --batch-mode install -pl yaml-core,platform-api,expression` and commit**

Commit message: `feat(#391): add DX refinements — shorthand directives, prefix rewriter, compute blocks, expression defaults`

---

## Batch 2: Orchestration Primitives (#405)

### Task 5: SpeedMultiplier.identity() + BlockingOrcStateMachine (D5)

**Files:**
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/runtime/SpeedMultiplier.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/BlockingOrcStateMachine.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultBlockingOrcStateMachine.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/orchestration/BlockingOrcStateMachineTest.java`

**Interfaces:**
- Consumes: `OrcStateMachine<S>` interface, `SpeedMultiplier` SPI
- Produces: `BlockingOrcStateMachine<S>` extension interface, `DefaultBlockingOrcStateMachine<S>`, `SpeedMultiplier.identity()`

- [ ] **Step 1: Add SpeedMultiplier.identity()**

```java
static SpeedMultiplier identity() { return () -> 1.0; }
```

- [ ] **Step 2: Write BlockingOrcStateMachine interface**

```java
public interface BlockingOrcStateMachine<S extends Enum<S>> extends OrcStateMachine<S> {
    void awaitState(S target) throws InterruptedException;
    boolean awaitState(S target, Duration timeout) throws InterruptedException;
    void awaitTransition(S from, S to) throws InterruptedException;
}
```

- [ ] **Step 3: Write tests for blocking await**

Test: `awaitState` blocks until another thread transitions to target state. Test: `awaitState` with timeout returns false on timeout. Test: SpeedMultiplier-aware timeout (2x speed → half real wait). Test: `awaitTransition` blocks until specific from→to transition occurs. Test: interrupt throws InterruptedException.

- [ ] **Step 4: Implement DefaultBlockingOrcStateMachine**

Extends `DefaultOrcStateMachine<S>`, implements `BlockingOrcStateMachine<S>`. Adds `ReentrantLock` + `Condition`. Override `transition()` to `signalAll()` after state change. `awaitState()` loops on condition with predicate `currentState() == target`. Timeout version adjusts duration by `speedMultiplier.currentSpeed()`.

- [ ] **Step 5: Run tests and commit**

### Task 6: Shared-state primitives (D11)

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcCounter.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultOrcCounter.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcGauge.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultOrcGauge.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcFlag.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultOrcFlag.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcAccumulator.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultOrcAccumulator.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcMap.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultOrcMap.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/orchestration/SharedStatePrimitivesTest.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/orchestration/ConcurrentSharedStateTest.java`

**Interfaces:**
- Produces: `OrcCounter`, `OrcGauge<T>`, `OrcFlag`, `OrcAccumulator`, `OrcMap<K,V>`

- [ ] **Step 1: Write OrcCounter interface + tests**

Interface: `increment()`, `decrement()`, `add(long)`, `get()`, `reset()`. Test: increment/decrement/get. Test: concurrent increments from multiple threads converge.

- [ ] **Step 2: Implement DefaultOrcCounter**

Wraps `LongAdder`. All methods delegate. `get()` calls `sum()`.

- [ ] **Step 3: Write OrcGauge + OrcFlag interfaces and tests**

OrcGauge: `set(T)`, `get()`, `compareAndSet(T, T)`. OrcFlag: `set()`, `clear()`, `toggle()`, `get()`. Test: basic operations + concurrent toggle convergence.

- [ ] **Step 4: Implement DefaultOrcGauge and DefaultOrcFlag**

OrcGauge wraps `AtomicReference<T>`. OrcFlag wraps `AtomicBoolean`.

- [ ] **Step 5: Write OrcAccumulator interface + test + impl**

Interface: `accumulate(double)`, `get()`, `reset()`. Constructor takes `DoubleBinaryOperator` + identity. DefaultOrcAccumulator wraps `DoubleAccumulator`. Test: sum accumulator, max accumulator.

- [ ] **Step 6: Write OrcMap interface + tests**

Interface: `get(K)`, `put(K,V)`, `putIfAbsent(K,V)`, `computeIfAbsent(K, Function)`, `merge(K,V, BiFunction)`, `remove(K)`, `containsKey(K)`, `size()`. Test: basic CRUD. Test: `computeIfAbsent` atomicity (concurrent calls, factory invoked once). Test: `merge` with accumulating BiFunction.

- [ ] **Step 7: Implement DefaultOrcMap**

Wraps `ConcurrentHashMap<K,V>`. All methods delegate directly.

- [ ] **Step 8: Write concurrent safety tests**

Test all five primitives under concurrent access from virtual threads. Use `ExecutorService.newVirtualThreadPerTaskExecutor()`, 100 threads, 1000 operations each. Assert final state is consistent.

- [ ] **Step 9: Run `mvn --batch-mode install -pl yaml-core` and commit**

Commit: `feat(#405): add shared-state orchestration primitives — counter, gauge, flag, accumulator, map`

---

## Batch 3: ScenarioScope Architecture (#405)

### Task 7: PrimitiveFactory extraction + lifecycle (D9, D12)

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/PrimitiveFactory.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultPrimitiveFactory.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/ScenarioScope.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultScenarioScope.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/orchestration/PrimitiveFactoryTest.java`

**Interfaces:**
- Consumes: D5 BlockingOrcStateMachine, D11 all shared-state primitives
- Produces: `PrimitiveFactory` interface, `DefaultPrimitiveFactory`, ScenarioScope with `counter()`, `gauge()`, `flag()`, `accumulator()`, `map()` factory methods

- [ ] **Step 1: Write PrimitiveFactory interface**

```java
public interface PrimitiveFactory {
    <T> OrcChannel<T> createChannel(String name, int capacity);
    OrcSignal createSignal(String name);
    <S extends Enum<S>> BlockingOrcStateMachine<S> createStateMachine(
        String name, Class<S> stateType, S initialState);
    OrcLatch createLatch(String name, int count);
    OrcSemaphore createSemaphore(String name, int permits);
    OrcCounter createCounter(String name);
    <T> OrcGauge<T> createGauge(String name);
    OrcFlag createFlag(String name);
    OrcAccumulator createAccumulator(String name,
        DoubleBinaryOperator op, double identity);
    <K, V> OrcMap<K, V> createMap(String name);
}
```

- [ ] **Step 2: Write DefaultPrimitiveFactory**

Stateless — creates new Default* instances for each call. ScenarioScope handles caching via computeIfAbsent.

- [ ] **Step 3: Refactor DefaultScenarioScope to use PrimitiveFactory**

Replace direct constructor calls with factory delegation. Add `counter()`, `gauge()`, `flag()`, `accumulator()`, `map()` factory methods to ScenarioScope interface. All use `computeIfAbsent` caching pattern. Constructor takes optional `PrimitiveFactory` (defaults to `DefaultPrimitiveFactory`).

- [ ] **Step 4: Extend close() for new primitive types (D12)**

`close()` must also: reset counters, clear flags, close map entries if closeable. Existing close behavior (channels, latches, signals, semaphores) preserved.

- [ ] **Step 5: Write tests — same-name-same-instance contract**

Test: `scope.counter("x") == scope.counter("x")`. Test: `scope.gauge("y") == scope.gauge("y")`. Test: PrimitiveFactory.createCounter called exactly once per name.

- [ ] **Step 6: Write test — SimulatedPrimitiveFactory substitution**

Test: construct ScenarioScope with custom PrimitiveFactory that returns pre-loaded channel. Verify channel contains expected messages.

- [ ] **Step 7: Run tests and commit**

### Task 8: spawn/childScope/SpawnedTask (D10)

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/SpawnedTask.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/ScenarioScope.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultScenarioScope.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/orchestration/SpawnTest.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/orchestration/ChildScopeTest.java`

**Interfaces:**
- Consumes: D9 PrimitiveFactory, D12 lifecycle close
- Produces: `SpawnedTask` (isDone, isFailed, exception, join, join(Duration)), `ScenarioScope.spawn(String, Runnable)`, `ScenarioScope.childScope(String)`

- [ ] **Step 1: Write SpawnedTask interface**

```java
public interface SpawnedTask {
    String name();
    boolean isDone();
    boolean isFailed();
    Throwable exception();
    void join() throws InterruptedException;
    boolean join(Duration timeout) throws InterruptedException;
}
```

- [ ] **Step 2: Write tests for spawn lifecycle**

Test: spawn starts virtual thread, isDone() becomes true on completion. Test: spawn with failure, isFailed() returns true, exception() returns the cause. Test: join() blocks until task completes. Test: join(Duration) returns false on timeout.

- [ ] **Step 3: Implement spawn in DefaultScenarioScope**

Internal `DefaultSpawnedTask` wraps virtual `Thread`. `Thread.ofVirtual().name(name).start(task)`. Track spawned tasks in `CopyOnWriteArrayList<DefaultSpawnedTask>`. `join()` delegates to `Thread.join()`.

- [ ] **Step 4: Write tests for childScope**

Test: childScope inherits parent's primitive namespace (counter created in parent visible in child). Test: closing parent closes all children (child's spawned tasks interrupted). Test: nested childScope (grandchild closed when parent closes).

- [ ] **Step 5: Implement childScope in DefaultScenarioScope**

`childScope(String name)` creates a new `DefaultScenarioScope` sharing the parent's primitives map + PrimitiveFactory, with its own spawned-tasks list. Register child in parent's children list. `close()` recursively closes children first.

- [ ] **Step 6: Write cancellation contract tests**

Test: `close()` interrupts all spawned virtual threads. Test: spawned task blocked on `channel.receive()` gets InterruptedException on close. Test: join timeout (5s default) logs stuck tasks. Test: SpeedMultiplier-aware timeout on join.

- [ ] **Step 7: Implement cancellation in close()**

On close: (1) interrupt all spawned threads, (2) join with timeout, (3) log stuck tasks, (4) close child scopes recursively, (5) close primitives.

- [ ] **Step 8: Run full yaml-core test suite and commit**

Commit: `feat(#405): add PrimitiveFactory, spawn/childScope, shared-state lifecycle to ScenarioScope`

---

## Batch 4: Simulation Bridges (#405)

### Task 9: SpeedMultiplier CDI producer (D6)

**Files:**
- Modify: `simulation-config/src/main/java/io/casehub/platform/simulation/quarkus/SimulationConfigBeans.java`
- Test: `simulation-config/src/test/java/io/casehub/platform/simulation/quarkus/SpeedMultiplierProducerTest.java`

**Interfaces:**
- Consumes: D5 SpeedMultiplier.identity(), SimulationRuntime.globalSpeed()
- Produces: CDI-managed `SpeedMultiplier` bean

- [ ] **Step 1: Write test**

Test: producer returns `SpeedMultiplier` whose `currentSpeed()` delegates to `SimulationRuntime.globalSpeed()`. Mock SimulationRuntime, set globalSpeed to 10.0, assert `speedMultiplier.currentSpeed() == 10.0`.

- [ ] **Step 2: Add @Produces method**

```java
@Produces
@DefaultBean
SpeedMultiplier speedMultiplier(SimulationRuntime runtime) {
    return runtime::globalSpeed;
}
```

- [ ] **Step 3: Run tests and commit**

### Task 10: CorpusVariableSource (D7)

**Files:**
- Create: `simulation-config/src/main/java/io/casehub/platform/simulation/config/CorpusVariableSource.java`
- Test: `simulation-config/src/test/java/io/casehub/platform/simulation/config/CorpusVariableSourceTest.java`

**Interfaces:**
- Consumes: `SimulationCorpus` SPI, `ObjectVariableSource` interface
- Produces: `CorpusVariableSource implements ObjectVariableSource`

- [ ] **Step 1: Write tests**

Test: `resolve("trades")` returns list of input objects from corpus keyed by "trades". Test: `resolve("trades[0]")` returns first element. Test: `resolve("nonexistent")` returns null. Test: drill-down `resolve("trades[0].symbol")` returns the field value.

- [ ] **Step 2: Implement CorpusVariableSource**

```java
public class CorpusVariableSource implements ObjectVariableSource {
    private final SimulationCorpus<?, ?> corpus;

    public CorpusVariableSource(SimulationCorpus<?, ?> corpus) {
        this.corpus = corpus;
    }

    @Override
    public Object resolve(String name) {
        // Parse name for array index: "trades[0]" → qualifiedName="trades", index=0
        // Return corpus.list(qualifiedName).stream()
        //     .map(InvocationRecord::input).toList()
        // or indexed element
    }
}
```

- [ ] **Step 3: Register as VariableResolver scope in SimulationConfigBeans**

Add `withObjectScope("corpus", corpusVariableSource)` wiring.

- [ ] **Step 4: Run tests and commit**

### Task 11: FeedBinding + feed: config (D8)

**Files:**
- Create: `simulation-config/src/main/java/io/casehub/platform/simulation/config/FeedBinding.java`
- Modify: simulation config YAML parsing (TemporalProfileConfig or equivalent)
- Test: `simulation-config/src/test/java/io/casehub/platform/simulation/config/FeedBindingTest.java`

**Interfaces:**
- Consumes: `TemporalEventSink<E>`, `OrcChannel<T>`, ScenarioScope, TemporalProfileConfig
- Produces: `FeedBinding` record, `FeedBinding.activate(ScenarioScope)` method

- [ ] **Step 1: Write FeedBinding record with tests**

```java
public record FeedBinding(String profileName, String channelName, Class<?> eventType) {
    public <E> TemporalEventSink<E> activate(ScenarioScope scope) {
        OrcChannel<E> channel = scope.channel(channelName);
        return event -> channel.send(event);
    }
}
```

Test: activate creates a sink that sends events to the named channel. Test: events sent via sink appear in channel.receive().

- [ ] **Step 2: Parse `feed:` from simulation YAML config**

In the existing YAML parsing (TemporalProfileConfig or YamlSimulationConfig), read optional `feed:` property from temporal profile definitions. Create FeedBinding records.

- [ ] **Step 3: Write integration test**

Test: full flow — YAML config with `feed: trades-channel`, activate FeedBinding with ScenarioScope, verify events from temporal profile arrive in channel.

- [ ] **Step 4: Run `mvn --batch-mode install -pl simulation-config` and commit**

Commit: `feat(#405): add simulation bridges — SpeedMultiplier producer, CorpusVariableSource, FeedBinding`

---

## Final: Full build verification

- [ ] **Run full project build**

```bash
mvn --batch-mode install
```

All modules must pass. No test regressions.

---

## References

- [2026-09-23-orchestration-dx-simulation-integration-design.md] — design spec
- ForEachDirective.java — yaml-core shorthand sealed type pattern
- VariableResolver.java — yaml-core variable resolution (withScope, withObjectScope)
- OrcStateMachine.java / DefaultOrcStateMachine.java — yaml-core state machine
- ScenarioScope.java / DefaultScenarioScope.java — yaml-core scope management
- SpeedMultiplier.java — yaml-core runtime SPI
- ExpressionEngineRegistry.java — platform-api expression registry
- SimulationConfigBeans.java — simulation-config CDI wiring
- GraphCaseMemoryStore — platform-api extension interface pattern (for D5)
- GitHub #391, #405, #411, #412, #413 — tracked issues
- GitHub #410 — downstream (correlate, deadline propagation)
