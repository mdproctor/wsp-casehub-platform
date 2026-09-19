# Inline Corpus — Unified Simulation YAML Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #361 — inline corpus entries in scenario YAML
**Issue group:** #352 (parent epic)

**Goal:** Replace the split simulation config (MicroProfile Config properties + standalone corpus YAML files) with a unified `simulation.yaml` format that supports per-method strategy declarations alongside inline corpus entries.

**Architecture:** New `YamlSimulationConfig` class in simulation-config-core parses a structured YAML file via Jackson. It implements both `SimulationConfig` and `ProfileSource`, replacing `SmallRyeSimulationConfig`, `YamlCorpusLoader`, and `MethodSimulationConfig`. CDI wiring in `SimulationConfigBeans` migrates to the new class. Convention-based discovery loads `simulation.yaml` from the classpath root.

**Tech Stack:** Java 21, Jackson (databind + dataformat-yaml), JUnit 5, AssertJ

## Global Constraints

- simulation-config-core must remain POJO — no CDI, no Quarkus imports
- Jackson YAML is already a compile dependency of simulation-config-core
- ObjectMapper uses `PropertyNamingStrategies.KEBAB_CASE` for YAML → Java mapping
- Corpus entries are `InvocationRecord<Object, Object>` — no typed deserialization
- External corpus files retain the existing format (qualified-name → list of entries)
- Environment knobs stay in MicroProfile Config: `casehub.simulation.active-profile`, `casehub.simulation.config`, `casehub.simulation.default-tenancy-id`

---

## Batch 1: YamlSimulationConfig parser + unit tests

### Task 1: Create YamlSimulationConfig with full parsing

**Files:**
- Create: `simulation-config-core/src/main/java/io/casehub/platform/simulation/config/YamlSimulationConfig.java`
- Create: `simulation-config-core/src/test/java/io/casehub/platform/simulation/config/YamlSimulationConfigTest.java`
- Create: `simulation-config-core/src/test/resources/simulation/test-simulation.yaml`

**Interfaces:**
- Consumes: `SimulationConfig` (simulation-api), `ProfileSource` (simulation-core), `InvocationRecord` (simulation-api), `ExhaustionPolicy` (simulation-api), `SimulationProfile` (simulation-core), `InMemorySimulationCorpus` (simulation-inmem), `MapSimulationConfig` (simulation-core)
- Produces: `YamlSimulationConfig` — implements `SimulationConfig` + `ProfileSource`. Public API:
  - `YamlSimulationConfig(InputStream yamlInput)`
  - `YamlSimulationConfig(InputStream yamlInput, String defaultTenancyIdOverride)`
  - `Optional<String> strategyFor(String qualifiedName)` (from SimulationConfig)
  - `boolean captureEnabled(String qualifiedName)` (from SimulationConfig)
  - `Optional<ExhaustionPolicy> exhaustionPolicy(String qualifiedName)` (from SimulationConfig)
  - `Optional<Double> threshold(String qualifiedName)` (from SimulationConfig)
  - `Map<String, String> extractorSpecs()`
  - `Map<String, String> scorerSpecs()`
  - `Optional<String> defaultTenancyId()`
  - `Set<String> profileNames()`
  - `Map<String, List<InvocationRecord<Object, Object>>> loadAllCorpus()`
  - `Map<String, List<InvocationRecord<Object, Object>>> loadAllCorpus(String activeProfile)`
  - `Optional<SimulationProfile> resolve(String name)` (from ProfileSource)

- [ ] **Step 1: Create test YAML fixture**

Create `simulation-config-core/src/test/resources/simulation/test-simulation.yaml`:

```yaml
default-tenancy-id: test-tenant

methods:
  test-spi.query:
    strategy: key
    key-extractor: "field:domain"
    capture: true
    exhaustion-policy: WRAP
    scorer: "fields:domain:exact:1.0"
    threshold: 0.8
    corpus:
      - key: cardiology
        tenancy-id: hospital-a
        input:
          domain: cardiology
          question: "latest labs"
        output: "Lab results for cardiology"
      - key: neurology
        input:
          domain: neurology
        output: "MRI results"
    corpus-files:
      - classpath:simulation/test-corpus.yaml

  test-spi.store:
    strategy: sequential
    corpus:
      - input: "store-input"
        output: "stored"

profiles:
  demo:
    methods:
      test-spi.query:
        strategy: sequential
        corpus:
          - input:
              domain: oncology
            output: "Demo results"
    corpus-files:
      - classpath:simulation/extra-corpus.yaml
```

- [ ] **Step 2: Write failing tests for strategy config parsing**

Create `YamlSimulationConfigTest.java` with tests:

