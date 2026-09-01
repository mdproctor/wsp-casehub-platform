# Module Outputs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #256 — feat: module outputs — expose derived values for cross-module composition
**Issue group:** #256

**Goal:** Add typed module outputs to yaml-core — computed values that modules expose for cross-module composition via `${module.alias.outputName}`.

**Architecture:** `YamlModuleOutput(ParameterType type, String value)` on `YamlModule`. `ModuleExpander` resolves output templates during expansion using the module's parameter scope, validates resolved values against declared types, and stores results in `ExpandedModule.moduleOutputs`. Chaining: later imports can use earlier outputs via `${module.*}` in parameter values — resolved before parameter validation. `outputSource()` on `ExpandedModule` creates a `VariableSource` for the `module` prefix.

**Tech Stack:** Java 21, JUnit 5, AssertJ. No external dependencies.

## Global Constraints

- Zero external dependencies — yaml-core has only test-scope deps
- J2CL-transpilable — no reflection, no ConcurrentHashMap, no CDI, no Jackson
- Output templates restricted to `${var.*}` references only (D5)
- Output names must not contain dots, blanks, or `${` (like alias validation)
- Import order = resolution order; forward references are build-time errors
- Parameter validation runs on RESOLVED values, not raw `${module.*}` strings

---

## Batch 1: Model + Output Resolution

### Task 1: YamlModuleOutput + YamlModule update + YamlModuleFile update

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/module/YamlModuleOutput.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/module/YamlModule.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/module/YamlModuleFile.java`
- Modify: `yaml-core/src/test/java/io/casehub/yaml/core/module/YamlModuleFileTest.java`

**Interfaces:**
- Produces: `YamlModuleOutput(ParameterType type, String value)`, updated `YamlModule` with `outputs` field, updated `YamlModuleFile.YamlModuleHeader` with `outputs` — consumed by Task 2

- [ ] **Step 1: Write failing tests**

Add to `YamlModuleFileTest`:

```java
@Test
void toModule_includes_outputs() {
    var output = new YamlModuleOutput(ParameterType.STRING, "jdbc:${var.engine}://db");
    var header = new YamlModuleFile.YamlModuleHeader("db",
            Map.of(), Map.of("url", output));
    var file = new YamlModuleFile(header, Map.of(), List.of());
    var module = file.toModule();
    assertThat(module.outputs()).containsKey("url");
    assertThat(module.outputs().get("url").type()).isEqualTo(ParameterType.STRING);
    assertThat(module.outputs().get("url").value()).isEqualTo("jdbc:${var.engine}://db");
}

@Test
void module_null_outputs_defaults_empty() {
    var module = new YamlModule("m", Map.of(), null, Map.of());
    assertThat(module.outputs()).isEmpty();
}
```

- [ ] **Step 2: Run tests — verify compilation fails**

Run: `/opt/homebrew/bin/mvn -f yaml-core/pom.xml test --batch-mode -q`

- [ ] **Step 3: Create YamlModuleOutput**

```java
package io.casehub.yaml.core.module;

