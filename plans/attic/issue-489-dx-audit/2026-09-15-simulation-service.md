# Simulation Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #294 — epic: SPI simulation strategies
**Issue group:** #312 (simulation-api), #313 (simulation-core), #314 (corpus storage), #315 (AgentProvider adapter)

**Goal:** Build a generic, domain-agnostic simulation framework — core contracts, four strategy implementations, in-memory corpus, annotation processor for decorator generation, and a concrete AgentProvider backend adapter (Path B).

**Architecture:** A `SimulationStrategy<I, O>` contract resolves responses for any SPI without a real impl. `SimulationCorpus<I, O>` stores input/output pairs for strategies to draw from. A `SimulationRuntime` bean wires strategies to SPIs by config. Two integration paths: Path A (generated `@Decorator` via annotation processor for simple SPIs) and Path B (backend integration for routed SPIs like AgentProvider). The annotation processor (`SimulationDecoratorProcessor`) mirrors `CallbackDecoratorProcessor` — scans Jandex for `@SimulationEligible`, generates `@Decorator` classes.

**Tech Stack:** Java 21, Maven, Quarkus CDI (ArC), SmallRye Config, Jandex, Mutiny (for AgentProvider reactive types), compile-testing (APT tests)

## Global Constraints

- `simulation-api` is **zero-dependency** — pure Java only, same rules as `platform-api`
- `simulation-core` depends only on `simulation-api` — no CDI, no Quarkus
- All strategy implementations are constructor-injected POJOs — no CDI annotations
- NoOp implementations across the codebase remain **untouched** — simulation wraps, never modifies
- Parent artifact: `io.casehub:casehub-platform-parent:0.2-SNAPSHOT`
- Package prefix: `io.casehub.platform.simulation`
- Config prefix: `casehub.simulation.<spi-name>.<method-name>.*`
- Agent adapter package: `io.casehub.platform.agent.simulation`
- Existing backend modules use `-core` suffix (e.g. `agent-openai-core`)

---

## Batch 1: simulation-api — Core Contracts

### Task 1: Create simulation-api module with SPI contracts

**Files:**
- Create: `simulation-api/pom.xml`
- Create: `simulation-api/src/main/java/io/casehub/platform/simulation/SimulationStrategy.java`
- Create: `simulation-api/src/main/java/io/casehub/platform/simulation/KeyExtractor.java`
- Create: `simulation-api/src/main/java/io/casehub/platform/simulation/SimulationCorpus.java`
- Create: `simulation-api/src/main/java/io/casehub/platform/simulation/InvocationRecord.java`
- Create: `simulation-api/src/main/java/io/casehub/platform/simulation/DataRealism.java`
- Create: `simulation-api/src/main/java/io/casehub/platform/simulation/ExhaustionPolicy.java`
- Create: `simulation-api/src/main/java/io/casehub/platform/simulation/SimulationEligible.java`
- Create: `simulation-api/src/main/java/io/casehub/platform/simulation/SimulationExhaustedException.java`
- Create: `simulation-api/src/main/java/io/casehub/platform/simulation/SimulationKeyNotFoundException.java`
- Create: `simulation-api/src/main/java/io/casehub/platform/simulation/SimulationConfigException.java`
- Create: `simulation-api/src/main/java/io/casehub/platform/simulation/NoOpSimulationCorpus.java`
- Modify: `pom.xml` (parent — add `<module>simulation-api</module>`)
- Test: `simulation-api/src/test/java/io/casehub/platform/simulation/InvocationRecordTest.java`

**Interfaces:**
- Produces: `SimulationStrategy<I, O>` (resolve, canResolve), `SimulationCorpus<I, O>` (lookupByKey, lookupByIndex, list, listByTenant, record, seed, clear, size — all take `qualifiedName`), `KeyExtractor<I>` (extract), `InvocationRecord<I, O>` (tenancyId, key, input, output, recordedAt), `@SimulationEligible` annotation, `ExhaustionPolicy` enum, `DataRealism` enum, exception types

- [ ] **Step 1: Create module pom.xml and register in parent**