```java
package io.casehub.platform.simulation.config;

import io.casehub.platform.simulation.ExhaustionPolicy;
import io.casehub.platform.simulation.InvocationRecord;
import org.junit.jupiter.api.Test;

import java.io.ByteArrayInputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class YamlSimulationConfigTest {

    @Test
    void parsesStrategyFromYaml() {
        var config = load("""
                methods:
                  test-spi.query:
                    strategy: key
                """);
        assertThat(config.strategyFor("test-spi.query")).hasValue("key");
    }

    @Test
    void parsesCaptureFromYaml() {
        var config = load("""
                methods:
                  test-spi.query:
                    capture: true
                """);
        assertThat(config.captureEnabled("test-spi.query")).isTrue();
    }

    @Test
    void parsesExhaustionPolicyFromYaml() {
        var config = load("""
                methods:
                  test-spi.query:
                    exhaustion-policy: THROW
                """);
        assertThat(config.exhaustionPolicy("test-spi.query")).hasValue(ExhaustionPolicy.THROW);
    }

    @Test
    void parsesThresholdFromYaml() {
        var config = load("""
                methods:
                  test-spi.query:
                    threshold: 0.8
                """);
        assertThat(config.threshold("test-spi.query")).hasValue(0.8);
    }

    @Test
    void parsesKeyExtractorSpec() {
        var config = load("""
                methods:
                  test-spi.query:
                    key-extractor: "field:domain"
                """);
        assertThat(config.extractorSpecs()).containsEntry("test-spi.query", "field:domain");
    }

    @Test
    void parsesScorerSpec() {
        var config = load("""
                methods:
                  test-spi.query:
                    scorer: "fields:domain:exact:1.0"
                """);
        assertThat(config.scorerSpecs()).containsEntry("test-spi.query", "fields:domain:exact:1.0");
    }

    @Test
    void returnsEmptyForUnconfiguredMethod() {
        var config = load("""
                methods:
                  test-spi.query:
                    strategy: key
                """);
        assertThat(config.strategyFor("unknown.method")).isEmpty();
        assertThat(config.captureEnabled("unknown.method")).isFalse();
        assertThat(config.exhaustionPolicy("unknown.method")).isEmpty();
        assertThat(config.threshold("unknown.method")).isEmpty();
    }

    @Test
    void parsesDefaultTenancyId() {
        var config = load("""
                default-tenancy-id: test-tenant
                methods:
                  test-spi.query:
                    strategy: key
                """);
        assertThat(config.defaultTenancyId()).hasValue("test-tenant");
    }

    @Test
    void defaultTenancyIdOverrideWins() {
        var config = loadWithOverride("""
                default-tenancy-id: yaml-tenant
                methods:
                  test-spi.query:
                    strategy: key
                """, "override-tenant");
        assertThat(config.defaultTenancyId()).hasValue("override-tenant");
    }

    @Test
    void captureDefaultsToFalse() {
        var config = load("""
                methods:
                  test-spi.query:
                    strategy: key
                """);
        assertThat(config.captureEnabled("test-spi.query")).isFalse();
    }

    @Test
    void parsesMultipleMethods() {
        var config = load("""
                methods:
                  spi-a.query:
                    strategy: key
                  spi-b.store:
                    strategy: sequential
                """);
        assertThat(config.strategyFor("spi-a.query")).hasValue("key");
        assertThat(config.strategyFor("spi-b.store")).hasValue("sequential");
    }

    private YamlSimulationConfig load(String yaml) {
        return new YamlSimulationConfig(
                new ByteArrayInputStream(yaml.getBytes(StandardCharsets.UTF_8)));
    }

    private YamlSimulationConfig loadWithOverride(String yaml, String tenancyOverride) {
        return new YamlSimulationConfig(
                new ByteArrayInputStream(yaml.getBytes(StandardCharsets.UTF_8)),
                tenancyOverride);
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl simulation-config-core -Dtest=YamlSimulationConfigTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: FAIL — `YamlSimulationConfig` does not exist

- [ ] **Step 4: Implement YamlSimulationConfig — config parsing**

Create `YamlSimulationConfig.java`:

```java
package io.casehub.platform.simulation.config;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.dataformat.yaml.YAMLFactory;
import io.casehub.platform.simulation.ExhaustionPolicy;
import io.casehub.platform.simulation.InvocationRecord;
import io.casehub.platform.simulation.ProfileSource;
import io.casehub.platform.simulation.SimulationConfig;
import io.casehub.platform.simulation.SimulationProfile;
import io.casehub.platform.simulation.inmem.InMemorySimulationCorpus;

import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.stream.Collectors;

public class YamlSimulationConfig implements SimulationConfig, ProfileSource {

    private final String defaultTenancyId;
    private final Map<String, MethodConfig> methods;
    private final Map<String, ProfileConfig> profiles;

    public YamlSimulationConfig(InputStream yamlInput) {
        this(yamlInput, null);
    }

    @SuppressWarnings("unchecked")
    public YamlSimulationConfig(InputStream yamlInput, String defaultTenancyIdOverride) {
        ObjectMapper mapper = new ObjectMapper(new YAMLFactory());
        try {
            Map<String, Object> root = mapper.readValue(yamlInput, Map.class);
            if (root == null) {
                root = Map.of();
            }

            String yamlTenancy = (String) root.get("default-tenancy-id");
            this.defaultTenancyId = defaultTenancyIdOverride != null
                    ? defaultTenancyIdOverride : yamlTenancy;

            this.methods = parseMethods(
                    (Map<String, Map<String, Object>>) root.get("methods"));

            this.profiles = parseProfiles(
                    (Map<String, Map<String, Object>>) root.get("profiles"));

        } catch (IOException e) {
            throw new UncheckedIOException("Failed to parse simulation YAML", e);
        }
    }

    // --- SimulationConfig ---

    @Override
    public Optional<String> strategyFor(String qualifiedName) {
        return Optional.ofNullable(methods.get(qualifiedName))
                .map(MethodConfig::strategy);
    }

    @Override
    public boolean captureEnabled(String qualifiedName) {
        return Optional.ofNullable(methods.get(qualifiedName))
                .map(MethodConfig::capture)
                .orElse(false);
    }

    @Override
    public Optional<ExhaustionPolicy> exhaustionPolicy(String qualifiedName) {
        return Optional.ofNullable(methods.get(qualifiedName))
                .map(MethodConfig::exhaustionPolicy);
    }

    @Override
    public Optional<Double> threshold(String qualifiedName) {
        return Optional.ofNullable(methods.get(qualifiedName))
                .map(MethodConfig::threshold);
    }

    // --- Accessors ---

    public Map<String, String> extractorSpecs() {
        return methods.entrySet().stream()
                .filter(e -> e.getValue().keyExtractor() != null)
                .collect(Collectors.toMap(Map.Entry::getKey,
                        e -> e.getValue().keyExtractor()));
    }

