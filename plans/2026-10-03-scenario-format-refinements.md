# Scenario Format Refinements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** casehub-pages#390 — Scenario format refinements
**Issue group:** casehub-pages#390, casehubio/platform#502

**Goal:** Delete both Java scenario parsers (ScenarioParser,
HierarchicalParser) and replace them with a single ScenarioEnvelopeParser
that reads compact-format YAML. Rewrite the compiler, orchestrator, and
executor to use CompactStep instead of HierarchicalStep+ScenarioCommand.
Update the TS Walker, parser, and scenario handler to match.

**Architecture:** The Java side becomes a format-agnostic pass-through —
envelope parser reads YAML structure, produces CompactStep records (action
name + flat params + decorator map), and hands them to the compiler for
forEach/when expansion. The orchestrator serializes CompactStep to a flat
JSON wire format (action + params, no commands[] array). Step semantics
(including AriaTarget reconstruction) are resolved at execution time on
the executor side.

**Tech Stack:** Java 21, Quarkus, Jackson YAML, yaml-core
(ForEachExpander, VariableResolver, Truthiness), TypeScript, Walker
(yaml-core TS)

**Repo:** All changes in `casehub-pages` repo at
`/Users/mdproctor/claude/casehub/slots/210/pages`

## Global Constraints

- All Java source under `backend/scenario/src/main/java/io/casehub/pages/scenario/`
- Runtime module: `backend/scenario-runtime/src/main/java/io/casehub/pages/scenario/runtime/`
- Client module: `backend/scenario-client/src/main/java/io/casehub/pages/scenario/client/`
- TS sources: `packages/pages-aria/src/scenario/` and `packages/pages-aria/src/server/`
- Walker: `packages/yaml-core/src/step/walker.ts`
- Test YAML: `backend/scenario/src/test/resources/scenarios/`
- Production YAML: search `META-INF/scenarios/` in backend modules
- Tutorials: `tutorials/*/tutorial.yaml`
- CompactStep boundary principle: typed fields for polymorphic parsed
  types (forEach, trigger, temporal); decorator map for simple
  pass-through values
- Speed ≤ 0 is the sentinel for "no pacing" — executors guard with
  `if (speed <= 0 || speed >= 1000) return` before computing delay
- Envelope parser applies defaults: `target: "browser"` when omitted,
  scenario-level `actor:` propagated to steps
- Step name derivation: `step:` → `slugify(label:)` → `{action}-{index}`
- Step name uniqueness validated at parse time
- `@ScenarioAction` annotation and `ActionRegistry` are unchanged
- Platform yaml-core types (ForEachExpander, ForEachDirective,
  VariableResolver, Truthiness, CsvDataSource) are unchanged

---

## Batch 1: Foundation — New Types + Parser

### Task 1: CompactStep and ScenarioEnvelope Records

**Files:**
- Create: `backend/scenario/src/main/java/io/casehub/pages/scenario/CompactStep.java`
- Create: `backend/scenario/src/main/java/io/casehub/pages/scenario/ScenarioEnvelope.java`
- Modify: `backend/scenario/src/main/java/io/casehub/pages/scenario/CompiledScenario.java`
- Test: `backend/scenario/src/test/java/io/casehub/pages/scenario/CompactStepTest.java`

**Interfaces:**
- Produces: `CompactStep(String action, Map<String,Object> params, ForEachDirective forEach, Trigger trigger, TemporalSpec temporal, Map<String,Object> decorators)` with `decorator(String key)` accessor
- Produces: `ScenarioEnvelope(String scenario, String description, double speed, String actor, String onError, List<ParamDescriptor> params, ScriptMeta meta, Map<String,Object> data, Map<String,Object> iterations, String slides, SimulationSpec simulation, List<ScenarioChapter> chapters, List<ScenarioSection> sections, List<CompactStep> steps)` with `allSteps()` method

- [ ] **Step 1: Write CompactStep record with decorator accessor test**

```java
// CompactStepTest.java
@Test
void decoratorReturnsValue() {
    var step = new CompactStep("fill", Map.of("role", "textbox"),
        null, null, null, Map.of("label", "Fill name", "target", "browser"));
    assertEquals("Fill name", step.decorator("label"));
    assertEquals("browser", step.decorator("target"));
    assertNull(step.decorator("nonexistent"));
}

@Test
void actionAndParamsAreAccessible() {
    var step = new CompactStep("click", Map.of("name", "Submit"),
        null, null, null, Map.of());
    assertEquals("click", step.action());
    assertEquals("Submit", step.params().get("name"));
}
```

- [ ] **Step 2: Run test — verify it fails (CompactStep not defined)**

Run: `mvn -pl backend/scenario test -Dtest=CompactStepTest -f pom.xml`
Expected: compilation failure

- [ ] **Step 3: Implement CompactStep record**