Create `simulation-api/pom.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>
    <parent>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-platform-parent</artifactId>
        <version>0.2-SNAPSHOT</version>
    </parent>
    <artifactId>casehub-platform-simulation-api</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform :: Simulation API</name>
    <description>Zero-dependency simulation contracts — SimulationStrategy, SimulationCorpus,
        InvocationRecord, @SimulationEligible. Pure Java only.</description>
    <dependencies>
        <dependency>
            <groupId>org.junit.jupiter</groupId>
            <artifactId>junit-jupiter</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.assertj</groupId>
            <artifactId>assertj-core</artifactId>
            <scope>test</scope>
        </dependency>
    </dependencies>
</project>
```

Add `<module>simulation-api</module>` to parent `pom.xml` after `platform-api` (line ~14).

Run: `mvn --batch-mode -pl simulation-api compile`
Expected: BUILD SUCCESS (empty module compiles)

- [ ] **Step 2: Write SimulationStrategy, KeyExtractor, enums, exceptions, and InvocationRecord**

Create all SPI types per the spec. Key contracts:

```java
// SimulationStrategy.java
package io.casehub.platform.simulation;
public interface SimulationStrategy<I, O> {
    O resolve(I input);
    boolean canResolve(I input);
}

// KeyExtractor.java
package io.casehub.platform.simulation;
@FunctionalInterface
public interface KeyExtractor<I> {
    String extract(I input);
}

// InvocationRecord.java
package io.casehub.platform.simulation;
import java.time.Instant;
public record InvocationRecord<I, O>(String tenancyId, String key, I input, O output, Instant recordedAt) {}

// DataRealism.java
package io.casehub.platform.simulation;
public enum DataRealism { GARBAGE, PLACEHOLDER, STRUCTURALLY_VALID, DOMAIN_PLAUSIBLE, RECORDED_REAL }

// ExhaustionPolicy.java
package io.casehub.platform.simulation;
public enum ExhaustionPolicy { WRAP, THROW }

// SimulationEligible.java
package io.casehub.platform.simulation;
import java.lang.annotation.*;
@Target(ElementType.TYPE)
@Retention(RetentionPolicy.RUNTIME)
public @interface SimulationEligible {
    String name() default "";
}

// SimulationExhaustedException.java — extends RuntimeException(String message)
// SimulationKeyNotFoundException.java — extends RuntimeException(String key) with getKey()
// SimulationConfigException.java — extends RuntimeException(String message)
```

- [ ] **Step 3: Write SimulationCorpus SPI and NoOpSimulationCorpus**

```java
// SimulationCorpus.java
package io.casehub.platform.simulation;
import java.util.*;
public interface SimulationCorpus<I, O> {
    Optional<O> lookupByKey(String qualifiedName, String key);
    Optional<O> lookupByIndex(String qualifiedName, int index);
    List<InvocationRecord<I, O>> list(String qualifiedName);
    List<InvocationRecord<I, O>> listByTenant(String qualifiedName, String tenancyId);
    void record(String qualifiedName, String tenancyId, I input, O output);
    void record(String qualifiedName, String tenancyId, String key, I input, O output);
    void seed(String qualifiedName, List<InvocationRecord<I, O>> records);
    void clear(String qualifiedName);
    int size(String qualifiedName);
}

// NoOpSimulationCorpus.java — returns empty for all lookups, discards records
package io.casehub.platform.simulation;
import java.util.*;
public class NoOpSimulationCorpus<I, O> implements SimulationCorpus<I, O> {
    @Override public Optional<O> lookupByKey(String qn, String key) { return Optional.empty(); }
    @Override public Optional<O> lookupByIndex(String qn, int index) { return Optional.empty(); }
    @Override public List<InvocationRecord<I, O>> list(String qn) { return List.of(); }
    @Override public List<InvocationRecord<I, O>> listByTenant(String qn, String tid) { return List.of(); }
    @Override public void record(String qn, String tid, I in, O out) {}
    @Override public void record(String qn, String tid, String key, I in, O out) {}
    @Override public void seed(String qn, List<InvocationRecord<I, O>> records) {}
    @Override public void clear(String qn) {}
    @Override public int size(String qn) { return 0; }
}
```

