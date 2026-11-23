# Message Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #922 — template-based message extraction
**Issue group:** #922

**Goal:** Build a standalone two-tier message extraction engine that turns structured prose into typed data, with regex matching (zero-dep) and NLP structural matching (OpenNLP) as fallback.

**Architecture:** Two modules — `message-extraction-api` (zero-dep: SPI types, regex matcher) and `message-extraction` (NLP structural matcher, OpenNLP tokenizer). Templates compile to regex patterns in -api; the -impl module adds POS-tag/lemma structural matching. Both tiers implement the same `MessageMatcher` interface.

**Tech Stack:** Java 21, Apache OpenNLP 2.5.12 (opennlp-tools), JUnit 5, AssertJ

## Global Constraints

- `message-extraction-api` must remain zero external dependencies — pure Java only
- `message-extraction` depends only on `message-extraction-api` + `opennlp-tools`
- All public types are immutable and thread-safe after construction
- Penn Treebank POS tagset for all POS tag references
- English only for this iteration
- No CDI, no Quarkus, no Spring — standalone library

---

## Batch 1: API Module — Core Types and Regex Matcher

### Task 1: Module scaffold and core types

**Files:**
- Create: `message-extraction-api/pom.xml`
- Create: `message-extraction-api/src/main/java/io/casehub/extraction/VariableConstraint.java`
- Create: `message-extraction-api/src/main/java/io/casehub/extraction/MessageMatch.java`
- Create: `message-extraction-api/src/main/java/io/casehub/extraction/MessageType.java`
- Create: `message-extraction-api/src/main/java/io/casehub/extraction/MessageSchema.java`
- Create: `message-extraction-api/src/main/java/io/casehub/extraction/MessageMatcher.java`
- Create: `message-extraction-api/src/main/java/io/casehub/extraction/NlpTokenizer.java`
- Create: `message-extraction-api/src/main/java/io/casehub/extraction/AnnotatedToken.java`
- Modify: `pom.xml` (root) — add `<module>message-extraction-api</module>`
- Test: `message-extraction-api/src/test/java/io/casehub/extraction/VariableConstraintTest.java`
- Test: `message-extraction-api/src/test/java/io/casehub/extraction/MessageSchemaTest.java`

**Interfaces:**
- Produces: `VariableConstraint` sealed interface (StringConstraint, EnumConstraint), `MessageMatch` sealed interface (Matched, Unmatched), `MessageType` record, `MessageSchema` record + Builder, `MessageMatcher` interface, `NlpTokenizer` SPI, `AnnotatedToken` record

- [ ] **Step 1: Create module POM**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>

    <parent>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-platform-parent</artifactId>
        <version>0.4-SNAPSHOT</version>
    </parent>

    <artifactId>casehub-platform-message-extraction-api</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform Message Extraction API</name>
    <description>Zero-dependency SPI and types for structured prose extraction.
        Includes regex-based MessageMatcher for exact template matching.</description>

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

Add `<module>message-extraction-api</module>` to root `pom.xml` modules list.

- [ ] **Step 2: Write failing tests for VariableConstraint**

```java
package io.casehub.extraction;

import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class VariableConstraintTest {

    @Test
    void stringConstraintIsRequiredByDefault() {
        var c = VariableConstraint.string();
        assertThat(c).isInstanceOf(VariableConstraint.StringConstraint.class);
        assertThat(((VariableConstraint.StringConstraint) c).required()).isTrue();
    }

    @Test
    void stringConstraintOptional() {
        var c = VariableConstraint.string().optional();
        assertThat(((VariableConstraint.StringConstraint) c).required()).isFalse();
    }

    @Test
    void enumConstraintWithValues() {
        var c = VariableConstraint.enumOf("approve", "reject", "abstain");
        assertThat(c).isInstanceOf(VariableConstraint.EnumConstraint.class);
        var ec = (VariableConstraint.EnumConstraint) c;
        assertThat(ec.values()).containsExactlyInAnyOrder("approve", "reject", "abstain");
        assertThat(ec.required()).isTrue();
    }

    @Test
    void enumConstraintOptional() {
        var c = VariableConstraint.enumOf("yes", "no").optional();
        assertThat(((VariableConstraint.EnumConstraint) c).required()).isFalse();
    }

    @Test
    void enumConstraintRejectsEmpty() {
        assertThatThrownBy(() -> VariableConstraint.enumOf())
            .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void enumConstraintValuesAreImmutable() {
        var c = (VariableConstraint.EnumConstraint) VariableConstraint.enumOf("a", "b");
        assertThatThrownBy(() -> c.values().add("c"))
            .isInstanceOf(UnsupportedOperationException.class);
    }
}
```

