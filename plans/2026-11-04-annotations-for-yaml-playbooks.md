# `#@` Annotations for YAML Playbooks — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #700 — feat: @ annotations for YAML playbooks
**Issue group:** #699, #700

**Goal:** Add `#@` annotation support to CaseHub YAML playbooks — extraction, data model, Walker integration, @Inject dependency resolution, and decorator migration with dual-path backward compatibility.

**Architecture:** A pre-parser (`AnnotationExtractor`) in yaml-core scans raw YAML text for `#@` comment lines, parses annotation names and arguments, and produces an `AnnotationMap` keyed by step index. Since `#@` lines are valid YAML comments, SnakeYAML ignores them natively — no text transformation. The Walker receives the `AnnotationMap` and attaches annotations to `ResolvedStep` records. `@Inject` annotations bind named variables via an `InjectionResolver` SPI before step execution. Decorator migration adds a dual-path where 12 decorator keys also work as annotations, with annotation-over-key precedence.

**Tech Stack:** Java 21, yaml-core (zero-dep, J2CL-safe), yaml-step-runtime (SnakeYAML, CDI), JUnit 5

## Global Constraints

- yaml-core must remain zero-dependency and J2CL-safe — no SnakeYAML, no CDI, no casehubio imports
- `#@` is the annotation prefix — always valid YAML (comments)
- V1 supports document-level + top-level step annotations only (nested deferred to #716)
- `AnnotationMap` uses `Map<String, List<Annotation>>` with string keys for forward-compatible hierarchical addressing
- Duplicate annotations of the same type on the same target → error (D10)
- Annotation-over-key precedence during dual-path window (D3)
- All primitives in yaml-core use j.u.c or lock-free — never `synchronized`

---

## Batch 1: Annotation Data Model + Parser (yaml-core)

### Task 1: Annotation records and AnnotationMap

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/annotation/Annotation.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/annotation/AnnotationArg.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/annotation/AnnotationMap.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/annotation/AnnotationMapTest.java`

**Interfaces:**
- Consumes: nothing (foundation)
- Produces:
  - `Annotation(String name, List<AnnotationArg> args)` — `hasArg(String name)`, `stringArg(int index)`, `namedArg(String name)`
  - `sealed interface AnnotationArg` — `Positional(String value)`, `Named(String name, String value)`
  - `AnnotationMap(List<Annotation> documentAnnotations, Map<String, List<Annotation>> stepAnnotations)` — `forStep(int index)`, `hasStepAnnotation(int index, String name)`, `forDocument(String name)`, `empty()` static factory

- [ ] **Step 1: Write failing tests for Annotation record**

```java
package io.casehub.yaml.core.annotation;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class AnnotationMapTest {

    @Test
    void annotationWithPositionalArgs() {
        var ann = new Annotation("timeout", List.of(new AnnotationArg.Positional("5s")));
        assertEquals("timeout", ann.name());
        assertEquals("5s", ann.stringArg(0));
        assertFalse(ann.hasArg("backoff"));
    }

    @Test
    void annotationWithNamedArgs() {
        var ann = new Annotation("retry", List.of(
            new AnnotationArg.Positional("3"),
            new AnnotationArg.Named("backoff", "exponential")));
        assertEquals("3", ann.stringArg(0));
        assertEquals("exponential", ann.namedArg("backoff"));
        assertTrue(ann.hasArg("backoff"));
    }

    @Test
    void annotationWithNoArgs() {
        var ann = new Annotation("background", List.of());
        assertEquals("background", ann.name());
        assertEquals(0, ann.args().size());
    }

    @Test
    void annotationMapForStep() {
        var timeout = new Annotation("timeout", List.of(new AnnotationArg.Positional("5s")));
        var map = new AnnotationMap(
            List.of(),
            Map.of("0", List.of(timeout)));
        assertEquals(1, map.forStep(0).size());
        assertEquals("timeout", map.forStep(0).get(0).name());
        assertTrue(map.hasStepAnnotation(0, "timeout"));
        assertFalse(map.hasStepAnnotation(1, "timeout"));
    }

    @Test
    void annotationMapDocumentLevel() {
        var desc = new Annotation("description", List.of(new AnnotationArg.Positional("My playbook")));
        var map = new AnnotationMap(List.of(desc), Map.of());
        assertEquals(1, map.documentAnnotations().size());
        assertTrue(map.forDocument("description").isPresent());
        assertFalse(map.forDocument("requires").isPresent());
    }

    @Test
    void emptyAnnotationMap() {
        var map = AnnotationMap.empty();
        assertTrue(map.documentAnnotations().isEmpty());
        assertTrue(map.forStep(0).isEmpty());
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl yaml-core test -Dtest=AnnotationMapTest -DfailIfNoTests=false --batch-mode`
Expected: FAIL — classes don't exist yet

- [ ] **Step 3: Implement Annotation, AnnotationArg, AnnotationMap**

`AnnotationArg.java`:
```java
package io.casehub.yaml.core.annotation;

public sealed interface AnnotationArg {
    record Positional(String value) implements AnnotationArg {}
    record Named(String name, String value) implements AnnotationArg {}
}
```

`Annotation.java`:
```java
package io.casehub.yaml.core.annotation;

import java.util.List;
import java.util.Objects;

public record Annotation(String name, List<AnnotationArg> args) {

    public Annotation {
        Objects.requireNonNull(name, "name");
        args = args != null ? List.copyOf(args) : List.of();
    }

    public boolean hasArg(String argName) {
        return args.stream().anyMatch(a -> a instanceof AnnotationArg.Named n && n.name().equals(argName));
    }

    public String stringArg(int index) {
        if (index < 0 || index >= args.size()) return null;
        return switch (args.get(index)) {
            case AnnotationArg.Positional p -> p.value();
            case AnnotationArg.Named n -> n.value();
        };
    }

    public String namedArg(String argName) {
        return args.stream()
            .filter(a -> a instanceof AnnotationArg.Named n && n.name().equals(argName))
            .map(a -> ((AnnotationArg.Named) a).value())
            .findFirst().orElse(null);
    }
}
```

`AnnotationMap.java`:
```java
package io.casehub.yaml.core.annotation;

import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;

public record AnnotationMap(
        List<Annotation> documentAnnotations,
        Map<String, List<Annotation>> stepAnnotations) {

    private static final AnnotationMap EMPTY = new AnnotationMap(List.of(), Map.of());

    public AnnotationMap {
        Objects.requireNonNull(documentAnnotations, "documentAnnotations");
        Objects.requireNonNull(stepAnnotations, "stepAnnotations");
        documentAnnotations = List.copyOf(documentAnnotations);
        stepAnnotations = Map.copyOf(stepAnnotations);
    }

    public static AnnotationMap empty() { return EMPTY; }

    public List<Annotation> forStep(int index) {
        return stepAnnotations.getOrDefault(String.valueOf(index), List.of());
    }

    public boolean hasStepAnnotation(int index, String name) {
        return forStep(index).stream().anyMatch(a -> a.name().equals(name));
    }

    public Optional<Annotation> forDocument(String name) {
        return documentAnnotations.stream().filter(a -> a.name().equals(name)).findFirst();
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn -pl yaml-core test -Dtest=AnnotationMapTest --batch-mode`
Expected: PASS — all 5 tests green

- [ ] **Step 5: Commit**

```bash
git add yaml-core/src/main/java/io/casehub/yaml/core/annotation/
git add yaml-core/src/test/java/io/casehub/yaml/core/annotation/
git commit -m "feat(#700): Annotation data model — Annotation, AnnotationArg, AnnotationMap records"
```

### Task 2: AnnotationParser — argument grammar

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/annotation/AnnotationParser.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/annotation/AnnotationParserTest.java`

**Interfaces:**
- Consumes: `Annotation`, `AnnotationArg` (from Task 1)
- Produces: `AnnotationParser.parse(String line) → Annotation` — parses a `#@name(args)` line into an Annotation record

- [ ] **Step 1: Write failing tests for AnnotationParser**

```java
package io.casehub.yaml.core.annotation;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class AnnotationParserTest {

    @Test
    void parseSimpleNoArgs() {
        var ann = AnnotationParser.parse("#@background");
        assertEquals("background", ann.name());
        assertTrue(ann.args().isEmpty());
    }

    @Test
    void parseWithLeadingWhitespace() {
        var ann = AnnotationParser.parse("  #@timeout(5s)");
        assertEquals("timeout", ann.name());
        assertEquals("5s", ann.stringArg(0));
    }

    @Test
    void parseSinglePositionalArg() {
        var ann = AnnotationParser.parse("#@timeout(5s)");
        assertEquals("timeout", ann.name());
        assertEquals(1, ann.args().size());
        assertEquals("5s", ann.stringArg(0));
    }

    @Test
    void parseMultiplePositionalArgs() {
        var ann = AnnotationParser.parse("#@requires(agent, rest-client)");
        assertEquals("requires", ann.name());
        assertEquals(2, ann.args().size());
        assertEquals("agent", ann.stringArg(0));
        assertEquals("rest-client", ann.stringArg(1));
    }

    @Test
    void parseMixedArgs() {
        var ann = AnnotationParser.parse("#@retry(3, backoff: exponential)");
        assertEquals("retry", ann.name());
        assertEquals("3", ann.stringArg(0));
        assertEquals("exponential", ann.namedArg("backoff"));
    }

    @Test
    void parseQuotedString() {
        var ann = AnnotationParser.parse("#@description(\"Customer onboarding — triggered on creation\")");
        assertEquals("description", ann.name());
        assertEquals("Customer onboarding — triggered on creation", ann.stringArg(0));
    }

    @Test
    void parseNamedWithQuotedValue() {
        var ann = AnnotationParser.parse("#@schedule(cron: \"0 */6 * * *\")");
        assertEquals("schedule", ann.name());
        assertEquals("0 */6 * * *", ann.namedArg("cron"));
    }

    @Test
    void parseInjectWithQualifier() {
        var ann = AnnotationParser.parse("#@Inject(AgentProvider, qualifier: \"claude\")");
        assertEquals("Inject", ann.name());
        assertEquals("AgentProvider", ann.stringArg(0));
        assertEquals("claude", ann.namedArg("qualifier"));
    }

    @Test
    void parseHyphenatedName() {
        var ann = AnnotationParser.parse("#@on-error(continue)");
        assertEquals("on-error", ann.name());
        assertEquals("continue", ann.stringArg(0));
    }

    @Test
    void parseDuration() {
        var ann = AnnotationParser.parse("#@delay(500ms)");
        assertEquals("delay", ann.name());
        assertEquals("500ms", ann.stringArg(0));
    }

    @Test
    void parseEmptyParens() {
        var ann = AnnotationParser.parse("#@deprecated()");
        assertEquals("deprecated", ann.name());
        assertTrue(ann.args().isEmpty());
    }

    @Test
    void nonAnnotationLineReturnsNull() {
        assertNull(AnnotationParser.parse("# regular comment"));
        assertNull(AnnotationParser.parse("name: value"));
        assertNull(AnnotationParser.parse(""));
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl yaml-core test -Dtest=AnnotationParserTest -DfailIfNoTests=false --batch-mode`
Expected: FAIL — class doesn't exist

- [ ] **Step 3: Implement AnnotationParser**

```java
package io.casehub.yaml.core.annotation;

import java.util.ArrayList;
import java.util.List;

public final class AnnotationParser {

    private AnnotationParser() {}

    public static Annotation parse(String line) {
        if (line == null) return null;
        String trimmed = line.stripLeading();
        if (!trimmed.startsWith("#@")) return null;

        String content = trimmed.substring(2);
        int parenStart = content.indexOf('(');
        if (parenStart < 0) {
            String name = content.trim();
            if (name.isEmpty() || !isValidName(name)) return null;
            return new Annotation(name, List.of());
        }

        String name = content.substring(0, parenStart).trim();
        if (name.isEmpty() || !isValidName(name)) return null;

        int parenEnd = content.lastIndexOf(')');
        if (parenEnd <= parenStart) {
            throw new IllegalArgumentException("Unclosed parenthesis in annotation: " + line);
        }

        String argsStr = content.substring(parenStart + 1, parenEnd).trim();
        if (argsStr.isEmpty()) {
            return new Annotation(name, List.of());
        }

        List<AnnotationArg> args = parseArgs(argsStr);
        return new Annotation(name, args);
    }

    private static List<AnnotationArg> parseArgs(String argsStr) {
        List<AnnotationArg> result = new ArrayList<>();
        int i = 0;
        while (i < argsStr.length()) {
            i = skipWhitespace(argsStr, i);
            if (i >= argsStr.length()) break;

            String token;
            int tokenEnd;
            if (argsStr.charAt(i) == '"') {
                tokenEnd = findClosingQuote(argsStr, i);
                token = argsStr.substring(i + 1, tokenEnd);
                tokenEnd++;
            } else {
                tokenEnd = findTokenEnd(argsStr, i);
                token = argsStr.substring(i, tokenEnd).trim();
            }

            i = skipWhitespace(argsStr, tokenEnd);

            if (i < argsStr.length() && argsStr.charAt(i) == ':') {
                i = skipWhitespace(argsStr, i + 1);
                String value;
                int valueEnd;
                if (i < argsStr.length() && argsStr.charAt(i) == '"') {
                    valueEnd = findClosingQuote(argsStr, i);
                    value = argsStr.substring(i + 1, valueEnd);
                    valueEnd++;
                } else {
                    valueEnd = findTokenEnd(argsStr, i);
                    value = argsStr.substring(i, valueEnd).trim();
                }
                result.add(new AnnotationArg.Named(token, value));
                i = valueEnd;
            } else {
                result.add(new AnnotationArg.Positional(token));
            }

            i = skipWhitespace(argsStr, i);
            if (i < argsStr.length() && argsStr.charAt(i) == ',') {
                i++;
            }
        }
        return result;
    }

    private static int findClosingQuote(String s, int openPos) {
        for (int i = openPos + 1; i < s.length(); i++) {
            if (s.charAt(i) == '\\' && i + 1 < s.length()) { i++; continue; }
            if (s.charAt(i) == '"') return i;
        }
        throw new IllegalArgumentException("Unclosed quote starting at position " + openPos);
    }

    private static int findTokenEnd(String s, int start) {
        int i = start;
        while (i < s.length() && s.charAt(i) != ',' && s.charAt(i) != ':' && s.charAt(i) != ')') {
            i++;
        }
        return i;
    }

    private static int skipWhitespace(String s, int pos) {
        while (pos < s.length() && Character.isWhitespace(s.charAt(pos))) pos++;
        return pos;
    }

    private static boolean isValidName(String name) {
        if (name.isEmpty()) return false;
        char c = name.charAt(0);
        if (!Character.isLetter(c) && c != '_') return false;
        for (int i = 1; i < name.length(); i++) {
            c = name.charAt(i);
            if (!Character.isLetterOrDigit(c) && c != '_' && c != '-' && c != '.') return false;
        }
        return true;
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn -pl yaml-core test -Dtest=AnnotationParserTest --batch-mode`
Expected: PASS — all 12 tests green

- [ ] **Step 5: Commit**

```bash
git add yaml-core/src/main/java/io/casehub/yaml/core/annotation/AnnotationParser.java
git add yaml-core/src/test/java/io/casehub/yaml/core/annotation/AnnotationParserTest.java
git commit -m "feat(#700): AnnotationParser — #@ argument grammar implementation"
```

### Task 3: AnnotationExtractor — pre-parser

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/annotation/AnnotationExtractor.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/annotation/AnnotationExtractorTest.java`

**Interfaces:**
- Consumes: `AnnotationParser.parse(String)` (Task 2), `Annotation`, `AnnotationMap` (Task 1)
- Produces: `AnnotationExtractor.extract(String yamlText) → AnnotationMap`

- [ ] **Step 1: Write failing tests**

```java
package io.casehub.yaml.core.annotation;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class AnnotationExtractorTest {

    @Test
    void extractDocumentLevelAnnotations() {
        String yaml = """
                #@description("Customer onboarding")
                #@requires(agent, rest-client)
                name: Customer onboarding
                steps:
                  - rest-request:
                      url: /api
                """;
        var map = AnnotationExtractor.extract(yaml);
        assertEquals(2, map.documentAnnotations().size());
        assertTrue(map.forDocument("description").isPresent());
        assertTrue(map.forDocument("requires").isPresent());
    }

    @Test
    void extractStepAnnotations() {
        String yaml = """
                name: Test
                steps:
                  #@timeout(5s)
                  - rest-request:
                      url: /api
                  #@retry(3)
                  - agent-invoke:
                      prompt: hello
                """;
        var map = AnnotationExtractor.extract(yaml);
        assertTrue(map.documentAnnotations().isEmpty());
        assertEquals(1, map.forStep(0).size());
        assertEquals("timeout", map.forStep(0).get(0).name());
        assertEquals(1, map.forStep(1).size());
        assertEquals("retry", map.forStep(1).get(0).name());
    }

    @Test
    void extractMultipleAnnotationsOnSameStep() {
        String yaml = """
                name: Test
                steps:
                  #@timeout(2s)
                  #@audit("PII access")
                  - rest-request:
                      url: /api
                """;
        var map = AnnotationExtractor.extract(yaml);
        assertEquals(2, map.forStep(0).size());
        assertTrue(map.hasStepAnnotation(0, "timeout"));
        assertTrue(map.hasStepAnnotation(0, "audit"));
    }

    @Test
    void extractInjectBindings() {
        String yaml = """
                #@Inject(AgentProvider, qualifier: "claude")
                claude: agent
                #@Inject(CaseMemoryStore)
                memory: store
                name: Test
                steps:
                  - rest-request:
                      url: /api
                """;
        var map = AnnotationExtractor.extract(yaml);
        var injects = map.documentAnnotations().stream()
            .filter(a -> a.name().equals("Inject")).toList();
        assertEquals(2, injects.size());
        assertEquals("AgentProvider", injects.get(0).stringArg(0));
        assertEquals("claude", injects.get(0).namedArg("qualifier"));
        assertEquals("CaseMemoryStore", injects.get(1).stringArg(0));
    }

    @Test
    void duplicateAnnotationOnSameTargetThrows() {
        String yaml = """
                name: Test
                steps:
                  #@timeout(5s)
                  #@timeout(3s)
                  - rest-request:
                      url: /api
                """;
        assertThrows(IllegalArgumentException.class, () -> AnnotationExtractor.extract(yaml));
    }

    @Test
    void noAnnotationsReturnsEmpty() {
        String yaml = """
                name: Test
                steps:
                  - rest-request:
                      url: /api
                """;
        var map = AnnotationExtractor.extract(yaml);
        assertTrue(map.documentAnnotations().isEmpty());
        assertTrue(map.forStep(0).isEmpty());
    }

    @Test
    void mixedDocumentAndStepAnnotations() {
        String yaml = """
                #@version(2.1)
                name: Test
                steps:
                  #@timeout(5s)
                  - rest-request:
                      url: /api
                """;
        var map = AnnotationExtractor.extract(yaml);
        assertEquals(1, map.documentAnnotations().size());
        assertEquals("version", map.documentAnnotations().get(0).name());
        assertEquals(1, map.forStep(0).size());
        assertEquals("timeout", map.forStep(0).get(0).name());
    }

    @Test
    void regularCommentsIgnored() {
        String yaml = """
                # This is a regular comment
                #@description("Test")
                name: Test
                steps:
                  # another comment
                  #@timeout(5s)
                  - rest-request:
                      url: /api
                """;
        var map = AnnotationExtractor.extract(yaml);
        assertEquals(1, map.documentAnnotations().size());
        assertEquals(1, map.forStep(0).size());
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl yaml-core test -Dtest=AnnotationExtractorTest -DfailIfNoTests=false --batch-mode`
Expected: FAIL — class doesn't exist

- [ ] **Step 3: Implement AnnotationExtractor**

```java
package io.casehub.yaml.core.annotation;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.HashSet;
import java.util.Set;

public final class AnnotationExtractor {

    private AnnotationExtractor() {}

    public static AnnotationMap extract(String yamlText) {
        if (yamlText == null || yamlText.isEmpty()) return AnnotationMap.empty();

        String[] lines = yamlText.split("\n", -1);
        List<Annotation> documentAnnotations = new ArrayList<>();
        Map<String, List<Annotation>> stepAnnotations = new LinkedHashMap<>();
        List<Annotation> pendingAnnotations = new ArrayList<>();
        boolean inSteps = false;
        int stepIndex = 0;

        for (String line : lines) {
            String trimmed = line.stripLeading();

            Annotation ann = AnnotationParser.parse(line);
            if (ann != null) {
                pendingAnnotations.add(ann);
                continue;
            }

            if (trimmed.isEmpty()) continue;

            if (trimmed.startsWith("steps:")) {
                flushToDocument(documentAnnotations, pendingAnnotations);
                inSteps = true;
                continue;
            }

            if (inSteps && trimmed.startsWith("- ")) {
                if (!pendingAnnotations.isEmpty()) {
                    validateNoDuplicates(pendingAnnotations, "step " + stepIndex);
                    stepAnnotations.put(String.valueOf(stepIndex), List.copyOf(pendingAnnotations));
                    pendingAnnotations.clear();
                }
                stepIndex++;
                continue;
            }

            if (!inSteps && !pendingAnnotations.isEmpty()) {
                flushToDocument(documentAnnotations, pendingAnnotations);
            }
        }

        if (!pendingAnnotations.isEmpty()) {
            flushToDocument(documentAnnotations, pendingAnnotations);
        }

        return new AnnotationMap(documentAnnotations, stepAnnotations);
    }

    private static void flushToDocument(List<Annotation> target, List<Annotation> pending) {
        validateNoDuplicates(pending, "document");
        target.addAll(pending);
        pending.clear();
    }

    private static void validateNoDuplicates(List<Annotation> annotations, String context) {
        Set<String> seen = new HashSet<>();
        for (Annotation ann : annotations) {
            if (!seen.add(ann.name())) {
                throw new IllegalArgumentException(
                    "Duplicate annotation @" + ann.name() + " on " + context);
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn -pl yaml-core test -Dtest=AnnotationExtractorTest --batch-mode`
Expected: PASS — all 8 tests green

- [ ] **Step 5: Commit**

```bash
git add yaml-core/src/main/java/io/casehub/yaml/core/annotation/AnnotationExtractor.java
git add yaml-core/src/test/java/io/casehub/yaml/core/annotation/AnnotationExtractorTest.java
git commit -m "feat(#700): AnnotationExtractor — #@ pre-parser with document + step-level extraction"
```

## Batch 2: Walker Integration + ResolvedStep Annotations

### Task 4: Add annotations to ResolvedStep + Walker

**Files:**
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/ResolvedStep.java` — add `annotations()` default method, add `List<Annotation>` field to each record variant
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/Walker.java` — accept `AnnotationMap`, attach annotations during `resolveOne`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/catalog/WalkerAnnotationTest.java`

**Interfaces:**
- Consumes: `AnnotationMap`, `Annotation` (Task 1), `AnnotationExtractor` (Task 3)
- Produces:
  - `ResolvedStep.annotations()` → `List<Annotation>` (default empty)
  - `Walker.resolve(List<Map<String,Object>> steps, PluginRegistry registry, AnnotationMap annotations)` — new overload

- [ ] **Step 1: Write failing tests**

```java
package io.casehub.yaml.step.catalog;

import io.casehub.yaml.core.annotation.Annotation;
import io.casehub.yaml.core.annotation.AnnotationArg;
import io.casehub.yaml.core.annotation.AnnotationMap;
import io.casehub.yaml.plugin.api.Definition;
import io.casehub.yaml.plugin.api.PluginRegistry;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

import java.util.List;
import java.util.Map;
import java.util.Optional;

class WalkerAnnotationTest {

    private final PluginRegistry registry = name -> {
        if ("rest-request".equals(name)) {
            return Optional.of(Definition.builder("rest-request").build());
        }
        return Optional.empty();
    };

    @Test
    void stepReceivesAnnotationsFromMap() {
        var steps = List.of(
            Map.<String, Object>of("rest-request", Map.of("url", "/api"))
        );
        var timeout = new Annotation("timeout", List.of(new AnnotationArg.Positional("5s")));
        var annotations = new AnnotationMap(List.of(), Map.of("0", List.of(timeout)));

        var resolved = Walker.resolve(steps, registry, annotations);
        assertEquals(1, resolved.size());
        assertEquals(1, resolved.get(0).annotations().size());
        assertEquals("timeout", resolved.get(0).annotations().get(0).name());
    }

    @Test
    void stepWithNoAnnotationsHasEmptyList() {
        var steps = List.of(
            Map.<String, Object>of("rest-request", Map.of("url", "/api"))
        );
        var resolved = Walker.resolve(steps, registry, AnnotationMap.empty());
        assertEquals(1, resolved.size());
        assertTrue(resolved.get(0).annotations().isEmpty());
    }

    @Test
    void existingResolveMethodStillWorks() {
        var steps = List.of(
            Map.<String, Object>of("rest-request", Map.of("url", "/api"))
        );
        var resolved = Walker.resolve(steps, registry);
        assertEquals(1, resolved.size());
        assertTrue(resolved.get(0).annotations().isEmpty());
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl yaml-step-runtime test -Dtest=WalkerAnnotationTest -DfailIfNoTests=false --batch-mode`
Expected: FAIL — `annotations()` method doesn't exist on ResolvedStep

- [ ] **Step 3: Add annotations() to ResolvedStep sealed interface**

Add a default method to the sealed interface and a `List<Annotation>` annotations field to each record. For backward compatibility, all existing record constructors get an overload that defaults annotations to `List.of()`.

The `ResolvedStep` interface gains:
```java
default List<io.casehub.yaml.core.annotation.Annotation> annotations() { return List.of(); }
```

Each record variant (PluginStep, InvokeStep, BlockStep, etc.) adds an `annotations` field with the existing constructors delegating to `List.of()`. Use `ide_replace_member` for each record.

- [ ] **Step 4: Add Walker.resolve overload accepting AnnotationMap**

Add to Walker:
```java
public static List<ResolvedStep> resolve(
        List<Map<String, Object>> steps, PluginRegistry registry, AnnotationMap annotations) {
    Set<String> seenNames = new java.util.HashSet<>();
    List<ResolvedStep> result = resolve(steps, registry, 0, "root", seenNames, annotations);
    validateBarrierQuorumReferences(result, seenNames);
    result = io.casehub.yaml.step.eval.FusionPass.fuse(result, registry);
    return result;
}
```

Modify the existing `resolve` and `resolveOne` to thread the `AnnotationMap` through, attaching `annotations.forStep(index)` to the step at each index in the top-level list.

The existing no-annotation overload delegates: `resolve(steps, registry, AnnotationMap.empty())`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn -pl yaml-step-runtime test -Dtest=WalkerAnnotationTest --batch-mode`
Expected: PASS — all 3 tests green

- [ ] **Step 6: Run full yaml-step-runtime test suite for regressions**

Run: `mvn -pl yaml-step-runtime test --batch-mode`
Expected: All existing tests still pass

- [ ] **Step 7: Commit**

```bash
git add yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/ResolvedStep.java
git add yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/Walker.java
git add yaml-step-runtime/src/test/java/io/casehub/yaml/step/catalog/WalkerAnnotationTest.java
git commit -m "feat(#700): Walker annotation integration — ResolvedStep.annotations() + AnnotationMap threading"
```

## Batch 3: @Inject Resolution (Phase 2)

### Task 5: InjectionResolver SPI + InjectionBinding record

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/annotation/InjectionResolver.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/annotation/InjectionBinding.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/annotation/InjectionBindingTest.java`

**Interfaces:**
- Consumes: `Annotation`, `AnnotationMap` (Task 1)
- Produces:
  - `InjectionResolver` — `@FunctionalInterface Object resolve(String typeName, Map<String, String> qualifiers)`
  - `InjectionBinding(String variableName, String typeHint, String typeName, Map<String, String> qualifiers)` — extracted from `@Inject` annotation + binding line
  - `InjectionBinding.extractAll(AnnotationMap map, Map<String, Object> contentMap) → List<InjectionBinding>`

- [ ] **Step 1: Write failing tests**

```java
package io.casehub.yaml.core.annotation;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

class InjectionBindingTest {

    @Test
    void extractBindingsFromAnnotationMap() {
        var inject1 = new Annotation("Inject", List.of(
            new AnnotationArg.Positional("AgentProvider"),
            new AnnotationArg.Named("qualifier", "claude")));
        var inject2 = new Annotation("Inject", List.of(
            new AnnotationArg.Positional("CaseMemoryStore")));
        var map = new AnnotationMap(List.of(inject1, inject2), Map.of());

        var content = new LinkedHashMap<String, Object>();
        content.put("claude", "agent");
        content.put("memory", "store");
        content.put("name", "Test");

        var bindings = InjectionBinding.extractAll(map, content);
        assertEquals(2, bindings.size());

        assertEquals("claude", bindings.get(0).variableName());
        assertEquals("agent", bindings.get(0).typeHint());
        assertEquals("AgentProvider", bindings.get(0).typeName());
        assertEquals("claude", bindings.get(0).qualifiers().get("qualifier"));

        assertEquals("memory", bindings.get(1).variableName());
        assertEquals("store", bindings.get(1).typeHint());
        assertEquals("CaseMemoryStore", bindings.get(1).typeName());
        assertTrue(bindings.get(1).qualifiers().isEmpty());
    }

    @Test
    void noInjectAnnotationsReturnsEmpty() {
        var desc = new Annotation("description", List.of(new AnnotationArg.Positional("test")));
        var map = new AnnotationMap(List.of(desc), Map.of());
        var bindings = InjectionBinding.extractAll(map, Map.of("name", "Test"));
        assertTrue(bindings.isEmpty());
    }

    @Test
    void resolverInterface() {
        InjectionResolver resolver = (typeName, qualifiers) -> "resolved:" + typeName;
        assertEquals("resolved:AgentProvider", resolver.resolve("AgentProvider", Map.of()));
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl yaml-core test -Dtest=InjectionBindingTest -DfailIfNoTests=false --batch-mode`
Expected: FAIL

- [ ] **Step 3: Implement InjectionResolver and InjectionBinding**

`InjectionResolver.java`:
```java
package io.casehub.yaml.core.annotation;

import java.util.Map;

@FunctionalInterface
public interface InjectionResolver {
    Object resolve(String typeName, Map<String, String> qualifiers);
}
```

`InjectionBinding.java`:
```java
package io.casehub.yaml.core.annotation;

import java.util.ArrayList;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public record InjectionBinding(
        String variableName,
        String typeHint,
        String typeName,
        Map<String, String> qualifiers) {

    public InjectionBinding {
        qualifiers = qualifiers != null ? Map.copyOf(qualifiers) : Map.of();
    }

    public static List<InjectionBinding> extractAll(AnnotationMap annotationMap, Map<String, Object> contentMap) {
        List<Annotation> injects = annotationMap.documentAnnotations().stream()
            .filter(a -> "Inject".equals(a.name()))
            .toList();

        if (injects.isEmpty()) return List.of();

        Iterator<Map.Entry<String, Object>> contentIter = contentMap.entrySet().iterator();
        List<InjectionBinding> result = new ArrayList<>();
        int injectIndex = 0;

        List<Annotation> allDocAnns = annotationMap.documentAnnotations();
        int annCursor = 0;

        for (Map.Entry<String, Object> entry : contentMap.entrySet()) {
            while (annCursor < allDocAnns.size() && "Inject".equals(allDocAnns.get(annCursor).name())) {
                if (injectIndex < injects.size()) {
                    Annotation inject = injects.get(injectIndex);
                    String typeName = inject.stringArg(0);
                    Map<String, String> qualifiers = new LinkedHashMap<>();
                    for (AnnotationArg arg : inject.args()) {
                        if (arg instanceof AnnotationArg.Named n) {
                            qualifiers.put(n.name(), n.value());
                        }
                    }
                    result.add(new InjectionBinding(
                        entry.getKey(),
                        String.valueOf(entry.getValue()),
                        typeName, qualifiers));
                    injectIndex++;
                }
                annCursor++;
                break;
            }
            if (annCursor < allDocAnns.size() && !"Inject".equals(allDocAnns.get(annCursor).name())) {
                annCursor++;
            }
        }

        return result;
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn -pl yaml-core test -Dtest=InjectionBindingTest --batch-mode`
Expected: PASS — all 3 tests green

- [ ] **Step 5: Commit**

```bash
git add yaml-core/src/main/java/io/casehub/yaml/core/annotation/InjectionResolver.java
git add yaml-core/src/main/java/io/casehub/yaml/core/annotation/InjectionBinding.java
git add yaml-core/src/test/java/io/casehub/yaml/core/annotation/InjectionBindingTest.java
git commit -m "feat(#700): InjectionResolver SPI + InjectionBinding extraction from @Inject annotations"
```

### Task 6: StructuralStepEvaluator @Inject wiring

**Files:**
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StructuralStepEvaluator.java` — add injection resolution before step evaluation
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/StructuralStepEvaluatorInjectionTest.java`

**Interfaces:**
- Consumes: `InjectionBinding.extractAll(AnnotationMap, Map)` (Task 5), `InjectionResolver` (Task 5), `VariableResolver.withObjectScope(String, ObjectVariableSource)` (existing)
- Produces: `StructuralStepEvaluator.withInjections(List<InjectionBinding>, InjectionResolver) → StructuralStepEvaluator` — returns a new evaluator with injected bindings wired into the VariableResolver

- [ ] **Step 1: Write failing tests**

```java
package io.casehub.yaml.step.eval;

import io.casehub.yaml.core.annotation.*;
import io.casehub.yaml.core.resolver.VariableResolver;
import io.casehub.yaml.plugin.api.Result;
import io.casehub.yaml.step.catalog.ResolvedStep;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;

class StructuralStepEvaluatorInjectionTest {

    @Test
    void injectedBindingsAvailableInResolver() {
        var evaluator = new StructuralStepEvaluator(
            new io.casehub.yaml.core.condition.ConditionEvaluator());

        var binding = new InjectionBinding("claude", "agent", "AgentProvider", Map.of("qualifier", "claude"));
        InjectionResolver resolver = (typeName, qualifiers) -> Map.of("name", "claude-agent", "ready", true);

        var enrichedEvaluator = evaluator.withInjections(List.of(binding), resolver);

        var capturedResolver = new AtomicReference<VariableResolver>();
        StepRunner runner = (step, vr) -> {
            capturedResolver.set(vr);
            return Result.of(Map.of());
        };

        var step = new ResolvedStep.PluginStep("test", "test-action",
            Map.of(), Map.of());
        var baseResolver = new VariableResolver(Map.of(), java.util.Set.of());

        enrichedEvaluator.evaluate(step, baseResolver, runner);

        assertNotNull(capturedResolver.get());
        Object resolved = capturedResolver.get().resolve("${claude.name}");
        assertEquals("claude-agent", resolved);
    }

    @Test
    void unresolvedBindingThrows() {
        var evaluator = new StructuralStepEvaluator(
            new io.casehub.yaml.core.condition.ConditionEvaluator());

        var binding = new InjectionBinding("claude", "agent", "AgentProvider", Map.of());
        InjectionResolver resolver = (typeName, qualifiers) -> null;

        assertThrows(IllegalStateException.class, () ->
            evaluator.withInjections(List.of(binding), resolver));
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl yaml-step-runtime test -Dtest=StructuralStepEvaluatorInjectionTest -DfailIfNoTests=false --batch-mode`
Expected: FAIL

- [ ] **Step 3: Implement withInjections on StructuralStepEvaluator**

Add a method that resolves all injection bindings and returns a new evaluator whose `evaluate` method enriches the VariableResolver with object scopes for each binding:

```java
public StructuralStepEvaluator withInjections(List<InjectionBinding> bindings, InjectionResolver resolver) {
    Map<String, Object> injected = new java.util.LinkedHashMap<>();
    for (InjectionBinding binding : bindings) {
        Object resolved = resolver.resolve(binding.typeName(), binding.qualifiers());
        if (resolved == null) {
            throw new IllegalStateException(
                binding.typeName() + " not available — @Inject binding '"
                + binding.variableName() + "' could not be resolved");
        }
        injected.put(binding.variableName(), resolved);
    }
    // Store injected map for use in evaluate — enrich resolver with object scopes
    return new StructuralStepEvaluator(this.conditionEvaluator, this.scope, injected);
}
```

Add a private constructor and field for injected bindings. In `evaluate`, enrich the resolver:
```java
VariableResolver enriched = resolver;
for (var entry : injectedBindings.entrySet()) {
    enriched = enriched.withObjectScope(entry.getKey(), name -> {
        if (entry.getValue() instanceof Map<?,?> m) return ((Map<String,Object>)m).get(name);
        return null;
    });
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn -pl yaml-step-runtime test -Dtest=StructuralStepEvaluatorInjectionTest --batch-mode`
Expected: PASS

- [ ] **Step 5: Run full suite for regressions**

Run: `mvn -pl yaml-step-runtime test --batch-mode`
Expected: All existing tests pass

- [ ] **Step 6: Commit**

```bash
git add yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StructuralStepEvaluator.java
git add yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/StructuralStepEvaluatorInjectionTest.java
git commit -m "feat(#700): @Inject resolution wiring — StructuralStepEvaluator.withInjections()"
```

## Batch 4: Decorator Migration (Phase 3)

### Task 7: Decorator dual-path in DecoratorChain + Walker

**Files:**
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/DecoratorChain.java` — read decorator values from annotations when present, log deprecation warning for key-form
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/Walker.java` — during `resolveOne`, merge annotation decorators into the decorator map with precedence
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/DecoratorAnnotationMigrationTest.java`

**Interfaces:**
- Consumes: `ResolvedStep.annotations()` (Task 4), `Annotation`, `AnnotationArg` (Task 1)
- Produces: Decorator values sourced from annotations when present, with deprecation warnings for key-form usage of migrated decorators

The 12 migrated decorators (D4): `timeout`, `retry`, `delay`, `priority`, `resource`, `background`, `on-error`, `trigger`, `semaphore`, `at`, `cancel`, `mutex`.

- [ ] **Step 1: Write failing tests**

```java
package io.casehub.yaml.step.eval;

import io.casehub.yaml.core.annotation.Annotation;
import io.casehub.yaml.core.annotation.AnnotationArg;
import io.casehub.yaml.core.annotation.AnnotationMap;
import io.casehub.yaml.plugin.api.Definition;
import io.casehub.yaml.plugin.api.PluginRegistry;
import io.casehub.yaml.step.catalog.ResolvedStep;
import io.casehub.yaml.step.catalog.Walker;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

import java.util.List;
import java.util.Map;
import java.util.Optional;

class DecoratorAnnotationMigrationTest {

    private final PluginRegistry registry = name -> {
        if ("rest-request".equals(name))
            return Optional.of(Definition.builder("rest-request").build());
        return Optional.empty();
    };

    @Test
    void annotationTimeoutTakesPrecedenceOverKey() {
        var steps = List.of(
            Map.<String, Object>of(
                "rest-request", Map.of("url", "/api"),
                "timeout", "10s"));
        var timeout = new Annotation("timeout", List.of(new AnnotationArg.Positional("5s")));
        var annotations = new AnnotationMap(List.of(), Map.of("0", List.of(timeout)));

        var resolved = Walker.resolve(steps, registry, annotations);
        var step = resolved.get(0);
        assertEquals("5s", step.decorators().get("timeout"));
    }

    @Test
    void annotationOnlyWithNoKey() {
        var steps = List.of(
            Map.<String, Object>of("rest-request", Map.of("url", "/api")));
        var retry = new Annotation("retry", List.of(new AnnotationArg.Positional("3")));
        var annotations = new AnnotationMap(List.of(), Map.of("0", List.of(retry)));

        var resolved = Walker.resolve(steps, registry, annotations);
        var step = resolved.get(0);
        assertEquals("3", step.decorators().get("retry"));
    }

    @Test
    void nonMigratedAnnotationNotInjectedAsDecorator() {
        var steps = List.of(
            Map.<String, Object>of("rest-request", Map.of("url", "/api")));
        var desc = new Annotation("description", List.of(new AnnotationArg.Positional("test")));
        var annotations = new AnnotationMap(List.of(), Map.of("0", List.of(desc)));

        var resolved = Walker.resolve(steps, registry, annotations);
        var step = resolved.get(0);
        assertFalse(step.decorators().containsKey("description"));
        assertEquals(1, step.annotations().size());
    }

    @Test
    void backgroundAnnotationNoArgs() {
        var steps = List.of(
            Map.<String, Object>of("rest-request", Map.of("url", "/api")));
        var bg = new Annotation("background", List.of());
        var annotations = new AnnotationMap(List.of(), Map.of("0", List.of(bg)));

        var resolved = Walker.resolve(steps, registry, annotations);
        var step = resolved.get(0);
        assertEquals(true, step.decorators().get("background"));
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl yaml-step-runtime test -Dtest=DecoratorAnnotationMigrationTest -DfailIfNoTests=false --batch-mode`
Expected: FAIL

- [ ] **Step 3: Implement annotation-to-decorator merging in Walker**

In `Walker.resolveOne`, after building the `decorators` map and before constructing the `ResolvedStep`, merge annotation decorator candidates:

```java
private static final Set<String> MIGRATED_DECORATORS = Set.of(
    "timeout", "retry", "delay", "priority", "resource", "background",
    "on-error", "trigger", "semaphore", "at", "cancel", "mutex");

// In resolveOne, after existing decorator extraction:
List<Annotation> stepAnns = annotations.forStep(stepIndexInParent);
for (Annotation ann : stepAnns) {
    if (MIGRATED_DECORATORS.contains(ann.name())) {
        if (decorators.containsKey(ann.name())) {
            LOG.warning("Step " + index + ": decorator key '" + ann.name()
                + "' is deprecated — use #@" + ann.name() + "() annotation instead");
        }
        // Annotation takes precedence (D3)
        Object value = ann.args().isEmpty() ? true : ann.stringArg(0);
        decorators.put(ann.name(), value);
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn -pl yaml-step-runtime test -Dtest=DecoratorAnnotationMigrationTest --batch-mode`
Expected: PASS — all 4 tests green

- [ ] **Step 5: Run full suite for regressions**

Run: `mvn -pl yaml-step-runtime test --batch-mode`
Expected: All existing tests pass

- [ ] **Step 6: Commit**

```bash
git add yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/Walker.java
git add yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/DecoratorAnnotationMigrationTest.java
git commit -m "feat(#700): decorator migration dual-path — annotation-over-key precedence + deprecation warnings"
```

### Task 8: Full integration test — end-to-end annotation pipeline

**Files:**
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/AnnotationIntegrationTest.java`

**Interfaces:**
- Consumes: All previous tasks — full pipeline from raw YAML text through AnnotationExtractor, PlaybookParser, Walker, to StructuralStepEvaluator

- [ ] **Step 1: Write the integration test**

```java
package io.casehub.yaml.step;

import io.casehub.yaml.core.annotation.AnnotationExtractor;
import io.casehub.yaml.core.annotation.InjectionBinding;
import io.casehub.yaml.core.annotation.InjectionResolver;
import io.casehub.yaml.core.condition.ConditionEvaluator;
import io.casehub.yaml.core.resolver.VariableResolver;
import io.casehub.yaml.plugin.api.Definition;
import io.casehub.yaml.plugin.api.PluginRegistry;
import io.casehub.yaml.plugin.api.Result;
import io.casehub.yaml.step.catalog.Walker;
import io.casehub.yaml.step.eval.StructuralStepEvaluator;
import io.casehub.yaml.step.statemachine.PlaybookParser;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Optional;

class AnnotationIntegrationTest {

    private final PluginRegistry registry = name -> {
        if ("rest-request".equals(name) || "agent-invoke".equals(name)) {
            return Optional.of(Definition.builder(name).build());
        }
        return Optional.empty();
    };

    @Test
    @SuppressWarnings("unchecked")
    void fullPipelineWithAnnotationsAndInject() {
        String yaml = """
                #@description("Integration test playbook")
                #@requires(agent)
                #@Inject(AgentProvider, qualifier: "claude")
                claude: agent
                name: Integration Test
                steps:
                  #@timeout(2s)
                  - rest-request:
                      url: /api/test
                  #@retry(3)
                  - agent-invoke:
                      prompt: hello
                """;

        // Phase 1: Extract annotations
        var annotationMap = AnnotationExtractor.extract(yaml);
        assertTrue(annotationMap.forDocument("description").isPresent());
        assertTrue(annotationMap.forDocument("requires").isPresent());

        // Phase 2: Parse YAML (SnakeYAML ignores #@ comments)
        var doc = PlaybookParser.parse(yaml);
        assertEquals("Integration Test", doc.content().get("name"));
        // Binding line is inert in content map
        assertEquals("agent", doc.content().get("claude"));

        // Phase 2b: Extract @Inject bindings
        var bindings = InjectionBinding.extractAll(annotationMap, doc.content());
        assertEquals(1, bindings.size());
        assertEquals("claude", bindings.get(0).variableName());

        // Phase 3: Resolve steps with annotations
        var steps = (List<Map<String, Object>>) doc.content().get("steps");
        var resolved = Walker.resolve(steps, registry, annotationMap);

        assertEquals(2, resolved.size());
        // Step 0 has @timeout merged as decorator
        assertEquals("2s", resolved.get(0).decorators().get("timeout"));
        // Step 1 has @retry merged as decorator
        assertEquals("3", resolved.get(1).decorators().get("retry"));

        // Phase 4: Evaluate with injections
        InjectionResolver injResolver = (typeName, qualifiers) ->
            Map.of("name", "test-" + typeName);
        var evaluator = new StructuralStepEvaluator(new ConditionEvaluator());
        var enriched = evaluator.withInjections(bindings, injResolver);

        var executedSteps = new ArrayList<String>();
        var runner = (io.casehub.yaml.step.eval.StepRunner) (step, vr) -> {
            executedSteps.add(step instanceof io.casehub.yaml.step.catalog.ResolvedStep.PluginStep ps
                ? ps.actionName() : "unknown");
            return Result.of(Map.of("status", "ok"));
        };

        var resolver = new VariableResolver(Map.of(), java.util.Set.of());
        for (var step : resolved) {
            enriched.evaluate(step, resolver, runner);
        }

        assertEquals(List.of("rest-request", "agent-invoke"), executedSteps);
    }
}
```

- [ ] **Step 2: Run integration test**

Run: `mvn -pl yaml-step-runtime test -Dtest=AnnotationIntegrationTest --batch-mode`
Expected: PASS

- [ ] **Step 3: Run both yaml-core and yaml-step-runtime full suites**

Run: `mvn -pl yaml-core,yaml-step-runtime test --batch-mode`
Expected: All tests pass across both modules

- [ ] **Step 4: Commit**

```bash
git add yaml-step-runtime/src/test/java/io/casehub/yaml/step/AnnotationIntegrationTest.java
git commit -m "feat(#700): end-to-end annotation integration test — all 3 phases verified"
```

## References

- [2026-11-04-annotations-design.md] — design spec this plan implements
- [decisions-700.md] — D1–D10 validated decisions
- `yaml-core/src/main/java/io/casehub/yaml/core/resolver/VariableResolver.java` — variable resolution, withObjectScope
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/Walker.java` — step resolution, PROMOTABLE_DECORATORS, RESERVED_KEYS
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/ResolvedStep.java` — sealed interface, 13 record variants
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/StepKeywords.java` — DECORATOR_KEYS (28 entries)
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/DecoratorChain.java` — decorator runtime wrapping
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StructuralStepEvaluator.java` — step evaluation + result scope
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/statemachine/PlaybookParser.java` — SnakeYAML entry point
- `yaml-core/src/main/java/io/casehub/yaml/core/playbook/PlaybookDocument.java` — current data model
- GitHub #700 — feature spec
- GitHub #716 — nested annotations (deferred)
- GitHub #717 — bare @ UI rendering (deferred)