- [ ] **Step 4: Write unit test for InvocationRecord and NoOpSimulationCorpus**

```java
// InvocationRecordTest.java
@Test void recordPreservesFields() {
    var record = new InvocationRecord<>("tenant-1", "k1", "input", "output", Instant.now());
    assertThat(record.tenancyId()).isEqualTo("tenant-1");
    assertThat(record.key()).isEqualTo("k1");
}

@Test void noOpCorpusReturnsEmpty() {
    var corpus = new NoOpSimulationCorpus<>();
    assertThat(corpus.lookupByKey("spi.method", "any")).isEmpty();
    assertThat(corpus.size("spi.method")).isZero();
    corpus.record("spi.method", "t1", "in", "out"); // no-op, no error
}
```

Run: `mvn --batch-mode -pl simulation-api test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add simulation-api/ pom.xml
git commit -m "feat(#312): simulation-api — core SPI contracts, NoOp corpus"
```

---

## Batch 2: simulation-core — Strategy Implementations

### Task 2: SequentialStrategy and RandomStrategy

**Files:**
- Create: `simulation-core/pom.xml`
- Create: `simulation-core/src/main/java/io/casehub/platform/simulation/strategy/SequentialStrategy.java`
- Create: `simulation-core/src/main/java/io/casehub/platform/simulation/strategy/RandomStrategy.java`
- Modify: `pom.xml` (parent — add `<module>simulation-core</module>`)
- Test: `simulation-core/src/test/java/io/casehub/platform/simulation/strategy/SequentialStrategyTest.java`
- Test: `simulation-core/src/test/java/io/casehub/platform/simulation/strategy/RandomStrategyTest.java`

**Interfaces:**
- Consumes: `SimulationStrategy<I, O>`, `SimulationCorpus<I, O>`, `ExhaustionPolicy` from simulation-api
- Produces: `SequentialStrategy<I, O>(corpus, qualifiedName, exhaustionPolicy)`, `RandomStrategy<I, O>(corpus, qualifiedName, random, generator)`

- [ ] **Step 1: Create simulation-core pom.xml**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>
    <parent>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-platform-parent</artifactId>
        <version>0.2-SNAPSHOT</version>
    </parent>
    <artifactId>casehub-platform-simulation-core</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform :: Simulation Core</name>
    <description>Strategy implementations — Sequential, KeyLookup, Random, RecordedReplay.
        Constructor-injected POJOs, no CDI.</description>
    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-simulation-api</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>org.junit.jupiter</groupId>
            <artifactId>junit-jupiter</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.assertj</groupId>
            <artifactId>assertj-core</artifactId>
            <scope>test</scope>
        </dependency>
    </dependencies>
