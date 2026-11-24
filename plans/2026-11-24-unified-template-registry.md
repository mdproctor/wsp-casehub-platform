# Unified Template Registry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #959 — feat: unified template registry with NLP-native extraction and schema publication
**Issue group:** #959

**Goal:** Build a unified template registry that replaces the fragmented template matching infrastructure with two new modules: `template-registry-api` (types, SPI, regex matching) and `template-registry` (NLP matching, OpenNLP, schema publication).

**Architecture:** Two-module split (Declaration Primitive API + L4 Extension). The API module holds immutable types (`TemplateDefinition`, `TemplateNamespace`, `TemplateMatch`, `TemplateSchema`), the `UnifiedTemplateRegistry` SPI, regex compilation/matching (inlined from `RegexMessageMatcher`), and the `NlpTokenizer` SPI. The impl module adds NLP structural matching via `StructuralMatcher`, lemmatised keyword filtering via `LemmatisedKeywordFilter`, `OpenNlpTokenizer`, and the `@ApplicationScoped` registry implementation with immutable-snapshot concurrency. A `NoOpUnifiedTemplateRegistry` `@DefaultBean` in `platform-core` provides the displacement pattern.

**Tech Stack:** Java 21, Maven, Apache OpenNLP 2.5.3, Quarkus CDI (`@ApplicationScoped`, `@DefaultBean`), yaml-core `VariableConstraint`, `@McpDomain`/`@PlatformQuery` for schema endpoint

## Global Constraints

- `template-registry-api` must remain zero external dependencies (depends only on `yaml-core`)
- `template-registry` depends on `template-registry-api` + OpenNLP + `mcp-api`
- All types are immutable records with defensive copies
- Thread safety via immutable snapshots with `AtomicReference` CAS (D9)
- `VariableConstraint` from `io.casehub.yaml.core.resolver` is canonical — no new copies
- Package: `io.casehub.template.registry` (api), `io.casehub.template.registry.nlp` (impl)
- English-only NLP (OpenNLP UD-EWT models)
- No `synchronized` blocks (virtual thread pinning)
- Integration test suite is the acceptance criterion (D5)

---

## Batch 1: template-registry-api — Foundation types, regex matching, and SPI

### Task 1: Module scaffolding and core types

**Files:**
- Create: `template-registry-api/pom.xml`
- Create: `template-registry-api/src/main/java/io/casehub/template/registry/TemplateDefinition.java`
- Create: `template-registry-api/src/main/java/io/casehub/template/registry/TemplateNamespace.java`
- Create: `template-registry-api/src/main/java/io/casehub/template/registry/TemplateMatch.java`
- Create: `template-registry-api/src/main/java/io/casehub/template/registry/TemplateSchema.java`
- Create: `template-registry-api/src/main/java/io/casehub/template/registry/NlpTokenizer.java`
- Create: `template-registry-api/src/main/java/io/casehub/template/registry/AnnotatedToken.java`
- Create: `template-registry-api/src/main/java/io/casehub/template/registry/UnifiedTemplateRegistry.java`
- Modify: `pom.xml` (add `<module>template-registry-api</module>`)
- Test: `template-registry-api/src/test/java/io/casehub/template/registry/TemplateDefinitionTest.java`
- Test: `template-registry-api/src/test/java/io/casehub/template/registry/TemplateNamespaceTest.java`
- Test: `template-registry-api/src/test/java/io/casehub/template/registry/TemplateMatchTest.java`

**Interfaces:**
- Produces: `TemplateDefinition(String name, List<String> patterns, Map<String, VariableConstraint> variables)`, `TemplateDefinition.Builder`
- Produces: `TemplateNamespace(String name, Map<String, TemplateDefinition> templates)`
- Produces: `TemplateMatch` sealed interface with `Matched`, `NearMiss`, `Unmatched`
- Produces: `TemplateSchema(String namespace, String templateName, List<String> patterns, Map<String, VariableConstraint> variables, List<StructuralSummary> structuralSummaries)`
- Produces: `NlpTokenizer` functional interface, `AnnotatedToken` record
- Produces: `UnifiedTemplateRegistry` SPI interface

- [ ] **Step 1: Create module POM**

Create `template-registry-api/pom.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0
         https://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>
    <parent>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-platform-parent</artifactId>
        <version>0.4-SNAPSHOT</version>
    </parent>

    <artifactId>casehub-platform-template-registry-api</artifactId>
    <name>CaseHub Platform — Template Registry API</name>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-yaml-core</artifactId>
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

Add `<module>template-registry-api</module>` to the parent `pom.xml` after `message-extraction-api`.

- [ ] **Step 2: Write failing tests for TemplateDefinition**

Create `template-registry-api/src/test/java/io/casehub/template/registry/TemplateDefinitionTest.java`:

```java
package io.casehub.template.registry;

import io.casehub.yaml.core.resolver.VariableConstraint;
import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.Map;
import static org.assertj.core.api.Assertions.*;

class TemplateDefinitionTest {

    @Test
    void builderCreatesDefinition() {
        var def = TemplateDefinition.builder("vote")
            .pattern("I ${decision} this ${subject}")
            .variable("decision", VariableConstraint.enumOf("approve", "reject"))
            .variable("subject", VariableConstraint.string())
            .build();

        assertThat(def.name()).isEqualTo("vote");
        assertThat(def.patterns()).containsExactly("I ${decision} this ${subject}");
        assertThat(def.variables()).containsKeys("decision", "subject");
    }

    @Test
    void multiplePatterns() {
        var def = TemplateDefinition.builder("vote")
            .pattern("I ${decision} this ${subject}")
            .pattern("${decision}")
            .build();

        assertThat(def.patterns()).hasSize(2);
    }

    @Test
    void nullNameThrows() {
        assertThatThrownBy(() -> new TemplateDefinition(null, List.of("pat"), Map.of()))
            .isInstanceOf(NullPointerException.class);
    }

