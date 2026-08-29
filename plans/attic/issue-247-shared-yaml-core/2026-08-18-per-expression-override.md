# Per-Expression Language Override Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** casehubio/engine#925 — feat: per-expression language override via YAML map syntax
**Issue group:** #902, #237, #238, #925, #926

**Goal:** Enable individual expressions in YAML case definitions to override the
definition-level `expressionLang` using map syntax: `when: { jq: ".expr" }`.

**Architecture:** Add a shared `resolveExpression(JsonNode, ExpressionEngineRegistry, String)`
helper to `CaseDefinitionYamlMapper` that handles both plain-string (existing) and
map-syntax (new) expressions. Update the JSON Schema so expression fields accept
`oneOf: [string, object]` — jsonschema2pojo generates `Object` return types, and Jackson
accepts both forms. Wire all registry-mediated expression sites through the helper.
Label rules are excluded (different type system). `doneWhen` keeps JQ as its default
language for backward compatibility.

**Tech Stack:** Java 21, Jackson/SnakeYAML, jsonschema2pojo, JUnit 5, AssertJ

## Global Constraints

- All changes confined to engine repo, `api/` and `schema/` modules
- No SPI changes, no runtime changes, no registry changes
- Label rules (`LabelRule` / `CompiledExpression`) excluded — separate type system
- `doneWhen` default language remains `"jq"` regardless of definition-level `expressionLang`
- Backward compatible — all existing YAML definitions parse identically
- IntelliJ MCP required for all source file operations

---

## Batch 1: Schema + Helper Foundation

### Task 1: JSON Schema update and resolveExpression helper

**Files:**
- Modify: `schema/src/main/resources/schema/CaseDefinition.yaml`
- Modify: `api/src/main/java/io/casehub/api/model/converter/CaseDefinitionYamlMapper.java`
- Create: `api/src/test/java/io/casehub/api/model/converter/CaseDefinitionYamlMapperExpressionOverrideTest.java`

**Interfaces:**
- Produces: `resolveExpression(JsonNode rawValue, ExpressionEngineRegistry registry, String defaultLang)` → `ExpressionEvaluator` — used by all subsequent tasks

- [ ] **Step 1: Update JSON Schema expression fields to oneOf**

In `schema/src/main/resources/schema/CaseDefinition.yaml`, change each expression field
from `type: string` to a `$ref` to a shared expression type definition. Add the
definition at the `$defs` level:

```yaml
  ExpressionOrOverride:
    description: >
      Expression string or per-expression language override map.
      Plain string uses the definition-level expressionLang.
      Map syntax overrides: { jq: ".expr" } or { mvel: "expr" }.
    oneOf:
      - type: string
      - type: object
        minProperties: 1
        maxProperties: 1
        additionalProperties:
          type: string
```

Update these fields to reference it:
- Binding `when` (line ~673): `when: { $ref: "#/$defs/ExpressionOrOverride", description: "..." }`
- ContextChangeTrigger `filter` (line ~808): `filter: { $ref: "#/$defs/ExpressionOrOverride", description: "..." }`
- Milestone `condition` (line ~892): change `type: string` to `$ref: "#/$defs/ExpressionOrOverride"`
- Milestone `entryCriteria` (line ~896): change `type: string` to `$ref: "#/$defs/ExpressionOrOverride"`
- Goal `condition` (line ~785): change `type: string` to `$ref: "#/$defs/ExpressionOrOverride"`
- CaseCompletion `doneWhen` (line ~797): change `type: string` to `$ref: "#/$defs/ExpressionOrOverride"`

Do NOT change label rule `when` (line ~423) — it stays `type: string`.

- [ ] **Step 2: Regenerate schema model classes**

Run: `mvn --batch-mode generate-sources -pl schema`
Expected: `io.casehub.model.Binding.getWhen()` now returns `Object` (was `String`).
Same for `Milestone.getCondition()`, `Goal.getCondition()`, etc.

- [ ] **Step 3: Fix compilation errors from type changes**

The schema model type changes (`String` → `Object`) will cause compilation errors in
`CaseDefinitionYamlMapper` where it calls `getWhen()`, `getCondition()`, etc. and passes
the result to `registry.create(String, String)`.