</project>
```

Add `<module>simulation-core</module>` to parent pom after `simulation-api`.

- [ ] **Step 2: Write failing tests for SequentialStrategy**

Test WRAP mode (cycles through corpus), THROW mode (throws on exhaustion), canResolve returns false on empty corpus. Use an `InMemorySimulationCorpus` test helper (or inline anonymous impl seeded with data).

- [ ] **Step 3: Implement SequentialStrategy**

Per spec: `AtomicInteger` counter, `ExhaustionPolicy.WRAP` wraps via modulo, `ExhaustionPolicy.THROW` throws `SimulationExhaustedException`. `canResolve` checks corpus size and counter position.

- [ ] **Step 4: Write failing tests for RandomStrategy, implement it**

Test corpus-based random sampling (seeded Random for determinism), on-demand generator mode. Verify reproducibility with same seed.

- [ ] **Step 5: Run all tests and commit**

Run: `mvn --batch-mode -pl simulation-core test`
Expected: PASS

```bash
git add simulation-core/ pom.xml
git commit -m "feat(#313): simulation-core — SequentialStrategy, RandomStrategy"
```

### Task 3: KeyLookupStrategy and RecordedReplayStrategy

**Files:**
- Create: `simulation-core/src/main/java/io/casehub/platform/simulation/strategy/KeyLookupStrategy.java`
- Create: `simulation-core/src/main/java/io/casehub/platform/simulation/strategy/RecordedReplayStrategy.java`
- Test: `simulation-core/src/test/java/io/casehub/platform/simulation/strategy/KeyLookupStrategyTest.java`
- Test: `simulation-core/src/test/java/io/casehub/platform/simulation/strategy/RecordedReplayStrategyTest.java`

**Interfaces:**
- Consumes: `SimulationStrategy<I, O>`, `SimulationCorpus<I, O>`, `KeyExtractor<I>` from simulation-api
- Produces: `KeyLookupStrategy<I, O>(corpus, qualifiedName, keyExtractor)`, `RecordedReplayStrategy<I, O>(corpus, qualifiedName, keyExtractor)`

- [ ] **Step 1: Write failing tests for KeyLookupStrategy**

Test exact key match, miss throws `SimulationKeyNotFoundException`, `canResolve` returns false on miss.

- [ ] **Step 2: Implement KeyLookupStrategy**

Per spec: uses `KeyExtractor<I>` to derive key from input, delegates to `corpus.lookupByKey(qualifiedName, key)`.

- [ ] **Step 3: Write failing tests for RecordedReplayStrategy, implement it**

Test key-first match (deterministic), sequential fallback when key not found. Verify fallback index advances.

- [ ] **Step 4: Run all tests and commit**

Run: `mvn --batch-mode -pl simulation-core test`
Expected: PASS

```bash
git add simulation-core/
git commit -m "feat(#313): simulation-core — KeyLookupStrategy, RecordedReplayStrategy"
```

---

## Batch 3: simulation-inmem — In-Memory Corpus

### Task 4: InMemorySimulationCorpus

**Files:**
- Create: `simulation-inmem/pom.xml`
- Create: `simulation-inmem/src/main/java/io/casehub/platform/simulation/inmem/InMemorySimulationCorpus.java`
- Modify: `pom.xml` (parent — add `<module>simulation-inmem</module>`)
- Test: `simulation-inmem/src/test/java/io/casehub/platform/simulation/inmem/InMemorySimulationCorpusTest.java`

**Interfaces:**
- Consumes: `SimulationCorpus<I, O>`, `InvocationRecord<I, O>` from simulation-api
- Produces: `InMemorySimulationCorpus<I, O>` — `@Alternative @Priority(100)`, `ConcurrentHashMap`-backed

- [ ] **Step 1: Create simulation-inmem pom.xml**

Depends on `simulation-api`. No Quarkus runtime dep — but needs `jakarta.enterprise.cdi-api` for `@Alternative` and `@Priority` annotations. Add Jandex plugin for CDI discovery.

- [ ] **Step 2: Write failing tests for InMemorySimulationCorpus**

Test: `record()` then `lookupByKey()` returns recorded output. `lookupByIndex()` returns in insertion order. `seed()` pre-populates. `listByTenant()` filters correctly. `clear()` removes only for given qualifiedName. `size()` reflects current count. Concurrent `record()` from multiple threads.

- [ ] **Step 3: Implement InMemorySimulationCorpus**

`ConcurrentHashMap<String, List<InvocationRecord<I, O>>>` keyed by `qualifiedName`. Within each list, `lookupByKey` scans for matching key, `lookupByIndex` uses list index. `record()` appends with auto-generated key if none provided. Thread-safe via `ConcurrentHashMap` + `CopyOnWriteArrayList` (or synchronized list).

- [ ] **Step 4: Run tests and commit**

Run: `mvn --batch-mode -pl simulation-inmem test`
Expected: PASS

```bash
git add simulation-inmem/ pom.xml
git commit -m "feat(#314): simulation-inmem — InMemorySimulationCorpus @Alternative"
```

---

## Batch 4: SimulationRuntime + Configuration

### Task 5: SimulationConfig and SimulationRuntime

**Files:**
- Create: `simulation-core/src/main/java/io/casehub/platform/simulation/SimulationRuntime.java`
- Create: `simulation-core/src/main/java/io/casehub/platform/simulation/SimulationConfig.java`
- Test: `simulation-core/src/test/java/io/casehub/platform/simulation/SimulationRuntimeTest.java`

**Interfaces:**
- Consumes: All strategy classes, `SimulationCorpus<I, O>`, `KeyExtractor<I>`
- Produces: `SimulationRuntime` — `registerExtractor(qualifiedName, extractor)`, `strategyFor(qualifiedName)`, `captureEnabled(qualifiedName)`, `capture(qualifiedName, tenancyId, input, output)`

**Note:** `SimulationRuntime` is framework-neutral in `simulation-core` (POJO with constructor injection). The Quarkus `@ApplicationScoped` producer goes in a Quarkus wiring module (or the consumer module that needs it). The `SimulationConfig` interface is defined here; the SmallRye `@ConfigMapping` implementation is provided by the consumer.

- [ ] **Step 1: Write SimulationConfig interface**

```java
package io.casehub.platform.simulation;
import java.util.Optional;
public interface SimulationConfig {
    Optional<String> strategyFor(String qualifiedName);
    boolean captureEnabled(String qualifiedName);
    Optional<ExhaustionPolicy> exhaustionPolicy(String qualifiedName);
}
```

- [ ] **Step 2: Write failing tests for SimulationRuntime**

Test: `strategyFor()` returns empty when no config. Returns `SequentialStrategy` when config says `"sequential"`. Returns `KeyLookupStrategy` when config says `"key-lookup"` and extractor registered. Throws `SimulationConfigException` when `"key-lookup"` configured but no extractor. `captureEnabled()` delegates to config. `capture()` delegates to corpus.

Use a stub `SimulationConfig` and `InMemorySimulationCorpus` in tests.

- [ ] **Step 3: Implement SimulationRuntime**

Per spec: non-generic POJO. Constructor takes `SimulationConfig` and `SimulationCorpus` (raw type — unavoidable for the non-generic registry pattern). `ConcurrentHashMap` for extractors and strategy cache. Factory method creates strategy by name string.

- [ ] **Step 4: Run tests and commit**

Run: `mvn --batch-mode -pl simulation-core test`
Expected: PASS

```bash
git add simulation-core/
git commit -m "feat(#312): SimulationConfig + SimulationRuntime — strategy factory and capture dispatch"
```

---

## Batch 5: simulation-generator — Annotation Processor

### Task 6: SimulationDecoratorProcessor

**Files:**
- Create: `simulation-generator/pom.xml`
- Create: `simulation-generator/src/main/java/io/casehub/platform/simulation/generator/SimulationDecoratorProcessor.java`
- Create: `simulation-generator/src/main/resources/META-INF/services/javax.annotation.processing.Processor`
- Modify: `pom.xml` (parent — add `<module>simulation-generator</module>`)
- Test: `simulation-generator/src/test/java/io/casehub/platform/simulation/generator/SimulationDecoratorProcessorTest.java`
- Test: `simulation-generator/src/test/java/io/casehub/platform/simulation/generator/test/TestSimpleService.java` (test SPI)

**Interfaces:**
- Consumes: `@SimulationEligible` annotation from simulation-api, Jandex indexes
- Produces: Generated `@Decorator` Java source files per `@SimulationEligible` SPI

- [ ] **Step 1: Create simulation-generator pom.xml**

Mirror `callback-generator/pom.xml` structure:
```xml
<dependencies>
    <dependency>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-platform-simulation-api</artifactId>
        <version>${project.version}</version>
    </dependency>
    <dependency>
        <groupId>io.smallrye</groupId>
        <artifactId>jandex</artifactId>
    </dependency>
    <!-- Test -->
    <dependency>
        <groupId>org.junit.jupiter</groupId>
        <artifactId>junit-jupiter</artifactId>
        <scope>test</scope>
    </dependency>
    <dependency>
        <groupId>org.assertj</groupId>
        <artifactId>assertj-core</artifactId>
        <scope>test</scope>
    </dependency>
    <dependency>
        <groupId>com.google.testing.compile</groupId>
        <artifactId>compile-testing</artifactId>
        <version>0.21.0</version>
        <scope>test</scope>
    </dependency>
