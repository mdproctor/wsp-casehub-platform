# Match Diagnostics Trace API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #976 — feat: match diagnostics trace API — explain why templates don't match
**Issue group:** #976

**Goal:** Add `matchWithTrace()` to `UnifiedTemplateRegistry` returning diagnostic data that explains why templates failed to match — candidate list, keyword affinities, per-element structural walk, and scores.

**Architecture:** New trace types (`MatchTraceResult`, `MatchTrace`, `CandidateTrace`, `ElementTrace`, `CandidateOutcome`, `ElementKind`) in `template-registry-api`. `StructuralMatcher` gains `matchWithTrace()` returning element-level diagnostics. `InMemoryTemplateRegistry` and `NlpTemplateRegistry` implement `matchWithTrace()` on top of their existing match pipelines, collecting trace data alongside match results.

**Tech Stack:** Pure Java records and enums. No new dependencies. Tests use AssertJ + JUnit 5. `NlpTemplateRegistry` tests use `OpenNlpTokenizer`.

## Global Constraints

- `template-registry-api` must remain zero-dependency (only depends on yaml-core for `VariableConstraint`)
- Existing `match()` methods must not change — zero hot-path overhead
- `ElementKind` is extracted to `template-registry-api` as a shared type; `StructuralMatcher.ElementKind` updated to reference it

---

## Batch 1: Trace types and SPI surface

### Task 1: Trace data model types in template-registry-api

**Files:**
- Create: `template-registry-api/src/main/java/io/casehub/template/registry/ElementKind.java`
- Create: `template-registry-api/src/main/java/io/casehub/template/registry/ElementTrace.java`
- Create: `template-registry-api/src/main/java/io/casehub/template/registry/CandidateOutcome.java`
- Create: `template-registry-api/src/main/java/io/casehub/template/registry/CandidateTrace.java`
- Create: `template-registry-api/src/main/java/io/casehub/template/registry/MatchTrace.java`
- Create: `template-registry-api/src/main/java/io/casehub/template/registry/MatchTraceResult.java`
- Test: `template-registry-api/src/test/java/io/casehub/template/registry/MatchTraceTest.java`

**Interfaces:**
- Produces: `ElementKind` enum (LITERAL, VARIABLE, CLAUSE), `ElementTrace(ElementKind kind, String expected, String actual, boolean matched)`, `CandidateOutcome` enum, `CandidateTrace(String namespace, String templateName, int patternIndex, double keywordAffinity, CandidateOutcome outcome, List<ElementTrace> elements, double score)`, `MatchTrace(List<CandidateTrace> candidates, String bestCandidate, double bestScore)`, `MatchTraceResult(TemplateMatch result, MatchTrace trace)`

- [ ] **Step 1: Write failing tests for trace types**

Create `MatchTraceTest.java`:

```java
package io.casehub.template.registry;

import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.Map;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class MatchTraceTest {

    @Test
    void elementTraceConstruction() {
        var trace = new ElementTrace(ElementKind.LITERAL, "approve", "approved", true);
        assertThat(trace.kind()).isEqualTo(ElementKind.LITERAL);
        assertThat(trace.expected()).isEqualTo("approve");
        assertThat(trace.actual()).isEqualTo("approved");
        assertThat(trace.matched()).isTrue();
    }

    @Test
    void elementTraceWithNullActual() {
        var trace = new ElementTrace(ElementKind.LITERAL, "approve", null, false);
        assertThat(trace.actual()).isNull();
        assertThat(trace.matched()).isFalse();
    }

    @Test
    void elementTraceRejectsNullKind() {
        assertThatThrownBy(() -> new ElementTrace(null, "x", "y", true))
            .isInstanceOf(NullPointerException.class);
    }

    @Test
    void elementTraceRejectsNullExpected() {
        assertThatThrownBy(() -> new ElementTrace(ElementKind.LITERAL, null, "y", true))
            .isInstanceOf(NullPointerException.class);
    }

    @Test
    void candidateTraceConstruction() {
        var elements = List.of(
            new ElementTrace(ElementKind.LITERAL, "i", "i", true),
            new ElementTrace(ElementKind.VARIABLE, "decision", "approve", true)
        );
        var candidate = new CandidateTrace("ns", "vote", 0, -1.0,
            CandidateOutcome.MATCHED, elements, 1.0);
        assertThat(candidate.namespace()).isEqualTo("ns");
        assertThat(candidate.templateName()).isEqualTo("vote");
        assertThat(candidate.elements()).hasSize(2);
        assertThat(candidate.outcome()).isEqualTo(CandidateOutcome.MATCHED);
    }

    @Test
    void candidateTraceElementsAreDefensivelyCopied() {
        var elements = new java.util.ArrayList<>(List.of(
            new ElementTrace(ElementKind.LITERAL, "x", "x", true)));
        var candidate = new CandidateTrace("ns", "t", 0, -1.0,
            CandidateOutcome.MATCHED, elements, 1.0);
        elements.clear();
        assertThat(candidate.elements()).hasSize(1);
    }

    @Test
    void matchTraceConstruction() {
        var candidate = new CandidateTrace("ns", "vote", 0, -1.0,
            CandidateOutcome.MATCHED, List.of(), 1.0);
        var trace = new MatchTrace(List.of(candidate), "ns:vote", 1.0);
        assertThat(trace.candidates()).hasSize(1);
        assertThat(trace.bestCandidate()).isEqualTo("ns:vote");
        assertThat(trace.bestScore()).isEqualTo(1.0);
    }

    @Test
    void matchTraceWithNoBestCandidate() {
        var candidate = new CandidateTrace("ns", "vote", 0, -1.0,
            CandidateOutcome.REGEX_FAILED, List.of(), 0.0);
        var trace = new MatchTrace(List.of(candidate), null, 0.0);
        assertThat(trace.bestCandidate()).isNull();
    }

    @Test
    void matchTraceResultComposition() {
        var match = new TemplateMatch.Unmatched("hello");
        var trace = new MatchTrace(List.of(), null, 0.0);
        var result = new MatchTraceResult(match, trace);
        assertThat(result.result()).isEqualTo(match);
        assertThat(result.trace()).isEqualTo(trace);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `/opt/homebrew/bin/mvn --batch-mode -pl template-registry-api test -Dtest=MatchTraceTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: compilation failure — types don't exist yet

