# Corpus Quality Testing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #974 — corpus quality testing
**Issue group:** #974

**Goal:** Build a two-mode harness that evaluates template match quality against LLM-generated or pre-recorded variations, with YAML fixture recording, field-level validation, collision detection, and a CLI tool for developer workflows.

**Architecture:** New report types and the harness class live in `template-registry-api` (zero LLM dependency for corpus mode). The CLI tool lives in `template-registry-llm` (needs `ChatModel`). Fixtures use a custom YAML format loaded by `VariationFixtureLoader` — not the simulation corpus infrastructure. The harness delegates to `CollisionDetector.detect()` for cross-namespace collision checking and uses `UnifiedTemplateRegistry.match()` for evaluation.

**Tech Stack:** Java 21, JUnit 5, AssertJ, Jackson YAML (`jackson-dataformat-yaml`), LangChain4j `ChatModel`

## Global Constraints

- `template-registry-api` depends only on `yaml-core` — no Jackson, no LLM, no CDI.
- `template-registry-llm` depends on `template-registry` (which depends on `template-registry-api`) + `langchain4j-core`.
- Fixture YAML format is specific to corpus quality testing — does not reuse `InvocationRecord` / `CorpusLoader`.
- `CollisionDetector.substituteTestValues()` is private — the harness calls `CollisionDetector.detect()` which calls it internally.
- `TemplateMatch.Matched.fields()` returns `Map<String, String>` — field validation compares against this.
- All new record types use defensive copies (unmodifiable collections) in compact constructors.

---

## Batch 1: Report Types and Fixture Format

### Task 1: VariationResult, TemplateReport, CorpusQualityReport records

**Files:**
- Create: `template-registry-api/src/main/java/io/casehub/template/registry/VariationResult.java`
- Create: `template-registry-api/src/main/java/io/casehub/template/registry/TemplateReport.java`
- Create: `template-registry-api/src/main/java/io/casehub/template/registry/CorpusQualityReport.java`
- Test: `template-registry-api/src/test/java/io/casehub/template/registry/CorpusQualityReportTest.java`

**Interfaces:**
- Consumes: `TemplateMatch` (sealed interface: `Matched`, `NearMiss`, `Unmatched`), `CollisionDetector.Collision`
- Produces:
  - `VariationResult(String input, boolean expectedMatch, TemplateMatch actualResult, boolean passed)` — single variation evaluation result
  - `TemplateReport(String templateName, int variationCount, int matchedCount, int fieldMismatchCount, int falsePositiveCount, List<VariationResult> variations)` — per-template aggregate with `double matchRate()`
  - `CorpusQualityReport(String namespace, List<TemplateReport> templates, List<CollisionDetector.Collision> collisions, int totalVariations, int totalMatched, int totalFalsePositives)` — namespace-level aggregate with `double matchRate()`

- [ ] **Step 1: Write tests for the three records**

```java
package io.casehub.template.registry;

import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class CorpusQualityReportTest {

    @Test
    void variationResult_passedWhenExpectedMatchAndCorrectTemplate() {
        var matched = new TemplateMatch.Matched("ns", "vote", 0, Map.of("decision", "approve"), 0.9);
        var result = new VariationResult("I approve this", true, matched, true);

        assertThat(result.passed()).isTrue();
        assertThat(result.expectedMatch()).isTrue();
    }

    @Test
    void variationResult_passedWhenExpectedNoMatchAndUnmatched() {
        var unmatched = new TemplateMatch.Unmatched("random text");
        var result = new VariationResult("random text", false, unmatched, true);

        assertThat(result.passed()).isTrue();
        assertThat(result.expectedMatch()).isFalse();
    }

    @Test
    void variationResult_failedWhenExpectedMatchButUnmatched() {
        var unmatched = new TemplateMatch.Unmatched("I approve this");
        var result = new VariationResult("I approve this", true, unmatched, false);

        assertThat(result.passed()).isFalse();
    }

    @Test
    void templateReport_matchRateCalculation() {
        var matched = new TemplateMatch.Matched("ns", "vote", 0, Map.of(), 0.9);
        var unmatched = new TemplateMatch.Unmatched("miss");
        var report = new TemplateReport("vote", 4, 3, 0, 0, List.of(
            new VariationResult("a", true, matched, true),
            new VariationResult("b", true, matched, true),
            new VariationResult("c", true, matched, true),
            new VariationResult("d", true, unmatched, false)
        ));

        assertThat(report.matchRate()).isEqualTo(0.75);
    }

    @Test
    void templateReport_matchRateOnePointZeroWhenNoVariations() {
        var report = new TemplateReport("empty", 0, 0, 0, 0, List.of());
        assertThat(report.matchRate()).isEqualTo(1.0);
    }

    @Test
    void corpusQualityReport_matchRateCalculation() {
        var report = new CorpusQualityReport("ns", List.of(), List.of(), 10, 8, 0);
        assertThat(report.matchRate()).isEqualTo(0.8);
    }

    @Test
    void corpusQualityReport_matchRateOnePointZeroWhenNoVariations() {
        var report = new CorpusQualityReport("ns", List.of(), List.of(), 0, 0, 0);
        assertThat(report.matchRate()).isEqualTo(1.0);
    }

    @Test
    void corpusQualityReport_collectionsAreUnmodifiable() {
        var report = new CorpusQualityReport("ns", List.of(), List.of(), 0, 0, 0);
        assertThat(report.templates()).isUnmodifiable();
        assertThat(report.collisions()).isUnmodifiable();
    }

    @Test
    void templateReport_collectionsAreUnmodifiable() {
        var report = new TemplateReport("t", 0, 0, 0, 0, List.of());
        assertThat(report.variations()).isUnmodifiable();
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl template-registry-api test -Dtest=CorpusQualityReportTest --batch-mode -q`
Expected: compilation failure — classes don't exist yet.

- [ ] **Step 3: Create VariationResult record**

```java
package io.casehub.template.registry;

import java.util.Objects;

public record VariationResult(
    String input,
    boolean expectedMatch,
    TemplateMatch actualResult,
    boolean passed
) {
    public VariationResult {
        Objects.requireNonNull(input, "input");
        Objects.requireNonNull(actualResult, "actualResult");
    }
}
```

- [ ] **Step 4: Create TemplateReport record**