```java
package io.casehub.pages.scenario;

import io.casehub.yaml.core.step.ForEachDirective;
import java.util.Map;

public record CompactStep(
    String action,
    Map<String, Object> params,
    ForEachDirective forEach,
    Trigger trigger,
    TemporalSpec temporal,
    Map<String, Object> decorators
) {
    @SuppressWarnings("unchecked")
    public <T> T decorator(String key) {
        return (T) decorators.get(key);
    }
}
```

- [ ] **Step 4: Implement ScenarioEnvelope record**

```java
package io.casehub.pages.scenario;

import java.util.List;
import java.util.Map;
import java.util.stream.Stream;

public record ScenarioEnvelope(
    String scenario,
    String description,
    double speed,
    String actor,
    String onError,
    List<ParamDescriptor> params,
    ScriptMeta meta,
    Map<String, Object> data,
    Map<String, Object> iterations,
    String slides,
    SimulationSpec simulation,
    List<ScenarioChapter> chapters,
    List<ScenarioSection> sections,
    List<CompactStep> steps
) {
    public List<CompactStep> allSteps() {
        if (steps != null && !steps.isEmpty()) return steps;
        Stream<CompactStep> fromSections = (sections != null ? sections : List.<ScenarioSection>of())
            .stream().flatMap(s -> s.steps().stream());
        Stream<CompactStep> fromChapters = (chapters != null ? chapters : List.<ScenarioChapter>of())
            .stream().flatMap(ch -> ch.sections().stream())
            .flatMap(s -> s.steps().stream());
        return Stream.concat(fromSections, fromChapters).toList();
    }
}
```

- [ ] **Step 5: Update CompiledScenario to use CompactStep**

Change `CompiledScenario` from `List<HierarchicalStep>` to
`List<CompactStep>`, remove `callRefs` field.

- [ ] **Step 6: Update ScenarioChapter and ScenarioSection generics**

Both records hold step lists — update from
`List<HierarchicalStep>` to `List<CompactStep>` in their type
parameters (if parameterized) or field types.

- [ ] **Step 7: Run tests — verify CompactStepTest passes**

Run: `mvn -pl backend/scenario test -Dtest=CompactStepTest -f pom.xml`
Expected: PASS

- [ ] **Step 8: Commit**

```
feat(#390): add CompactStep and ScenarioEnvelope records
```

### Task 2: ScenarioEnvelopeParser

**Files:**
- Create: `backend/scenario/src/main/java/io/casehub/pages/scenario/ScenarioEnvelopeParser.java`
- Test: `backend/scenario/src/test/java/io/casehub/pages/scenario/ScenarioEnvelopeParserTest.java`

**Interfaces:**
- Consumes: `CompactStep`, `ScenarioEnvelope`, `ForEachDirective`, `Trigger`, `TemporalSpec`
- Produces: `ScenarioEnvelopeParser.parse(String yaml) → ScenarioEnvelope`

- [ ] **Step 1: Write test for flat-format parsing**

```java
@Test
void parsesFlatFormatWithSteps() {
    var yaml = """
        scenario: demo
        steps:
          - navigate: /intake
          - fill:
              role: textbox
              name: Subject
              value: hello
            label: Fill subject
          - click:
              role: button
              name: Submit
        """;
    var envelope = ScenarioEnvelopeParser.parse(yaml);
    assertEquals("demo", envelope.scenario());
    assertEquals(3, envelope.allSteps().size());

    var fill = envelope.allSteps().get(1);
    assertEquals("fill", fill.action());
    assertEquals("textbox", fill.params().get("role"));
    assertEquals("Fill subject", fill.decorator("label"));
    assertEquals("browser", fill.decorator("target")); // default
}
```

- [ ] **Step 2: Write test for sectioned format**

```java
@Test
void parsesSectionedFormat() {
    var yaml = """
        scenario: tutorial
        actor: system
        speed: 1.0
        sections:
          - label: Section One
            content: Walk through the form
            steps:
              - fill:
                  role: textbox
                  name: Name
                  value: Alice
        """;
    var envelope = ScenarioEnvelopeParser.parse(yaml);
    assertEquals("tutorial", envelope.scenario());
    assertEquals("system", envelope.actor());
    assertEquals(1.0, envelope.speed());
    assertEquals(1, envelope.sections().size());
    assertEquals("Section One", envelope.sections().get(0).label());

    var step = envelope.allSteps().get(0);
    assertEquals("fill", step.action());
    assertEquals("system", step.decorator("actor")); // inherited
    assertEquals("browser", step.decorator("target")); // default
}
```

- [ ] **Step 3: Write test for speed sentinel and step name derivation**