- [ ] **Step 3: Create the trace types**

Use `ide_create_file` to create each file:

`ElementKind.java`:
```java
package io.casehub.template.registry;

public enum ElementKind {
    LITERAL,
    VARIABLE,
    CLAUSE
}
```

`ElementTrace.java`:
```java
package io.casehub.template.registry;

import java.util.Objects;

public record ElementTrace(
    ElementKind kind,
    String expected,
    String actual,
    boolean matched
) {
    public ElementTrace {
        Objects.requireNonNull(kind, "kind");
        Objects.requireNonNull(expected, "expected");
    }
}
```

`CandidateOutcome.java`:
```java
package io.casehub.template.registry;

public enum CandidateOutcome {
    MATCHED,
    KEYWORD_FILTERED,
    REGEX_FAILED,
    STRUCTURAL_FAILED,
    CONSTRAINT_FAILED,
    BELOW_THRESHOLD
}
```

`CandidateTrace.java`:
```java
package io.casehub.template.registry;

import java.util.List;
import java.util.Objects;

public record CandidateTrace(
    String namespace,
    String templateName,
    int patternIndex,
    double keywordAffinity,
    CandidateOutcome outcome,
    List<ElementTrace> elements,
    double score
) {
    public CandidateTrace {
        Objects.requireNonNull(namespace, "namespace");
        Objects.requireNonNull(templateName, "templateName");
        Objects.requireNonNull(outcome, "outcome");
        Objects.requireNonNull(elements, "elements");
        elements = List.copyOf(elements);
    }
}
```

`MatchTrace.java`:
```java
package io.casehub.template.registry;

import java.util.List;
import java.util.Objects;

public record MatchTrace(
    List<CandidateTrace> candidates,
    String bestCandidate,
    double bestScore
) {
    public MatchTrace {
        Objects.requireNonNull(candidates, "candidates");
        candidates = List.copyOf(candidates);
    }
}
```

`MatchTraceResult.java`:
```java
package io.casehub.template.registry;

import java.util.Objects;

public record MatchTraceResult(
    TemplateMatch result,
    MatchTrace trace
) {
    public MatchTraceResult {
        Objects.requireNonNull(result, "result");
        Objects.requireNonNull(trace, "trace");
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `/opt/homebrew/bin/mvn --batch-mode -pl template-registry-api test -Dtest=MatchTraceTest`
Expected: all 8 tests PASS

- [ ] **Step 5: Add matchWithTrace() to UnifiedTemplateRegistry SPI**

Use `ide_insert_member` to add two methods to `UnifiedTemplateRegistry` after the existing `match` methods:

```java
MatchTraceResult matchWithTrace(String input);

