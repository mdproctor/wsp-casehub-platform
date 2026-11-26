# Match Step Type-Safe Variable Flow — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #970 — match playbook step with type-safe variable flow
**Issue group:** #970

**Goal:** Extend the `match` playbook step with a template mode that connects the unified template registry to playbook execution, with compile-time type safety and metadata propagation.

**Architecture:** The existing `match` step gains a template mode detected by YAML structure (`namespace:` present → template mode). The Walker parses template-mode config into a `TemplateMatchSpec`, and `StructuralStepEvaluator` dispatches to per-template handler blocks with scoped variable binding. `VariableConstraint` in yaml-core gains metadata support for grammar hints.

**Tech Stack:** Java 21, yaml-core (zero-dep), playbook-compiler, yaml-step-runtime, template-registry-api

## Global Constraints

- `yaml-core` must remain zero-dependency and J2CL-safe — no new imports
- `platform-api/` must remain zero-dependency
- All new types are immutable records
- Thread safety via immutable snapshots — no `synchronized` (virtual thread pinning)
- Every commit references issue #970

---

## Batch 1: Foundation — VariableConstraint Metadata + TemplateMatchSpec

### Task 1: VariableConstraint metadata extension

**Files:**
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/resolver/VariableConstraint.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/resolver/MetadataKeys.java`
- Create: `yaml-core/src/test/java/io/casehub/yaml/core/resolver/VariableConstraintMetadataTest.java`

**Interfaces:**
- Produces: `VariableConstraint.metadata()` → `Map<String, String>`, `VariableConstraint.withMetadata(Map<String, String>)` → `VariableConstraint`, `MetadataKeys.PERSON`, `MetadataKeys.NUMBER`, `MetadataKeys.PRONOUNS`

- [ ] **Step 1: Write failing tests for metadata on StringConstraint**

```java
package io.casehub.yaml.core.resolver;

import org.junit.jupiter.api.Test;
import java.util.Map;
import static org.junit.jupiter.api.Assertions.*;

class VariableConstraintMetadataTest {

    @Test
    void stringConstraint_defaultMetadata_isEmpty() {
        var c = VariableConstraint.string();
        assertEquals(Map.of(), c.metadata());
    }

    @Test
    void stringConstraint_withMetadata_returnsMetadata() {
        var meta = Map.of(MetadataKeys.PERSON, "3rd", MetadataKeys.PRONOUNS, "they/them");
        var c = VariableConstraint.string().withMetadata(meta);
        assertEquals("3rd", c.metadata().get(MetadataKeys.PERSON));
        assertEquals("they/them", c.metadata().get(MetadataKeys.PRONOUNS));
        assertTrue(c.required());
    }

    @Test
    void stringConstraint_withMetadata_preservesRequired() {
        var c = VariableConstraint.string().optional().withMetadata(Map.of("k", "v"));
        assertFalse(c.required());
        assertEquals("v", c.metadata().get("k"));
    }

    @Test
    void stringConstraint_optional_preservesMetadata() {
        var c = VariableConstraint.string().withMetadata(Map.of("k", "v")).optional();
        assertFalse(c.required());
        assertEquals("v", c.metadata().get("k"));
    }

    @Test
    void stringConstraint_metadataIsImmutable() {
        var c = VariableConstraint.string().withMetadata(Map.of("k", "v"));
        assertThrows(UnsupportedOperationException.class, () -> c.metadata().put("x", "y"));
    }

    @Test
    void enumConstraint_defaultMetadata_isEmpty() {
        var c = VariableConstraint.enumOf("a", "b");
        assertEquals(Map.of(), c.metadata());
    }

    @Test
    void enumConstraint_withMetadata_returnsMetadata() {
        var c = VariableConstraint.enumOf("a", "b")
            .withMetadata(Map.of(MetadataKeys.NUMBER, "singular"));
        assertEquals("singular", c.metadata().get(MetadataKeys.NUMBER));
    }

    @Test
    void enumConstraint_optional_preservesMetadata() {
        var c = VariableConstraint.enumOf("a", "b")
            .withMetadata(Map.of("k", "v")).optional();
        assertFalse(c.required());
        assertEquals("v", c.metadata().get("k"));
    }

    @Test
    void enumConstraint_metadataIsImmutable() {
        var c = VariableConstraint.enumOf("a", "b").withMetadata(Map.of("k", "v"));
        assertThrows(UnsupportedOperationException.class, () -> c.metadata().put("x", "y"));
    }

    @Test
    void nullMetadata_defaultsToEmpty() {
        var c = new VariableConstraint.StringConstraint(true, null);
        assertEquals(Map.of(), c.metadata());
    }