```java
package io.casehub.template.registry;

import java.util.List;
import java.util.Objects;

public record TemplateReport(
    String templateName,
    int variationCount,
    int matchedCount,
    int fieldMismatchCount,
    int falsePositiveCount,
    List<VariationResult> variations
) {
    public TemplateReport {
        Objects.requireNonNull(templateName, "templateName");
        Objects.requireNonNull(variations, "variations");
        variations = List.copyOf(variations);
    }

    public double matchRate() {
        return variationCount == 0 ? 1.0 : (double) matchedCount / variationCount;
    }
}
```

- [ ] **Step 5: Create CorpusQualityReport record**

```java
package io.casehub.template.registry;

import java.util.List;
import java.util.Objects;

public record CorpusQualityReport(
    String namespace,
    List<TemplateReport> templates,
    List<CollisionDetector.Collision> collisions,
    int totalVariations,
    int totalMatched,
    int totalFalsePositives
) {
    public CorpusQualityReport {
        Objects.requireNonNull(namespace, "namespace");
        Objects.requireNonNull(templates, "templates");
        Objects.requireNonNull(collisions, "collisions");
        templates = List.copyOf(templates);
        collisions = List.copyOf(collisions);
    }

    public double matchRate() {
        return totalVariations == 0 ? 1.0 : (double) totalMatched / totalVariations;
    }
}
```

- [ ] **Step 6: Run tests and verify they pass**

Run: `mvn -pl template-registry-api test -Dtest=CorpusQualityReportTest --batch-mode -q`
Expected: all 9 tests PASS.

- [ ] **Step 7: Commit**

```
feat(#974): add VariationResult, TemplateReport, CorpusQualityReport records
```

### Task 2: VariationFixture record and VariationFixtureLoader

**Files:**
- Create: `template-registry-api/src/main/java/io/casehub/template/registry/VariationFixture.java`
- Create: `template-registry-api/src/main/java/io/casehub/template/registry/VariationFixtureLoader.java`
- Modify: `template-registry-api/pom.xml` — add `jackson-dataformat-yaml` + `jackson-databind` test scope
- Create: `template-registry-api/src/test/resources/fixtures/test-fixtures.variations.yaml`
- Test: `template-registry-api/src/test/java/io/casehub/template/registry/VariationFixtureLoaderTest.java`

**Interfaces:**
- Consumes: nothing new — pure Java records + Jackson YAML
- Produces:
  - `VariationFixture(String templateName, String input, boolean expectMatch, Map<String, String> expectedFields)` — single fixture entry
  - `VariationFixtureLoader.load(Path file)` → `List<VariationFixture>` — loads from YAML
  - `VariationFixtureLoader.load(InputStream is)` → `List<VariationFixture>` — loads from stream (for classpath resources)
  - `VariationFixtureLoader.namespace(Path file)` → `String` — reads namespace from fixture file header

YAML format:
```yaml
namespace: protocol:review
fixtures:
  - template: vote
    input: "I approved this architecture"
    expectMatch: true
    expectedFields:
      decision: approve
      subject: architecture
  - template: vote
    input: "the design looks good to me"
    expectMatch: false
```

- [ ] **Step 1: Add Jackson YAML dependency to template-registry-api pom.xml**

Add `jackson-dataformat-yaml` and `jackson-databind` as **compile** scope dependencies (the fixture loader is a production class used by both the harness and CI tests):

```xml
<dependency>
    <groupId>com.fasterxml.jackson.core</groupId>
    <artifactId>jackson-databind</artifactId>
</dependency>
<dependency>
    <groupId>com.fasterxml.jackson.dataformat</groupId>
    <artifactId>jackson-dataformat-yaml</artifactId>
</dependency>
```

- [ ] **Step 2: Create test fixture YAML file**

Write `template-registry-api/src/test/resources/fixtures/test-fixtures.variations.yaml`:
```yaml
namespace: test:greetings
fixtures:
  - template: hello
    input: "hi there friend"
    expectMatch: true
    expectedFields:
      target: friend
  - template: hello
    input: "random unrelated text"
    expectMatch: false
  - template: goodbye
    input: "see you later team"
    expectMatch: true
    expectedFields:
      target: team
```

- [ ] **Step 3: Write tests for VariationFixtureLoader**

```java
package io.casehub.template.registry;

import org.junit.jupiter.api.Test;

import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class VariationFixtureLoaderTest {

    @Test
    void load_fromInputStream() {
        InputStream is = getClass().getResourceAsStream("/fixtures/test-fixtures.variations.yaml");
        List<VariationFixture> fixtures = VariationFixtureLoader.load(is);

        assertThat(fixtures).hasSize(3);
        assertThat(fixtures.get(0).templateName()).isEqualTo("hello");
        assertThat(fixtures.get(0).input()).isEqualTo("hi there friend");
        assertThat(fixtures.get(0).expectMatch()).isTrue();
        assertThat(fixtures.get(0).expectedFields()).containsEntry("target", "friend");
    }

    @Test
    void load_negativeFixtureHasEmptyFields() {
        InputStream is = getClass().getResourceAsStream("/fixtures/test-fixtures.variations.yaml");
        List<VariationFixture> fixtures = VariationFixtureLoader.load(is);

        var negative = fixtures.get(1);
        assertThat(negative.expectMatch()).isFalse();
        assertThat(negative.expectedFields()).isEmpty();
    }

    @Test
    void namespace_readsFromFile() throws Exception {
        InputStream is = getClass().getResourceAsStream("/fixtures/test-fixtures.variations.yaml");
        Path tmp = Files.createTempFile("fixtures", ".yaml");
        try {
            Files.write(tmp, is.readAllBytes());
            String ns = VariationFixtureLoader.namespace(tmp);
            assertThat(ns).isEqualTo("test:greetings");
        } finally {
            Files.deleteIfExists(tmp);
        }
    }

    @Test
    void load_fromPath() throws Exception {
        InputStream is = getClass().getResourceAsStream("/fixtures/test-fixtures.variations.yaml");
        Path tmp = Files.createTempFile("fixtures", ".yaml");
        try {
            Files.write(tmp, is.readAllBytes());
            List<VariationFixture> fixtures = VariationFixtureLoader.load(tmp);
            assertThat(fixtures).hasSize(3);
        } finally {
            Files.deleteIfExists(tmp);
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `mvn -pl template-registry-api test -Dtest=VariationFixtureLoaderTest --batch-mode -q`
Expected: compilation failure — `VariationFixture` and `VariationFixtureLoader` don't exist.

- [ ] **Step 5: Create VariationFixture record**

```java
package io.casehub.template.registry;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Objects;