- [ ] **Step 3: Run tests — verify they fail (class not found)**

Run: `/opt/homebrew/bin/mvn -pl message-extraction-api test --batch-mode -q`
Expected: Compilation failure — `VariableConstraint` does not exist

- [ ] **Step 4: Implement VariableConstraint**

```java
package io.casehub.extraction;

import java.util.Objects;
import java.util.Set;

public sealed interface VariableConstraint {

    boolean required();
    VariableConstraint optional();

    record StringConstraint(boolean required) implements VariableConstraint {
        @Override
        public VariableConstraint optional() { return new StringConstraint(false); }
    }

    record EnumConstraint(Set<String> values, boolean required) implements VariableConstraint {
        public EnumConstraint {
            Objects.requireNonNull(values, "values");
            if (values.isEmpty()) throw new IllegalArgumentException("Enum constraint must have at least one value");
            values = Set.copyOf(values);
        }
        @Override
        public VariableConstraint optional() { return new EnumConstraint(values, false); }
    }

    static VariableConstraint string() { return new StringConstraint(true); }

    static VariableConstraint enumOf(String... values) {
        Objects.requireNonNull(values, "values");
        return new EnumConstraint(Set.of(values), true);
    }
}
```

- [ ] **Step 5: Run tests — verify VariableConstraint tests pass**

Run: `/opt/homebrew/bin/mvn -pl message-extraction-api test --batch-mode -q`
Expected: All pass

- [ ] **Step 6: Implement remaining core types**

`AnnotatedToken.java`:
```java
package io.casehub.extraction;

import java.util.Objects;

public record AnnotatedToken(String surface, String lemma, String pos, int start, int end) {
    public AnnotatedToken {
        Objects.requireNonNull(surface, "surface");
        Objects.requireNonNull(lemma, "lemma");
        Objects.requireNonNull(pos, "pos");
    }
}
```

`NlpTokenizer.java`:
```java
package io.casehub.extraction;

import java.util.List;

public interface NlpTokenizer {
    List<AnnotatedToken> tokenize(String text);
}
```

`MessageMatch.java`:
```java
package io.casehub.extraction;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Objects;

public sealed interface MessageMatch {

    record Matched(String type, int templateIndex, Map<String, String> fields, double score) implements MessageMatch {
        public Matched {
            Objects.requireNonNull(type, "type");
            Objects.requireNonNull(fields, "fields");
            if (score <= 0.0 || score > 1.0) throw new IllegalArgumentException("Score must be in (0, 1.0]: " + score);
            fields = Collections.unmodifiableMap(new LinkedHashMap<>(fields));
        }
    }

    record Unmatched(String input) implements MessageMatch {
        public Unmatched {
            Objects.requireNonNull(input, "input");
        }
    }
}
```

`MessageMatcher.java`:
```java
package io.casehub.extraction;

public interface MessageMatcher {
    MessageMatch match(String input);
}
```

`MessageType.java`:
```java
package io.casehub.extraction;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;

public record MessageType(String name, List<String> templates, Map<String, VariableConstraint> variables) {
    public MessageType {
        Objects.requireNonNull(name, "name");
        Objects.requireNonNull(templates, "templates");
        if (templates.isEmpty()) throw new IllegalArgumentException("Message type must have at least one template");
        templates = List.copyOf(templates);
        variables = variables != null ? Collections.unmodifiableMap(new LinkedHashMap<>(variables)) : Map.of();
    }
}
```