```java
@Test
void omittedSpeedUsesNoDelaySentinel() {
    var yaml = """
        scenario: demo
        steps:
          - navigate: /home
        """;
    var envelope = ScenarioEnvelopeParser.parse(yaml);
    assertTrue(envelope.speed() <= 0); // sentinel
}

@Test
void stepNameDerivation() {
    var yaml = """
        scenario: demo
        steps:
          - step: explicit-name
            navigate: /home
          - fill:
              role: textbox
              name: Subject
              value: hello
            label: Fill the subject field
          - click:
              role: button
              name: Submit
        """;
    var envelope = ScenarioEnvelopeParser.parse(yaml);
    assertEquals("explicit-name", envelope.allSteps().get(0).decorator("step"));
    assertEquals("fill-the-subject-field",
        ScenarioEnvelopeParser.deriveStepName(envelope.allSteps().get(1), 1));
    assertEquals("click-2",
        ScenarioEnvelopeParser.deriveStepName(envelope.allSteps().get(2), 2));
}

@Test
void stepNameCollisionFails() {
    var yaml = """
        scenario: demo
        steps:
          - navigate: /home
            step: same-name
          - click:
              role: button
              name: Submit
            step: same-name
        """;
    assertThrows(IllegalArgumentException.class,
        () -> ScenarioEnvelopeParser.parse(yaml));
}
```

- [ ] **Step 4: Write test for forEach, trigger, temporal typed fields**

```java
@Test
void parsesForEachAsTypedField() {
    var yaml = """
        scenario: demo
        steps:
          - fill:
              role: textbox
              name: Name
              value: "${each.member.name}"
            forEach:
              as: member
              in: members
        """;
    var step = ScenarioEnvelopeParser.parse(yaml).allSteps().get(0);
    assertNotNull(step.forEach());
    assertNull(step.decorators().get("forEach")); // typed, not in decorator map
}
```

- [ ] **Step 5: Write test for envelope fields (params, data, simulation, onError)**

```java
@Test
void parsesEnvelopeFields() {
    var yaml = """
        scenario: demo
        on-error: stop
        params:
          - name: teamName
            type: string
            required: true
        data:
          members:
            inline: |
              name:string
              Alice
        simulation:
          strategies:
            correlator: random
          corpus:
            - classpath:corpus/tickets.yaml
          capture:
            - case.created
        steps:
          - navigate: /home
        """;
    var envelope = ScenarioEnvelopeParser.parse(yaml);
    assertEquals("stop", envelope.onError());
    assertEquals(1, envelope.params().size());
    assertNotNull(envelope.data());
    assertNotNull(envelope.simulation());
    assertEquals("random", envelope.simulation().strategies().get("correlator"));
}
```

- [ ] **Step 6: Run tests — verify they fail**

Run: `mvn -pl backend/scenario test -Dtest=ScenarioEnvelopeParserTest -f pom.xml`
Expected: compilation failure

- [ ] **Step 7: Implement ScenarioEnvelopeParser**

Static `parse(String yaml)` method:
1. Parse YAML with Jackson YAMLFactory (use `YamlMappers.yamlMapper()`)
2. Read envelope fields: scenario, description, speed (default -1.0
   sentinel), actor, on-error, params, meta, data, iterations,
   slides, simulation
3. Read structure: chapters → sections → steps
4. For each step map entry: identify the action key (single non-decorator
   key per §Canonical Decorator Keys), extract params, extract decorators
5. Parse typed fields: `forEach` → `ForEachDirective`, `trigger` →
   `Trigger`, `temporal` → `TemporalSpec`
6. Apply defaults: `target: "browser"` if absent, propagate
   scenario-level `actor:` to steps missing `actor:`
7. Derive step names and validate uniqueness
8. Return `ScenarioEnvelope`

Static `deriveStepName(CompactStep step, int index)` method:
1. If `step.decorator("step")` non-null → return it
2. If `step.decorator("label")` non-null → return `slugify(label)`
3. Otherwise → return `step.action() + "-" + index`

Static `slugify(String label)` method (from ScenarioStepAdapter):
`label.toLowerCase().replaceAll("[^a-z0-9]+", "-").replaceAll("^-|-$", "")`

The set of canonical decorator keys (for action-key discrimination):
```java
private static final Set<String> DECORATOR_KEYS = Set.of(
    "label", "step", "target", "actor", "delay", "when",
    "forEach", "content", "trigger", "speed", "await", "mode"
);
```

- [ ] **Step 8: Run tests — verify all pass**

Run: `mvn -pl backend/scenario test -Dtest=ScenarioEnvelopeParserTest -f pom.xml`
Expected: PASS

- [ ] **Step 9: Commit**

```
feat(#390): add ScenarioEnvelopeParser with compact-format parsing
```

---

## Batch 2: Compiler Rewrite

### Task 3: CompactStepAdapter and ScenarioCompiler Rewrite