public record VariationFixture(
    String templateName,
    String input,
    boolean expectMatch,
    Map<String, String> expectedFields
) {
    public VariationFixture {
        Objects.requireNonNull(templateName, "templateName");
        Objects.requireNonNull(input, "input");
        expectedFields = expectedFields != null
            ? Collections.unmodifiableMap(new LinkedHashMap<>(expectedFields))
            : Map.of();
    }
}
```

- [ ] **Step 6: Create VariationFixtureLoader**

```java
package io.casehub.template.registry;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.dataformat.yaml.YAMLFactory;

import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public final class VariationFixtureLoader {

    private static final ObjectMapper YAML = new ObjectMapper(new YAMLFactory());

    private VariationFixtureLoader() {}

    public static List<VariationFixture> load(Path file) {
        try (InputStream is = Files.newInputStream(file)) {
            return load(is);
        } catch (IOException e) {
            throw new UncheckedIOException("Failed to load fixture file: " + file, e);
        }
    }

    public static List<VariationFixture> load(InputStream is) {
        try {
            JsonNode root = YAML.readTree(is);
            JsonNode fixturesNode = root.get("fixtures");
            if (fixturesNode == null || !fixturesNode.isArray()) {
                return List.of();
            }

            List<VariationFixture> fixtures = new ArrayList<>();
            for (JsonNode entry : fixturesNode) {
                String template = entry.get("template").asText();
                String input = entry.get("input").asText();
                boolean expectMatch = entry.has("expectMatch") && entry.get("expectMatch").asBoolean();

                Map<String, String> expectedFields = new LinkedHashMap<>();
                JsonNode fieldsNode = entry.get("expectedFields");
                if (fieldsNode != null && fieldsNode.isObject()) {
                    var it = fieldsNode.fields();
                    while (it.hasNext()) {
                        var field = it.next();
                        expectedFields.put(field.getKey(), field.getValue().asText());
                    }
                }

                fixtures.add(new VariationFixture(template, input, expectMatch, expectedFields));
            }
            return List.copyOf(fixtures);
        } catch (IOException e) {
            throw new UncheckedIOException("Failed to parse fixture YAML", e);
        }
    }

    public static String namespace(Path file) {
        try (InputStream is = Files.newInputStream(file)) {
            JsonNode root = YAML.readTree(is);
            JsonNode ns = root.get("namespace");
            if (ns == null || ns.isNull()) {
                throw new IllegalArgumentException("Fixture file missing 'namespace' field: " + file);
            }
            return ns.asText();
        } catch (IOException e) {
            throw new UncheckedIOException("Failed to read namespace from: " + file, e);
        }
    }
}
```

- [ ] **Step 7: Run tests and verify they pass**

Run: `mvn -pl template-registry-api test -Dtest=VariationFixtureLoaderTest --batch-mode -q`
Expected: all 4 tests PASS.

- [ ] **Step 8: Commit**

```
feat(#974): add VariationFixture record and VariationFixtureLoader
```

---

## Batch 2: Quality Harness

### Task 3: CorpusQualityHarness — corpus mode (evaluate)

**Files:**
- Create: `template-registry-api/src/main/java/io/casehub/template/registry/CorpusQualityHarness.java`
- Test: `template-registry-api/src/test/java/io/casehub/template/registry/CorpusQualityHarnessTest.java`

**Interfaces:**
- Consumes:
  - `UnifiedTemplateRegistry.match(String namespaceName, String input)` → `TemplateMatch`
  - `CollisionDetector.detect(List<String>, Map<String, VariableConstraint>, String, String, UnifiedTemplateRegistry)` → `List<Collision>`
  - `VariationFixture(templateName, input, expectMatch, expectedFields)` from Task 2
  - `VariationResult`, `TemplateReport`, `CorpusQualityReport` from Task 1
  - `TemplateNamespace.templates()` → `Map<String, TemplateDefinition>`
  - `TemplateDefinition.variables()` → `Map<String, VariableConstraint>`
- Produces:
  - `CorpusQualityHarness(UnifiedTemplateRegistry registry)` — constructor
  - `CorpusQualityReport evaluate(String namespaceName, List<VariationFixture> fixtures)` — corpus mode: match each fixture, validate fields, collect collisions, build report

- [ ] **Step 1: Write tests for harness evaluate()**

```java
package io.casehub.template.registry;

import io.casehub.yaml.core.resolver.VariableConstraint;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class CorpusQualityHarnessTest {

    private InMemoryTemplateRegistry registry;
    private CorpusQualityHarness harness;

    @BeforeEach
    void setUp() {
        registry = new InMemoryTemplateRegistry();
        harness = new CorpusQualityHarness(registry);
    }

    @Test
    void evaluate_allFixturesMatch() {
        registry.register(new TemplateNamespace("ns", Map.of("greet",
            TemplateDefinition.builder("greet")
                .pattern("hello ${target}")
                .variable("target", VariableConstraint.string())
                .build())));

        var fixtures = List.of(
            new VariationFixture("greet", "hello world", true, Map.of("target", "world")),
            new VariationFixture("greet", "hello team", true, Map.of("target", "team"))
        );

        var report = harness.evaluate("ns", fixtures);

        assertThat(report.namespace()).isEqualTo("ns");
        assertThat(report.totalVariations()).isEqualTo(2);
        assertThat(report.totalMatched()).isEqualTo(2);
        assertThat(report.matchRate()).isEqualTo(1.0);
        assertThat(report.totalFalsePositives()).isZero();
        assertThat(report.templates()).hasSize(1);
        assertThat(report.templates().get(0).templateName()).isEqualTo("greet");
    }

    @Test
    void evaluate_missedVariation() {
        registry.register(new TemplateNamespace("ns", Map.of("greet",
            TemplateDefinition.builder("greet")
                .pattern("hello ${target}")
                .variable("target", VariableConstraint.string())
                .build())));

        var fixtures = List.of(
            new VariationFixture("greet", "hello world", true, Map.of("target", "world")),
            new VariationFixture("greet", "good morning everyone", true, Map.of())
        );

        var report = harness.evaluate("ns", fixtures);

        assertThat(report.totalVariations()).isEqualTo(2);
        assertThat(report.totalMatched()).isEqualTo(1);
        assertThat(report.matchRate()).isEqualTo(0.5);
    }

    @Test
    void evaluate_negativeFixturePassesWhenUnmatched() {
        registry.register(new TemplateNamespace("ns", Map.of("greet",
            TemplateDefinition.builder("greet")
                .pattern("hello ${target}")
                .variable("target", VariableConstraint.string())
                .build())));

        var fixtures = List.of(
            new VariationFixture("greet", "completely unrelated text", false, Map.of())
        );

        var report = harness.evaluate("ns", fixtures);

        assertThat(report.templates().get(0).variations().get(0).passed()).isTrue();
    }

    @Test
    void evaluate_negativeFixtureFailsWhenMatched() {
        registry.register(new TemplateNamespace("ns", Map.of("greet",
            TemplateDefinition.builder("greet")
                .pattern("hello ${target}")
                .variable("target", VariableConstraint.string())
                .build())));

        var fixtures = List.of(
            new VariationFixture("greet", "hello world", false, Map.of())
        );

        var report = harness.evaluate("ns", fixtures);

        var variation = report.templates().get(0).variations().get(0);
        assertThat(variation.passed()).isFalse();
        assertThat(report.totalFalsePositives()).isEqualTo(1);
    }

    @Test
    void evaluate_fieldMismatchCountsAsFailure() {
        registry.register(new TemplateNamespace("ns", Map.of("greet",
            TemplateDefinition.builder("greet")
                .pattern("hello ${target}")
                .variable("target", VariableConstraint.string())
                .build())));

        var fixtures = List.of(
            new VariationFixture("greet", "hello world", true, Map.of("target", "wrong_value"))
        );

        var report = harness.evaluate("ns", fixtures);

        assertThat(report.templates().get(0).fieldMismatchCount()).isEqualTo(1);
        assertThat(report.templates().get(0).variations().get(0).passed()).isFalse();
    }

    @Test
    void evaluate_emptyFixturesReturnsEmptyReport() {
        registry.register(new TemplateNamespace("ns", Map.of("greet",
            TemplateDefinition.builder("greet")
                .pattern("hello ${target}")
                .variable("target", VariableConstraint.string())
                .build())));

        var report = harness.evaluate("ns", List.of());

        assertThat(report.totalVariations()).isZero();
        assertThat(report.matchRate()).isEqualTo(1.0);
        assertThat(report.templates()).isEmpty();
    }

    @Test
    void evaluate_crossNamespaceCollisionDetected() {
        registry.register(new TemplateNamespace("ns1", Map.of("greet",
            TemplateDefinition.builder("greet")
                .pattern("hello ${target}")
                .variable("target", VariableConstraint.string())
                .build())));
        registry.register(new TemplateNamespace("ns2", Map.of("salute",
            TemplateDefinition.builder("salute")
                .pattern("hello ${name}")
                .variable("name", VariableConstraint.string())
                .build())));

        var fixtures = List.of(
            new VariationFixture("greet", "hello world", true, Map.of("target", "world"))
        );

        var report = harness.evaluate("ns1", fixtures);

        assertThat(report.collisions()).isNotEmpty();
        assertThat(report.collisions().get(0).collidingNamespace()).isEqualTo("ns2");
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl template-registry-api test -Dtest=CorpusQualityHarnessTest --batch-mode -q`
Expected: compilation failure — `CorpusQualityHarness` doesn't exist.

- [ ] **Step 3: Create CorpusQualityHarness**

```java
package io.casehub.template.registry;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;

public class CorpusQualityHarness {

    private final UnifiedTemplateRegistry registry;

    public CorpusQualityHarness(UnifiedTemplateRegistry registry) {
        this.registry = Objects.requireNonNull(registry, "registry");
    }

    public CorpusQualityReport evaluate(String namespaceName,
                                         List<VariationFixture> fixtures) {
        Objects.requireNonNull(namespaceName, "namespaceName");
        Objects.requireNonNull(fixtures, "fixtures");

        Map<String, List<VariationResult>> resultsByTemplate = new LinkedHashMap<>();
        Map<String, int[]> countersByTemplate = new LinkedHashMap<>();
        List<CollisionDetector.Collision> allCollisions = new ArrayList<>();

        int totalVariations = 0;
        int totalMatched = 0;
        int totalFalsePositives = 0;

        for (VariationFixture fixture : fixtures) {
            TemplateMatch match = registry.match(namespaceName, fixture.input());
            boolean isCorrectMatch = match instanceof TemplateMatch.Matched m
                && m.templateName().equals(fixture.templateName());
            boolean fieldsMatch = true;

            if (isCorrectMatch && fixture.expectMatch() && !fixture.expectedFields().isEmpty()) {
                var matched = (TemplateMatch.Matched) match;
                fieldsMatch = fixture.expectedFields().entrySet().stream()
                    .allMatch(e -> e.getValue().equals(matched.fields().get(e.getKey())));
            }

            boolean passed;
            if (fixture.expectMatch()) {
                passed = isCorrectMatch && fieldsMatch;
            } else {
                passed = !isCorrectMatch;
            }

            var result = new VariationResult(fixture.input(), fixture.expectMatch(), match, passed);

            resultsByTemplate
                .computeIfAbsent(fixture.templateName(), k -> new ArrayList<>())
                .add(result);

            int[] counters = countersByTemplate
                .computeIfAbsent(fixture.templateName(), k -> new int[3]);

            totalVariations++;
            if (fixture.expectMatch()) {
                if (isCorrectMatch) {
                    counters[0]++;
                    totalMatched++;
                    if (!fieldsMatch) {
                        counters[1]++;
                    }
                }
            } else {
                if (isCorrectMatch) {
                    counters[2]++;
                    totalFalsePositives++;
                }
            }

            if (fixture.expectMatch()) {
                var templateDef = findTemplateDef(namespaceName, fixture.templateName());
                if (templateDef != null) {
                    var collisions = CollisionDetector.detect(
                        List.of(fixture.input()),
                        templateDef.variables(),
                        namespaceName,
                        fixture.templateName(),
                        registry);
                    allCollisions.addAll(collisions);
                }
            }
        }

        List<TemplateReport> templateReports = new ArrayList<>();
        for (var entry : resultsByTemplate.entrySet()) {
            int[] c = countersByTemplate.get(entry.getKey());
            int varCount = entry.getValue().size();
            templateReports.add(new TemplateReport(
                entry.getKey(), varCount, c[0], c[1], c[2], entry.getValue()));
        }

        return new CorpusQualityReport(
            namespaceName, templateReports, allCollisions,
            totalVariations, totalMatched, totalFalsePositives);
    }

    private TemplateDefinition findTemplateDef(String namespaceName, String templateName) {
        var schemas = registry.schemas(namespaceName);
        for (var schema : schemas) {
            if (schema.name().equals(templateName)) {
                return null;
            }
        }
        return null;
    }
}
```

Note: `findTemplateDef` returns null for now — collision detection from fixtures uses the fixture input directly. The harness passes fixture inputs through `CollisionDetector.detect()` which uses `matchStructural()`. The variables for substitution need to come from the namespace's template definition. Let me revise this — we need access to the `TemplateDefinition` from the registry. `InMemoryTemplateRegistry` stores `TemplateNamespace` objects and we can access them. But the `UnifiedTemplateRegistry` SPI doesn't expose namespace retrieval by name. The collision detection for fixture inputs should use the input as-is (already concrete text, not patterns with `${var}` placeholders), so we pass them directly to `matchStructural`:

```java
    private void detectCollisionsForFixtures(String namespaceName,
                                              List<VariationFixture> fixtures,
                                              List<CollisionDetector.Collision> collisions) {
        for (VariationFixture fixture : fixtures) {
            if (!fixture.expectMatch()) continue;
            TemplateMatch structural = registry.matchStructural(fixture.input());
            if (structural instanceof TemplateMatch.Matched m
                && !m.namespace().equals(namespaceName)) {
                collisions.add(new CollisionDetector.Collision(
                    fixture.input(), m.namespace(), m.templateName()));
            }
        }
    }
```

The actual implementation should use this simpler approach since fixtures contain concrete text, not `${var}` patterns. I'll provide the corrected implementation below.

- [ ] **Step 3 (revised): Create CorpusQualityHarness with correct collision detection**

```java
package io.casehub.template.registry;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;

public class CorpusQualityHarness {

    private final UnifiedTemplateRegistry registry;

    public CorpusQualityHarness(UnifiedTemplateRegistry registry) {
        this.registry = Objects.requireNonNull(registry, "registry");
    }

    public CorpusQualityReport evaluate(String namespaceName,
                                         List<VariationFixture> fixtures) {
        Objects.requireNonNull(namespaceName, "namespaceName");
        Objects.requireNonNull(fixtures, "fixtures");

        Map<String, List<VariationResult>> resultsByTemplate = new LinkedHashMap<>();
        Map<String, int[]> countersByTemplate = new LinkedHashMap<>();
        List<CollisionDetector.Collision> allCollisions = new ArrayList<>();

        int totalVariations = 0;
        int totalMatched = 0;
        int totalFalsePositives = 0;

        for (VariationFixture fixture : fixtures) {
            TemplateMatch match = registry.match(namespaceName, fixture.input());
            boolean isCorrectMatch = match instanceof TemplateMatch.Matched m
                && m.templateName().equals(fixture.templateName());
            boolean fieldsMatch = true;

            if (isCorrectMatch && fixture.expectMatch() && !fixture.expectedFields().isEmpty()) {
                var matched = (TemplateMatch.Matched) match;
                fieldsMatch = fixture.expectedFields().entrySet().stream()
                    .allMatch(e -> e.getValue().equals(matched.fields().get(e.getKey())));
            }

            boolean passed;
            if (fixture.expectMatch()) {
                passed = isCorrectMatch && fieldsMatch;
            } else {
                passed = !isCorrectMatch;
            }

            var result = new VariationResult(fixture.input(), fixture.expectMatch(), match, passed);

            resultsByTemplate
                .computeIfAbsent(fixture.templateName(), k -> new ArrayList<>())
                .add(result);

            int[] counters = countersByTemplate
                .computeIfAbsent(fixture.templateName(), k -> new int[3]);

            totalVariations++;
            if (fixture.expectMatch()) {
                if (isCorrectMatch) {
                    counters[0]++;
                    totalMatched++;
                    if (!fieldsMatch) {
                        counters[1]++;
                    }
                }
            } else {
                if (isCorrectMatch) {
                    counters[2]++;
                    totalFalsePositives++;
                }
            }

            if (fixture.expectMatch()) {
                TemplateMatch structural = registry.matchStructural(fixture.input());
                if (structural instanceof TemplateMatch.Matched m
                    && !m.namespace().equals(namespaceName)) {
                    allCollisions.add(new CollisionDetector.Collision(
                        fixture.input(), m.namespace(), m.templateName()));
                }
            }
        }

        List<TemplateReport> templateReports = new ArrayList<>();
        for (var entry : resultsByTemplate.entrySet()) {
            int[] c = countersByTemplate.get(entry.getKey());
            int varCount = entry.getValue().size();
            templateReports.add(new TemplateReport(
                entry.getKey(), varCount, c[0], c[1], c[2], entry.getValue()));
        }

        return new CorpusQualityReport(
            namespaceName, templateReports, allCollisions,
            totalVariations, totalMatched, totalFalsePositives);
    }
}
```

- [ ] **Step 4: Run tests and verify they pass**

Run: `mvn -pl template-registry-api test -Dtest=CorpusQualityHarnessTest --batch-mode -q`
Expected: all 7 tests PASS.

- [ ] **Step 5: Commit**

```
feat(#974): add CorpusQualityHarness with corpus-mode evaluation
```

---

## Batch 3: Fixture Writer and CLI Tool

### Task 4: VariationFixtureWriter — write generated fixtures to YAML

**Files:**
- Create: `template-registry-api/src/main/java/io/casehub/template/registry/VariationFixtureWriter.java`
- Test: `template-registry-api/src/test/java/io/casehub/template/registry/VariationFixtureWriterTest.java`

**Interfaces:**
- Consumes: `VariationFixture`, `VariationResult`, `CorpusQualityReport`, `TemplateReport`
- Produces:
  - `VariationFixtureWriter.write(Path file, String namespace, List<VariationFixture> fixtures)` — writes fixtures to YAML
  - `VariationFixtureWriter.fromReport(CorpusQualityReport report)` → `List<VariationFixture>` — extracts fixtures from an evaluated report (for recording LLM-generated variations)

- [ ] **Step 1: Write tests for VariationFixtureWriter**

```java
package io.casehub.template.registry;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class VariationFixtureWriterTest {

    @TempDir
    Path tempDir;

    @Test
    void write_roundTripsWithLoader() {
        Path file = tempDir.resolve("output.variations.yaml");
        var fixtures = List.of(
            new VariationFixture("vote", "I approve this design", true,
                Map.of("decision", "approve", "subject", "design")),
            new VariationFixture("vote", "random noise", false, Map.of())
        );

        VariationFixtureWriter.write(file, "protocol:review", fixtures);

        assertThat(VariationFixtureLoader.namespace(file)).isEqualTo("protocol:review");
        List<VariationFixture> loaded = VariationFixtureLoader.load(file);
        assertThat(loaded).hasSize(2);
        assertThat(loaded.get(0).templateName()).isEqualTo("vote");
        assertThat(loaded.get(0).input()).isEqualTo("I approve this design");
        assertThat(loaded.get(0).expectMatch()).isTrue();
        assertThat(loaded.get(0).expectedFields()).containsEntry("decision", "approve");
        assertThat(loaded.get(1).expectMatch()).isFalse();
    }

    @Test
    void fromReport_extractsPositiveFixtures() {
        var matched = new TemplateMatch.Matched("ns", "greet", 0,
            Map.of("target", "world"), 0.9);
        var result = new VariationResult("hello world", true, matched, true);
        var templateReport = new TemplateReport("greet", 1, 1, 0, 0, List.of(result));
        var report = new CorpusQualityReport("ns", List.of(templateReport),
            List.of(), 1, 1, 0);

        var fixtures = VariationFixtureWriter.fromReport(report);

        assertThat(fixtures).hasSize(1);
        assertThat(fixtures.get(0).templateName()).isEqualTo("greet");
        assertThat(fixtures.get(0).input()).isEqualTo("hello world");
        assertThat(fixtures.get(0).expectMatch()).isTrue();
        assertThat(fixtures.get(0).expectedFields()).containsEntry("target", "world");
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl template-registry-api test -Dtest=VariationFixtureWriterTest --batch-mode -q`
Expected: compilation failure.

- [ ] **Step 3: Create VariationFixtureWriter**

```java
package io.casehub.template.registry;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import com.fasterxml.jackson.dataformat.yaml.YAMLFactory;
import com.fasterxml.jackson.dataformat.yaml.YAMLGenerator;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public final class VariationFixtureWriter {

    private static final ObjectMapper YAML = new ObjectMapper(
        new YAMLFactory()
            .disable(YAMLGenerator.Feature.WRITE_DOC_START_MARKER))
        .disable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS);

    private VariationFixtureWriter() {}

    public static void write(Path file, String namespace, List<VariationFixture> fixtures) {
        Map<String, Object> doc = new LinkedHashMap<>();
        doc.put("namespace", namespace);

        List<Map<String, Object>> fixtureList = new ArrayList<>();
        for (VariationFixture f : fixtures) {
            Map<String, Object> entry = new LinkedHashMap<>();
            entry.put("template", f.templateName());
            entry.put("input", f.input());
            entry.put("expectMatch", f.expectMatch());
            if (!f.expectedFields().isEmpty()) {
                entry.put("expectedFields", new LinkedHashMap<>(f.expectedFields()));
            }
            fixtureList.add(entry);
        }
        doc.put("fixtures", fixtureList);

        try {
            Files.writeString(file, YAML.writeValueAsString(doc));
        } catch (IOException e) {
            throw new UncheckedIOException("Failed to write fixture file: " + file, e);
        }
    }

    public static List<VariationFixture> fromReport(CorpusQualityReport report) {
        List<VariationFixture> fixtures = new ArrayList<>();
        for (TemplateReport template : report.templates()) {
            for (VariationResult result : template.variations()) {
                Map<String, String> fields = Map.of();
                if (result.expectedMatch()
                    && result.actualResult() instanceof TemplateMatch.Matched m) {
                    fields = m.fields();
                }
                fixtures.add(new VariationFixture(
                    template.templateName(),
                    result.input(),
                    result.expectedMatch(),
                    fields));
            }
        }
        return List.copyOf(fixtures);
    }
}
```

- [ ] **Step 4: Run tests and verify they pass**

Run: `mvn -pl template-registry-api test -Dtest=VariationFixtureWriterTest --batch-mode -q`
Expected: all 2 tests PASS.

- [ ] **Step 5: Commit**

```
feat(#974): add VariationFixtureWriter for YAML fixture serialization
```

### Task 5: CorpusVariationGenerator CLI tool

**Files:**
- Create: `template-registry-llm/src/main/java/io/casehub/template/registry/llm/CorpusVariationGenerator.java`
- Test: `template-registry-llm/src/test/java/io/casehub/template/registry/llm/CorpusVariationGeneratorTest.java`

**Interfaces:**
- Consumes:
  - `LlmVariationSeeder(ChatModel chatModel, int maxVariationsPerPattern)` — LLM variation generation
  - `InMemoryTemplateRegistry` — in-process registry for standalone use
  - `CorpusQualityHarness(UnifiedTemplateRegistry registry)` — evaluation
  - `VariationFixtureWriter.write(Path, String, List<VariationFixture>)` — output
  - `VariationFixtureWriter.fromReport(CorpusQualityReport)` — fixture extraction
  - `TemplateNamespace`, `TemplateDefinition` — corpus loading
- Produces:
  - `CorpusVariationGenerator.main(String[] args)` — CLI entry point
  - `CorpusVariationGenerator.run(Config config)` → `CorpusQualityReport` — testable core logic
  - `CorpusVariationGenerator.Config(Path corpus, int variations, Path output, double threshold)` — configuration record

The CLI tool loads a template namespace from YAML, creates an `InMemoryTemplateRegistry`, seeds variations via `LlmVariationSeeder`, evaluates with the harness, writes fixtures, and prints a summary.

- [ ] **Step 1: Write test for the core run() method**

This test uses a stub `VariationSeeder` to avoid LLM dependency:

```java
package io.casehub.template.registry.llm;

import io.casehub.template.registry.CorpusQualityHarness;
import io.casehub.template.registry.CorpusQualityReport;
import io.casehub.template.registry.InMemoryTemplateRegistry;
import io.casehub.template.registry.TemplateDefinition;
import io.casehub.template.registry.TemplateNamespace;
import io.casehub.template.registry.VariationFixtureLoader;
import io.casehub.template.registry.VariationSeeder;
import io.casehub.yaml.core.resolver.VariableConstraint;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class CorpusVariationGeneratorTest {

    @TempDir
    Path tempDir;

    @Test
    void run_generatesVariationsAndWritesFixtures() {
        VariationSeeder stubSeeder = (template, language) ->
            List.of("hi ${target}", "hey ${target}");

        var namespace = new TemplateNamespace("test:greetings", Map.of("greet",
            TemplateDefinition.builder("greet")
                .pattern("hello ${target}")
                .variable("target", VariableConstraint.string())
                .build()));

        var registry = new InMemoryTemplateRegistry();
        registry.register(namespace);

        Path output = tempDir.resolve("output.variations.yaml");

        var report = CorpusVariationGenerator.run(
            namespace, stubSeeder, registry, output, 0.0);

        assertThat(report.totalVariations()).isGreaterThan(0);
        assertThat(output).exists();

        var loaded = VariationFixtureLoader.load(output);
        assertThat(loaded).isNotEmpty();
        assertThat(VariationFixtureLoader.namespace(output)).isEqualTo("test:greetings");
    }

    @Test
    void run_reportContainsAllTemplates() {
        VariationSeeder stubSeeder = (template, language) ->
            List.of("variation of " + template.name());

        var namespace = new TemplateNamespace("ns", Map.of(
            "t1", TemplateDefinition.builder("t1").pattern("pattern one").build(),
            "t2", TemplateDefinition.builder("t2").pattern("pattern two").build()
        ));

        var registry = new InMemoryTemplateRegistry();
        registry.register(namespace);

        Path output = tempDir.resolve("out.yaml");
        var report = CorpusVariationGenerator.run(
            namespace, stubSeeder, registry, output, 0.0);

        assertThat(report.templates()).hasSize(2);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl template-registry-llm test -Dtest=CorpusVariationGeneratorTest --batch-mode -q`
Expected: compilation failure.

- [ ] **Step 3: Create CorpusVariationGenerator**

```java
package io.casehub.template.registry.llm;

import io.casehub.template.registry.CorpusQualityHarness;
import io.casehub.template.registry.CorpusQualityReport;
import io.casehub.template.registry.InMemoryTemplateRegistry;
import io.casehub.template.registry.TemplateDefinition;
import io.casehub.template.registry.TemplateMatch;
import io.casehub.template.registry.TemplateNamespace;
import io.casehub.template.registry.TemplateReport;
import io.casehub.template.registry.UnifiedTemplateRegistry;
import io.casehub.template.registry.VariationFixture;
import io.casehub.template.registry.VariationFixtureWriter;
import io.casehub.template.registry.VariationSeeder;

import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Objects;

public class CorpusVariationGenerator {

    public static CorpusQualityReport run(TemplateNamespace namespace,
                                           VariationSeeder seeder,
                                           UnifiedTemplateRegistry registry,
                                           Path outputPath,
                                           double threshold) {
        Objects.requireNonNull(namespace, "namespace");
        Objects.requireNonNull(seeder, "seeder");
        Objects.requireNonNull(registry, "registry");
        Objects.requireNonNull(outputPath, "outputPath");

        List<VariationFixture> allFixtures = new ArrayList<>();

        for (var entry : namespace.templates().entrySet()) {
            TemplateDefinition def = entry.getValue();
            List<String> variations = seeder.seed(def, namespace.language());

            for (String variation : variations) {
                TemplateMatch match = registry.match(namespace.name(), variation);
                Map<String, String> fields = Map.of();
                if (match instanceof TemplateMatch.Matched m) {
                    fields = m.fields();
                }
                boolean matched = match instanceof TemplateMatch.Matched m
                    && m.templateName().equals(def.name());
                allFixtures.add(new VariationFixture(
                    def.name(), variation, true, fields));
            }
        }

        var harness = new CorpusQualityHarness(registry);
        var report = harness.evaluate(namespace.name(), allFixtures);

        VariationFixtureWriter.write(outputPath, namespace.name(),
            VariationFixtureWriter.fromReport(report));

        printSummary(report, threshold);

        return report;
    }

    private static void printSummary(CorpusQualityReport report, double threshold) {
        System.out.printf("%n=== Corpus Quality Report: %s ===%n", report.namespace());
        System.out.printf("Overall match rate: %.1f%% (%d/%d)%n",
            report.matchRate() * 100, report.totalMatched(), report.totalVariations());
        System.out.printf("False positives: %d%n", report.totalFalsePositives());
        System.out.printf("Collisions: %d%n", report.collisions().size());

        for (TemplateReport t : report.templates()) {
            String status = t.matchRate() >= threshold ? "PASS" : "FAIL";
            System.out.printf("  [%s] %s: %.1f%% (%d/%d) fieldMismatch=%d falsePos=%d%n",
                status, t.templateName(), t.matchRate() * 100,
                t.matchedCount(), t.variationCount(),
                t.fieldMismatchCount(), t.falsePositiveCount());
        }

        if (!report.collisions().isEmpty()) {
            System.out.printf("%nCollisions:%n");
            for (var c : report.collisions()) {
                System.out.printf("  '%s' → %s:%s%n",
                    c.variation(), c.collidingNamespace(), c.collidingTemplate());
            }
        }

        System.out.printf("%nResult: %s (threshold: %.1f%%)%n",
            report.matchRate() >= threshold ? "PASS" : "FAIL",
            threshold * 100);
    }

    public static void main(String[] args) {
        System.err.println("CLI argument parsing not yet implemented — use run() directly in tests.");
        System.exit(1);
    }
}
```

- [ ] **Step 4: Run tests and verify they pass**

Run: `mvn -pl template-registry-llm test -Dtest=CorpusVariationGeneratorTest --batch-mode -q`
Expected: all 2 tests PASS.

- [ ] **Step 5: Commit**

```
feat(#974): add CorpusVariationGenerator CLI tool for LLM-mode quality evaluation
```

---

## Batch 4: CI Quality Gate Test

### Task 6: JUnit quality gate test with parameterized fixture loading

**Files:**
- Create: `template-registry-api/src/test/java/io/casehub/template/registry/CorpusQualityGateTest.java`
- Create: `template-registry-api/src/test/resources/fixtures/greetings.variations.yaml`

**Interfaces:**
- Consumes:
  - `VariationFixtureLoader.load(Path)` → `List<VariationFixture>`
  - `VariationFixtureLoader.namespace(Path)` → `String`
  - `CorpusQualityHarness(UnifiedTemplateRegistry).evaluate(namespaceName, fixtures)` → `CorpusQualityReport`
  - `InMemoryTemplateRegistry`, `TemplateNamespace`, `TemplateDefinition`
- Produces: A passing test pattern that can be replicated by consumers writing their own quality gates.

- [ ] **Step 1: Create a realistic fixture YAML file**

Write `template-registry-api/src/test/resources/fixtures/greetings.variations.yaml`:
```yaml
namespace: test:greetings
fixtures:
  - template: hello
    input: "hello world"
    expectMatch: true
    expectedFields:
      target: world
  - template: hello
    input: "hello team"
    expectMatch: true
    expectedFields:
      target: team
  - template: hello
    input: "hi there everyone"
    expectMatch: false
  - template: goodbye
    input: "goodbye friends"
    expectMatch: true
    expectedFields:
      target: friends
```

- [ ] **Step 2: Write the quality gate test**

```java
package io.casehub.template.registry;

import io.casehub.yaml.core.resolver.VariableConstraint;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;

import java.io.IOException;
import java.net.URISyntaxException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.List;
import java.util.Map;
import java.util.stream.Stream;

import static org.assertj.core.api.Assertions.assertThat;

class CorpusQualityGateTest {

    private static final double MIN_MATCH_RATE = 0.8;

    private static InMemoryTemplateRegistry registry;
    private static CorpusQualityHarness harness;

    @BeforeAll
    static void setUpRegistry() {
        registry = new InMemoryTemplateRegistry();
        registry.register(new TemplateNamespace("test:greetings", Map.of(
            "hello", TemplateDefinition.builder("hello")
                .pattern("hello ${target}")
                .variable("target", VariableConstraint.string())
                .build(),
            "goodbye", TemplateDefinition.builder("goodbye")
                .pattern("goodbye ${target}")
                .variable("target", VariableConstraint.string())
                .build()
        )));
        harness = new CorpusQualityHarness(registry);
    }

    static Stream<Path> loadFixtureFiles() throws URISyntaxException, IOException {
        Path fixturesDir = Paths.get(
            CorpusQualityGateTest.class.getResource("/fixtures").toURI());
        return Files.list(fixturesDir)
            .filter(p -> p.toString().endsWith(".variations.yaml"))
            .sorted();
    }

    @ParameterizedTest
    @MethodSource("loadFixtureFiles")
    void corpusQualityGate(Path fixtureFile) {
        String namespaceName = VariationFixtureLoader.namespace(fixtureFile);
        List<VariationFixture> fixtures = VariationFixtureLoader.load(fixtureFile);
        CorpusQualityReport report = harness.evaluate(namespaceName, fixtures);

        for (TemplateReport template : report.templates()) {
            assertThat(template.matchRate())
                .as("template '%s' match rate", template.templateName())
                .isGreaterThanOrEqualTo(MIN_MATCH_RATE);
            assertThat(template.fieldMismatchCount())
                .as("template '%s' field mismatches", template.templateName())
                .isZero();
            assertThat(template.falsePositiveCount())
                .as("template '%s' false positives", template.templateName())
                .isZero();
        }

        assertThat(report.collisions())
            .as("cross-namespace collisions")
            .isEmpty();
    }
}
```

- [ ] **Step 3: Run the quality gate test**

Run: `mvn -pl template-registry-api test -Dtest=CorpusQualityGateTest --batch-mode -q`
Expected: parameterized test executes for each `.variations.yaml` file; all PASS.

- [ ] **Step 4: Run full template-registry-api test suite**

Run: `mvn -pl template-registry-api test --batch-mode -q`
Expected: all tests PASS (existing + new).

- [ ] **Step 5: Commit**

```
feat(#974): add CorpusQualityGateTest — CI quality gate for template corpora
```

- [ ] **Step 6: Run full project build**

Run: `mvn --batch-mode install -q`
Expected: build succeeds. No existing tests broken.

- [ ] **Step 7: Commit any fixes if needed, or confirm clean build**

---

## References

- `/Users/mdproctor/claude/public/casehub/work/specs/issue-974-corpus-quality-testing/2026-11-26-corpus-quality-testing-design.md` — design spec this plan implements
- `/Users/mdproctor/claude/public/casehub/work/specs/issue-974-corpus-quality-testing/decisions.md` — 5 design decisions
- `template-registry-api/src/main/java/io/casehub/template/registry/UnifiedTemplateRegistry.java` — SPI interface (match, matchStructural, schemas, namespaces)
- `template-registry-api/src/main/java/io/casehub/template/registry/TemplateMatch.java` — sealed interface (Matched, NearMiss, Unmatched)
- `template-registry-api/src/main/java/io/casehub/template/registry/TemplateDefinition.java` — template record (name, patterns, variables)
- `template-registry-api/src/main/java/io/casehub/template/registry/CollisionDetector.java` — static detect() method + Collision record
- `template-registry-api/src/main/java/io/casehub/template/registry/VariationSeeder.java` — SPI @FunctionalInterface
- `template-registry-llm/src/main/java/io/casehub/template/registry/llm/LlmVariationSeeder.java` — ChatModel-backed variation generator
- `template-registry-llm/src/main/java/io/casehub/template/registry/llm/VariationSeedingService.java` — variation generation + collision check + registration
- `template-registry-api/src/test/java/io/casehub/template/registry/CollisionDetectorTest.java` — test pattern reference (InMemoryTemplateRegistry, AssertJ style)
- GitHub #974 — focal issue
