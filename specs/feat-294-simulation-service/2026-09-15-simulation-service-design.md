# Simulation Service Design Spec

**Branch:** feat/294-simulation-service
**Epic:** casehubio/platform#294
**Date:** 2026-09-15

## Overview

A generic, domain-agnostic simulation framework for casehub-platform. Any SPI without a real implementation wired at runtime gets configurable simulation behaviour instead of silent no-op responses. The service owns three concerns: **seeding** data into the system, **responding** to invocations via pluggable strategies, and **capturing** real invocations for corpus building.

The service is interface-agnostic. It applies to any part of the system where a real implementation may not be wired — LLMs, banking, connectors, identity providers, memory stores, or any internal SPI. The mechanism is SPI-shaped: if it has inputs and outputs, the simulation strategies can drive it.

## Architecture

### Two modes

The simulation framework provides two modes of operation per SPI:

- **Simulation mode** — when a simulation strategy is configured for an SPI method, responses are resolved from the configured strategy instead of delegating to the underlying implementation. This is configuration-driven: `casehub.simulation.<spi-name>.<method-name>.strategy=<strategy>` activates simulation regardless of whether the delegate is a NoOp or a real implementation.
- **Capture mode** — when capture is enabled, the framework records input/output pairs to a `SimulationCorpus` while passing through to the real implementation.
- **Passthrough** — when neither simulation nor capture is configured, the framework delegates transparently. Zero overhead in the common case.

NoOp implementations remain untouched — zero-dependency, zero-logic, trivially constructable. The simulation framework wraps them; it does not modify them.

### Two integration paths

Not all SPIs are equal. The framework provides two integration paths depending on the SPI's existing architecture:

**Path A — Generated `@Decorator`** (default for simple SPIs)

For SPIs with direct CDI injection and simple request-response methods (PreferenceProvider, CaseMemoryStore, DataSourceRegistry, ExpressionEngine, etc.), the framework generates a `@Decorator` per `@SimulationEligible` SPI. The decorator intercepts calls, routes to simulation strategies when configured, and optionally captures invocations.

**Path B — Backend integration** (for SPIs with existing routing layers)

SPIs that already have multi-backend routing (like AgentProvider → RoutingAgentProvider → AgentBackend) integrate simulation as a backend implementation rather than a decorator. The simulation backend registers with the existing routing infrastructure and is dispatched to via the existing model/key resolution mechanism.

