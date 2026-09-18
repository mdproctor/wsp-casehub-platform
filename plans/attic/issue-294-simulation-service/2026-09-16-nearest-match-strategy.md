# NearestMatchStrategy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #317 — nearest-match strategy — constraint weighting and similarity scoring
**Issue group:** #317

**Goal:** Add a `nearest-match` strategy that scores corpus entries against invocation inputs and returns the best match above a configurable threshold.

**Architecture:** `SimilarityScorer<I>` functional interface in simulation-api (parallel to `KeyExtractor<I>`). `NearestMatchStrategy` in simulation-core does O(n) corpus scan. `RecordFieldScorer` in simulation-config-core provides field-based scoring via Jackson decomposition. `DeclarativeScorerFactory` parses config strings into scorer instances.

**Tech Stack:** Java 21, Jackson (ObjectMapper.convertValue in simulation-config-core only), JUnit 5, AssertJ

## Global Constraints

- `simulation-api` must remain zero-dependency (pure Java)
- `simulation-core` must remain zero-dependency beyond simulation-api
- `RecordFieldScorer` lives in simulation-config-core (not simulation-core) because it uses Jackson
- All similarity scores in [0.0, 1.0] — 1.0 = perfect match, 0.0 = no match

---

## Batch 1: Core strategy — NearestMatch works with programmatic scorers

### Task 1: SimilarityScorer + NearestMatchStrategy + SimulationRuntime integration

Add the core nearest-match capability: the SPI interface, the strategy implementation, and the runtime integration. After this task, NearestMatch works end-to-end with programmatically registered scorers.

**Files:**
- Create: `simulation-api/src/main/java/io/casehub/platform/simulation/SimilarityScorer.java`
- Create: `simulation-api/src/main/java/io/casehub/platform/simulation/SimulationNoMatchException.java`
- Create: `simulation-core/src/main/java/io/casehub/platform/simulation/strategy/NearestMatchStrategy.java`
- Modify: `simulation-core/src/main/java/io/casehub/platform/simulation/SimulationRuntime.java`
- Modify: `simulation-core/src/main/java/io/casehub/platform/simulation/SimulationConfig.java`
- Create: `simulation-core/src/test/java/io/casehub/platform/simulation/strategy/NearestMatchStrategyTest.java`
- Modify: `simulation-core/src/test/java/io/casehub/platform/simulation/SimulationRuntimeTest.java`

**Interfaces:**
- Produces: `SimilarityScorer<I>` (`double score(I query, I candidate)`)
- Produces: `NearestMatchStrategy<I, O>` constructor: `(SimulationCorpus, String qualifiedName, SimilarityScorer, double threshold)`
- Produces: `SimulationRuntime.registerScorer(String qualifiedName, SimilarityScorer<I> scorer)`
- Produces: `SimulationConfig.threshold(String qualifiedName)` → `Optional<Double>`

- [ ] **Step 1: Create SimilarityScorer interface**

```java
// simulation-api/src/main/java/io/casehub/platform/simulation/SimilarityScorer.java
package io.casehub.platform.simulation;

@FunctionalInterface
public interface SimilarityScorer<I> {

    double score(I query, I candidate);
}
```

- [ ] **Step 2: Create SimulationNoMatchException**

```java
// simulation-api/src/main/java/io/casehub/platform/simulation/SimulationNoMatchException.java
package io.casehub.platform.simulation;

public class SimulationNoMatchException extends RuntimeException {

    private final String qualifiedName;
    private final double threshold;

    public SimulationNoMatchException(final String qualifiedName, final double threshold) {
        super("No corpus entry for " + qualifiedName + " scored above threshold " + threshold);
        this.qualifiedName = qualifiedName;
        this.threshold = threshold;
    }

    public String getQualifiedName() { return qualifiedName; }

    public double getThreshold() { return threshold; }
}
```

- [ ] **Step 3: Write failing tests for NearestMatchStrategy**