**Files:**
- Create: `backend/scenario/src/main/java/io/casehub/pages/scenario/CompactStepAdapter.java`
- Modify: `backend/scenario/src/main/java/io/casehub/pages/scenario/ScenarioCompiler.java`
- Modify: `backend/scenario/src/test/java/io/casehub/pages/scenario/ScenarioCompilerTest.java`
- Delete: `backend/scenario/src/main/java/io/casehub/pages/scenario/ScenarioStepAdapter.java`

**Interfaces:**
- Consumes: `CompactStep`, `ScenarioEnvelopeParser`, `ForEachExpander`, `ForEachDirective`, `VariableResolver`, `Truthiness`, `CsvDataSource`
- Produces: `CompactStepAdapter implements ForEachAdapter<CompactStep>`, `ScenarioCompiler.compile(yaml, callerParams, templateLoader) → CompiledScenario`

- [ ] **Step 1: Write CompactStepAdapter test**

```java
@Test
void stampCreatesNewStepWithResolvedParams() {
    var step = new CompactStep("fill",
        Map.of("role", "textbox", "value", "${each.member.name}"),
        ForEachDirective.groupRef("member", "members"),
        null, null, Map.of("label", "Create ${each.member.name}"));
    var adapter = new CompactStepAdapter();
    var resolver = VariableResolver.builder()
        .addSource("each", Map.of("member", Map.of("name", "Alice")))
        .build();
    var stamped = adapter.stamp(step, "member-0", resolver);
    assertEquals("fill", stamped.action());
    assertEquals("Alice", stamped.params().get("value"));
    assertEquals("Create Alice", stamped.decorator("label"));
}
```

- [ ] **Step 2: Run test — verify it fails**

- [ ] **Step 3: Implement CompactStepAdapter**

```java
package io.casehub.pages.scenario;

import io.casehub.yaml.core.ForEachExpander.ForEachAdapter;
import io.casehub.yaml.core.step.ForEachDirective;
import io.casehub.yaml.core.VariableResolver;
import java.util.LinkedHashMap;
import java.util.Map;

public class CompactStepAdapter implements ForEachAdapter<CompactStep> {

    @Override
    public ForEachDirective getForEach(CompactStep step) {
        return step.forEach();
    }

    @Override
    public String getCondition(CompactStep step) {
        return step.decorator("when");
    }

    @Override
    public CompactStep stamp(CompactStep step, String stampedId,
                             VariableResolver resolver) {
        var resolvedParams = new LinkedHashMap<String, Object>();
        for (var entry : step.params().entrySet()) {
            resolvedParams.put(entry.getKey(),
                resolveValue(entry.getValue(), resolver));
        }
        var resolvedDecorators = new LinkedHashMap<String, Object>();
        for (var entry : step.decorators().entrySet()) {
            resolvedDecorators.put(entry.getKey(),
                resolveValue(entry.getValue(), resolver));
        }
        resolvedDecorators.put("step", stampedId);
        return new CompactStep(step.action(), resolvedParams,
            null, step.trigger(), step.temporal(), resolvedDecorators);
    }

    private Object resolveValue(Object value, VariableResolver resolver) {
        if (value instanceof String s) {
            return resolver.resolve(s);
        }
        return value;
    }

    public static String slugify(String label) {
        return label.toLowerCase()
            .replaceAll("[^a-z0-9]+", "-")
            .replaceAll("^-|-$", "");
    }
}
```

- [ ] **Step 4: Rewrite ScenarioCompiler**

Replace the `compile()` method:
1. Call `ScenarioEnvelopeParser.parse(yaml)` instead of
   `HierarchicalParser.parse(yaml)`
2. Validate params via `ParameterValidator`
3. Build `CsvDataSource` from envelope `data:`
4. Build iteration groups from envelope `iterations:`
5. Call `ForEachExpander.expand()` with `CompactStepAdapter`
6. Evaluate `when:` conditions via `Truthiness`
7. Return `CompiledScenario(expandedSteps)`
8. Delete `inlineCalls()` and `validateCallGraph()` methods

- [ ] **Step 5: Rewrite ScenarioCompilerTest**

Update tests to use compact-format YAML (action-name-as-key). Test:
- Basic compilation (flat format → CompactStep list)
- ForEach expansion with CSV data
- When-conditional filtering
- Parameter validation
- Include expansion via IncludeExpander (pre-parse)

- [ ] **Step 6: Run tests — verify all pass**

Run: `mvn -pl backend/scenario test -Dtest=ScenarioCompilerTest -f pom.xml`

- [ ] **Step 7: Delete old adapter**

Use `ide_refactor_safe_delete` on `ScenarioStepAdapter.java`

- [ ] **Step 8: Commit**

```
feat(#390): rewrite ScenarioCompiler with CompactStepAdapter
```

---

## Batch 3: Orchestrator + Executor Rewrite

### Task 4: ScenarioOrchestrator Type Migration + Wire Protocol