public record YamlModuleOutput(ParameterType type, String value) {}
```

- [ ] **Step 4: Update YamlModule — add outputs field**

Change record to 4 fields: `name`, `parameters`, `outputs`, `sections`. Update compact constructor to default `outputs` to `Map.of()` when null. **Note:** This changes constructor argument order — all existing callers of `new YamlModule(name, params, sections)` must add `Map.of()` for outputs.

```java
public record YamlModule(
        String name,
        Map<String, YamlModuleParameter> parameters,
        Map<String, YamlModuleOutput> outputs,
        Map<String, Map<String, Object>> sections) {

    public YamlModule {
        if (parameters == null) { parameters = Map.of(); }
        if (outputs == null) { outputs = Map.of(); }
        if (sections == null) { sections = Map.of(); }
    }
}
```

- [ ] **Step 5: Update YamlModuleFile.YamlModuleHeader — add outputs**

```java
public record YamlModuleHeader(String name,
        Map<String, YamlModuleParameter> parameters,
        Map<String, YamlModuleOutput> outputs) {
    public YamlModuleHeader {
        if (parameters == null) { parameters = Map.of(); }
        if (outputs == null) { outputs = Map.of(); }
    }
}
```

Update `toModule()`:
```java
public YamlModule toModule() {
    return new YamlModule(module.name(), module.parameters(),
            module.outputs(), sections);
}
```

- [ ] **Step 6: Fix all existing callers of YamlModule constructor**

Every `new YamlModule(name, params, sections)` in test files must become `new YamlModule(name, params, Map.of(), sections)`. Fix in:
- `ModuleExpanderTest.java` — all test methods that construct YamlModule
- Any other test files

- [ ] **Step 7: Run tests — verify all pass**

- [ ] **Step 8: Commit**

```
feat(yaml-core): YamlModuleOutput + outputs field on YamlModule

YamlModuleOutput(ParameterType type, String value) for typed module outputs.
YamlModule gains Map<String, YamlModuleOutput> outputs (3rd field).
YamlModuleFile.YamlModuleHeader updated to carry outputs through toModule().

Refs #256
```

### Task 2: Output resolution + validation in ModuleExpander

**Files:**
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/module/ModuleExpander.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/module/ExpandedModule.java`
- Modify: `yaml-core/src/test/java/io/casehub/yaml/core/module/ModuleExpanderTest.java`

**Interfaces:**
- Consumes: `YamlModuleOutput` from Task 1
- Produces: `ExpandedModule.moduleOutputs` (alias → outputName → resolvedValue), `ExpandedModule.outputSource()` — consumed by downstream resolvers

- [ ] **Step 1: Write failing tests**