    @Test
    void metadataKeys_constantsAreDefined() {
        assertEquals("person", MetadataKeys.PERSON);
        assertEquals("number", MetadataKeys.NUMBER);
        assertEquals("pronouns", MetadataKeys.PRONOUNS);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl yaml-core test -Dtest=VariableConstraintMetadataTest --batch-mode -q`
Expected: compilation errors — `metadata()`, `withMetadata()`, `MetadataKeys` don't exist

- [ ] **Step 3: Implement VariableConstraint metadata extension**

Modify `yaml-core/src/main/java/io/casehub/yaml/core/resolver/VariableConstraint.java`:

Add `metadata()` and `withMetadata()` to the sealed interface. Add `metadata` field to both `StringConstraint` and `EnumConstraint` records with backward-compatible two-arg constructors. See spec §Type Changes — VariableConstraint for the full implementation.

Create `yaml-core/src/main/java/io/casehub/yaml/core/resolver/MetadataKeys.java`:

```java
package io.casehub.yaml.core.resolver;

public final class MetadataKeys {
    public static final String PERSON = "person";
    public static final String NUMBER = "number";
    public static final String PRONOUNS = "pronouns";
    private MetadataKeys() {}
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn -pl yaml-core test -Dtest=VariableConstraintMetadataTest --batch-mode -q`
Expected: all 12 tests PASS

- [ ] **Step 5: Run full yaml-core test suite to verify backward compatibility**

Run: `mvn -pl yaml-core test --batch-mode -q`
Expected: all existing tests still PASS (backward-compatible constructor changes)

- [ ] **Step 6: Commit**

```bash
git add yaml-core/src/main/java/io/casehub/yaml/core/resolver/VariableConstraint.java
git add yaml-core/src/main/java/io/casehub/yaml/core/resolver/MetadataKeys.java
git add yaml-core/src/test/java/io/casehub/yaml/core/resolver/VariableConstraintMetadataTest.java
git commit -m "feat(#970): add metadata support to VariableConstraint + MetadataKeys constants"
```

### Task 2: TemplateMatchSpec record + MatchStep extension

**Files:**
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/TemplateMatchSpec.java`
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/ResolvedStep.java` (MatchStep record)
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/StepKeywords.java` (RESERVED_CAPTURE_NAMES)
- Create: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/catalog/TemplateMatchSpecTest.java`

**Interfaces:**
- Consumes: `ResolvedStep` (existing sealed interface), `ResolvedMatchCase` (existing)
- Produces: `TemplateMatchSpec(namespace, inputExpression, handlers, unmatchedHandler)`, `MatchStep.valueMode(...)`, `MatchStep.templateMode(...)`, `MatchStep.isTemplateMode()`

- [ ] **Step 1: Write failing tests for TemplateMatchSpec and MatchStep factories**

```java
package io.casehub.yaml.step.catalog;

import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.Map;
import static org.junit.jupiter.api.Assertions.*;

class TemplateMatchSpecTest {

    @Test
    void templateMatchSpec_construction() {
        var handler = List.<ResolvedStep>of(
            new ResolvedStep.PluginStep("s1", "action", Map.of(), Map.of()));
        var spec = new TemplateMatchSpec(
            "protocol:review", "${response.text}",
            Map.of("vote", handler), List.of());
        assertEquals("protocol:review", spec.namespace());
        assertEquals("${response.text}", spec.inputExpression());
        assertEquals(1, spec.handlers().size());
        assertTrue(spec.unmatchedHandler().isEmpty());
    }

    @Test
    void templateMatchSpec_nullNamespace_throws() {
        assertThrows(NullPointerException.class, () ->
            new TemplateMatchSpec(null, "${x}", Map.of("a", List.of()), List.of()));
    }

    @Test
    void templateMatchSpec_nullUnmatched_defaultsToEmpty() {
        var spec = new TemplateMatchSpec("ns", "${x}", Map.of("a", List.of()), null);
        assertTrue(spec.unmatchedHandler().isEmpty());
    }

    @Test
    void matchStep_valueMode_factory() {
        var step = ResolvedStep.MatchStep.valueMode(
            "m1", "${expr}", List.of(), Map.of());
        assertFalse(step.isTemplateMode());
        assertEquals("${expr}", step.scrutinee());
        assertNull(step.templateSpec());
    }

    @Test
    void matchStep_templateMode_factory() {
        var spec = new TemplateMatchSpec("ns", "${x}", Map.of("a", List.of()), List.of());
        var step = ResolvedStep.MatchStep.templateMode("m1", spec, Map.of());
        assertTrue(step.isTemplateMode());
        assertNull(step.scrutinee());
        assertNotNull(step.templateSpec());
    }

    @Test
    void matchStep_valueMode_nullScrutinee_throws() {
        assertThrows(NullPointerException.class, () ->
            ResolvedStep.MatchStep.valueMode("m1", null, List.of(), Map.of()));
    }

    @Test
    void matchStep_templateMode_nullSpec_throws() {
        assertThrows(NullPointerException.class, () ->
            ResolvedStep.MatchStep.templateMode("m1", null, Map.of()));
    }

    @Test
    void reservedCaptureNames_includes_tmatch() {
        assertTrue(StepKeywords.RESERVED_CAPTURE_NAMES.contains("_tmatch"));
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl yaml-step-runtime test -Dtest=TemplateMatchSpecTest --batch-mode -q`
Expected: compilation errors — `TemplateMatchSpec`, `valueMode()`, `templateMode()`, `isTemplateMode()` don't exist

- [ ] **Step 3: Create TemplateMatchSpec**

Create `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/TemplateMatchSpec.java`:

```java
package io.casehub.yaml.step.catalog;

import java.util.List;
import java.util.Map;
import java.util.Objects;

public record TemplateMatchSpec(
    String namespace,
    String inputExpression,
    Map<String, List<ResolvedStep>> handlers,
    List<ResolvedStep> unmatchedHandler
) {
    public TemplateMatchSpec {
        Objects.requireNonNull(namespace, "namespace");
        Objects.requireNonNull(inputExpression, "inputExpression");
        handlers = Map.copyOf(handlers);
        unmatchedHandler = unmatchedHandler != null ? List.copyOf(unmatchedHandler) : List.of();
    }
}
```

- [ ] **Step 4: Extend MatchStep with static factories and isTemplateMode()**

Modify `ResolvedStep.MatchStep` in `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/ResolvedStep.java`:

Add `TemplateMatchSpec templateSpec` field. Add `isTemplateMode()` method. Add `valueMode()` and `templateMode()` static factories. Keep existing constructors working (they become value-mode constructors — `templateSpec` defaults to null). See spec §ResolvedStep.MatchStep Extension for full code.

- [ ] **Step 5: Add `_tmatch` to RESERVED_CAPTURE_NAMES**

Modify `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/StepKeywords.java`:

Change line 26-27 from:
```java
public static final Set<String> RESERVED_CAPTURE_NAMES = Set.of(
        "result", "error", "each", "var", "params", "module", "events");
```
to:
```java
public static final Set<String> RESERVED_CAPTURE_NAMES = Set.of(
        "result", "error", "each", "var", "params", "module", "events", "_tmatch");
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mvn -pl yaml-step-runtime test -Dtest=TemplateMatchSpecTest --batch-mode -q`
Expected: all 8 tests PASS

- [ ] **Step 7: Run full yaml-step-runtime test suite to verify backward compatibility**

Run: `mvn -pl yaml-step-runtime test --batch-mode -q`
Expected: all existing tests still PASS. If any MatchStep construction sites broke due to the new field, update them to use `MatchStep.valueMode(...)`.

- [ ] **Step 8: Commit**

```bash
git add yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/TemplateMatchSpec.java
git add yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/ResolvedStep.java
git add yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/StepKeywords.java
git add yaml-step-runtime/src/test/java/io/casehub/yaml/step/catalog/TemplateMatchSpecTest.java
git commit -m "feat(#970): add TemplateMatchSpec record and MatchStep factory methods"
```

## Batch 2: Walker — Template Mode Parsing

### Task 3: Walker template-mode detection and construction

**Files:**
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/Walker.java`
- Modify: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/catalog/WalkerTest.java`

**Interfaces:**
- Consumes: `TemplateMatchSpec(namespace, inputExpression, handlers, unmatchedHandler)`, `MatchStep.templateMode(name, spec, decorators)`, `MatchStep.valueMode(name, scrutinee, cases, decorators)`
- Produces: Walker correctly resolves template-mode match steps from YAML

- [ ] **Step 1: Write failing tests for Walker template-mode parsing**

Add to `WalkerTest.java`:

```java
@Test
void templateMode_match_resolves() {
    var step = Map.<String, Object>of(
        "match", Map.of(
            "input", "${response.text}",
            "namespace", "protocol:review",
            "on", Map.of(
                "vote", List.of(Map.of("log", "voted")),
                "escalate", List.of(Map.of("log", "escalated"))
            )
        )
    );
    var resolved = Walker.resolve(List.of(step));
    assertEquals(1, resolved.size());
    assertInstanceOf(ResolvedStep.MatchStep.class, resolved.get(0));
    var match = (ResolvedStep.MatchStep) resolved.get(0);
    assertTrue(match.isTemplateMode());
    assertEquals("protocol:review", match.templateSpec().namespace());
    assertEquals("${response.text}", match.templateSpec().inputExpression());
    assertEquals(2, match.templateSpec().handlers().size());
    assertTrue(match.templateSpec().unmatchedHandler().isEmpty());
}

@Test
void templateMode_match_withUnmatched_resolves() {
    var step = Map.<String, Object>of(
        "match", Map.of(
            "input", "${text}",
            "namespace", "ns",
            "on", Map.of("t1", List.of(Map.of("log", "matched"))),
            "unmatched", List.of(Map.of("log", "unmatched"))
        )
    );
    var resolved = Walker.resolve(List.of(step));
    var match = (ResolvedStep.MatchStep) resolved.get(0);
    assertTrue(match.isTemplateMode());
    assertEquals(1, match.templateSpec().unmatchedHandler().size());
}

@Test
void templateMode_match_missingNamespace_treatedAsValueMode_throws() {
    var step = Map.<String, Object>of(
        "match", Map.of("input", "${x}", "on", Map.of("t", List.of()))
    );
    assertThrows(IllegalArgumentException.class, () -> Walker.resolve(List.of(step)));
}

@Test
void templateMode_match_missingInput_throws() {
    var step = Map.<String, Object>of(
        "match", Map.of("namespace", "ns", "on", Map.of("t", List.of()))
    );
    assertThrows(IllegalArgumentException.class, () -> Walker.resolve(List.of(step)));
}

@Test
void templateMode_match_missingOn_throws() {
    var step = Map.<String, Object>of(
        "match", Map.of("input", "${x}", "namespace", "ns")
    );
    assertThrows(IllegalArgumentException.class, () -> Walker.resolve(List.of(step)));
}

@Test
void templateMode_match_emptyOn_throws() {
    var step = Map.<String, Object>of(
        "match", Map.of("input", "${x}", "namespace", "ns", "on", Map.of())
    );
    assertThrows(IllegalArgumentException.class, () -> Walker.resolve(List.of(step)));
}

@Test
void valueMode_match_stillWorks() {
    var step = Map.of(
        "match", "${status}",
        "cases", List.of(
            Map.of("pattern", "active", "steps", List.of(Map.of("log", "active")))
        )
    );
    var resolved = Walker.resolve(List.of(step));
    var match = (ResolvedStep.MatchStep) resolved.get(0);
    assertFalse(match.isTemplateMode());
    assertEquals("${status}", match.scrutinee());
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl yaml-step-runtime test -Dtest=WalkerTest#templateMode_match_resolves+templateMode_match_withUnmatched_resolves+templateMode_match_missingInput_throws+templateMode_match_missingOn_throws+templateMode_match_emptyOn_throws+valueMode_match_stillWorks --batch-mode -q`
Expected: FAIL — Walker throws on template-mode match (requires `cases`)

- [ ] **Step 3: Implement Walker template-mode detection and construction**

Modify `Walker.java`:

**3a.** After the existing `if (hasMatch && companions.containsKey("cases"))` block (~line 450), add template-mode detection:

```java
if (hasMatch && matchValue instanceof Map<?,?> matchMap
        && matchMap.containsKey("namespace")) {
    if (structuralType != null) {
        throw new IllegalArgumentException(
            path + " → Step " + index + ": ambiguous — structural keyword '"
            + structuralType + "' and 'match' (template mode) both present");
    }
    structuralType = "match-template";
}
```

**3b.** Update the `match requires cases` guard (~line 482) to allow template mode:

```java
if (hasMatch && !"match".equals(structuralType)
        && !"match-template".equals(structuralType)) {
    throw new IllegalArgumentException(
        path + " → Step " + index
        + ": 'match' requires either 'cases' or a template config "
        + "with 'namespace' + 'on'");
}
```

**3c.** After the existing `if ("match".equals(structuralType))` block (~line 517), add template-mode construction. See spec §Walker Changes — Template-mode construction for full code. The key logic: extract `input`, `namespace`, `on`, `unmatched` from `matchValue` Map; validate required keys; resolve handler step lists recursively; construct `TemplateMatchSpec`; return `MatchStep.templateMode(...)`.

**3d.** Update existing value-mode MatchStep construction (~line 519) to use factory:

```java
if ("match".equals(structuralType)) {
    var cases = (List<Map<String, Object>>) companions.get("cases");
    return ResolvedStep.MatchStep.valueMode(
            stepName,
            (String) matchValue,
            resolveMatchCases(cases, registry, index, depth, stepPath, seenNames, annotations, stepKey, collector, playbookFile, locations),
            decorators);
}
```

**3e.** Update `withAnnotations()` and `withDecorators()` methods that copy-on-modify MatchStep to dispatch by mode (see spec §Walker Changes point 3).

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn -pl yaml-step-runtime test -Dtest=WalkerTest --batch-mode -q`
Expected: all tests PASS (new template-mode tests + existing value-mode tests)

- [ ] **Step 5: Commit**

```bash
git add yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/Walker.java
git add yaml-step-runtime/src/test/java/io/casehub/yaml/step/catalog/WalkerTest.java
git commit -m "feat(#970): Walker template-mode detection and construction for match step"
```

## Batch 3: Runtime — Template Dispatch in StructuralStepEvaluator

### Task 4: StructuralStepEvaluator template match dispatch

**Files:**
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StructuralStepEvaluator.java`
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/runner/PlaybookRunnerCore.java`
- Modify: `yaml-step-runtime/pom.xml` (add template-registry-api dependency)
- Create: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/TemplateMatchEvaluatorTest.java`

**Interfaces:**
- Consumes: `TemplateMatchSpec`, `MatchStep.isTemplateMode()`, `UnifiedTemplateRegistry.match(namespace, input)`, `TemplateMatch.Matched`, `TemplateMatch.NearMiss`, `TemplateMatch.Unmatched`, `VariableResolver.withObjectScope()`
- Produces: Template-mode dispatch with scoped `${templateName.variable}` and `${_tmatch.*}` context

- [ ] **Step 1: Add template-registry-api dependency to yaml-step-runtime pom.xml**

Add to `yaml-step-runtime/pom.xml` `<dependencies>`:

```xml
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-template-registry-api</artifactId>
</dependency>
```

(Version managed by parent BOM)

- [ ] **Step 2: Write failing tests for template match dispatch**

Create `yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/TemplateMatchEvaluatorTest.java`:

```java
package io.casehub.yaml.step.eval;

import io.casehub.template.registry.InMemoryTemplateRegistry;
import io.casehub.template.registry.TemplateDefinition;
import io.casehub.template.registry.TemplateNamespace;
import io.casehub.yaml.core.condition.ConditionEvaluator;
import io.casehub.yaml.core.resolver.VariableConstraint;
import io.casehub.yaml.core.resolver.VariableResolver;
import io.casehub.yaml.plugin.api.Result;
import io.casehub.yaml.step.catalog.ResolvedStep;
import io.casehub.yaml.step.catalog.TemplateMatchSpec;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

class TemplateMatchEvaluatorTest {

    private InMemoryTemplateRegistry registry;
    private StructuralStepEvaluator evaluator;

    @BeforeEach
    void setUp() {
        registry = new InMemoryTemplateRegistry();
        registry.register(new TemplateNamespace("protocol:review",
            Map.of(
                "vote", TemplateDefinition.builder("vote")
                    .pattern("I ${decision} this ${subject}")
                    .variable("decision", VariableConstraint.enumOf("approve", "reject"))
                    .variable("subject", VariableConstraint.string())
                    .build(),
                "escalate", TemplateDefinition.builder("escalate")
                    .pattern("escalate to ${target} because ${reason}")
                    .variable("target", VariableConstraint.string())
                    .variable("reason", VariableConstraint.string())
                    .build()
            )));
        evaluator = new StructuralStepEvaluator(
            ConditionEvaluator.alwaysTrue(), null, registry);
    }

    @Test
    void templateMatch_dispatchesToCorrectHandler() {
        var voteHandler = List.<ResolvedStep>of(
            new ResolvedStep.PluginStep("s1", "assert", Map.of(
                "that", "${vote.decision}", "equals", "approve"), Map.of()));
        var spec = new TemplateMatchSpec("protocol:review", "${input}",
            Map.of("vote", voteHandler), List.of());
        var step = ResolvedStep.MatchStep.templateMode("m1", spec, Map.of());

        var resolver = VariableResolver.forParams(Map.of(), Map.of("input", "I approve this architecture"), java.util.Set.of());
        var result = evaluator.evaluate(step, resolver, (s, r, run) -> Result.of(Map.of()));
        assertTrue(result.isSuccess());
    }

    @Test
    void templateMatch_unmatchedHandler_executesOnNoMatch() {
        var unmatchedHandler = List.<ResolvedStep>of(
            new ResolvedStep.PluginStep("s1", "log", Map.of("message", "no match"), Map.of()));
        var spec = new TemplateMatchSpec("protocol:review", "${input}",
            Map.of("vote", List.of()), unmatchedHandler);
        var step = ResolvedStep.MatchStep.templateMode("m1", spec, Map.of());

        var resolver = VariableResolver.forParams(Map.of(), Map.of("input", "hello world"), java.util.Set.of());
        var result = evaluator.evaluate(step, resolver, (s, r, run) -> Result.of(Map.of()));
        assertTrue(result.isSuccess());
    }

    @Test
    void templateMatch_noHandlerForTemplate_fallsToUnmatched() {
        var unmatchedHandler = List.<ResolvedStep>of(
            new ResolvedStep.PluginStep("s1", "log", Map.of(), Map.of()));
        var spec = new TemplateMatchSpec("protocol:review", "${input}",
            Map.of("escalate", List.of()), unmatchedHandler);
        var step = ResolvedStep.MatchStep.templateMode("m1", spec, Map.of());

        var resolver = VariableResolver.forParams(Map.of(), Map.of("input", "I approve this design"), java.util.Set.of());
        var result = evaluator.evaluate(step, resolver, (s, r, run) -> Result.of(Map.of()));
        assertTrue(result.isSuccess());
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mvn -pl yaml-step-runtime test -Dtest=TemplateMatchEvaluatorTest --batch-mode -q`
Expected: FAIL — `StructuralStepEvaluator` has no 3-arg constructor with registry, `evaluateMatch` doesn't handle template mode

- [ ] **Step 4: Implement template dispatch in StructuralStepEvaluator**

Modify `StructuralStepEvaluator.java`:

**4a.** Add `templateRegistry` field and update constructors:
- Add `private final UnifiedTemplateRegistry templateRegistry;` field
- Add 3-arg public constructor: `(ConditionEvaluator, ExecutionScope, UnifiedTemplateRegistry)`
- Update private constructor to accept and store registry (default to `new NoOpUnifiedTemplateRegistry()` when null)
- Thread `templateRegistry` through `withListener()`, `withCaptureCollector()`, `withInjections()` copy-on-modify methods

**4b.** Add `evaluateTemplateMatch()` method (see spec §Runtime Changes for full code):
- Resolve input expression
- Call `registry.match(namespace, input)`
- Dispatch `Matched` → handler block with `withObjectScope(templateName, ...)` and `_tmatch` context
- Dispatch `NearMiss` → unmatched handler with diagnostic logging and near-miss context
- Dispatch `Unmatched` → unmatched handler

**4c.** Update `evaluateMatch()` to branch on `isTemplateMode()`:
```java
if (match.templateSpec() != null) {
    return evaluateTemplateMatch(match.templateSpec(), ctx, runner);
}
```

**4d.** Update `preRegisterLatches()` to recurse into MatchStep (both modes) — see spec §preRegisterLatches.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn -pl yaml-step-runtime test -Dtest=TemplateMatchEvaluatorTest --batch-mode -q`
Expected: all 3 tests PASS

- [ ] **Step 6: Run full yaml-step-runtime test suite**

Run: `mvn -pl yaml-step-runtime test --batch-mode -q`
Expected: all tests PASS

- [ ] **Step 7: Wire registry into PlaybookRunnerCore**

Modify `PlaybookRunnerCore.java`:
- Add `UnifiedTemplateRegistry` constructor parameter (with backward-compatible constructors defaulting to null)
- Pass registry to `StructuralStepEvaluator` construction (~line 297 in `executeSteps()`)

- [ ] **Step 8: Commit**

```bash
git add yaml-step-runtime/pom.xml
git add yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StructuralStepEvaluator.java
git add yaml-step-runtime/src/main/java/io/casehub/yaml/step/runner/PlaybookRunnerCore.java
git add yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/TemplateMatchEvaluatorTest.java
git commit -m "feat(#970): template match dispatch in StructuralStepEvaluator with scoped variables"
```

## Batch 4: Compiler — Template Mode Validation

### Task 5: TemplateSchemaResolver + MatchCompiler template mode

**Files:**
- Create: `playbook-compiler/src/main/java/io/casehub/platform/compiler/TemplateSchemaResolver.java`
- Modify: `playbook-compiler/src/main/java/io/casehub/platform/compiler/PlaybookCompiler.java`
- Modify: `playbook-compiler/src/main/java/io/casehub/platform/compiler/CompilationContext.java`
- Modify: `playbook-compiler/src/main/java/io/casehub/platform/compiler/MatchCompiler.java`
- Modify: `playbook-compiler/pom.xml` (add template-registry-api dependency)
- Create: `playbook-compiler/src/test/java/io/casehub/platform/compiler/TemplateMatchCompilerTest.java`

**Interfaces:**
- Consumes: `TemplateSchema(namespace, templateName, patterns, variables, structuralSummaries)`, `VariableConstraint.required()`, `VariableConstraint.metadata()`
- Produces: `TemplateSchemaResolver` SPI, compile-time diagnostics for template variable references

- [ ] **Step 1: Add template-registry-api dependency to playbook-compiler pom.xml**

Add to `playbook-compiler/pom.xml` `<dependencies>`:

```xml
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-template-registry-api</artifactId>
</dependency>
```

- [ ] **Step 2: Write failing tests for template-mode compilation**

Create `playbook-compiler/src/test/java/io/casehub/platform/compiler/TemplateMatchCompilerTest.java`:

```java
package io.casehub.platform.compiler;

import io.casehub.template.registry.TemplateSchema;
import io.casehub.yaml.core.resolver.VariableConstraint;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

class TemplateMatchCompilerTest {

    private TemplateSchemaResolver resolver(String ns, List<TemplateSchema> schemas) {
        return namespace -> namespace.equals(ns) ? schemas : List.of();
    }

    @Test
    void templateMode_compilesSuccessfully() {
        var schemas = List.of(
            new TemplateSchema("ns", "vote", List.of("I ${decision} this"),
                Map.of("decision", VariableConstraint.enumOf("approve", "reject")),
                List.of()));
        var compiler = new PlaybookCompiler(null, resolver("ns", schemas));
        var result = compiler.compile("test", Map.of(
            "steps", List.of(Map.of(
                "match", Map.of(
                    "input", "${text}",
                    "namespace", "ns",
                    "on", Map.of("vote", List.of(Map.of("log", "voted")))
                )
            ))
        ));
        assertInstanceOf(CompilationOutcome.Success.class, result);
    }

    @Test
    void templateMode_unknownNamespace_producesError() {
        var compiler = new PlaybookCompiler(null, TemplateSchemaResolver.noOp());
        var result = compiler.compile("test", Map.of(
            "steps", List.of(Map.of(
                "match", Map.of(
                    "input", "${text}",
                    "namespace", "unknown",
                    "on", Map.of("t1", List.of(Map.of("log", "x")))
                )
            ))
        ));
        assertInstanceOf(CompilationOutcome.Failure.class, result);
        var failure = (CompilationOutcome.Failure) result;
        assertTrue(failure.diagnostics().stream().anyMatch(d ->
            d.message().contains("unknown") && d.severity() == CompilationDiagnostic.Severity.ERROR));
    }

    @Test
    void templateMode_unknownHandler_producesError() {
        var schemas = List.of(
            new TemplateSchema("ns", "vote", List.of("pattern"),
                Map.of("decision", VariableConstraint.string()), List.of()));
        var compiler = new PlaybookCompiler(null, resolver("ns", schemas));
        var result = compiler.compile("test", Map.of(
            "steps", List.of(Map.of(
                "match", Map.of(
                    "input", "${text}",
                    "namespace", "ns",
                    "on", Map.of("nonexistent", List.of(Map.of("log", "x")))
                )
            ))
        ));
        assertInstanceOf(CompilationOutcome.Failure.class, result);
    }

    @Test
    void templateMode_noOp_resolver_default() {
        var compiler = new PlaybookCompiler();
        assertNotNull(compiler.schemaResolver());
        assertTrue(compiler.schemaResolver().resolve("any").isEmpty());
    }

    @Test
    void valueMode_match_unaffected() {
        var compiler = new PlaybookCompiler();
        var result = compiler.compile("test", Map.of(
            "steps", List.of(Map.of(
                "match", "status",
                "cases", List.of(Map.of("pattern", "active"))
            ))
        ));
        assertInstanceOf(CompilationOutcome.Success.class, result);
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mvn -pl playbook-compiler test -Dtest=TemplateMatchCompilerTest --batch-mode -q`
Expected: FAIL — `TemplateSchemaResolver` doesn't exist, `PlaybookCompiler` doesn't accept it

- [ ] **Step 4: Create TemplateSchemaResolver SPI**

Create `playbook-compiler/src/main/java/io/casehub/platform/compiler/TemplateSchemaResolver.java`:

```java
package io.casehub.platform.compiler;

import io.casehub.template.registry.TemplateSchema;
import java.util.List;

@FunctionalInterface
public interface TemplateSchemaResolver {
    List<TemplateSchema> resolve(String namespace);

    static TemplateSchemaResolver noOp() {
        return namespace -> List.of();
    }
}
```

- [ ] **Step 5: Update PlaybookCompiler constructors**

Modify `PlaybookCompiler.java`:
- Add `private final TemplateSchemaResolver schemaResolver;` field
- Restructure constructors: canonical 3-arg constructor does all registrations; 0-arg and 1-arg delegate to it
- Add package-private `schemaResolver()` accessor

- [ ] **Step 6: Add compiler() accessor to CompilationContext**

Modify `CompilationContext.java` — add:
```java
PlaybookCompiler compiler() { return compiler; }
```

- [ ] **Step 7: Implement MatchCompiler template mode**

Modify `MatchCompiler.java`:
- Rename existing `compile()` body to `compileValueMode()`
- Add mode detection: `stepValue instanceof Map config && config.containsKey("namespace")`
- Implement `compileTemplateMode()`: resolve namespace, validate handler keys, validate variable references, compile to SetTask with metadata
- Implement `validateTemplateReferences()` for compile-time variable checking

- [ ] **Step 8: Run tests to verify they pass**

Run: `mvn -pl playbook-compiler test -Dtest=TemplateMatchCompilerTest --batch-mode -q`
Expected: all 5 tests PASS

- [ ] **Step 9: Run full playbook-compiler test suite**

Run: `mvn -pl playbook-compiler test --batch-mode -q`
Expected: all tests PASS

- [ ] **Step 10: Commit**

```bash
git add playbook-compiler/pom.xml
git add playbook-compiler/src/main/java/io/casehub/platform/compiler/TemplateSchemaResolver.java
git add playbook-compiler/src/main/java/io/casehub/platform/compiler/PlaybookCompiler.java
git add playbook-compiler/src/main/java/io/casehub/platform/compiler/CompilationContext.java
git add playbook-compiler/src/main/java/io/casehub/platform/compiler/MatchCompiler.java
git add playbook-compiler/src/test/java/io/casehub/platform/compiler/TemplateMatchCompilerTest.java
git commit -m "feat(#970): TemplateSchemaResolver SPI and MatchCompiler template mode with validation"
```

## Batch 5: Integration — End-to-End Playbook Test

### Task 6: End-to-end template match playbook test

**Files:**
- Create: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/runner/TemplateMatchPlaybookTest.java`
- Create: `yaml-step-runtime/src/test/resources/playbooks/template-match.yaml`

**Interfaces:**
- Consumes: All prior tasks — full Walker → StructuralStepEvaluator pipeline with template registry

- [ ] **Step 1: Create test playbook YAML**

Create `yaml-step-runtime/src/test/resources/playbooks/template-match.yaml`:

```yaml
name: template-match-test
steps:
  - match:
      input: ${text}
      namespace: protocol:review
      on:
        vote:
          - log: "Vote: ${vote.decision} on ${vote.subject}"
        escalate:
          - log: "Escalate to ${escalate.target}"
      unmatched:
        - log: "No match for input"
```

- [ ] **Step 2: Write end-to-end test**

Create `yaml-step-runtime/src/test/java/io/casehub/yaml/step/runner/TemplateMatchPlaybookTest.java`:

```java
package io.casehub.yaml.step.runner;

import io.casehub.template.registry.InMemoryTemplateRegistry;
import io.casehub.template.registry.TemplateDefinition;
import io.casehub.template.registry.TemplateNamespace;
import io.casehub.yaml.core.resolver.VariableConstraint;
import io.casehub.yaml.plugin.api.MapServiceRegistry;
import io.casehub.yaml.step.catalog.StepActionRegistry;
import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

class TemplateMatchPlaybookTest {

    @Test
    void endToEnd_voteMatch() {
        var registry = new InMemoryTemplateRegistry();
        registry.register(new TemplateNamespace("protocol:review",
            Map.of(
                "vote", TemplateDefinition.builder("vote")
                    .pattern("I ${decision} this ${subject}")
                    .variable("decision", VariableConstraint.enumOf("approve", "reject"))
                    .variable("subject", VariableConstraint.string())
                    .build(),
                "escalate", TemplateDefinition.builder("escalate")
                    .pattern("escalate to ${target} because ${reason}")
                    .variable("target", VariableConstraint.string())
                    .variable("reason", VariableConstraint.string())
                    .build()
            )));

        var pluginRegistry = StepActionRegistry.builtIn();
        var serviceRegistry = new MapServiceRegistry();
        var runner = new PlaybookRunnerCore(
            pluginRegistry, serviceRegistry, null, null, null, null, java.util.List.of(), null, registry);

        var config = PlaybookRunConfig.builder()
            .vars(Map.of("text", "I approve this architecture"))
            .build();

        var result = runner.run(
            """
            name: template-match-e2e
            steps:
              - match:
                  input: ${text}
                  namespace: protocol:review
                  on:
                    vote:
                      - log: "Vote received"
                    escalate:
                      - log: "Escalation received"
                  unmatched:
                    - log: "No match"
            """, config);

        assertTrue(result.success(), "Playbook should succeed: " + result.errorMessage());
    }

    @Test
    void endToEnd_unmatched() {
        var registry = new InMemoryTemplateRegistry();
        registry.register(new TemplateNamespace("protocol:review",
            Map.of("vote", TemplateDefinition.builder("vote")
                .pattern("I ${decision} this ${subject}")
                .variable("decision", VariableConstraint.string())
                .variable("subject", VariableConstraint.string())
                .build())));

        var pluginRegistry = StepActionRegistry.builtIn();
        var serviceRegistry = new MapServiceRegistry();
        var runner = new PlaybookRunnerCore(
            pluginRegistry, serviceRegistry, null, null, null, null, java.util.List.of(), null, registry);

        var config = PlaybookRunConfig.builder()
            .vars(Map.of("text", "hello world"))
            .build();

        var result = runner.run(
            """
            name: unmatched-e2e
            steps:
              - match:
                  input: ${text}
                  namespace: protocol:review
                  on:
                    vote:
                      - log: "matched"
                  unmatched:
                    - log: "no match"
            """, config);

        assertTrue(result.success(), "Playbook should succeed: " + result.errorMessage());
    }
}
```

- [ ] **Step 3: Run end-to-end tests**

Run: `mvn -pl yaml-step-runtime test -Dtest=TemplateMatchPlaybookTest --batch-mode -q`
Expected: both tests PASS

- [ ] **Step 4: Run full build to verify cross-module integration**

Run: `mvn --batch-mode install -DskipTests=false`
Expected: BUILD SUCCESS across all modules

- [ ] **Step 5: Commit**

```bash
git add yaml-step-runtime/src/test/java/io/casehub/yaml/step/runner/TemplateMatchPlaybookTest.java
git add yaml-step-runtime/src/test/resources/playbooks/template-match.yaml
git commit -m "feat(#970): end-to-end template match playbook tests"
```

## References

- `specs/issue-970-match-step-type-safe-vars/2026-11-26-match-step-type-safe-vars-design.md` — design spec this plan implements
- `yaml-core/src/main/java/io/casehub/yaml/core/resolver/VariableConstraint.java` — metadata extension target
- `playbook-compiler/src/main/java/io/casehub/platform/compiler/MatchCompiler.java` — existing value-mode compiler
- `playbook-compiler/src/main/java/io/casehub/platform/compiler/PlaybookCompiler.java:46-81` — constructor chain
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/Walker.java:450-524` — match resolution
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StructuralStepEvaluator.java:325-350` — evaluateMatch()
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/ResolvedStep.java:104-120` — MatchStep record
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/StepKeywords.java:26-27` — RESERVED_CAPTURE_NAMES
- `template-registry-api/src/main/java/io/casehub/template/registry/UnifiedTemplateRegistry.java` — matching SPI
- `template-registry-api/src/main/java/io/casehub/template/registry/TemplateSchema.java` — schema type
- GitHub #970 — focal issue
- GitHub #959 — unified template registry
- GitHub #969 — YAML corpus format
- GitHub #943 — parent epic