These call sites will be migrated to use `resolveExpression()` in Tasks 2 and 3.
For now, add casts or null-checks to keep compilation green. The key sites:
- `convertBinding()`: `schemaBinding.getWhen()` — cast to `(String)` temporarily
- Milestone loop: `sm.getCondition()` / `sm.getEntryCriteria()` — cast to `(String)`
- Goal loop: `sg.getCondition()` — cast to `(String)`
- Trigger: `schemaTrigger.getContextChange().getFilter()` — cast to `(String)`

Run: `mvn --batch-mode compile -pl api`
Expected: BUILD SUCCESS

- [ ] **Step 4: Write failing tests for resolveExpression helper**

Create `CaseDefinitionYamlMapperExpressionOverrideTest.java`:

```java
package io.casehub.api.model.converter;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.casehub.api.engine.ExpressionEngineRegistry;
import io.casehub.api.model.evaluator.ExpressionEvaluator;
import io.casehub.api.model.evaluator.JQExpressionEvaluator;
import org.junit.jupiter.api.Test;

class CaseDefinitionYamlMapperExpressionOverrideTest {

    private static final ObjectMapper JSON = new ObjectMapper();
    private final ExpressionEngineRegistry registry = new JqAndMvelTestRegistry();

    @Test
    void resolveExpression_plainString_usesDefaultLang() throws Exception {
        JsonNode node = JSON.readTree("\"amount > 1000\"");
        ExpressionEvaluator result = CaseDefinitionYamlMapper.resolveExpression(
                node, registry, "jq");
        assertThat(result).isInstanceOf(JQExpressionEvaluator.class);
        assertThat(result.type()).isEqualTo("jq");
    }

    @Test
    void resolveExpression_mapOverride_usesMapKey() throws Exception {
        JsonNode node = JSON.readTree("{\"mvel\": \"transaction.amount > 1000\"}");
        ExpressionEvaluator result = CaseDefinitionYamlMapper.resolveExpression(
                node, registry, "jq");
        assertThat(result.type()).isEqualTo("mvel");
    }

    @Test
    void resolveExpression_mapOverride_jqExplicit() throws Exception {
        JsonNode node = JSON.readTree("{\"jq\": \".amount > 1000\"}");
        ExpressionEvaluator result = CaseDefinitionYamlMapper.resolveExpression(
                node, registry, "mvel");
        assertThat(result).isInstanceOf(JQExpressionEvaluator.class);
        assertThat(result.type()).isEqualTo("jq");
    }

    @Test
    void resolveExpression_nullNode_returnsNull() {
        ExpressionEvaluator result = CaseDefinitionYamlMapper.resolveExpression(
                null, registry, "jq");
        assertThat(result).isNull();
    }

    @Test
    void resolveExpression_multipleKeys_throws() throws Exception {
        JsonNode node = JSON.readTree("{\"jq\": \"a\", \"mvel\": \"b\"}");
        assertThatThrownBy(() ->
                CaseDefinitionYamlMapper.resolveExpression(node, registry, "jq"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("single-key map");
    }

    @Test
    void resolveExpression_unsupportedLanguage_throws() throws Exception {
        JsonNode node = JSON.readTree("{\"drools\": \"rule\"}");
        assertThatThrownBy(() ->
                CaseDefinitionYamlMapper.resolveExpression(node, registry, "jq"))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void resolveExpression_emptyMap_throws() throws Exception {
        JsonNode node = JSON.readTree("{}");
        assertThatThrownBy(() ->
                CaseDefinitionYamlMapper.resolveExpression(node, registry, "jq"))
                .isInstanceOf(IllegalArgumentException.class);
    }
}
```

The `JqAndMvelTestRegistry` is a test-only `ExpressionEngineRegistry` that supports both
`"jq"` and `"mvel"` languages. Check if the existing `JqOnlyExpressionEngineRegistry`
(at `api/src/test/java/io/casehub/api/engine/JqOnlyExpressionEngineRegistry.java`) can be
extended or if a new one is needed. The test registry must:
- `create("expr", "jq")` → `new JQExpressionEvaluator("expr")`
- `create("expr", "mvel")` → `new MvelExpressionEvaluator("expr")` (or equivalent)
- `assertLanguageSupported("jq")` / `assertLanguageSupported("mvel")` → no-op
- `assertLanguageSupported("drools")` → throw