```java
@Test
void output_resolves_from_module_parameters() {
    var param = new YamlModuleParameter(ParameterType.STRING, true, null,
            null, null, null, null, null);
    var output = new YamlModuleOutput(ParameterType.STRING,
            "jdbc:${var.engine}://db:5432/app");
    var module = new YamlModule("db", Map.of("engine", param),
            Map.of("url", output), Map.of("nodes", Map.of("n", Map.of())));
    var imp = new YamlImport("db", "app-db", null, Map.of("engine", "postgres"));

    var result = ModuleExpander.expand(List.of(imp),
            Map.of("db", module), Map.of());

    assertThat(result.moduleOutputs()).containsKey("app-db");
    assertThat(result.moduleOutputs().get("app-db"))
            .containsEntry("url", "jdbc:postgres://db:5432/app");
}

@Test
void output_type_validation_passes() {
    var param = new YamlModuleParameter(ParameterType.INTEGER, true, null,
            null, null, null, null, null);
    var output = new YamlModuleOutput(ParameterType.INTEGER, "${var.port}");
    var module = new YamlModule("db", Map.of("port", param),
            Map.of("port", output), Map.of());
    var imp = new YamlImport("db", "a", null, Map.of("port", "5432"));

    var result = ModuleExpander.expand(List.of(imp),
            Map.of("db", module), Map.of());

    assertThat(result.moduleOutputs().get("a")).containsEntry("port", "5432");
}

@Test
void output_type_validation_fails() {
    var param = new YamlModuleParameter(ParameterType.STRING, true, null,
            null, null, null, null, null);
    var output = new YamlModuleOutput(ParameterType.INTEGER, "${var.engine}");
    var module = new YamlModule("db", Map.of("engine", param),
            Map.of("port", output), Map.of());
    var imp = new YamlImport("db", "a", null, Map.of("engine", "postgres"));

    assertThatThrownBy(() -> ModuleExpander.expand(List.of(imp),
            Map.of("db", module), Map.of()))
            .isInstanceOf(IllegalArgumentException.class)
            .hasMessageContaining("port")
            .hasMessageContaining("INTEGER");
}

@Test
void output_template_scope_violation_rejected() {
    var output = new YamlModuleOutput(ParameterType.STRING,
            "${module.other.url}");
    var module = new YamlModule("m", Map.of(),
            Map.of("url", output), Map.of());
    var imp = new YamlImport("m", "a", null, Map.of());

    assertThatThrownBy(() -> ModuleExpander.expand(List.of(imp),
            Map.of("m", module), Map.of()))
            .isInstanceOf(IllegalArgumentException.class)
            .hasMessageContaining("module")
            .hasMessageContaining("${var.*}");
}

@Test
void output_name_with_dot_rejected() {
    var output = new YamlModuleOutput(ParameterType.STRING, "value");
    var module = new YamlModule("m", Map.of(),
            Map.of("nested.key", output), Map.of());
    var imp = new YamlImport("m", "a", null, Map.of());

    assertThatThrownBy(() -> ModuleExpander.expand(List.of(imp),
            Map.of("m", module), Map.of()))
            .isInstanceOf(IllegalArgumentException.class)
            .hasMessageContaining(".");
}

@Test
void module_with_no_outputs_backward_compatible() {
    var module = new YamlModule("m", Map.of(), Map.of(),
            Map.of("nodes", Map.of("n", Map.of())));
    var imp = new YamlImport("m", "a", null, Map.of());

    var result = ModuleExpander.expand(List.of(imp),
            Map.of("m", module), Map.of());

    assertThat(result.moduleOutputs()).containsKey("a");
    assertThat(result.moduleOutputs().get("a")).isEmpty();
}

@Test
void outputSource_resolves_alias_dot_name() {
    var param = new YamlModuleParameter(ParameterType.STRING, false, "pg",
            null, null, null, null, null);
    var output = new YamlModuleOutput(ParameterType.STRING, "${var.engine}");
    var module = new YamlModule("db", Map.of("engine", param),
            Map.of("type", output), Map.of());
    var imp = new YamlImport("db", "app-db", null, Map.of());

    var result = ModuleExpander.expand(List.of(imp),
            Map.of("db", module), Map.of());

    var source = result.outputSource();
    assertThat(source.resolve("app-db.type")).isEqualTo("pg");
}

@Test
void outputSource_returns_null_for_missing() {
    var result = ModuleExpander.expand(List.of(), Map.of(), Map.of());
    assertThat(result.outputSource().resolve("nonexistent.x")).isNull();
}
```

- [ ] **Step 2: Run tests — verify compilation fails**

- [ ] **Step 3: Add moduleOutputs to ExpandedModule + outputSource()**

```java
public record ExpandedModule(
        Map<String, Map<String, Object>> sections,
        Map<String, Map<String, String>> moduleScopes,
        Map<String, String> importConditions,
        Map<String, Map<String, String>> moduleOutputs) {

    @SuppressWarnings("unchecked")
    public <T> Map<String, T> section(String name) {
        return (Map<String, T>) (Map<String, ?>)
                sections.getOrDefault(name, Map.of());
    }

    public VariableSource outputSource() {
        return name -> {
            int dot = name.indexOf('.');
            if (dot < 0) return null;
            String alias = name.substring(0, dot);
            String outputName = name.substring(dot + 1);
            Map<String, String> outputs = moduleOutputs.get(alias);
            return outputs != null ? outputs.get(outputName) : null;
        };
    }
}
```

Import `io.casehub.yaml.core.resolver.VariableSource`.

- [ ] **Step 4: Add output resolution to ModuleExpander**

In the per-import loop, after `resolveParameters` and before section expansion:

1. Validate output names (no dots, no blanks)
2. Validate output template scope (only `${var.*}`)
3. Resolve output templates using module parameter scope
4. Validate resolved values against declared types
5. Store in `allOutputs`

Create helper methods: `validateOutputNames()`, `validateOutputTemplateScope()`, `resolveOutputs()`.

Update all existing `new ExpandedModule(sections, scopes, conditions)` calls to include `moduleOutputs` as 4th argument.

- [ ] **Step 5: Fix existing tests**

