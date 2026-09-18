# NearestMatchStrategy Design Spec

**Branch:** issue-294-simulation-service
**Issue:** casehubio/platform#317
**Date:** 2026-09-16

## Overview

Add a `nearest-match` strategy to the simulation framework. When an invocation input doesn't have an exact key match in the corpus, NearestMatchStrategy scores all corpus entries against the input and returns the best match above a configurable threshold. This handles inputs that vary between runs (different UUIDs, amounts, entity names) while the response shape remains stable.

## Core contracts

### SimilarityScorer

New `@FunctionalInterface` in `simulation-api`:

```java
package io.casehub.platform.simulation;

@FunctionalInterface
public interface SimilarityScorer<I> {
    double score(I query, I candidate);
}
```

Returns a value in [0.0, 1.0] where 1.0 is a perfect match and 0.0 is no match. Parallel to `KeyExtractor<I>` — per-SPI, registered programmatically via `SimulationRuntime.registerScorer()`.

### NearestMatchStrategy

New strategy in `simulation-core`:

```java
package io.casehub.platform.simulation.strategy;

public final class NearestMatchStrategy<I, O> implements SimulationStrategy<I, O> {

    private final SimulationCorpus<I, O> corpus;
    private final String qualifiedName;
    private final SimilarityScorer<I> scorer;
    private final double threshold;

    public NearestMatchStrategy(SimulationCorpus<I, O> corpus,
                                String qualifiedName,
                                SimilarityScorer<I> scorer,
                                double threshold) { ... }

    @Override
    public O resolve(I input) {
        // O(n) scan: score every corpus entry, return best above threshold
        return corpus.list(qualifiedName).stream()
            .map(r -> new ScoredMatch<>(r, scorer.score(input, r.input())))
            .filter(m -> m.score() >= threshold)
            .max(Comparator.comparingDouble(ScoredMatch::score))
            .map(m -> m.record().output())
            .orElseThrow(() -> new SimulationNoMatchException(qualifiedName, threshold));
    }

    @Override
    public boolean canResolve(I input) {
        return corpus.list(qualifiedName).stream()
            .anyMatch(r -> scorer.score(input, r.input()) >= threshold);
    }

    private record ScoredMatch<I, O>(InvocationRecord<I, O> record, double score) {}
}
```

**Thread safety:** `corpus.list()` returns `List.copyOf()` snapshots (InMemorySimulationCorpus already does this). Concurrent corpus growth during capture mode is safe.

**Performance:** O(n) scan per invocation. Corpora are small (10-50 entries in test fixtures). For 50 entries with a simple field scorer, sub-millisecond. Indexing is a follow-on if needed — the strategy contract doesn't change.

### SimulationNoMatchException

New exception in `simulation-api`:

```java
package io.casehub.platform.simulation;

public class SimulationNoMatchException extends RuntimeException {
    private final String qualifiedName;
    private final double threshold;

    public SimulationNoMatchException(String qualifiedName, double threshold) {
        super("No corpus entry for " + qualifiedName + " scored above threshold " + threshold);
        this.qualifiedName = qualifiedName;
        this.threshold = threshold;
    }

    public String qualifiedName() { return qualifiedName; }
    public double threshold() { return threshold; }
}
```

## Built-in field scorer

### RecordFieldScorer

Convenience implementation in `simulation-core` for the common case: decompose a Java record/POJO into fields, score each field independently, combine with weighted sum.

```java
package io.casehub.platform.simulation.strategy;

public final class RecordFieldScorer<I> implements SimilarityScorer<I> {

    private final List<FieldSpec> fields;
    private final ObjectMapper mapper;

    private RecordFieldScorer(List<FieldSpec> fields, ObjectMapper mapper) { ... }

    @Override
    public double score(I query, I candidate) {
        Map<String, Object> queryMap = mapper.convertValue(query, MAP_TYPE);
        Map<String, Object> candidateMap = mapper.convertValue(candidate, MAP_TYPE);

        double weightedSum = 0.0;
        double totalWeight = 0.0;
        for (FieldSpec field : fields) {
            Object qVal = queryMap.get(field.name());
            Object cVal = candidateMap.get(field.name());
            weightedSum += field.weight() * field.scorer().score(qVal, cVal);
            totalWeight += field.weight();
        }
        return totalWeight > 0.0 ? weightedSum / totalWeight : 0.0;
    }

    public static <I> Builder<I> builder() { return new Builder<>(); }

    public static final class Builder<I> {
        public Builder<I> field(String name, FieldSimilarity scorer, double weight) { ... }
        public RecordFieldScorer<I> build() { ... }
    }

    record FieldSpec(String name, FieldSimilarity scorer, double weight) {}
}
```

Uses Jackson `ObjectMapper.convertValue()` for field decomposition — same mechanism as `DeclarativeExtractorFactory` (D16).

### FieldSimilarity

Built-in per-field scoring functions:

```java
package io.casehub.platform.simulation.strategy;

@FunctionalInterface
public interface FieldSimilarity {
    double score(Object queryValue, Object candidateValue);

    FieldSimilarity EXACT = (q, c) ->
        Objects.equals(q, c) ? 1.0 : 0.0;

    FieldSimilarity SUBSTRING = (q, c) -> {
        if (q == null || c == null) return q == c ? 1.0 : 0.0;
        String qs = q.toString(), cs = c.toString();
        if (qs.equals(cs)) return 1.0;
        if (qs.contains(cs) || cs.contains(qs)) return 0.8;
        return 0.0;
    };

    FieldSimilarity NUMERIC_RANGE = (q, c) -> {
        if (!(q instanceof Number qn) || !(c instanceof Number cn)) return 0.0;
        double diff = Math.abs(qn.doubleValue() - cn.doubleValue());
        double max = Math.max(Math.abs(qn.doubleValue()), Math.abs(cn.doubleValue()));
        return max == 0.0 ? 1.0 : Math.max(0.0, 1.0 - diff / max);
    };

    FieldSimilarity IGNORE = (q, c) -> 1.0;
}
```