Run: `mvn --batch-mode test -pl api -Dtest=CaseDefinitionYamlMapperExpressionOverrideTest`
Expected: FAIL — `resolveExpression` method does not exist

- [ ] **Step 5: Implement resolveExpression helper**

Add to `CaseDefinitionYamlMapper` as a package-private static method (visible to tests
in the same package):

```java
static ExpressionEvaluator resolveExpression(
        final JsonNode rawValue,
        final ExpressionEngineRegistry registry,
        final String defaultLang) {
    if (rawValue == null || rawValue.isNull()) {
        return null;
    }
    if (rawValue.isTextual()) {
        return registry.create(rawValue.asText(), defaultLang);
    }
    if (rawValue.isObject()) {
        if (rawValue.size() != 1) {
            throw new IllegalArgumentException(
                    "Expression override must be a single-key map {lang: expr}, got "
                            + rawValue.size() + " keys");
        }
        var entry = rawValue.fields().next();
        String lang = entry.getKey();
        String expr = entry.getValue().asText();
        registry.assertLanguageSupported(lang);
        return registry.create(expr, lang);
    }
    throw new IllegalArgumentException(
            "Expression must be a string or single-key map {lang: expr}, got: "
                    + rawValue.getNodeType());
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl api -Dtest=CaseDefinitionYamlMapperExpressionOverrideTest`
Expected: ALL PASS

- [ ] **Step 7: Run full api module tests**

Run: `mvn --batch-mode test -pl api`
Expected: BUILD SUCCESS — no regressions from schema type changes

- [ ] **Step 8: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/117/engine add schema/src/main/resources/schema/CaseDefinition.yaml api/src/main/java/io/casehub/api/model/converter/CaseDefinitionYamlMapper.java api/src/test/java/io/casehub/api/model/converter/CaseDefinitionYamlMapperExpressionOverrideTest.java
git -C /Users/mdproctor/claude/casehub/slots/117/engine commit -m "feat(#925): add ExpressionOrOverride schema type and resolveExpression helper

Refs casehubio/engine#925"
```

---

## Batch 2: Wire Expression Sites

### Task 2: Wire binding `when` and trigger `filter`

**Files:**
- Modify: `api/src/main/java/io/casehub/api/model/converter/CaseDefinitionYamlMapper.java`
- Modify: `api/src/test/java/io/casehub/api/model/converter/CaseDefinitionYamlMapperExpressionOverrideTest.java`
- Create: `api/src/test/resources/casehub/expression-override-binding.yaml` (test fixture)

**Interfaces:**
- Consumes: `resolveExpression(JsonNode, ExpressionEngineRegistry, String)` from Task 1

- [ ] **Step 1: Write failing YAML round-trip test for binding `when` override**

Add test to `CaseDefinitionYamlMapperExpressionOverrideTest`:

```java
@Test
void load_bindingWhen_mapOverride_producesCorrectEvaluator() throws IOException {
    try (InputStream is = getClass().getClassLoader()
            .getResourceAsStream("casehub/expression-override-binding.yaml")) {
        CaseDefinition def = CaseDefinitionYamlMapper.load(is,
                new ObjectMapper(new com.fasterxml.jackson.dataformat.yaml.YAMLFactory()),
                registry, node -> WorkerFunction.NONE);
        Binding binding = def.getBindings().stream()
                .filter(b -> "jq-override".equals(b.getName()))
                .findFirst().orElseThrow();
        assertThat(binding.getWhen()).isNotNull();
        assertThat(binding.getWhen().type()).isEqualTo("jq");
    }
}
```

Create `api/src/test/resources/casehub/expression-override-binding.yaml`:

```yaml
name: expression-override-test
version: "1.0"
expressionLang: mvel
spec:
  capabilities:
    - name: worker-cap
      worker:
        type: test
  bindings:
    - name: mvel-default
      capability: worker-cap
      on:
        contextChange: {}
      when: "status == 'READY'"
    - name: jq-override
      capability: worker-cap
      on:
        contextChange:
          filter: { jq: ".status == \"READY\"" }
      when: { jq: ".amount > 1000" }
