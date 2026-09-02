# yaml-core Structural Type Checking — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #260 — yaml-core structural type checking — compile-time safety for module composition
**Issue group:** #260

**Goal:** Add expansion-time structural type checking for cross-module output-to-parameter references in `ModuleExpander`, catching type mismatches and missing outputs before resolution.

**Architecture:** New `validateModuleRefs()` method in `ModuleExpander` runs after `validateImports()` and before the expansion loop, scanning all import parameter values for `${module.*}` references and collecting forward-reference, missing-output, and type-incompatibility errors in one pass. `ParameterType` gains a `canAccept(ParameterType)` method implementing the compatibility matrix.

**Tech Stack:** Pure Java (zero dependencies), JUnit 5, AssertJ

## Global Constraints

- yaml-core must remain zero-dependency and J2CL-transpilable
- All validation errors use `ParameterViolation` / `ParameterValidationException` (existing types)
- Collect-all error reporting — never fail-fast
- Existing tests must pass unchanged

---

## Batch 1: Structural type checking

### Task 1: ParameterType.canAccept — type compatibility matrix

**Files:**
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/module/ParameterType.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/module/ParameterTypeTest.java`

**Interfaces:**
- Consumes: nothing (standalone addition)
- Produces: `boolean ParameterType.canAccept(ParameterType outputType)` — used by Task 2's `validateModuleRefs`

- [ ] **Step 1: Write failing tests for canAccept**

Add to `ParameterTypeTest.java`:

```java
@Test
void canAccept_same_type_always_true() {
    for (ParameterType type : ParameterType.values()) {
        assertThat(type.canAccept(type))
                .as(type + " should accept itself")
                .isTrue();
    }
}

@Test
void canAccept_string_accepts_scalars() {
    assertThat(ParameterType.STRING.canAccept(ParameterType.INTEGER)).isTrue();
    assertThat(ParameterType.STRING.canAccept(ParameterType.NUMBER)).isTrue();
    assertThat(ParameterType.STRING.canAccept(ParameterType.BOOLEAN)).isTrue();
}

@Test
void canAccept_string_rejects_list() {
    assertThat(ParameterType.STRING.canAccept(ParameterType.LIST)).isFalse();
}

@Test
void canAccept_number_accepts_integer() {
    assertThat(ParameterType.NUMBER.canAccept(ParameterType.INTEGER)).isTrue();
}

@Test
void canAccept_number_rejects_others() {
    assertThat(ParameterType.NUMBER.canAccept(ParameterType.STRING)).isFalse();
    assertThat(ParameterType.NUMBER.canAccept(ParameterType.BOOLEAN)).isFalse();
    assertThat(ParameterType.NUMBER.canAccept(ParameterType.LIST)).isFalse();
}

@Test
void canAccept_integer_rejects_number() {
    assertThat(ParameterType.INTEGER.canAccept(ParameterType.NUMBER)).isFalse();
}

@Test
void canAccept_boolean_rejects_non_boolean() {
    assertThat(ParameterType.BOOLEAN.canAccept(ParameterType.STRING)).isFalse();
    assertThat(ParameterType.BOOLEAN.canAccept(ParameterType.INTEGER)).isFalse();
    assertThat(ParameterType.BOOLEAN.canAccept(ParameterType.NUMBER)).isFalse();
    assertThat(ParameterType.BOOLEAN.canAccept(ParameterType.LIST)).isFalse();
}

