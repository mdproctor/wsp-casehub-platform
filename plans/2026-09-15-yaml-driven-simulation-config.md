# YAML-Driven Simulation Configuration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #325 — feat: YAML-driven simulation configuration and corpus seeding
**Issue group:** #312 (simulation-api), #313 (simulation-core), #314 (simulation-inmem), #315 (agent-simulation-core)

**Goal:** Make the simulation framework's documented config keys actually work — `application.properties` binds to `SimulationConfig`, YAML files seed corpora at startup, and common KeyExtractor patterns are config-driven.

**Architecture:** Two new modules (`simulation-config-core` + `simulation-config`) following the established core/Quarkus split pattern. `SmallRyeSimulationConfig` scans config property names at construction time via `ConfigProvider.getConfig()` (manual prefix scanning — no `@ConfigMapping`). `YamlCorpusLoader` parses YAML fixture files into `InvocationRecord<Object, Object>` entries. `DeclarativeExtractorFactory` creates `KeyExtractor<Object>` lambdas from config strings (`identity`, `field:name`, `composite:a,b`). `SimulationConfigBeans` wires everything at CDI startup.

**Tech Stack:** Java 21, SmallRye Config API, Jackson databind + dataformat-yaml, Quarkus CDI (Arc), JUnit 5, AssertJ

## Global Constraints

- `simulation-config-core` has no CDI, no Quarkus imports — pure Java + SmallRye Config API + Jackson
- `simulation-config` has Quarkus CDI only — `@Produces`, `@Startup`, `@ApplicationScoped`
- Package: `io.casehub.platform.simulation.config` (core) and `io.casehub.platform.simulation.config.quarkus` (beans)
- All `@ConfigMapping` methods require Javadoc (GE-20260512-552405) — but we're not using `@ConfigMapping`
- Parent POM version: `0.2-SNAPSHOT`, group: `io.casehub`

---

## Batch 1: Config binding — SmallRyeSimulationConfig

### Task 1: Module scaffolding + SmallRyeSimulationConfig

**Files:**
- Create: `simulation-config-core/pom.xml`
- Create: `simulation-config-core/src/main/java/io/casehub/platform/simulation/config/MethodSimulationConfig.java`
- Create: `simulation-config-core/src/main/java/io/casehub/platform/simulation/config/SmallRyeSimulationConfig.java`
- Create: `simulation-config-core/src/test/java/io/casehub/platform/simulation/config/SmallRyeSimulationConfigTest.java`
- Modify: `pom.xml` (parent — add `<module>simulation-config-core</module>`)

**Interfaces:**
- Consumes: `SimulationConfig` (simulation-core: `strategyFor`, `captureEnabled`, `exhaustionPolicy`)
- Consumes: `ExhaustionPolicy` (simulation-api: enum `WRAP`, `THROW`)
- Produces: `SmallRyeSimulationConfig implements SimulationConfig` — constructor takes `org.eclipse.microprofile.config.Config`
- Produces: `MethodSimulationConfig` — internal value class with `strategy()`, `capture()`, `exhaustionPolicy()`, `keyExtractor()`

- [ ] **Step 1: Create `simulation-config-core/pom.xml`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>
    <parent>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-platform-parent</artifactId>
        <version>0.2-SNAPSHOT</version>
    </parent>

    <artifactId>casehub-platform-simulation-config-core</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform :: Simulation Config Core</name>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-simulation-api</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-simulation-core</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>io.smallrye.config</groupId>
            <artifactId>smallrye-config</artifactId>
        </dependency>
        <dependency>
            <groupId>com.fasterxml.jackson.core</groupId>
            <artifactId>jackson-databind</artifactId>
        </dependency>
        <dependency>
            <groupId>com.fasterxml.jackson.dataformat</groupId>
            <artifactId>jackson-dataformat-yaml</artifactId>
        </dependency>
        <dependency>
            <groupId>com.fasterxml.jackson.datatype</groupId>
            <artifactId>jackson-datatype-jsr310</artifactId>
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

- [ ] **Step 2: Add module to parent `pom.xml`**

Add `<module>simulation-config-core</module>` after `<module>agent-simulation-core</module>` in the `<modules>` section of the root `pom.xml`.

- [ ] **Step 3: Write failing tests for SmallRyeSimulationConfig**

Create `simulation-config-core/src/test/java/io/casehub/platform/simulation/config/SmallRyeSimulationConfigTest.java`:

```java
package io.casehub.platform.simulation.config;

import io.casehub.platform.simulation.ExhaustionPolicy;
import io.smallrye.config.SmallRyeConfig;
import io.smallrye.config.SmallRyeConfigBuilder;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class SmallRyeSimulationConfigTest {

    @Test
    void parsesStrategyFromProperties() {
        var config = buildConfig(
                "casehub.simulation.my-spi.query.strategy", "sequential");
        var simConfig = new SmallRyeSimulationConfig(config);

        assertThat(simConfig.strategyFor("my-spi.query")).hasValue("sequential");
    }

    @Test
    void parsesCaptureFromProperties() {
        var config = buildConfig(
                "casehub.simulation.my-spi.store.capture", "true");
        var simConfig = new SmallRyeSimulationConfig(config);

        assertThat(simConfig.captureEnabled("my-spi.store")).isTrue();
    }

    @Test
    void parsesExhaustionPolicyFromProperties() {
        var config = buildConfig(
                "casehub.simulation.my-spi.query.exhaustion-policy", "THROW");
        var simConfig = new SmallRyeSimulationConfig(config);

        assertThat(simConfig.exhaustionPolicy("my-spi.query"))
                .hasValue(ExhaustionPolicy.THROW);
    }

    @Test
    void returnsEmptyForUnconfiguredMethod() {
        var config = buildConfig(
                "casehub.simulation.my-spi.query.strategy", "sequential");
        var simConfig = new SmallRyeSimulationConfig(config);

        assertThat(simConfig.strategyFor("my-spi.unknown")).isEmpty();
        assertThat(simConfig.captureEnabled("my-spi.unknown")).isFalse();
        assertThat(simConfig.exhaustionPolicy("my-spi.unknown")).isEmpty();
    }

    @Test
    void ignoresReservedKeysWithFewerThanThreeSegments() {
        var config = buildConfig(
                "casehub.simulation.corpus.files", "classpath:test.yaml");
        var simConfig = new SmallRyeSimulationConfig(config);

        assertThat(simConfig.strategyFor("corpus.files")).isEmpty();
    }

    @Test
    void parsesMultipleMethodsAcrossSpis() {
        var config = new SmallRyeConfigBuilder()
                .withDefaultValue("casehub.simulation.spi-a.query.strategy", "key-lookup")
                .withDefaultValue("casehub.simulation.spi-a.store.capture", "true")
                .withDefaultValue("casehub.simulation.spi-b.invoke.strategy", "sequential")
                .withDefaultValue("casehub.simulation.spi-b.invoke.exhaustion-policy", "WRAP")
                .build();
        var simConfig = new SmallRyeSimulationConfig(config);

        assertThat(simConfig.strategyFor("spi-a.query")).hasValue("key-lookup");
        assertThat(simConfig.captureEnabled("spi-a.store")).isTrue();
        assertThat(simConfig.strategyFor("spi-b.invoke")).hasValue("sequential");
        assertThat(simConfig.exhaustionPolicy("spi-b.invoke"))
                .hasValue(ExhaustionPolicy.WRAP);
    }

    @Test
    void parsesKeyExtractorSpec() {
        var config = buildConfig(
                "casehub.simulation.my-spi.query.key-extractor", "field:domain");
        var simConfig = new SmallRyeSimulationConfig(config);

        assertThat(simConfig.extractorSpecs()).containsEntry("my-spi.query", "field:domain");
    }

    private SmallRyeConfig buildConfig(String key, String value) {
        return new SmallRyeConfigBuilder()
                .withDefaultValue(key, value)
                .build();
    }
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl simulation-config-core -Dtest=SmallRyeSimulationConfigTest`
Expected: Compilation failure — `SmallRyeSimulationConfig` class does not exist.

- [ ] **Step 5: Implement MethodSimulationConfig**

Create `simulation-config-core/src/main/java/io/casehub/platform/simulation/config/MethodSimulationConfig.java`:

```java
package io.casehub.platform.simulation.config;

import io.casehub.platform.simulation.ExhaustionPolicy;

import java.util.Optional;

class MethodSimulationConfig {

    private String strategy;
    private boolean capture;
    private ExhaustionPolicy exhaustionPolicy;
    private String keyExtractor;

    Optional<String> strategy() {
        return Optional.ofNullable(strategy);
    }

    boolean capture() {
        return capture;
    }

    Optional<ExhaustionPolicy> exhaustionPolicy() {
        return Optional.ofNullable(exhaustionPolicy);
    }

    Optional<String> keyExtractor() {
        return Optional.ofNullable(keyExtractor);
    }

    void set(String property, String value) {
        switch (property) {
            case "strategy" -> this.strategy = value;
            case "capture" -> this.capture = Boolean.parseBoolean(value);
            case "exhaustion-policy" -> this.exhaustionPolicy =
                    ExhaustionPolicy.valueOf(value.toUpperCase().replace("-", "_"));
            case "key-extractor" -> this.keyExtractor = value;
            default -> { /* ignore unknown properties */ }
        }
    }
}
```

- [ ] **Step 6: Implement SmallRyeSimulationConfig**

Create `simulation-config-core/src/main/java/io/casehub/platform/simulation/config/SmallRyeSimulationConfig.java`:

```java
package io.casehub.platform.simulation.config;

import io.casehub.platform.simulation.ExhaustionPolicy;
import io.casehub.platform.simulation.SimulationConfig;
import org.eclipse.microprofile.config.Config;

import java.util.HashMap;
import java.util.Map;
import java.util.Optional;
import java.util.stream.Collectors;

public class SmallRyeSimulationConfig implements SimulationConfig {

    private static final String PREFIX = "casehub.simulation.";
    private final Map<String, MethodSimulationConfig> methods;

    public SmallRyeSimulationConfig(Config config) {
        this.methods = new HashMap<>();
        for (String name : config.getPropertyNames()) {
            if (!name.startsWith(PREFIX)) {
                continue;
            }
            String suffix = name.substring(PREFIX.length());
            String[] parts = suffix.split("\\.");
            if (parts.length != 3) {
                continue;
            }
            String qualifiedName = parts[0] + "." + parts[1];
            String property = parts[2];
            config.getOptionalValue(name, String.class)
                    .ifPresent(value -> methods
                            .computeIfAbsent(qualifiedName, k -> new MethodSimulationConfig())
                            .set(property, value));
        }
    }

    @Override
    public Optional<String> strategyFor(String qualifiedName) {
        return Optional.ofNullable(methods.get(qualifiedName))
                .flatMap(MethodSimulationConfig::strategy);
    }

    @Override
    public boolean captureEnabled(String qualifiedName) {
        return Optional.ofNullable(methods.get(qualifiedName))
                .map(MethodSimulationConfig::capture)
                .orElse(false);
    }

    @Override
    public Optional<ExhaustionPolicy> exhaustionPolicy(String qualifiedName) {
        return Optional.ofNullable(methods.get(qualifiedName))
                .flatMap(MethodSimulationConfig::exhaustionPolicy);
    }

    public Map<String, String> extractorSpecs() {
        return methods.entrySet().stream()
                .filter(e -> e.getValue().keyExtractor().isPresent())
                .collect(Collectors.toMap(Map.Entry::getKey,
                        e -> e.getValue().keyExtractor().orElseThrow()));
    }
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl simulation-config-core -Dtest=SmallRyeSimulationConfigTest`
Expected: All 7 tests PASS.

- [ ] **Step 8: Commit**

```bash
git add simulation-config-core/ pom.xml
git commit -m "feat(#325): SmallRyeSimulationConfig — config binding via prefix scanning

Implements SimulationConfig by scanning casehub.simulation.* properties.
Manual prefix scanning avoids SmallRye @ConfigMapping gotchas with
two-level dynamic keys (GE-20260519-b9719e, GE-20260609-4c6577).

Refs #325"
```

---

## Batch 2: YAML corpus loader + declarative extractors

### Task 2: YamlCorpusLoader

**Files:**
- Create: `simulation-config-core/src/main/java/io/casehub/platform/simulation/config/YamlCorpusLoader.java`
- Create: `simulation-config-core/src/test/java/io/casehub/platform/simulation/config/YamlCorpusLoaderTest.java`
- Create: `simulation-config-core/src/test/resources/simulation/test-corpus.yaml`
- Create: `simulation-config-core/src/test/resources/simulation/extra-corpus.yaml`

**Interfaces:**
- Consumes: `InvocationRecord<I, O>` (simulation-api: record with tenancyId, key, input, output, recordedAt)
- Produces: `YamlCorpusLoader` — `load(InputStream)` → `Map<String, List<InvocationRecord<Object, Object>>>`, `loadFromPaths(List<String>)` → same