**Files:**
- Modify: `backend/scenario-runtime/src/main/java/io/casehub/pages/scenario/runtime/SequencePartitioner.java`
- Modify: `backend/scenario-runtime/src/main/java/io/casehub/pages/scenario/runtime/ScenarioOrchestrator.java`
- Modify: `backend/scenario-runtime/src/test/java/.../ScenarioOrchestratorTest.java`
- Modify: `backend/scenario-runtime/src/test/java/.../SequencePartitionerTest.java`

**Interfaces:**
- Consumes: `CompactStep`, `ScenarioEnvelope`, `ScenarioEnvelopeParser`
- Produces: New wire format JSON: `{name, label, actor, action, params, await?, mode?}`

- [ ] **Step 1: Update SequencePartitioner**

Change `StepSequence` record from `List<HierarchicalStep>` to
`List<CompactStep>`. Update `step.target()` → `step.decorator("target")`.

- [ ] **Step 2: Write orchestrator wire serialization test**

```java
@Test
void serializesCompactStepToFlatWireFormat() {
    var step = new CompactStep("fill",
        Map.of("role", "textbox", "name", "Subject", "value", "hello"),
        null, null, null,
        Map.of("target", "browser", "label", "Fill subject",
               "step", "fill-subject", "actor", "system"));
    var json = orchestrator.serializeStep(step);
    assertEquals("fill", json.get("action").asText());
    assertEquals("textbox", json.get("params").get("role").asText());
    assertEquals("fill-subject", json.get("name").asText());
    assertEquals("Fill subject", json.get("label").asText());
    assertEquals("system", json.get("actor").asText());
    assertFalse(json.has("commands")); // no commands[] array
}
```

- [ ] **Step 3: Rewrite ScenarioOrchestrator**

Systematic type-change pass (29 reference sites):
1. `start()`: `HierarchicalParser.parse()` → `ScenarioEnvelopeParser.parse()`
2. `allSteps`: `List<HierarchicalStep>` → `List<CompactStep>`
3. `serializeSteps()`: rewrite from commands[] to flat action+params
4. `step.name()/label()` → `step.decorator("step")/decorator("label")`
   or use `deriveStepName()`
5. `step.commands().get(0).action()` → `step.action()`
6. `step.content()` → `step.decorator("content")` wrapped as
   `NarrativeContent.Inline`
7. `step.target()` → `step.decorator("target")`
8. `step.temporal()` → `step.temporal()` (unchanged typed field)
9. `step.trigger()` → `step.trigger()` (unchanged typed field)
10. Add `AtomicBoolean callbackFired` guard on `onStepResult()`
    completion check: `callbackFired.compareAndSet(false, true)`
    before `fireCallback()`

- [ ] **Step 4: Update orchestrator tests for CompactStep types**

- [ ] **Step 5: Run all runtime tests**

Run: `mvn -pl backend/scenario-runtime test -f pom.xml`
Expected: PASS

- [ ] **Step 6: Commit**

```
feat(#390): rewrite orchestrator wire protocol to flat action+params
```

### Task 5: ScenarioExecutorClient Rewrite

**Files:**
- Modify: `backend/scenario-client/src/main/java/io/casehub/pages/scenario/client/ScenarioExecutorClient.java`
- Modify: `backend/scenario-client/src/test/java/.../ScenarioExecutorClientTest.java`

**Interfaces:**
- Consumes: New wire format from orchestrator, `ActionRegistry`, `ActionContext`
- Produces: `@ScenarioAction` handler invocations from flat params

- [ ] **Step 1: Write test for single-action dispatch**

```java
@Test
void dispatchesSingleActionFromFlatWireFormat() {
    var stepJson = mapper.createObjectNode()
        .put("name", "fill-subject")
        .put("action", "fill")
        .put("actor", "system");
    stepJson.putObject("params")
        .put("role", "textbox")
        .put("name", "Subject")
        .put("value", "hello");

    executor.executeStep(stepJson);

    verify(actionRegistry).invoke("fill", any(ActionContext.class));
}
```

- [ ] **Step 2: Write test for stop control**

```java
@Test
void handleControlStopClearsQueueAndSendsFailures() {
    // Enqueue two steps, then stop before execution
    executor.enqueue(stepJson("step-1", "fill"));
    executor.enqueue(stepJson("step-2", "click"));
    executor.handleControl("stop", null);
    assertTrue(executor.isStepQueueEmpty());
    verify(resultCallback, times(2)).accept(argThat(
        result -> !result.get("success").asBoolean()));
}
```

- [ ] **Step 2b: Write test for mutation rejection with await+match**