@Test
void canAccept_list_rejects_non_list() {
    assertThat(ParameterType.LIST.canAccept(ParameterType.STRING)).isFalse();
    assertThat(ParameterType.LIST.canAccept(ParameterType.INTEGER)).isFalse();
    assertThat(ParameterType.LIST.canAccept(ParameterType.NUMBER)).isFalse();
    assertThat(ParameterType.LIST.canAccept(ParameterType.BOOLEAN)).isFalse();
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=ParameterTypeTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: compilation failure — `canAccept` method does not exist

- [ ] **Step 3: Implement canAccept on ParameterType**

Add to `ParameterType.java` after the `parse` method:

```java
public boolean canAccept(ParameterType outputType) {
    if (this == outputType) return true;
    if (this == STRING && outputType != LIST) return true;
    if (this == NUMBER && outputType == INTEGER) return true;
    return false;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=ParameterTypeTest`
Expected: all tests PASS

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add yaml-core/src/main/java/io/casehub/yaml/core/module/ParameterType.java yaml-core/src/test/java/io/casehub/yaml/core/module/ParameterTypeTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(yaml-core): ParameterType.canAccept — type compatibility matrix Refs #260"
```

### Task 2: validateModuleRefs — collect-all module reference validation

**Files:**
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/module/ModuleExpander.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/module/ModuleExpanderTest.java`

**Interfaces:**
- Consumes: `ParameterType.canAccept(ParameterType)` from Task 1
- Produces: no new public API — `validateModuleRefs` is `private static`, called from `expand()`

- [ ] **Step 1: Write failing test — missing output reference**

Add to `ModuleExpanderTest.java`:

```java
@Test
void missing_output_reference_throws() {
    var output = new YamlModuleOutput(ParameterType.STRING, "val");
    var module = new YamlModule("m", Map.of(), Map.of("real", output), Map.of());
    var paramDecl = new YamlModuleParameter(ParameterType.STRING, true, null,
            null, null, null, null, null);
    var consumer = new YamlModule("c", Map.of("x", paramDecl), Map.of(), Map.of());

    assertThatThrownBy(() -> ModuleExpander.expand(
            List.of(new YamlImport("m", "a", null, Map.of()),
                    new YamlImport("c", "b", null,
                            Map.of("x", "${module.a.nonexistent}"))),
            Map.of("m", module, "c", consumer), Map.of()))
            .isInstanceOf(ParameterValidationException.class)
            .satisfies(ex -> {
                var violations = ((ParameterValidationException) ex).violations();
                assertThat(violations).hasSize(1);
                assertThat(violations.get(0).constraint())
                        .isEqualTo("module-ref-missing-output");
                assertThat(violations.get(0).message())
                        .contains("nonexistent")
                        .contains("real");
            });
}
```

- [ ] **Step 2: Write failing test — type incompatible whole-value reference**

```java
@Test
void type_incompatible_whole_value_throws() {
    var boolOutput = new YamlModuleOutput(ParameterType.BOOLEAN, "${var.flag}");
    var boolParam = new YamlModuleParameter(ParameterType.BOOLEAN, true, null,
            null, null, null, null, null);
    var producer = new YamlModule("producer",
            Map.of("flag", boolParam),
            Map.of("enabled", boolOutput), Map.of());

    var intParam = new YamlModuleParameter(ParameterType.INTEGER, true, null,
            null, null, null, null, null);
    var consumer = new YamlModule("consumer",
            Map.of("count", intParam), Map.of(), Map.of());

    assertThatThrownBy(() -> ModuleExpander.expand(
            List.of(new YamlImport("producer", "p", null,
                            Map.of("flag", "true")),
                    new YamlImport("consumer", "c", null,
                            Map.of("count", "${module.p.enabled}"))),
            Map.of("producer", producer, "consumer", consumer), Map.of()))
            .isInstanceOf(ParameterValidationException.class)
            .satisfies(ex -> {
                var violations = ((ParameterValidationException) ex).violations();
                assertThat(violations).hasSize(1);
                assertThat(violations.get(0).constraint())
                        .isEqualTo("module-ref-type-incompatible");
                assertThat(violations.get(0).message())
                        .contains("BOOLEAN")
                        .contains("INTEGER");
            });
}
```

- [ ] **Step 3: Write failing test — type compatible widening passes**

```java
@Test
void type_compatible_widening_passes() {
    var intOutput = new YamlModuleOutput(ParameterType.INTEGER, "${var.port}");
    var intParam = new YamlModuleParameter(ParameterType.INTEGER, true, null,
            null, null, null, null, null);
    var producer = new YamlModule("producer",
            Map.of("port", intParam),
            Map.of("port", intOutput), Map.of());

    var numParam = new YamlModuleParameter(ParameterType.NUMBER, true, null,
            null, null, null, null, null);
    var consumer = new YamlModule("consumer",
            Map.of("factor", numParam), Map.of(), Map.of());

    var result = ModuleExpander.expand(
            List.of(new YamlImport("producer", "p", null,
                            Map.of("port", "5432")),
                    new YamlImport("consumer", "c", null,
                            Map.of("factor", "${module.p.port}"))),
            Map.of("producer", producer, "consumer", consumer), Map.of());

    assertThat(result.moduleScopes().get("c"))
            .containsEntry("factor", "5432");
}
```

- [ ] **Step 4: Write failing test — embedded ref into non-STRING param**

```java
@Test
void embedded_ref_non_string_param_throws() {
    var strOutput = new YamlModuleOutput(ParameterType.STRING, "val");
    var producer = new YamlModule("producer", Map.of(),
            Map.of("host", strOutput), Map.of());

    var intParam = new YamlModuleParameter(ParameterType.INTEGER, true, null,
            null, null, null, null, null);
    var consumer = new YamlModule("consumer",
            Map.of("port", intParam), Map.of(), Map.of());

    assertThatThrownBy(() -> ModuleExpander.expand(
            List.of(new YamlImport("producer", "p", null, Map.of()),
                    new YamlImport("consumer", "c", null,
                            Map.of("port", "prefix-${module.p.host}"))),
            Map.of("producer", producer, "consumer", consumer), Map.of()))
            .isInstanceOf(ParameterValidationException.class)
            .satisfies(ex -> {
                var violations = ((ParameterValidationException) ex).violations();
                assertThat(violations).hasSize(1);
                assertThat(violations.get(0).constraint())
                        .isEqualTo("module-ref-embedded-type");
                assertThat(violations.get(0).message())
                        .contains("INTEGER")
                        .contains("string interpolation");
            });
}
```

- [ ] **Step 5: Write failing test — embedded ref into STRING param passes**

```java
@Test
void embedded_ref_string_param_passes() {
    var strOutput = new YamlModuleOutput(ParameterType.STRING, "localhost");
    var producer = new YamlModule("producer", Map.of(),
            Map.of("host", strOutput), Map.of());

    var strParam = new YamlModuleParameter(ParameterType.STRING, true, null,
            null, null, null, null, null);
    var consumer = new YamlModule("consumer",
            Map.of("url", strParam), Map.of(), Map.of());

    var result = ModuleExpander.expand(
            List.of(new YamlImport("producer", "p", null, Map.of()),
                    new YamlImport("consumer", "c", null,
                            Map.of("url", "http://${module.p.host}:8080"))),
            Map.of("producer", producer, "consumer", consumer), Map.of());

    assertThat(result.moduleScopes().get("c"))
            .containsEntry("url", "http://localhost:8080");
}
```

- [ ] **Step 6: Write failing test — collect-all reports multiple errors**

```java
@Test
void collect_all_multiple_errors() {
    var boolOutput = new YamlModuleOutput(ParameterType.BOOLEAN, "true");
    var producer = new YamlModule("producer", Map.of(),
            Map.of("flag", boolOutput), Map.of());

    var intParam = new YamlModuleParameter(ParameterType.INTEGER, true, null,
            null, null, null, null, null);
    var strParam = new YamlModuleParameter(ParameterType.STRING, true, null,
            null, null, null, null, null);
    var consumer = new YamlModule("consumer",
            Map.of("count", intParam, "name", strParam), Map.of(), Map.of());

    assertThatThrownBy(() -> ModuleExpander.expand(
            List.of(new YamlImport("producer", "p", null, Map.of()),
                    new YamlImport("consumer", "c", null,
                            Map.of("count", "${module.p.flag}",
                                    "name", "${module.p.missing}"))),
            Map.of("producer", producer, "consumer", consumer), Map.of()))
            .isInstanceOf(ParameterValidationException.class)
            .satisfies(ex -> {
                var violations = ((ParameterValidationException) ex).violations();
                assertThat(violations).hasSizeGreaterThanOrEqualTo(2);
                assertThat(violations.stream().map(ParameterViolation::constraint))
                        .contains("module-ref-type-incompatible",
                                "module-ref-missing-output");
            });
}
```

- [ ] **Step 7: Write failing test — LIST to STRING rejected**

```java
@Test
void list_to_string_rejected() {
    var listOutput = new YamlModuleOutput(ParameterType.LIST, "${var.items}");
    var listParam = new YamlModuleParameter(ParameterType.LIST, true, null,
            null, null, null, null, null);
    var producer = new YamlModule("producer",
            Map.of("items", listParam),
            Map.of("items", listOutput), Map.of());

    var strParam = new YamlModuleParameter(ParameterType.STRING, true, null,
            null, null, null, null, null);
    var consumer = new YamlModule("consumer",
            Map.of("label", strParam), Map.of(), Map.of());

    assertThatThrownBy(() -> ModuleExpander.expand(
            List.of(new YamlImport("producer", "p", null,
                            Map.of("items", "a,b,c")),
                    new YamlImport("consumer", "c", null,
                            Map.of("label", "${module.p.items}"))),
            Map.of("producer", producer, "consumer", consumer), Map.of()))
            .isInstanceOf(ParameterValidationException.class)
            .satisfies(ex -> {
                var violations = ((ParameterValidationException) ex).violations();
                assertThat(violations).hasSize(1);
                assertThat(violations.get(0).constraint())
                        .isEqualTo("module-ref-type-incompatible");
            });
}
```

- [ ] **Step 8: Run all new tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=ModuleExpanderTest`
Expected: new tests FAIL (missing_output_reference_throws, type_incompatible_whole_value_throws, etc. fail because `validateModuleRefs` doesn't exist yet). Existing tests still PASS.

- [ ] **Step 9: Implement validateModuleRefs and helper methods**

Add to `ModuleExpander.java`:

1. Add the `WHOLE_MODULE_REF` pattern constant:
```java
private static final Pattern WHOLE_MODULE_REF =
        Pattern.compile("^\\s*\\$\\{module\\.[^}]+}\\s*$");
```

2. Add the `isWholeModuleRef` method:
```java
private static boolean isWholeModuleRef(String value) {
    return WHOLE_MODULE_REF.matcher(value).matches();
}
```

3. Add the `findModuleByAlias` method:
```java
private static YamlModule findModuleByAlias(String alias,
        List<YamlImport> imports,
        Map<String, YamlModule> availableModules) {
    for (YamlImport imp : imports) {
        if (alias.equals(imp.as())) {
            return availableModules.get(imp.module());
        }
    }
    return null;
}
```

4. Add the `validateModuleRefs` method (full implementation from the spec — see design doc section 2).

5. Update `expand()` — add `validateModuleRefs(imports, availableModules);` after `validateImports(imports, availableModules);`.

6. Replace `checkForwardRefs` call in `resolveModuleRefsInParams` with a defense-in-depth guard:
```java
// Replace the call to checkForwardRefs(value, allOutputs.keySet(), currentAlias);
// with a minimal assertion:
Matcher guardMatcher = VAR_REF.matcher(value);
while (guardMatcher.find()) {
    String guardKey = guardMatcher.group(1);
    if (!guardKey.startsWith("module.")) continue;
    String rest = guardKey.substring("module.".length());
    int dot = rest.indexOf('.');
    if (dot < 0) continue;
    String refAlias = rest.substring(0, dot);
    if (!allOutputs.containsKey(refAlias)) {
        throw new IllegalStateException(
                "Forward reference to '" + refAlias + "' in import '"
                + currentAlias
                + "' — should have been caught by validateModuleRefs.");
    }
}
```

7. Remove the `checkForwardRefs` method (dead code after consolidation).

- [ ] **Step 10: Run all ModuleExpander tests**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=ModuleExpanderTest`
Expected: ALL tests PASS — both new and existing (including `forward_reference_throws_actionable_error` which should still pass via `validateModuleRefs`)

- [ ] **Step 11: Run full yaml-core test suite**

Run: `mvn --batch-mode test -pl yaml-core`
Expected: ALL tests PASS — no regressions

- [ ] **Step 12: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add yaml-core/src/main/java/io/casehub/yaml/core/module/ModuleExpander.java yaml-core/src/test/java/io/casehub/yaml/core/module/ModuleExpanderTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(yaml-core): structural type checking for cross-module output references

Adds validateModuleRefs() to ModuleExpander — collect-all validation
of ${module.*} references in import parameters. Checks: forward refs,
missing outputs, type compatibility (via ParameterType.canAccept),
and embedded interpolation into non-STRING parameters.

Consolidates checkForwardRefs into the new validation pass with a
defense-in-depth assertion guard retained in resolution.

Refs #260"
```

## References

- `specs/issue-260-yaml-structural-type-checks/2026-09-01-yaml-structural-type-checks-design.md` — design spec
- `yaml-core/src/main/java/io/casehub/yaml/core/module/ModuleExpander.java` — target file (validateImports, checkForwardRefs, resolveModuleRefsInParams, expand)
- `yaml-core/src/main/java/io/casehub/yaml/core/module/ParameterType.java` — target file (canAccept addition)
- `yaml-core/src/main/java/io/casehub/yaml/core/module/YamlModuleOutput.java` — output model with type field (#256)
- `yaml-core/src/main/java/io/casehub/yaml/core/module/ParameterValidator.java` — collect-all pattern reference
- `docs/specs/issue-252-yaml-core-modules/2026-08-31-yaml-core-modules-design.md` — module system design
- GitHub #260 — focal issue
- GitHub #256 — module outputs (dependency, closed)
- GitHub #252 — module system (dependency, closed)