</dependencies>
```

Register processor in `META-INF/services/javax.annotation.processing.Processor`.

- [ ] **Step 2: Create test SPI interface and write processor test**

Create a minimal `@SimulationEligible` test interface:
```java
package io.casehub.platform.simulation.generator.test;
import io.casehub.platform.simulation.SimulationEligible;
@SimulationEligible(name = "test-service")
public interface TestSimpleService {
    String lookup(String id);
    void save(String id, String value);
    int count();
}
```

Build a test Jandex index from this interface. Test that the processor generates a decorator class with correct methods: `lookup()` checks strategy then delegates, `save()` (void) handles capture then delegates, `count()` delegates.

- [ ] **Step 3: Implement SimulationDecoratorProcessor**

Mirror `CallbackDecoratorProcessor` structure:
- Extends `AbstractProcessor`, `@SupportedAnnotationTypes("*")`
- `loadCombinedIndex()` — reads `META-INF/jandex.idx` from classpath
- `generateFromIndex()` — finds `@SimulationEligible` interfaces, generates decorator per interface
- `generateDecoratorSource()` — builds Java source string with per-method simulation/capture blocks
- `generateMethod()` — for each abstract method: check `simulation.strategyFor(qualifiedName)`, if present and canResolve → resolve. Otherwise delegate. If `simulation.captureEnabled(qualifiedName)` → capture.
- `toKebabCase()` — reuse from `CallbackDecoratorProcessor` (same algorithm)
- `typeToJava()` — reuse pattern from `CallbackDecoratorProcessor`

Generated decorator imports: `SimulationRuntime`, `SimulationStrategy`, `CurrentPrincipal`, `@Decorator`, `@Delegate`, `@Priority`, `@Inject`.

The generated class name: `Simulated{SpiName}` (e.g. `SimulatedTestSimpleService`).
Package: `io.casehub.platform.simulation.generated`.

- [ ] **Step 4: Verify generated source matches expected output**

Assert the generated decorator:
- Implements the SPI interface
- Has `@Decorator @Priority(APPLICATION + 200)`
- Has `@Inject @Delegate` field
- Has `@Inject SimulationRuntime simulation`
- Has `@Inject CurrentPrincipal currentPrincipal`
- Each method has `qualifiedName = "test-service.<method>"`
- Non-void methods return strategy result or delegate result
- Void methods call delegate then optionally capture

- [ ] **Step 5: Run tests and commit**

Run: `mvn --batch-mode -pl simulation-generator test`
Expected: PASS

```bash
git add simulation-generator/ pom.xml
git commit -m "feat(#312): simulation-generator — SimulationDecoratorProcessor annotation processor"
```

---

## Batch 6: agent-simulation — AgentProvider Backend (Path B)

### Task 7: SimulatedAgentBackend

**Files:**
- Create: `agent-simulation-core/pom.xml`
- Create: `agent-simulation-core/src/main/java/io/casehub/platform/agent/simulation/SimulatedAgentBackend.java`
- Create: `agent-simulation-core/src/main/java/io/casehub/platform/agent/simulation/AgentSimulationInput.java`
- Modify: `pom.xml` (parent — add `<module>agent-simulation-core</module>`)
- Test: `agent-simulation-core/src/test/java/io/casehub/platform/agent/simulation/SimulatedAgentBackendTest.java`

**Interfaces:**
- Consumes: `AgentBackend` (key, invoke, openSession), `AgentSessionConfig`, `AgentEvent`, `SimulationRuntime`, `SimulationStrategy<AgentSimulationInput, List<AgentEvent>>`
- Produces: `SimulatedAgentBackend` with `key() = "simulated"`, `invoke()` resolves from strategy and converts `List<AgentEvent>` → `Multi<AgentEvent>`

- [ ] **Step 1: Create agent-simulation-core pom.xml**

Dependencies: `agent-api`, `simulation-api`, `simulation-core`, Mutiny (for `Multi`), test deps.

- [ ] **Step 2: Write AgentSimulationInput record**

```java
package io.casehub.platform.agent.simulation;
public record AgentSimulationInput(String systemPrompt, String userPrompt, String model) {}
```

Factory method: `static AgentSimulationInput from(AgentSessionConfig config)` — extracts system prompt, user prompt, model from config.

- [ ] **Step 3: Write failing tests for SimulatedAgentBackend**

Test: `key()` returns `"simulated"`. `invoke()` with strategy configured returns `Multi<AgentEvent>` from corpus. `invoke()` with no strategy returns empty Multi. `openSession()` returns a session that resolves per-query. Key extractor strips UUIDs from prompts.

- [ ] **Step 4: Implement SimulatedAgentBackend**

```java
package io.casehub.platform.agent.simulation;
public class SimulatedAgentBackend implements AgentBackend {
    private final SimulationRuntime simulation;
    private static final String QN_INVOKE = "agent-provider.invoke";