```java
// simulation-core/src/test/java/.../strategy/NearestMatchStrategyTest.java
package io.casehub.platform.simulation.strategy;

import io.casehub.platform.simulation.SimilarityScorer;
import io.casehub.platform.simulation.SimulationNoMatchException;
import org.junit.jupiter.api.Test;

import static io.casehub.platform.simulation.strategy.ListBackedCorpus.entry;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class NearestMatchStrategyTest {

    private static final String QN = "test-spi.method";

    @Test
    void bestMatchAboveThresholdIsReturned() {
        var corpus = ListBackedCorpus.of(
                entry("k1", "alpha", "result-alpha"),
                entry("k2", "beta", "result-beta"),
                entry("k3", "alphabet", "result-alphabet"));

        SimilarityScorer<String> scorer = (q, c) -> {
            if (q.equals(c)) return 1.0;
            if (q.startsWith(c) || c.startsWith(q)) return 0.7;
            return 0.0;
        };

        var strategy = new NearestMatchStrategy<>(corpus, QN, scorer, 0.5);

        assertThat(strategy.resolve("alpha")).isEqualTo("result-alpha");
    }

    @Test
    void higherScoreWinsOverLowerScore() {
        var corpus = ListBackedCorpus.of(
                entry("k1", "abc", "result-abc"),
                entry("k2", "abcdef", "result-abcdef"));

        SimilarityScorer<String> scorer = (q, c) -> {
            int common = 0;
            for (int i = 0; i < Math.min(q.length(), c.length()); i++) {
                if (q.charAt(i) == c.charAt(i)) common++;
            }
            return (double) common / Math.max(q.length(), c.length());
        };

        var strategy = new NearestMatchStrategy<>(corpus, QN, scorer, 0.0);

        assertThat(strategy.resolve("abcde")).isEqualTo("result-abcdef");
    }

    @Test
    void noMatchAboveThresholdThrowsException() {
        var corpus = ListBackedCorpus.of(
                entry("k1", "alpha", "result-alpha"));

        SimilarityScorer<String> scorer = (q, c) -> 0.1;

        var strategy = new NearestMatchStrategy<>(corpus, QN, scorer, 0.5);

        assertThatThrownBy(() -> strategy.resolve("unrelated"))
                .isInstanceOf(SimulationNoMatchException.class);
    }

    @Test
    void canResolveReturnsTrueWhenMatchAboveThreshold() {
        var corpus = ListBackedCorpus.of(
                entry("k1", "alpha", "result-alpha"));

        SimilarityScorer<String> scorer = (q, c) -> 0.9;

        var strategy = new NearestMatchStrategy<>(corpus, QN, scorer, 0.5);

        assertThat(strategy.canResolve("anything")).isTrue();
    }

    @Test
    void canResolveReturnsFalseWhenNoMatchAboveThreshold() {
        var corpus = ListBackedCorpus.of(
                entry("k1", "alpha", "result-alpha"));

        SimilarityScorer<String> scorer = (q, c) -> 0.1;

        var strategy = new NearestMatchStrategy<>(corpus, QN, scorer, 0.5);

        assertThat(strategy.canResolve("anything")).isFalse();
    }

    @Test
    void emptyCorpusCannotResolve() {
        var corpus = ListBackedCorpus.<String, String>of();

        SimilarityScorer<String> scorer = (q, c) -> 1.0;

        var strategy = new NearestMatchStrategy<>(corpus, QN, scorer, 0.0);

        assertThat(strategy.canResolve("anything")).isFalse();
    }
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `mvn --batch-mode -pl simulation-core test -Dtest=NearestMatchStrategyTest`
Expected: FAIL — `NearestMatchStrategy` does not exist yet

- [ ] **Step 5: Implement NearestMatchStrategy**

```java
// simulation-core/src/main/java/.../strategy/NearestMatchStrategy.java
package io.casehub.platform.simulation.strategy;

import io.casehub.platform.simulation.InvocationRecord;
import io.casehub.platform.simulation.SimilarityScorer;
import io.casehub.platform.simulation.SimulationCorpus;
import io.casehub.platform.simulation.SimulationNoMatchException;
import io.casehub.platform.simulation.SimulationStrategy;

import java.util.Comparator;

public final class NearestMatchStrategy<I, O> implements SimulationStrategy<I, O> {

    private final SimulationCorpus<I, O> corpus;
    private final String qualifiedName;
    private final SimilarityScorer<I> scorer;
    private final double threshold;

    public NearestMatchStrategy(final SimulationCorpus<I, O> corpus,
                                final String qualifiedName,
                                final SimilarityScorer<I> scorer,
                                final double threshold) {
        this.corpus = corpus;
        this.qualifiedName = qualifiedName;
        this.scorer = scorer;
        this.threshold = threshold;
    }