`MessageSchema.java` with builder:
```java
package io.casehub.extraction;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;

public record MessageSchema(List<MessageType> types) {
    public MessageSchema {
        Objects.requireNonNull(types, "types");
        if (types.isEmpty()) throw new IllegalArgumentException("Schema must have at least one message type");
        types = List.copyOf(types);
    }

    public static Builder builder() { return new Builder(); }

    public static final class Builder {
        private final List<MessageType> types = new ArrayList<>();

        public TypeBuilder message(String name) { return new TypeBuilder(this, name); }

        public MessageSchema build() { return new MessageSchema(List.copyOf(types)); }

        private void addType(MessageType type) { types.add(type); }
    }

    public static final class TypeBuilder {
        private final Builder parent;
        private final String name;
        private final List<String> templates = new ArrayList<>();
        private final Map<String, VariableConstraint> variables = new LinkedHashMap<>();

        TypeBuilder(Builder parent, String name) {
            this.parent = Objects.requireNonNull(parent);
            this.name = Objects.requireNonNull(name);
        }

        public TypeBuilder template(String template) {
            templates.add(Objects.requireNonNull(template, "template"));
            return this;
        }

        public TypeBuilder variable(String name, VariableConstraint constraint) {
            variables.put(Objects.requireNonNull(name), Objects.requireNonNull(constraint));
            return this;
        }

        public Builder done() {
            parent.addType(new MessageType(name, templates, variables));
            return parent;
        }
    }
}
```

- [ ] **Step 7: Write MessageSchema builder test**

```java
package io.casehub.extraction;

import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class MessageSchemaTest {

    @Test
    void builderCreatesSchemaWithOneType() {
        var schema = MessageSchema.builder()
            .message("vote")
                .template("I ${decision} this ${subject}")
                .variable("decision", VariableConstraint.enumOf("approve", "reject"))
                .variable("subject", VariableConstraint.string())
                .done()
            .build();
        assertThat(schema.types()).hasSize(1);
        assertThat(schema.types().get(0).name()).isEqualTo("vote");
        assertThat(schema.types().get(0).templates()).containsExactly("I ${decision} this ${subject}");
        assertThat(schema.types().get(0).variables()).containsKeys("decision", "subject");
    }

    @Test
    void builderCreatesSchemaWithMultipleTypes() {
        var schema = MessageSchema.builder()
            .message("vote")
                .template("I ${decision}")
                .done()
            .message("escalate")
                .template("Escalating to ${target}")
                .done()
            .build();
        assertThat(schema.types()).hasSize(2);
    }

    @Test
    void emptySchemaRejected() {
        assertThatThrownBy(() -> MessageSchema.builder().build())
            .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void typeWithNoTemplateRejected() {
        assertThatThrownBy(() -> MessageSchema.builder()
            .message("vote").done().build())
            .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void typesAreImmutable() {
        var schema = MessageSchema.builder()
            .message("vote").template("${x}").done()
            .build();
        assertThatThrownBy(() -> schema.types().add(null))
            .isInstanceOf(UnsupportedOperationException.class);
    }
}
```

- [ ] **Step 8: Run all tests — verify green**

Run: `/opt/homebrew/bin/mvn -pl message-extraction-api test --batch-mode -q`
Expected: All pass

- [ ] **Step 9: Commit**

```bash
git add message-extraction-api/ pom.xml
git commit -m "feat(#922): add message-extraction-api module with core types

MessageSchema, MessageType, VariableConstraint, MessageMatch,
MessageMatcher, NlpTokenizer, AnnotatedToken — zero-dep foundation
for structured prose extraction."
```

### Task 2: RegexMessageMatcher

**Files:**
- Create: `message-extraction-api/src/main/java/io/casehub/extraction/RegexMessageMatcher.java`
- Test: `message-extraction-api/src/test/java/io/casehub/extraction/RegexMessageMatcherTest.java`