```

Run: `mvn --batch-mode test -pl api -Dtest=CaseDefinitionYamlMapperExpressionOverrideTest#load_bindingWhen_mapOverride_producesCorrectEvaluator`
Expected: FAIL — the mapper still uses `schemaBinding.getWhen()` string path

- [ ] **Step 2: Wire convertBinding to use resolveExpression**

In `convertBinding()`, replace:
```java
if (schemaBinding.getWhen() != null) {
    builder.when(registry.create(schemaBinding.getWhen(), expressionLang));
}
```
with:
```java
if (rawBindingNode != null && rawBindingNode.has("when")) {
    builder.when(resolveExpression(rawBindingNode.get("when"), registry, expressionLang));
}
```

- [ ] **Step 3: Wire convertTrigger to use resolveExpression**

Change `convertTrigger` signature to accept a raw trigger node:
```java
private static io.casehub.api.model.Trigger convertTrigger(
        final io.casehub.model.Trigger schemaTrigger,
        final JsonNode rawTriggerNode,
        final ExpressionEngineRegistry registry,
        final String expressionLang)
```

In the ContextChangeTrigger branch, replace:
```java
return new io.casehub.api.model.ContextChangeTrigger(
        filter != null ? registry.create(filter, expressionLang) : null, listenLayer);
```
with:
```java
JsonNode ctxNode = rawTriggerNode != null ? rawTriggerNode.get("contextChange") : null;
JsonNode filterNode = ctxNode != null ? ctxNode.get("filter") : null;
ExpressionEvaluator filterEval = resolveExpression(filterNode, registry, expressionLang);
return new io.casehub.api.model.ContextChangeTrigger(filterEval, listenLayer);
```

Update the call site in `convertBinding()`:
```java
final io.casehub.api.model.Trigger trigger = convertTrigger(
        schemaBinding.getOn(),
        rawBindingNode != null ? rawBindingNode.get("on") : null,
        registry, expressionLang);
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl api -Dtest=CaseDefinitionYamlMapperExpressionOverrideTest`
Expected: ALL PASS

- [ ] **Step 5: Run full api module tests**

Run: `mvn --batch-mode test -pl api`
Expected: BUILD SUCCESS — no regressions

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/117/engine add api/
git -C /Users/mdproctor/claude/casehub/slots/117/engine commit -m "feat(#925): wire binding when + trigger filter through resolveExpression

Refs casehubio/engine#925"
```

### Task 3: Wire milestones, goals, and doneWhen

**Files:**
- Modify: `api/src/main/java/io/casehub/api/model/converter/CaseDefinitionYamlMapper.java`
- Modify: `api/src/test/java/io/casehub/api/model/converter/CaseDefinitionYamlMapperExpressionOverrideTest.java`
- Modify: `api/src/test/resources/casehub/expression-override-binding.yaml` (extend fixture)

**Interfaces:**
- Consumes: `resolveExpression(JsonNode, ExpressionEngineRegistry, String)` from Task 1

- [ ] **Step 1: Write failing tests for milestone and goal overrides**

Add tests to `CaseDefinitionYamlMapperExpressionOverrideTest`:

```java
@Test
void load_milestoneCondition_mapOverride() throws IOException {
    try (InputStream is = loadFixture()) {
        CaseDefinition def = loadDef(is);
        Milestone ms = def.getMilestones().stream()
                .filter(m -> "jq-milestone".equals(m.getName()))
                .findFirst().orElseThrow();
        assertThat(ms.getCompletionCriteria().type()).isEqualTo("jq");
    }
}

@Test
void load_goalCondition_mapOverride() throws IOException {
    try (InputStream is = loadFixture()) {
        CaseDefinition def = loadDef(is);
        Goal goal = def.getGoals().stream()
                .filter(g -> "jq-goal".equals(g.getName()))
                .findFirst().orElseThrow();
        assertThat(goal.getCondition().type()).isEqualTo("jq");
    }
}