```java
@Test
void rejectsAwaitMatchOnMutationAction() {
    var stepJson = mapper.createObjectNode()
        .put("name", "create-case")
        .put("action", "rest");
    stepJson.putObject("params")
        .put("method", "POST")
        .put("url", "/api/cases");
    stepJson.putObject("await")
        .put("timeout", 5000)
        .put("interval", 500)
        .putObject("match").put("status", "created");

    assertThrows(IllegalArgumentException.class,
        () -> executor.executeStep(stepJson),
        "poll-retry rejected on mutation");
}

@Test
void allowsAwaitStatusOnMutation() {
    var stepJson = mapper.createObjectNode()
        .put("name", "create-case")
        .put("action", "rest");
    stepJson.putObject("params")
        .put("method", "POST")
        .put("url", "/api/cases");
    stepJson.putObject("await").put("status", 201);

    // Should NOT throw — response validation is safe on mutations
    assertDoesNotThrow(() -> executor.executeStep(stepJson));
}
```

- [ ] **Step 3: Write test for speed guard**

```java
@Test
void sleepForSpeedSkipsWhenSpeedIsZeroOrNegative() {
    // speed <= 0 → no delay
    executor.sleepForSpeed(0);   // should return immediately
    executor.sleepForSpeed(-1);  // should return immediately
}
```

- [ ] **Step 4: Rewrite ScenarioExecutorClient**

1. `executeStep()`: read `stepNode.get("action")` + `stepNode.get("params")`
   instead of iterating `stepNode.get("commands")`
2. Build `ActionContext` from params map: `ActionContext.of(actor, paramsMap, awaitMatch)`
3. `await`: read from `stepNode.get("await")` (step-level)
4. `mode`: read from `stepNode.path("mode")` (step-level)
5. `handleControl()`: add `case "stop"` — clear step queue, abort
   in-progress, send failure results for uncompleted steps
6. `sleepForSpeed()`: add guard `if (speed <= 0 || speed >= 1000) return`

- [ ] **Step 5: Run all client tests**

Run: `mvn -pl backend/scenario-client test -f pom.xml`
Expected: PASS

- [ ] **Step 6: Commit**

```
feat(#390): rewrite ScenarioExecutorClient for flat wire format
```

---

## Batch 4: TS Changes

### Task 6: Walker DECORATOR_KEYS + parser.ts Updates

**Files:**
- Modify: `packages/yaml-core/src/step/walker.ts`
- Modify: `packages/pages-aria/src/scenario/parser.ts`
- Modify: `packages/pages-aria/src/scenario/types.ts`
- Test: existing Walker tests + parser tests

**Interfaces:**
- Produces: Walker recognizes `label`, `target`, `actor`, `when`, `speed`, `content`, `await`, `mode` as decorators
- Produces: `parser.ts` WALKER_KNOWN_KEYS updated, `sec['label']` instead of `sec['title']`
- Produces: `TutorialSection.label` (renamed from `title`)

- [ ] **Step 1: Write Walker test for new decorator keys**

```typescript
test('new scenario decorator keys are carried through', () => {
  const steps = Walker.resolve([{
    fill: { role: 'textbox', name: 'Subject', value: 'hello' },
    label: 'Fill subject',
    target: 'browser',
    actor: 'system',
    speed: 0.5,
    content: 'Narrative text',
    await: { match: { status: 200 }, timeout: 5000 },
    mode: 'SINGLE',
    when: '${condition}'
  }], catalog);
  expect(steps[0].decorators.label).toBe('Fill subject');
  expect(steps[0].decorators.target).toBe('browser');
  expect(steps[0].decorators.actor).toBe('system');
  expect(steps[0].decorators.speed).toBe(0.5);
  expect(steps[0].decorators.content).toBe('Narrative text');
  expect(steps[0].decorators.await).toEqual({ match: { status: 200 }, timeout: 5000 });
  expect(steps[0].decorators.mode).toBe('SINGLE');
  expect(steps[0].decorators.when).toBe('${condition}');
});
```

- [ ] **Step 2: Add keys to Walker DECORATOR_KEYS and RESERVED_KEYS**

In `walker.ts`, add to both sets:
`'label', 'target', 'actor', 'when', 'speed', 'content', 'await', 'mode'`

- [ ] **Step 3: Run Walker tests**

Run: `npm test -- --testPathPattern=walker` (from yaml-core package)
Expected: PASS (existing tests + new test)

- [ ] **Step 4: Update parser.ts WALKER_KNOWN_KEYS**

Add the same 8 keys to `WALKER_KNOWN_KEYS` at line 13 of `parser.ts`.

- [ ] **Step 5: Update parser.ts section field**

Change `sec['title']` → `sec['label']` in `parseScenarioFromParsed()`.

- [ ] **Step 6: Update types.ts**

Rename `TutorialSection.title` → `TutorialSection.label`.

- [ ] **Step 7: Run parser tests**

Run: `npm test -- --testPathPattern=parser` (from pages-aria)
Expected: PASS (update test fixtures if needed for label/title rename)

- [ ] **Step 8: Commit**

```
feat(#390): extend Walker DECORATOR_KEYS and parser WALKER_KNOWN_KEYS
```