    @Override
    public O resolve(final I input) {
        return corpus.list(qualifiedName).stream()
                .map(r -> new ScoredMatch<>(r, scorer.score(input, r.input())))
                .filter(m -> m.score() >= threshold)
                .max(Comparator.comparingDouble(ScoredMatch::score))
                .map(m -> m.record().output())
                .orElseThrow(() -> new SimulationNoMatchException(qualifiedName, threshold));
    }

    @Override
    public boolean canResolve(final I input) {
        return corpus.list(qualifiedName).stream()
                .anyMatch(r -> scorer.score(input, r.input()) >= threshold);
    }

    private record ScoredMatch<I, O>(InvocationRecord<I, O> record, double score) {}
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mvn --batch-mode -pl simulation-core test -Dtest=NearestMatchStrategyTest`
Expected: ALL PASS

- [ ] **Step 7: Add threshold() to SimulationConfig + registerScorer/createStrategy to SimulationRuntime**

Add to `SimulationConfig.java`:

```java
default Optional<Double> threshold(String qualifiedName) {
    return Optional.empty();
}
```

Add to `SimulationRuntime.java`:

```java
// New field
private final ConcurrentHashMap<String, SimilarityScorer<?>> scorers = new ConcurrentHashMap<>();

// New registration method
public <I> void registerScorer(final String qualifiedName, final SimilarityScorer<I> scorer) {
    scorers.put(qualifiedName, scorer);
}

// New case in createStrategy switch
case "nearest-match" -> {
    final SimilarityScorer scorer = requireScorer(qualifiedName);
    final double threshold = config.threshold(qualifiedName).orElse(0.0);
    yield new NearestMatchStrategy<>(corpus, qualifiedName, scorer, threshold);
}

// New helper
private SimilarityScorer<?> requireScorer(final String qualifiedName) {
    final SimilarityScorer<?> scorer = scorers.get(qualifiedName);
    if (scorer == null) {
        throw new SimulationConfigException(
                "Strategy for " + qualifiedName + " requires a SimilarityScorer, but none registered");
    }
    return scorer;
}
```

Import `NearestMatchStrategy` and `SimilarityScorer` in SimulationRuntime.

- [ ] **Step 8: Add SimulationRuntime integration test**

Add test to `SimulationRuntimeTest.java`:

```java
@Test
void nearestMatchStrategyResolvesFromRegisteredScorer() {
    var config = new TestSimulationConfig(Map.of("test-spi.find", "nearest-match"));
    var corpus = new InMemorySimulationCorpus<>();
    var runtime = new SimulationRuntime(config, corpus);

    runtime.registerScorer("test-spi.find",
            (SimilarityScorer<String>) (q, c) -> q.equals(c) ? 1.0 : 0.0);

    corpus.seed("test-spi.find", List.of(
            new InvocationRecord<>("t1", null, "hello", "world", Instant.now())));

    Optional<SimulationStrategy<String, String>> strategy = runtime.strategyFor("test-spi.find");
    assertThat(strategy).isPresent();
    assertThat(strategy.get().resolve("hello")).isEqualTo("world");
}
```

- [ ] **Step 9: Run all simulation-api + simulation-core tests**

Run: `mvn --batch-mode -pl simulation-api,simulation-core test`
Expected: ALL PASS

- [ ] **Step 10: Commit**

```bash
git add simulation-api/src/ simulation-core/src/
git commit -m "feat(#317): SimilarityScorer + NearestMatchStrategy

SimilarityScorer<I> functional interface in simulation-api.
NearestMatchStrategy in simulation-core — O(n) corpus scan,
threshold-based matching, canResolve/resolve contract.
SimulationRuntime extended with registerScorer() and
nearest-match strategy factory case.

Refs #317

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

## Batch 2: Built-in field scorer + declarative config

### Task 2: FieldSimilarity + RecordFieldScorer + DeclarativeScorerFactory

Add the built-in field-based scorer and the declarative config factory. After this task, scorers can be configured via application.properties alongside programmatic registration.

**Files:**
- Create: `simulation-config-core/src/main/java/io/casehub/platform/simulation/config/FieldSimilarity.java`
- Create: `simulation-config-core/src/main/java/io/casehub/platform/simulation/config/RecordFieldScorer.java`
- Create: `simulation-config-core/src/main/java/io/casehub/platform/simulation/config/DeclarativeScorerFactory.java`
- Modify: `simulation-config-core/src/main/java/io/casehub/platform/simulation/config/MethodSimulationConfig.java`
- Modify: `simulation-config-core/src/main/java/io/casehub/platform/simulation/config/SmallRyeSimulationConfig.java`
- Modify: `simulation-config/src/main/java/io/casehub/platform/simulation/config/quarkus/SimulationConfigBeans.java`
- Create: `simulation-config-core/src/test/java/io/casehub/platform/simulation/config/FieldSimilarityTest.java`
- Create: `simulation-config-core/src/test/java/io/casehub/platform/simulation/config/RecordFieldScorerTest.java`
- Create: `simulation-config-core/src/test/java/io/casehub/platform/simulation/config/DeclarativeScorerFactoryTest.java`

**Interfaces:**
- Consumes: `SimilarityScorer<I>` from Task 1
- Consumes: `SimulationRuntime.registerScorer()` from Task 1
- Consumes: `SimulationConfig.threshold()` from Task 1
- Produces: `FieldSimilarity` (EXACT, SUBSTRING, NUMERIC_RANGE, IGNORE constants)
- Produces: `RecordFieldScorer.builder().field(name, scorer, weight).build()`
- Produces: `DeclarativeScorerFactory.create(String spec)` → `SimilarityScorer<Object>`

- [ ] **Step 1: Write FieldSimilarity tests**

```java
// simulation-config-core/src/test/java/.../config/FieldSimilarityTest.java
package io.casehub.platform.simulation.config;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class FieldSimilarityTest {

    @Test
    void exactMatchScoresOneForEqual() {
        assertThat(FieldSimilarity.EXACT.score("hello", "hello")).isEqualTo(1.0);
    }

    @Test
    void exactMatchScoresZeroForDifferent() {
        assertThat(FieldSimilarity.EXACT.score("hello", "world")).isEqualTo(0.0);
    }

    @Test
    void exactMatchHandlesNulls() {
        assertThat(FieldSimilarity.EXACT.score(null, null)).isEqualTo(1.0);
        assertThat(FieldSimilarity.EXACT.score(null, "x")).isEqualTo(0.0);
    }

    @Test
    void substringScoresOneForExactMatch() {
        assertThat(FieldSimilarity.SUBSTRING.score("hello", "hello")).isEqualTo(1.0);
    }

    @Test
    void substringScoresPartialForContainment() {
        assertThat(FieldSimilarity.SUBSTRING.score("hello world", "hello")).isEqualTo(0.8);
        assertThat(FieldSimilarity.SUBSTRING.score("hello", "hello world")).isEqualTo(0.8);
    }

    @Test
    void substringScoresZeroForNoOverlap() {
        assertThat(FieldSimilarity.SUBSTRING.score("hello", "world")).isEqualTo(0.0);
    }

    @Test
    void numericRangeScoresOneForEqual() {
        assertThat(FieldSimilarity.NUMERIC_RANGE.score(100, 100)).isEqualTo(1.0);
    }

    @Test
    void numericRangeDecaysWithDistance() {
        double score = FieldSimilarity.NUMERIC_RANGE.score(100, 150);
        assertThat(score).isGreaterThan(0.0).isLessThan(1.0);
    }

    @Test
    void numericRangeScoresZeroForNonNumeric() {
        assertThat(FieldSimilarity.NUMERIC_RANGE.score("hello", 100)).isEqualTo(0.0);
    }

    @Test
    void ignoreAlwaysScoresOne() {
        assertThat(FieldSimilarity.IGNORE.score("anything", "else")).isEqualTo(1.0);
        assertThat(FieldSimilarity.IGNORE.score(null, null)).isEqualTo(1.0);
    }
}
```

- [ ] **Step 2: Implement FieldSimilarity**

```java
// simulation-config-core/src/main/java/.../config/FieldSimilarity.java
package io.casehub.platform.simulation.config;

import java.util.Objects;

@FunctionalInterface
public interface FieldSimilarity {

    double score(Object queryValue, Object candidateValue);

    FieldSimilarity EXACT = (q, c) -> Objects.equals(q, c) ? 1.0 : 0.0;

    FieldSimilarity SUBSTRING = (q, c) -> {
        if (q == null || c == null) return Objects.equals(q, c) ? 1.0 : 0.0;
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

- [ ] **Step 3: Run FieldSimilarity tests**

Run: `mvn --batch-mode -pl simulation-config-core test -Dtest=FieldSimilarityTest`
Expected: ALL PASS

- [ ] **Step 4: Write RecordFieldScorer tests**

```java
// simulation-config-core/src/test/java/.../config/RecordFieldScorerTest.java
package io.casehub.platform.simulation.config;

import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.within;

class RecordFieldScorerTest {