    public Map<String, String> scorerSpecs() {
        return methods.entrySet().stream()
                .filter(e -> e.getValue().scorer() != null)
                .collect(Collectors.toMap(Map.Entry::getKey,
                        e -> e.getValue().scorer()));
    }

    public Optional<String> defaultTenancyId() {
        return Optional.ofNullable(defaultTenancyId);
    }

    public Set<String> profileNames() {
        return Collections.unmodifiableSet(profiles.keySet());
    }

    // --- Corpus loading ---

    public Map<String, List<InvocationRecord<Object, Object>>> loadAllCorpus() {
        Map<String, List<InvocationRecord<Object, Object>>> result = new HashMap<>();
        methods.forEach((qn, mc) -> {
            List<InvocationRecord<Object, Object>> records = loadCorpusForMethod(qn, mc);
            if (!records.isEmpty()) {
                result.put(qn, records);
            }
        });
        return result;
    }

    public Map<String, List<InvocationRecord<Object, Object>>> loadAllCorpus(
            String activeProfile) {
        Map<String, List<InvocationRecord<Object, Object>>> result = loadAllCorpus();

        ProfileConfig profile = profiles.get(activeProfile);
        if (profile == null) {
            return result;
        }

        // Per-method corpus from profile
        profile.methods().forEach((qn, mc) -> {
            List<InvocationRecord<Object, Object>> profileRecords =
                    loadCorpusForMethod(qn, mc);
            if (!profileRecords.isEmpty()) {
                result.computeIfAbsent(qn, k -> new ArrayList<>())
                        .addAll(profileRecords);
            }
        });

        // Profile-level corpus-files (apply to all methods in the file)
        if (profile.corpusFiles() != null && !profile.corpusFiles().isEmpty()) {
            loadExternalCorpusFiles(profile.corpusFiles())
                    .forEach((qn, records) ->
                            result.computeIfAbsent(qn, k -> new ArrayList<>())
                                    .addAll(records));
        }

        return result;
    }

    // --- ProfileSource ---

    @Override
    @SuppressWarnings({"rawtypes", "unchecked"})
    public Optional<SimulationProfile> resolve(String name) {
        ProfileConfig profile = profiles.get(name);
        if (profile == null) {
            return Optional.empty();
        }

        SimulationConfig composedConfig = new SimulationConfig() {
            @Override
            public Optional<String> strategyFor(String qualifiedName) {
                MethodConfig pm = profile.methods().get(qualifiedName);
                if (pm != null && pm.strategy() != null) {
                    return Optional.of(pm.strategy());
                }
                return YamlSimulationConfig.this.strategyFor(qualifiedName);
            }

            @Override
            public boolean captureEnabled(String qualifiedName) {
                MethodConfig pm = profile.methods().get(qualifiedName);
                if (pm != null && pm.capture()) {
                    return true;
                }
                return YamlSimulationConfig.this.captureEnabled(qualifiedName);
            }

            @Override
            public Optional<ExhaustionPolicy> exhaustionPolicy(String qualifiedName) {
                MethodConfig pm = profile.methods().get(qualifiedName);
                if (pm != null && pm.exhaustionPolicy() != null) {
                    return Optional.of(pm.exhaustionPolicy());
                }
                return YamlSimulationConfig.this.exhaustionPolicy(qualifiedName);
            }

            @Override
            public Optional<Double> threshold(String qualifiedName) {
                MethodConfig pm = profile.methods().get(qualifiedName);
                if (pm != null && pm.threshold() != null) {
                    return Optional.of(pm.threshold());
                }
                return YamlSimulationConfig.this.threshold(qualifiedName);
            }
        };

        InMemorySimulationCorpus corpus = new InMemorySimulationCorpus<>();
        // Load base corpus for methods the profile touches
        profile.methods().keySet().forEach(qn -> {
            MethodConfig baseMc = methods.get(qn);
            if (baseMc != null) {
                loadCorpusForMethod(qn, baseMc).forEach(
                        r -> corpus.seed(qn, List.of(r)));
            }
        });
        // Load profile corpus
        profile.methods().forEach((qn, mc) -> {
            loadCorpusForMethod(qn, mc).forEach(
                    r -> corpus.seed(qn, List.of(r)));
        });
        // Profile-level corpus-files
        if (profile.corpusFiles() != null && !profile.corpusFiles().isEmpty()) {
            loadExternalCorpusFiles(profile.corpusFiles())
                    .forEach((qn, records) -> corpus.seed(qn, records));
        }

        return Optional.of(new SimulationProfile(composedConfig, corpus));
    }

    // --- Internal parsing ---

    @SuppressWarnings("unchecked")
    private Map<String, MethodConfig> parseMethods(Map<String, Map<String, Object>> raw) {
        if (raw == null) {
            return Map.of();
        }
        Map<String, MethodConfig> result = new LinkedHashMap<>();
        raw.forEach((qn, props) -> result.put(qn, parseMethodConfig(props)));
        return result;
    }

    @SuppressWarnings("unchecked")
    private MethodConfig parseMethodConfig(Map<String, Object> props) {
        String strategy = (String) props.get("strategy");
        boolean capture = Boolean.TRUE.equals(props.get("capture"));
        ExhaustionPolicy ep = props.containsKey("exhaustion-policy")
                ? ExhaustionPolicy.valueOf(
                        ((String) props.get("exhaustion-policy")).toUpperCase().replace("-", "_"))
                : null;
        String keyExtractor = (String) props.get("key-extractor");
        String scorer = (String) props.get("scorer");
        Double threshold = props.containsKey("threshold")
                ? ((Number) props.get("threshold")).doubleValue() : null;

        List<CorpusEntry> corpus = new ArrayList<>();
        List<Map<String, Object>> rawCorpus =
                (List<Map<String, Object>>) props.get("corpus");
        if (rawCorpus != null) {
            for (Map<String, Object> entry : rawCorpus) {
                corpus.add(new CorpusEntry(
                        (String) entry.get("key"),
                        (String) entry.get("tenancy-id"),
                        entry.get("input"),
                        entry.get("output")));
            }
        }

        List<String> corpusFiles = (List<String>) props.get("corpus-files");

        return new MethodConfig(strategy, capture, ep, keyExtractor, scorer,
                threshold, corpus, corpusFiles);
    }