All existing `ModuleExpanderTest` tests that check `ExpandedModule` fields need updating for the new constructor parameter. Tests that create modules via `new YamlModule(name, params, Map.of(), sections)` already have the outputs field from Task 1.

- [ ] **Step 6: Run tests — verify all pass**

- [ ] **Step 7: Full build**

Run: `/opt/homebrew/bin/mvn -f yaml-core/pom.xml test --batch-mode -q`

- [ ] **Step 8: Commit**

```
feat(yaml-core): output resolution + validation in ModuleExpander

Resolves output templates using module parameter scope during expansion.
Validates: output names (no dots/blanks), template scope (var-only),
resolved value vs declared type. ExpandedModule gains moduleOutputs +
outputSource() for VariableResolver wiring.

Refs #256
```

## Batch 2: Chaining

### Task 3: Cross-module output chaining in parameter values

**Files:**
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/module/ModuleExpander.java`
- Modify: `yaml-core/src/test/java/io/casehub/yaml/core/module/ModuleExpanderTest.java`

**Interfaces:**
- Consumes: `moduleOutputs` from Task 2, `VariableResolver`, `VariableSource`
- Produces: chaining support — later imports' parameter values can contain `${module.alias.*}`

- [ ] **Step 1: Write failing tests**

```java
@Test
void chaining_later_import_uses_earlier_output() {
    var dbParam = new YamlModuleParameter(ParameterType.STRING, true, null,
            null, null, null, null, null);
    var dbOutput = new YamlModuleOutput(ParameterType.STRING,
            "jdbc:${var.engine}://db:5432/app");
    var dbModule = new YamlModule("database", Map.of("engine", dbParam),
            Map.of("url", dbOutput), Map.of("nodes", Map.of("db", Map.of())));

    var cacheParam = new YamlModuleParameter(ParameterType.STRING, true, null,
            null, null, null, null, null);
    var cacheModule = new YamlModule("cache", Map.of("backend", cacheParam),
            Map.of(), Map.of("nodes", Map.of("c", Map.of())));

    var result = ModuleExpander.expand(
            List.of(new YamlImport("database", "app-db", null,
                            Map.of("engine", "postgres")),
                    new YamlImport("cache", "app-cache", null,
                            Map.of("backend", "${module.app-db.url}"))),
            Map.of("database", dbModule, "cache", cacheModule),
            Map.of());

    assertThat(result.moduleScopes().get("app-cache"))
            .containsEntry("backend", "jdbc:postgres://db:5432/app");
}

@Test
void forward_reference_throws_actionable_error() {
    var module = new YamlModule("m", Map.of(),
            Map.of("out", new YamlModuleOutput(ParameterType.STRING, "val")),
            Map.of());

    assertThatThrownBy(() -> ModuleExpander.expand(
            List.of(new YamlImport("m", "b", null,
                            Map.of("x", "${module.a.out}")),
                    new YamlImport("m", "a", null, Map.of())),
            Map.of("m", module), Map.of()))
            .isInstanceOf(IllegalArgumentException.class)
            .hasMessageContaining("b")
            .hasMessageContaining("a")
            .hasMessageContaining("before");
}

@Test
void chaining_type_validated_after_resolution() {
    var dbParam = new YamlModuleParameter(ParameterType.INTEGER, true, null,
            null, null, null, null, null);
    var dbOutput = new YamlModuleOutput(ParameterType.INTEGER, "${var.port}");
    var dbModule = new YamlModule("db", Map.of("port", dbParam),
            Map.of("port", dbOutput), Map.of());

    var appParam = new YamlModuleParameter(ParameterType.INTEGER, true, null,
            null, null, null, null, null);
    var appModule = new YamlModule("app", Map.of("dbPort", appParam),
            Map.of(), Map.of());

    var result = ModuleExpander.expand(
            List.of(new YamlImport("db", "mydb", null, Map.of("port", "5432")),
                    new YamlImport("app", "myapp", null,
                            Map.of("dbPort", "${module.mydb.port}"))),
            Map.of("db", dbModule, "app", appModule),
            Map.of());

    assertThat(result.moduleScopes().get("myapp"))
            .containsEntry("dbPort", "5432");
}