**Interfaces:**
- Consumes: `MessageSchema`, `MessageType`, `VariableConstraint`, `MessageMatch`, `MessageMatcher`
- Produces: `RegexMessageMatcher` implements `MessageMatcher` — compiles templates to regex, extracts variables, validates constraints post-match

- [ ] **Step 1: Write failing tests for regex matching**

```java
package io.casehub.extraction;

import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class RegexMessageMatcherTest {

    @Test
    void matchesExactTemplateAndExtractsVariables() {
        var schema = MessageSchema.builder()
            .message("vote")
                .template("I ${decision} this ${subject}")
                .variable("decision", VariableConstraint.enumOf("approve", "reject"))
                .variable("subject", VariableConstraint.string())
                .done()
            .build();
        var matcher = new RegexMessageMatcher(schema);
        var result = matcher.match("I approve this design");
        assertThat(result).isInstanceOf(MessageMatch.Matched.class);
        var matched = (MessageMatch.Matched) result;
        assertThat(matched.type()).isEqualTo("vote");
        assertThat(matched.templateIndex()).isEqualTo(0);
        assertThat(matched.fields()).containsEntry("decision", "approve");
        assertThat(matched.fields()).containsEntry("subject", "design");
        assertThat(matched.score()).isEqualTo(1.0);
    }

    @Test
    void rejectsInputThatDoesNotMatchAnyTemplate() {
        var schema = MessageSchema.builder()
            .message("vote")
                .template("I ${decision} this ${subject}")
                .done()
            .build();
        var matcher = new RegexMessageMatcher(schema);
        var result = matcher.match("completely unrelated text");
        assertThat(result).isInstanceOf(MessageMatch.Unmatched.class);
    }

    @Test
    void enumConstraintRejectsInvalidValue() {
        var schema = MessageSchema.builder()
            .message("vote")
                .template("I ${decision} this ${subject}")
                .variable("decision", VariableConstraint.enumOf("approve", "reject"))
                .done()
            .build();
        var matcher = new RegexMessageMatcher(schema);
        var result = matcher.match("I celebrate this design");
        assertThat(result).isInstanceOf(MessageMatch.Unmatched.class);
    }

    @Test
    void matchesFirstMatchingTemplateInMultiTemplateType() {
        var schema = MessageSchema.builder()
            .message("vote")
                .template("I ${decision} this ${subject}")
                .template("${decision}")
                .variable("decision", VariableConstraint.enumOf("approve", "reject"))
                .done()
            .build();
        var matcher = new RegexMessageMatcher(schema);
        var result = matcher.match("I approve this design");
        assertThat(result).isInstanceOf(MessageMatch.Matched.class);
        assertThat(((MessageMatch.Matched) result).templateIndex()).isEqualTo(0);
    }

    @Test
    void fallsThroughToSecondTemplateWhenFirstDoesNotMatch() {
        var schema = MessageSchema.builder()
            .message("vote")
                .template("I ${decision} this ${subject}")
                .template("${decision}")
                .variable("decision", VariableConstraint.enumOf("approve", "reject"))
                .done()
            .build();
        var matcher = new RegexMessageMatcher(schema);
        var result = matcher.match("approve");
        assertThat(result).isInstanceOf(MessageMatch.Matched.class);
        assertThat(((MessageMatch.Matched) result).templateIndex()).isEqualTo(1);
    }

    @Test
    void matchesFirstTypeWhenMultipleTypesExist() {
        var schema = MessageSchema.builder()
            .message("vote")
                .template("I ${decision}")
                .variable("decision", VariableConstraint.enumOf("approve"))
                .done()
            .message("escalate")
                .template("Escalating to ${target}")
                .done()
            .build();
        var matcher = new RegexMessageMatcher(schema);
        assertThat(matcher.match("I approve")).isInstanceOf(MessageMatch.Matched.class);
        assertThat(((MessageMatch.Matched) matcher.match("I approve")).type()).isEqualTo("vote");
        assertThat(matcher.match("Escalating to manager")).isInstanceOf(MessageMatch.Matched.class);
        assertThat(((MessageMatch.Matched) matcher.match("Escalating to manager")).type()).isEqualTo("escalate");
    }

    @Test
    void optionalSegmentsWork() {
        var schema = MessageSchema.builder()
            .message("vote")
                .template("I ${decision}[ because ${rationale}]")
                .variable("decision", VariableConstraint.enumOf("approve", "reject"))
                .variable("rationale", VariableConstraint.string().optional())
                .done()
            .build();
        var matcher = new RegexMessageMatcher(schema);

        var withRationale = (MessageMatch.Matched) matcher.match("I approve because it looks good");
        assertThat(withRationale.fields()).containsEntry("decision", "approve");
        assertThat(withRationale.fields()).containsEntry("rationale", "it looks good");

        var withoutRationale = (MessageMatch.Matched) matcher.match("I approve");
        assertThat(withoutRationale.fields()).containsEntry("decision", "approve");
        assertThat(withoutRationale.fields()).doesNotContainKey("rationale");
    }

    @Test
    void enumConstraintMatchesCaseInsensitive() {
        var schema = MessageSchema.builder()
            .message("vote")
                .template("${decision}")
                .variable("decision", VariableConstraint.enumOf("approve", "reject"))
                .done()
            .build();
        var matcher = new RegexMessageMatcher(schema);
        var result = matcher.match("Approve");
        assertThat(result).isInstanceOf(MessageMatch.Matched.class);
        assertThat(((MessageMatch.Matched) result).fields().get("decision")).isEqualTo("Approve");
    }
}
```