    @SuppressWarnings("unchecked")
    private Map<String, ProfileConfig> parseProfiles(
            Map<String, Map<String, Object>> raw) {
        if (raw == null) {
            return Map.of();
        }
        Map<String, ProfileConfig> result = new LinkedHashMap<>();
        raw.forEach((name, props) -> {
            Map<String, MethodConfig> profileMethods = parseMethods(
                    (Map<String, Map<String, Object>>) props.get("methods"));
            List<String> corpusFiles = (List<String>) props.get("corpus-files");
            result.put(name, new ProfileConfig(profileMethods, corpusFiles));
        });
        return result;
    }

    private List<InvocationRecord<Object, Object>> loadCorpusForMethod(
            String qualifiedName, MethodConfig mc) {
        List<InvocationRecord<Object, Object>> records = new ArrayList<>();

        // Inline corpus entries
        if (mc.corpus() != null) {
            for (CorpusEntry entry : mc.corpus()) {
                String tenancyId = entry.tenancyId() != null
                        ? entry.tenancyId() : defaultTenancyId;
                records.add(new InvocationRecord<>(
                        tenancyId, entry.key(), entry.input(),
                        entry.output(), Instant.now()));
            }
        }

        // External corpus files (per-method)
        if (mc.corpusFiles() != null && !mc.corpusFiles().isEmpty()) {
            Map<String, List<InvocationRecord<Object, Object>>> external =
                    loadExternalCorpusFiles(mc.corpusFiles());
            List<InvocationRecord<Object, Object>> forMethod =
                    external.get(qualifiedName);
            if (forMethod != null) {
                records.addAll(forMethod);
            }
        }

        return records;
    }

    @SuppressWarnings("unchecked")
    private Map<String, List<InvocationRecord<Object, Object>>> loadExternalCorpusFiles(
            List<String> paths) {
        ObjectMapper yamlMapper = new ObjectMapper(new YAMLFactory());
        Map<String, List<InvocationRecord<Object, Object>>> merged = new HashMap<>();
        for (String path : paths) {
            try (InputStream is = openStream(path.trim())) {
                Map<String, List<Map<String, Object>>> raw =
                        yamlMapper.readValue(is, Map.class);
                if (raw == null) continue;
                raw.forEach((qn, entries) -> {
                    List<InvocationRecord<Object, Object>> records = new ArrayList<>();
                    for (Map<String, Object> entry : entries) {
                        String tenancyId = (String) entry.get("tenancy-id");
                        if (tenancyId == null) {
                            tenancyId = defaultTenancyId;
                        }
                        records.add(new InvocationRecord<>(
                                tenancyId, (String) entry.get("key"),
                                entry.get("input"), entry.get("output"),
                                Instant.now()));
                    }
                    merged.computeIfAbsent(qn, k -> new ArrayList<>()).addAll(records);
                });
            } catch (IOException e) {
                throw new UncheckedIOException(
                        "Failed to load corpus file: " + path, e);
            }
        }
        return merged;
    }

    private InputStream openStream(String path) {
        if (path.startsWith("classpath:")) {
            String resource = path.substring("classpath:".length());
            InputStream is = Thread.currentThread().getContextClassLoader()
                    .getResourceAsStream(resource);
            if (is == null) {
                throw new IllegalArgumentException(
                        "Corpus file not found on classpath: " + resource);
            }
            return is;
        }
        try {
            return java.nio.file.Files.newInputStream(java.nio.file.Path.of(path));
        } catch (IOException e) {
            throw new UncheckedIOException(
                    "Failed to open corpus file: " + path, e);
        }
    }

    // --- Internal records ---

    record MethodConfig(
            String strategy,
            boolean capture,
            ExhaustionPolicy exhaustionPolicy,
            String keyExtractor,
            String scorer,
            Double threshold,
            List<CorpusEntry> corpus,
            List<String> corpusFiles) {}

    record CorpusEntry(
            String key,
            String tenancyId,
            Object input,
            Object output) {}