    public SimulatedAgentBackend(SimulationRuntime simulation) {
        this.simulation = simulation;
    }

    @Override public String key() { return "simulated"; }

    @Override
    public Multi<AgentEvent> invoke(AgentSessionConfig config) {
        Optional<SimulationStrategy<AgentSimulationInput, List<AgentEvent>>> strategy =
            simulation.strategyFor(QN_INVOKE);
        if (strategy.isEmpty()) return Multi.createFrom().empty();

        AgentSimulationInput input = AgentSimulationInput.from(config);
        if (!strategy.get().canResolve(input)) return Multi.createFrom().empty();

        List<AgentEvent> events = strategy.get().resolve(input);
        return Multi.createFrom().iterable(events);
    }

    @Override
    public AgentSession openSession(AgentSessionInit init) {
        // Deferred — return a minimal session that delegates invoke per query
        throw new UnsupportedOperationException("Multi-turn simulation not yet implemented");
    }
}
```

- [ ] **Step 5: Register default KeyExtractor for agent-provider.invoke**

Add a startup registration in `SimulatedAgentBackend` or a companion class:
```java
public static KeyExtractor<AgentSimulationInput> defaultKeyExtractor() {
    return input -> stripNonDeterministic(input.systemPrompt())
        + "::" + stripNonDeterministic(input.userPrompt());
}