@Test
void conditional_import_outputs_available() {
    var output = new YamlModuleOutput(ParameterType.STRING, "value");
    var module = new YamlModule("m", Map.of(),
            Map.of("out", output), Map.of());

    var result = ModuleExpander.expand(
            List.of(new YamlImport("m", "gated", "${var.enabled}", Map.of())),
            Map.of("m", module), Map.of());

    assertThat(result.moduleOutputs().get("gated"))
            .containsEntry("out", "value");
}
```

- [ ] **Step 2: Run tests — verify they fail**

- [ ] **Step 3: Add `${module.*}` resolution in parameter values**

In `ModuleExpander`, before parameter validation:
1. Build a `VariableSource` from `allOutputs` (already-resolved outputs)
2. For each parameter value in the import, check for `${module.*}` references
3. If found, verify the referenced alias exists in `allOutputs.keySet()` — if not, throw forward-reference error with actionable message
4. Resolve using a temporary `VariableResolver` with the `module` source
5. Pass resolved values to `ParameterValidator.validateOrThrow()`

```java
private static Map<String, String> resolveModuleRefsInParams(
        Map<String, String> rawParams,
        Map<String, Map<String, String>> allOutputs,
        String currentAlias) {
    if (rawParams.values().stream().noneMatch(v -> v.contains("${module."))) {
        return rawParams;
    }
    VariableSource moduleSource = buildModuleSource(allOutputs);
    VariableResolver resolver = new VariableResolver(
            Map.of("module", moduleSource), Set.of());
    Map<String, String> resolved = new LinkedHashMap<>();
    for (var entry : rawParams.entrySet()) {
        String value = entry.getValue();
        if (value.contains("${module.")) {
            // Check for forward references
            checkForwardRefs(value, allOutputs.keySet(), currentAlias);
            value = resolver.resolveString(value, currentAlias + "." + entry.getKey());
        }
        resolved.put(entry.getKey(), value);
    }
    return resolved;
}

private static VariableSource buildModuleSource(
        Map<String, Map<String, String>> allOutputs) {
    return name -> {
        int dot = name.indexOf('.');
        if (dot < 0) return null;
        String alias = name.substring(0, dot);
        String outputName = name.substring(dot + 1);
        Map<String, String> outputs = allOutputs.get(alias);
        return outputs != null ? outputs.get(outputName) : null;
    };
}
```

- [ ] **Step 4: Run tests — verify all pass**

- [ ] **Step 5: Full build**

Run: `/opt/homebrew/bin/mvn -f yaml-core/pom.xml test --batch-mode -q`

- [ ] **Step 6: Commit**

```
feat(yaml-core): cross-module output chaining in parameter values

Later imports can reference earlier imports' resolved outputs via
${module.alias.outputName} in parameter values. Resolution happens
before parameter validation so types are checked on actual values.
Forward references throw actionable error with reorder guidance.

Closes #256
Refs #256
```

## References

- `specs/issue-256-module-outputs/2026-09-01-module-outputs-design.md` — design spec
- `specs/issue-256-module-outputs/decisions.md` — D1–D5 decisions
- `io.casehub.yaml.core.module.YamlModule` — Task 1 target
- `io.casehub.yaml.core.module.ModuleExpander` — Tasks 2-3 target
- `io.casehub.yaml.core.module.ExpandedModule` — Task 2 target
- `io.casehub.yaml.core.module.ParameterType` — reused for output type validation
- `io.casehub.yaml.core.resolver.VariableResolver` — used internally for template resolution
- `io.casehub.yaml.core.resolver.VariableSource` — outputSource() return type
- casehubio/platform#256 — focal issue
- casehubio/platform#260 — structural type checking (follow-up)