### Task 7: scenario-handler.ts Dispatch Rewrite

**Files:**
- Modify: `packages/pages-aria/src/server/scenario-handler.ts`
- Test: existing scenario handler tests

**Interfaces:**
- Consumes: New DispatchStep shape `{name, label, actor?, action, params}`
- Produces: Single-action execution per step, AriaTarget from flat params

- [ ] **Step 1: Update DispatchStep interface**

```typescript
interface DispatchStep {
  name: string;
  label?: string;
  actor?: string;
  action: string;
  params: Record<string, any>;
  await?: { match?: Record<string, any>; timeout?: number; interval?: number; status?: number };
  mode?: string;
}
```

Remove `ScenarioCommand` and `CommandPayload` interfaces.

- [ ] **Step 2: Rewrite executeSequence for single-action dispatch**

Replace command-array iteration with single action per step:
```typescript
// Before: for (const cmd of step.commands) { ... }
// After:
const ariaTarget = {
  role: step.params.role,
  name: step.params.name,
  index: step.params.index,
  within: step.params.within
};
await executeAriaCommand(step.action, ariaTarget, step.params, step.actor);
```

- [ ] **Step 3: Add 'stop' to ExecutorControl and onControl**

```typescript
type ExecutorControl = 'pause' | 'resume' | 'step' | 'speed' | 'stop';

// In onControl switch:
case 'stop':
  stopped = true;
  stepQueue.length = 0;
  // send failure results for pending steps
  break;
```

- [ ] **Step 4: Add speed guard**

```typescript
// In sleepForSpeed:
if (speed <= 0 || speed >= 1000) return;
const delay = Math.max(10, Math.round(1000 / speed));
await sleep(delay);
```

- [ ] **Step 5: Add TS step name derivation from label decorator**

The TS execution layer must derive step names when `ResolvedStep.name`
is null (client-loaded scenarios via Walker path). Add to the TS
scenario execution code (in `parseScenarioFromParsed()` or downstream):

```typescript
function deriveStepName(step: ResolvedStep, index: number): string {
  if (step.name) return step.name;
  if (step.decorators?.label) {
    return step.decorators.label.toLowerCase()
      .replace(/[^a-z0-9]+/g, '-')
      .replace(/^-|-$/g, '');
  }
  return `${step.action}-${index}`;
}
```

Apply this in the step array post-processing after `Walker.resolve()`.

- [ ] **Step 6: Run scenario handler tests**

Run: `npm test -- --testPathPattern=scenario` (from pages-aria)
Expected: PASS (update test fixtures for new DispatchStep shape)

- [ ] **Step 7: Commit**

```
feat(#390): rewrite scenario-handler.ts for flat action+params dispatch
```

---

## Batch 5: YAML Migration + Cleanup

### Task 8: Migrate YAML Files to Compact Format

**Files:**
- Modify: all YAML files listed below
- No new Java/TS code — format migration only

**YAML files to migrate (commands[] → compact):**
- `backend/scenario/src/test/resources/scenarios/foreach-csv-inline.yaml`
- `backend/scenario/src/test/resources/scenarios/parameterized-onboard.yaml`
- `backend/scenario/src/test/resources/scenarios/environment-setup.yaml`
- `backend/scenario/src/test/resources/scenarios/graphql-inject-chat.yaml` — `delivery:` → `target: server`
- `backend/scenario/src/test/resources/scenarios/hybrid-helpdesk-demo.yaml` — `delivery:` → `target: server`
- `backend/scenario/src/test/resources/scenarios/caller-script.yaml` — `action: call` → `includes:`
- `backend/scenario/src/test/resources/scenarios/callee-create-user.yaml` — becomes include template
- `backend/scenario/src/test/resources/scenarios/cyclic-a.yaml` — call → includes
- `backend/scenario/src/test/resources/scenarios/cyclic-b.yaml` — call → includes

**Production YAML:**
- Find and migrate `META-INF/scenarios/helpdesk-intake.yaml`
- Find and migrate `META-INF/scenarios/environment-setup.yaml`
- Find and migrate `META-INF/scenarios/onboard-team-members.yaml`

**Tutorial YAML:**
- Check `tutorials/form-automation/tutorial.yaml`
- Check `tutorials/yaml-composition/tutorial.yaml`
- Check `tutorials/architecture-concepts/tutorial.yaml`

- [ ] **Step 1: Migrate test YAML files**

For each file, convert from:
```yaml
commands:
  - action: fill
    target: { role: textbox, name: Subject }
    value: hello
```
To:
```yaml
steps:
  - fill:
      role: textbox
      name: Subject
      value: hello
```

For call → includes migration:
```yaml
# Before
- action: call
  script: seeds/create-user
  callParams:
    userName: Alice
# After (at envelope level, not step level)
includes:
  - file: seeds/create-user.yaml
    params:
      userName: Alice
```

