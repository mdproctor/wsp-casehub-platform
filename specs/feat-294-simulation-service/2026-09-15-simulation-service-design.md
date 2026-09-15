# Simulation Service Design Spec

**Branch:** feat/294-simulation-service
**Epic:** casehubio/platform#294
**Date:** 2026-09-15

## Overview

A generic, domain-agnostic simulation framework for casehub-platform. Any SPI without a real implementation wired at runtime gets configurable simulation behaviour instead of silent no-op responses. The service owns three concerns: **seeding** data into the system, **responding** to invocations via pluggable strategies, and **capturing** real invocations for corpus building.

The service is interface-agnostic. It applies to any part of the system where a real implementation may not be wired — LLMs, banking, connectors, identity providers, memory stores, or any internal SPI. The mechanism is SPI-shaped: if it has inputs and outputs, the simulation strategies can drive it.

## Architecture

### Two modes, one decorator

A single generated `@Decorator` per SPI handles both modes:

- **Simulation mode** — when no real impl is active (the delegate is a NoOp) and a simulation strategy is configured, the decorator resolves a response from the configured strategy instead of delegating to the NoOp.
- **Capture mode** — when a real impl IS active and capture is enabled, the decorator records input/output pairs to a `SimulationCorpus` while passing through to the real implementation.
- **Passthrough** — when neither simulation nor capture is configured, the decorator delegates transparently. Zero overhead in the common case.

NoOp implementations remain untouched — zero-dependency, zero-logic, trivially constructable. The simulation decorator wraps them; it does not modify them.

### Activation

The `@SimulationEligible` annotation on an SPI interface triggers code generation of the `@Decorator`. Configuration at boot time controls behaviour:

```properties
# Enable simulation with key-based lookup strategy
casehub.simulation.agent-provider.strategy=key-lookup

# Enable capture mode (record real invocations)
casehub.simulation.agent-provider.capture=true

# Both can be active simultaneously on different SPIs
casehub.simulation.case-memory-store.strategy=sequential
casehub.simulation.preference-store.capture=true
```

### Module structure

| Module | Packaging | Contains | Depends on |
|--------|-----------|----------|------------|
| `simulation-api` | jar (zero-dep) | SimulationStrategy, SimulationCorpus, InvocationRecord, KeyExtractor, DataRealism, @SimulationEligible | nothing |
| `simulation-core` | jar | Strategy implementations: SequentialStrategy, KeyLookupStrategy, RandomStrategy, RecordedReplayStrategy | simulation-api |
| `simulation-generator` | maven-plugin | SimulationDecoratorProcessor — generates @Decorator per @SimulationEligible SPI | simulation-api, generator-common |
| `simulation-inmem` | jar (Jandex) | InMemorySimulationCorpus @Alternative @Priority(100) | simulation-api |
| `simulation-fs` | jar (Jandex) | FilesystemSimulationCorpus @Alternative (YAML/JSON fixtures, captured corpora) | simulation-api |

Follows the established module naming convention (D2): dedicated `simulation-api` module, not embedded in `platform-api`. Simulation is opt-in — consumers add the modules they need.

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
    Optional<O> lookupByKey(String key);
    Optional<O> lookupByIndex(int index);
    List<InvocationRecord<I, O>> list();
    List<InvocationRecord<I, O>> listByTenant(String tenancyId);
    void record(String tenancyId, I input, O output);
    void record(String tenancyId, String key, I input, O output);
    void seed(List<InvocationRecord<I, O>> records);
    void clear();
    int size();
}
```

Follows the store pattern (D5): NoOp @DefaultBean, InMemory @Alternative, filesystem @Alternative. Tenant-aware per D10 — captured data is scoped to the tenant context of the invocation.

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

Placed on SPI interfaces to trigger decorator generation. The `name` defaults to kebab-case of the interface name (e.g. `AgentProvider` → `agent-provider`). Used as the config key: `casehub.simulation.<name>.strategy=...`.

## Strategy implementations

All in `simulation-core`, constructor-injected POJOs (no CDI annotations).

### SequentialStrategy

Returns responses from a pre-defined list in order. Thread-safe atomic counter.

```java
public class SequentialStrategy<I, O> implements SimulationStrategy<I, O> {
    private final SimulationCorpus<I, O> corpus;
    private final AtomicInteger index = new AtomicInteger(0);
    private final ExhaustionPolicy exhaustionPolicy;