MatchTraceResult matchWithTrace(String namespaceName, String input);
```

- [ ] **Step 6: Update StructuralMatcher.ElementKind to reference shared type**

Use `ide_edit_member` to replace `StructuralMatcher.ElementKind` enum with:

```java
// Alias to shared type — consumers should use io.casehub.template.registry.ElementKind directly
```

Update `StructuralMatcher.Element` record to use `io.casehub.template.registry.ElementKind` and update all references in `StructuralMatcher.java` (compile, match, compileSegment). Use `ide_replace_text_in_file` to update the import and all `ElementKind.` references.

- [ ] **Step 7: Run full module tests**

Run: `/opt/homebrew/bin/mvn --batch-mode -pl template-registry-api,template-registry -am test`
Expected: all existing tests still pass (StructuralMatcher tests use the shared ElementKind)

- [ ] **Step 8: Commit**

```bash
git add template-registry-api/src/main/java/io/casehub/template/registry/ElementKind.java template-registry-api/src/main/java/io/casehub/template/registry/ElementTrace.java template-registry-api/src/main/java/io/casehub/template/registry/CandidateOutcome.java template-registry-api/src/main/java/io/casehub/template/registry/CandidateTrace.java template-registry-api/src/main/java/io/casehub/template/registry/MatchTrace.java template-registry-api/src/main/java/io/casehub/template/registry/MatchTraceResult.java template-registry-api/src/main/java/io/casehub/template/registry/UnifiedTemplateRegistry.java template-registry-api/src/test/java/io/casehub/template/registry/MatchTraceTest.java template-registry/src/main/java/io/casehub/template/registry/nlp/StructuralMatcher.java
git commit -m "feat(#976): trace data model types and matchWithTrace SPI"
```

---

## Batch 2: StructuralMatcher trace and InMemoryTemplateRegistry implementation

### Task 2: StructuralMatcher.matchWithTrace()

**Files:**
- Modify: `template-registry/src/main/java/io/casehub/template/registry/nlp/StructuralMatcher.java`
- Test: `template-registry/src/test/java/io/casehub/template/registry/nlp/StructuralMatcherTest.java`

**Interfaces:**
- Consumes: `ElementKind`, `ElementTrace` from template-registry-api
- Produces: `StructuralMatcher.TraceableMatchResult(Optional<MatchResult> result, List<ElementTrace> elements)` — new record inside `StructuralMatcher`; `StructuralMatcher.matchWithTrace(List<AnnotatedToken> tokens, Map<String, VariableConstraint> constraints)` — new method

- [ ] **Step 1: Write failing tests for matchWithTrace**

Add to `StructuralMatcherTest.java`:

```java
@Test
void matchWithTraceReportsElementsOnSuccess() {
    var matcher = StructuralMatcher.compile(
        "I ${decision} this ${subject}", tokenizer);
    var tokens = tokenizer.tokenize("I approve this design");
    var result = matcher.matchWithTrace(tokens, Map.of());
    assertThat(result.result()).isPresent();
    assertThat(result.elements()).isNotEmpty();
    assertThat(result.elements().get(0).kind())
        .isEqualTo(io.casehub.template.registry.ElementKind.LITERAL);
    assertThat(result.elements().get(0).matched()).isTrue();
}

@Test
void matchWithTraceReportsFailedLiteral() {
    var matcher = StructuralMatcher.compile(
        "I ${decision} this ${subject}", tokenizer);
    var tokens = tokenizer.tokenize("the design looks good to me");
    var result = matcher.matchWithTrace(tokens, Map.of());
    assertThat(result.result()).isEmpty();
    assertThat(result.elements()).isNotEmpty();
    var firstLiteral = result.elements().stream()
        .filter(e -> e.kind() == io.casehub.template.registry.ElementKind.LITERAL)
        .findFirst().orElseThrow();
    assertThat(firstLiteral.matched()).isFalse();
    assertThat(firstLiteral.expected()).isEqualTo("i");
}