@Test
void load_doneWhen_mapOverride() throws IOException {
    // Separate fixture with doneWhen override
    String yaml = """
            name: donewhen-override-test
            version: "1.0"
            expressionLang: mvel
            spec:
              goals:
                - name: done
                  condition: "completed == true"
              completion:
                doneWhen: { jq: ".completed == true" }
            """;
    CaseDefinition def = CaseDefinitionYamlMapper.load(
            new java.io.ByteArrayInputStream(yaml.getBytes()),
            new ObjectMapper(new com.fasterxml.jackson.dataformat.yaml.YAMLFactory()),
            registry, node -> WorkerFunction.NONE);
    assertThat(def.getCompletion()).isInstanceOf(
            io.casehub.api.model.PredicateBasedCompletion.class);
}

@Test
void load_doneWhen_plainString_defaultsToJq() throws IOException {
    // doneWhen without override stays JQ even with expressionLang: mvel
    String yaml = """
            name: donewhen-default-test
            version: "1.0"
            expressionLang: mvel
            spec:
              goals:
                - name: done
                  condition: "completed == true"
              completion:
                doneWhen: ".completed == true"
            """;
    CaseDefinition def = CaseDefinitionYamlMapper.load(
            new java.io.ByteArrayInputStream(yaml.getBytes()),
            new ObjectMapper(new com.fasterxml.jackson.dataformat.yaml.YAMLFactory()),
            registry, node -> WorkerFunction.NONE);
    assertThat(def.getCompletion()).isInstanceOf(
            io.casehub.api.model.PredicateBasedCompletion.class);
    // Verify it's JQ, not MVEL — backward compatibility
}
```

Extend the YAML fixture with milestone and goal entries that use map override syntax.

Run: `mvn --batch-mode test -pl api -Dtest=CaseDefinitionYamlMapperExpressionOverrideTest`
Expected: FAIL — mapper still uses string accessors for milestones/goals

- [ ] **Step 2: Thread raw nodes to milestone and goal loops**

In `convertToApiModel()`, the milestone loop currently iterates:
```java
for (io.casehub.model.Milestone sm : schema.getSpec().getMilestones()) {
```

Add parallel raw node iteration:
```java
JsonNode milestonesNode = specNode != null ? specNode.get("milestones") : null;
List<io.casehub.model.Milestone> schemaMilestones = schema.getSpec().getMilestones();
for (int i = 0; i < schemaMilestones.size(); i++) {
    io.casehub.model.Milestone sm = schemaMilestones.get(i);
    JsonNode rawMilestoneNode = milestonesNode != null && i < milestonesNode.size()
            ? milestonesNode.get(i) : null;
```

Replace milestone expression creation:
```java
.completionCriteria(effectiveRegistry.create(sm.getCondition(), expressionLang))
```
with:
```java
.completionCriteria(resolveExpression(
        rawMilestoneNode != null ? rawMilestoneNode.get("condition") : null,
        effectiveRegistry, expressionLang))
```

Same for `entryCriteria`:
```java
milestoneBuilder.entryCriteria(resolveExpression(
        rawMilestoneNode != null ? rawMilestoneNode.get("entryCriteria") : null,
        effectiveRegistry, expressionLang));
```

- [ ] **Step 3: Thread raw nodes to goal loop**

Same pattern for goals:
```java
JsonNode goalsNode = specNode != null ? specNode.get("goals") : null;
List<io.casehub.model.Goal> schemaGoals = schema.getSpec().getGoals();
for (int i = 0; i < schemaGoals.size(); i++) {
    io.casehub.model.Goal sg = schemaGoals.get(i);
    JsonNode rawGoalNode = goalsNode != null && i < goalsNode.size()
            ? goalsNode.get(i) : null;
```

Replace:
```java
effectiveRegistry.create(sg.getCondition(), expressionLang)
```
with:
```java
resolveExpression(
        rawGoalNode != null ? rawGoalNode.get("condition") : null,
        effectiveRegistry, expressionLang)
```

- [ ] **Step 4: Wire doneWhen through resolveExpression with JQ default**

Replace:
```java
def.setCompletion(new PredicateBasedCompletion(new JQExpressionEvaluator(doneWhen)));
```
with:
```java
JsonNode doneWhenNode = completionNode.get("doneWhen");
ExpressionEvaluator doneWhenEval = resolveExpression(
        doneWhenNode, effectiveRegistry, JQExpressionEvaluator.TYPE);
def.setCompletion(new PredicateBasedCompletion(doneWhenEval));
```

Note: default language is `JQExpressionEvaluator.TYPE` (not `expressionLang`) for
backward compatibility.

Remove the now-unused `String doneWhen = completionNode.get("doneWhen").asText()` variable.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl api -Dtest=CaseDefinitionYamlMapperExpressionOverrideTest`
Expected: ALL PASS

- [ ] **Step 6: Run full test suite**

Run: `mvn --batch-mode test -pl api`
Expected: BUILD SUCCESS

Run: `mvn --batch-mode test`
Expected: BUILD SUCCESS (full engine)

- [ ] **Step 7: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/117/engine add api/
git -C /Users/mdproctor/claude/casehub/slots/117/engine commit -m "feat(#925): wire milestones, goals, doneWhen through resolveExpression

doneWhen default stays JQ for backward compat.

Refs casehubio/engine#925"
```

---

## Batch 3: ADR Update + Cleanup

### Task 4: Update ADR-0009 and remove temporary casts

**Files:**
- Modify: `docs/adr/0009-expression-lang-granularity.md`
- Modify: `api/src/main/java/io/casehub/api/model/converter/CaseDefinitionYamlMapper.java` (remove temporary casts from Task 1 Step 3)

**Interfaces:**
- None — documentation and cleanup only

- [ ] **Step 1: Remove temporary String casts**

Check `CaseDefinitionYamlMapper` for any remaining `(String)` casts added in Task 1 Step 3
that were not already replaced in Tasks 2-3. All expression sites should now go through
`resolveExpression()` reading from raw `JsonNode`, so no schema model `getWhen()` /
`getCondition()` casts should remain for expression fields.

- [ ] **Step 2: Update ADR-0009**

Add a "Superseded" note to `docs/adr/0009-expression-lang-granularity.md`:

```markdown
Status: Superseded (per-expression override added by #925)

## Superseded by #925

The original decision chose per-definition granularity. Engine#925 adds per-expression
override via YAML map syntax (`when: { jq: ".expr" }`), implementing Option B from this
ADR. The definition-level `expressionLang` remains the default — per-expression is additive.

The CNCF SW 1.0 divergence concern is accepted: CNCF SW 1.0 defines `expressionLang` at
the workflow level, but casehub's typed-POJO context model (`contextType` + MVEL inference)
creates a concrete need for mixed-language definitions that CNCF SW 1.0 does not address.
```

- [ ] **Step 3: Run full test suite**

Run: `mvn --batch-mode test`
Expected: BUILD SUCCESS

- [ ] **Step 4: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/117/engine add docs/adr/0009-expression-lang-granularity.md api/
git -C /Users/mdproctor/claude/casehub/slots/117/engine commit -m "docs(#925): supersede ADR-0009 with per-expression override

Closes casehubio/engine#925

Refs casehubio/engine#925"
```

---

## References

- [2026-08-18-per-expression-override-design.md] — design spec this plan implements
- [decisions.md] — D1-D5 design decisions
- `api/src/main/java/io/casehub/api/model/converter/CaseDefinitionYamlMapper.java` — primary file
- `schema/src/main/resources/schema/CaseDefinition.yaml` — JSON Schema source
- `docs/adr/0009-expression-lang-granularity.md` — ADR being superseded
- `api/src/test/java/io/casehub/api/engine/JqOnlyExpressionEngineRegistry.java` — existing test registry
- GE-20260420-18fbd4 — ExpressionEvaluator marker interface dispatch
- GE-20260818-68c8a3 — TypedEvaluator pattern
- casehubio/engine#925 — focal issue
- casehubio/engine#238 — parent feature (JavaBeanCaseFile)