private static String stripNonDeterministic(String text) {
    if (text == null) return "";
    return text.replaceAll("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", "<UUID>")
               .replaceAll("\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}", "<TIMESTAMP>");
}
```

- [ ] **Step 6: Run tests and commit**

Run: `mvn --batch-mode -pl agent-simulation-core test`
Expected: PASS

```bash
git add agent-simulation-core/ pom.xml
git commit -m "feat(#315): agent-simulation-core — SimulatedAgentBackend (Path B)"
```

---

## Next Phase (not in this plan)

- **CaseMemoryStore simulation (Path A, #320):** First use of `simulation-generator` in a consuming repo. `@SimulationEligible` on `CaseMemoryStore` interface in neocortex/memory-api. Depends on generator being proven in this plan's Batch 5.
- **Filesystem corpus (#314 partial):** `simulation-fs` module with YAML/JSON fixture loading.
- **Capture/replay (#316):** End-to-end capture decorator wiring in a `@QuarkusTest`.
- **Event simulation (#318):** `SimulatedEventEmitter` + DataSource integration.
- **NearestMatchStrategy (#317):** Constraint weighting, similarity scoring.
- **Consumer adoption (#323):** Fixture files for clinical, devtown, aml, fsitrading.

## References

- [2026-09-15-simulation-service-design.md] — design spec this plan implements
- [callback-generator/src/main/java/.../CallbackDecoratorProcessor.java] — annotation processor precedent
- [callback-generator/pom.xml] — annotation processor module pom precedent
- [agent-api/src/main/java/.../AgentBackend.java] — backend SPI interface
- [agent-api/src/main/java/.../BackendInstanceRegistry.java] — backend registration SPI
- [agent-router-core/src/main/java/.../RoutingAgentProvider.java] — routing infrastructure
- [agent-openai-core/pom.xml] — agent backend module pom precedent
- [platform/src/main/java/.../NoOpAgentProvider.java] — existing NoOp pattern
- [GitHub #294] — epic
- [GitHub #312] — simulation-api
- [GitHub #313] — simulation-core
- [GitHub #314] — corpus storage
- [GitHub #315] — AgentProvider simulation adapter