- [ ] **Step 2: Run tests — verify compilation fails**

Run: `/opt/homebrew/bin/mvn -pl message-extraction-api test --batch-mode -q`
Expected: Compilation failure — `RegexMessageMatcher` does not exist

- [ ] **Step 3: Implement RegexMessageMatcher**

The implementation compiles each template string into a `java.util.regex.Pattern` using the same approach as `TemplateExtractor` (VAR_PATTERN for `${name}`, optional segments via `[...]`). After a regex match, it validates extracted values against `VariableConstraint`. If validation fails, the template is skipped and the next template is tried.

```java
package io.casehub.extraction;

import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public final class RegexMessageMatcher implements MessageMatcher {

    private final List<CompiledType> compiledTypes;

    public RegexMessageMatcher(MessageSchema schema) {
        Objects.requireNonNull(schema, "schema");
        List<CompiledType> types = new ArrayList<>();
        for (MessageType type : schema.types()) {
            List<CompiledTemplate> templates = new ArrayList<>();
            for (int i = 0; i < type.templates().size(); i++) {
                templates.add(compileTemplate(type.templates().get(i)));
            }
            types.add(new CompiledType(type.name(), templates, type.variables()));
        }
        this.compiledTypes = Collections.unmodifiableList(types);
    }

    @Override
    public MessageMatch match(String input) {
        Objects.requireNonNull(input, "input");
        for (CompiledType type : compiledTypes) {
            for (int i = 0; i < type.templates.size(); i++) {
                Optional<Map<String, String>> extracted = type.templates.get(i).extract(input);
                if (extracted.isPresent() && validateConstraints(extracted.get(), type.variables)) {
                    return new MessageMatch.Matched(type.name, i, extracted.get(), 1.0);
                }
            }
        }
        return new MessageMatch.Unmatched(input);
    }

    // Template compilation and extraction logic follows the same
    // approach as TemplateExtractor: VAR_PATTERN, optional segments,
    // named capture groups. Implementation details elided for plan
    // brevity — reuse the same regex compilation algorithm from
    // TemplateExtractor (parseSegments, appendSegmentRegex, sanitizeGroupName).
    // The key difference: this class validates constraints post-match.

    private boolean validateConstraints(Map<String, String> fields, Map<String, VariableConstraint> constraints) {
        for (var entry : constraints.entrySet()) {
            String value = fields.get(entry.getKey());
            VariableConstraint constraint = entry.getValue();
            if (value == null) {
                if (constraint.required()) return false;
                continue;
            }
            if (constraint instanceof VariableConstraint.EnumConstraint ec) {
                if (ec.values().stream().noneMatch(v -> v.equalsIgnoreCase(value))) return false;
            }
        }
        return true;
    }

    private static CompiledTemplate compileTemplate(String template) {
        // Reuse TemplateExtractor's regex compilation algorithm
        // (parseSegments → appendSegmentRegex → Pattern.compile)
        // Returns CompiledTemplate with compiled Pattern + variable names
        // ... (full implementation in the actual code)
    }

    private record CompiledType(String name, List<CompiledTemplate> templates,
                                Map<String, VariableConstraint> variables) {}
    private record CompiledTemplate(Pattern pattern, List<String> variableNames) {
        Optional<Map<String, String>> extract(String input) {
            Matcher m = pattern.matcher(input);
            if (!m.matches()) return Optional.empty();
            Map<String, String> result = new LinkedHashMap<>();
            for (String name : variableNames) {
                String value = m.group(sanitizeGroupName(name));
                if (value != null) result.put(name, value);
            }
            return Optional.of(result);
        }
    }

    private static String sanitizeGroupName(String name) {
        if (name.indexOf('.') < 0 && name.indexOf('-') < 0) return name;
        return name.replace(".", "0DOT0").replace("-", "0HYPHEN0");
    }
}
```