    @Test
    void singleExactFieldScoresCorrectly() {
        var scorer = RecordFieldScorer.<Map<String, Object>>builder()
                .field("domain", FieldSimilarity.EXACT, 1.0)
                .build();

        double match = scorer.score(
                Map.of("domain", "test"),
                Map.of("domain", "test"));
        double miss = scorer.score(
                Map.of("domain", "test"),
                Map.of("domain", "other"));

        assertThat(match).isEqualTo(1.0);
        assertThat(miss).isEqualTo(0.0);
    }

    @Test
    void weightedMultiFieldScoring() {
        var scorer = RecordFieldScorer.<Map<String, Object>>builder()
                .field("domain", FieldSimilarity.EXACT, 1.0)
                .field("question", FieldSimilarity.EXACT, 0.5)
                .build();

        double score = scorer.score(
                Map.of("domain", "test", "question", "how?"),
                Map.of("domain", "test", "question", "what?"));

        // domain matches (1.0 * 1.0) + question misses (0.0 * 0.5) = 1.0
        // total weight = 1.5, weighted avg = 1.0 / 1.5 ≈ 0.667
        assertThat(score).isCloseTo(0.667, within(0.01));
    }

    @Test
    void missingFieldScoresZero() {
        var scorer = RecordFieldScorer.<Map<String, Object>>builder()
                .field("domain", FieldSimilarity.EXACT, 1.0)
                .build();

        double score = scorer.score(
                Map.of("domain", "test"),
                Map.of("other", "value"));

        assertThat(score).isEqualTo(0.0);
    }

