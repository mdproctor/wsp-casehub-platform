# Type Unification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** casehub-pages#508 — Complete type unification
**Issue group:** #502 (epic)

**Goal:** Eliminate remaining type name drift and YAML ceremony divergence between Java and TS YAML runtimes.

**Architecture:** Rename Java types to match TS names (Walker, DefinitionSource), port TS Walker's inline action resolution to Java (stripKeys + resolveOne pattern), add YAML multi-document front matter support to ScenarioParser. Then clean up TS-side drift in pages repo.

**Tech Stack:** Java 21 (yaml-step-runtime, yaml-core), TypeScript (pages yaml-core), SnakeYAML, js-yaml

## Global Constraints

- `yaml-core/` and `yaml-plugin-api/` must remain zero-dependency
- Use `ide_refactor_rename` for class/file renames — never bash `mv` on source files
- All renames in yaml-step-runtime stay within `io.casehub.yaml.step.catalog` package
- Test file renames in yaml-core stay within `io.casehub.yaml.core.step` package

---

## Batch 1: Platform Type Renames

### Task 1: Rename StepWalker → Walker and YamlStepDefinitionSource → YamlDefinitionSource

**Files:**
- Rename: `StepWalker` → `Walker` (use `ide_refactor_rename`)
- Rename: `StepWalkerTest` → `WalkerTest` (use `ide_refactor_rename`)
- Rename: `YamlStepDefinitionSource` → `YamlDefinitionSource` (use `ide_refactor_rename`)
- Modify: `docs/guides/yaml-language-guide.md` — update class name references
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/catalog/WalkerTest.java` (renamed)

**Interfaces:**
- Produces: `Walker.resolve(List<Map<String, Object>>, PluginRegistry)` — same signature, new class name
- Produces: `YamlDefinitionSource.populate(PluginRegistry)` — same signature, new class name

- [ ] **Step 1: Rename StepWalker → Walker via IntelliJ**

Use `ide_refactor_rename` on `io.casehub.yaml.step.catalog.StepWalker` to `Walker`.
This updates the class file, all 43 test references in StepWalkerTest, the logger, and imports.

- [ ] **Step 2: Rename StepWalkerTest → WalkerTest via IntelliJ**

Use `ide_refactor_rename` on `io.casehub.yaml.step.catalog.StepWalkerTest` to `WalkerTest`.

- [ ] **Step 3: Rename YamlStepDefinitionSource → YamlDefinitionSource via IntelliJ**

Use `ide_refactor_rename` on `io.casehub.yaml.step.catalog.YamlStepDefinitionSource` to `YamlDefinitionSource`.

- [ ] **Step 4: Rename test files in yaml-core**

Use `ide_refactor_rename`:
- `io.casehub.yaml.core.step.StepDefinitionParserTest` → `DeclarationParserTest`
- `io.casehub.yaml.core.step.StepDefinitionTest` → `DeclarationTest`

- [ ] **Step 5: Update doc references**

Edit `docs/guides/yaml-language-guide.md`:
- Line 778: `StepWalker` → `Walker`
- Line 687: `YamlStepDefinitionSource` → `YamlDefinitionSource`

Historical spec docs (5 files) — add inline annotation "(renamed to Walker)" rather than rewriting historical decision context.

- [ ] **Step 6: Run tests to verify renames**

Run: `mvn --batch-mode test -pl yaml-step-runtime,yaml-core -Dsurefire.useFile=false`
Expected: All tests pass with new class names.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor(#508): rename StepWalker → Walker, YamlStepDefinitionSource → YamlDefinitionSource

Aligns Java type names with TS Walker naming convention.
Renames test files in yaml-core to match already-renamed production classes.

Refs casehub-pages#508"
```

---

## Batch 2: Ceremony Elimination

### Task 2: Add REMOVED_KEYS rejection and stripKeys utility to Walker