Note: The full regex compilation logic (parseSegments, appendSegmentRegex, VAR_PATTERN, optional segment parsing) must be copied from `TemplateExtractor` — it is the same algorithm. Do NOT depend on yaml-core; copy the algorithm. This is intentional — the message-extraction-api module is standalone and zero-dep.

- [ ] **Step 4: Run tests — verify all green**

Run: `/opt/homebrew/bin/mvn -pl message-extraction-api test --batch-mode -q`
Expected: All pass

- [ ] **Step 5: Commit**

```bash
git add message-extraction-api/
git commit -m "feat(#922): add RegexMessageMatcher with post-match constraint validation

Compiles templates to regex patterns, extracts variables, validates
enum constraints post-match. First-match-wins across types and templates."
```

## Batch 2: Impl Module — NLP Structural Matcher

### Task 3: OpenNLP tokenizer and TwoTierMessageMatcher

**Files:**
- Create: `message-extraction/pom.xml`
- Create: `message-extraction/src/main/java/io/casehub/extraction/nlp/OpenNlpTokenizer.java`
- Create: `message-extraction/src/main/java/io/casehub/extraction/nlp/StructuralPattern.java`
- Create: `message-extraction/src/main/java/io/casehub/extraction/nlp/NlpMessageMatcher.java`
- Create: `message-extraction/src/main/java/io/casehub/extraction/nlp/TwoTierMessageMatcher.java`
- Modify: `pom.xml` (root) — add `<module>message-extraction</module>`
- Test: `message-extraction/src/test/java/io/casehub/extraction/nlp/OpenNlpTokenizerTest.java`
- Test: `message-extraction/src/test/java/io/casehub/extraction/nlp/TwoTierMessageMatcherTest.java`

**Interfaces:**
- Consumes: `NlpTokenizer` SPI, `AnnotatedToken`, `MessageSchema`, `MessageMatcher`, `MessageMatch`, `RegexMessageMatcher`
- Produces: `OpenNlpTokenizer` (NlpTokenizer impl), `TwoTierMessageMatcher` (regex first → NLP fallback), `StructuralPattern` (compiled NLP pattern)

- [ ] **Step 1: Create module POM with OpenNLP dependency**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>

    <parent>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-platform-parent</artifactId>
        <version>0.4-SNAPSHOT</version>
    </parent>

    <artifactId>casehub-platform-message-extraction</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform Message Extraction</name>
    <description>NLP structural matching for message extraction.
        Two-tier: regex first (from -api), NLP fallback via OpenNLP.</description>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-message-extraction-api</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>org.apache.opennlp</groupId>
            <artifactId>opennlp-tools</artifactId>
            <version>2.5.12</version>
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