    record ProfileConfig(
            Map<String, MethodConfig> methods,
            List<String> corpusFiles) {}
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl simulation-config-core -Dtest=YamlSimulationConfigTest`
Expected: ALL PASS

- [ ] **Step 6: Add corpus loading tests**

Append these tests to `YamlSimulationConfigTest`:

```java
@Test
void loadsInlineCorpusEntries() {
    var config = load("""
            default-tenancy-id: test-tenant
            methods:
              test-spi.query:
                strategy: key
                corpus:
                  - key: cardiology
                    tenancy-id: hospital-a
                    input:
                      domain: cardiology
                    output: "Lab results"
            """);
    var corpus = config.loadAllCorpus();
    assertThat(corpus).containsKey("test-spi.query");
    assertThat(corpus.get("test-spi.query")).hasSize(1);

    var record = corpus.get("test-spi.query").get(0);
    assertThat(record.tenancyId()).isEqualTo("hospital-a");
    assertThat(record.key()).isEqualTo("cardiology");
    assertThat(record.output()).isEqualTo("Lab results");
}

@Test
void corpusFallsBackToDefaultTenancyId() {
    var config = load("""
            default-tenancy-id: fallback-tenant
            methods:
              test-spi.query:
                strategy: key
                corpus:
                  - key: neuro
                    input: "q1"
                    output: "r1"
            """);
    var record = config.loadAllCorpus().get("test-spi.query").get(0);
    assertThat(record.tenancyId()).isEqualTo("fallback-tenant");
}

@Test
void corpusExplicitTenancyOverridesDefault() {
    var config = load("""
            default-tenancy-id: default
            methods:
              test-spi.query:
                strategy: key
                corpus:
                  - tenancy-id: explicit
                    input: "q1"
                    output: "r1"
            """);
    var record = config.loadAllCorpus().get("test-spi.query").get(0);
    assertThat(record.tenancyId()).isEqualTo("explicit");
}

@Test
void loadCorpusFromExternalFiles() {
    var config = load("""
            methods:
              my-spi.query:
                strategy: key
                corpus-files:
                  - classpath:simulation/test-corpus.yaml
            """);
    var corpus = config.loadAllCorpus();
    assertThat(corpus).containsKey("my-spi.query");
    assertThat(corpus.get("my-spi.query")).hasSizeGreaterThanOrEqualTo(2);
}

@Test
void inlineAndExternalCorpusMerge() {
    var config = load("""
            default-tenancy-id: t1
            methods:
              my-spi.query:
                strategy: key
                corpus:
                  - key: inline
                    input: "inline-input"
                    output: "inline-output"
                corpus-files:
                  - classpath:simulation/test-corpus.yaml
            """);
    var entries = config.loadAllCorpus().get("my-spi.query");
    assertThat(entries.get(0).key()).isEqualTo("inline");
    assertThat(entries.size()).isGreaterThan(1);
}

@Test
void emptyMethodsBlockProducesEmptyCorpus() {
    var config = load("""
            methods:
              test-spi.query:
                strategy: key
            """);
    assertThat(config.loadAllCorpus()).isEmpty();
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl simulation-config-core -Dtest=YamlSimulationConfigTest`
Expected: ALL PASS

- [ ] **Step 8: Add profile tests**

Append these tests to `YamlSimulationConfigTest`:

```java
@Test
void profileOverridesBaseStrategy() {
    var config = load("""
            methods:
              test-spi.query:
                strategy: key
            profiles:
              demo:
                methods:
                  test-spi.query:
                    strategy: sequential
            """);
    var profile = config.resolve("demo");
    assertThat(profile).isPresent();
    assertThat(profile.get().config().strategyFor("test-spi.query"))
            .hasValue("sequential");
}

@Test
void profileFallsBackToBaseForUnconfiguredMethods() {
    var config = load("""
            methods:
              test-spi.query:
                strategy: key
              test-spi.store:
                strategy: sequential
            profiles:
              demo:
                methods:
                  test-spi.query:
                    strategy: random
            """);
    var profile = config.resolve("demo");
    assertThat(profile).isPresent();
    assertThat(profile.get().config().strategyFor("test-spi.store"))
            .hasValue("sequential");
}

@Test
void resolveUnknownProfileReturnsEmpty() {
    var config = load("""
            methods:
              test-spi.query:
                strategy: key
            """);
    assertThat(config.resolve("nonexistent")).isEmpty();
}

@Test
void profileNamesReturnsAllProfiles() {
    var config = load("""
            methods:
              test-spi.query:
                strategy: key
            profiles:
              demo:
                methods:
                  test-spi.query:
                    strategy: sequential
              staging:
                methods:
                  test-spi.query:
                    strategy: random
            """);
    assertThat(config.profileNames()).containsExactlyInAnyOrder("demo", "staging");
}

@Test
void loadAllCorpusWithProfileMergesEntries() {
    var config = load("""
            default-tenancy-id: t1
            methods:
              test-spi.query:
                strategy: key
                corpus:
                  - key: base
                    input: "base-input"
                    output: "base-output"
            profiles:
              demo:
                methods:
                  test-spi.query:
                    strategy: sequential
                    corpus:
                      - input: "demo-input"
                        output: "demo-output"
            """);
    var corpus = config.loadAllCorpus("demo");
    var entries = corpus.get("test-spi.query");
    assertThat(entries).hasSize(2);
    assertThat(entries.get(0).key()).isEqualTo("base");
    assertThat(entries.get(1).output()).isEqualTo("demo-output");
}

@Test
void malformedYamlThrowsUncheckedIOException() {
    assertThatThrownBy(() -> load("not: [valid: yaml: {{"))
            .isInstanceOf(UncheckedIOException.class);
}
```

- [ ] **Step 9: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl simulation-config-core -Dtest=YamlSimulationConfigTest`
Expected: ALL PASS

- [ ] **Step 10: Run full module tests**

Run: `mvn --batch-mode test -pl simulation-config-core`
Expected: ALL PASS (existing tests unaffected — new class doesn't touch old classes)

- [ ] **Step 11: Commit**

```bash
git add simulation-config-core/src/main/java/io/casehub/platform/simulation/config/YamlSimulationConfig.java simulation-config-core/src/test/java/io/casehub/platform/simulation/config/YamlSimulationConfigTest.java simulation-config-core/src/test/resources/simulation/test-simulation.yaml
git commit -m "feat(#361): YamlSimulationConfig — unified YAML parser with inline corpus

Replaces SmallRyeSimulationConfig's flat-property parsing with structured
YAML. Supports per-method strategy/capture/exhaustion-policy/key-extractor/
scorer/threshold, inline corpus entries, external corpus-files refs, profile
overrides, and defaultTenancyId. Implements SimulationConfig + ProfileSource.

Refs #361

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Batch 2: CDI wiring migration + retirement

### Task 2: Migrate SimulationConfigBeans and retire old classes

**Files:**
- Modify: `simulation-config/src/main/java/io/casehub/platform/simulation/config/quarkus/SimulationConfigBeans.java`
- Modify: `simulation-config/src/test/java/io/casehub/platform/simulation/config/quarkus/SimulationConfigIT.java`
- Modify: `simulation-config/src/test/resources/application.properties`
- Create: `simulation-config/src/test/resources/simulation.yaml` (replaces application.properties config + it-corpus.yaml)
- Delete: `simulation-config-core/src/main/java/io/casehub/platform/simulation/config/SmallRyeSimulationConfig.java`
- Delete: `simulation-config-core/src/main/java/io/casehub/platform/simulation/config/YamlCorpusLoader.java`
- Delete: `simulation-config-core/src/main/java/io/casehub/platform/simulation/config/MethodSimulationConfig.java`
- Delete: `simulation-config-core/src/test/java/io/casehub/platform/simulation/config/SmallRyeSimulationConfigTest.java`
- Delete: `simulation-config-core/src/test/java/io/casehub/platform/simulation/config/YamlCorpusLoaderTest.java`
- Delete: `simulation-config/src/test/resources/simulation/it-corpus.yaml`

**Interfaces:**
- Consumes: `YamlSimulationConfig` (from Task 1), `SimulationRuntime.setProfileSource()`, `DeclarativeExtractorFactory`, `DeclarativeScorerFactory`
- Produces: No new public interfaces — existing CDI producers continue producing `SimulationConfig`, `SimulationCorpus`, `SimulationRuntime`

- [ ] **Step 1: Create unified test simulation.yaml for IT**

Create `simulation-config/src/test/resources/simulation.yaml`:

```yaml
default-tenancy-id: t1

methods:
  test-spi.query:
    strategy: sequential
    exhaustion-policy: WRAP
    corpus:
      - key: first
        input: "q1"
        output: "response-1"
      - key: second
        input: "q2"
        output: "response-2"

  test-spi.store:
    capture: true

  test-spi.lookup:
    strategy: key-lookup
    key-extractor: "field:name"
    corpus:
      - key: alice
        input:
          name: alice
          age: 30
        output: "found-alice"

profiles:
  test-profile:
    methods:
      profile-spi.invoke:
        strategy: sequential
```

- [ ] **Step 2: Rewrite SimulationConfigBeans to use YamlSimulationConfig**

Replace the full content of `SimulationConfigBeans.java`:

```java
package io.casehub.platform.simulation.config.quarkus;

import io.casehub.platform.simulation.SimulationConfig;
import io.casehub.platform.simulation.SimulationCorpus;
import io.casehub.platform.simulation.SimulationRuntime;
import io.casehub.platform.simulation.config.DeclarativeExtractorFactory;
import io.casehub.platform.simulation.config.DeclarativeScorerFactory;
import io.casehub.platform.simulation.config.YamlSimulationConfig;
import io.casehub.platform.simulation.inmem.InMemorySimulationCorpus;
import io.quarkus.runtime.StartupEvent;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.event.Observes;
import jakarta.enterprise.inject.Produces;
import org.eclipse.microprofile.config.ConfigProvider;

import java.io.InputStream;

@ApplicationScoped
public class SimulationConfigBeans {

    @Produces
    @ApplicationScoped
    public YamlSimulationConfig simulationConfig() {
        var mpConfig = ConfigProvider.getConfig();
        String configPath = mpConfig
                .getOptionalValue("casehub.simulation.config", String.class)
                .orElse(null);
        String defaultTenancyId = mpConfig
                .getOptionalValue("casehub.simulation.default-tenancy-id", String.class)
                .orElse(null);

        InputStream is = discoverYaml(configPath);
        if (is == null) {
            return new YamlSimulationConfig(
                    new java.io.ByteArrayInputStream(new byte[0]),
                    defaultTenancyId);
        }
        return new YamlSimulationConfig(is, defaultTenancyId);
    }

    @Produces
    @ApplicationScoped
    @SuppressWarnings({"rawtypes", "unchecked"})
    public SimulationCorpus simulationCorpus() {
        return new InMemorySimulationCorpus<>();
    }

    @Produces
    @ApplicationScoped
    @SuppressWarnings({"rawtypes", "unchecked"})
    public SimulationRuntime simulationRuntime(SimulationConfig config,
                                               SimulationCorpus corpus) {
        return new SimulationRuntime(config, corpus);
    }

    @SuppressWarnings({"rawtypes", "unchecked"})
    void onStartup(@Observes StartupEvent event,
                   YamlSimulationConfig config,
                   SimulationCorpus corpus,
                   SimulationRuntime runtime) {

        String activeProfile = ConfigProvider.getConfig()
                .getOptionalValue("casehub.simulation.active-profile", String.class)
                .orElse(null);

        if (activeProfile != null) {
            config.loadAllCorpus(activeProfile).forEach(corpus::seed);
        } else {
            config.loadAllCorpus().forEach(corpus::seed);
        }

        runtime.setProfileSource(config);

        var factory = new DeclarativeExtractorFactory();
        config.extractorSpecs()
                .forEach((qn, spec) ->
                        runtime.registerExtractor(qn, factory.create(spec)));

        var scorerFactory = new DeclarativeScorerFactory();
        config.scorerSpecs()
                .forEach((qn, spec) ->
                        runtime.registerScorer(qn, scorerFactory.create(spec)));
    }

    private InputStream discoverYaml(String configPath) {
        ClassLoader cl = Thread.currentThread().getContextClassLoader();
        if (configPath != null) {
            if (configPath.startsWith("classpath:")) {
                return cl.getResourceAsStream(
                        configPath.substring("classpath:".length()));
            }
            try {
                return java.nio.file.Files.newInputStream(
                        java.nio.file.Path.of(configPath));
            } catch (java.io.IOException e) {
                throw new java.io.UncheckedIOException(
                        "Failed to open simulation config: " + configPath, e);
            }
        }
        InputStream is = cl.getResourceAsStream("simulation.yaml");
        if (is != null) return is;
        return cl.getResourceAsStream("simulation.yml");
    }
}
```

- [ ] **Step 3: Update IT application.properties — remove old simulation properties**

Replace content of `simulation-config/src/test/resources/application.properties` with:

```properties
# Simulation config now via simulation.yaml on classpath (convention discovery)
```

- [ ] **Step 4: Run integration tests to verify they pass**

Run: `mvn --batch-mode test -pl simulation-config`
Expected: ALL PASS — SimulationConfigIT tests pass with YAML config

- [ ] **Step 5: Delete retired classes and tests**

Use `ide_refactor_safe_delete` for each:
- `SmallRyeSimulationConfig.java`
- `YamlCorpusLoader.java`
- `MethodSimulationConfig.java`
- `SmallRyeSimulationConfigTest.java`
- `YamlCorpusLoaderTest.java`

Delete `simulation-config/src/test/resources/simulation/it-corpus.yaml` via bash (non-code file):

```bash
rm simulation-config/src/test/resources/simulation/it-corpus.yaml
```

- [ ] **Step 6: Run full build for both modules**

Run: `mvn --batch-mode test -pl simulation-config-core,simulation-config`
Expected: ALL PASS — no compile errors, no test failures

- [ ] **Step 7: Commit**

```bash
git add -A simulation-config-core/ simulation-config/
git commit -m "feat(#361): migrate CDI wiring to YamlSimulationConfig, retire old classes

SimulationConfigBeans now discovers simulation.yaml by convention,
parses via YamlSimulationConfig, and wires ProfileSource + extractors +
scorers. Convention: simulation.yaml on classpath root, overridable
via casehub.simulation.config property.

Retired: SmallRyeSimulationConfig, YamlCorpusLoader, MethodSimulationConfig
and their tests. Standalone corpus files replaced by inline corpus entries
and corpus-files refs in the unified YAML.

Refs #361

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Batch 3: JSON Schema + documentation

### Task 3: Create JSON Schema for simulation.yaml validation

**Files:**
- Create: `simulation-config-core/src/main/resources/schema/simulation.schema.json`
- Create: `simulation-config-core/src/test/java/io/casehub/platform/simulation/config/SimulationSchemaTest.java`

**Interfaces:**
- Consumes: `PlatformSchemaGenerator` (schema-generator module) — not used here; this is a hand-written JSON Schema since the YAML format is not driven by Java types
- Produces: `simulation.schema.json` classpath resource for IDE auto-completion

- [ ] **Step 1: Write failing schema validation test**

```java
package io.casehub.platform.simulation.config;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.dataformat.yaml.YAMLFactory;
import com.networknt.json.schema.JsonSchemaFactory;
import com.networknt.json.schema.SpecVersion;
import com.networknt.json.schema.ValidationMessage;
import org.junit.jupiter.api.Test;

import java.io.InputStream;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;

class SimulationSchemaTest {

    @Test
    void schemaValidatesTestFixture() {
        Set<ValidationMessage> errors = validate("simulation/test-simulation.yaml");
        assertThat(errors).isEmpty();
    }

    @Test
    void schemaRejectsUnknownTopLevelKey() {
        Set<ValidationMessage> errors = validateYaml("""
                unknown-key: value
                methods:
                  test.query:
                    strategy: key
                """);
        assertThat(errors).isNotEmpty();
    }

    @Test
    void schemaRejectsCorpusEntryWithoutOutput() {
        Set<ValidationMessage> errors = validateYaml("""
                methods:
                  test.query:
                    strategy: key
                    corpus:
                      - input: "hello"
                """);
        assertThat(errors).isNotEmpty();
    }

    private Set<ValidationMessage> validate(String classpathResource) {
        try {
            var yamlMapper = new ObjectMapper(new YAMLFactory());
            InputStream yamlIs = getClass().getClassLoader()
                    .getResourceAsStream(classpathResource);
            JsonNode yamlNode = yamlMapper.readTree(yamlIs);

            InputStream schemaIs = getClass().getClassLoader()
                    .getResourceAsStream("schema/simulation.schema.json");
            var schemaFactory = JsonSchemaFactory.getInstance(SpecVersion.VersionFlag.V202012);
            var schema = schemaFactory.getSchema(schemaIs);
            return schema.validate(yamlNode);
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    private Set<ValidationMessage> validateYaml(String yaml) {
        try {
            var yamlMapper = new ObjectMapper(new YAMLFactory());
            JsonNode yamlNode = yamlMapper.readTree(yaml);

            InputStream schemaIs = getClass().getClassLoader()
                    .getResourceAsStream("schema/simulation.schema.json");
            var schemaFactory = JsonSchemaFactory.getInstance(SpecVersion.VersionFlag.V202012);
            var schema = schemaFactory.getSchema(schemaIs);
            return schema.validate(yamlNode);
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }
}
```

**Note:** Check if `com.networknt:json-schema-validator` is already a dependency (it may be available via `schema-generator`). If not, add it as a test-scope dependency to `simulation-config-core/pom.xml`:

```xml
<dependency>
    <groupId>com.networknt</groupId>
    <artifactId>json-schema-validator</artifactId>
    <version>1.5.6</version>
    <scope>test</scope>
</dependency>
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl simulation-config-core -Dtest=SimulationSchemaTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: FAIL — schema file does not exist

- [ ] **Step 3: Create simulation.schema.json**

Create `simulation-config-core/src/main/resources/schema/simulation.schema.json`:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://casehub.io/schema/simulation.schema.json",
  "title": "CaseHub Simulation Configuration",
  "description": "Unified simulation YAML — per-method strategy, inline corpus, profiles",
  "type": "object",
  "additionalProperties": false,
  "properties": {
    "default-tenancy-id": {
      "type": "string",
      "description": "Fallback tenancy ID for corpus entries without tenancy-id"
    },
    "methods": {
      "type": "object",
      "description": "Per-qualified-name method configuration",
      "additionalProperties": {
        "$ref": "#/$defs/method-config"
      }
    },
    "profiles": {
      "type": "object",
      "description": "Named override sets",
      "additionalProperties": {
        "$ref": "#/$defs/profile-config"
      }
    }
  },
  "$defs": {
    "method-config": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "strategy": {
          "type": "string",
          "description": "Strategy name",
          "enum": ["key-lookup", "key", "sequential", "seq", "random", "rand",
                   "recorded-replay", "replay", "nearest-match", "nearest"]
        },
        "key-extractor": {
          "type": "string",
          "description": "Declarative key extractor spec (identity, field:<path>, composite:<f1>,<f2>)"
        },
        "capture": {
          "type": "boolean",
          "default": false,
          "description": "Enable invocation capture"
        },
        "exhaustion-policy": {
          "type": "string",
          "enum": ["WRAP", "THROW"],
          "description": "Behaviour when corpus entries are exhausted"
        },
        "scorer": {
          "type": "string",
          "description": "Nearest-match scorer spec (fields:<name>:<scorer>:<weight>,...)"
        },
        "threshold": {
          "type": "number",
          "minimum": 0.0,
          "maximum": 1.0,
          "description": "Nearest-match threshold"
        },
        "corpus": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/corpus-entry"
          },
          "description": "Inline corpus entries"
        },
        "corpus-files": {
          "type": "array",
          "items": { "type": "string" },
          "description": "External corpus file paths (classpath: or filesystem)"
        }
      }
    },
    "corpus-entry": {
      "type": "object",
      "required": ["output"],
      "additionalProperties": false,
      "properties": {
        "key": {
          "type": "string",
          "description": "Lookup key for key-lookup strategy"
        },
        "tenancy-id": {
          "type": "string",
          "description": "Tenant ID (falls back to default-tenancy-id)"
        },
        "input": {
          "description": "Input value — any YAML type"
        },
        "output": {
          "description": "Output value — any YAML type"
        }
      }
    },
    "profile-config": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "methods": {
          "type": "object",
          "additionalProperties": {
            "$ref": "#/$defs/method-config"
          }
        },
        "corpus-files": {
          "type": "array",
          "items": { "type": "string" },
          "description": "Profile-level corpus files (all methods)"
        }
      }
    }
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl simulation-config-core -Dtest=SimulationSchemaTest`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add simulation-config-core/src/main/resources/schema/simulation.schema.json simulation-config-core/src/test/java/io/casehub/platform/simulation/config/SimulationSchemaTest.java simulation-config-core/pom.xml
git commit -m "feat(#361): JSON Schema for simulation.yaml — IDE validation support

Publishes simulation.schema.json as classpath resource. Covers top-level
structure, per-method config, corpus entries, profiles, and strategy enum
values. Schema tests validate the test fixture and reject malformed input.

Refs #361

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 4: Update documentation

**Files:**
- Modify: `docs/guides/consumer-guide.md` — update simulation config section
- Modify: `docs/guides/contributor-guide.md` — update simulation internals section
- Modify: `docs/examples/simulation/` — update example YAML files to unified format

**Interfaces:**
- Consumes: Spec §1 YAML schema (for documentation examples)
- Produces: Updated documentation reflecting the unified YAML format

- [ ] **Step 1: Update consumer-guide.md simulation config section**

Search for sections referencing `casehub.simulation.corpus.files`, `SmallRyeSimulationConfig`, or `application.properties` simulation keys. Replace with `simulation.yaml` format documentation and examples matching the spec's YAML schema.

- [ ] **Step 2: Update contributor-guide.md simulation internals**

Replace references to `SmallRyeSimulationConfig` and `YamlCorpusLoader` with `YamlSimulationConfig`. Update the architecture description to reflect the unified YAML parser.

- [ ] **Step 3: Update ARC42STORIES.MD**

Update L16 description in `ARC42STORIES.MD` — replace references to `SmallRyeSimulationConfig prefix scanning` and `YamlCorpusLoader` with `YamlSimulationConfig unified YAML parser`.

- [ ] **Step 4: Update example YAML files**

Convert files in `docs/examples/simulation/` (devtown, clinical, aml, fsitrading) from standalone corpus format to the unified `simulation.yaml` format where appropriate. Add inline corpus examples.

- [ ] **Step 5: Run full build to verify no broken doc links**

Run: `mvn --batch-mode install -DskipTests`
Expected: BUILD SUCCESS

- [ ] **Step 6: Commit**

```bash
git add docs/
git commit -m "docs(#361): update simulation guides and examples for unified YAML

Consumer guide: simulation.yaml format, inline corpus examples.
Contributor guide: YamlSimulationConfig architecture.
Examples: unified format with inline corpus entries.

Refs #361

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## References

- [2026-09-19-inline-corpus-unified-yaml-design.md] — design spec this plan implements
- [D7-D16 in decisions.md] — design decisions
- [SmallRyeSimulationConfig.java] — current flat-property parser (retiring)
- [YamlCorpusLoader.java] — current corpus loader (retiring)
- [MethodSimulationConfig.java] — current per-method config (retiring)
- [SimulationConfigBeans.java:22-73] — CDI wiring (migrating)
- [SimulationConfigIT.java] — integration test (migrating)
- [test-corpus.yaml, extra-corpus.yaml] — existing test fixtures
- [2026-09-15-yaml-driven-simulation-config-design.md] — original YAML config spec
- [GitHub #361] — focal issue
- [GitHub #352] — parent epic