| Criteria | Path A (Decorator) | Path B (Backend) |
|----------|-------------------|-----------------|
| SPI shape | Simple request-response | Routing layer with multiple backends |
| Return types | Blocking / data types | Reactive streams, stateful sessions |
| Integration | Generated @Decorator wrapping SPI | Implements backend interface, registered with router |
| First target | CaseMemoryStore (#320) | AgentProvider (#315) |
| Strategy contract | Same `SimulationStrategy<I, O>` | Same `SimulationStrategy<I, O>` |

Both paths use the same `SimulationStrategy<I, O>` contract, `SimulationCorpus`, and configuration model. The difference is where the interception happens.

### Activation

The `@SimulationEligible` annotation on an SPI interface triggers code generation of the `@Decorator`. Configuration at boot time controls behaviour:

```properties
# Per-method strategy configuration (multi-method SPIs)
casehub.simulation.case-memory-store.query.strategy=key-lookup
casehub.simulation.case-memory-store.store.strategy=sequential
# erase: no strategy → passthrough

# Enable capture mode per method
casehub.simulation.case-memory-store.query.capture=true

# AgentProvider uses Path B (backend), but config key structure is the same
casehub.simulation.agent-provider.invoke.strategy=key-lookup

# Single-method SPIs can use the method name directly
casehub.simulation.preference-store.get.capture=true
```

### Module structure

| Module | Packaging | Contains | Depends on |
|--------|-----------|----------|------------|
| `simulation-api` | jar (zero-dep) | SimulationStrategy, SimulationCorpus, InvocationRecord, KeyExtractor, DataRealism, @SimulationEligible | nothing |
| `simulation-core` | jar | Strategy implementations: SequentialStrategy, KeyLookupStrategy, RandomStrategy, RecordedReplayStrategy | simulation-api |
| `simulation-generator` | annotation-processor | SimulationDecoratorProcessor — generates @Decorator per @SimulationEligible SPI (extends AbstractProcessor, sibling to CallbackDecoratorProcessor) | simulation-api, generator-common |
| `simulation-inmem` | jar (Jandex) | InMemorySimulationCorpus @Alternative @Priority(100) | simulation-api |
| `simulation-fs` | jar (Jandex) | FilesystemSimulationCorpus @ApplicationScoped (YAML/JSON fixtures, captured corpora) | simulation-api |

`simulation-api` includes a NoOp `@DefaultBean` SimulationCorpus (returns empty for all lookups, discards records). This follows the store pattern: the @DefaultBean is active when no corpus module is on the classpath, preventing `UnsatisfiedResolutionException`.

CDI priority follows the persistence backend ladder (PP-20260522-0cfa30):
- NoOp @DefaultBean (Tier 1b) — in `simulation-api`, active with no corpus module
- Filesystem @ApplicationScoped (Tier 2, primary) — durable, file-backed corpus
- InMemory @Alternative @Priority(100) (Tier 4) — ephemeral, wins in tests

Filesystem and in-memory are mutually exclusive per deployment — do not co-deploy in production. InMemory wins when both are on the classpath (test safety net).

Follows the established module naming convention (D2): dedicated `simulation-api` module, not embedded in `platform-api`. Simulation is opt-in — consumers add the modules they need. Note: `@SimulationEligible` lives in `simulation-api`, diverging from `@CallbackEligible` which lives in `platform-api`. This is intentional — callbacks are a universal platform concern, while simulation is opt-in. SPIs that want simulation add `simulation-api` as a dependency; those that don't are unaffected.

## Core contracts

### SimulationStrategy

```java
package io.casehub.platform.simulation;

public interface SimulationStrategy<I, O> {
    O resolve(I input);
    boolean canResolve(I input);
}
```

Generic `<I, O>` — each SPI adapter defines its own input/output types (D3). The strategy does not know what SPI it serves. `canResolve` allows strategies to signal when they cannot produce a response (e.g. corpus exhausted in sequential mode).

### KeyExtractor

```java
@FunctionalInterface
public interface KeyExtractor<I> {
    String extract(I input);
}
```

Owned by strategies that need key-based matching (D7). Functional interface — typically a one-liner per SPI.

### SimulationCorpus

```java
package io.casehub.platform.simulation;

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
```

Every corpus method takes `qualifiedName` — the method-qualified key (e.g., `"case-memory-store.query"`) that partitions the data space. Without it, two SPIs using the same key (e.g., `"default"`) would collide. The composite key for data access is `(qualifiedName, tenancyId, key)`.

Follows the store pattern (D5) per CDI priority ladder (PP-20260522-0cfa30): NoOp @DefaultBean (Tier 1b, in simulation-api), Filesystem @ApplicationScoped (Tier 2, primary), InMemory @Alternative @Priority(100) (Tier 4, tests). Tenant-aware per D10 — captured data is scoped to the tenant context of the invocation.

### InvocationRecord

```java
package io.casehub.platform.simulation;

public record InvocationRecord<I, O>(
    String tenancyId,
    String key,
    I input,
    O output,
    Instant recordedAt
) {}
```

A captured input/output pair. Stored in the corpus. Used for replay and corpus building.

### DataRealism

```java
package io.casehub.platform.simulation;

public enum DataRealism {
    GARBAGE,
    PLACEHOLDER,
    STRUCTURALLY_VALID,
    DOMAIN_PLAUSIBLE,
    RECORDED_REAL
}
```

Advisory — the framework does not enforce realism level. Used by corpus seeding tools and scenario configuration to communicate expected data quality.

### @SimulationEligible

```java
package io.casehub.platform.simulation;

import java.lang.annotation.*;

@Target(ElementType.TYPE)
@Retention(RetentionPolicy.RUNTIME)
public @interface SimulationEligible {
    String name() default "";
}
```

Placed on SPI interfaces to trigger decorator generation. The `name` defaults to kebab-case of the interface name (e.g. `AgentProvider` → `agent-provider`). Used as the config key prefix: `casehub.simulation.<name>.<method>.strategy=...`.

### SimulationRuntime

```java
package io.casehub.platform.simulation;

@ApplicationScoped
public class SimulationRuntime {
    @Inject SimulationConfig config;
    @Inject SimulationCorpus corpus;

    private final Map<String, KeyExtractor<?>> extractors = new ConcurrentHashMap<>();
    private final Map<String, SimulationStrategy<?, ?>> strategyCache = new ConcurrentHashMap<>();

    // --- Registration API (called by SPI adapter modules at startup) ---

    public <I> void registerExtractor(String qualifiedName, KeyExtractor<I> extractor) {
        extractors.put(qualifiedName, extractor);
    }

    // --- Strategy resolution (called by decorators and backends) ---

    @SuppressWarnings("unchecked")
    public <I, O> Optional<SimulationStrategy<I, O>> strategyFor(String qualifiedName) {
        return config.strategyFor(qualifiedName)
            .map(strategyName -> (SimulationStrategy<I, O>) strategyCache.computeIfAbsent(
                qualifiedName, qn -> createStrategy(qn, strategyName)));
    }

    public boolean captureEnabled(String qualifiedName) {
        return config.captureEnabled(qualifiedName);
    }

    public <I, O> void capture(String qualifiedName, String tenancyId, I input, O output) {
        corpus.record(qualifiedName, tenancyId, input, output);
    }

    public <I, O> void capture(String qualifiedName, String tenancyId, String key, I input, O output) {
        corpus.record(qualifiedName, tenancyId, key, input, output);
    }

    // --- Strategy factory ---

    @SuppressWarnings("unchecked")
    private <I, O> SimulationStrategy<I, O> createStrategy(String qualifiedName, String strategyName) {
        return switch (strategyName) {
            case "sequential" -> new SequentialStrategy<>(corpus, qualifiedName,
                config.exhaustionPolicy(qualifiedName).orElse(ExhaustionPolicy.WRAP));
            case "key-lookup" -> {
                KeyExtractor<I> extractor = requireExtractor(qualifiedName);
                yield new KeyLookupStrategy<>(corpus, qualifiedName, extractor);
            }
            case "random" -> new RandomStrategy<>(corpus, qualifiedName, new Random());
            case "recorded-replay" -> {
                KeyExtractor<I> extractor = requireExtractor(qualifiedName);
                yield new RecordedReplayStrategy<>(corpus, qualifiedName, extractor);
            }
            default -> throw new SimulationConfigException(
                "Unknown strategy '" + strategyName + "' for " + qualifiedName);
        };
    }

    @SuppressWarnings("unchecked")
    private <I> KeyExtractor<I> requireExtractor(String qualifiedName) {
        KeyExtractor<I> extractor = (KeyExtractor<I>) extractors.get(qualifiedName);
        if (extractor == null) {
            throw new SimulationConfigException(
                "Strategy for " + qualifiedName + " requires a KeyExtractor, but none registered");
        }
        return extractor;
    }
}
```

Non-generic `@ApplicationScoped` bean — avoids the CDI type erasure problem with `Instance<SimulationStrategy<I, O>>`. Generated decorators and backend implementations inject `SimulationRuntime` and resolve strategies by method-qualified name at runtime. Follows the `CallbackRegistry` pattern: a non-generic registry that resolves by name, not by generic type parameters.

**Registration:** SPI adapter modules register their `KeyExtractor` instances at startup via CDI `@Observes StartupEvent`. The factory uses registered components to construct the configured strategy variant. Strategies that don't require a KeyExtractor (sequential, random) work without registration.

```java
// Example: CaseMemoryStore adapter registers extractors at startup
@ApplicationScoped
public class CaseMemoryStoreSimulationAdapter {
    @Inject SimulationRuntime simulation;

    void onStartup(@Observes StartupEvent event) {
        simulation.registerExtractor("case-memory-store.query",
            (QuerySimulationInput input) -> input.query().domain().name()
                + ":" + input.query().question());
    }
}
```

## Strategy implementations

All in `simulation-core`, constructor-injected POJOs (no CDI annotations).

### SequentialStrategy

Returns responses from a pre-defined list in order. Thread-safe atomic counter.

```java
public class SequentialStrategy<I, O> implements SimulationStrategy<I, O> {
    private final SimulationCorpus<I, O> corpus;
    private final String qualifiedName;
    private final AtomicInteger index = new AtomicInteger(0);
    private final ExhaustionPolicy exhaustionPolicy;

    public O resolve(I input) {
        int i = index.getAndIncrement();
        if (exhaustionPolicy == ExhaustionPolicy.THROW && i >= corpus.size(qualifiedName)) {
            throw new SimulationExhaustedException(
                "Corpus exhausted at index " + i + " (size: " + corpus.size(qualifiedName) + ")");
        }
        return corpus.lookupByIndex(qualifiedName, i % corpus.size(qualifiedName))
            .orElseThrow(() -> new SimulationExhaustedException(...));
    }

    public boolean canResolve(I input) {
        if (exhaustionPolicy == ExhaustionPolicy.THROW) {
            return index.get() < corpus.size(qualifiedName);
        }
        return corpus.size(qualifiedName) > 0;
    }
}

public enum ExhaustionPolicy { WRAP, THROW }
```

**Caveat:** non-deterministic under async/distributed consumers — consumption order depends on thread scheduling.

### KeyLookupStrategy

Invocation parameters → key → exact match in corpus.

```java
public class KeyLookupStrategy<I, O> implements SimulationStrategy<I, O> {
    private final SimulationCorpus<I, O> corpus;
    private final String qualifiedName;
    private final KeyExtractor<I> keyExtractor;

    public O resolve(I input) {
        String key = keyExtractor.extract(input);
        return corpus.lookupByKey(qualifiedName, key)
            .orElseThrow(() -> new SimulationKeyNotFoundException(key));
    }

    public boolean canResolve(I input) {
        String key = keyExtractor.extract(input);
        return corpus.lookupByKey(qualifiedName, key).isPresent();
    }
}
```

Fully deterministic. The key function is SPI-specific — per-SPI adapters provide it.

### RandomStrategy

Samples from corpus or generates on demand.

```java
public class RandomStrategy<I, O> implements SimulationStrategy<I, O> {
    private final SimulationCorpus<I, O> corpus;
    private final String qualifiedName;
    private final Random random;
    private final Supplier<O> generator; // optional on-demand generation

    public O resolve(I input) {
        if (generator != null) return generator.get();
        int i = random.nextInt(corpus.size(qualifiedName));
        return corpus.lookupByIndex(qualifiedName, i)
            .orElseThrow(() -> new SimulationExhaustedException(...));
    }
}
```

Optional seed for reproducibility. Can use a `Supplier<O>` for on-demand generation (lorem ipsum, random data, etc.).

### RecordedReplayStrategy

Replays captured corpus in recorded order.

```java
public class RecordedReplayStrategy<I, O> implements SimulationStrategy<I, O> {
    private final SimulationCorpus<I, O> corpus;
    private final String qualifiedName;
    private final KeyExtractor<I> keyExtractor;
    private final AtomicInteger index = new AtomicInteger(0);

    public O resolve(I input) {
        String key = keyExtractor.extract(input);
        return corpus.lookupByKey(qualifiedName, key)
            .orElseGet(() -> {
                // fallback to sequential if key not found
                return corpus.lookupByIndex(qualifiedName, index.getAndIncrement())
                    .orElseThrow();
            });
    }
}
```

Key-based first (deterministic when keys match), sequential fallback when keys don't match.

### NearestMatchStrategy (deferred)

The hard problem — constraint weighting, similarity scoring. Designed but deferred from initial implementation. The `SimulationStrategy<I, O>` contract supports it; the implementation is a later phase (issue #317).

```java
public class NearestMatchStrategy<I, O> implements SimulationStrategy<I, O> {
    private final SimulationCorpus<I, O> corpus;
    private final String qualifiedName;
    private final SimilarityScorer<I> scorer;
    private final double threshold;

    public O resolve(I input) {
        return corpus.list(qualifiedName).stream()
            .map(r -> new ScoredMatch<>(r, scorer.score(input, r.input())))
            .filter(m -> m.score() >= threshold)
            .max(Comparator.comparingDouble(ScoredMatch::score))
            .map(m -> m.record().output())
            .orElseThrow(() -> new SimulationNoMatchException(...));
    }
}

@FunctionalInterface
public interface SimilarityScorer<I> {
    double score(I query, I candidate);
}
```

## Code generation

### SimulationDecoratorProcessor

Annotation processor (extends `AbstractProcessor`, sibling to `CallbackDecoratorProcessor`). Scans Jandex indexes for `@SimulationEligible` interfaces and generates a `@Decorator` for each. This is an annotation processor — not a Maven plugin — following the same mechanism as callback-generator. `generator-common` provides shared Jandex/JavaPoet utilities used by both.

**Generated decorator template (Path A — direct SPIs only):**

The generator produces a **per-method** strategy resolution block for each abstract method on the SPI. Each method gets its own method-qualified name (`"{spi-name}.{method-name}"`), its own input/output type pair, and its own strategy lookup. This handles multi-method SPIs like CaseMemoryStore where `store()`, `query()`, and `erase()` have different I/O types.

```java
@Decorator
@Priority(Interceptor.Priority.APPLICATION + 200)
public class Simulated{SpiName} implements {SpiInterface} {

    @Inject @Delegate @Any {SpiInterface} delegate;
    @Inject SimulationRuntime simulation;
    @Inject CurrentPrincipal currentPrincipal;

    // --- Per-method: generated for each abstract method ---

    @Override
    public {ReturnType} {method}({params}) {
        String qualifiedName = "{spi-name}.{method-name}";

        // Simulation mode: strategy configured for this method
        Optional<SimulationStrategy<{MethodInputType}, {MethodOutputType}>> strategy =
            simulation.strategyFor(qualifiedName);
        if (strategy.isPresent()) {
            {MethodInputType} input = new {MethodInputType}({params});
            if (strategy.get().canResolve(input)) {
                return strategy.get().resolve(input);
            }
        }

        // Passthrough + optional capture
        {ReturnType} result = delegate.{method}({params});

        if (simulation.captureEnabled(qualifiedName)) {
            String tenancyId = currentPrincipal.tenancyId();
            {MethodInputType} input = new {MethodInputType}({params});
            simulation.capture(qualifiedName, tenancyId, input, result);
        }

        return result;
    }

    // ... all other methods delegate to delegate (GE-20260818-2589ee)
}
```

Each method gets its own input record type (`{MethodInputType}`) that wraps the method's parameters directly — `new {MethodInputType}({params})` maps one-to-one with the method signature. Domain-specific field selection for matching is the `KeyExtractor`'s responsibility, not the input record's.

The generator handles:
- All abstract methods implemented with delegation (avoiding the CDI @Decorator gotcha from GE-20260818-2589ee)
- Lazy initialization pattern (no @PostConstruct — GE-20260806-93549d)
- Idempotency guard for double-application through bridges (GE-20260620-9d043b)
- `@IfBuildProperty` gating for zero-overhead when simulation module is absent

### Per-method input/output types

Each simulated method needs its own typed input/output record. For Path A (decorator) SPIs, input records wrap the method parameters directly — the generator produces `new {MethodInputType}({params})`. For Path B (backend) SPIs, input/output types are defined by the backend implementation and may restructure parameters for optimal key extraction.

**Example — CaseMemoryStore (Path A — decorator, multi-method SPI):**

Each abstract method gets its own input record:

```java
// query() — wraps the single method parameter directly
public record QuerySimulationInput(MemoryQuery query) {}
// Output: List<Memory>
// KeyExtractor: input -> input.query().domain().name() + ":" + input.query().question()

// store() — wraps the single method parameter directly
public record StoreSimulationInput(MemoryInput input) {}
// Output: String (the stored memory ID)

// erase() — wraps the single method parameter directly
public record EraseSimulationInput(EraseRequest request) {}
// Output: int (erasure count)
```

Configuration per method:
```properties
casehub.simulation.case-memory-store.query.strategy=key-lookup
casehub.simulation.case-memory-store.store.strategy=sequential
# erase: no strategy → passthrough to delegate
```

**Example — AgentProvider (Path B — backend):**

```java
// Input restructures AgentSessionConfig for key extraction
public record AgentSimulationInput(
    String systemPrompt,
    String userPrompt,
    String model
) {}

// Output is List<AgentEvent> — the MATERIALIZED form
// The backend converts List<AgentEvent> → Multi<AgentEvent> via
// Multi.createFrom().iterable(events)
// KeyExtractor strips UUIDs/timestamps from prompts before hashing
```

### Reactive type handling

Platform SPIs are predominantly blocking (per the "Blocking SPI + virtual threads" architectural pattern). For SPIs that return reactive types (`Multi<T>`, `Uni<T>`), the simulation output type is the **materialized data form** (e.g., `List<AgentEvent>` not `Multi<AgentEvent>`). The conversion between materialized and reactive forms is handled by the integration layer:

- **Path A (decorator):** The decorator wraps the materialized output in the reactive type (e.g., `Multi.createFrom().iterable(list)`)
- **Path B (backend):** The backend implementation handles conversion internally (e.g., `SimulatedAgentBackend.invoke()` returns `Multi.createFrom().iterable(corpus.lookup(key))`)

This keeps the corpus and strategy contracts data-oriented — they store and return data structures, not reactive publishers.

## Corpus storage

### InMemorySimulationCorpus

`@Alternative @Priority(100)`. `ConcurrentHashMap` keyed by `(qualifiedName, tenancyId, key)`. Thread-safe. Supports concurrent capture from async callers.

### FilesystemSimulationCorpus

`@ApplicationScoped` (Tier 2, primary backend per CDI priority ladder). Reads YAML/JSON fixture files at startup. Writes captured corpora to configurable directory. Hot-reload for scenario development.

**Fixture file format:**

```yaml
qualifiedName: agent-provider.invoke
tenancy: default
records:
  - key: "clinical-triage-prompt-v2"
    input:
      systemPrompt: "You are a clinical triage agent..."
      userPrompt: "Patient presents with..."
      model: "claude-opus-5"
    output:
      events:
        - type: TEXT_DELTA
          text: "Based on the symptoms described..."
        - type: INVOCATION_COMPLETE
          usage: { inputTokens: 150, outputTokens: 200 }
    recordedAt: "2026-09-10T14:30:00Z"
```

### Seeding

- **YAML/JSON fixtures** — declarative corpus definition per SPI. Checked into repos alongside test resources.
- **Programmatic builders** — `CorpusBuilder<I, O>` fluent API for test setup.
- **Captured data** — filesystem corpus accumulates from real runs.
- **Export/import** — corpora are files. Copy between environments (staging → CI).

## Tenant awareness

Per D10, all corpus operations are tenant-scoped:

- `record()` takes `tenancyId` — captured data tagged with tenant context
- `listByTenant()` filters by tenant
- Fixture files declare their tenant scope
- The generated decorator injects `CurrentPrincipal` and reads `currentPrincipal.tenancyId()` for capture context

## Configuration

Per D11, configuration is boot-time via SmallRye Config:

```java
@ConfigMapping(prefix = "casehub.simulation")
public interface SimulationConfig {
    @WithParentName
    Map<String, SpiSimulationConfig> spis();

    interface SpiSimulationConfig {
        @WithParentName
        Map<String, MethodSimulationConfig> methods();
    }

    interface MethodSimulationConfig {
        Optional<String> strategy();
        @WithDefault("false")
        boolean capture();
        Optional<String> corpusPath();
        Optional<String> exhaustionPolicy();
    }
}
```

Two-level map: `spis()` maps SPI names (e.g., `case-memory-store`), `methods()` maps method names (e.g., `query`). The method-qualified name `case-memory-store.query` is resolved by `SimulationRuntime.strategyFor()` and maps to `casehub.simulation.case-memory-store.query.strategy=...` in properties.

Usage in `application.properties` — method-qualified keys:

```properties
# AgentProvider (Path B) — per-method
casehub.simulation.agent-provider.invoke.strategy=key-lookup
casehub.simulation.agent-provider.invoke.corpus-path=classpath:simulation/agent-provider.yaml

# CaseMemoryStore (Path A) — per-method, different strategies
casehub.simulation.case-memory-store.query.strategy=key-lookup
casehub.simulation.case-memory-store.store.strategy=sequential
casehub.simulation.case-memory-store.query.capture=true
```

## Event simulation

Per D8, events use the same `SimulationStrategy<I, O>` contract. An event trigger serves as the input:

```java
public record EventTrigger(
    String eventType,
    String tenancyId,
    Instant triggerTime,
    Map<String, Object> context
) {}
```

A scheduled emitter (analogous to `DigestFlushScheduler`) invokes the strategy on a configurable schedule and injects the resulting event into the DataSource pipeline:

```java
@ApplicationScoped
public class SimulatedEventEmitter {
    @Inject SimulationRuntime simulation;
    @Inject DataSourceRegistry dataSourceRegistry;

    @Scheduled(every = "{casehub.simulation.events.interval:10s}")
    void emit() {
        simulation.<EventTrigger, CloudEvent>strategyFor("event-emitter.emit")
            .ifPresent(strategy -> {
                EventTrigger trigger = new EventTrigger(...);
                if (strategy.canResolve(trigger)) {
                    CloudEvent event = strategy.resolve(trigger);
                    // Tenant context from corpus/fixture data, not CurrentPrincipal
                    // (@Scheduled runs outside request context — no CurrentPrincipal available)
                    dataSourceRegistry.resolveSource(path, trigger.tenancyId())
                        .ifPresent(ds -> ds.add(event));
                }
            });
    }
}
```

## Relationship to existing systems

Per D9, three complementary systems:

| System | Scope | Activation | Data model |
|--------|-------|------------|------------|
| **Demo SPI Convention** | Connector SPIs (ChatPlatform, CalendarPlatform) | `@Alternative @Priority(300) @IfBuildProfile("demo")` — build-time (Quarkus augmentation) | Pre-loaded datasets, bootstrap endpoints |
| **Scenario Engine** | Cross-service orchestration | Scenario YAML steps | Step-driven, multi-service |
| **Simulation Service** | Platform SPIs (AgentProvider, CaseMemoryStore, etc.) | Config-driven — runtime | Corpus-backed, 5 strategy modes |

The Demo Convention handles connector-level mock data. The Simulation Service handles platform SPIs. They do not overlap.

**Scenario Engine integration** is deferred to Phase 4 (#322). The current boot-time configuration model (D11) does not support per-scenario strategy switching. Phase 4 will design a runtime-override mechanism (e.g., request-scoped strategy selection, scenario-aware config) to enable scenario steps to configure simulation strategies. The `SimulationStrategy<I, O>` contract and `SimulationRuntime` are designed to support this — the integration mechanism is what's deferred.

## Cross-repo interaction map

| SPI / Boundary | platform | eidos | ledger | work | engine | blocks | clinical | devtown | aml | fsitrading |
|---|---|---|---|---|---|---|---|---|---|---|
| AgentProvider (LLM) | SPI | — | — | — | via blocks | 326+ hits | heavy | — | — | — |
| CaseMemoryStore | SPI | — | — | — | yes | 500+ hits | yes | yes | yes | yes |
| PreferenceProvider | SPI | yes | — | yes | yes | — | yes | yes | yes | — |
| DataSourceRegistry | SPI | yes | — | yes | yes | — | yes | — | — | — |
| ExpressionEngine | SPI | — | — | yes | yes | yes | — | yes | yes | — |
| Identity (DID/signing) | SPI | yes | yes | yes | yes | — | yes | yes | yes | — |
| CredentialResolver | SPI | — | yes | — | — | — | — | — | — | — |
| DocumentSigning | SPI | — | yes | — | — | — | — | — | — | — |
| ModelRegistry | SPI | yes | — | — | — | yes | yes | — | yes | yes |
| @RegisterRestClient | — | — | — | — | — | Mem0/Graphiti | — | 5 GitHub APIs | — | — |

## Scope

This spec covers **Phase 1 (Foundation)** and **Phase 2 (LLM first)** of epic #294. The following items are explicitly deferred to later phases:

| Item | Phase | Issue | Notes |
|------|-------|-------|-------|
| REST client simulation | 3 | #319 | `@RegisterRestClient` proxy interception. Strategy contract supports this; integration mechanism differs (MicroProfile REST Client proxy, not CDI decorator). |
| Generic @DefaultBean upgrade | 3 | #321 | Proposes `SimulationAwareDefaultBean` base class as an alternative to decorator wrapping for ~35 existing @DefaultBean no-ops. May complement or replace Path A for some SPIs — design decision deferred. |
| Pages scenario integration | 4 | #322 | Requires runtime strategy switching — conflicts with current boot-time config (D11). Needs request-scoped override mechanism. |
| NearestMatchStrategy | 2 | #317 | Constraint weighting, similarity scoring. Contract (`SimulationStrategy<I, O>`) supports it; implementation is the hard problem. |

The strategy contract (`SimulationStrategy<I, O>`) and `SimulationRuntime` are designed to accommodate these deferred items without breaking changes.

## Implementation priority

1. **Foundation:** `simulation-api` (contracts + NoOp @DefaultBean corpus), `simulation-core` (strategies), `simulation-inmem` (in-memory corpus)
2. **Generator:** `simulation-generator` (annotation processor for Path A decorators)
3. **First adapter (Path B):** `SimulatedAgentBackend` implementing `AgentBackend` — highest-value target (blocks 326+, clinical 8 files, engine via blocks). Integrates with `RoutingAgentProvider` via `BackendInstanceRegistry`. (#315)
4. **Second adapter (Path A):** `@SimulationEligible` on `CaseMemoryStore` — second most consumed (7 repos). First use of generated decorator path. (#320)
5. **Corpus filesystem:** `simulation-fs` (YAML fixtures, captured corpora)
6. **Capture/replay:** Record real invocations to corpus, replay via RecordedReplayStrategy (#316)
7. **Event simulation:** `SimulatedEventEmitter` + DataSource integration (#318)
8. **Nearest match:** NearestMatchStrategy implementation (deferred hard problem — #317)
9. **Consumer adoption:** clinical, devtown, aml, fsitrading fixture files and migration guides (#323)

## References

- [platform#294](https://github.com/casehubio/platform/issues/294) — epic
- [GE-20260818-2589ee] — CDI @Decorator must implement all abstract methods
- [GE-20260818-61ed16] — Selective CDI injection controls decorator scope
- [GE-20260817-55c9b2] — CDI @Decorator for transparent callback routing
- [GE-20260806-93549d] — @PostConstruct skipped on @Decorator beans
- [GE-20260529-c4ed43] — Shared @ApplicationScoped kernel across strategies
- [GE-20260620-9d043b] — @Decorator double-application through bridge
- [GE-20260515-ffde26] — Jandex library module pattern
- [GE-20260528-f0a75c] — @DefaultBean BlockingToReactiveBridge pattern
- [GE-20260910-8ecdb7] — Core extraction breaks downstream test constructors
- [GE-20260909-c81437] — module-core/module/module-spring naming convention
- [GE-20260429-a79d0e] — @Alternative @Priority auto-activates
- [GE-20260604-81a6a6] — @DefaultBean @Unremovable required cross-module
- `callback-generator/` — CallbackDecoratorProcessor (decorator generation precedent)
- `platform-api/` package structure — SPI contract patterns
- NoOpAgentProvider, NoOpPreferenceStore — existing NoOp patterns
- Demo SPI Convention — parent/docs/platform/demo-spi-convention.md
- Scenario Format — parent/docs/platform/scenario-format.md