Add `<module>message-extraction</module>` to root `pom.xml`.

- [ ] **Step 2: Write failing test for OpenNlpTokenizer**

```java
package io.casehub.extraction.nlp;

import io.casehub.extraction.AnnotatedToken;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class OpenNlpTokenizerTest {

    private final OpenNlpTokenizer tokenizer = new OpenNlpTokenizer();

    @Test
    void tokenizesSimpleSentence() {
        var tokens = tokenizer.tokenize("I approve this design");
        assertThat(tokens).hasSizeGreaterThanOrEqualTo(4);
        assertThat(tokens.get(0).surface()).isEqualTo("I");
        assertThat(tokens.get(0).pos()).isNotEmpty();
        assertThat(tokens.get(0).lemma()).isNotEmpty();
    }

    @Test
    void lemmatizesVerbs() {
        var tokens = tokenizer.tokenize("I approved this design");
        var approved = tokens.stream()
            .filter(t -> t.surface().equals("approved"))
            .findFirst().orElseThrow();
        assertThat(approved.lemma()).isEqualTo("approve");
    }

    @Test
    void rejectsNull() {
        assertThatThrownBy(() -> tokenizer.tokenize(null))
            .isInstanceOf(NullPointerException.class);
    }
}
```

- [ ] **Step 3: Implement OpenNlpTokenizer**

Load OpenNLP models (tokenizer, POS tagger, lemmatizer) lazily on first call. Use thread-safe model loading with `volatile` + double-checked locking. Models loaded from classpath resources.

```java
package io.casehub.extraction.nlp;

import io.casehub.extraction.AnnotatedToken;
import io.casehub.extraction.NlpTokenizer;
import opennlp.tools.lemmatizer.DictionaryLemmatizer;
import opennlp.tools.postag.POSModel;
import opennlp.tools.postag.POSTaggerME;
import opennlp.tools.tokenize.TokenizerME;
import opennlp.tools.tokenize.TokenizerModel;

import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;

public final class OpenNlpTokenizer implements NlpTokenizer {
    // Lazy-loaded models, thread-safe
    // tokenize() → tokenize text → POS tag → lemmatize → produce AnnotatedToken list
    // Model paths: classpath resources bundled in this module
}
```

Note: OpenNLP model files (`en-token.bin`, `en-pos-maxent.bin`, `en-lemmatizer.dict`) must be downloaded and placed in `message-extraction/src/main/resources/opennlp/models/`. Use the models from the OpenNLP downloads page. If models are too large for the repo, document the download steps and use a Maven plugin or test-scoped profile.

- [ ] **Step 4: Run tokenizer tests — verify green**

Run: `/opt/homebrew/bin/mvn -pl message-extraction test -Dtest=OpenNlpTokenizerTest --batch-mode -q`
Expected: All pass

- [ ] **Step 5: Write failing test for TwoTierMessageMatcher**