- [ ] **Step 2: Migrate production YAML files**

Same conversion pattern. Pay attention to `forEach:`, `when:`, `data:`,
`iterations:` blocks — these move to the envelope or become decorator
sibling keys.

- [ ] **Step 3: Check tutorial YAML files**

Tutorials use sections with steps. Verify they already use compact format
or migrate as needed.

- [ ] **Step 4: Run full test suite to verify migrations**

Run: `mvn -pl backend/scenario,backend/scenario-runtime,backend/scenario-client test -f pom.xml`
Expected: PASS

- [ ] **Step 5: Commit**

```
feat(#390): migrate YAML files to compact format
```

### Task 9: Delete Old Parser Types and Tests

**Files:**
- Delete: `backend/scenario/src/main/java/io/casehub/pages/scenario/ScenarioParser.java`
- Delete: `backend/scenario/src/main/java/io/casehub/pages/scenario/ScenarioStep.java`
- Delete: `backend/scenario/src/main/java/io/casehub/pages/scenario/ScenarioCommand.java`
- Delete: `backend/scenario/src/main/java/io/casehub/pages/scenario/HierarchicalParser.java`
- Delete: `backend/scenario/src/main/java/io/casehub/pages/scenario/HierarchicalStep.java`
- Delete: `backend/scenario/src/main/java/io/casehub/pages/scenario/HierarchicalScenario.java`
- Delete: `backend/scenario/src/main/java/io/casehub/pages/scenario/AriaTarget.java`
- Delete: `backend/scenario/src/main/java/io/casehub/pages/scenario/CallGraphValidator.java`
- Delete: `backend/scenario/src/main/java/io/casehub/pages/scenario/Scenario.java`
- Delete: `backend/scenario/src/test/java/.../ScenarioParserTest.java`
- Delete: `backend/scenario/src/test/java/.../HierarchicalParserTest.java`
- Delete: `backend/scenario/src/test/java/.../ScenarioCompilerCallTest.java`
- Delete: `backend/scenario/src/test/java/.../CallGraphValidatorTest.java`

**Interfaces:**
- Consumes: nothing (pure deletion)
- Produces: clean codebase with no references to deleted types

- [ ] **Step 1: Verify no remaining references to deleted types**

Use `ide_find_references` for each type to confirm zero usages remain
before deleting.

- [ ] **Step 2: Delete source files**

Use `ide_refactor_safe_delete` for each file. Order: leaf types first
(AriaTarget, ScenarioCommand, ScenarioStep), then records
(HierarchicalStep, HierarchicalScenario), then parsers
(HierarchicalParser, ScenarioParser), then validators
(CallGraphValidator), then Format A (Scenario).

- [ ] **Step 3: Delete test files**

Delete the 4 test files listed above.

- [ ] **Step 4: Run full build to verify clean compilation**

Run: `mvn -pl backend/scenario,backend/scenario-runtime,backend/scenario-client test -f pom.xml`
Expected: PASS with no compilation errors

- [ ] **Step 5: Commit**

```
feat(#390): delete old parsers and Format A types

Removes: ScenarioParser, HierarchicalParser, ScenarioStep,
ScenarioCommand, HierarchicalStep, HierarchicalScenario,
AriaTarget, CallGraphValidator, Scenario, and their tests.
```

---

## References

- `specs/epic-502-yaml-parity/2026-10-02-scenario-format-refinements-design.md` — design spec (post-review)
- `specs/epic-502-yaml-parity/decisions.md` — D18–D26 (scope expansion), D5–D12 (includes)
- `backend/scenario/src/main/java/io/casehub/pages/scenario/HierarchicalParser.java` — 328 lines (being deleted)
- `backend/scenario/src/main/java/io/casehub/pages/scenario/ScenarioCompiler.java` — 163 lines (being rewritten)
- `backend/scenario/src/main/java/io/casehub/pages/scenario/ScenarioStepAdapter.java` — 93 lines (being replaced)
- `backend/scenario-runtime/src/main/java/io/casehub/pages/scenario/runtime/ScenarioOrchestrator.java` — 589 lines (type migration + wire rewrite)
- `backend/scenario-client/src/main/java/io/casehub/pages/scenario/client/ScenarioExecutorClient.java` — 342 lines (wire format rewrite)
- `packages/yaml-core/src/step/walker.ts` — 456 lines (DECORATOR_KEYS extension)
- `packages/pages-aria/src/server/scenario-handler.ts` — 919 lines (dispatch rewrite)
- `packages/pages-aria/src/scenario/parser.ts` — 169 lines (WALKER_KNOWN_KEYS + label)
- casehub-pages#390 — focal issue
- casehubio/platform#502 — parent epic
- Design review: 3 dimensions × 3 rounds, 38 issues, 0 unresolved ($105.65)