@Test
void matchWithTraceReportsVariableCapture() {
    var matcher = StructuralMatcher.compile(
        "I ${decision} this ${subject}", tokenizer);
    var tokens = tokenizer.tokenize("I approve this design");
    var result = matcher.matchWithTrace(tokens, Map.of());
    var clauseElements = result.elements().stream()
        .filter(e -> e.kind() == io.casehub.template.registry.ElementKind.CLAUSE)
        .toList();
    assertThat(clauseElements).isNotEmpty();
    assertThat(clauseElements.stream().anyMatch(e ->
        "decision".equals(e.expected()) && e.matched())).isTrue();
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `/opt/homebrew/bin/mvn --batch-mode -pl template-registry test -Dtest=StructuralMatcherTest#matchWithTrace* -Dsurefire.failIfNoSpecifiedTests=false`
Expected: compilation failure — `matchWithTrace` doesn't exist

- [ ] **Step 3: Implement matchWithTrace()**

Add `TraceableMatchResult` record inside `StructuralMatcher`:

```java
public record TraceableMatchResult(
    Optional<MatchResult> result,
    List<ElementTrace> elements
) {
    public TraceableMatchResult {
        Objects.requireNonNull(elements, "elements");
        elements = List.copyOf(elements);
    }
}
```

Add `matchWithTrace()` method — mirrors the existing `match()` algorithm at lines 140-196 but collects `ElementTrace` for each element:

```java
public TraceableMatchResult matchWithTrace(List<AnnotatedToken> tokens,
                                            Map<String, VariableConstraint> constraints) {
    List<ElementTrace> traces = new ArrayList<>();
    Map<String, String> fields = new LinkedHashMap<>();
    int tokenIdx = 0;
    int matched = 0;
    boolean failed = false;

    for (int i = 0; i < elements.size(); i++) {
        Element elem = elements.get(i);
        if (tokenIdx >= tokens.size()) {
            if (elem.optional()) {
                traces.add(new ElementTrace(elem.kind(), elementExpected(elem), null, false));
                continue;
            }
            traces.add(new ElementTrace(elem.kind(), elementExpected(elem), null, false));
            failed = true;
            continue;
        }

        AnnotatedToken token = tokens.get(tokenIdx);

        switch (elem.kind()) {
            case LITERAL -> {
                boolean match = token.lemma().equalsIgnoreCase(elem.lemma())
                    || token.surface().equalsIgnoreCase(elem.surface());
                traces.add(new ElementTrace(elem.kind(), elem.lemma(), token.lemma(), match));
                if (match) {
                    matched++;
                    tokenIdx++;
                } else if (!elem.optional()) {
                    failed = true;
                }
            }
            case VARIABLE -> {
                String value = resolveVariableValue(token, elem, constraints);
                boolean match = value != null;
                traces.add(new ElementTrace(elem.kind(), elem.variableName(),
                    match ? value : token.surface(), match));
                if (match) {
                    fields.put(elem.variableName(), value);
                    matched++;
                    tokenIdx++;
                } else if (!elem.optional()) {
                    failed = true;
                }
            }
            case CLAUSE -> {
                ClauseCapture capture = captureClause(tokens, tokenIdx, i, constraints, elem.variableName());
                boolean match = capture.value() != null && !capture.value().isBlank();
                traces.add(new ElementTrace(elem.kind(), elem.variableName(),
                    capture.value(), match));
                if (match) {
                    fields.put(elem.variableName(), capture.value());
                    matched++;
                }
                tokenIdx = capture.endIdx();
                if (!match && !elem.optional()) {
                    failed = true;
                }
            }
        }
    }

    if (failed || matched == 0) {
        return new TraceableMatchResult(Optional.empty(), traces);
    }
    long requiredCount = elements.stream().filter(e -> !e.optional()).count();
    if (requiredCount == 0) {
        return new TraceableMatchResult(Optional.empty(), traces);
    }
    double score = Math.min((double) matched / requiredCount, 1.0);
    if (score <= 0.0) {
        return new TraceableMatchResult(Optional.empty(), traces);
    }
    return new TraceableMatchResult(
        Optional.of(new MatchResult(fields, score)), traces);
}

private String elementExpected(Element elem) {
    return elem.variableName() != null ? elem.variableName() : elem.lemma();
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `/opt/homebrew/bin/mvn --batch-mode -pl template-registry test -Dtest=StructuralMatcherTest`
Expected: all tests PASS (new + existing)

- [ ] **Step 5: Commit**

```bash
git add template-registry/src/main/java/io/casehub/template/registry/nlp/StructuralMatcher.java template-registry/src/test/java/io/casehub/template/registry/nlp/StructuralMatcherTest.java
git commit -m "feat(#976): StructuralMatcher.matchWithTrace() with element-level diagnostics"
```

### Task 3: InMemoryTemplateRegistry.matchWithTrace() — regex tier

**Files:**
- Modify: `template-registry-api/src/main/java/io/casehub/template/registry/InMemoryTemplateRegistry.java`
- Test: `template-registry-api/src/test/java/io/casehub/template/registry/InMemoryTemplateRegistryTest.java`

**Interfaces:**
- Consumes: `MatchTraceResult`, `MatchTrace`, `CandidateTrace`, `CandidateOutcome` from Task 1
- Produces: `InMemoryTemplateRegistry.matchWithTrace(String input)`, `InMemoryTemplateRegistry.matchWithTrace(String ns, String input)`, `InMemoryTemplateRegistry.matchInNamespaceWithTrace(String ns, TemplateNamespace, String input, Snapshot)` (protected — overridden by NlpTemplateRegistry in Task 4)

- [ ] **Step 1: Write failing tests**

Add to `InMemoryTemplateRegistryTest.java`:

```java
@Test
void matchWithTraceOnMatchReportsCandidate() {
    var registry = new InMemoryTemplateRegistry();
    registry.register(reviewNamespace());
    var result = registry.matchWithTrace("protocol:review",
        "I approve this design");
    assertThat(result.result()).isInstanceOf(TemplateMatch.Matched.class);
    assertThat(result.trace().bestCandidate()).isEqualTo("protocol:review:vote");
    assertThat(result.trace().bestScore()).isEqualTo(1.0);
    assertThat(result.trace().candidates()).isNotEmpty();
    var matched = result.trace().candidates().stream()
        .filter(c -> c.outcome() == CandidateOutcome.MATCHED)
        .findFirst().orElseThrow();
    assertThat(matched.templateName()).isEqualTo("vote");
    assertThat(matched.score()).isEqualTo(1.0);
    assertThat(matched.elements()).isEmpty();
}

@Test
void matchWithTraceOnFailReportsAllCandidates() {
    var registry = new InMemoryTemplateRegistry();
    registry.register(reviewNamespace());
    var result = registry.matchWithTrace("protocol:review",
        "completely unrelated input");
    assertThat(result.result()).isInstanceOf(TemplateMatch.Unmatched.class);
    assertThat(result.trace().bestCandidate()).isNull();
    assertThat(result.trace().candidates()).hasSizeGreaterThanOrEqualTo(2);
    assertThat(result.trace().candidates()).allMatch(
        c -> c.outcome() == CandidateOutcome.REGEX_FAILED);
}

@Test
void matchWithTraceGlobalSearchesAllNamespaces() {
    var registry = new InMemoryTemplateRegistry();
    registry.register(reviewNamespace());
    var result = registry.matchWithTrace("I approve this design");
    assertThat(result.result()).isInstanceOf(TemplateMatch.Matched.class);
    assertThat(result.trace().candidates()).isNotEmpty();
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `/opt/homebrew/bin/mvn --batch-mode -pl template-registry-api test -Dtest=InMemoryTemplateRegistryTest#matchWithTrace* -Dsurefire.failIfNoSpecifiedTests=false`
Expected: compilation failure — `matchWithTrace` doesn't exist

- [ ] **Step 3: Implement matchWithTrace in InMemoryTemplateRegistry**

Add `matchInNamespaceWithTrace()` protected method (parallel to `matchInNamespace()`):

```java
protected List<CandidateTrace> matchInNamespaceWithTrace(
        String namespaceName, TemplateNamespace ns,
        String input, Snapshot snap) {
    List<CandidateTrace> candidates = new ArrayList<>();
    for (var templateEntry : ns.templates().entrySet()) {
        TemplateDefinition def = templateEntry.getValue();
        List<CompiledTemplate> compiledList =
            snap.compiled.get(namespaceName + ":" + def.name());
        if (compiledList == null) continue;

        for (int i = 0; i < compiledList.size(); i++) {
            CompiledTemplate compiled = compiledList.get(i);
            Optional<Map<String, String>> result =
                compiled.extract(input, def.variables());
            if (result.isPresent()) {
                candidates.add(new CandidateTrace(
                    namespaceName, def.name(), i, -1.0,
                    CandidateOutcome.MATCHED, List.of(), 1.0));
            } else {
                candidates.add(new CandidateTrace(
                    namespaceName, def.name(), i, -1.0,
                    CandidateOutcome.REGEX_FAILED, List.of(), 0.0));
            }
        }
    }
    return candidates;
}
```

Add `matchWithTrace(String ns, String input)`:

```java
@Override
public MatchTraceResult matchWithTrace(String namespaceName, String input) {
    Objects.requireNonNull(namespaceName, "namespaceName");
    Objects.requireNonNull(input, "input");
    Snapshot snap = snapshot.get();
    TemplateNamespace ns = snap.namespaces.get(namespaceName);
    if (ns == null) {
        throw new IllegalArgumentException(
            "Unknown namespace: " + namespaceName);
    }
    List<CandidateTrace> candidates =
        matchInNamespaceWithTrace(namespaceName, ns, input, snap);
    TemplateMatch result = matchInNamespace(namespaceName, ns, input, snap);
    return buildTraceResult(result, candidates);
}
```

Add `matchWithTrace(String input)`:

```java
@Override
public MatchTraceResult matchWithTrace(String input) {
    Objects.requireNonNull(input, "input");
    Snapshot snap = snapshot.get();
    List<CandidateTrace> allCandidates = new ArrayList<>();
    TemplateMatch matchResult = new TemplateMatch.Unmatched(input);
    for (var nsEntry : snap.namespaces.entrySet()) {
        List<CandidateTrace> nsCandidates =
            matchInNamespaceWithTrace(
                nsEntry.getKey(), nsEntry.getValue(), input, snap);
        allCandidates.addAll(nsCandidates);
        if (matchResult instanceof TemplateMatch.Unmatched) {
            TemplateMatch nsResult = matchInNamespace(
                nsEntry.getKey(), nsEntry.getValue(), input, snap);
            if (nsResult instanceof TemplateMatch.Matched) {
                matchResult = nsResult;
            }
        }
    }
    return buildTraceResult(matchResult, allCandidates);
}
```

Add private helper:

```java
private MatchTraceResult buildTraceResult(TemplateMatch result,
                                           List<CandidateTrace> candidates) {
    String bestCandidate = null;
    double bestScore = 0.0;
    for (CandidateTrace c : candidates) {
        if (c.outcome() == CandidateOutcome.MATCHED && c.score() > bestScore) {
            bestScore = c.score();
            bestCandidate = c.namespace() + ":" + c.templateName();
        }
    }
    return new MatchTraceResult(result,
        new MatchTrace(candidates, bestCandidate, bestScore));
}
```

Add imports for `ArrayList`, `CandidateTrace`, `CandidateOutcome`, `MatchTrace`, `MatchTraceResult`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `/opt/homebrew/bin/mvn --batch-mode -pl template-registry-api test -Dtest=InMemoryTemplateRegistryTest`
Expected: all tests PASS (new + existing)

- [ ] **Step 5: Commit**

```bash
git add template-registry-api/src/main/java/io/casehub/template/registry/InMemoryTemplateRegistry.java template-registry-api/src/main/java/io/casehub/template/registry/UnifiedTemplateRegistry.java template-registry-api/src/test/java/io/casehub/template/registry/InMemoryTemplateRegistryTest.java
git commit -m "feat(#976): InMemoryTemplateRegistry.matchWithTrace() — regex tier diagnostics"
```

---

## Batch 3: NlpTemplateRegistry trace and integration test

### Task 4: NlpTemplateRegistry.matchWithTrace() — NLP tier

**Files:**
- Modify: `template-registry/src/main/java/io/casehub/template/registry/nlp/NlpTemplateRegistry.java`
- Test: `template-registry/src/test/java/io/casehub/template/registry/nlp/NlpTemplateRegistryTest.java`

**Interfaces:**
- Consumes: `StructuralMatcher.matchWithTrace()` from Task 2, `CandidateTrace`, `CandidateOutcome`, `ElementTrace`, `MatchTrace`, `MatchTraceResult` from Task 1, `LemmatisedKeywordFilter.affinity()` from existing code
- Produces: `NlpTemplateRegistry.matchWithTrace(String input)`, `NlpTemplateRegistry.matchWithTrace(String ns, String input)` (overrides SPI)

- [ ] **Step 1: Write failing tests**

Add to `NlpTemplateRegistryTest.java`:

```java
@Test
void matchWithTraceReportsKeywordFiltering() {
    var result = registry.matchWithTrace("protocol:review",
        "The weather is nice");
    assertThat(result.result()).isInstanceOf(TemplateMatch.Unmatched.class);
    var filtered = result.trace().candidates().stream()
        .filter(c -> c.outcome() == CandidateOutcome.KEYWORD_FILTERED)
        .toList();
    assertThat(filtered).isNotEmpty();
    assertThat(filtered.get(0).keywordAffinity()).isGreaterThanOrEqualTo(0.0);
    assertThat(filtered.get(0).keywordAffinity()).isLessThan(0.3);
}

@Test
void matchWithTraceReportsNlpElements() {
    var result = registry.matchWithTrace("protocol:review",
        "I approved this design");
    assertThat(result.result()).isInstanceOf(TemplateMatch.Matched.class);
    var nlpCandidate = result.trace().candidates().stream()
        .filter(c -> c.outcome() == CandidateOutcome.MATCHED
            && !c.elements().isEmpty())
        .findFirst();
    assertThat(nlpCandidate).isPresent();
    assertThat(nlpCandidate.get().elements()).isNotEmpty();
}

@Test
void matchWithTraceReportsRegexMatchBeforeNlp() {
    var result = registry.matchWithTrace("protocol:review",
        "I approve this design");
    assertThat(result.result()).isInstanceOf(TemplateMatch.Matched.class);
    var matched = result.trace().candidates().stream()
        .filter(c -> c.outcome() == CandidateOutcome.MATCHED)
        .findFirst().orElseThrow();
    assertThat(matched.score()).isEqualTo(1.0);
    assertThat(matched.elements()).isEmpty();
}

@Test
void matchWithTraceGlobalBestScore() {
    var result = registry.matchWithTrace("I approved this design");
    assertThat(result.result()).isInstanceOf(TemplateMatch.Matched.class);
    assertThat(result.trace().bestCandidate()).isNotNull();
    assertThat(result.trace().bestScore()).isGreaterThan(0.0);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `/opt/homebrew/bin/mvn --batch-mode -pl template-registry test -Dtest=NlpTemplateRegistryTest#matchWithTrace* -Dsurefire.failIfNoSpecifiedTests=false`
Expected: compilation failure

- [ ] **Step 3: Implement NlpTemplateRegistry trace methods**

Override `matchInNamespaceWithTrace()`:

```java
@Override
protected List<CandidateTrace> matchInNamespaceWithTrace(
        String namespaceName, TemplateNamespace ns,
        String input, Snapshot snap) {
    List<CandidateTrace> candidates = new ArrayList<>(
        super.matchInNamespaceWithTrace(namespaceName, ns, input, snap));

    List<AnnotatedToken> inputTokens = tokenizer.tokenize(input);

    for (var templateEntry : ns.templates().entrySet()) {
        TemplateDefinition def = templateEntry.getValue();
        String key = namespaceName + ":" + def.name();
        NlpTemplateCompiler.CompiledNlpTemplate compiled = nlpCompiled.get(key);
        if (compiled == null) continue;

        for (int i = 0; i < compiled.matchers().size(); i++) {
            Set<String> keywords = compiled.keywordSets().get(i);
            double affinity = LemmatisedKeywordFilter.affinity(
                keywords, inputTokens);
            if (affinity < affinityThreshold && !keywords.isEmpty()) {
                candidates.add(new CandidateTrace(
                    namespaceName, def.name(), i, affinity,
                    CandidateOutcome.KEYWORD_FILTERED, List.of(), 0.0));
                continue;
            }

            StructuralMatcher matcher = compiled.matchers().get(i);
            var traceResult = matcher.matchWithTrace(inputTokens, def.variables());
            List<ElementTrace> elements = traceResult.elements();

            if (traceResult.result().isPresent()
                    && traceResult.result().get().score() > scoreThreshold) {
                double score = traceResult.result().get().score();
                candidates.add(new CandidateTrace(
                    namespaceName, def.name(), i, affinity,
                    CandidateOutcome.MATCHED, elements, score));
            } else if (traceResult.result().isPresent()) {
                candidates.add(new CandidateTrace(
                    namespaceName, def.name(), i, affinity,
                    CandidateOutcome.BELOW_THRESHOLD, elements,
                    traceResult.result().get().score()));
            } else {
                candidates.add(new CandidateTrace(
                    namespaceName, def.name(), i, affinity,
                    CandidateOutcome.STRUCTURAL_FAILED, elements, 0.0));
            }
        }
    }
    return candidates;
}
```

Override `matchWithTrace(String input)` for best-score cross-namespace:

```java
@Override
public MatchTraceResult matchWithTrace(String input) {
    Objects.requireNonNull(input, "input");
    List<CandidateTrace> allCandidates = new ArrayList<>();
    TemplateMatch.Matched bestMatch = null;

    for (String ns : namespaces()) {
        var nsResult = matchWithTrace(ns, input);
        allCandidates.addAll(nsResult.trace().candidates());
        if (nsResult.result() instanceof TemplateMatch.Matched matched) {
            if (matched.score() == 1.0) {
                return new MatchTraceResult(matched,
                    new MatchTrace(allCandidates,
                        matched.namespace() + ":" + matched.templateName(),
                        matched.score()));
            }
            if (bestMatch == null || matched.score() > bestMatch.score()) {
                bestMatch = matched;
            }
        }
    }

    TemplateMatch result = bestMatch != null
        ? bestMatch : new TemplateMatch.Unmatched(input);
    String bestCandidate = bestMatch != null
        ? bestMatch.namespace() + ":" + bestMatch.templateName() : null;
    double bestScore = bestMatch != null ? bestMatch.score() : 0.0;
    return new MatchTraceResult(result,
        new MatchTrace(allCandidates, bestCandidate, bestScore));
}
```

Add imports for `ArrayList`, `CandidateTrace`, `CandidateOutcome`, `ElementTrace`, `MatchTrace`, `MatchTraceResult`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `/opt/homebrew/bin/mvn --batch-mode -pl template-registry test -Dtest=NlpTemplateRegistryTest`
Expected: all tests PASS (new + existing)

- [ ] **Step 5: Commit**

```bash
git add template-registry/src/main/java/io/casehub/template/registry/nlp/NlpTemplateRegistry.java template-registry/src/test/java/io/casehub/template/registry/nlp/NlpTemplateRegistryTest.java
git commit -m "feat(#976): NlpTemplateRegistry.matchWithTrace() — full NLP pipeline diagnostics"
```

### Task 5: Integration test — trace explains a failed match

**Files:**
- Test: `template-registry/src/test/java/io/casehub/template/registry/nlp/TemplateRegistryIntegrationTest.java` (add test)

**Interfaces:**
- Consumes: all trace types from Tasks 1-4, `NlpTemplateRegistry`, `OpenNlpTokenizer`

- [ ] **Step 1: Write the integration test**

Add to `TemplateRegistryIntegrationTest.java`:

```java
@Test
void traceExplainsWhyInputDidNotMatch() {
    var registry = new NlpTemplateRegistry(new OpenNlpTokenizer());
    var vote = TemplateDefinition.builder("vote")
        .pattern("I ${decision} this design")
        .variable("decision", VariableConstraint.enumOf("approve", "reject"))
        .build();
    var templates = new LinkedHashMap<String, TemplateDefinition>();
    templates.put("vote", vote);
    registry.register(new TemplateNamespace("protocol:review", templates));

    var result = registry.matchWithTrace("protocol:review",
        "the design looks good to me");

    assertThat(result.result()).isInstanceOf(TemplateMatch.Unmatched.class);

    var trace = result.trace();
    assertThat(trace.bestCandidate()).isNull();

    var regexCandidate = trace.candidates().stream()
        .filter(c -> c.outcome() == CandidateOutcome.REGEX_FAILED)
        .findFirst();
    assertThat(regexCandidate).isPresent()
        .hasValueSatisfying(c -> {
            assertThat(c.templateName()).isEqualTo("vote");
            assertThat(c.keywordAffinity()).isEqualTo(-1.0);
            assertThat(c.elements()).isEmpty();
        });

    var nlpCandidates = trace.candidates().stream()
        .filter(c -> c.outcome() != CandidateOutcome.REGEX_FAILED
            && c.outcome() != CandidateOutcome.KEYWORD_FILTERED)
        .toList();
    if (!nlpCandidates.isEmpty()) {
        var nlpCandidate = nlpCandidates.get(0);
        assertThat(nlpCandidate.keywordAffinity()).isGreaterThanOrEqualTo(0.0);
        assertThat(nlpCandidate.elements()).isNotEmpty();
        var failedElement = nlpCandidate.elements().stream()
            .filter(e -> !e.matched())
            .findFirst();
        assertThat(failedElement).isPresent();
    }
}
```

- [ ] **Step 2: Run the integration test**

Run: `/opt/homebrew/bin/mvn --batch-mode -pl template-registry test -Dtest=TemplateRegistryIntegrationTest#traceExplainsWhyInputDidNotMatch`
Expected: PASS

- [ ] **Step 3: Run full test suite for both modules**

Run: `/opt/homebrew/bin/mvn --batch-mode -pl template-registry-api,template-registry -am test`
Expected: all tests PASS

- [ ] **Step 4: Commit**

```bash
git add template-registry/src/test/java/io/casehub/template/registry/nlp/TemplateRegistryIntegrationTest.java
git commit -m "test(#976): integration test — trace explains failed match"
```

## References

- [2026-11-25-match-diagnostics-trace-design.md] — design spec this plan implements
- `template-registry-api/src/main/java/io/casehub/template/registry/UnifiedTemplateRegistry.java` — SPI gaining matchWithTrace()
- `template-registry-api/src/main/java/io/casehub/template/registry/InMemoryTemplateRegistry.java:74-96` — matchInNamespace() regex walk
- `template-registry/src/main/java/io/casehub/template/registry/nlp/NlpTemplateRegistry.java:81-122` — matchInNamespace() NLP walk
- `template-registry/src/main/java/io/casehub/template/registry/nlp/StructuralMatcher.java:140-196` — per-element match loop
- `template-registry/src/main/java/io/casehub/template/registry/nlp/LemmatisedKeywordFilter.java:63-71` — affinity scoring
- `template-registry-api/src/main/java/io/casehub/template/registry/CompiledTemplate.java:29-73` — regex extraction
- `template-registry-api/src/main/java/io/casehub/template/registry/TemplateMatch.java` — existing sealed result type
- GitHub #976 — focal issue
- GitHub #959 — parent epic