```java
package io.casehub.extraction.nlp;

import io.casehub.extraction.*;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class TwoTierMessageMatcherTest {

    private final OpenNlpTokenizer tokenizer = new OpenNlpTokenizer();

    @Test
    void exactMatchUsesRegexTierWithScoreOne() {
        var schema = MessageSchema.builder()
            .message("vote")
                .template("I ${decision} this ${subject}")
                .variable("decision", VariableConstraint.enumOf("approve", "reject"))
                .done()
            .build();
        var matcher = new TwoTierMessageMatcher(schema, tokenizer);
        var result = (MessageMatch.Matched) matcher.match("I approve this design");
        assertThat(result.score()).isEqualTo(1.0);
        assertThat(result.fields().get("decision")).isEqualTo("approve");
    }

    @Test
    void grammaticalVariationFallsToNlpTier() {
        var schema = MessageSchema.builder()
            .message("vote")
                .template("I ${decision} this ${subject}")
                .variable("decision", VariableConstraint.enumOf("approve", "reject"))
                .done()
            .build();
        var matcher = new TwoTierMessageMatcher(schema, tokenizer);
        var result = matcher.match("I approved this design");
        assertThat(result).isInstanceOf(MessageMatch.Matched.class);
        var matched = (MessageMatch.Matched) result;
        assertThat(matched.fields().get("decision")).isEqualToIgnoringCase("approve");
        assertThat(matched.score()).isLessThan(1.0);
        assertThat(matched.score()).isGreaterThan(0.5);
    }

    @Test
    void noMatchReturnsUnmatched() {
        var schema = MessageSchema.builder()
            .message("vote")
                .template("I ${decision} this ${subject}")
                .variable("decision", VariableConstraint.enumOf("approve", "reject"))
                .done()
            .build();
        var matcher = new TwoTierMessageMatcher(schema, tokenizer);
        var result = matcher.match("The weather is nice today");
        assertThat(result).isInstanceOf(MessageMatch.Unmatched.class);
    }

    @Test
    void thresholdRejectsLowScoreMatches() {
        var schema = MessageSchema.builder()
            .message("vote")
                .template("I ${decision} this ${subject} because ${rationale}")
                .variable("decision", VariableConstraint.enumOf("approve"))
                .done()
            .build();
        var matcher = new TwoTierMessageMatcher(schema, tokenizer, 0.9);
        var result = matcher.match("approve");
        assertThat(result).isInstanceOf(MessageMatch.Unmatched.class);
    }
}
```

- [ ] **Step 6: Implement TwoTierMessageMatcher and NLP matching**

`TwoTierMessageMatcher` delegates to `RegexMessageMatcher` first. On `Unmatched`, runs NLP structural matching via the `NlpTokenizer`. Structural patterns are compiled from templates at construction time by running the tokenizer on template literal segments.

The NLP matcher:
1. Tokenizes the input via `NlpTokenizer`
2. For each message type/template, matches the token stream against the structural pattern
3. Enum variables: match by lemma against allowed values
4. String variables: capture single token surface form
5. Clause variables: capture all tokens to next anchor, joined with spaces
6. Score = matched elements / total elements

- [ ] **Step 7: Run all tests — verify green**

Run: `/opt/homebrew/bin/mvn -pl message-extraction test --batch-mode -q`
Expected: All pass

- [ ] **Step 8: Commit**

```bash
git add message-extraction/ pom.xml
git commit -m "feat(#922): add message-extraction module with NLP structural matching

TwoTierMessageMatcher: regex first (score=1.0), NLP fallback
(scored coverage). OpenNlpTokenizer for tokenization, POS tagging,
and lemmatization. English models bundled as classpath resources."
```

## Batch 3: Full build verification

### Task 4: Full build and cross-module test

**Files:**
- No new files — verify existing modules compile and test together

**Interfaces:**
- Consumes: All types from Tasks 1-3

- [ ] **Step 1: Run full build from root**

Run: `/opt/homebrew/bin/mvn --batch-mode install -pl message-extraction-api,message-extraction`
Expected: BUILD SUCCESS — both modules compile, all tests pass

- [ ] **Step 2: Verify no unintended dependencies in -api module**

Run: `/opt/homebrew/bin/mvn -pl message-extraction-api dependency:tree --batch-mode`
Expected: Only junit and assertj (test scope). No runtime dependencies.

- [ ] **Step 3: Commit any fixes**

If any fixes were needed, commit them.

---

## References

- [2026-11-23-message-extraction-design.md] — design spec this plan implements
- [yaml-core/src/main/java/io/casehub/yaml/core/resolver/TemplateExtractor.java] — regex compilation algorithm to replicate
- [yaml-core/src/main/java/io/casehub/yaml/core/resolver/TemplateRegistry.java] — ordered template matching pattern
- [coordination-core/src/main/java/io/casehub/platform/coordination/protocol/ProtocolMatchResult.java] — sealed match result pattern
- [coordination-core/src/main/java/io/casehub/platform/coordination/protocol/ProtocolEvaluator.java] — future consumer
- [GitHub #922] — focal issue