- [ ] **Step 1: Create test corpus fixture file**

Create `simulation-config-core/src/test/resources/simulation/test-corpus.yaml`:

```yaml
my-spi.query:
  - key: cardiology
    tenancy-id: hospital-a
    input:
      domain: cardiology
      question: "latest labs"
    output: "Lab results for cardiology"
  - key: neurology
    tenancy-id: hospital-a
    input:
      domain: neurology
      question: "MRI scan"
    output: "MRI results"

my-spi.store:
  - tenancy-id: hospital-b
    input: "store-input"
    output: "stored"
```

Create `simulation-config-core/src/test/resources/simulation/extra-corpus.yaml`:

```yaml
my-spi.query:
  - key: oncology
    tenancy-id: hospital-c
    input:
      domain: oncology
      question: "biopsy results"
    output: "Biopsy report"
```

- [ ] **Step 2: Write failing tests**

Create `simulation-config-core/src/test/java/io/casehub/platform/simulation/config/YamlCorpusLoaderTest.java`:

```java
package io.casehub.platform.simulation.config;

import io.casehub.platform.simulation.InvocationRecord;
import org.junit.jupiter.api.Test;

import java.io.InputStream;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class YamlCorpusLoaderTest {

    private final YamlCorpusLoader loader = new YamlCorpusLoader();

    @Test
    void loadsEntriesFromYaml() {
        var result = loadTestCorpus("simulation/test-corpus.yaml");

        assertThat(result).containsKeys("my-spi.query", "my-spi.store");
        assertThat(result.get("my-spi.query")).hasSize(2);
        assertThat(result.get("my-spi.store")).hasSize(1);
    }

    @Test
    void parsesKeyAndTenancyId() {
        var result = loadTestCorpus("simulation/test-corpus.yaml");
        InvocationRecord<Object, Object> first = result.get("my-spi.query").get(0);

        assertThat(first.key()).isEqualTo("cardiology");
        assertThat(first.tenancyId()).isEqualTo("hospital-a");
    }

    @Test
    void parsesMapInput() {
        var result = loadTestCorpus("simulation/test-corpus.yaml");
        InvocationRecord<Object, Object> first = result.get("my-spi.query").get(0);

        assertThat(first.input()).isInstanceOf(Map.class);
        @SuppressWarnings("unchecked")
        Map<String, Object> input = (Map<String, Object>) first.input();
        assertThat(input).containsEntry("domain", "cardiology");
    }

    @Test
    void parsesStringOutput() {
        var result = loadTestCorpus("simulation/test-corpus.yaml");
        InvocationRecord<Object, Object> first = result.get("my-spi.query").get(0);

        assertThat(first.output()).isEqualTo("Lab results for cardiology");
    }

    @Test
    void handlesNullKey() {
        var result = loadTestCorpus("simulation/test-corpus.yaml");
        InvocationRecord<Object, Object> storeEntry = result.get("my-spi.store").get(0);

        assertThat(storeEntry.key()).isNull();
    }

    @Test
    void setsRecordedAtToNonNull() {
        var result = loadTestCorpus("simulation/test-corpus.yaml");
        InvocationRecord<Object, Object> first = result.get("my-spi.query").get(0);

        assertThat(first.recordedAt()).isNotNull();
    }

    @Test
    void loadFromPathsMergesAcrossFiles() {
        var result = loader.loadFromPaths(List.of(
                "classpath:simulation/test-corpus.yaml",
                "classpath:simulation/extra-corpus.yaml"));

        assertThat(result.get("my-spi.query")).hasSize(3);
    }

    private Map<String, List<InvocationRecord<Object, Object>>> loadTestCorpus(
            String resource) {
        InputStream is = getClass().getClassLoader().getResourceAsStream(resource);
        assertThat(is).as("Test resource %s", resource).isNotNull();
        return loader.load(is);
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl simulation-config-core -Dtest=YamlCorpusLoaderTest`
Expected: Compilation failure — `YamlCorpusLoader` does not exist.

- [ ] **Step 4: Implement YamlCorpusLoader**

Create `simulation-config-core/src/main/java/io/casehub/platform/simulation/config/YamlCorpusLoader.java`:

```java
package io.casehub.platform.simulation.config;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.dataformat.yaml.YAMLFactory;
import io.casehub.platform.simulation.InvocationRecord;

import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.time.Instant;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

public class YamlCorpusLoader {

    private final ObjectMapper yamlMapper = new ObjectMapper(new YAMLFactory());

    @SuppressWarnings("unchecked")
    public Map<String, List<InvocationRecord<Object, Object>>> load(InputStream input) {
        try {
            Map<String, List<Map<String, Object>>> raw =
                    yamlMapper.readValue(input, Map.class);
            Map<String, List<InvocationRecord<Object, Object>>> result = new HashMap<>();
            raw.forEach((qualifiedName, entries) -> {
                List<InvocationRecord<Object, Object>> records = new ArrayList<>();
                for (Map<String, Object> entry : entries) {
                    records.add(new InvocationRecord<>(
                            (String) entry.get("tenancy-id"),
                            (String) entry.get("key"),
                            entry.get("input"),
                            entry.get("output"),
                            Instant.now()));
                }
                result.put(qualifiedName, records);
            });
            return result;
        } catch (IOException e) {
            throw new UncheckedIOException("Failed to parse YAML corpus", e);
        }
    }

    public Map<String, List<InvocationRecord<Object, Object>>> loadFromPaths(
            List<String> paths) {
        Map<String, List<InvocationRecord<Object, Object>>> merged = new HashMap<>();
        for (String path : paths) {
            InputStream is = openStream(path.trim());
            Map<String, List<InvocationRecord<Object, Object>>> loaded = load(is);
            loaded.forEach((qn, records) ->
                    merged.computeIfAbsent(qn, k -> new ArrayList<>()).addAll(records));
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
            throw new UncheckedIOException("Failed to open corpus file: " + path, e);
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl simulation-config-core -Dtest=YamlCorpusLoaderTest`
Expected: All 7 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add simulation-config-core/
git commit -m "feat(#325): YamlCorpusLoader — YAML fixture file parsing

Loads InvocationRecord<Object, Object> entries from YAML files.
Supports classpath: and filesystem paths. Merges across multiple files.

Refs #325"
```

### Task 3: DeclarativeExtractorFactory

**Files:**
- Create: `simulation-config-core/src/main/java/io/casehub/platform/simulation/config/DeclarativeExtractorFactory.java`
- Create: `simulation-config-core/src/test/java/io/casehub/platform/simulation/config/DeclarativeExtractorFactoryTest.java`

**Interfaces:**
- Consumes: `KeyExtractor<I>` (simulation-api: `@FunctionalInterface`, `String extract(I input)`)
- Consumes: `SimulationConfigException` (simulation-core)
- Produces: `DeclarativeExtractorFactory` — `KeyExtractor<Object> create(String spec)`

- [ ] **Step 1: Write failing tests**

Create `simulation-config-core/src/test/java/io/casehub/platform/simulation/config/DeclarativeExtractorFactoryTest.java`:

```java
package io.casehub.platform.simulation.config;