    public O resolve(I input) {
        int i = index.getAndIncrement();
        return corpus.lookupByIndex(i % corpus.size())
            .orElseThrow(() -> new SimulationExhaustedException(...));
    }

    public boolean canResolve(I input) {
        return corpus.size() > 0;
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
    private final KeyExtractor<I> keyExtractor;

    public O resolve(I input) {
        String key = keyExtractor.extract(input);
        return corpus.lookupByKey(key)
            .orElseThrow(() -> new SimulationKeyNotFoundException(key));
    }

    public boolean canResolve(I input) {
        String key = keyExtractor.extract(input);
        return corpus.lookupByKey(key).isPresent();
    }
}
```

Fully deterministic. The key function is SPI-specific — per-SPI adapters provide it.

### RandomStrategy

Samples from corpus or generates on demand.

```java
public class RandomStrategy<I, O> implements SimulationStrategy<I, O> {
    private final SimulationCorpus<I, O> corpus;
    private final Random random;
    private final Supplier<O> generator; // optional on-demand generation

    public O resolve(I input) {
        if (generator != null) return generator.get();
        int i = random.nextInt(corpus.size());
        return corpus.lookupByIndex(i)
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
    private final KeyExtractor<I> keyExtractor;

    public O resolve(I input) {
        String key = keyExtractor.extract(input);
        return corpus.lookupByKey(key)
            .orElseGet(() -> {
                // fallback to sequential if key not found
                return corpus.lookupByIndex(index.getAndIncrement())
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
    private final SimilarityScorer<I> scorer;
    private final double threshold;

    public O resolve(I input) {
        return corpus.list().stream()
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

Maven plugin (sibling to `callback-generator`). Scans Jandex indexes for `@SimulationEligible` interfaces and generates a `@Decorator` for each.

**Generated decorator template:**

```java
@Decorator
@Priority(Interceptor.Priority.APPLICATION + 200)
public class Simulated{SpiName} implements {SpiInterface} {

    @Inject @Delegate @Any {SpiInterface} delegate;
    @Inject SimulationConfig config;
    @Inject Instance<SimulationStrategy<{InputType}, {OutputType}>> strategies;
    @Inject Instance<SimulationCorpus<{InputType}, {OutputType}>> corpuses;

    @Override
    public {ReturnType} {method}({params}) {
        String spiName = "{spi-name}";

        // Simulation mode: strategy configured and delegate is a NoOp
        if (config.strategyFor(spiName).isPresent()) {
            SimulationStrategy<...> strategy = resolveStrategy(spiName);
            {InputType} input = new {InputType}({params});
            if (strategy.canResolve(input)) {
                return strategy.resolve(input);
            }
        }

        // Passthrough + optional capture
        {ReturnType} result = delegate.{method}({params});

        if (config.captureEnabled(spiName)) {
            SimulationCorpus<...> corpus = resolveCorpus(spiName);
            {InputType} input = new {InputType}({params});
            corpus.record(tenancyId, input, result);
        }

        return result;
    }

    // ... all other methods delegate to delegate (GE-20260818-2589ee)
}
```

The generator handles:
- All abstract methods implemented with delegation (avoiding the CDI @Decorator gotcha from GE-20260818-2589ee)
- Lazy initialization pattern (no @PostConstruct — GE-20260806-93549d)
- Idempotency guard for double-application through bridges (GE-20260620-9d043b)
- `@IfBuildProperty` gating for zero-overhead when simulation module is absent

### Per-SPI input/output types

Each `@SimulationEligible` SPI needs typed input/output records. These live alongside the SPI (in the SPI's own module or in a simulation adapter module).

**Example — AgentProvider:**

```java
public record AgentSimulationInput(
    String systemPrompt,
    String userPrompt,
    String model,
    Map<String, Object> config
) {}

// Output is Multi<AgentEvent> — the existing return type
// KeyExtractor strips UUIDs/timestamps from prompts before hashing
```

**Example — CaseMemoryStore:**

```java
public record MemorySimulationInput(
    String tenancyId,
    List<String> entityIds,
    String domain,
    String question,
    MemoryOrder order
) {}

// Output is List<Memory>
```

## Corpus storage

### InMemorySimulationCorpus

`@Alternative @Priority(100)`. `ConcurrentHashMap` keyed by `(spiName, tenancyId, key)`. Thread-safe. Supports concurrent capture from async callers.

### FilesystemSimulationCorpus

`@Alternative @Priority(200)`. Reads YAML/JSON fixture files at startup. Writes captured corpora to configurable directory. Hot-reload for scenario development.

**Fixture file format:**

```yaml
spi: agent-provider
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
- The generated decorator reads `CurrentPrincipal.tenancyId()` for capture context

## Configuration

Per D11, configuration is boot-time via SmallRye Config:

```java
@ConfigMapping(prefix = "casehub.simulation")
public interface SimulationConfig {
    @WithParentName
    Map<String, SpiSimulationConfig> spis();

    interface SpiSimulationConfig {
        Optional<String> strategy();
        @WithDefault("false")
        boolean capture();
        Optional<String> corpusPath();
    }
}
```

Usage in `application.properties`:

```properties
casehub.simulation.agent-provider.strategy=key-lookup
casehub.simulation.agent-provider.corpus-path=classpath:simulation/agent-provider.yaml
casehub.simulation.case-memory-store.strategy=sequential
casehub.simulation.case-memory-store.capture=true
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
    @Inject SimulationStrategy<EventTrigger, CloudEvent> strategy;
    @Inject DataSourceRegistry dataSourceRegistry;

    @Scheduled(every = "{casehub.simulation.events.interval:10s}")
    void emit() {
        EventTrigger trigger = new EventTrigger(...);
        if (strategy.canResolve(trigger)) {
            CloudEvent event = strategy.resolve(trigger);
            dataSourceRegistry.resolve(path).ifPresent(ds -> ds.receive(event));
        }
    }
}
```

## Relationship to existing systems

Per D9, three complementary systems:

| System | Scope | Activation | Data model |
|--------|-------|------------|------------|
| **Demo SPI Convention** | Connector SPIs (ChatPlatform, CalendarPlatform) | `@IfBuildProfile("demo")` — compile-time | Pre-loaded datasets, bootstrap endpoints |
| **Scenario Engine** | Cross-service orchestration | Scenario YAML steps | Step-driven, multi-service |
| **Simulation Service** | Platform SPIs (AgentProvider, CaseMemoryStore, etc.) | Config-driven — runtime | Corpus-backed, 5 strategy modes |

The Scenario Engine can configure simulation strategies as part of scenario setup. The Demo Convention handles connector-level mock data. They do not overlap.

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

## Implementation priority

1. **Foundation:** `simulation-api` (contracts), `simulation-core` (strategies), `simulation-inmem` (in-memory corpus)
2. **Generator:** `simulation-generator` (decorator processor)
3. **First adapter:** `@SimulationEligible` on `AgentProvider` — highest-value target (blocks 326+, clinical 8 files, engine via blocks)
4. **Second adapter:** `@SimulationEligible` on `CaseMemoryStore` — second most consumed (7 repos)
5. **Corpus filesystem:** `simulation-fs` (YAML fixtures, captured corpora)
6. **Event simulation:** `SimulatedEventEmitter` + DataSource integration
7. **Nearest match:** NearestMatchStrategy implementation (deferred hard problem)
8. **Consumer adoption:** clinical, devtown, aml, fsitrading fixture files and migration guides

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