    @Test
    void worksWithRecordTypes() {
        record QueryInput(String domain, int limit) {}

        var scorer = RecordFieldScorer.<QueryInput>builder()
                .field("domain", FieldSimilarity.EXACT, 1.0)
                .field("limit", FieldSimilarity.IGNORE, 0.0)
                .build();

        double score = scorer.score(
                new QueryInput("test", 10),
                new QueryInput("test", 50));

        assertThat(score).isEqualTo(1.0);
    }
}
```

- [ ] **Step 5: Implement RecordFieldScorer**

```java
// simulation-config-core/src/main/java/.../config/RecordFieldScorer.java
package io.casehub.platform.simulation.config;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;
import io.casehub.platform.simulation.SimilarityScorer;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

public final class RecordFieldScorer<I> implements SimilarityScorer<I> {

    private static final TypeReference<Map<String, Object>> MAP_TYPE =
            new TypeReference<>() {};

    private final List<FieldSpec> fields;
    private final ObjectMapper mapper;

    private RecordFieldScorer(final List<FieldSpec> fields, final ObjectMapper mapper) {
        this.fields = List.copyOf(fields);
        this.mapper = mapper;
    }

    @Override
    @SuppressWarnings("unchecked")
    public double score(final I query, final I candidate) {
        final Map<String, Object> queryMap = toMap(query);
        final Map<String, Object> candidateMap = toMap(candidate);

        double weightedSum = 0.0;
        double totalWeight = 0.0;
        for (final FieldSpec field : fields) {
            final Object qVal = queryMap.get(field.name());
            final Object cVal = candidateMap.get(field.name());
            weightedSum += field.weight() * field.scorer().score(qVal, cVal);
            totalWeight += field.weight();
        }
        return totalWeight > 0.0 ? weightedSum / totalWeight : 0.0;
    }

    @SuppressWarnings("unchecked")
    private Map<String, Object> toMap(final Object input) {
        if (input instanceof Map) {
            return (Map<String, Object>) input;
        }
        return mapper.convertValue(input, MAP_TYPE);
    }

    public static <I> Builder<I> builder() {
        return new Builder<>();
    }

    public static final class Builder<I> {
        private final List<FieldSpec> fields = new ArrayList<>();