import io.casehub.platform.simulation.KeyExtractor;
import io.casehub.platform.simulation.SimulationConfigException;
import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class DeclarativeExtractorFactoryTest {

    private final DeclarativeExtractorFactory factory = new DeclarativeExtractorFactory();

    @Test
    void identityExtractorUsesToString() {
        KeyExtractor<Object> extractor = factory.create("identity");

        assertThat(extractor.extract("hello")).isEqualTo("hello");
        assertThat(extractor.extract(42)).isEqualTo("42");
    }

    @Test
    void fieldExtractorFromMap() {
        KeyExtractor<Object> extractor = factory.create("field:domain");

        String key = extractor.extract(Map.of("domain", "cardiology", "other", "x"));
        assertThat(key).isEqualTo("cardiology");
    }

    @Test
    void fieldExtractorFromRecord() {
        KeyExtractor<Object> extractor = factory.create("field:name");

        record TestInput(String name, int age) {}
        String key = extractor.extract(new TestInput("alice", 30));
        assertThat(key).isEqualTo("alice");
    }

    @Test
    void compositeExtractorConcatenatesFields() {
        KeyExtractor<Object> extractor = factory.create("composite:department,severity");

        String key = extractor.extract(Map.of("department", "ER", "severity", "HIGH"));
        assertThat(key).isEqualTo("department=ER:severity=HIGH");
    }

    @Test
    void unknownSpecThrowsConfigException() {
        assertThatThrownBy(() -> factory.create("bogus"))
                .isInstanceOf(SimulationConfigException.class)
                .hasMessageContaining("Unknown key-extractor spec");
    }

    @Test
    void fieldExtractorMissingFieldReturnsNull() {
        KeyExtractor<Object> extractor = factory.create("field:missing");

        String key = extractor.extract(Map.of("other", "value"));
        assertThat(key).isEqualTo("null");
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl simulation-config-core -Dtest=DeclarativeExtractorFactoryTest`
Expected: Compilation failure — `DeclarativeExtractorFactory` does not exist.

- [ ] **Step 3: Implement DeclarativeExtractorFactory**

Create `simulation-config-core/src/main/java/io/casehub/platform/simulation/config/DeclarativeExtractorFactory.java`:

```java
package io.casehub.platform.simulation.config;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;
import io.casehub.platform.simulation.KeyExtractor;
import io.casehub.platform.simulation.SimulationConfigException;

import java.util.Arrays;
import java.util.Map;
import java.util.stream.Collectors;

public class DeclarativeExtractorFactory {

    private static final TypeReference<Map<String, Object>> MAP_TYPE =
            new TypeReference<>() {};
    private final ObjectMapper objectMapper;

    public DeclarativeExtractorFactory() {
        this.objectMapper = new ObjectMapper();
        objectMapper.registerModule(new JavaTimeModule());
    }

    public KeyExtractor<Object> create(String spec) {
        if ("identity".equals(spec)) {
            return input -> String.valueOf(input);
        }
        if (spec.startsWith("field:")) {
            String fieldName = spec.substring("field:".length());
            return input -> String.valueOf(toMap(input).get(fieldName));
        }
        if (spec.startsWith("composite:")) {
            String[] fields = spec.substring("composite:".length()).split(",");
            return input -> {
                Map<String, Object> map = toMap(input);
                return Arrays.stream(fields)
                        .map(f -> f + "=" + map.getOrDefault(f, "null"))
                        .collect(Collectors.joining(":"));
            };
        }
        throw new SimulationConfigException(
                "Unknown key-extractor spec: " + spec
                        + ". Valid: identity, field:<name>, composite:<f1>,<f2>");
    }

    @SuppressWarnings("unchecked")
    private Map<String, Object> toMap(Object input) {
        if (input instanceof Map) {
            return (Map<String, Object>) input;
        }
        return objectMapper.convertValue(input, MAP_TYPE);
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl simulation-config-core -Dtest=DeclarativeExtractorFactoryTest`
Expected: All 6 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add simulation-config-core/
git commit -m "feat(#325): DeclarativeExtractorFactory — config-driven KeyExtractors

Supports identity, field:<name>, and composite:<f1>,<f2> specs.
Jackson ObjectMapper.convertValue handles typed inputs (records, POJOs).

Refs #325"
```

---

## Batch 3: Quarkus CDI wiring + integration tests

### Task 4: SimulationConfigBeans + integration test

**Files:**
- Create: `simulation-config/pom.xml`
- Create: `simulation-config/src/main/java/io/casehub/platform/simulation/config/quarkus/SimulationConfigBeans.java`
- Create: `simulation-config/src/test/java/io/casehub/platform/simulation/config/quarkus/SimulationConfigIT.java`
- Create: `simulation-config/src/test/resources/application.properties`
- Create: `simulation-config/src/test/resources/simulation/it-corpus.yaml`
- Modify: `pom.xml` (parent — add `<module>simulation-config</module>`)

**Interfaces:**
- Consumes: `SmallRyeSimulationConfig` (simulation-config-core)
- Consumes: `YamlCorpusLoader` (simulation-config-core)
- Consumes: `DeclarativeExtractorFactory` (simulation-config-core)
- Consumes: `SimulationRuntime` (simulation-core: POJO, constructor: `SimulationConfig` + `SimulationCorpus`)
- Consumes: `SimulationCorpus<Object, Object>` (simulation-api)
- Produces: CDI `@Produces @ApplicationScoped` beans for `SimulationConfig` and `SimulationRuntime`

- [ ] **Step 1: Create `simulation-config/pom.xml`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>
    <parent>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-platform-parent</artifactId>
        <version>0.2-SNAPSHOT</version>
    </parent>

    <artifactId>casehub-platform-simulation-config</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform :: Simulation Config</name>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-simulation-config-core</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-simulation-inmem</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-arc</artifactId>
        </dependency>
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-junit5</artifactId>
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

- [ ] **Step 2: Add module to parent `pom.xml`**

Add `<module>simulation-config</module>` after `<module>simulation-config-core</module>`.

- [ ] **Step 3: Create test resources**

Create `simulation-config/src/test/resources/application.properties`:

```properties
casehub.simulation.test-spi.query.strategy=sequential
casehub.simulation.test-spi.query.exhaustion-policy=WRAP
casehub.simulation.test-spi.store.capture=true
casehub.simulation.test-spi.lookup.strategy=key-lookup
casehub.simulation.test-spi.lookup.key-extractor=field:name
casehub.simulation.corpus.files=classpath:simulation/it-corpus.yaml
```

Create `simulation-config/src/test/resources/simulation/it-corpus.yaml`:

```yaml
test-spi.query:
  - key: first
    tenancy-id: t1
    input: "q1"
    output: "response-1"
  - key: second
    tenancy-id: t1
    input: "q2"
    output: "response-2"

test-spi.lookup:
  - key: alice
    tenancy-id: t1
    input:
      name: alice
      age: 30
    output: "found-alice"
```

- [ ] **Step 4: Write failing integration test**

Create `simulation-config/src/test/java/io/casehub/platform/simulation/config/quarkus/SimulationConfigIT.java`:

```java
package io.casehub.platform.simulation.config.quarkus;

import io.casehub.platform.simulation.SimulationConfig;
import io.casehub.platform.simulation.SimulationRuntime;
import io.casehub.platform.simulation.SimulationStrategy;
import io.quarkus.test.junit.QuarkusTest;
import jakarta.inject.Inject;
import org.junit.jupiter.api.Test;

import java.util.Map;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;

@QuarkusTest
class SimulationConfigIT {

    @Inject
    SimulationConfig config;

    @Inject
    SimulationRuntime runtime;

    @Test
    void configBindsStrategyFromProperties() {
        assertThat(config.strategyFor("test-spi.query")).hasValue("sequential");
    }

    @Test
    void configBindsCaptureFromProperties() {
        assertThat(config.captureEnabled("test-spi.store")).isTrue();
    }

    @Test
    void runtimeResolvesSequentialStrategy() {
        Optional<SimulationStrategy<Object, Object>> strategy =
                runtime.strategyFor("test-spi.query");

        assertThat(strategy).isPresent();
        assertThat(strategy.get().resolve("any")).isEqualTo("response-1");
        assertThat(strategy.get().resolve("any")).isEqualTo("response-2");
    }

    @Test
    void yamlCorpusIsSeededAtStartup() {
        Optional<SimulationStrategy<Object, Object>> strategy =
                runtime.strategyFor("test-spi.query");

        assertThat(strategy).isPresent();
        assertThat(strategy.get().canResolve("any")).isTrue();
    }

    @Test
    void declarativeExtractorWorksWithKeyLookup() {
        Optional<SimulationStrategy<Object, Object>> strategy =
                runtime.strategyFor("test-spi.lookup");

        assertThat(strategy).isPresent();
        Object result = strategy.get().resolve(Map.of("name", "alice", "age", 30));
        assertThat(result).isEqualTo("found-alice");
    }
}
```

- [ ] **Step 5: Run test to verify it fails**

Run: `mvn --batch-mode test -pl simulation-config -Dtest=SimulationConfigIT`
Expected: Failure — `SimulationConfigBeans` does not exist.

- [ ] **Step 6: Implement SimulationConfigBeans**

Create `simulation-config/src/main/java/io/casehub/platform/simulation/config/quarkus/SimulationConfigBeans.java`:

```java
package io.casehub.platform.simulation.config.quarkus;

import io.casehub.platform.simulation.SimulationConfig;
import io.casehub.platform.simulation.SimulationCorpus;
import io.casehub.platform.simulation.SimulationRuntime;
import io.casehub.platform.simulation.config.DeclarativeExtractorFactory;
import io.casehub.platform.simulation.config.SmallRyeSimulationConfig;
import io.casehub.platform.simulation.config.YamlCorpusLoader;
import io.quarkus.runtime.StartupEvent;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.event.Observes;
import jakarta.enterprise.inject.Produces;
import org.eclipse.microprofile.config.ConfigProvider;
import org.eclipse.microprofile.config.inject.ConfigProperty;

import java.util.List;
import java.util.Optional;

@ApplicationScoped
public class SimulationConfigBeans {

    @Produces
    @ApplicationScoped
    public SimulationConfig simulationConfig() {
        return new SmallRyeSimulationConfig(ConfigProvider.getConfig());
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
                   SimulationConfig config,
                   SimulationCorpus corpus,
                   SimulationRuntime runtime,
                   @ConfigProperty(name = "casehub.simulation.corpus.files")
                   Optional<List<String>> corpusFiles) {
        if (corpusFiles.isPresent() && !corpusFiles.get().isEmpty()) {
            var loader = new YamlCorpusLoader();
            var loaded = loader.loadFromPaths(corpusFiles.get());
            loaded.forEach(corpus::seed);
        }

        if (config instanceof SmallRyeSimulationConfig smallRyeConfig) {
            var factory = new DeclarativeExtractorFactory();
            smallRyeConfig.extractorSpecs()
                    .forEach((qn, spec) -> runtime.registerExtractor(qn, factory.create(spec)));
        }
    }
}
```

- [ ] **Step 7: Run integration tests to verify they pass**

Run: `mvn --batch-mode test -pl simulation-config -Dtest=SimulationConfigIT`
Expected: All 5 tests PASS.

- [ ] **Step 8: Run full build to verify no regressions**

Run: `mvn --batch-mode install`
Expected: All modules build and test successfully.

- [ ] **Step 9: Commit**

```bash
git add simulation-config/ pom.xml
git commit -m "feat(#325): SimulationConfigBeans — CDI wiring for simulation config

Produces SimulationConfig and SimulationRuntime. Startup observer loads
YAML corpus files and registers declarative KeyExtractors. Follows
endpoints-config/config module pattern.

Refs #325"
```

---

## Batch 4: Documentation + CLAUDE.md

### Task 5: Update CLAUDE.md and simulation guide

**Files:**
- Modify: `CLAUDE.md` — add simulation-config and simulation-config-core to module table
- Modify: `docs/guides/simulation-guide.md` — update quick start with config module, add YAML corpus section details
- Modify: `docs/guides/consumer-guide.md` — add simulation-config to the simulation module table

**Interfaces:**
- None (documentation only)

- [ ] **Step 1: Update CLAUDE.md module table**

Add after the `simulation-inmem` entry in the module table:

```markdown
| `simulation-config-core/` | `casehub-platform-simulation-config-core` | POJO: SmallRyeSimulationConfig (prefix scanning), YamlCorpusLoader (YAML fixture parsing), DeclarativeExtractorFactory (identity/field/composite extractors). No CDI. Depends on simulation-core + Jackson + SmallRye Config API |
| `simulation-config/` | `casehub-platform-simulation-config` | Quarkus beans: @Produces SimulationConfig + SimulationRuntime + @Startup corpus populator + declarative extractor registration. Classpath-activated. Required alongside simulation-generator for CDI |
```

- [ ] **Step 2: Update simulation guide quick start**

In `docs/guides/simulation-guide.md`, add `simulation-config` to the dependency list in the Quick Start section, after the simulation-inmem dependency:

```xml
<!-- Config binding + YAML corpus + declarative extractors -->
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-platform-simulation-config</artifactId>
</dependency>
```

- [ ] **Step 3: Update consumer guide simulation table**

In `docs/guides/consumer-guide.md`, add to the Simulation table:

```markdown
| `casehub-platform-simulation-config` | Config binding (`application.properties` → `SimulationConfig`), YAML corpus fixtures, declarative KeyExtractors |
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md docs/guides/simulation-guide.md docs/guides/consumer-guide.md
git commit -m "docs(#325): add simulation-config modules to CLAUDE.md, guides

Refs #325"
```

## References

- [2026-09-15-yaml-driven-simulation-config-design.md] — design spec this plan implements
- [simulation-core/SimulationConfig.java:5] — interface to implement
- [simulation-core/SimulationRuntime.java:13] — POJO to produce as CDI bean
- [simulation-api/InvocationRecord.java:5] — record for YAML corpus entries
- [simulation-api/KeyExtractor.java:3] — functional interface for extractors
- [endpoints-config/EndpointsConfigBeans.java:14] — CDI beans pattern to follow
- [endpoints-config-core/EndpointConfigLoader.java:22] — YAML loader pattern
- [GE-20260519-b9719e] — SmallRye Config Map NoSuchElementException
- [GE-20260609-4c6577] — ghost entries with @WithParentName map
- [casehubio/platform#325] — focal issue
- [casehubio/platform#321] — DefaultBean upgrade path (future)
- [casehubio/platform#328] — corpus builders (future)