### Usage example — programmatic

```java
// At startup — register scorer for case-memory-store.query
simulation.registerScorer("case-memory-store.query",
    RecordFieldScorer.<MemoryQuery>builder()
        .field("domain", FieldSimilarity.EXACT, 1.0)
        .field("question", FieldSimilarity.SUBSTRING, 0.5)
        .field("limit", FieldSimilarity.IGNORE, 0.0)
        .build());
```

```properties
# application.properties
casehub.simulation.case-memory-store.query.strategy=nearest-match
casehub.simulation.case-memory-store.query.threshold=0.7
```

## Declarative configuration

### DeclarativeScorerFactory

New class in `simulation-config-core`, parallel to `DeclarativeExtractorFactory`:

```java
package io.casehub.platform.simulation.config;

public class DeclarativeScorerFactory {

    public <I> SimilarityScorer<I> create(String spec) {
        // Format: "fields:name:scorer:weight,name:scorer:weight,..."
        // Example: "fields:domain:exact:1.0,question:substring:0.5"
        ...
    }
}
```

Parses config string → `RecordFieldScorer` instance. Scorer names map to `FieldSimilarity` constants: `exact`, `substring`, `numeric-range`, `ignore`.

### Config property

```properties
casehub.simulation.case-memory-store.query.scorer=fields:domain:exact:1.0,question:substring:0.5
```

Added to `MethodSimulationConfig.set()` as a new `"scorer"` property. `SimulationConfigBeans.onStartup()` reads scorer specs and registers them via `DeclarativeScorerFactory` — same wiring pattern as declarative extractors.

### Threshold config

```properties
casehub.simulation.case-memory-store.query.threshold=0.7
```

Added to `MethodSimulationConfig` and exposed via new `SimulationConfig.threshold(String qualifiedName)` method (returns `Optional<Double>`, default 0.0).

## Integration with SimulationRuntime

### Registration

New method on `SimulationRuntime`:

```java
public <I> void registerScorer(String qualifiedName, SimilarityScorer<I> scorer) {
    scorers.put(qualifiedName, scorer);
}
```

Parallel to `registerExtractor()`. Stored in a `ConcurrentHashMap<String, SimilarityScorer<?>>`.

### Strategy factory

Add `"nearest-match"` case to `createStrategy()`:

```java
case "nearest-match" -> {
    SimilarityScorer scorer = requireScorer(qualifiedName);
    double threshold = config.threshold(qualifiedName).orElse(0.0);
    yield new NearestMatchStrategy<>(corpus, qualifiedName, scorer, threshold);
}
```

`requireScorer()` follows the `requireExtractor()` pattern — throws `SimulationConfigException` if no scorer registered.

## Module placement

All changes to existing modules — no new module needed:

| Change | Module |
|--------|--------|
| `SimilarityScorer<I>` | simulation-api |
| `SimulationNoMatchException` | simulation-api |
| `NearestMatchStrategy` | simulation-core |
| `RecordFieldScorer`, `FieldSimilarity` | simulation-core |
| `SimulationRuntime.registerScorer()` | simulation-core |
| `SimulationConfig.threshold()` | simulation-core |
| `DeclarativeScorerFactory` | simulation-config-core |
| `MethodSimulationConfig` (scorer, threshold) | simulation-config-core |
| `SimulationConfigBeans` (startup wiring) | simulation-config |

## Relationship to CBR

NearestMatchStrategy and CBR's `CbrSimilarityScorer` are structurally parallel but independent (D17). CBR integration is a consumer concern:

```java
// Bridge — implement SimilarityScorer using CBR infrastructure
SimilarityScorer<MemoryQuery> cbrBridge = (q1, q2) -> {
    var queryFeatures = extractFeatures(q1);
    var caseFeatures = extractFeatures(q2);
    return CbrSimilarityScorer.score(queryFeatures, caseFeatures, weights, schema);
};
simulation.registerScorer("case-memory-store.query", cbrBridge);
```

This keeps simulation-core zero-dep on neocortex while allowing full CBR power when needed.

## Scope

This spec covers `NearestMatchStrategy` and its supporting infrastructure. Not in scope:

- Vector embeddings / semantic similarity — follow-on enhancement to `FieldSimilarity`
- Corpus indexing for large corpora — follow-on optimisation
- Per-scenario scorer overrides — deferred to #322 (runtime strategy switching)

## References

- [2026-09-15-simulation-service-design.md] — parent design spec (NearestMatchStrategy sketch, SimilarityScorer interface)
- [decisions.md] — D17 (generic scorer), D18 (programmatic + declarative), D19 (threshold/no-match), D20 (O(n) scan)
- [CbrSimilarityScorer.java (neocortex-memory-api)] — CBR similarity infrastructure
- [LocalSimilarityFunction.java] — CBR per-field scoring
- [SimilaritySpec.java, FeatureField.java] — CBR type system (not reused)
- [DeclarativeExtractorFactory.java] — parallel declarative pattern
- [KeyLookupStrategy.java] — existing strategy pattern
- [SimulationRuntime.java] — integration point (createStrategy, registerScorer)
- [GitHub #317] — focal issue
- [GitHub #329, #330] — downstream declarative configuration issues