        public Builder<I> field(final String name, final FieldSimilarity scorer,
                                final double weight) {
            fields.add(new FieldSpec(name, scorer, weight));
            return this;
        }

        public RecordFieldScorer<I> build() {
            final ObjectMapper mapper = new ObjectMapper();
            mapper.registerModule(new JavaTimeModule());
            return new RecordFieldScorer<>(fields, mapper);
        }
    }

    record FieldSpec(String name, FieldSimilarity scorer, double weight) {}
}
```

- [ ] **Step 6: Run RecordFieldScorer tests**

Run: `mvn --batch-mode -pl simulation-config-core test -Dtest=RecordFieldScorerTest`
Expected: ALL PASS

- [ ] **Step 7: Write DeclarativeScorerFactory tests**

```java
// simulation-config-core/src/test/java/.../config/DeclarativeScorerFactoryTest.java
package io.casehub.platform.simulation.config;

import io.casehub.platform.simulation.SimulationConfigException;
import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.assertj.core.api.Assertions.within;

class DeclarativeScorerFactoryTest {

    private final DeclarativeScorerFactory factory = new DeclarativeScorerFactory();

    @Test
    void singleExactField() {
        var scorer = factory.create("fields:domain:exact:1.0");

        double match = scorer.score(
                Map.of("domain", "test"),
                Map.of("domain", "test"));

        assertThat(match).isEqualTo(1.0);
    }

    @Test
    void multipleFieldsParsed() {
        var scorer = factory.create("fields:domain:exact:1.0,question:substring:0.5");

        double score = scorer.score(
                Map.of("domain", "test", "question", "how?"),
                Map.of("domain", "test", "question", "what?"));

        // domain matches (1.0 * 1.0) + question misses (0.0 * 0.5) = 1.0
        // total weight = 1.5, weighted avg = 1.0 / 1.5 ≈ 0.667
        assertThat(score).isCloseTo(0.667, within(0.01));
    }

    @Test
    void numericRangeField() {
        var scorer = factory.create("fields:amount:numeric-range:1.0");

        double score = scorer.score(
                Map.of("amount", 100),
                Map.of("amount", 100));

        assertThat(score).isEqualTo(1.0);
    }

    @Test
    void ignoreField() {
        var scorer = factory.create("fields:id:ignore:0.0,name:exact:1.0");

        double score = scorer.score(
                Map.of("id", "abc", "name", "test"),
                Map.of("id", "xyz", "name", "test"));

        assertThat(score).isEqualTo(1.0);
    }

    @Test
    void unknownScorerThrows() {
        assertThatThrownBy(() -> factory.create("fields:name:unknown:1.0"))
                .isInstanceOf(SimulationConfigException.class);
    }

    @Test
    void unknownFormatThrows() {
        assertThatThrownBy(() -> factory.create("invalid-spec"))
                .isInstanceOf(SimulationConfigException.class);
    }
}
```

- [ ] **Step 8: Implement DeclarativeScorerFactory**

```java
// simulation-config-core/src/main/java/.../config/DeclarativeScorerFactory.java
package io.casehub.platform.simulation.config;

import io.casehub.platform.simulation.SimilarityScorer;
import io.casehub.platform.simulation.SimulationConfigException;

public class DeclarativeScorerFactory {

    public SimilarityScorer<Object> create(final String spec) {
        if (!spec.startsWith("fields:")) {
            throw new SimulationConfigException(
                    "Unknown scorer spec: " + spec + ". Valid: fields:<name>:<scorer>:<weight>,..."
            );
        }

        final String fieldsDef = spec.substring("fields:".length());
        final String[] fieldSpecs = fieldsDef.split(",");
        final RecordFieldScorer.Builder<Object> builder = RecordFieldScorer.builder();

        for (final String fieldSpec : fieldSpecs) {
            final String[] parts = fieldSpec.split(":");
            if (parts.length != 3) {
                throw new SimulationConfigException(
                        "Invalid field spec: " + fieldSpec + ". Expected: <name>:<scorer>:<weight>");
            }
            final String name = parts[0];
            final FieldSimilarity scorer = resolveScorer(parts[1]);
            final double weight = Double.parseDouble(parts[2]);
            builder.field(name, scorer, weight);
        }

        return builder.build();
    }