    @Test
    void emptyPatternsThrows() {
        assertThatThrownBy(() -> new TemplateDefinition("x", List.of(), Map.of()))
            .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void patternsAreDefensivelyCopied() {
        var patterns = new java.util.ArrayList<>(List.of("pat"));
        var def = new TemplateDefinition("x", patterns, Map.of());
        patterns.add("extra");
        assertThat(def.patterns()).hasSize(1);
    }

    @Test
    void nullVariablesDefaultsToEmptyMap() {
        var def = new TemplateDefinition("x", List.of("pat"), null);
        assertThat(def.variables()).isEmpty();
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl template-registry-api -Dtest=TemplateDefinitionTest`
Expected: compilation failure (class not found)

- [ ] **Step 4: Implement TemplateDefinition**

Create `template-registry-api/src/main/java/io/casehub/template/registry/TemplateDefinition.java` — record with compact constructor validation, `Builder` inner class. Full code per spec lines 109–129.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl template-registry-api -Dtest=TemplateDefinitionTest`
Expected: all 6 tests pass

- [ ] **Step 6: Write failing tests for TemplateNamespace**

Create `TemplateNamespaceTest.java` testing: valid construction, null name throws, empty templates throws, key/name mismatch throws, defensive copy.

- [ ] **Step 7: Implement TemplateNamespace**

Record with compact constructor per spec lines 137–159.

- [ ] **Step 8: Write failing tests for TemplateMatch**

Create `TemplateMatchTest.java` testing: `Matched` with valid score, `Matched` with score out of range throws, `Matched` with zero score throws, `NearMiss` with nulls throws, `Unmatched` with null throws, fields are defensively copied.

- [ ] **Step 9: Implement TemplateMatch**

Sealed interface with three records per spec lines 167–209.

- [ ] **Step 10: Implement remaining types**

Create `TemplateSchema.java` (record per spec lines 220–240), `NlpTokenizer.java` (`@FunctionalInterface` per spec lines 292–295), `AnnotatedToken.java` (record with compact constructor per spec lines 297–309), `UnifiedTemplateRegistry.java` (interface per spec lines 248–274).

- [ ] **Step 11: Run all tests and commit**

Run: `mvn --batch-mode test -pl template-registry-api`
Expected: all tests pass

```bash
git add template-registry-api/ pom.xml
git commit -m "feat(#959): add template-registry-api module with core types and SPI

Refs #959

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 2: Regex compilation, matching, and generation

**Files:**
- Create: `template-registry-api/src/main/java/io/casehub/template/registry/RegexTemplateCompiler.java`
- Create: `template-registry-api/src/main/java/io/casehub/template/registry/CompiledTemplate.java`
- Create: `template-registry-api/src/main/java/io/casehub/template/registry/TemplateGenerator.java`
- Create: `template-registry-api/src/main/java/io/casehub/template/registry/InMemoryTemplateRegistry.java`
- Test: `template-registry-api/src/test/java/io/casehub/template/registry/RegexTemplateCompilerTest.java`
- Test: `template-registry-api/src/test/java/io/casehub/template/registry/TemplateGeneratorTest.java`
- Test: `template-registry-api/src/test/java/io/casehub/template/registry/InMemoryTemplateRegistryTest.java`

**Interfaces:**
- Consumes: `TemplateDefinition`, `TemplateNamespace`, `TemplateMatch`, `VariableConstraint`
- Produces: `RegexTemplateCompiler.compile(String pattern) → CompiledTemplate`
- Produces: `CompiledTemplate.extract(String input) → Optional<Map<String, String>>`
- Produces: `CompiledTemplate.extract(String input, Map<String, VariableConstraint> constraints) → Optional<Map<String, String>>`
- Produces: `TemplateGenerator.generate(TemplateDefinition def, Map<String, String> values) → String`
- Produces: `InMemoryTemplateRegistry implements UnifiedTemplateRegistry` (regex-only, in-memory)

- [ ] **Step 1: Write failing tests for RegexTemplateCompiler**

```java
package io.casehub.template.registry;

import io.casehub.yaml.core.resolver.VariableConstraint;
import org.junit.jupiter.api.Test;
import java.util.Map;
import static org.assertj.core.api.Assertions.*;

class RegexTemplateCompilerTest {

    @Test
    void simpleExtraction() {
        var compiled = RegexTemplateCompiler.compile("I ${decision} this ${subject}");
        var result = compiled.extract("I approve this design");
        assertThat(result).isPresent();
        assertThat(result.get()).containsEntry("decision", "approve")
            .containsEntry("subject", "design");
    }

    @Test
    void optionalSegmentPresent() {
        var compiled = RegexTemplateCompiler.compile(
            "I ${decision} this ${subject}[ because ${rationale}]");
        var result = compiled.extract("I approve this design because it is clean");
        assertThat(result).isPresent();
        assertThat(result.get()).containsEntry("rationale", "it is clean");
    }

    @Test
    void optionalSegmentAbsent() {
        var compiled = RegexTemplateCompiler.compile(
            "I ${decision} this ${subject}[ because ${rationale}]");
        var result = compiled.extract("I approve this design");
        assertThat(result).isPresent();
        assertThat(result.get()).containsKey("decision")
            .doesNotContainKey("rationale");
    }

    @Test
    void noMatchReturnsEmpty() {
        var compiled = RegexTemplateCompiler.compile("I ${decision} this ${subject}");
        var result = compiled.extract("Something completely different");
        assertThat(result).isEmpty();
    }

    @Test
    void enumConstraintPasses() {
        var compiled = RegexTemplateCompiler.compile("I ${decision} this");
        var constraints = Map.of("decision",
            VariableConstraint.enumOf("approve", "reject"));
        var result = compiled.extract("I approve this", constraints);
        assertThat(result).isPresent();
    }

    @Test
    void enumConstraintFails() {
        var compiled = RegexTemplateCompiler.compile("I ${decision} this");
        var constraints = Map.of("decision",
            VariableConstraint.enumOf("approve", "reject"));
        var result = compiled.extract("I maybe this", constraints);
        assertThat(result).isEmpty();
    }

    @Test
    void variableNames() {
        var compiled = RegexTemplateCompiler.compile(
            "I ${decision} this ${subject}");
        assertThat(compiled.variableNames())
            .containsExactly("decision", "subject");
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl template-registry-api -Dtest=RegexTemplateCompilerTest`
Expected: compilation failure

- [ ] **Step 3: Implement RegexTemplateCompiler and CompiledTemplate**

Port the compilation logic from `TemplateExtractor.compile()` and `RegexMessageMatcher.compileTemplate()`. The `CompiledTemplate` holds the compiled `Pattern`, variable names, and original template string. `extract()` with constraints validates via `VariableConstraint` (same logic as `TemplateExtractor.extract(input, constraints)`).

Key: `RegexTemplateCompiler` is a static utility. `CompiledTemplate` is the compiled result with `extract()` methods.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl template-registry-api -Dtest=RegexTemplateCompilerTest`
Expected: all 7 tests pass

- [ ] **Step 5: Write failing tests for TemplateGenerator**

```java
package io.casehub.template.registry;

import io.casehub.yaml.core.resolver.VariableConstraint;
import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.Map;
import static org.assertj.core.api.Assertions.*;

class TemplateGeneratorTest {

    @Test
    void simpleSubstitution() {
        var def = new TemplateDefinition("vote",
            List.of("I ${decision} this ${subject}"), Map.of());
        var result = TemplateGenerator.generate(def, Map.of(
            "decision", "approve", "subject", "design"));
        assertThat(result).isEqualTo("I approve this design");
    }

    @Test
    void optionalSegmentIncludedWhenAllPresent() {
        var def = new TemplateDefinition("vote",
            List.of("I ${decision} this[ because ${rationale}]"), Map.of());
        var result = TemplateGenerator.generate(def, Map.of(
            "decision", "approve", "rationale", "it is clean"));
        assertThat(result).isEqualTo("I approve this because it is clean");
    }

    @Test
    void optionalSegmentOmittedWhenMissing() {
        var def = new TemplateDefinition("vote",
            List.of("I ${decision} this[ because ${rationale}]"), Map.of());
        var result = TemplateGenerator.generate(def, Map.of(
            "decision", "approve"));
        assertThat(result).isEqualTo("I approve this");
    }

    @Test
    void missingRequiredVariableThrows() {
        var def = new TemplateDefinition("vote",
            List.of("I ${decision} this ${subject}"), Map.of());
        assertThatThrownBy(() -> TemplateGenerator.generate(def, Map.of(
            "decision", "approve")))
            .isInstanceOf(IllegalArgumentException.class)
            .hasMessageContaining("subject");
    }

    @Test
    void usesPatternZero() {
        var def = new TemplateDefinition("vote",
            List.of("I ${decision} this ${subject}", "${decision}"),
            Map.of());
        var result = TemplateGenerator.generate(def, Map.of(
            "decision", "approve", "subject", "design"));
        assertThat(result).isEqualTo("I approve this design");
    }
}
```

- [ ] **Step 6: Implement TemplateGenerator**

Segment-aware template expansion per spec §Generation lines 312–323. Parse segments using the same bracket-aware logic as `TemplateExtractor.parseSegments()`. Substitute `${var}` in each segment. Include optional segments only when all their variables have values. Throw `IllegalArgumentException` on unresolved mandatory variables.

- [ ] **Step 7: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl template-registry-api -Dtest=TemplateGeneratorTest`
Expected: all 5 tests pass

- [ ] **Step 8: Write failing tests for InMemoryTemplateRegistry**

```java
package io.casehub.template.registry;

import io.casehub.yaml.core.resolver.VariableConstraint;
import org.junit.jupiter.api.Test;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import static org.assertj.core.api.Assertions.*;

class InMemoryTemplateRegistryTest {

    private TemplateNamespace reviewNamespace() {
        var vote = TemplateDefinition.builder("vote")
            .pattern("I ${decision} this ${subject}[ because ${rationale}]")
            .variable("decision", VariableConstraint.enumOf("approve", "reject", "abstain"))
            .variable("subject", VariableConstraint.string())
            .variable("rationale", VariableConstraint.string().optional())
            .build();
        var escalate = TemplateDefinition.builder("escalate")
            .pattern("Escalating to ${target}[ due to ${reason}]")
            .variable("target", VariableConstraint.string())
            .variable("reason", VariableConstraint.string().optional())
            .build();
        var templates = new LinkedHashMap<String, TemplateDefinition>();
        templates.put("vote", vote);
        templates.put("escalate", escalate);
        return new TemplateNamespace("protocol:review", templates);
    }

    @Test
    void matchExact() {
        var registry = new InMemoryTemplateRegistry();
        registry.register(reviewNamespace());

        var result = registry.match("protocol:review",
            "I approve this design");
        assertThat(result).isInstanceOf(TemplateMatch.Matched.class);
        var matched = (TemplateMatch.Matched) result;
        assertThat(matched.namespace()).isEqualTo("protocol:review");
        assertThat(matched.templateName()).isEqualTo("vote");
        assertThat(matched.fields()).containsEntry("decision", "approve");
        assertThat(matched.score()).isEqualTo(1.0);
    }

    @Test
    void matchGlobalSearchesAllNamespaces() {
        var registry = new InMemoryTemplateRegistry();
        registry.register(reviewNamespace());

        var result = registry.match("I approve this design");
        assertThat(result).isInstanceOf(TemplateMatch.Matched.class);
    }

    @Test
    void noMatch() {
        var registry = new InMemoryTemplateRegistry();
        registry.register(reviewNamespace());

        var result = registry.match("protocol:review",
            "Something unrelated");
        assertThat(result).isInstanceOf(TemplateMatch.Unmatched.class);
    }

    @Test
    void duplicateNamespaceThrows() {
        var registry = new InMemoryTemplateRegistry();
        registry.register(reviewNamespace());
        assertThatThrownBy(() -> registry.register(reviewNamespace()))
            .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void deregisterAllowsReRegister() {
        var registry = new InMemoryTemplateRegistry();
        registry.register(reviewNamespace());
        registry.deregister("protocol:review");
        registry.register(reviewNamespace());
    }

    @Test
    void unknownNamespaceThrows() {
        var registry = new InMemoryTemplateRegistry();
        assertThatThrownBy(() -> registry.match("unknown", "input"))
            .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void generateSlotFilling() {
        var registry = new InMemoryTemplateRegistry();
        registry.register(reviewNamespace());

        var surface = registry.generate("protocol:review", "vote",
            Map.of("decision", "approve", "subject", "design"));
        assertThat(surface).isEqualTo("I approve this design");
    }

    @Test
    void schemaAvailable() {
        var registry = new InMemoryTemplateRegistry();
        registry.register(reviewNamespace());

        var schema = registry.schema("protocol:review", "vote");
        assertThat(schema).isPresent();
        assertThat(schema.get().patterns()).hasSize(1);
        assertThat(schema.get().variables()).containsKey("decision");
    }

    @Test
    void constraintValidation() {
        var registry = new InMemoryTemplateRegistry();
        registry.register(reviewNamespace());

        var result = registry.match("protocol:review",
            "I maybe this design");
        assertThat(result).isInstanceOf(TemplateMatch.Unmatched.class);
    }

    @Test
    void namespacesReturnsRegistered() {
        var registry = new InMemoryTemplateRegistry();
        registry.register(reviewNamespace());
        assertThat(registry.namespaces()).containsExactly("protocol:review");
    }
}
```

- [ ] **Step 9: Implement InMemoryTemplateRegistry**

Regex-only implementation using `RegexTemplateCompiler` and `TemplateGenerator`. Immutable-snapshot concurrency via `AtomicReference`. First-match-wins for regex in registration order. `schema()` returns schemas without structural summaries (NLP not on classpath).

- [ ] **Step 10: Run all tests and commit**

Run: `mvn --batch-mode test -pl template-registry-api`
Expected: all tests pass

```bash
git add template-registry-api/
git commit -m "feat(#959): add regex compilation, generation, and InMemoryTemplateRegistry

Refs #959

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

## Batch 2: template-registry — NLP tier and two-tier matching

### Task 3: OpenNlpTokenizer migration, LemmatisedKeywordFilter, and StructuralMatcher

**Files:**
- Create: `template-registry/pom.xml`
- Create: `template-registry/src/main/java/io/casehub/template/registry/nlp/OpenNlpTokenizer.java`
- Create: `template-registry/src/main/java/io/casehub/template/registry/nlp/LemmatisedKeywordFilter.java`
- Create: `template-registry/src/main/java/io/casehub/template/registry/nlp/StructuralMatcher.java`
- Modify: `pom.xml` (add `<module>template-registry</module>`)
- Test: `template-registry/src/test/java/io/casehub/template/registry/nlp/OpenNlpTokenizerTest.java`
- Test: `template-registry/src/test/java/io/casehub/template/registry/nlp/LemmatisedKeywordFilterTest.java`
- Test: `template-registry/src/test/java/io/casehub/template/registry/nlp/StructuralMatcherTest.java`

**Interfaces:**
- Consumes: `NlpTokenizer`, `AnnotatedToken`, `VariableConstraint` from template-registry-api
- Produces: `OpenNlpTokenizer implements NlpTokenizer` — tokenization, POS tagging, lemmatisation
- Produces: `LemmatisedKeywordFilter.extract(String template, NlpTokenizer) → Set<String>` — lemmatised keyword set
- Produces: `LemmatisedKeywordFilter.affinity(Set<String> keywords, List<AnnotatedToken> inputTokens) → double` — lemma-overlap score
- Produces: `StructuralMatcher` — structural element list compiled from template + NlpTokenizer, `match(List<AnnotatedToken>, Map<String, VariableConstraint>) → Optional<MatchResult>`

- [ ] **Step 1: Create module POM**

Create `template-registry/pom.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0
         https://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>
    <parent>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-platform-parent</artifactId>
        <version>0.4-SNAPSHOT</version>
    </parent>

    <artifactId>casehub-platform-template-registry</artifactId>
    <name>CaseHub Platform — Template Registry</name>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-template-registry-api</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>org.apache.opennlp</groupId>
            <artifactId>opennlp-tools</artifactId>
        </dependency>
        <dependency>
            <groupId>org.apache.opennlp</groupId>
            <artifactId>opennlp-models-tokenizer-en</artifactId>
        </dependency>
        <dependency>
            <groupId>org.apache.opennlp</groupId>
            <artifactId>opennlp-models-pos-en</artifactId>
        </dependency>
        <dependency>
            <groupId>org.apache.opennlp</groupId>
            <artifactId>opennlp-models-lemmatizer-en</artifactId>
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

Add `<module>template-registry</module>` to parent `pom.xml` after `template-registry-api`.

- [ ] **Step 2: Write failing tests for OpenNlpTokenizer**

```java
package io.casehub.template.registry.nlp;

import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class OpenNlpTokenizerTest {

    private final OpenNlpTokenizer tokenizer = new OpenNlpTokenizer();

    @Test
    void tokenizesSimpleSentence() {
        var tokens = tokenizer.tokenize("I approve this design");
        assertThat(tokens).hasSizeGreaterThanOrEqualTo(4);
        assertThat(tokens.get(0).surface()).isEqualTo("I");
    }

    @Test
    void lemmatizesVerb() {
        var tokens = tokenizer.tokenize("She approved the architecture");
        var approved = tokens.stream()
            .filter(t -> t.surface().equals("approved"))
            .findFirst().orElseThrow();
        assertThat(approved.lemma()).isEqualTo("approve");
    }

    @Test
    void posTagsPresent() {
        var tokens = tokenizer.tokenize("I approve this design");
        assertThat(tokens).allSatisfy(t -> {
            assertThat(t.pos()).isNotEmpty();
            assertThat(t.start()).isGreaterThanOrEqualTo(0);
            assertThat(t.end()).isGreaterThan(t.start());
        });
    }
}
```

- [ ] **Step 3: Implement OpenNlpTokenizer**

Migrate from `message-extraction/src/main/java/io/casehub/extraction/nlp/OpenNlpTokenizer.java`. Implements `NlpTokenizer` from template-registry-api. Same lazy model loading, same thread-safety (models shared, ME instances per-call).

- [ ] **Step 4: Write failing tests for LemmatisedKeywordFilter**

```java
package io.casehub.template.registry.nlp;

import io.casehub.template.registry.AnnotatedToken;
import org.junit.jupiter.api.Test;
import java.util.Set;
import static org.assertj.core.api.Assertions.*;

class LemmatisedKeywordFilterTest {

    private final OpenNlpTokenizer tokenizer = new OpenNlpTokenizer();

    @Test
    void extractsContentLemmas() {
        var keywords = LemmatisedKeywordFilter.extract(
            "I ${decision} this ${subject}", tokenizer);
        assertThat(keywords).isNotEmpty();
        assertThat(keywords).doesNotContain("i", "this");
    }

    @Test
    void morphologicalAffinity() {
        var keywords = LemmatisedKeywordFilter.extract(
            "Escalating to ${target}", tokenizer);
        var inputTokens = tokenizer.tokenize("I escalated to the manager");
        double affinity = LemmatisedKeywordFilter.affinity(
            keywords, inputTokens);
        assertThat(affinity).isGreaterThan(0.0);
    }

    @Test
    void noAffinityForUnrelatedInput() {
        var keywords = LemmatisedKeywordFilter.extract(
            "Escalating to ${target}", tokenizer);
        var inputTokens = tokenizer.tokenize("The weather is nice today");
        double affinity = LemmatisedKeywordFilter.affinity(
            keywords, inputTokens);
        assertThat(affinity).isEqualTo(0.0);
    }
}
```

- [ ] **Step 5: Implement LemmatisedKeywordFilter**

Evolve from `TemplateKeywords` in coordination-core. `extract()` strips `${var}` patterns and brackets, tokenises via `NlpTokenizer`, filters stop words, returns lemma set. `affinity()` computes lemma overlap score.

- [ ] **Step 6: Write failing tests for StructuralMatcher**

```java
package io.casehub.template.registry.nlp;

import io.casehub.template.registry.AnnotatedToken;
import io.casehub.yaml.core.resolver.VariableConstraint;
import org.junit.jupiter.api.Test;
import java.util.Map;
import static org.assertj.core.api.Assertions.*;

class StructuralMatcherTest {

    private final OpenNlpTokenizer tokenizer = new OpenNlpTokenizer();

    @Test
    void exactMatchScoresHigh() {
        var matcher = StructuralMatcher.compile(
            "I ${decision} this ${subject}", tokenizer);
        var tokens = tokenizer.tokenize("I approve this design");
        var result = matcher.match(tokens, Map.of());
        assertThat(result).isPresent();
        assertThat(result.get().score()).isGreaterThan(0.5);
    }

    @Test
    void tenseVariation() {
        var matcher = StructuralMatcher.compile(
            "I ${decision} this ${subject}", tokenizer);
        var tokens = tokenizer.tokenize("I approved this design");
        var result = matcher.match(tokens, Map.of());
        assertThat(result).isPresent();
        assertThat(result.get().fields()).containsKey("decision");
    }

    @Test
    void enumConstraintByLemma() {
        var matcher = StructuralMatcher.compile(
            "I ${decision} this ${subject}", tokenizer);
        var constraints = Map.of("decision",
            VariableConstraint.enumOf("approve", "reject"));
        var tokens = tokenizer.tokenize("I approved this design");
        var result = matcher.match(tokens, constraints);
        assertThat(result).isPresent();
        assertThat(result.get().fields().get("decision")).isEqualTo("approve");
    }

    @Test
    void noMatchForUnrelated() {
        var matcher = StructuralMatcher.compile(
            "I ${decision} this ${subject}", tokenizer);
        var tokens = tokenizer.tokenize("The weather is nice today");
        var result = matcher.match(tokens, Map.of());
        assertThat(result).isEmpty();
    }

    @Test
    void clauseCapture() {
        var matcher = StructuralMatcher.compile(
            "Escalating to ${target} because ${reason}", tokenizer);
        var tokens = tokenizer.tokenize(
            "Escalating to the manager because the deadline is tomorrow");
        var result = matcher.match(tokens, Map.of());
        assertThat(result).isPresent();
        assertThat(result.get().fields().get("reason")).contains("deadline");
    }
}
```

- [ ] **Step 7: Implement StructuralMatcher**

Evolve from `StructuralPattern` in message-extraction. Compile template literal segments via NlpTokenizer into structural elements (LITERAL, VARIABLE, CLAUSE). `match()` walks elements against input tokens — LITERAL matches by lemma, VARIABLE captures single token, CLAUSE captures to next anchor. Score = matched/total.

- [ ] **Step 8: Run all tests and commit**

Run: `mvn --batch-mode test -pl template-registry`
Expected: all tests pass

```bash
git add template-registry/ pom.xml
git commit -m "feat(#959): add template-registry module with NLP matching components

Refs #959

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 4: NlpTemplateRegistry — two-tier matching with immutable snapshots

**Files:**
- Create: `template-registry/src/main/java/io/casehub/template/registry/nlp/NlpTemplateRegistry.java`
- Create: `template-registry/src/main/java/io/casehub/template/registry/nlp/NlpTemplateCompiler.java`
- Create: `template-registry/src/main/java/io/casehub/template/registry/nlp/RegistrySnapshot.java`
- Test: `template-registry/src/test/java/io/casehub/template/registry/nlp/NlpTemplateRegistryTest.java`

**Interfaces:**
- Consumes: `UnifiedTemplateRegistry` SPI, `InMemoryTemplateRegistry` (for regex tier), `StructuralMatcher`, `LemmatisedKeywordFilter`, `OpenNlpTokenizer`
- Produces: `NlpTemplateRegistry implements UnifiedTemplateRegistry` — full two-tier matching, immutable snapshots, schema with structural summaries

- [ ] **Step 1: Write failing tests for NlpTemplateRegistry**

```java
package io.casehub.template.registry.nlp;

import io.casehub.template.registry.*;
import io.casehub.yaml.core.resolver.VariableConstraint;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import static org.assertj.core.api.Assertions.*;

class NlpTemplateRegistryTest {

    private NlpTemplateRegistry registry;

    @BeforeEach
    void setUp() {
        registry = new NlpTemplateRegistry(new OpenNlpTokenizer());
        var vote = TemplateDefinition.builder("vote")
            .pattern("I ${decision} this ${subject}")
            .variable("decision", VariableConstraint.enumOf("approve", "reject"))
            .variable("subject", VariableConstraint.string())
            .build();
        var templates = new LinkedHashMap<String, TemplateDefinition>();
        templates.put("vote", vote);
        registry.register(new TemplateNamespace("protocol:review", templates));
    }

    @Test
    void regexTierMatchesExact() {
        var result = registry.match("protocol:review", "I approve this design");
        assertThat(result).isInstanceOf(TemplateMatch.Matched.class);
        var matched = (TemplateMatch.Matched) result;
        assertThat(matched.score()).isEqualTo(1.0);
    }

    @Test
    void nlpTierMatchesTenseVariation() {
        var result = registry.match("protocol:review", "I approved this design");
        assertThat(result).isInstanceOf(TemplateMatch.Matched.class);
        var matched = (TemplateMatch.Matched) result;
        assertThat(matched.score()).isLessThan(1.0);
        assertThat(matched.score()).isGreaterThan(0.5);
        assertThat(matched.fields()).containsEntry("decision", "approve");
    }

    @Test
    void nlpTierMatchesPluralVariation() {
        var result = registry.match("protocol:review", "I approve these designs");
        assertThat(result).isInstanceOf(TemplateMatch.Matched.class);
    }

    @Test
    void noMatchReturnsUnmatched() {
        var result = registry.match("protocol:review", "The weather is nice");
        assertThat(result).isInstanceOf(TemplateMatch.Unmatched.class);
    }

    @Test
    void schemaIncludesStructuralSummaries() {
        var schema = registry.schema("protocol:review", "vote");
        assertThat(schema).isPresent();
        assertThat(schema.get().structuralSummaries()).isNotEmpty();
    }

    @Test
    void concurrentRegistration() throws Exception {
        var threads = new Thread[10];
        for (int i = 0; i < threads.length; i++) {
            final int idx = i;
            threads[i] = Thread.ofVirtual().start(() -> {
                var def = TemplateDefinition.builder("t" + idx)
                    .pattern("Template ${var" + idx + "}")
                    .build();
                var templates = new LinkedHashMap<String, TemplateDefinition>();
                templates.put("t" + idx, def);
                registry.register(new TemplateNamespace("ns:" + idx, templates));
            });
        }
        for (var t : threads) t.join();
        assertThat(registry.namespaces()).hasSize(11);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl template-registry -Dtest=NlpTemplateRegistryTest`
Expected: compilation failure

- [ ] **Step 3: Implement NlpTemplateCompiler and RegistrySnapshot**

`NlpTemplateCompiler` compiles templates into `StructuralMatcher` instances and lemmatised keyword sets. `RegistrySnapshot` is an immutable data class holding the compiled state: namespace map, regex-compiled templates, NLP-compiled structural matchers, keyword sets.

- [ ] **Step 4: Implement NlpTemplateRegistry**

`NlpTemplateRegistry implements UnifiedTemplateRegistry`. Constructor takes `NlpTokenizer`. Uses `AtomicReference<RegistrySnapshot>` for immutable-snapshot concurrency. `register()` builds new snapshot with CAS retry. `match()` does two-tier: regex first (via `CompiledTemplate`), NLP fallback with keyword filtering (via `LemmatisedKeywordFilter`) then structural matching (via `StructuralMatcher`). `generate()` delegates to `TemplateGenerator`. `schema()` returns schemas with structural summaries populated from NLP compilation.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl template-registry -Dtest=NlpTemplateRegistryTest`
Expected: all tests pass

- [ ] **Step 6: Run all module tests and commit**

Run: `mvn --batch-mode test -pl template-registry`
Expected: all tests pass

```bash
git add template-registry/
git commit -m "feat(#959): add NlpTemplateRegistry with two-tier matching

Refs #959

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

## Batch 3: Platform integration, @McpDomain, and integration tests

### Task 5: NoOp @DefaultBean and @McpDomain endpoint

**Files:**
- Create: `platform-core/src/main/java/io/casehub/platform/template/NoOpUnifiedTemplateRegistry.java`
- Create: `template-registry/src/main/java/io/casehub/template/registry/nlp/TemplateRegistryBeans.java`
- Create: `template-registry/src/main/java/io/casehub/template/registry/nlp/TemplateSchemaEndpoint.java`
- Modify: `platform-core/pom.xml` (add template-registry-api dependency)
- Modify: `template-registry/pom.xml` (add mcp-api dependency)
- Test: `platform-core/src/test/java/io/casehub/platform/template/NoOpUnifiedTemplateRegistryTest.java`
- Test: `template-registry/src/test/java/io/casehub/template/registry/nlp/TemplateSchemaEndpointTest.java`

**Interfaces:**
- Consumes: `UnifiedTemplateRegistry`, `TemplateMatch`, `TemplateSchema`, `NlpTemplateRegistry`
- Produces: `NoOpUnifiedTemplateRegistry` `@DefaultBean` (returns Unmatched, empty schemas, throws on generate)
- Produces: `TemplateRegistryBeans` `@Produces @ApplicationScoped NlpTemplateRegistry`
- Produces: `TemplateSchemaEndpoint @McpDomain("template-schemas")` with `@PlatformQuery` methods

- [ ] **Step 1: Write failing test for NoOp**

```java
package io.casehub.platform.template;

import io.casehub.template.registry.TemplateMatch;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class NoOpUnifiedTemplateRegistryTest {

    private final NoOpUnifiedTemplateRegistry registry = new NoOpUnifiedTemplateRegistry();

    @Test
    void matchReturnsUnmatched() {
        var result = registry.match("any input");
        assertThat(result).isInstanceOf(TemplateMatch.Unmatched.class);
    }

    @Test
    void matchWithNamespaceReturnsUnmatched() {
        var result = registry.match("ns", "any input");
        assertThat(result).isInstanceOf(TemplateMatch.Unmatched.class);
    }

    @Test
    void generateThrows() {
        assertThatThrownBy(() -> registry.generate("ns", "t", java.util.Map.of()))
            .isInstanceOf(UnsupportedOperationException.class);
    }

    @Test
    void schemasReturnsEmpty() {
        assertThat(registry.schemas("ns")).isEmpty();
    }

    @Test
    void namespacesReturnsEmpty() {
        assertThat(registry.namespaces()).isEmpty();
    }
}
```

- [ ] **Step 2: Implement NoOpUnifiedTemplateRegistry**

Follows the established NoOp pattern in platform-core: `register()`/`deregister()` are no-ops, `match()` returns `Unmatched`, `generate()` throws `UnsupportedOperationException`, `schema()`/`schemas()` return empty.

- [ ] **Step 3: Add platform-core dependency and run test**

Add `casehub-platform-template-registry-api` dependency to `platform-core/pom.xml`.

Run: `mvn --batch-mode test -pl platform-core -Dtest=NoOpUnifiedTemplateRegistryTest`
Expected: pass

- [ ] **Step 4: Implement TemplateRegistryBeans**

CDI `@Produces @ApplicationScoped` for `NlpTemplateRegistry`. Injects `NlpTokenizer` (defaults to `OpenNlpTokenizer`).

- [ ] **Step 5: Implement TemplateSchemaEndpoint**

`@McpDomain("template-schemas")` class per spec §Schema Publication. `listSchemas`, `getSchema`, `matchTemplate` methods with `@PlatformQuery` and `@ContextParam("tenancyId")`.

- [ ] **Step 6: Write test for TemplateSchemaEndpoint**

Unit test verifying endpoint delegates to registry correctly.

- [ ] **Step 7: Run all tests and commit**

Run: `mvn --batch-mode test -pl platform-core,template-registry`
Expected: all pass

```bash
git add platform-core/ template-registry/
git commit -m "feat(#959): add NoOp @DefaultBean, CDI beans, and @McpDomain endpoint

Refs #959

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 6: Integration test suite (D5 acceptance criterion)

**Files:**
- Test: `template-registry/src/test/java/io/casehub/template/registry/nlp/TemplateRegistryIntegrationTest.java`

**Interfaces:**
- Consumes: `NlpTemplateRegistry`, `TemplateDefinition`, `TemplateNamespace`, `TemplateMatch`, `TemplateSchema`, `VariableConstraint`

- [ ] **Step 1: Write comprehensive integration tests**

```java
package io.casehub.template.registry.nlp;

import io.casehub.template.registry.*;
import io.casehub.yaml.core.resolver.VariableConstraint;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Nested;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import static org.assertj.core.api.Assertions.*;

class TemplateRegistryIntegrationTest {

    private NlpTemplateRegistry registry;

    @BeforeEach
    void setUp() {
        registry = new NlpTemplateRegistry(new OpenNlpTokenizer());
    }

    private void registerProtocol() {
        var vote = TemplateDefinition.builder("vote")
            .pattern("I ${decision} this ${subject}[ because ${rationale}]")
            .variable("decision", VariableConstraint.enumOf(
                "approve", "reject", "abstain"))
            .variable("subject", VariableConstraint.string())
            .variable("rationale", VariableConstraint.string().optional())
            .build();
        var escalate = TemplateDefinition.builder("escalate")
            .pattern("Escalating to ${target}[ due to ${reason}]")
            .variable("target", VariableConstraint.string())
            .variable("reason", VariableConstraint.string().optional())
            .build();
        var templates = new LinkedHashMap<String, TemplateDefinition>();
        templates.put("vote", vote);
        templates.put("escalate", escalate);
        registry.register(new TemplateNamespace("protocol:review", templates));
    }

    @Nested
    class ShortSentences {
        @BeforeEach void init() { registerProtocol(); }

        @Test void exactMatch() {
            var r = registry.match("protocol:review", "I approve this design");
            assertThat(r).isInstanceOf(TemplateMatch.Matched.class);
            var m = (TemplateMatch.Matched) r;
            assertThat(m.templateName()).isEqualTo("vote");
            assertThat(m.fields()).containsEntry("decision", "approve");
            assertThat(m.score()).isEqualTo(1.0);
        }

        @Test void shortEscalation() {
            var r = registry.match("protocol:review", "Escalating to Sarah");
            assertThat(r).isInstanceOf(TemplateMatch.Matched.class);
        }
    }

    @Nested
    class LongSentences {
        @BeforeEach void init() { registerProtocol(); }

        @Test void withOptionalClause() {
            var r = registry.match("protocol:review",
                "I approve this architecture because the failover design addresses all concerns");
            assertThat(r).isInstanceOf(TemplateMatch.Matched.class);
            var m = (TemplateMatch.Matched) r;
            assertThat(m.fields().get("rationale")).contains("failover");
        }

        @Test void escalationWithReason() {
            var r = registry.match("protocol:review",
                "Escalating to the security team due to unresolved compliance gaps in the authentication module");
            assertThat(r).isInstanceOf(TemplateMatch.Matched.class);
            var m = (TemplateMatch.Matched) r;
            assertThat(m.fields().get("reason")).contains("compliance");
        }
    }

    @Nested
    class GrammarVariation {
        @BeforeEach void init() { registerProtocol(); }

        @ParameterizedTest
        @ValueSource(strings = {
            "I approved this design",
            "I approves this design",
            "I approving this design"
        })
        void tenseVariations(String input) {
            var r = registry.match("protocol:review", input);
            assertThat(r).isInstanceOf(TemplateMatch.Matched.class);
            var m = (TemplateMatch.Matched) r;
            assertThat(m.fields().get("decision")).isEqualTo("approve");
        }

        @Test void pluralSubject() {
            var r = registry.match("protocol:review", "I approve these designs");
            assertThat(r).isInstanceOf(TemplateMatch.Matched.class);
        }
    }

    @Nested
    class VariableTypeCombinations {
        @BeforeEach void init() { registerProtocol(); }

        @Test void enumConstraintPasses() {
            var r = registry.match("protocol:review", "I approve this design");
            assertThat(r).isInstanceOf(TemplateMatch.Matched.class);
        }

        @Test void enumConstraintRejects() {
            var r = registry.match("protocol:review", "I celebrate this design");
            assertThat(r).isInstanceOf(TemplateMatch.Unmatched.class);
        }

        @Test void optionalVariablePresent() {
            var r = registry.match("protocol:review",
                "I approve this design because it is elegant");
            var m = (TemplateMatch.Matched) r;
            assertThat(m.fields()).containsKey("rationale");
        }

        @Test void optionalVariableAbsent() {
            var r = registry.match("protocol:review", "I approve this design");
            var m = (TemplateMatch.Matched) r;
            assertThat(m.fields()).doesNotContainKey("rationale");
        }
    }

    @Nested
    class ScoreDistribution {
        @BeforeEach void init() { registerProtocol(); }

        @Test void regexExactScoresOne() {
            var r = (TemplateMatch.Matched) registry.match(
                "protocol:review", "I approve this design");
            assertThat(r.score()).isEqualTo(1.0);
        }

        @Test void nlpScoresLessThanOne() {
            var r = registry.match("protocol:review", "I approved this design");
            if (r instanceof TemplateMatch.Matched m) {
                if (m.score() < 1.0) {
                    assertThat(m.score()).isBetween(0.5, 1.0);
                }
            }
        }

        @Test void unrelatedInputUnmatched() {
            var r = registry.match("protocol:review",
                "The weather is beautiful today");
            assertThat(r).isInstanceOf(TemplateMatch.Unmatched.class);
        }
    }

    @Nested
    class BidirectionalRoundtrip {
        @BeforeEach void init() { registerProtocol(); }

        @Test void extractThenGenerate() {
            String input = "I approve this design";
            var matched = (TemplateMatch.Matched) registry.match(
                "protocol:review", input);

            String generated = registry.generate(
                "protocol:review", matched.templateName(), matched.fields());
            assertThat(generated).isEqualTo(input);
        }

        @Test void extractWithOptionalThenGenerate() {
            String input = "I reject this proposal because it lacks detail";
            var matched = (TemplateMatch.Matched) registry.match(
                "protocol:review", input);

            String generated = registry.generate(
                "protocol:review", matched.templateName(), matched.fields());
            assertThat(generated).isEqualTo(input);
        }
    }

    @Nested
    class SchemaPublication {
        @BeforeEach void init() { registerProtocol(); }

        @Test void schemaAvailableAfterRegistration() {
            var schema = registry.schema("protocol:review", "vote");
            assertThat(schema).isPresent();
            assertThat(schema.get().patterns()).hasSize(1);
            assertThat(schema.get().variables()).containsKeys("decision", "subject");
        }

        @Test void structuralSummariesPopulated() {
            var schema = registry.schema("protocol:review", "vote");
            assertThat(schema).isPresent();
            assertThat(schema.get().structuralSummaries()).isNotEmpty();
            var summary = schema.get().structuralSummaries().get(0);
            assertThat(summary.elements()).isNotEmpty();
        }

        @Test void allSchemasForNamespace() {
            var schemas = registry.schemas("protocol:review");
            assertThat(schemas).hasSize(2);
        }
    }

    @Nested
    class MultiNamespace {

        @Test void crossNamespaceMatch() {
            registerProtocol();
            var acknowledge = TemplateDefinition.builder("ack")
                .pattern("Acknowledged by ${actor}")
                .variable("actor", VariableConstraint.string())
                .build();
            var templates = new LinkedHashMap<String, TemplateDefinition>();
            templates.put("ack", acknowledge);
            registry.register(new TemplateNamespace("protocol:workflow", templates));

            var r1 = registry.match("I approve this design");
            assertThat(r1).isInstanceOf(TemplateMatch.Matched.class);
            assertThat(((TemplateMatch.Matched) r1).namespace()).isEqualTo("protocol:review");

            var r2 = registry.match("Acknowledged by Sarah");
            assertThat(r2).isInstanceOf(TemplateMatch.Matched.class);
            assertThat(((TemplateMatch.Matched) r2).namespace()).isEqualTo("protocol:workflow");
        }
    }
}
```

- [ ] **Step 2: Run integration tests**

Run: `mvn --batch-mode test -pl template-registry -Dtest=TemplateRegistryIntegrationTest`
Expected: all tests pass (they test against already-implemented components)

- [ ] **Step 3: Commit**

```bash
git add template-registry/
git commit -m "feat(#959): add integration test suite — D5 acceptance criterion

Refs #959

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 4: Full build verification**

Run: `mvn --batch-mode install`
Expected: full platform build passes including new modules

- [ ] **Step 5: Final commit if any adjustments needed**

```bash
git add -A
git commit -m "fix(#959): build adjustments from full platform verification

Refs #959

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

## References

- `specs/issue-959-unified-template-registry/2026-11-24-unified-template-registry-design.md` — design spec
- `specs/issue-959-unified-template-registry/decisions.md` — D1–D10 validated decisions
- `yaml-core/src/main/java/io/casehub/yaml/core/resolver/TemplateExtractor.java` — regex compilation reference
- `yaml-core/src/main/java/io/casehub/yaml/core/resolver/VariableConstraint.java` — canonical constraint type
- `message-extraction-api/src/main/java/io/casehub/extraction/RegexMessageMatcher.java` — regex matching to port
- `message-extraction/src/main/java/io/casehub/extraction/nlp/StructuralPattern.java` — NLP matching to port
- `message-extraction/src/main/java/io/casehub/extraction/nlp/OpenNlpTokenizer.java` — tokenizer to migrate
- `coordination-core/src/main/java/io/casehub/platform/coordination/protocol/TemplateKeywords.java` — keyword filter to evolve
- `platform-core/src/main/java/io/casehub/platform/datasource/NoOpDataSourceRegistry.java` — NoOp pattern reference
- GitHub #959 — focal issue
- GitHub #943 — parent epic
- GitHub #961–#965 — follow-up issues filed by spec review