**Files:**
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/Walker.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/catalog/WalkerTest.java`

**Interfaces:**
- Consumes: `Walker.resolveOne()` — existing private method
- Produces: `Walker.stripKeys(Map, Set)` — new private utility

- [ ] **Step 1: Write failing tests for REMOVED_KEYS rejection**

Add two tests to `WalkerTest.java`:

```java
@Test
void rejectsStepsKey() {
    Map<String, Object> step = new LinkedHashMap<>();
    step.put("match", "${x}");
    step.put("cases", List.of(Map.of("pattern", "a", "steps", List.of())));

    assertThatThrownBy(() -> Walker.resolve(List.of(step), registry))
            .isInstanceOf(IllegalArgumentException.class)
            .hasMessageContaining("'steps' is no longer valid");
}

@Test
void rejectsDoKey() {
    Map<String, Object> step = new LinkedHashMap<>();
    step.put("match", "${x}");
    step.put("cases", List.of(Map.of("pattern", "a", "do", List.of())));

    assertThatThrownBy(() -> Walker.resolve(List.of(step), registry))
            .isInstanceOf(IllegalArgumentException.class)
            .hasMessageContaining("'do' is no longer valid");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=WalkerTest#rejectsStepsKey+rejectsDoKey -Dsurefire.useFile=false`
Expected: FAIL — no rejection logic for these keys yet.

- [ ] **Step 3: Implement REMOVED_KEYS and stripKeys**

In `Walker.java`, add:

```java
private static final Set<String> REMOVED_KEYS = Set.of("steps", "do");
```

At the top of `resolveOne()`, before the key classification loop, add a check:

```java
for (String key : step.keySet()) {
    if (REMOVED_KEYS.contains(key)) {
        throw new IllegalArgumentException(
                path + " → Step " + index + ": '" + key
                + "' is no longer valid — use inline sibling keys, or 'block' for multiple actions");
    }
}
```

Add the `stripKeys` utility method:

```java
private static Map<String, Object> stripKeys(
        Map<String, Object> map, Set<String> keysToStrip) {
    var result = new LinkedHashMap<String, Object>();
    for (var e : map.entrySet()) {
        if (!keysToStrip.contains(e.getKey())) {
            result.put(e.getKey(), e.getValue());
        }
    }
    return result;
}
```

- [ ] **Step 4: Run tests to verify REMOVED_KEYS pass**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=WalkerTest#rejectsStepsKey+rejectsDoKey -Dsurefire.useFile=false`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add yaml-step-runtime/
git commit -m "feat(#508): add REMOVED_KEYS rejection and stripKeys utility to Walker

Rejects 'steps' and 'do' keys with a clear error message pointing to
inline sibling keys or 'block' for multiple actions.

Refs casehub-pages#508"
```

### Task 3: Port inline action resolution to match cases and select branches

**Files:**
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/Walker.java`
- Modify: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/catalog/WalkerTest.java`

**Interfaces:**
- Consumes: `Walker.stripKeys(Map, Set)` from Task 2
- Consumes: `Walker.resolveOne()` — existing private method

- [ ] **Step 1: Write failing test for inline match case resolution**

Add test to `WalkerTest.java`:

```java
@Test
void resolvesMatchCaseWithInlineAction() {
    Map<String, Object> step = new LinkedHashMap<>();
    step.put("match", "${status}");
    step.put("cases", List.of(
            Map.of("pattern", "active",
                    "process", Map.of("command", "activate.sh")),
            Map.of("default", List.of(
                    Map.of("assert", Map.of("expected", "fallback"))))));

    List<ResolvedStep> resolved = Walker.resolve(List.of(step), registry);

    assertThat(resolved).hasSize(1);
    var match = (ResolvedStep.MatchStep) resolved.get(0);
    assertThat(match.cases()).hasSize(2);
    assertThat(match.cases().get(0).steps()).hasSize(1);
    assertThat(match.cases().get(0).steps().get(0)).isInstanceOf(ResolvedStep.PluginStep.class);
    var plugin = (ResolvedStep.PluginStep) match.cases().get(0).steps().get(0);
    assertThat(plugin.actionName()).isEqualTo("process");
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=WalkerTest#resolvesMatchCaseWithInlineAction -Dsurefire.useFile=false`
Expected: FAIL — current code looks for `do` key, not inline action.

- [ ] **Step 3: Modify resolveMatchCases for inline resolution**

In `Walker.java`, replace the non-default case resolution in `resolveMatchCases()`. Replace the block that currently does:

```java
if (caseMap.containsKey("steps")) {
    throw new IllegalArgumentException(...);
}
String guard = ...;
var steps = caseMap.containsKey("do")
            ? (List<Map<String, Object>>) caseMap.get("do")
            : List.<Map<String, Object>>of();
result.add(new ResolvedMatchCase(pattern, guard, resolve(steps, ...)));
```

With:

```java
String guard = caseMap.containsKey("guard")
               ? String.valueOf(caseMap.get("guard")) : null;
var rest = stripKeys(caseMap, Set.of("pattern", "when", "guard"));
List<ResolvedStep> caseSteps = rest.isEmpty()
    ? List.of()
    : List.of(resolveOne(rest, registry, i, depth + 1, casePath, seenNames));
result.add(new ResolvedMatchCase(pattern, guard, caseSteps));
```

- [ ] **Step 4: Write failing test for inline select branch resolution**

Add test to `WalkerTest.java`:

```java
@Test
void resolvesSelectBranchWithInlineAction() {
    Map<String, Object> step = new LinkedHashMap<>();
    step.put("select", List.of(
            Map.of("subscribe", "events",
                    "process", Map.of("command", "handle.sh")),
            Map.of("wait", "timeout-signal",
                    "assert", Map.of("expected", "timed-out"))));

    List<ResolvedStep> resolved = Walker.resolve(List.of(step), registry);

    assertThat(resolved).hasSize(1);
    var select = (ResolvedStep.SelectStep) resolved.get(0);
    assertThat(select.branches()).hasSize(2);
    assertThat(select.branches().get(0).steps()).hasSize(1);
    assertThat(select.branches().get(0).steps().get(0)).isInstanceOf(ResolvedStep.PluginStep.class);
}
```

- [ ] **Step 5: Run test to verify it fails**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=WalkerTest#resolvesSelectBranchWithInlineAction -Dsurefire.useFile=false`
Expected: FAIL

- [ ] **Step 6: Modify resolveSelectBranches for inline resolution**

In `Walker.java`, replace the select branch resolution. Replace the block that currently does:

```java
if (branchMap.containsKey("steps")) {
    throw new IllegalArgumentException(...);
}
var steps = branchMap.containsKey("do")
            ? (List<Map<String, Object>>) branchMap.get("do")
            : List.<Map<String, Object>>of();
result.add(new ResolvedStep.SelectBranch(type, name, resolve(steps, ...)));
```

With (for subscribe branches):

```java
var rest = stripKeys(branchMap, Set.of("subscribe"));
var branchSteps = rest.isEmpty()
    ? List.<ResolvedStep>of()
    : List.of(resolveOne(rest, registry, 0, depth + 1, branchPath, seenNames));
result.add(new ResolvedStep.SelectBranch(type, name, branchSteps));
```

And similarly for wait branches, stripping `"wait"`.

- [ ] **Step 7: Update existing tests that use `do:` syntax**

Find all tests in `WalkerTest.java` that construct match cases or select branches using `"do"` key and update them to use inline action syntax. The existing `resolvesMatchStep` and `resolvesSelectStep` tests use `"do"` — update to inline:

Match test: replace `Map.of("pattern", "active", "do", List.of(Map.of("process", ...)))` with `Map.of("pattern", "active", "process", Map.of(...))`.

Select test: replace `Map.of("subscribe", "events", "do", List.of(Map.of("process", ...)))` with `Map.of("subscribe", "events", "process", Map.of(...))`.

- [ ] **Step 8: Run full Walker test suite**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=WalkerTest -Dsurefire.useFile=false`
Expected: All tests pass.

- [ ] **Step 9: Commit**

```bash
git add yaml-step-runtime/
git commit -m "feat(#508): port inline action resolution from TS Walker

Match cases and select branches now resolve actions as inline sibling
keys (strip config keys, resolve remainder via resolveOne). 'do' wrapper
eliminated — use inline keys or 'block' for multiple actions.

Refs casehub-pages#508"
```

---

## Batch 3: Front Matter Format

### Task 4: Add multi-document YAML front matter support to ScenarioParser

**Files:**
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/scenario/ScenarioParser.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/scenario/ScenarioParserTest.java`

**Interfaces:**
- Consumes: `ScenarioParser.parse(String, Map)` — existing API
- Produces: `ScenarioParser.parseYaml(String yaml)` — new entry point that handles multi-document split

- [ ] **Step 1: Write failing test for multi-document parsing**

Add test to `ScenarioParserTest.java`:

```java
@Test
void parsesMultiDocumentFrontMatter() {
    String yaml = """
            scenario: test-scenario
            ---
            states:
              idle:
                - next: done
              done: terminal
            """;

    ScenarioDefinition def = ScenarioParser.parseYaml(yaml);

    assertThat(def.name()).isEqualTo("test-scenario");
    assertThat(def.states()).containsKey("idle");
    assertThat(def.states()).containsKey("done");
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=ScenarioParserTest#parsesMultiDocumentFrontMatter -Dsurefire.useFile=false`
Expected: FAIL — `parseYaml` method doesn't exist yet.

- [ ] **Step 3: Implement parseYaml with multi-document support**

In `ScenarioParser.java`, add:

```java
@SuppressWarnings("unchecked")
public static ScenarioDefinition parseYaml(String yaml) {
    var loader = new org.yaml.snakeyaml.Yaml();
    var documents = new java.util.ArrayList<Object>();
    for (Object doc : loader.loadAll(yaml)) {
        documents.add(doc);
    }

    if (documents.size() == 1) {
        var root = (Map<String, Object>) documents.get(0);
        var name = (String) root.getOrDefault("scenario", "unnamed");
        return parse(name, root);
    }

    var meta = (Map<String, Object>) documents.get(0);
    var name = (String) meta.getOrDefault("scenario", "unnamed");
    var content = documents.get(1);

    if (content instanceof Map) {
        var contentMap = new LinkedHashMap<>((Map<String, Object>) content);
        return parse(name, contentMap);
    }

    throw new IllegalArgumentException(
            "Second YAML document must be a mapping (states or metadata)");
}
```

- [ ] **Step 4: Write test for single-document backward compatibility**

```java
@Test
void parseYaml_singleDocument_backwardCompatible() {
    String yaml = """
            scenario: legacy
            states:
              start:
                - next: end
              end: terminal
            """;

    ScenarioDefinition def = ScenarioParser.parseYaml(yaml);

    assertThat(def.name()).isEqualTo("legacy");
    assertThat(def.states()).containsKey("start");
}
```

- [ ] **Step 5: Run full ScenarioParser test suite**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=ScenarioParserTest -Dsurefire.useFile=false`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add yaml-step-runtime/
git commit -m "feat(#508): add multi-document YAML front matter support to ScenarioParser

ScenarioParser.parseYaml() handles both single-document (backward compat)
and multi-document (front matter: metadata --- content) YAML formats.

Refs casehub-pages#508"
```

---

## Batch 4: Pages Cleanup

### Task 5: Fix TS type name drift

**Files:**
- Modify: `packages/yaml-core/src/step/sources/yaml-source.test.ts` — test description
- Modify: `packages/yaml-core/src/step/sources/script-source.test.ts` — test description
- Modify: `examples/src/casehub-entry.ts` — export/import names
- Modify: `packages/yaml-core/src/schema.ts` — schema key name
- Test: Existing tests pass after changes

**Interfaces:**
- No interface changes — cosmetic drift fixes

- [ ] **Step 1: Fix test descriptions**

In `yaml-source.test.ts:86`: change test description string from `StepDefinitionParser` to `DeclarationParser`.

In `script-source.test.ts:54`: change test description string from `ValidatingStepAction` to `ValidatingAction`.

- [ ] **Step 2: Fix casehub-entry.ts exports**

At line 42: change `export type { StepResult }` to `export type { Result }`.
At line 54: change `import type { StepAction }` to `import type { Action }`.

Verify the source types exist in the import source — if they were already renamed in the exporting module, the import paths may need updating.

- [ ] **Step 3: Fix schema drift**

In `schema.ts:25`: change `importSchema.steps` to `importSchema.actions`.

- [ ] **Step 4: Regenerate typecheck output**

Run: `npm run typecheck` (or the equivalent in the examples package) to regenerate `examples/.typecheck/`.

- [ ] **Step 5: Run pages test suite**

Run: `npm test -- --filter yaml-core` in the pages repo.
Expected: All tests pass.

- [ ] **Step 6: Annotate historical spec docs**

In `docs/specs/issue-501-step-catalog-browser/decisions.md`: add "(renamed to Walker)" after `StepWalker` references.

In `docs/specs/issue-501-step-catalog-browser/2026-09-29-step-catalog-browser-design.md`: add inline annotations for 9 old-name references.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor(#508): fix type name drift in pages — test descriptions, exports, schema

Aligns remaining references to post-unification names:
StepDefinitionParser → DeclarationParser, StepResult → Result,
StepAction → Action, importSchema.steps → importSchema.actions.

Refs casehub-pages#508"
```

---

## Batch 5: Pages Front Matter + Scenario Updates

### Task 6: Add TS front matter parsing and update scenario documents

**Files:**
- Modify: TS scenario parser (likely `packages/yaml-core/src/step/sources/yaml-source.ts` or a scenario parser file)
- Modify: 22 scenario `.ts` files in `examples/samples/Scenarios/`
- Test: Existing scenario tests pass

**Interfaces:**
- Consumes: js-yaml `loadAll()` — built-in multi-document support

- [ ] **Step 1: Identify the TS scenario parser entry point**

Find the function that loads YAML scenario content and passes it to `Walker.resolve()`. This is the call site that needs `loadAll()` support.

- [ ] **Step 2: Write failing test for multi-document YAML**

Write a test that passes a multi-document YAML string (metadata `---` actions) to the parser and verifies both metadata and actions are extracted.

- [ ] **Step 3: Implement multi-document support**

Change from `load()` to `loadAll()`. Split: first document = metadata, second = action array. Fall back to single-document when only one document exists.

- [ ] **Step 4: Update scenario documents**

For each of the 22 scenario files (Coordination.ts: 4, Data Delivery.ts: 3, Flow Control.ts: 9, Composition.ts: 3, Concurrency Patterns.ts: 3):
- Extract metadata keys to before the `---` separator
- Move the action array after the `---` separator
- Verify each file individually

- [ ] **Step 5: Run pages test suite**

Run full test suite to verify all scenarios still parse and execute.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(#508): add TS front matter parsing, update 22 scenario documents

TS parser uses loadAll() for multi-document YAML. Scenario documents
migrated to front matter format: metadata --- bare action array.

Refs casehub-pages#508"
```

---

## Batch 6: Build Verification

### Task 7: Full cross-repo build verification

**Files:**
- No file changes — verification only

- [ ] **Step 1: Full platform build**

Run: `mvn --batch-mode install` in the platform repo.
Expected: Clean build, all tests pass.

- [ ] **Step 2: Full pages build**

Run: `npm test` in the pages repo.
Expected: All tests pass.

- [ ] **Step 3: Verify no remaining old-name references in platform source**

Search for `StepWalker`, `YamlStepDefinitionSource`, `StepDefinitionParser` (as class names, not in historical specs) in Java source files. Expected: zero hits outside of docs/specs.

- [ ] **Step 4: Verify no remaining `do:` or `steps:` usage in tests**

Search Walker tests for `"do"` and `"steps"` as map keys in test fixtures. Expected: zero hits.

## References

- [2026-10-04-type-unification-design.md] — design spec
- [walker.ts] — TS Walker with target behavior (REMOVED_KEYS, stripKeys, inline resolution)
- [StepWalker.java → Walker.java] — Java Walker, primary modification target
- [ScenarioParser.java] — front matter entry point
- [D37-D39 in decisions.md] — design decisions
- [casehub-pages#508] — focal issue
- [casehub-pages#506] — type unification (landed, established the naming)