    private FieldSimilarity resolveScorer(final String name) {
        return switch (name) {
            case "exact" -> FieldSimilarity.EXACT;
            case "substring" -> FieldSimilarity.SUBSTRING;
            case "numeric-range" -> FieldSimilarity.NUMERIC_RANGE;
            case "ignore" -> FieldSimilarity.IGNORE;
            default -> throw new SimulationConfigException(
                    "Unknown field scorer: " + name + ". Valid: exact, substring, numeric-range, ignore");
        };
    }
}
```

- [ ] **Step 9: Run DeclarativeScorerFactory tests**

Run: `mvn --batch-mode -pl simulation-config-core test -Dtest=DeclarativeScorerFactoryTest`
Expected: ALL PASS

- [ ] **Step 10: Add scorer + threshold to MethodSimulationConfig and SmallRyeSimulationConfig**

In `MethodSimulationConfig.java`, add:

```java
// New field
private String scorer;
private Double threshold;

// New accessors
Optional<String> scorer() {
    return Optional.ofNullable(scorer);
}

Optional<Double> threshold() {
    return Optional.ofNullable(threshold);
}

// In set() switch, add:
case "scorer" -> this.scorer = value;
case "threshold" -> this.threshold = Double.parseDouble(value);
```

In `SmallRyeSimulationConfig.java`, add:

```java
@Override
public Optional<Double> threshold(String qualifiedName) {
    return Optional.ofNullable(methods.get(qualifiedName))
            .flatMap(MethodSimulationConfig::threshold);
}

public Map<String, String> scorerSpecs() {
    return methods.entrySet().stream()
            .filter(e -> e.getValue().scorer().isPresent())
            .collect(Collectors.toMap(Map.Entry::getKey,
                    e -> e.getValue().scorer().orElseThrow()));
}
```

- [ ] **Step 11: Wire declarative scorers in SimulationConfigBeans**

In `SimulationConfigBeans.onStartup()`, add after the extractor registration block:

```java
var scorerFactory = new DeclarativeScorerFactory();
extractorConfig.scorerSpecs()
        .forEach((qn, spec) -> runtime.registerScorer(qn, scorerFactory.create(spec)));
```

- [ ] **Step 12: Run all simulation module tests**

Run: `mvn --batch-mode -pl simulation-api,simulation-core,simulation-inmem,simulation-config-core,simulation-config test`
Expected: ALL PASS

- [ ] **Step 13: Commit**

```bash
git add simulation-config-core/src/ simulation-config/src/
git commit -m "feat(#317): RecordFieldScorer + DeclarativeScorerFactory

FieldSimilarity built-in functions (EXACT, SUBSTRING, NUMERIC_RANGE,
IGNORE). RecordFieldScorer decomposes records via Jackson and applies
per-field weighted scoring. DeclarativeScorerFactory parses config
strings into scorer instances — parallel to DeclarativeExtractorFactory.

Config wiring: casehub.simulation.<spi>.<method>.scorer=fields:...
and casehub.simulation.<spi>.<method>.threshold=0.7

Refs #317

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 14: Update CLAUDE.md and simulation guide**

Add NearestMatchStrategy to CLAUDE.md module descriptions for simulation-core and simulation-config-core.
Add nearest-match to the strategy decision flowchart in `docs/guides/simulation-guide.md`.

- [ ] **Step 15: Commit docs**

```bash
git add CLAUDE.md docs/guides/simulation-guide.md
git commit -m "docs(#317): add nearest-match strategy to CLAUDE.md and simulation guide

Refs #317

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

## References

- [2026-09-16-nearest-match-strategy-design.md] — design spec this plan implements
- [decisions.md D17-D20] — decisions driving the design
- [SimulationRuntime.java] — integration point (createStrategy switch, registerScorer)
- [SimulationConfig.java] — threshold() addition
- [KeyLookupStrategy.java, KeyLookupStrategyTest.java] — existing strategy pattern
- [ListBackedCorpus.java] — test corpus helper
- [DeclarativeExtractorFactory.java] — parallel declarative pattern
- [MethodSimulationConfig.java] — config property binding
- [SmallRyeSimulationConfig.java] — config prefix scanning
- [SimulationConfigBeans.java] — CDI startup wiring
- [GitHub #317] — focal issue
- [GitHub #329, #330] — downstream declarative configuration issues
